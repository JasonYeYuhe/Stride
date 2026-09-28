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
                        bounds: SyncPushBounds = .standard) -> TestDevice {
        let d = TestDevice(server: server, owner: owner, token: token, bounds: bounds)
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

    // MARK: - The first full pull proves the account (owner decision, 2026-09-28)

    /// Stamps an hour old — what a 1.3.0 store holds for rows its last snapshot carried (the
    /// migrated-rows rule marks a row only if its stamp is 5 min or more before that sync).
    @discardableResult
    private func aged<Row: SyncDeliverable>(_ row: Row) -> Row {
        let t = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-3_600))
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

    /// What the first 1.3.1 launch finds on a dormant 1.3.0 device that synced as the rows say:
    /// no delivery state (1.3.0 had none), no cursor under 1.3.1's per-owner key, and 1.3.0's
    /// last-sync time — whose session may since have expired, which 1.3.0 did not record. Then
    /// the real migration: the rows are stamped delivered and their marks await the proof.
    private func arriveFrom130(_ d: TestDevice, owner: String) throws {
        for habit in try d.habits() {
            habit.syncedAt = nil
            habit.records.forEach { $0.syncedAt = nil }
        }
        try d.context.fetch(FetchDescriptor<HabitGroup>()).forEach { $0.syncedAt = nil }
        try d.save()
        d.cursors.setCursor(nil, for: owner)
        d.defaults.set(SyncTimestamp.string(from: Date()), forKey: SyncDeliveryMigration.lastSyncTimeKey)
        guard case .stamped(let counts) = SyncDeliveryMigration.runOnceIfNeeded(in: d.context, defaults: d.defaults),
              counts.total > 0 else { return XCTFail("the migration stamped nothing") }
        XCTAssertTrue(d.marks.isAwaited)
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
    /// holds a habit this device delivered, so the marks stand: the habit deleted on another
    /// device meanwhile is removed (not re-uploaded, which after a sweep would resurrect it),
    /// nothing else is deleted, nothing is uploaded, the next sync is quiet, and signing out
    /// and back in resumes with no proof to make.
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
        d.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")

        let summary = expectSynced(await d.sync())

        XCTAssertEqual(summary.requests.first?.endpoint, .pull)
        XCTAssertEqual(summary.pulls.first?.fullPull, true, "the proof is a full pull, cursor or not")
        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertEqual(try d.habitNames(), ["Read", "Stretch"])
        XCTAssertEqual(read.records.count, 2)
        XCTAssertEqual(summary.pushedRows.total, 0, "every row was in the last 1.3.0 snapshot")
        XCTAssertTrue(d.log.lines.isEmpty)
        XCTAssertFalse(d.marks.isAwaited)
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

    /// A snapshot that fails validation proves nothing it does not contain: the marks stay
    /// provisional and the flag set, nothing is deleted or uploaded, and the next run — though
    /// it has a cursor by then — full-pulls again and decides.
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

        let first = expectSynced(await d.sync())
        XCTAssertEqual(first.marks, .undecided)
        XCTAssertTrue(first.deletionPassSkipped)
        XCTAssertTrue(d.marks.isAwaited)
        XCTAssertEqual(try d.habitNames(), ["Read"])
        XCTAssertEqual(first.pushedRows.total, 0, "provisional marks: not pending, not deleted")
        XCTAssertNotNil(d.cursors.cursor(for: "1"))

        let second = expectSynced(await d.sync())
        XCTAssertEqual(second.pulls.first?.fullPull, true)
        guard case .proven = second.marks else { return XCTFail("\(String(describing: second.marks))") }
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertEqual(try d.habitNames(), ["Read"])
    }

    /// The flag is settled only once the deciding pull is saved: a proving pull rolled back (its
    /// recovery-log append failed) leaves it set, and the retry decides.
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
        guard case .stopped(.recoveryLogFailed, _) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(d.marks.isAwaited)
        XCTAssertEqual(try d.habitNames(), ["Read", "Run"])

        d.log.failure = nil
        let summary = expectSynced(await d.sync())
        guard case .proven = summary.marks else { return XCTFail("\(String(describing: summary.marks))") }
        XCTAssertFalse(d.marks.isAwaited)
        XCTAssertEqual(try d.habitNames(), ["Read"])
        XCTAssertTrue(d.log.lines.contains { $0.item.ref.id == runID }, "the offline edit is recoverable")
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

    init(server: FakeSyncServer, owner: String, token: String, bounds: SyncPushBounds) {
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
                            marks: SyncMarksProof(defaults: defaults), recoveryLog: log,
                            report: { sink?($0) }, bounds: bounds)
        sink = { [weak self] in self?.reports.append($0) }
    }

    func remove() { defaults.removePersistentDomain(forName: suiteName) }

    var marks: SyncMarksProof { SyncMarksProof(defaults: defaults) }

    func sync(options: SyncRunOptions = []) async -> SyncRunOutcome {
        await engine.run(in: context, options: options)
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
/// the re-feed, entries keyed by habit and day, tombstones, skip reasons, `totals`, row caps,
/// `snapshot_required` and `cursor_expired`. The transport's double — the engine under test
/// talks to it through `SyncTransport` exactly as it talks to APIClient.
@MainActor
final class FakeSyncServer: SyncTransport {
    struct Request {
        var endpoint: SyncEndpoint
        var token: String
        var since: String?
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

        mutating func skip(_ type: String, _ id: String, _ reason: String) {
            skipped[type, default: []].append(id)
            skippedReasons[type, default: [:]][id] = reason
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
            upsert(&entries, key: canon(e.habitId) + "|" + e.date, wire: e, stamp: e.updatedAt ?? e.createdAt,
                   keepID: true, same: { $0.note == $1.note && $0.value == $1.value })
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
    }

    func pull(since: String?, token: String) async -> SyncTransportResponse {
        if let early = receive(Request(endpoint: .pull, token: token, since: since)) { return early }
        if snapshotRequested {
            snapshotRequested = false
            return error(409, "snapshot_required")
        }
        let sinceDate = since.flatMap(SyncTimestamp.parse)
        if sinceDate != nil {
            if expireNextCursor || clock.timeIntervalSince(sinceDate!) > (365 - 10) * 86_400 {
                expireNextCursor = false
                return error(409, "cursor_expired", extra: ["retentionDays": 365])
            }
        }
        func changed<W>(_ rows: [String: Stored<W>]) -> [W] {
            rows.values.filter { row in sinceDate.map { row.updatedAt > $0 } ?? true }
                .sorted { $0.updatedAt < $1.updatedAt }.map(\.wire)
        }
        func deleted(_ kind: SyncRowKind) -> [String] {
            guard let sinceDate else { return [] }
            return tombstones.filter { $0.kind == kind && $0.at > sinceDate }.map(\.id)
        }
        return ok(PullAnswer(
            habits: changed(habits), entries: changed(entries), groups: changed(groups),
            deletedHabitIds: deleted(.habit), deletedEntryIds: deleted(.entry), deletedGroupIds: deleted(.group),
            serverTime: SyncTimestamp.millisecondString(from: clock),
            totals: SyncTotals(habits: habits.count, entries: entries.count, groups: groups.count)))
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
