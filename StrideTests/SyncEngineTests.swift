import XCTest
import SwiftData
import Foundation

/// The 1.3.1 sync run (`SyncEngine`, Shared/) end to end on in-memory stores: two "devices" —
/// each its own container, queue, cursor store, recovery log and gate — against one
/// `FakeSyncServer`. The engine, planner, resolver and reconciler are the real ones; only the
/// network is replaced, by a small model of routes/sync.js that is the transport's double, not
/// the code under test. scripts/sync_rehearsal.sh drives the same engine against the real
/// server.
///
/// DEV-PLAN-1.3.md M2, Tests: *Delivery state*, the engine-level parts of *Full-pull
/// deletion* and *Restore*, and the run binding (review 2).
@MainActor
final class SyncEngineTests: XCTestCase {

    var server: FakeSyncServer!
    var devices: [TestDevice] = []

    override func setUp() {
        super.setUp()
        server = FakeSyncServer()
        server.validTokens = ["token-A", "token-A2", "token-B"]
    }

    override func tearDown() {
        devices.forEach { $0.remove() }
        devices = []
        server = nil
        super.tearDown()
    }

    private func device(owner: String = "1", token: String = "token-A",
                        bounds: SyncPushBounds = .standard,
                        recoveryLog: (any SyncRecoveryLogSink)? = nil,
                        backoff: Bool = false) -> TestDevice {
        let d = TestDevice(server: server, owner: owner, token: token, bounds: bounds,
                           recoveryLog: recoveryLog, backoff: backoff)
        devices.append(d)
        return d
    }

    private let day0 = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    private func day(_ n: Int) -> Date { day0.addingTimeInterval(Double(n) * 86_400) }

    @discardableResult
    private func expectSynced(_ outcome: SyncRunOutcome, file: StaticString = #filePath, line: UInt = #line) -> SyncRunSummary {
        guard case .synced(let summary) = outcome else {
            XCTFail("expected .synced, got \(outcome)", file: file, line: line)
            return SyncRunSummary()
        }
        return summary
    }

    // MARK: - The vertical slice: two devices, one account

    /// The happy path: A's habits reach B, B's tap reaches A, and a second sync with no edits
    /// pushes nothing (1.3.0 pushed the whole store every time).
    func testTwoDevicesConvergeAndASyncWithNoEditsPushesNothing() async throws {
        let a = device(), b = device(token: "token-A2")
        let read = a.habit("Read", records: [day(0), day(1)])
        a.habit("Run")
        try a.save()

        let first = expectSynced(await a.sync())
        XCTAssertEqual(first.pushedRows, SyncRowCounts(groups: 0, habits: 2, entries: 2))
        XCTAssertEqual(first.pulls.first?.fullPull, true, "no cursor yet: full pull first")
        XCTAssertEqual(first.requests.map(\.endpoint), [.pull, .push, .pull])

        expectSynced(await b.sync())
        XCTAssertEqual(try b.habitNames(), ["Read", "Run"])
        let bRead = try XCTUnwrap(b.habits().first { $0.id == read.id })
        XCTAssertEqual(bRead.records.count, 2)

        // One tap on B → the next push carries exactly one entry and no habit.
        bRead.records.append(HabitRecord(date: day(2)))
        try b.save()
        let tap = expectSynced(await b.sync())
        XCTAssertEqual(tap.pushedRows, SyncRowCounts(groups: 0, habits: 0, entries: 1))

        expectSynced(await a.sync())
        XCTAssertEqual(read.records.count, 3)

        // Nothing edited anywhere: no push request at all, both ways.
        for d in [a, b] {
            let idle = expectSynced(await d.sync())
            XCTAssertTrue(idle.pushes.isEmpty, "a sync with no edits pushed \(idle.pushedRows)")
            XCTAssertEqual(try d.pendingCount(), 0)
        }
    }

    /// Two edits of one entry 300 ms apart on two devices end as the later edit, whichever
    /// pushes first — millisecond stamps on the wire, and the local-newer guard at milliseconds.
    func testTwoEditsThreeHundredMillisecondsApartEndAsTheLaterWhicheverPushesFirst() async throws {
        for laterPushesFirst in [true, false] {
            server = FakeSyncServer()
            server.validTokens = ["token-A", "token-A2"]
            let a = device(), b = device(token: "token-A2")
            a.habit("Water", records: [day(0)])
            try a.save()
            expectSynced(await a.sync())
            expectSynced(await b.sync())

            let base = SyncTimestamp.floorToMillisecond(Date()).addingTimeInterval(5)
            let aRecord = try XCTUnwrap(a.habits().first?.records.first)
            let bRecord = try XCTUnwrap(b.habits().first?.records.first)
            aRecord.value = 3; aRecord.updatedAt = base.addingTimeInterval(0.300)
            bRecord.value = 5; bRecord.updatedAt = base.addingTimeInterval(0.700)   // the later edit
            try a.save(); try b.save()

            let (first, second) = laterPushesFirst ? (b, a) : (a, b)
            expectSynced(await first.sync())
            expectSynced(await second.sync())
            expectSynced(await first.sync())

            XCTAssertEqual(aRecord.value, 5, "later pushes first: \(laterPushesFirst)")
            XCTAssertEqual(bRecord.value, 5, "later pushes first: \(laterPushesFirst)")
            XCTAssertEqual(try a.pendingCount(), 0)
            XCTAssertEqual(try b.pendingCount(), 0)
        }
    }

    /// A device whose clock runs 10 minutes slow loses an edit and ends with the winner's value:
    /// the server's LWW re-feed puts the winner back into the feed, and the loser's reconciler
    /// adopts it (review 2, "The LWW winner goes back to the device that lost").
    func testASlowClockDeviceThatLosesAnEditEndsWithTheWinnersValue() async throws {
        let fast = device(), slow = device(token: "token-A2")
        fast.habit("Read")
        try fast.save()
        expectSynced(await fast.sync())
        expectSynced(await slow.sync())

        let winner = try XCTUnwrap(fast.habits().first)
        winner.name = "Winner"
        winner.touch()
        try fast.save()
        expectSynced(await fast.sync())
        expectSynced(await slow.sync())

        let loser = try XCTUnwrap(slow.habits().first)
        XCTAssertEqual(loser.name, "Winner")
        loser.name = "Loser"
        loser.updatedAt = winner.stamp.addingTimeInterval(-600)   // stamped by a slow clock
        try slow.save()
        expectSynced(await slow.sync())
        expectSynced(await slow.sync())

        XCTAssertEqual(loser.name, "Winner")
        XCTAssertEqual(try slow.pendingCount(), 0)
    }

    /// A habit deleted on B while A edited one of its check-ins offline: gone from A after its
    /// sync, and A's recovery log holds the edit.
    func testAHabitDeletedElsewhereWhileEditedOfflineIsGoneAndTheEditIsRecoverable() async throws {
        let a = device(), b = device(token: "token-A2")
        a.habit("Read", records: [day(0)])
        try a.save()
        expectSynced(await a.sync())
        expectSynced(await b.sync())

        let bHabit = try XCTUnwrap(b.habits().first)
        b.queue.trackHabit(bHabit.id.uuidString)
        b.context.delete(bHabit)
        try b.save()
        expectSynced(await b.sync())

        let aRecord = try XCTUnwrap(a.habits().first?.records.first)
        aRecord.note = "offline edit"
        aRecord.touch()
        try a.save()
        expectSynced(await a.sync())

        XCTAssertTrue(try a.habits().isEmpty)
        let line = try XCTUnwrap(a.log.lines.first { $0.item.ref.id == aRecord.id.uuidString })
        guard case let .record(record, _, habitName) = line.item.row else { return XCTFail() }
        XCTAssertEqual(record.note, "offline edit")
        XCTAssertEqual(habitName, "Read")
        XCTAssertEqual(line.accountID, "1")
    }

    // MARK: - Chunks

    /// A failure injected at chunk 2 leaves chunk 1 acknowledged, sends no later chunk, and the
    /// retry sends only what chunk 2 carried.
    func testAFailureAtChunkTwoKeepsChunkOneAndTheRetrySendsOnlyTheRest() async throws {
        var bounds = SyncPushBounds.standard
        bounds.habits = 2
        let a = device(bounds: bounds)
        for n in 0..<5 { a.habit("H\(n)") }
        try a.save()
        expectSynced(await a.sync())   // settles the cursor; pushes all five
        for habit in try a.habits() { habit.touch() }
        try a.save()

        server.scriptPush(at: 2, SyncTransportResponse(status: 503, body: Data(#"{"error":"server_error"}"#.utf8)))
        let failed = await a.sync()
        guard case .stopped(.backOff(.transient, _), let summary) = failed else { return XCTFail("\(failed)") }
        XCTAssertEqual(summary.pushes.count, 2, "chunk 3 must not run after chunk 2 failed")
        XCTAssertEqual(summary.acknowledged, 2)
        XCTAssertEqual(try a.pendingCount(), 3)

        let retry = expectSynced(await a.sync())
        XCTAssertEqual(retry.pushedRows.habits, 3)
        XCTAssertEqual(try a.pendingCount(), 0)
    }

    /// `400 too_many_rows` re-chunks against the returned limits and resends in the same sync.
    func testTooManyRowsReChunksAgainstTheLimitsInTheSameSync() async throws {
        let a = device()
        for n in 0..<6 { a.habit("H\(n)") }
        try a.save()
        server.rowLimits = SyncRowLimits(habits: 4, entries: 5000, groups: 200)

        let summary = expectSynced(await a.sync())
        XCTAssertEqual(summary.pushes.map(\.status), [400, 200, 200])
        XCTAssertEqual(summary.pushes.dropFirst().map(\.rows.habits), [4, 2])
        XCTAssertEqual(try a.pendingCount(), 0)
    }

    /// A `row_error` row is held, the rest of its chunk lands, and it survives the next full pull
    /// without being sent again until edited.
    func testARowErrorIsHeldSurvivesAFullPullAndIsNotResentUntilEdited() async throws {
        let a = device()
        let bad = a.habit("Bad")
        a.habit("Good", records: [day(0)])
        try a.save()
        server.forcedReasons[bad.id.uuidString] = "row_error"

        expectSynced(await a.sync())
        XCTAssertEqual(bad.activeHold, .rowError)
        XCTAssertEqual(server.habits.count, 1)
        XCTAssertEqual(server.entries.count, 1)

        a.cursors.setCursor(nil, for: "1")   // the next sync full-pulls
        let next = expectSynced(await a.sync())
        XCTAssertTrue(next.pushes.isEmpty, "the held row is not sent again")
        XCTAssertTrue(try a.habits().contains { $0.id == bad.id }, "held rows survive a full pull")

        server.forcedReasons = [:]
        bad.name = "Fixed"
        bad.touch()
        try a.save()
        expectSynced(await a.sync())
        XCTAssertNil(bad.activeHold)
        XCTAssertEqual(server.habits.count, 2)
    }

    // MARK: - Cursor age and forced resend

    /// A cursor older than retention − 10 d is cleared locally and the run full-pulls before it
    /// pushes; so is one the server answers `409 cursor_expired`.
    func testAnExpiredCursorFullPullsFirstLocallyOrWhenTheServerSaysSo() async throws {
        let a = device()
        a.habit("Read")
        try a.save()
        expectSynced(await a.sync())

        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-400 * 86_400)), for: "1")
        try XCTUnwrap(a.habits().first).touch()
        try a.save()
        let local = expectSynced(await a.sync())
        XCTAssertEqual(local.requests.map(\.endpoint), [.pull, .push, .pull])
        XCTAssertEqual(local.pulls.first?.fullPull, true)
        XCTAssertFalse(server.requests.contains { $0.since.map { SyncTimestamp.parse($0)! < Date().addingTimeInterval(-300 * 86_400) } ?? false },
                       "the expired cursor was never sent")

        server.expireNextCursor = true
        try XCTUnwrap(a.habits().first).touch()
        try a.save()
        let remote = expectSynced(await a.sync())
        XCTAssertEqual(remote.requests.map(\.endpoint), [.push, .pull, .pull])
        XCTAssertEqual(remote.pulls.map(\.status), [409, 200])
        XCTAssertEqual(remote.pulls.last?.fullPull, true)
    }

    /// `409 snapshot_required` on a push: every row `needsResend` with `syncedAt` kept, then a
    /// pull on the live cursor BEFORE the resend goes up — in the same run.
    func testSnapshotRequiredMarksEveryRowAndPullsBeforeTheResend() async throws {
        let a = device()
        let habit = a.habit("Read", records: [day(0)])
        try a.save()
        expectSynced(await a.sync())
        // Move the cursor past the 60 s overlap: a row the next pull brings back is one the
        // server holds, and applying it clears `needsResend` — it needs no resend.
        server.clock += 120
        expectSynced(await a.sync())
        let deliveredAt = habit.syncedAt
        habit.touch()
        try a.save()

        server.snapshotRequested = true
        var checkedFirstPull = false
        server.onRequest = { request in
            // At the pull after the 409: marked, delivered state kept, nothing resent yet.
            guard request.endpoint == .pull, !checkedFirstPull else { return }
            checkedFirstPull = true
            XCTAssertTrue(habit.needsResend)
            XCTAssertEqual(habit.syncedAt, deliveredAt)
            XCTAssertTrue(habit.records.allSatisfy(\.needsResend))
        }
        let summary = expectSynced(await a.sync())
        server.onRequest = nil

        XCTAssertEqual(summary.requests.map(\.endpoint), [.push, .pull, .push, .pull])
        XCTAssertEqual(summary.pushes.map(\.status), [409, 200])
        XCTAssertEqual(summary.pushes.last?.rows, SyncRowCounts(groups: 0, habits: 1, entries: 1), "the resend: everything")
        XCTAssertFalse(habit.needsResend)
        XCTAssertEqual(try a.pendingCount(), 0)
    }

    /// A sync holding `needsResend` rows pulls before it pushes; on an expired cursor it
    /// full-pulls first, so a delivered row the server no longer has — its tombstone swept — is
    /// deleted (archived), not resent as a new insert (review 2).
    func testAForcedResendOnAnExpiredCursorDeletesADeliveredButAbsentRowInsteadOfResendingIt() async throws {
        let a = device(), b = device(token: "token-A2")
        a.habit("Kept")
        let doomed = a.habit("Deleted elsewhere")
        try a.save()
        expectSynced(await a.sync())
        expectSynced(await b.sync())

        let bDoomed = try XCTUnwrap(b.habits().first { $0.id == doomed.id })
        b.queue.trackHabit(bDoomed.id.uuidString)
        b.context.delete(bDoomed)
        try b.save()
        expectSynced(await b.sync())
        server.tombstones.removeAll()   // swept

        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-400 * 86_400)), for: "1")
        let summary = expectSynced(await a.sync(options: .fullResync))

        XCTAssertEqual(summary.requests.first?.endpoint, .pull)
        XCTAssertEqual(summary.pulls.first?.fullPull, true)
        XCTAssertEqual(try a.habitNames(), ["Kept"])
        XCTAssertNil(server.habits[doomed.id.uuidString], "not resurrected on the server")
        XCTAssertEqual(a.log.lines.map(\.item.ref.id), [doomed.id.uuidString], "archived: it was pending (needsResend)")
        XCTAssertNil(a.cursors.cursor(for: "1"), "Full resync clears the cursor at the end")
    }

    /// Settings → Full resync on a live cursor: pull on it, push every row, then clear the cursor
    /// so the next sync full-pulls.
    func testFullResyncPullsOnTheCurrentCursorPushesEverythingThenClearsTheCursor() async throws {
        let a = device()
        a.habit("Read", records: [day(0), day(1)])
        try a.save()
        expectSynced(await a.sync())
        server.clock += 120   // move the cursor past the overlap, or its echo settles the rows first
        expectSynced(await a.sync())
        let cursor = try XCTUnwrap(a.cursors.cursor(for: "1"))

        let summary = expectSynced(await a.sync(options: .fullResync))
        XCTAssertEqual(summary.requests.map(\.endpoint), [.pull, .push, .pull])
        XCTAssertEqual(server.requests.first { $0.endpoint == .pull && $0.token == "token-A" && $0.since == cursor }?.since, cursor)
        XCTAssertEqual(summary.pushedRows, SyncRowCounts(groups: 0, habits: 1, entries: 2))
        XCTAssertNil(a.cursors.cursor(for: "1"))
        XCTAssertEqual(try a.pendingCount(), 0)

        let next = expectSynced(await a.sync())
        XCTAssertEqual(next.pulls.first?.fullPull, true)
    }

    /// Review delivery-2: Full resync marks every record, including a check-in of a held habit
    /// and an orphan no habit owns. The planner never sends either, so nothing acknowledges them
    /// and their flag stays — and while it counted as a forced resend, every later sync pulled
    /// before the push as well as after it. Once the Full resync's own full pull is done, a sync
    /// with nothing to send makes one pull.
    func testAFullResyncLeavesNoExtraPullBehindForRowsThePlannerNeverSends() async throws {
        let a = device()
        a.habit("Read")
        try a.save()
        expectSynced(await a.sync())
        // Another account's ids kept by a restore, held `not_owned`, with a check-in the user made
        // on it since (not held itself); and an orphan check-in from an old bug.
        let held = a.habit("Another account's", records: [day(0)])
        held.hold(.notOwned)
        let orphan = HabitRecord(date: day(9))
        a.context.insert(orphan)
        try a.save()
        server.clock += 120   // past the overlap: no echo settles the rows

        expectSynced(await a.sync(options: .fullResync))
        XCTAssertTrue(held.records[0].needsResend, "marked, and never sent while its habit is held")
        XCTAssertTrue(orphan.needsResend)
        XCTAssertFalse(try SyncPushPlanner.hasForcedResend(in: a.context), "nothing the planner could send")

        server.clock += 120
        let afterResync = expectSynced(await a.sync())
        XCTAssertEqual(afterResync.pulls.first?.fullPull, true, "the full pull Full resync asked for")
        server.clock += 120
        let quiet = expectSynced(await a.sync())
        XCTAssertEqual(quiet.requests.map(\.endpoint), [.pull], "one pull, not one before a push with nothing to send")
        XCTAssertEqual(held.activeHold, .notOwned)
        XCTAssertTrue(held.records[0].needsResend, "still owed once the hold is lifted")
    }

    // MARK: - Queued deletions and day matching (M2 slice review)

    /// Untap a delivered check-in and tap the day again, offline, then a sync that pulls before
    /// it pushes — every device's first 1.3.1 sync has no cursor, and Full resync pulls first
    /// too. The pull still brings the untapped X back (its deletion is only queued); the day
    /// match renamed the re-tap to X, the push carried `deletedEntryIds: [X]` with an upsert of
    /// X, the server answered `tombstoned`, and the check-in was dropped on every device. The
    /// control (a live cursor, push first) always kept it.
    func testAnUntapAndReTapBeforeAPullFirstSyncKeepsTheCheckIn() async throws {
        for fullResync in [false, true] {
            let a = device(owner: fullResync ? "2" : "1")
            let habit = a.habit("Read", records: [day(0)])
            try a.save()
            expectSynced(await a.sync())
            let untapped = try XCTUnwrap(habit.records.first)
            let untappedID = untapped.id.uuidString

            a.queue.trackEntry(untappedID)
            habit.records.removeAll { $0.id == untapped.id }
            a.context.delete(untapped)
            habit.records.append(HabitRecord(date: day(0), note: "tapped again"))
            try a.save()
            if !fullResync { a.cursors.setCursor(nil, for: "1") }

            let summary = expectSynced(await a.sync(options: fullResync ? .fullResync : []))

            XCTAssertEqual(summary.requests.first?.endpoint, .pull, "the case under test pulls first")
            XCTAssertEqual(summary.dropped, 0, "fullResync=\(fullResync)")
            XCTAssertTrue(a.log.lines.isEmpty, "fullResync=\(fullResync)")
            let local = try XCTUnwrap(a.habits().first).records
            XCTAssertEqual(local.map(\.note), ["tapped again"], "fullResync=\(fullResync)")
            XCTAssertNotEqual(local.first?.id.uuidString, untappedID)
            XCTAssertEqual(try a.pendingCount(), 0)
            let onServer = server.entries.values.filter { $0.wire.habitId == habit.id.uuidString }
            XCTAssertEqual(onServer.map(\.wire.note), ["tapped again"], "fullResync=\(fullResync)")
            XCTAssertTrue(a.queue.pending().isEmpty)
            server.entries.removeAll()
            server.habits.removeAll()
        }
    }

    /// The same untap and re-tap made on B reaches A in one incremental pull as
    /// `deletedEntryIds: [X]` plus the new entry Y for that habit-day. A ends with Y (it used to
    /// end with no record for the day, the server holding Y, and nothing pending to repair it).
    func testAnotherDevicesUntapAndReTapOfADayReachesThisDeviceAsTheNewCheckIn() async throws {
        let a = device(), b = device(token: "token-A2")
        a.habit("Read", records: [day(0)])
        try a.save()
        expectSynced(await a.sync())
        expectSynced(await b.sync())

        let bHabit = try XCTUnwrap(b.habits().first)
        let untapped = try XCTUnwrap(bHabit.records.first)
        b.queue.trackEntry(untapped.id.uuidString)
        bHabit.records.removeAll { $0.id == untapped.id }
        b.context.delete(untapped)
        bHabit.records.append(HabitRecord(date: day(0), note: "tapped again"))
        try b.save()
        expectSynced(await b.sync())

        let pulled = expectSynced(await a.sync())
        XCTAssertEqual(pulled.pulls.map(\.fullPull), [false])
        let local = try XCTUnwrap(a.habits().first).records
        XCTAssertEqual(local.map(\.note), ["tapped again"])
        XCTAssertEqual(local.map(\.id), try XCTUnwrap(b.habits().first).records.map(\.id))
        XCTAssertEqual(try a.pendingCount(), 0)
    }

    /// The phone and the iPad check the same day before either has pulled the other's check-in.
    /// The server holds one row per habit and day and keeps the iPad's id Y, so the phone's X is
    /// answered `applied` with `aliases: {X: Y}`, and the phone takes Y in the save that
    /// acknowledges it (review data-safety-4). Its post-push pull is lost here — the only other
    /// thing that would have renamed it — and the uncheck that follows deletes Y and queues Y: the
    /// push deletes the day's row, and no pull checks the day again, here or on the iPad. Kept as
    /// X, the uncheck's push deleted nothing and the next pull brought the day back as Y.
    func testAnUncheckAfterAnAliasedPushDeletesTheDaysRowOnTheServer() async throws {
        let (phone, iPad, walk, y) = try await sameDayOnTwoDevices()
        let checkIn = try XCTUnwrap(walk.records.first)
        server.scriptPull(at: 1, .noAnswer)
        let lost = await phone.sync()
        guard case .stopped(.backOff, let pushed) = lost else { return XCTFail("the lost pull stops the run: \(lost)") }
        XCTAssertEqual(pushed.acknowledged, 1)
        XCTAssertEqual(checkIn.id, y, "the check-in took the id the server keeps, with its acknowledgement")
        XCTAssertFalse(checkIn.isPending)

        let untap = HabitCheckIn.tap(walk, on: day(0), in: phone.context)
        try phone.save()
        let untapped = try XCTUnwrap(untap.deletedRecordID)
        phone.queue.trackEntry(untapped)
        XCTAssertEqual(untapped, y.uuidString)
        expectSynced(await phone.sync())

        XCTAssertTrue(server.entries.values.filter { $0.wire.habitId == walk.id.uuidString }.isEmpty,
                      "the uncheck deleted the day's row on the server")
        XCTAssertTrue(phone.queue.pending().isEmpty)
        expectSynced(await phone.sync())
        XCTAssertEqual(try phone.context.fetchCount(FetchDescriptor<HabitRecord>()), 0, "no pull checked the day again")
        expectSynced(await iPad.sync())
        XCTAssertEqual(try iPad.context.fetchCount(FetchDescriptor<HabitRecord>()), 0, "the iPad's check-in went with it")
    }

    /// The same uncheck, made while the push carrying X is in flight: no record is left to rename,
    /// and the queued deletion names X, which the server does not hold. The acknowledgement queues
    /// Y beside it (review data-safety-4), so the run's own pull does not bring the day back and
    /// the next push deletes it on the server. Without that, that very pull checked the day again.
    func testAnUncheckWhileTheAliasedPushIsInFlightStillDeletesTheDaysRowOnTheServer() async throws {
        let (phone, iPad, walk, y) = try await sameDayOnTwoDevices()
        let x = try XCTUnwrap(walk.records.first).id.uuidString
        let checkedDay = day(0)
        server.onRequest = { [unowned phone] request in
            guard request.endpoint == .push else { return }
            let untap = HabitCheckIn.tap(walk, on: checkedDay, in: phone.context)
            try? phone.save()
            if let id = untap.deletedRecordID { phone.queue.trackEntry(id) }
        }
        expectSynced(await phone.sync())
        server.onRequest = nil

        XCTAssertEqual(try phone.context.fetchCount(FetchDescriptor<HabitRecord>()), 0, "the run's own pull left the day unchecked")
        XCTAssertEqual(Set(phone.queue.pending().entries), [x, y.uuidString])
        expectSynced(await phone.sync())
        XCTAssertTrue(server.entries.values.filter { $0.wire.habitId == walk.id.uuidString }.isEmpty)
        XCTAssertTrue(phone.queue.pending().isEmpty)
        XCTAssertEqual(try phone.context.fetchCount(FetchDescriptor<HabitRecord>()), 0)
        expectSynced(await iPad.sync())
        XCTAssertEqual(try iPad.context.fetchCount(FetchDescriptor<HabitRecord>()), 0)
    }

    /// Both devices hold "Walk"; the iPad checks day 0 and syncs (the server's row is its Y); the
    /// phone checks the same day and has not synced since. Returns the phone's habit and Y.
    private func sameDayOnTwoDevices() async throws -> (phone: TestDevice, iPad: TestDevice, walk: Habit, y: UUID) {
        let phone = device(), iPad = device(token: "token-A2")
        let walk = phone.habit("Walk")
        try phone.save()
        expectSynced(await phone.sync())
        expectSynced(await iPad.sync())

        let iPadWalk = try XCTUnwrap(iPad.habits().first)
        HabitCheckIn.tap(iPadWalk, on: day(0), in: iPad.context)
        try iPad.save()
        expectSynced(await iPad.sync())
        let y = try XCTUnwrap(iPadWalk.records.first).id

        HabitCheckIn.tap(walk, on: day(0), in: phone.context)
        try phone.save()
        XCTAssertNotEqual(try XCTUnwrap(walk.records.first).id, y, "precondition: the day under two ids")
        return (phone, iPad, walk, y)
    }

    /// A cursor this device still counts live, but old enough that the server may not (a clock
    /// running slow): the run pulls on it BEFORE pushing, so a `cursor_expired` answer comes while
    /// nothing has gone up yet — full pull first, then push, as the spec orders it. Pushed first,
    /// the pending edits went up on the expired cursor.
    func testACursorNearingExpiryIsPulledOnBeforeThePush() async throws {
        let a = device()
        a.habit("Read")
        try a.save()
        expectSynced(await a.sync())

        let old = SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-340 * 86_400))
        a.cursors.setCursor(old, for: "1")
        try XCTUnwrap(a.habits().first).touch()
        try a.save()
        let live = expectSynced(await a.sync())
        XCTAssertEqual(live.requests.map(\.endpoint), [.pull, .push, .pull])
        XCTAssertEqual(live.pulls.first?.fullPull, false, "an incremental pull on the old cursor")

        a.cursors.setCursor(old, for: "1")
        server.expireNextCursor = true
        try XCTUnwrap(a.habits().first).touch()
        try a.save()
        let expired = expectSynced(await a.sync())
        XCTAssertEqual(expired.requests.map(\.endpoint), [.pull, .pull, .push, .pull])
        XCTAssertEqual(expired.pulls.map(\.status), [409, 200, 200])
        XCTAssertEqual(expired.pulls.map(\.fullPull), [false, true, false])
    }

    // MARK: - Account isolation and the run binding

    /// No binding, no request: signed out, or signed in but not as the owner (the gate).
    func testASignedOutOrUnsettledOwnerMakesNoRequest() async throws {
        let a = device()
        a.habit("Read")
        try a.save()
        a.gate.state = .signedOut
        let signedOut = await a.sync()
        XCTAssertEqual(signedOut, .blocked(.signedOut))
        a.gate.state = .ownerUnsettled
        let unsettled = await a.sync()
        XCTAssertEqual(unsettled, .blocked(.ownerUnsettled))
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// Sign out and into account B while chunk 1 is in flight: chunk 2 is never sent, nothing is
    /// acknowledged, the deletion queue and the cursor are unchanged, and no request carries B's
    /// token (review 2).
    func testASwitchToAnotherAccountBetweenChunksSendsNothingMoreAndAcknowledgesNothing() async throws {
        var bounds = SyncPushBounds.standard
        bounds.habits = 1
        let a = device(bounds: bounds)
        a.habit("One")
        try a.save()
        expectSynced(await a.sync())
        let cursor = a.cursors.cursor(for: "1")
        a.habit("Two"); a.habit("Three")
        a.queue.trackEntry(UUID().uuidString)
        try a.save()
        let queued = a.queue.pending()
        let requestsBefore = server.requests.count

        server.onRequest = { [unowned a] request in
            guard request.endpoint == .push else { return }
            a.gate.state = .ready(SyncRunBinding(ownerID: "2", token: "token-B", generation: 1))
        }
        let outcome = await a.sync()
        server.onRequest = nil

        guard case .stopped(.bindingChanged, _) = outcome else { return XCTFail("\(outcome)") }
        let sent = server.requests.dropFirst(requestsBefore)
        XCTAssertEqual(sent.count, 1, "only the chunk already in flight")
        XCTAssertFalse(server.requests.contains { $0.token == "token-B" })
        XCTAssertEqual(try a.pendingCount(), 2, "nothing acknowledged")
        XCTAssertEqual(a.queue.pending(), queued)
        XCTAssertEqual(a.cursors.cursor(for: "1"), cursor)
        XCTAssertNil(a.cursors.cursor(for: "2"))
    }

    /// Re-login to the same account (a new token and generation, same owner) resumes: nothing is
    /// pushed, and the cursor is the one it had.
    func testReloginToTheSameAccountPushesNothingAndKeepsTheCursor() async throws {
        let a = device()
        a.habit("Read", records: [day(0)])
        try a.save()
        expectSynced(await a.sync())
        let cursor = try XCTUnwrap(a.cursors.cursor(for: "1"))

        a.gate.state = .signedOut
        let signedOut = await a.sync()
        XCTAssertEqual(signedOut, .blocked(.signedOut))
        a.gate.state = .ready(SyncRunBinding(ownerID: "1", token: "token-A2", generation: 2))
        let summary = expectSynced(await a.sync())

        XCTAssertTrue(summary.pushes.isEmpty)
        XCTAssertEqual(summary.pulls.map(\.fullPull), [false])
        XCTAssertEqual(server.requests.last { $0.endpoint == .pull }?.since, cursor)
        XCTAssertEqual(server.requests.last?.token, "token-A2")
    }

    /// 401 stops the run as `needsReauth` and resets nothing.
    func testUnauthorizedStopsAsNeedsReauthAndResetsNothing() async throws {
        let a = device()
        let habit = a.habit("Read")
        try a.save()
        expectSynced(await a.sync())
        let cursor = a.cursors.cursor(for: "1")
        habit.touch()
        try a.save()
        server.validTokens = []

        let outcome = await a.sync()
        guard case .stopped(.needsReauth, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(a.cursors.cursor(for: "1"), cursor)
        XCTAssertNotNil(habit.syncedAt)
        XCTAssertTrue(habit.isPending)
    }

    /// 429 and 503 sync_paused back off by what the server said and hold nothing.
    func testRateLimitAndPauseBackOffAsTheServerAsked() async throws {
        let a = device()
        a.habit("Read")
        try a.save()
        server.scriptPull(at: 1, SyncTransportResponse(status: 429, body: Data(#"{"error":"rate_limited","code":"rate_limited"}"#.utf8), retryAfter: "120"))
        let limited = await a.sync()
        guard case .stopped(.backOff(.serverAsked(seconds: 120, paused: false), _), _) = limited else { return XCTFail("\(limited)") }

        server.scriptPull(at: 1, SyncTransportResponse(status: 503, body: Data(#"{"error":"sync_paused","code":"sync_paused","retryAfterSeconds":600}"#.utf8)))
        let paused = await a.sync()
        guard case .stopped(.backOff(.serverAsked(seconds: 600, paused: true), _), _) = paused else { return XCTFail("\(paused)") }
        XCTAssertEqual(try a.pendingCount(), 1)
    }

    // MARK: - Push answered tombstoned, and restored rows

    /// A push answered `tombstoned` drops the row: archived first (reason `tombstoned`), then
    /// deleted locally. A restored row answered `tombstoned` is held instead, and a restored row
    /// answered `not_owned` is held and survives a full pull.
    func testTombstonedAnswersDropAfterArchivingAndRestoredRowsAreHeld() async throws {
        let a = device()
        let edited = a.habit("Edited offline")
        let restored = a.habit("Restored")
        let foreign = a.habit("Another account's")
        restored.restoredAt = Date()
        foreign.restoredAt = Date()
        try a.save()
        server.markTombstoned(.habit, edited.id.uuidString)
        server.markTombstoned(.habit, restored.id.uuidString)
        server.forcedReasons[foreign.id.uuidString] = "not_owned"
        // Settle the cursor first without pulling the tombstones back in: the push must meet them.
        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(30)), for: "1")

        let summary = expectSynced(await a.sync())

        XCTAssertEqual(try a.habitNames(), ["Another account's", "Restored"])
        XCTAssertEqual(a.log.lines.map(\.item.ref.id), [edited.id.uuidString])
        XCTAssertEqual(a.log.lines.first?.item.reason, .tombstoned)
        XCTAssertEqual(restored.activeHold, .tombstoned)
        XCTAssertEqual(foreign.activeHold, .notOwned)
        XCTAssertEqual(summary.dropped, 1)

        a.cursors.setCursor(nil, for: "1")
        expectSynced(await a.sync())
        XCTAssertEqual(try a.habitNames(), ["Another account's", "Restored"], "held rows survive a full pull")
    }

    /// Review delivery-1: habits deleted on another device, restored here with their ids, and
    /// checked in on Today before the next sync. The new check-in has no `restoredAt` of its
    /// own; the push answers the habit `tombstoned` and every check-in `tombstoned_habit`. The
    /// check-in stays — local, unarchived, held back with its habit — and "Restore as New Copies"
    /// takes it along, as the pull path and `reidentify` already treat it. With a live cursor the
    /// push meets the tombstone; with none, the full pull keeps the never-delivered habit by
    /// absence without holding it, so the push decides there too.
    func testACheckInMadeOnARestoredHabitTheServerTombstonedStaysAndMovesWithTheCopy() async throws {
        for liveCursor in [true, false] {
            server = FakeSyncServer()
            server.validTokens = ["token-A"]
            let a = device()
            let habit = a.habit("Restored", records: [day(0)])
            let restoredAt = Date()
            habit.restoredAt = restoredAt
            habit.records[0].restoredAt = restoredAt
            let tapped = HabitRecord(date: day(5))
            habit.records.append(tapped)
            try a.save()
            let oldID = habit.id.uuidString
            server.markTombstoned(.habit, oldID)
            if liveCursor {
                // Past the tombstone, so the pull does not carry it: the push must meet it.
                a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(30)), for: "1")
            }

            let summary = expectSynced(await a.sync())
            XCTAssertEqual(summary.pushedRows.entries, 2, "cursor \(liveCursor): the push met the tombstone")
            XCTAssertEqual(habit.activeHold, .tombstoned, "cursor \(liveCursor)")
            XCTAssertEqual(try a.context.fetch(FetchDescriptor<HabitRecord>()).count, 2, "cursor \(liveCursor)")
            XCTAssertNil(tapped.syncHoldReason, "cursor \(liveCursor): kept by its habit's hold, not held itself")
            XCTAssertTrue(a.log.lines.isEmpty, "cursor \(liveCursor): nothing archived, nothing dropped")
            XCTAssertEqual(summary.dropped, 0)
            XCTAssertTrue(try SyncPushPlanner.plan(in: a.context, deletions: a.queue.pending()).isEmpty,
                          "cursor \(liveCursor): held back with its habit")

            let copies = try SyncCopies.reidentify(try SyncCopies.heldRows(in: a.context), in: a.context)
            XCTAssertEqual(copies.rows, SyncRowCounts(groups: 0, habits: 1, entries: 2), "cursor \(liveCursor)")
            XCTAssertNotEqual(habit.id.uuidString, oldID)
            expectSynced(await a.sync())
            XCTAssertEqual(Set(server.entries.values.map(\.wire.habitId)), [habit.id.uuidString], "cursor \(liveCursor)")
            XCTAssertEqual(server.entries.count, 2, "cursor \(liveCursor): today's check-in reached the account with the copy")
            XCTAssertTrue(tapped.hasBeenDelivered && !tapped.isPending, "cursor \(liveCursor)")
        }
    }

    /// A failed recovery-log append on a pull deletes nothing and writes no cursor; the next sync
    /// retries and succeeds. The row the tombstone takes is held (so no push meets it first).
    func testAFailedRecoveryLogAppendOnAPullDeletesNothingAndWritesNoCursor() async throws {
        let a = device(), b = device(token: "token-A2")
        a.habit("Read", records: [day(0)])
        try a.save()
        expectSynced(await a.sync())
        expectSynced(await b.sync())
        let bHabit = try XCTUnwrap(b.habits().first)
        b.queue.trackHabit(bHabit.id.uuidString)
        b.context.delete(bHabit)
        try b.save()
        expectSynced(await b.sync())

        let aRecord = try XCTUnwrap(a.habits().first?.records.first)
        aRecord.hold(.rowError)
        try a.save()
        let cursor = a.cursors.cursor(for: "1")
        a.log.failure = CocoaError(.fileWriteOutOfSpace)

        let failed = await a.sync()
        guard case .stopped(.recoveryLogFailed, let summary) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(summary.pushes.isEmpty, "a held row is not pushed: the pull met the tombstone")
        XCTAssertEqual(try a.habits().count, 1, "nothing deleted")
        XCTAssertEqual(a.cursors.cursor(for: "1"), cursor, "no cursor written")

        a.log.failure = nil
        expectSynced(await a.sync())
        XCTAssertTrue(try a.habits().isEmpty)
        XCTAssertEqual(a.log.lines.map(\.item.ref.id), [aRecord.id.uuidString], "held rows are archived too")
        XCTAssertEqual(a.log.lines.first?.item.reason, .deletedElsewhere)
    }

    /// A push answered `tombstoned` whose archive fails deletes nothing, still saves the
    /// acknowledgements the server gave, and writes no cursor.
    func testAFailedRecoveryLogAppendOnAPushDropKeepsTheRowAndTheAcknowledgements() async throws {
        let a = device()
        let doomed = a.habit("Deleted elsewhere")
        let fine = a.habit("Fine")
        try a.save()
        server.markTombstoned(.habit, doomed.id.uuidString)
        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(30)), for: "1")
        let cursor = a.cursors.cursor(for: "1")
        a.log.failure = CocoaError(.fileWriteOutOfSpace)

        let failed = await a.sync()
        guard case .stopped(.recoveryLogFailed, _) = failed else { return XCTFail("\(failed)") }
        XCTAssertEqual(try a.habitNames(), ["Deleted elsewhere", "Fine"])
        XCTAssertTrue(doomed.isPending)
        XCTAssertFalse(fine.isPending, "the acknowledgement is true, so it is kept")
        XCTAssertEqual(a.cursors.cursor(for: "1"), cursor)
    }

    // MARK: - The file recovery log under the engine (phase B)

    /// A directory the test owns, removed (after its permissions are put back) at the end.
    private func scratchLogDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncEngineTests-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func setWritable(_ dir: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: dir.path)
    }

    /// The app's sink is the FILE (`SyncRecoveryLog`), and "on disk before the delete" is only as
    /// true as the file's failure path: with the log's directory unwritable (a full disk, or M3's
    /// locked background sync), a pull whose tombstone takes a held row deletes nothing and writes
    /// no cursor, and nothing reaches the directory. Made writable again, the next sync archives
    /// and deletes, and the export holds the row.
    func testAnUnwritableRecoveryLogFileOnAPullDeletesNothingAndWritesNoCursor() async throws {
        let dir = try scratchLogDirectory()
        let file = SyncRecoveryLog(directory: dir)
        let a = device(recoveryLog: file), b = device(token: "token-A2")
        a.habit("Read", records: [day(0)])
        try a.save()
        expectSynced(await a.sync())
        expectSynced(await b.sync())
        let bHabit = try XCTUnwrap(b.habits().first)
        b.queue.trackHabit(bHabit.id.uuidString)
        b.context.delete(bHabit)
        try b.save()
        expectSynced(await b.sync())

        let aRecord = try XCTUnwrap(a.habits().first?.records.first)
        aRecord.note = "edited, then refused"
        aRecord.touch()
        aRecord.hold(.rowError)      // held, so no push meets the tombstone first: the pull does
        try a.save()
        let cursor = a.cursors.cursor(for: "1")
        try setWritable(dir, false)

        let failed = await a.sync()
        guard case .stopped(.recoveryLogFailed, _) = failed else { return XCTFail("\(failed)") }
        XCTAssertEqual(try a.habits().count, 1, "nothing deleted")
        XCTAssertEqual(try a.habits().first?.records.count, 1)
        XCTAssertEqual(a.cursors.cursor(for: "1"), cursor, "no cursor written")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "nothing on disk")

        try setWritable(dir, true)
        expectSynced(await a.sync())
        XCTAssertTrue(try a.habits().isEmpty)
        let export = try SyncRecoveryLog.decodeExport(try file.exportData(accountID: "1"))
        XCTAssertEqual(export.items.count, 1)
        XCTAssertEqual(export.items.first?.record?.note, "edited, then refused")
        XCTAssertEqual(export.items.first?.habitName, "Read")
        XCTAssertEqual(export.items.first?.reason, .deletedElsewhere)
        XCTAssertEqual(export.accountId, "1")
    }

    /// The push path: a row answered `tombstoned` whose archive cannot be written stays, pending
    /// (answered again next sync), and the chunk's true acknowledgements are kept.
    func testAnUnwritableRecoveryLogFileOnAPushDropKeepsTheRowPending() async throws {
        let dir = try scratchLogDirectory()
        let file = SyncRecoveryLog(directory: dir)
        let a = device(recoveryLog: file)
        let doomed = a.habit("Deleted elsewhere")
        let fine = a.habit("Fine")
        try a.save()
        server.markTombstoned(.habit, doomed.id.uuidString)
        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(30)), for: "1")
        try setWritable(dir, false)

        let failed = await a.sync()
        guard case .stopped(.recoveryLogFailed, _) = failed else { return XCTFail("\(failed)") }
        XCTAssertEqual(try a.habitNames(), ["Deleted elsewhere", "Fine"])
        XCTAssertTrue(doomed.isPending)
        XCTAssertFalse(fine.isPending)

        try setWritable(dir, true)
        expectSynced(await a.sync())
        XCTAssertEqual(try a.habitNames(), ["Fine"])
        XCTAssertEqual(try file.read(accountID: "1").lines.map(\.habit?.name), ["Deleted elsewhere"])
    }

    // MARK: - The per-owner backoff (phase B)

    private static let invalidPayload = SyncTransportResponse(status: 400, body: Data(
        #"{"error":"invalid_payload","code":"invalid_payload","message":"habits must be an array"}"#.utf8))

    /// `400 invalid_payload` is a client bug: the run stops, nothing is held, the rows stay
    /// pending, and the owner's backoff starts at about a minute. An automatic run inside the
    /// window sends nothing; a manual one (Sync Now) goes at once, and its success resets the
    /// window, so the next automatic run goes too.
    func testInvalidPayloadBacksOffAutomaticRunsWhileManualRunsGoAndSuccessResets() async throws {
        let a = device(backoff: true)
        let habit = a.habit("Read")
        try a.save()
        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")
        server.scriptPush(at: 1, Self.invalidPayload)

        let failed = await a.sync(trigger: .automatic)
        guard case .stopped(.backOff(.clientBug, _), _) = failed else { return XCTFail("\(failed)") }
        XCTAssertNil(habit.syncHoldReason, "the rows are not what is wrong")
        XCTAssertTrue(habit.isPending)
        let state = try XCTUnwrap(a.backoffStore.state(for: "1"))
        XCTAssertEqual(state.reason, .clientBug)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertEqual(state.delay, 60, accuracy: 12.001)

        let requests = server.requests.count
        let waiting = await a.sync(trigger: .automatic)
        XCTAssertEqual(waiting, .blocked(.backingOff(state)))
        XCTAssertEqual(server.requests.count, requests, "an automatic run inside the window sends nothing")

        expectSynced(await a.sync(trigger: .manual))
        XCTAssertFalse(habit.isPending)
        XCTAssertNil(a.backoffStore.state(for: "1"), "success resets")
        expectSynced(await a.sync(trigger: .automatic))
    }

    /// The outcome is written under the owner the run was bound to, and read for the owner the
    /// next run is bound to: account A's window never holds back account B's first sync.
    func testTheBackoffBelongsToTheRunsOwner() async throws {
        let a = device(backoff: true)
        a.habit("Read")
        try a.save()
        server.scriptPull(at: 1, SyncTransportResponse(status: 503, body: Data(
            #"{"error":"sync_paused","code":"sync_paused","retryAfterSeconds":900}"#.utf8)))
        let paused = await a.sync(trigger: .automatic)
        guard case .stopped(.backOff(.serverAsked(seconds: 900, paused: true), _), _) = paused else { return XCTFail("\(paused)") }
        XCTAssertEqual(a.backoffStore.state(for: "1")?.reason, .paused)
        XCTAssertEqual(a.backoffStore.state(for: "1")?.delay, 900)

        a.gate.state = .ready(SyncRunBinding(ownerID: "2", token: "token-B", generation: 1))
        let asB = await a.sync(trigger: .automatic)
        guard case .synced = asB else { return XCTFail("B has no window of its own: \(asB)") }
        XCTAssertNil(a.backoffStore.state(for: "2"))
        XCTAssertEqual(a.backoffStore.state(for: "1")?.reason, .paused, "A's window is A's")
    }

    /// 1.4.0's `.background` trigger through the engine (RELEASE-1.4.0.md D5): a run that got no
    /// answer at all — offline, or iOS cancelling a refresh whose time ran out, which APIClient
    /// reports the same way — writes no backoff, so the foreground sync the user starts next goes
    /// at once and delivers the row. Recorded, its minute's window would turn that sync away.
    func testABackgroundRunWithNoAnswerWritesNoBackoffAndTheNextAutomaticRunGoes() async throws {
        let a = device(backoff: true)
        let habit = a.habit("Read")
        try a.save()
        a.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")
        server.scriptPush(at: 1, .noAnswer)

        let cut = await a.sync(trigger: .background)
        guard case .stopped(.backOff(.transient, let answer), _) = cut, answer.status == nil else { return XCTFail("\(cut)") }
        XCTAssertNil(a.backoffStore.state(for: "1"), "no answer on a background run leaves no window")
        XCTAssertTrue(habit.isPending)

        expectSynced(await a.sync(trigger: .automatic))
        XCTAssertFalse(habit.isPending)
    }

    /// A background run waits out an open window like a launch, and a real answer — here the
    /// pause switch — is recorded for it as for any run.
    func testABackgroundRunRecordsTheServersAnswerAndWaitsOutTheWindow() async throws {
        let a = device(backoff: true)
        a.habit("Read")
        try a.save()
        server.scriptPull(at: 1, SyncTransportResponse(status: 503, body: Data(
            #"{"error":"sync_paused","code":"sync_paused","retryAfterSeconds":900}"#.utf8)))

        let paused = await a.sync(trigger: .background)
        guard case .stopped(.backOff(.serverAsked(seconds: 900, paused: true), _), _) = paused else { return XCTFail("\(paused)") }
        let state = try XCTUnwrap(a.backoffStore.state(for: "1"))
        XCTAssertEqual(state.reason, .paused)
        XCTAssertEqual(state.delay, 900)

        let requests = server.requests.count
        let waiting = await a.sync(trigger: .background)
        XCTAssertEqual(waiting, .blocked(.backingOff(state)))
        XCTAssertEqual(server.requests.count, requests, "a background run inside the window sends nothing")
    }

    /// Stops that are not the server asking for less traffic leave the window alone — a sign-out
    /// mid-run above all, which says nothing about the server.
    func testASignOutMidRunWritesNoBackoff() async throws {
        let a = device(backoff: true)
        a.habit("Read")
        try a.save()
        server.onRequest = { [a] _ in a.gate.state = .signedOut }
        let stopped = await a.sync(trigger: .automatic)
        guard case .stopped(.bindingChanged, _) = stopped else { return XCTFail("\(stopped)") }
        XCTAssertNil(a.backoffStore.state(for: "1"))
    }

    // MARK: - The first full pull proves the account (owner decision, 2026-09-28)

    /// Stamps an hour old — what a 1.3.0 store holds for rows its last snapshot carried (the
    /// migrated-rows rule marks a row only if its stamp is 5 min or more before that sync).
    /// `seconds` for a store that slept longer.
    @discardableResult
    private func aged<Row: SyncDeliverable>(_ row: Row, by seconds: TimeInterval = 3_600) -> Row {
        let t = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-seconds))
        if let habit = row as? Habit {
            habit.createdAt = t
            habit.updatedAt = t
            habit.records.forEach { $0.updatedAt = t }
        } else if let group = row as? HabitGroup {
            group.createdAt = t
            group.updatedAt = t
        }
        return row
    }

    /// What 1.3.0 left under its own cursor key (`SyncDefaultsCursorStore.legacyKey`).
    private enum Cursor130 {
        /// The cursor of this device's last sync before the update — the server's time of that
        /// pull less the overlap, which is what 1.3.0 wrote after every sync.
        case lastSync
        /// None: 1.3.0 never finished a sync on this store, or it came from 1.2.2 or earlier.
        case none
        case at(Date)
    }

    /// What the first 1.3.1 launch finds on a dormant 1.3.0 device that synced as the rows say:
    /// no delivery state (1.3.0 had none), no cursor under 1.3.1's per-owner key, 1.3.0's own
    /// cursor (`cursor`) and last-sync time — whose session may since have expired, which 1.3.0 did
    /// not record. Then the real migration: the rows are stamped delivered, their marks await the
    /// proof, and 1.3.0's cursor is pinned for the pass that verifies them.
    private func arriveFrom130(_ d: TestDevice, owner: String, cursor: Cursor130 = .lastSync,
                               lastSync: Date = Date()) throws {
        let legacy: String?
        switch cursor {
        case .lastSync: legacy = d.cursors.cursor(for: owner)
        case .none: legacy = nil
        case .at(let date): legacy = SyncTimestamp.millisecondString(from: date)
        }
        for habit in try d.habits() {
            habit.syncedAt = nil
            habit.records.forEach { $0.syncedAt = nil }
        }
        try d.context.fetch(FetchDescriptor<HabitGroup>()).forEach { $0.syncedAt = nil }
        try d.save()
        d.cursors.setCursor(nil, for: owner)
        if let legacy {
            d.defaults.set(legacy, forKey: SyncDefaultsCursorStore.legacyKey)
        } else {
            d.defaults.removeObject(forKey: SyncDefaultsCursorStore.legacyKey)
        }
        d.defaults.set(SyncTimestamp.string(from: lastSync), forKey: SyncDeliveryMigration.lastSyncTimeKey)
        guard case .stamped(let counts) = SyncDeliveryMigration.runOnceIfNeeded(in: d.context, defaults: d.defaults),
              counts.total > 0 else { return XCTFail("the migration stamped nothing") }
        XCTAssertTrue(d.marks.isAwaited)
        XCTAssertTrue(d.marks.isUnverified)
        XCTAssertEqual(d.marks.deletionsSince, legacy, "1.3.0's cursor, pinned")
    }

    /// The first request's `deletionsSince`, as the fake server received it.
    private func askedDeletionsSince(_ server: FakeSyncServer, from index: Int = 0) -> String? {
        server.requests.dropFirst(index).first { $0.endpoint == .pull }?.deletionsSince
    }

    /// Deletes `name` on `other` and syncs it: a deletion made while the dormant device slept.
    private func deleteElsewhere(_ name: String, on other: TestDevice) async throws {
        let habit = try XCTUnwrap(other.habits().first { $0.name == name })
        other.queue.trackHabit(habit.id.uuidString)
        habit.records.forEach { other.queue.trackEntry($0.id.uuidString) }
        other.context.delete(habit)
        try other.save()
        expectSynced(await other.sync())
    }

    /// The same account again (the session expired while the device was on 1.3.0). The proof is
    /// a full pull before anything is pushed — whatever cursor the owner has — and the snapshot
    /// holds a habit this device delivered, so the marks stand: nothing the account holds goes up
    /// again. The habit deleted on another device after this device's last 1.3.0 sync is in the
    /// account's deletions since 1.3.0's cursor, which the pull asked for (review data-safety-1),
    /// so it goes as an incremental pull would have removed it: quietly — nothing pushed, nothing
    /// in Recovered Edits for a row nobody edited here. The next sync is quiet, and signing out and
    /// back in resumes with no proof to make.
    func testAMigratedStoreSignedIntoItsOwnAccountIsProvenAndKeepsItsMarks() async throws {
        let d = device(), other = device(token: "token-A2")
        let read = aged(d.habit("Read", records: [day(0), day(1)]))
        aged(d.habit("Run", records: [day(0)]))
        aged(d.habit("Stretch"))
        try d.save()
        expectSynced(await d.sync())            // 1.3.0's snapshots put the rows on the account
        expectSynced(await other.sync())
        try await deleteElsewhere("Run", on: other)
        try arriveFrom130(d, owner: "1")
        let pinned = try XCTUnwrap(d.marks.deletionsSince)
        d.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")
        let before = server.requests.count

        let summary = expectSynced(await d.sync())

        XCTAssertEqual(summary.requests.first?.endpoint, .pull)
        XCTAssertEqual(summary.pulls.first?.fullPull, true, "the proof is a full pull, cursor or not")
        XCTAssertEqual(askedDeletionsSince(server, from: before), pinned, "it asked for the deletions since 1.3.0's cursor")
        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(summary.unverifiedPass, .deletionsListed)
        XCTAssertEqual(try d.habitNames(), ["Read", "Stretch"])
        XCTAssertEqual(read.records.count, 2)
        XCTAssertEqual(summary.markedForResend, SyncRowCounts())
        XCTAssertTrue(summary.pushes.isEmpty, "the account holds every other row, and Run was listed")
        XCTAssertTrue(d.log.lines.isEmpty, "a deletion made elsewhere, applied quietly")
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertFalse(d.marks.isUnverified, "the pass ran")
        XCTAssertNil(d.defaults.object(forKey: SyncMarksProof.deletionsSinceKey), "the pin goes with the flag")
        XCTAssertEqual(try d.pendingCount(), 0)

        let quiet = expectSynced(await d.sync())
        XCTAssertTrue(quiet.pushes.isEmpty, "0/0/0")
        XCTAssertEqual(quiet.pulls.map(\.fullPull), [false])
        XCTAssertNil(quiet.marks)

        d.gate.state = .signedOut
        d.gate.state = .ready(SyncRunBinding(ownerID: "1", token: "token-A2", generation: 2))
        let resumed = expectSynced(await d.sync())
        XCTAssertTrue(resumed.pushes.isEmpty)
        XCTAssertEqual(resumed.pulls.map(\.fullPull), [false], "same account: resume, no proof")
        XCTAssertEqual(try d.habitNames(), ["Read", "Stretch"])
    }

    /// Review data-safety-1 (the reviewer's S1). A 1.3.0 device signed into B restored a backup
    /// made under A — 1.3.0 keeps the ids — and every 1.3.0 sync pushed those rows into B, which
    /// refused them (`not_owned`, `not_owned_habit`); 1.3.0 never read `skipped`, so the rows and
    /// the check-ins made on them since exist only here. The migration marks them delivered with
    /// the rest, and B's snapshot proves the marks with B's own habit: the proving pull's pass
    /// deleted them all as "deleted elsewhere", with no recovery-log line. A mark says 1.3.0
    /// pushed a row, not that a server took it. So the pass decides by B's deletions since 1.3.0's
    /// cursor: the habit B's phone deleted is listed and goes quietly; A's rows and one no server
    /// has are not, and are resent as the restore they were — A's `not_owned` (held for Restore as
    /// New Copies, an edit made since included), the other inserted. That pass clears the flag, so
    /// a deletion made elsewhere later deletes by absence again.
    func testAMigratedStoresRowsTheAccountLacksAreResentForTheServerToAnswerNotDeleted() async throws {
        let d = device(owner: "2", token: "token-B"), phone = device(owner: "2", token: "token-A2")
        aged(d.habit("B's own", records: [day(0)]))
        let deletedOnPhone = aged(d.habit("Deleted on B's phone"))
        try d.save()
        expectSynced(await d.sync())            // 1.3.0's snapshots put these on B
        expectSynced(await phone.sync())
        let deletedID = deletedOnPhone.id.uuidString
        try await deleteElsewhere("Deleted on B's phone", on: phone)
        // A's backup, restored with its ids after that sync; B has refused every row of it since.
        let restored = aged(d.habit("From A's backup", records: (0..<19).map(day)))
        let onNoServer = aged(d.habit("On no server"))
        try d.save()
        let restoredID = restored.id, onNoServerID = onNoServer.id.uuidString
        server.forcedReasons[restored.id.uuidString] = "not_owned"
        restored.records.forEach { server.forcedReasons[$0.id.uuidString] = "not_owned_habit" }
        try arriveFrom130(d, owner: "2")
        // A check-in edited after the update, before the first 1.3.1 sync: pending, and still A's.
        let edited = try XCTUnwrap(restored.records.first)
        let editedID = edited.id
        edited.note = "edited after the update"
        edited.touch()
        try d.save()

        let summary = expectSynced(await d.sync())

        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(summary.unverifiedPass, .deletionsListed)
        XCTAssertEqual(try d.habitNames(), ["B's own", "From A's backup", "On no server"],
                       "only the listed deletion went; nothing refused was deleted")
        XCTAssertFalse(try d.habits().contains { $0.id.uuidString == deletedID })
        let kept = try XCTUnwrap(d.habits().first { $0.id == restoredID })
        XCTAssertEqual(kept.activeHold, .notOwned)
        XCTAssertNotNil(kept.restoredAt, "resent as the restore it was")
        XCTAssertEqual(kept.records.count, 19)
        XCTAssertTrue(kept.records.allSatisfy { $0.activeHold == .notOwned }, "the edited check-in too")
        XCTAssertEqual(kept.records.first { $0.id == editedID }?.note, "edited after the update")
        XCTAssertNil(server.habits[restoredID.uuidString])
        XCTAssertNotNil(server.habits[onNoServerID], "no server row and no tombstone: inserted")
        XCTAssertNil(try d.habits().first { $0.id.uuidString == onNoServerID }?.restoredAt, "acknowledged")
        XCTAssertTrue(d.log.lines.isEmpty, "the phone's deletion was listed, and went quietly")
        XCTAssertEqual(summary.markedForResend, SyncRowCounts(groups: 0, habits: 2, entries: 19))
        XCTAssertEqual(try d.pendingCount(), 0)
        XCTAssertFalse(d.marks.isUnverified, "cleared by the pass that resent them")

        // A pass has run after the proof: from here a delivered row the account lacks was deleted
        // elsewhere, and the next full pull removes it by absence, with no resend.
        expectSynced(await phone.sync())
        try await deleteElsewhere("On no server", on: phone)
        d.cursors.setCursor(nil, for: "2")
        let mark = server.requests.count
        let later = expectSynced(await d.sync())
        XCTAssertEqual(later.pulls.first?.fullPull, true)
        XCTAssertNil(askedDeletionsSince(server, from: mark), "verified: nothing to ask")
        XCTAssertNil(later.unverifiedPass)
        XCTAssertTrue(later.pushes.isEmpty, "deleted by absence, not resent")
        XCTAssertEqual(try d.habitNames(), ["B's own", "From A's backup"], "held rows survive the full pull")
        XCTAssertTrue(d.log.lines.isEmpty, "delivered and unedited: nothing to archive")
    }

    /// Another account adopts the store (the reviewer's R1). Its snapshot holds none of this
    /// device's rows, so every mark is forgotten before the deletion pass: nothing is deleted,
    /// the rows are uploaded once, and one the server knows as another account's comes back
    /// `not_owned` and is held — kept by later full pulls, never re-sent until edited.
    func testAMigratedStoreAdoptedByAnotherAccountForgetsItsMarksDeletesNothingAndUploads() async throws {
        let serverB = FakeSyncServer()
        serverB.validTokens = ["token-B"]
        let theirs = TestDevice(server: serverB, owner: "2", token: "token-B", bounds: .standard)
        let d = TestDevice(server: serverB, owner: "2", token: "token-B", bounds: .standard)
        devices += [theirs, d]
        theirs.habit("B's own")
        try theirs.save()
        expectSynced(await theirs.sync())

        let group = aged(HabitGroup(name: "Morning"))
        d.context.insert(group)
        let read = aged(d.habit("Read", records: [day(0), day(1)]))
        read.groupId = group.id
        let lent = aged(d.habit("Also in account A"))
        try d.save()
        try arriveFrom130(d, owner: "2")
        serverB.forcedReasons[lent.id.uuidString] = "not_owned"

        let summary = expectSynced(await d.sync())

        XCTAssertEqual(summary.requests.first?.endpoint, .pull)
        XCTAssertEqual(summary.pulls.first?.fullPull, true)
        XCTAssertEqual(summary.marks, .forgotten(.init(habits: 2, records: 2, groups: 1)))
        XCTAssertEqual(try d.habitNames(), ["Also in account A", "B's own", "Read"], "nothing deleted")
        XCTAssertEqual(summary.pushedRows, SyncRowCounts(groups: 1, habits: 2, entries: 2))
        XCTAssertNotNil(serverB.habits[read.id.uuidString])
        XCTAssertEqual(serverB.entries.count, 2)
        XCTAssertEqual(lent.activeHold, .notOwned)
        XCTAssertNil(serverB.habits[lent.id.uuidString])
        XCTAssertTrue(d.log.lines.isEmpty)
        XCTAssertFalse(d.marks.isAwaited)

        let quiet = expectSynced(await d.sync())
        XCTAssertTrue(quiet.pushes.isEmpty, "the held row is not re-sent")
        d.cursors.setCursor(nil, for: "2")
        let full = expectSynced(await d.sync())
        XCTAssertEqual(full.pulls.first?.fullPull, true)
        XCTAssertNil(full.marks, "decided once")
        XCTAssertEqual(try d.habitNames(), ["Also in account A", "B's own", "Read"], "held survives a full pull")
    }

    /// The edge the rule cannot see: every row this device delivered was deleted elsewhere, so
    /// the snapshot holds none of them and the marks are forgotten. While tombstones are kept
    /// that costs nothing: the re-upload is answered `tombstoned`, the rows are dropped — to the
    /// recovery log first, since they were pending — and the account is as the other device
    /// left it. After a sweep (M0: only once the 426 floor retires ≤ 1.3.0) there is no
    /// tombstone to answer and the rows come back: the documented residual, pinned here so a
    /// change to it is seen. It needs a store with no surviving delivered row, and it restores
    /// the deleted habits rather than losing anything — the trade the owner chose over deleting
    /// by marks nobody proved.
    func testAStoreWhoseEveryDeliveredRowWasDeletedElsewhereReuploadsAndIsAnsweredByTheTombstone() async throws {
        for swept in [false, true] {
            let server = FakeSyncServer()
            server.validTokens = ["token-A", "token-A2"]
            let d = TestDevice(server: server, owner: "1", token: "token-A", bounds: .standard)
            let other = TestDevice(server: server, owner: "1", token: "token-A2", bounds: .standard)
            devices += [d, other]
            aged(d.habit("Read", records: [day(0)]))
            try d.save()
            expectSynced(await d.sync())
            expectSynced(await other.sync())
            try await deleteElsewhere("Read", on: other)
            try arriveFrom130(d, owner: "1")
            if swept { server.tombstones.removeAll() }

            let summary = expectSynced(await d.sync())

            XCTAssertEqual(summary.marks, .forgotten(.init(habits: 1, records: 1, groups: 0)))
            XCTAssertEqual(summary.pushedRows, SyncRowCounts(groups: 0, habits: 1, entries: 1))
            if swept {
                XCTAssertEqual(server.habits.count, 1, "after a sweep: the documented residual")
                XCTAssertEqual(try d.habitNames(), ["Read"])
            } else {
                XCTAssertTrue(server.habits.isEmpty, "the tombstone answered: not resurrected")
                XCTAssertTrue(try d.habits().isEmpty, "dropped here too")
                XCTAssertEqual(d.log.lines.map(\.item.reason), [.tombstoned, .tombstoned], "habit and check-in, archived")
            }
        }
    }

    /// A snapshot whose totals do not match its arrays proves nothing it does not contain: the
    /// marks stay provisional and both flags set, nothing is applied, deleted or uploaded, and
    /// the run ends before its push with no cursor written (review data-safety-2). The next run
    /// full-pulls again and decides.
    func testATruncatedProvingPullLeavesTheProofToTheNextFullPull() async throws {
        let d = device()
        aged(d.habit("Read"))
        try d.save()
        expectSynced(await d.sync())
        try arriveFrom130(d, owner: "1")
        server.scriptPull(at: 1, SyncTransportResponse(status: 200, body: Data("""
            {"habits":[],"entries":[],"groups":[],"serverTime":"\(SyncTimestamp.millisecondString(from: server.clock))",
             "totals":{"habits":9,"entries":0,"groups":0}}
            """.utf8)))

        let first = await d.sync()
        guard case .stopped(.backOff(.transient, _), let stopped) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(stopped.marks, .undecided)
        XCTAssertTrue(stopped.deletionPassSkipped)
        XCTAssertTrue(stopped.pushes.isEmpty, "provisional marks: nothing goes up before the proof")
        XCTAssertTrue(d.marks.isAwaited)
        XCTAssertTrue(d.marks.isUnverified)
        XCTAssertNotNil(d.marks.deletionsSince, "the pin stays for the pull that decides")
        XCTAssertEqual(try d.habitNames(), ["Read"])
        XCTAssertNil(d.cursors.cursor(for: "1"), "nothing applied: no cursor")

        let second = expectSynced(await d.sync())
        XCTAssertEqual(second.pulls.first?.fullPull, true)
        guard case .proven = second.marks else { return XCTFail("\(String(describing: second.marks))") }
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertFalse(d.marks.isUnverified)
        XCTAssertNil(d.marks.deletionsSince)
        XCTAssertEqual(try d.habitNames(), ["Read"])
    }

    /// Review data-safety-2 (the reviewer's S2). The marks were inferred for account A, and B's
    /// session adopted the store. B's proving pull could not decide — its totals did not match, a
    /// truncated body — yet it still inserted B's habit, delivered by being applied, and the run
    /// went on to push a new row into B and acknowledge it. Either one then "proved" A's marks at
    /// the next full pull, whose pass deleted A's rows. An undecided proving pull now applies
    /// nothing and ends the run before the push, writing no cursor, so the next one decides on
    /// B's snapshot alone: none of this device's rows, every mark forgotten, nothing deleted, and
    /// A's rows go up to be refused `not_owned` and held.
    func testAnUndecidedProvingPullAppliesNothingAndEndsTheRunSoTheNextDecidesOnTheSnapshot() async throws {
        let serverB = FakeSyncServer()
        serverB.validTokens = ["token-B"]
        let theirs = TestDevice(server: serverB, owner: "2", token: "token-B", bounds: .standard)
        let d = TestDevice(server: serverB, owner: "2", token: "token-B", bounds: .standard)
        devices += [theirs, d]
        theirs.habit("B's own", records: [day(0)])
        try theirs.save()
        expectSynced(await theirs.sync())

        let fromA = aged(d.habit("A's habit", records: [day(1)]))
        try d.save()
        let fromAID = fromA.id
        try arriveFrom130(d, owner: "2")
        serverB.forcedReasons[fromA.id.uuidString] = "not_owned"
        fromA.records.forEach { serverB.forcedReasons[$0.id.uuidString] = "not_owned_habit" }
        d.habit("Made after the update")
        try d.save()
        let own = try XCTUnwrap(serverB.habits.values.first?.wire)
        let ownEntry = try XCTUnwrap(serverB.entries.values.first?.wire)
        serverB.scriptPull(at: 1, SyncTransportResponse(status: 200, body: try pullBody(
            habits: [own], entries: [ownEntry], totals: SyncTotals(habits: 1, entries: 2, groups: 0),
            serverTime: serverB.clock)))

        let first = await d.sync()

        guard case .stopped(.backOff(.transient, _), let stopped) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(stopped.marks, .undecided)
        XCTAssertEqual(stopped.pulls.count, 1)
        XCTAssertTrue(stopped.pushes.isEmpty, "the run ended before the push")
        XCTAssertEqual(try d.habitNames(), ["A's habit", "Made after the update"], "B's habit was not applied")
        XCTAssertNil(d.cursors.cursor(for: "2"), "nothing applied: no cursor")
        XCTAssertTrue(d.marks.isAwaited)
        XCTAssertTrue(d.marks.isUnverified)

        let second = expectSynced(await d.sync())

        XCTAssertEqual(second.pulls.first?.fullPull, true)
        XCTAssertEqual(second.marks, .forgotten(.init(habits: 1, records: 1, groups: 0)))
        XCTAssertEqual(try d.habitNames(), ["A's habit", "B's own", "Made after the update"], "nothing deleted")
        let kept = try XCTUnwrap(d.habits().first { $0.id == fromAID })
        XCTAssertEqual(kept.activeHold, .notOwned)
        XCTAssertTrue(kept.records.allSatisfy { $0.activeHold == .notOwned })
        XCTAssertTrue(d.log.lines.isEmpty)
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertFalse(d.marks.isUnverified, "forgotten marks leave nothing to verify")
    }

    /// A pull answer as routes/sync.js sends it, to script one request with `FakeSyncServer`.
    private func pullBody(habits: [SyncHabit], entries: [SyncEntry] = [], deletedHabitIds: [String] = [],
                          totals: SyncTotals, serverTime: Date) throws -> Data {
        struct Body: Encodable {
            var habits: [SyncHabit]
            var entries: [SyncEntry]
            var groups: [SyncGroup] = []
            var deletedHabitIds: [String]
            var deletedEntryIds: [String] = []
            var deletedGroupIds: [String] = []
            var serverTime: String
            var totals: SyncTotals
        }
        return try JSONEncoder().encode(Body(habits: habits, entries: entries, deletedHabitIds: deletedHabitIds,
                                             serverTime: SyncTimestamp.millisecondString(from: serverTime),
                                             totals: totals))
    }

    /// The flags are settled only once the deciding pull is saved: a proving pull rolled back (its
    /// recovery-log append failed) leaves both set, and the pinned cursor, and the retry decides.
    /// The habit edited offline was deleted elsewhere after the last 1.3.0 sync, so it is in the
    /// account's deletions since then and goes by the normal rule — archived first, since the edit
    /// is pending, and that append is what fails.
    func testAProvingPullThatRollsBackLeavesTheProofToBeMade() async throws {
        let d = device(), other = device(token: "token-A2")
        aged(d.habit("Read"))
        let run = aged(d.habit("Run", records: [day(0)]))
        let runID = run.id.uuidString
        try d.save()
        expectSynced(await d.sync())
        expectSynced(await other.sync())
        try await deleteElsewhere("Run", on: other)
        try arriveFrom130(d, owner: "1")
        run.note = "edited offline"
        run.touch()
        try d.save()
        d.log.failure = CocoaError(.fileWriteOutOfSpace)

        let failed = await d.sync()
        guard case .stopped(.recoveryLogFailed, let stopped) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(stopped.pushes.isEmpty)
        XCTAssertTrue(d.marks.isAwaited)
        XCTAssertTrue(d.marks.isUnverified)
        XCTAssertNotNil(d.marks.deletionsSince)
        XCTAssertEqual(try d.habitNames(), ["Read", "Run"])

        d.log.failure = nil
        let summary = expectSynced(await d.sync())
        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(summary.unverifiedPass, .deletionsListed)
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertFalse(d.marks.isUnverified)
        XCTAssertEqual(try d.habitNames(), ["Read"])
        XCTAssertTrue(summary.pushes.isEmpty, "deleted by the list, not resent")
        XCTAssertEqual(d.log.lines.map(\.item.ref.id), [runID], "the offline edit is recoverable")
        XCTAssertEqual(d.log.lines.first?.item.reason, .deletedElsewhere)
    }

    // MARK: The pass that verifies migrated marks (review data-safety-1)

    /// The reviewer's H2 and H3: the everyday upgrade of a two-device user. After this device's
    /// last 1.3.0 sync, the iPad deleted a habit with three check-ins, deleted another habit
    /// queueing only its own id, and untapped one check-in of a third. All of it is in the
    /// account's deletions since 1.3.0's cursor — a check-in also through its habit's id — so it
    /// goes as an incremental pull from that cursor would have removed it: nothing pushed, nothing
    /// in Recovered Edits. (deb5ebc resent every such row and archived each as a tombstoned edit:
    /// "Recovered Edits (1)" for an untap, a line per check-in for a deleted habit.)
    func testDeletionsAndUntapsMadeElsewhereSinceTheLast130SyncApplyQuietly() async throws {
        let d = device(), iPad = device(token: "token-A2")
        let kept = aged(d.habit("Kept", records: [day(0), day(1)]))
        aged(d.habit("Gone", records: [day(2), day(3), day(4)]))
        aged(d.habit("Gone, its id alone queued", records: [day(5), day(6)]))
        try d.save()
        expectSynced(await d.sync())
        expectSynced(await iPad.sync())
        try await deleteElsewhere("Gone", on: iPad)
        let alone = try XCTUnwrap(iPad.habits().first { $0.name == "Gone, its id alone queued" })
        iPad.queue.trackHabit(alone.id.uuidString)
        iPad.context.delete(alone)
        let iPadKept = try XCTUnwrap(iPad.habits().first { $0.name == "Kept" })
        let untapped = try XCTUnwrap(iPadKept.records.first { $0.date == day(1) })
        iPad.queue.trackEntry(untapped.id.uuidString)
        iPadKept.records.removeAll { $0.id == untapped.id }
        iPad.context.delete(untapped)
        try iPad.save()
        expectSynced(await iPad.sync())
        try arriveFrom130(d, owner: "1")

        let summary = expectSynced(await d.sync())

        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(summary.unverifiedPass, .deletionsListed)
        XCTAssertEqual(try d.habitNames(), ["Kept"])
        XCTAssertEqual(kept.records.map(\.date), [day(0)], "the untap arrived")
        XCTAssertTrue(summary.pushes.isEmpty, "0 rows pushed")
        XCTAssertTrue(d.log.lines.isEmpty, "0 recovery-log lines: nobody edited these here")
        XCTAssertEqual(summary.markedForResend, SyncRowCounts())
        XCTAssertEqual(try d.pendingCount(), 0)
        XCTAssertFalse(d.marks.isUnverified)
        let next = expectSynced(await d.sync())
        XCTAssertTrue(next.pushes.isEmpty, "and the next sync is quiet")
    }

    /// The reviewer's H1, as a sweep can make it happen. A device slept on 1.3.0 for over a year:
    /// its last sync, 400 days ago, pushed "Kept" and "Gone", "Gone" was deleted elsewhere since,
    /// and a sweep has taken the tombstones — which it may only do past retention, so the cursor
    /// 1.3.0 kept is past the server's horizon. The server cannot list the deletions since it
    /// whole, so "Gone" is deleted and every row of it archived first: never resent, which put the
    /// deleted habit and its history back into the account and onto every device (deb5ebc: 4 rows
    /// pushed, the server with [Gone, Kept] and 5 entries).
    func testADeviceDormantPastTheHorizonDeletesAndArchivesWhatTheAccountLacksAndResendsNothing() async throws {
        let d = device(), other = device(token: "token-A2")
        let slept: TimeInterval = 400 * 86_400
        let kept = aged(d.habit("Kept", records: [day(0), day(1)]), by: slept + 86_400)
        let gone = aged(d.habit("Gone", records: [day(2), day(3), day(4)]), by: slept + 86_400)
        try d.save()
        let goneRows = Set([gone.id.uuidString] + gone.records.map(\.id.uuidString))
        expectSynced(await d.sync())
        expectSynced(await other.sync())
        try await deleteElsewhere("Gone", on: other)
        server.tombstones.removeAll()   // swept: no row, no tombstone
        try arriveFrom130(d, owner: "1", cursor: .at(server.clock.addingTimeInterval(-slept)),
                          lastSync: Date().addingTimeInterval(-slept))
        let before = server.requests.count

        let summary = expectSynced(await d.sync())

        XCTAssertNotNil(askedDeletionsSince(server, from: before), "it asked…")
        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(summary.unverifiedPass, .deletionsUnknown, "…and was told no list could be whole")
        XCTAssertEqual(try d.habitNames(), ["Kept"])
        XCTAssertTrue(summary.pushes.isEmpty, "nothing resent")
        XCTAssertEqual(Array(server.habits.keys), [kept.id.uuidString], "never re-inserted")
        XCTAssertEqual(server.entries.count, 2)
        XCTAssertEqual(Set(d.log.lines.map(\.item.ref.id)), goneRows, "the habit and every check-in, archived")
        XCTAssertTrue(d.log.lines.allSatisfy { $0.item.reason == .deletedElsewhere })
        XCTAssertFalse(d.marks.isUnverified)
        let next = expectSynced(await d.sync())
        XCTAssertTrue(next.pushes.isEmpty)
        XCTAssertEqual(server.habits.count, 1, "and it stays out")
    }

    /// A same-account restore the 1.3.0 server refused: the backup brought back, with their ids, a
    /// habit and check-ins the account had deleted before the restore — so before this device's
    /// last 1.3.0 sync, and not among the deletions since. Every 1.3.0 sync pushed them and was
    /// answered `tombstoned`, unread, and a check-in was made on the habit after the update. The
    /// pass resends them as the restore they were: the tombstone holds the habit and its
    /// check-ins, the new one stays with them (review delivery-1), nothing lands in Recovered
    /// Edits, and Restore as New Copies puts the habit and every check-in back into the account.
    func testASameAccountRestoreTheServerRefusedIsHeldTombstonedAndRestoresAsNewCopies() async throws {
        let d = device(), other = device(token: "token-A2")
        aged(d.habit("Kept"))
        try d.save()
        expectSynced(await d.sync())
        let original = aged(other.habit("Restored from the backup", records: [day(0), day(1), day(2)]))
        try other.save()
        expectSynced(await other.sync())
        let restoredID = original.id, recordIDs = original.records.sorted { $0.date < $1.date }.map(\.id)
        try await deleteElsewhere("Restored from the backup", on: other)
        let restored = d.habit("Restored from the backup")
        restored.id = restoredID
        restored.records = recordIDs.enumerated().map { index, id in
            let record = HabitRecord(date: day(index))
            record.id = id
            return record
        }
        aged(restored)
        try d.save()
        // 1.3.0 synced after the restore, more than the overlap after the account's deletion.
        server.clock = server.clock.addingTimeInterval(120)
        try arriveFrom130(d, owner: "1", cursor: .at(server.clock.addingTimeInterval(-SyncCursor.overlap)))
        let madeSince = HabitRecord(date: day(3), note: "after the update")
        restored.records.append(madeSince)
        try d.save()

        let summary = expectSynced(await d.sync())

        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(summary.unverifiedPass, .deletionsListed)
        XCTAssertEqual(summary.markedForResend, SyncRowCounts(groups: 0, habits: 1, entries: 3))
        XCTAssertEqual(restored.activeHold, .tombstoned, "held for the user's choice, not dropped")
        XCTAssertEqual(restored.records.count, 4)
        XCTAssertEqual(restored.records.filter { $0.activeHold == .tombstoned }.count, 3)
        XCTAssertNil(madeSince.syncHoldReason, "kept by its habit's hold")
        XCTAssertTrue(d.log.lines.isEmpty, "nothing archived, nothing dropped")
        XCTAssertEqual(summary.dropped, 0)
        XCTAssertNil(server.habits[restoredID.uuidString], "the tombstone stands for the old id")

        let copies = try SyncCopies.reidentify(try SyncCopies.heldRows(in: d.context, reasons: [.tombstoned]), in: d.context)
        XCTAssertEqual(copies.rows, SyncRowCounts(groups: 0, habits: 1, entries: 4))
        let after = expectSynced(await d.sync())
        XCTAssertEqual(after.pushedRows, SyncRowCounts(groups: 0, habits: 1, entries: 4))
        XCTAssertNotEqual(restored.id, restoredID)
        XCTAssertEqual(server.habits[restored.id.uuidString]?.wire.name, "Restored from the backup")
        XCTAssertEqual(server.entries.values.filter { $0.wire.habitId == restored.id.uuidString }.count, 4,
                       "the habit and every check-in are back in the account")
    }

    /// No list to decide by — no cursor was pinned (1.3.0 never finished a sync on this store, or
    /// it came from 1.2.2 or earlier), or the server does not answer the field (its 1.3.1 half not
    /// deployed yet). The pass cannot tell the habit deleted elsewhere from another account's
    /// restore the 1.3.0 server refused, so it deletes both and archives every row first: the
    /// refused rows are in the recovery log, nothing is lost, and nothing is resent into an
    /// account that may have swept the tombstone that would have answered it.
    func testWithNoListThePassDeletesAndArchivesEveryRowItDeletes() async throws {
        for mode in ["no pinned cursor", "a server that ignores the parameter"] {
            server = FakeSyncServer()
            server.validTokens = ["token-A", "token-A2"]
            server.listsDeletionsSince = mode == "no pinned cursor"
            let d = device(), other = device(token: "token-A2")
            aged(d.habit("Kept"))
            let run = aged(d.habit("Run", records: [day(0)]))
            try d.save()
            let runRows = Set([run.id.uuidString] + run.records.map(\.id.uuidString))
            expectSynced(await d.sync())
            expectSynced(await other.sync())
            try await deleteElsewhere("Run", on: other)
            let refused = aged(d.habit("Another account's restore", records: [day(1), day(2)]))
            try d.save()
            let refusedRows = Set([refused.id.uuidString] + refused.records.map(\.id.uuidString))
            server.forcedReasons[refused.id.uuidString] = "not_owned"
            try arriveFrom130(d, owner: "1", cursor: mode == "no pinned cursor" ? .none : .lastSync)
            let before = server.requests.count

            let summary = expectSynced(await d.sync())

            XCTAssertEqual(askedDeletionsSince(server, from: before) != nil, mode != "no pinned cursor", mode)
            guard case .proven = summary.marks else { return XCTFail("\(mode): \(String(describing: summary.marks))") }
            XCTAssertEqual(summary.unverifiedPass, .deletionsUnknown, mode)
            XCTAssertEqual(try d.habitNames(), ["Kept"], mode)
            XCTAssertTrue(summary.pushes.isEmpty, "\(mode): nothing resent")
            XCTAssertEqual(Set(d.log.lines.map(\.item.ref.id)), runRows.union(refusedRows),
                           "\(mode): every row it deleted, archived — the refused ones included")
            XCTAssertTrue(d.log.lines.allSatisfy { $0.item.reason == .deletedElsewhere }, mode)
            XCTAssertFalse(d.marks.isUnverified, mode)
            XCTAssertNil(d.marks.deletionsSince, mode)
        }
    }

    /// "Upload these habits to this account" (the account screen's future choice for an
    /// owner-unknown device): the user said these rows go up, so every mark is forgotten and
    /// nothing is left to prove — even for the marks' own account. Its deletion comes back as a
    /// `tombstoned` answer, dropped and archived; the rows it still has are adopted, not re-sent.
    func testUploadTheseHabitsForgetsEveryMarkAndLeavesNothingToProve() async throws {
        let d = device(), other = device(token: "token-A2")
        aged(d.habit("Read", records: [day(0)]))
        aged(d.habit("Run", records: [day(0)]))
        try d.save()
        expectSynced(await d.sync())
        expectSynced(await other.sync())
        try await deleteElsewhere("Run", on: other)
        try arriveFrom130(d, owner: "1")

        let forgotten = try d.marks.forgetMarks(in: d.context)

        XCTAssertEqual(forgotten, .init(habits: 2, records: 2, groups: 0))
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertFalse(d.context.hasChanges, "saved")
        let summary = expectSynced(await d.sync())
        XCTAssertNil(summary.marks)
        XCTAssertEqual(summary.pushedRows, SyncRowCounts(groups: 0, habits: 1, entries: 1), "Run: the account has Read")
        XCTAssertEqual(try d.habitNames(), ["Read"])
        XCTAssertEqual(Set(d.log.lines.map(\.item.reason)), [.tombstoned])
        XCTAssertEqual(try d.pendingCount(), 0)
    }
}

// MARK: - Test device

@MainActor
final class TestDevice {
    final class Gate: SyncRunGate {
        var state: SyncGateState
        init(_ state: SyncGateState) { self.state = state }
        func current() -> SyncGateState { state }
    }

    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let suiteName = "SyncEngineTests-\(UUID().uuidString)"
    let queue: SyncDeletionQueue
    let cursors: SyncDefaultsCursorStore
    let log = SyncMemoryRecoveryLog()
    let gate: Gate
    let engine: SyncEngine
    var reports: [SyncDiagnosticReport] = []
    /// The per-owner backoff in this device's defaults (used by the engine only when the device
    /// was made with `backoff: true`).
    var backoffStore: SyncBackoffStore { SyncBackoffStore(defaults: defaults) }

    /// `recoveryLog` replaces the in-memory `log` (the file log's tests); `backoff` gives the
    /// engine the per-owner backoff, which most tests leave out so every run goes.
    init(server: FakeSyncServer, owner: String, token: String, bounds: SyncPushBounds,
         recoveryLog: (any SyncRecoveryLogSink)? = nil, backoff: Bool = false) {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        defaults = UserDefaults(suiteName: suiteName)!
        queue = SyncDeletionQueue(local: defaults, shared: nil)
        cursors = SyncDefaultsCursorStore(defaults: defaults)
        gate = Gate(.ready(SyncRunBinding(ownerID: owner, token: token, generation: 0)))
        var sink: ((SyncDiagnosticReport) -> Void)?
        engine = SyncEngine(transport: server, gate: gate, cursorStore: cursors, deletionQueue: queue,
                            strikes: SyncUnknownHabitStrikes(defaults: defaults),
                            marks: SyncMarksProof(defaults: defaults), recoveryLog: recoveryLog ?? log,
                            backoff: backoff ? SyncBackoffStore(defaults: defaults) : nil,
                            report: { sink?($0) }, bounds: bounds)
        sink = { [weak self] in self?.reports.append($0) }
    }

    func remove() { defaults.removePersistentDomain(forName: suiteName) }

    var marks: SyncMarksProof { SyncMarksProof(defaults: defaults) }

    func sync(options: SyncRunOptions = [], trigger: SyncBackoffTrigger = .manual) async -> SyncRunOutcome {
        await engine.run(in: context, options: options, trigger: trigger)
    }

    @discardableResult
    func habit(_ name: String, records: [Date] = []) -> Habit {
        let h = Habit(name: name)
        context.insert(h)
        h.records = records.map { HabitRecord(date: $0) }
        return h
    }

    func save() throws { try context.save() }
    func habits() throws -> [Habit] { try context.fetch(FetchDescriptor<Habit>()) }
    func habitNames() throws -> [String] { try habits().map(\.name).sorted() }

    func pendingCount() throws -> Int {
        try context.fetch(FetchDescriptor<Habit>()).filter(\.isPending).count
            + context.fetch(FetchDescriptor<HabitRecord>()).filter(\.isPending).count
            + context.fetch(FetchDescriptor<HabitGroup>()).filter(\.isPending).count
    }
}

// MARK: - Fake server

/// A small model of routes/sync.js for one account: LWW upserts with the values-differ check and
/// the re-feed, entries keyed by habit and day (and the `aliases` answer that follows from it),
/// tombstones, skip reasons, `totals`, row caps, `snapshot_required` and `cursor_expired`. The
/// transport's double — the engine under test talks to it through `SyncTransport` exactly as it
/// talks to APIClient, as the 1.3.1 app it is.
@MainActor
final class FakeSyncServer: SyncTransport {
    struct Request {
        var endpoint: SyncEndpoint
        var token: String
        var since: String?
        var deletionsSince: String? = nil
    }

    struct Stored<Wire> {
        var wire: Wire
        var stamp: Int64
        var updatedAt: Date
    }

    var habits: [String: Stored<SyncHabit>] = [:]
    /// Keyed by canonical habit id + "|" + date, as the server's `ON CONFLICT(habit_id, date)`.
    var entries: [String: Stored<SyncEntry>] = [:]
    var groups: [String: Stored<SyncGroup>] = [:]
    var tombstones: [(kind: SyncRowKind, id: String, at: Date)] = []
    var clock = SyncTimestamp.floorToMillisecond(Date())
    var validTokens: Set<String> = []
    var forcedReasons: [String: String] = [:]
    var snapshotRequested = false
    var expireNextCursor = false
    /// Answers a full pull's `deletionsSince` as routes/sync.js does. false: a server from before
    /// the 1.3.1 half, which ignores the parameter.
    var listsDeletionsSince = true
    var rowLimits = SyncRowLimits(habits: 500, entries: 5000, groups: 200)
    var onRequest: ((Request) -> Void)?
    private(set) var requests: [Request] = []
    private var scripted: [SyncEndpoint: [Int: SyncTransportResponse]] = [:]
    private var counts: [SyncEndpoint: Int] = [:]

    /// Answers the `n`-th request (1-based, counted from now) of that endpoint with `response`.
    func scriptPush(at n: Int, _ response: SyncTransportResponse) { script(.push, n, response) }
    func scriptPull(at n: Int, _ response: SyncTransportResponse) { script(.pull, n, response) }
    private func script(_ endpoint: SyncEndpoint, _ n: Int, _ response: SyncTransportResponse) {
        counts[endpoint] = 0
        scripted[endpoint, default: [:]][n] = response
    }

    func markTombstoned(_ kind: SyncRowKind, _ id: String) {
        tombstones.append((kind, SyncReconciler.canonicalID(id), clock))
    }

    private func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    private func receive(_ request: Request) -> SyncTransportResponse? {
        requests.append(request)
        onRequest?(request)
        _ = tick()
        counts[request.endpoint, default: 0] += 1
        if let scripted = scripted[request.endpoint]?.removeValue(forKey: counts[request.endpoint]!) { return scripted }
        guard validTokens.contains(request.token) else { return error(401, "unauthorized") }
        return nil
    }

    private func error(_ status: Int, _ code: String, extra: [String: Any] = [:]) -> SyncTransportResponse {
        var body: [String: Any] = ["error": code, "code": code, "message": "fake"]
        body.merge(extra) { $1 }
        return SyncTransportResponse(status: status, body: try! JSONSerialization.data(withJSONObject: body))
    }

    private func ok<T: Encodable>(_ value: T) -> SyncTransportResponse {
        SyncTransportResponse(status: 200, body: try! JSONEncoder().encode(value))
    }

    // MARK: Push

    private struct PushBody: Decodable {
        var habits: [SyncHabit]
        var entries: [SyncEntry]
        var groups: [SyncGroup]
        var deletedHabitIds: [String]
        var deletedEntryIds: [String]
        var deletedGroupIds: [String]
    }

    private struct PushAnswer: Encodable {
        var ok = true
        var applied: [String: Int] = ["habits": 0, "entries": 0, "groups": 0]
        var skipped: [String: [String]] = ["habits": [], "entries": [], "groups": []]
        var skippedReasons: [String: [String: String]] = ["habits": [:], "entries": [:], "groups": [:]]
        /// Only when there is one, as the server sends it.
        var aliases: [String: [String: String]]?

        mutating func skip(_ type: String, _ id: String, _ reason: String) {
            skipped[type, default: []].append(id)
            skippedReasons[type, default: [:]][id] = reason
        }

        mutating func alias(entry sent: String, to stored: String) {
            aliases = ["entries": (aliases?["entries"] ?? [:]).merging([sent: stored]) { $1 }]
        }
    }

    func push(body: Data, token: String) async -> SyncTransportResponse {
        if let early = receive(Request(endpoint: .push, token: token, since: nil)) { return early }
        guard let payload = try? JSONDecoder().decode(PushBody.self, from: body) else { return error(400, "invalid_payload") }
        if payload.habits.count > rowLimits.habits || payload.entries.count > rowLimits.entries
            || payload.groups.count > rowLimits.groups {
            return error(400, "too_many_rows", extra: ["limits": ["habits": rowLimits.habits,
                                                                  "entries": rowLimits.entries,
                                                                  "groups": rowLimits.groups]])
        }
        if snapshotRequested {
            snapshotRequested = false
            return error(409, "snapshot_required")
        }
        let now = clock
        func canon(_ id: String) -> String { SyncReconciler.canonicalID(id) }
        func isTombstoned(_ kind: SyncRowKind, _ id: String) -> Bool {
            tombstones.contains { $0.kind == kind && $0.id == canon(id) }
        }

        for id in payload.deletedHabitIds {
            habits.removeValue(forKey: canon(id))
            entries = entries.filter { canon($0.value.wire.habitId) != canon(id) }
            tombstones.append((.habit, canon(id), now))
        }
        for id in payload.deletedEntryIds {
            entries = entries.filter { canon($0.value.wire.id) != canon(id) }
            tombstones.append((.entry, canon(id), now))
        }
        for id in payload.deletedGroupIds {
            groups.removeValue(forKey: canon(id))
            tombstones.append((.group, canon(id), now))
        }

        var answer = PushAnswer()
        for g in payload.groups {
            if isTombstoned(.group, g.id) { answer.skip("groups", g.id, "tombstoned"); continue }
            if let reason = forcedReasons[canon(g.id)] { answer.skip("groups", g.id, reason); continue }
            upsert(&groups, key: canon(g.id), wire: g, stamp: g.updatedAt,
                   same: { $0.name == $1.name && $0.colorHex == $1.colorHex && $0.sortOrder == $1.sortOrder })
            answer.applied["groups", default: 0] += 1
        }
        for h in payload.habits {
            if isTombstoned(.habit, h.id) { answer.skip("habits", h.id, "tombstoned"); continue }
            if let reason = forcedReasons[canon(h.id)] { answer.skip("habits", h.id, reason); continue }
            upsert(&habits, key: canon(h.id), wire: h, stamp: h.updatedAt,
                   same: { $0.name == $1.name && $0.note == $1.note && $0.isArchived == $1.isArchived
                       && $0.sortOrder == $1.sortOrder && $0.groupId == $1.groupId && $0.targetValue == $1.targetValue })
            answer.applied["habits", default: 0] += 1
        }
        for e in payload.entries {
            if isTombstoned(.entry, e.id) { answer.skip("entries", e.id, "tombstoned"); continue }
            if isTombstoned(.habit, e.habitId) { answer.skip("entries", e.id, "tombstoned_habit"); continue }
            if let reason = forcedReasons[canon(e.id)] { answer.skip("entries", e.id, reason); continue }
            guard habits[canon(e.habitId)] != nil else { answer.skip("entries", e.id, "unknown_habit"); continue }
            let key = canon(e.habitId) + "|" + e.date
            upsert(&entries, key: key, wire: e, stamp: e.updatedAt ?? e.createdAt,
                   keepID: true, same: { $0.note == $1.note && $0.value == $1.value })
            if let stored = entries[key]?.wire.id, stored != e.id { answer.alias(entry: e.id, to: stored) }
            answer.applied["entries", default: 0] += 1
        }
        return ok(answer)
    }

    /// The server's guard: applied when the incoming client stamp is >= the stored one and the
    /// stamp or a value differs; otherwise, when it is strictly older and the values differ, the
    /// stored row's `updated_at` moves (the LWW re-feed), so the losing device pulls the winner.
    private func upsert<W: SyncWireRow>(_ table: inout [String: Stored<W>], key: String, wire: W, stamp: String,
                                        keepID: Bool = false, same: (W, W) -> Bool) {
        let ms = SyncTimestamp.parse(stamp).map(SyncTimestamp.milliseconds) ?? 0
        guard var existing = table[key] else {
            table[key] = Stored(wire: wire, stamp: ms, updatedAt: clock)
            return
        }
        if ms >= existing.stamp {
            if ms != existing.stamp || !same(existing.wire, wire) {
                existing.wire = keepID ? wire.withID(existing.wire.rowID) : wire
                existing.stamp = ms
                existing.updatedAt = clock
            }
        } else if !same(existing.wire, wire) {
            existing.updatedAt = clock
        }
        table[key] = existing
    }

    // MARK: Pull

    private struct PullAnswer: Encodable {
        var habits: [SyncHabit]
        var entries: [SyncEntry]
        var groups: [SyncGroup]
        var deletedHabitIds: [String]
        var deletedEntryIds: [String]
        var deletedGroupIds: [String]
        var serverTime: String
        var totals: SyncTotals
        /// Only when a full pull asked, as the server sends it.
        var deletionsSince: DeletionsSince?
    }

    private struct DeletionsSince: Encodable {
        var complete: Bool
        var habitIds: [String]?
        var entryIds: [String]?
        var groupIds: [String]?
    }

    /// The server's horizon for both `cursor_expired` and `deletionsSince`: retention less the grace.
    static let cursorHorizon: TimeInterval = (365 - 10) * 86_400

    func pull(since: String?, deletionsSince: String?, token: String) async -> SyncTransportResponse {
        if let early = receive(Request(endpoint: .pull, token: token, since: since, deletionsSince: deletionsSince)) {
            return early
        }
        if snapshotRequested {
            snapshotRequested = false
            return error(409, "snapshot_required")
        }
        let sinceDate = since.flatMap(SyncTimestamp.parse)
        if sinceDate != nil {
            if expireNextCursor || clock.timeIntervalSince(sinceDate!) > Self.cursorHorizon {
                expireNextCursor = false
                return error(409, "cursor_expired", extra: ["retentionDays": 365])
            }
        }
        func changed<W>(_ rows: [String: Stored<W>]) -> [W] {
            rows.values.filter { row in sinceDate.map { row.updatedAt > $0 } ?? true }
                .sorted { $0.updatedAt < $1.updatedAt }.map(\.wire)
        }
        func deleted(_ kind: SyncRowKind, after date: Date?) -> [String] {
            guard let date else { return [] }
            return tombstones.filter { $0.kind == kind && $0.at > date }.map(\.id)
        }
        // A full pull that asks gets the account's deletions since that time — or none, past the
        // horizon (a sweep may have taken a tombstone after it) or for a time it cannot read.
        var listed: DeletionsSince?
        if since == nil, let deletionsSince, listsDeletionsSince {
            if let date = SyncTimestamp.parse(deletionsSince), clock.timeIntervalSince(date) <= Self.cursorHorizon {
                listed = DeletionsSince(complete: true, habitIds: deleted(.habit, after: date),
                                        entryIds: deleted(.entry, after: date), groupIds: deleted(.group, after: date))
            } else {
                listed = DeletionsSince(complete: false)
            }
        }
        return ok(PullAnswer(
            habits: changed(habits), entries: changed(entries), groups: changed(groups),
            deletedHabitIds: deleted(.habit, after: sinceDate), deletedEntryIds: deleted(.entry, after: sinceDate),
            deletedGroupIds: deleted(.group, after: sinceDate),
            serverTime: SyncTimestamp.millisecondString(from: clock),
            totals: SyncTotals(habits: habits.count, entries: entries.count, groups: groups.count),
            deletionsSince: listed))
    }
}

/// Lets the fake keep the first id of an entry row, as `ON CONFLICT(habit_id, date)` does.
protocol SyncWireRow {
    var rowID: String { get }
    func withID(_ id: String) -> Self
}

extension SyncHabit: SyncWireRow {
    var rowID: String { id }
    func withID(_ id: String) -> SyncHabit { self }
}

extension SyncGroup: SyncWireRow {
    var rowID: String { id }
    func withID(_ id: String) -> SyncGroup { self }
}

extension SyncEntry: SyncWireRow {
    var rowID: String { id }
    func withID(_ id: String) -> SyncEntry {
        SyncEntry(id: id, habitId: habitId, date: date, note: note, value: value, createdAt: createdAt, updatedAt: updatedAt)
    }
}
