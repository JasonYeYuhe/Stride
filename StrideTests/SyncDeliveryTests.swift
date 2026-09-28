import XCTest
import SwiftData
import Foundation

/// The 1.3.1 delivery state and millisecond stamps (DEV-PLAN-1.3.md M2: "Delivery state, not a
/// boolean", "Millisecond edit stamps", sub-decision (b)), against the real code in Shared/.
///
/// The planner, engine and reconciler build on these rules; their own tests live beside them.
/// This file pins the layer underneath: what "pending", "held" and "delivered" mean, that a stamp
/// survives the wire unchanged, which rows the first 1.3.1 launch marks as delivered — and that a
/// store written by 1.3.0 opens under this schema with every row and field intact.
@MainActor
final class SyncDeliveryTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var defaults: UserDefaults!
    private var suiteName = ""
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        suiteName = "SyncDeliveryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        defaults = nil
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func date(_ iso: String) -> Date { SyncTimestamp.parse(iso)! }

    private func ms(_ date: Date?) -> Int64? { date.map(SyncTimestamp.milliseconds) }

    private func isWholeMillisecond(_ date: Date) -> Bool {
        date == SyncTimestamp.floorToMillisecond(date)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - Timestamps

    func testTouchFloorsToTheMillisecond() {
        let habit = Habit(name: "Read")
        let record = HabitRecord(date: Date())
        let group = HabitGroup(name: "Health")
        for _ in 0..<50 {
            habit.touch(); record.touch(); group.touch()
            XCTAssertTrue(isWholeMillisecond(habit.updatedAt!))
            XCTAssertTrue(isWholeMillisecond(record.updatedAt!))
            XCTAssertTrue(isWholeMillisecond(group.updatedAt!))
        }
    }

    /// An edit must change the stamp — it is what makes a row pending and lifts a hold — even
    /// when two edits land inside one millisecond (a tight loop does, every time).
    func testEveryTouchChangesTheStamp() {
        let habit = Habit(name: "Read")
        let record = HabitRecord(date: Date())
        let group = HabitGroup(name: "Health")
        var previous: [Date] = [habit.stamp, record.stamp, group.stamp]
        for _ in 0..<1_000 {
            habit.touch(); record.touch(); group.touch()
            let now = [habit.stamp, record.stamp, group.stamp]
            for (a, b) in zip(previous, now) { XCTAssertFalse(SyncTimestamp.sameMillisecond(a, b)) }
            previous = now
        }
    }

    /// A tie bumps by one millisecond; a clock that stepped backwards is NOT dragged forward to
    /// the old clock's future — the stamp moves back, which the inequality rule sends anyway.
    func testNextStampBumpsOnlyOnATie() {
        let now = SyncTimestamp.now()
        let tie = SyncTimestamp.nextStamp(after: now)
        XCTAssertTrue(SyncTimestamp.isNewer(tie, than: now))
        let future = now.addingTimeInterval(3_600)
        XCTAssertTrue(SyncTimestamp.isNewer(future, than: SyncTimestamp.nextStamp(after: future)))
        XCTAssertTrue(isWholeMillisecond(SyncTimestamp.nextStamp(after: nil)))
    }

    /// A row never edited stamps as its creation time, which goes on the wire as it is stored.
    func testNewRowsAreStampedAtWholeMilliseconds() {
        let habit = Habit(name: "Read")
        let group = HabitGroup(name: "Health")
        let record = HabitRecord(date: Date())
        XCTAssertTrue(isWholeMillisecond(habit.createdAt))
        XCTAssertTrue(isWholeMillisecond(habit.stamp))
        XCTAssertTrue(isWholeMillisecond(group.createdAt))
        XCTAssertTrue(isWholeMillisecond(group.stamp))
        XCTAssertTrue(isWholeMillisecond(record.stamp))
        XCTAssertEqual(habit.createdAt, habit.updatedAt)
    }

    func testMillisecondStringHasExactlyThreeDigitsAndFloors() {
        XCTAssertEqual(SyncTimestamp.millisecondString(from: Date(timeIntervalSince1970: 1_789_493_598.123)),
                       "2026-09-15T17:33:18.123Z")
        XCTAssertEqual(SyncTimestamp.millisecondString(from: Date(timeIntervalSince1970: 1_789_493_598)),
                       "2026-09-15T17:33:18.000Z")
        XCTAssertEqual(SyncTimestamp.millisecondString(from: Date(timeIntervalSince1970: 1_789_493_598.007)),
                       "2026-09-15T17:33:18.007Z")
        // Never rounded up into the next millisecond — or the next second.
        XCTAssertEqual(SyncTimestamp.millisecondString(from: Date(timeIntervalSince1970: 1_789_493_598.9999)),
                       "2026-09-15T17:33:18.999Z")
        XCTAssertEqual(SyncTimestamp.millisecondString(from: Date(timeIntervalSince1970: 1_789_493_598.1239)),
                       "2026-09-15T17:33:18.123Z")
        // The legacy whole-second serialiser is unchanged: still truncates.
        XCTAssertEqual(SyncTimestamp.string(from: Date(timeIntervalSince1970: 1_789_493_598.9)), "2026-09-15T17:33:18Z")
    }

    /// The store and the wire hold the same number: what touch() stored, sent as a string and
    /// read back (the server's echo, the acknowledgement), is the same `Date` — `==`, not "close".
    func testTheWireStringParsesBackToTheSameDate() {
        let habit = Habit(name: "Read")
        for _ in 0..<200 {
            habit.touch()
            let stamp = habit.updatedAt!
            XCTAssertEqual(SyncTimestamp.parse(SyncTimestamp.millisecondString(from: stamp)), stamp)
        }
        // Across a spread of instants, not only "now" — the binary rounding differs by magnitude.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let millis = Int64.random(in: 946_684_800_000...4_102_444_800_000, using: &generator) // 2000...2100
            let d = Date(timeIntervalSince1970: Double(millis) / 1000)
            let floored = SyncTimestamp.floorToMillisecond(d)
            XCTAssertEqual(SyncTimestamp.milliseconds(d), millis)
            XCTAssertEqual(SyncTimestamp.parse(SyncTimestamp.millisecondString(from: floored)), floored)
        }
    }

    func testParseStillReadsWholeSecondsAndTheyEqualDotZero() {
        let whole = date("2026-09-15T17:33:18Z")
        XCTAssertEqual(whole.timeIntervalSince1970, 1_789_493_598)
        XCTAssertEqual(date("2026-09-15T17:33:18.000Z"), whole)
        XCTAssertEqual(ms(date("2026-09-15T17:33:18.700Z")), 1_789_493_598_700)
        XCTAssertNil(SyncTimestamp.parse("2026-09-15"))
    }

    func testMillisecondComparisons() {
        let a = date("2026-09-15T17:33:18.700Z")
        let b = date("2026-09-15T17:33:18.300Z")
        XCTAssertTrue(SyncTimestamp.isNewer(a, than: b))
        XCTAssertFalse(SyncTimestamp.isNewer(b, than: a))
        XCTAssertFalse(SyncTimestamp.isNewer(a, than: a))
        // Sub-millisecond differences are the same millisecond: a 1.3.0 stamp and its wire form.
        let legacy = Date(timeIntervalSince1970: 1_789_493_598.300_42)
        XCTAssertTrue(SyncTimestamp.sameMillisecond(legacy, b))
        XCTAssertFalse(SyncTimestamp.isNewer(legacy, than: b))
        XCTAssertTrue(SyncTimestamp.sameMillisecond(nil, nil))
        XCTAssertFalse(SyncTimestamp.sameMillisecond(a, nil))
        XCTAssertFalse(SyncTimestamp.sameMillisecond(nil, a))
    }

    // MARK: - Stamp

    func testStampFallsBackToCreatedAtAndARecordToItsDate() {
        let habit = Habit(name: "Old")
        habit.updatedAt = nil
        XCTAssertEqual(habit.stamp, habit.createdAt)

        let group = HabitGroup(name: "Old")
        group.updatedAt = nil
        XCTAssertEqual(group.stamp, group.createdAt)

        // HabitRecord has no createdAt: the push sends `date` in its place.
        let record = HabitRecord(date: date("2026-09-15T00:00:00Z"))
        record.updatedAt = nil
        XCTAssertEqual(record.stamp, record.date)
        record.acknowledge(sentStamp: record.date)
        XCTAssertFalse(record.isPending)
    }

    // MARK: - Delivery state

    func testNewRowsArePendingAndNeverDelivered() {
        let rows: [SyncDeliverable] = [Habit(name: "A"), HabitRecord(date: Date()), HabitGroup(name: "G")]
        for row in rows {
            XCTAssertTrue(row.isPending)
            XCTAssertFalse(row.hasBeenDelivered)
            XCTAssertFalse(row.isHeld)
            XCTAssertNil(row.activeHold)
            XCTAssertFalse(row.needsResend)
            XCTAssertNil(row.restoredAt)
        }
    }

    func testAcknowledgedAtTheCurrentStampIsNotPending() {
        let habit = Habit(name: "A")
        habit.acknowledge(sentStamp: habit.stamp)
        XCTAssertFalse(habit.isPending)
        XCTAssertTrue(habit.hasBeenDelivered)
        habit.touch()
        XCTAssertTrue(habit.isPending, "an edit makes it pending again")
        XCTAssertTrue(habit.hasBeenDelivered, "and it keeps its evidence of delivery")
    }

    /// Edit during an in-flight push, on a first upload *(review 2)*: acknowledged with the stamp
    /// that was SENT, so the row stays pending AND is no longer "never delivered".
    func testAnEditDuringTheInFlightPushStaysPendingWithTheSentStamp() {
        let record = HabitRecord(date: Date())
        record.updatedAt = date("2026-09-15T17:33:18.300Z")
        let sent = record.stamp
        record.updatedAt = date("2026-09-15T17:33:18.700Z")   // the tap that landed mid-push
        record.acknowledge(sentStamp: sent)
        XCTAssertEqual(record.syncedAt, sent)
        XCTAssertTrue(record.isPending)
        XCTAssertTrue(record.hasBeenDelivered)
    }

    /// Inequality, not ordering: a clock stepped backwards between two edits still sends the edit.
    func testAClockStepBackwardsStillLeavesTheRowPending() {
        let group = HabitGroup(name: "G")
        group.updatedAt = date("2026-09-15T17:33:18.000Z")
        group.acknowledge(sentStamp: group.stamp)
        group.updatedAt = date("2026-09-15T17:30:00.000Z")
        XCTAssertTrue(group.isPending)
    }

    /// A 1.3.0 row keeps its sub-millisecond stamp until edited; the acknowledgement stores the
    /// stamp as it crossed the wire, and the two still compare equal.
    func testASubMillisecondLegacyStampAcknowledgedFromTheWireIsNotPending() {
        let habit = Habit(name: "Legacy")
        habit.updatedAt = Date(timeIntervalSince1970: 1_789_493_598.123_456)
        let wire = SyncTimestamp.millisecondString(from: habit.stamp)
        XCTAssertEqual(wire, "2026-09-15T17:33:18.123Z")
        habit.acknowledge(sentStamp: SyncTimestamp.parse(wire)!)
        XCTAssertFalse(habit.isPending)
    }

    func testAHeldRowIsNotPendingUntilEdited() {
        let habit = Habit(name: "Bad")
        habit.hold(.invalidValue)
        XCTAssertTrue(habit.isHeld)
        XCTAssertEqual(habit.activeHold, .invalidValue)
        XCTAssertFalse(habit.isPending)
        XCTAssertFalse(habit.hasBeenDelivered, "a hold is not an acknowledgement")

        habit.touch()
        XCTAssertFalse(habit.isHeld, "the edit's new stamp lifts the hold by itself")
        XCTAssertNil(habit.activeHold)
        XCTAssertTrue(habit.isPending)
    }

    /// Held at the SENT stamp: an edit made while the push was in flight is a new value, not held.
    func testAHoldAtTheSentStampDoesNotHoldAnEditMadeInFlight() {
        let record = HabitRecord(date: Date())
        record.updatedAt = date("2026-09-15T17:33:18.300Z")
        let sent = record.stamp
        record.updatedAt = date("2026-09-15T17:33:18.700Z")
        record.hold(.rowError, sentStamp: sent)
        XCTAssertFalse(record.isHeld)
        XCTAssertTrue(record.isPending)
    }

    /// A previously delivered row that is later held stays delivered: the full-pull rule must
    /// keep it because it is held, not because it looks never-sent.
    func testHoldingADeliveredRowKeepsItsEvidenceOfDelivery() {
        let habit = Habit(name: "A")
        habit.acknowledge(sentStamp: habit.stamp)
        let delivered = habit.syncedAt
        habit.touch()
        habit.hold(.notOwned)
        XCTAssertEqual(habit.syncedAt, delivered)
        XCTAssertTrue(habit.isHeld)
        XCTAssertFalse(habit.isPending)
    }

    func testAnUnknownHoldReasonStillReadsAsHeld() {
        let habit = Habit(name: "A")
        habit.hold(.rowError)
        habit.syncHoldReason = "some_future_reason"
        XCTAssertTrue(habit.isHeld)
        XCTAssertEqual(habit.activeHold, .rowError)
        XCTAssertFalse(habit.isPending)
    }

    func testHoldReasonsAreTheServersCodes() {
        XCTAssertEqual(Set(SyncHoldReason.allCases.map(\.rawValue)),
                       ["missing_field", "row_error", "invalid_value", "unknown_habit", "not_owned", "too_large", "tombstoned"])
    }

    func testReleaseHoldMakesTheRowPendingAgain() {
        let group = HabitGroup(name: "G")
        group.hold(.tombstoned)
        group.releaseHold()
        XCTAssertFalse(group.isHeld)
        XCTAssertTrue(group.isPending)
    }

    /// Forced resend: planned even when acknowledged, `syncedAt` untouched; the next
    /// acknowledgement clears it. A held row is still not sent.
    func testNeedsResendPlansTheRowAndLeavesSyncedAt() {
        let habit = Habit(name: "A")
        habit.acknowledge(sentStamp: habit.stamp)
        let delivered = habit.syncedAt
        habit.markNeedsResend()
        XCTAssertTrue(habit.isPending)
        XCTAssertEqual(habit.syncedAt, delivered)

        habit.acknowledge(sentStamp: habit.stamp)
        XCTAssertFalse(habit.needsResend)
        XCTAssertFalse(habit.isPending)

        let held = Habit(name: "Held")
        held.hold(.missingField)
        held.markNeedsResend()
        XCTAssertFalse(held.isPending)
        XCTAssertTrue(held.isHeld, "a forced resend does not lift a hold")
    }

    func testAcknowledgementClearsRestoredAtAndAStaleHold() {
        let record = HabitRecord(date: Date())
        record.restoredAt = Date()
        record.hold(.rowError)
        record.touch()                              // lifts the hold; the fields are stale
        record.acknowledge(sentStamp: record.stamp)
        XCTAssertNil(record.restoredAt)
        XCTAssertNil(record.syncHoldReason)
        XCTAssertNil(record.syncHoldStamp)
        XCTAssertFalse(record.isPending)
    }

    /// Applying remote state: `syncedAt = stamp`, and needsResend, holds and restoredAt cleared —
    /// otherwise this device's own push echoes back through the cursor overlap as pending, forever.
    func testAdoptingRemoteStateIsNotPending() {
        let habit = Habit(name: "A")
        habit.markNeedsResend()
        habit.hold(.rowError)
        habit.restoredAt = Date()
        habit.updatedAt = date("2026-09-15T17:33:18.700Z")  // the reconciler adopted the server's
        habit.adoptRemoteState()
        XCTAssertEqual(habit.syncedAt, date("2026-09-15T17:33:18.700Z"))
        XCTAssertFalse(habit.isPending)
        XCTAssertFalse(habit.needsResend)
        XCTAssertNil(habit.syncHoldReason)
        XCTAssertNil(habit.restoredAt)
    }

    /// Rows older apps wrote arrive as whole seconds and compare the same way.
    func testAWholeSecondRemoteStampIsNotPendingAfterAdopt() {
        let record = HabitRecord(date: Date())
        record.updatedAt = date("2026-09-15T17:33:18Z")
        record.adoptRemoteState()
        XCTAssertFalse(record.isPending)
        XCTAssertEqual(SyncTimestamp.millisecondString(from: record.stamp), "2026-09-15T17:33:18.000Z")
    }

    func testDeliveryStatePersistsThroughTheStore() throws {
        let habit = Habit(name: "A")
        context.insert(habit)
        let record = HabitRecord(date: Date())
        habit.records.append(record)
        let group = HabitGroup(name: "G")
        context.insert(group)
        habit.acknowledge(sentStamp: habit.stamp)
        record.hold(.tooLarge)
        group.markNeedsResend()
        group.restoredAt = date("2026-09-15T17:33:18.500Z")
        try context.save()

        let fresh = ModelContext(container)
        let h = try XCTUnwrap(fresh.fetch(FetchDescriptor<Habit>()).first)
        let r = try XCTUnwrap(fresh.fetch(FetchDescriptor<HabitRecord>()).first)
        let g = try XCTUnwrap(fresh.fetch(FetchDescriptor<HabitGroup>()).first)
        XCTAssertFalse(h.isPending)
        XCTAssertEqual(r.activeHold, .tooLarge)
        XCTAssertTrue(g.needsResend)
        XCTAssertEqual(g.restoredAt, date("2026-09-15T17:33:18.500Z"))
    }

    // MARK: - Wire stamps without a formatter (large-account performance, M2)

    /// `SyncWireStamp` must give exactly what `SyncTimestamp` gives — the same string, and the
    /// same `Date` bit for bit — or an echo would stop comparing equal to the stamp it echoes.
    /// Swept over every millisecond fraction, both shapes, leap days, the ends of the range it
    /// handles, and random instants from 1970 to 9999; anything it does not handle must come
    /// back from `SyncTimestamp` unchanged.
    func testWireStampsMatchTheFormatterBitForBit() {
        func check(_ date: Date, file: StaticString = #filePath, line: UInt = #line) {
            let string = SyncWireStamp.string(from: date)
            XCTAssertEqual(string, SyncTimestamp.millisecondString(from: date), file: file, line: line)
            let whole = String(string.prefix(19)) + "Z"
            for s in [string, whole] {
                let fast = SyncWireStamp.parse(s), slow = SyncTimestamp.parse(s)
                XCTAssertEqual(fast?.timeIntervalSince1970.bitPattern, slow?.timeIntervalSince1970.bitPattern,
                               s, file: file, line: line)
            }
        }
        let base = date("2026-09-15T17:33:18.000Z")
        for ms in 0..<1_000 { check(base.addingTimeInterval(Double(ms) / 1000)) }
        for iso in ["1970-01-01T00:00:00.000Z", "1999-12-31T23:59:59.999Z", "2000-02-29T12:00:00.500Z",
                    "2024-02-29T23:59:59.999Z", "2069-12-31T23:59:59.999Z", "2070-01-01T00:00:00.000Z",
                    "2100-03-01T00:00:00.001Z", "9999-12-31T23:59:59.999Z"] {
            check(SyncTimestamp.parse(iso)!)
        }
        // Sub-millisecond instants (1.3.0's stamps) floor as `milliseconds` does.
        check(Date(timeIntervalSince1970: 1_789_493_598.123_456))
        check(Date(timeIntervalSince1970: 1_789_493_598.999_999_9))
        var generator = SystemRandomNumberGenerator()
        // Where it parses itself (1970–2069) most densely; to 9999 it formats itself and parses
        // through the formatter.
        for _ in 0..<10_000 {
            check(Date(timeIntervalSince1970: Double(Int64.random(in: 0..<3_155_760_000_000, using: &generator)) / 1000))
            check(Date(timeIntervalSince1970: Double.random(in: 0..<3_155_760_000, using: &generator)))
        }
        for _ in 0..<2_000 {
            check(Date(timeIntervalSince1970: Double(Int64.random(in: 0..<253_402_300_800_000, using: &generator)) / 1000))
        }

        // Outside what it handles: the formatter answers, whatever it answers.
        for s in ["1969-12-31T23:59:59.999Z", "0001-01-01T00:00:00Z", "2026-02-29T00:00:00Z",
                  "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-04-31T00:00:00Z",
                  "2026-09-15T24:00:00Z", "2026-09-15T23:60:00Z", "2026-09-15T23:59:60Z",
                  "2026-09-15T17:33:18.12Z", "2026-09-15T17:33:18.1234Z", "2026-09-15T17:33:18z",
                  "2026-09-15t17:33:18Z", "2026-09-15T17:33:18+00:00", "2026-09-15T17:33:18.123+09:00",
                  "2026-09-15 17:33:18Z", "+2026-09-15T17:33:18Z", "2026-9-15T17:33:18.000Z", "",
                  "not a date", "２０２６-09-15T17:33:18Z", "2026-09-15T17:33:18.１２３Z"] {
            XCTAssertEqual(SyncWireStamp.parse(s)?.timeIntervalSince1970.bitPattern,
                           SyncTimestamp.parse(s)?.timeIntervalSince1970.bitPattern, s)
        }
        for date in [Date(timeIntervalSince1970: -0.001), Date(timeIntervalSince1970: -86_400 * 365),
                     Date(timeIntervalSince1970: 253_402_300_800)] {
            XCTAssertEqual(SyncWireStamp.string(from: date), SyncTimestamp.millisecondString(from: date))
        }
    }

    // MARK: - The pending fetch (large-account performance, M2)

    /// `SyncPendingRows` asks the store for a superset and lets `isPending` decide: it must
    /// return exactly the records `isPending` names, in every delivery state — the 1.3.0 shapes
    /// included (a stamp below the millisecond, a record with no `updatedAt`) — before a save
    /// (the planner runs on the app's context between autosaves), after it, and cold.
    func testThePendingFetchFindsExactlyThePendingRecords() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("pending.store")
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let disk = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)])
        let context = ModelContext(disk)
        context.autosaveEnabled = false
        let day = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let base = date("2026-09-15T17:33:18.000Z")
        let legacy = Date(timeIntervalSince1970: 1_789_493_598.123_456)   // 1.3.0: below the ms

        let habit = Habit(name: "States")
        context.insert(habit)
        var cases: [(String, HabitRecord)] = []
        func record(_ name: String, _ n: Int, _ configure: (HabitRecord) -> Void) {
            let r = HabitRecord(date: day.addingTimeInterval(Double(n) * 86_400))
            r.updatedAt = base.addingTimeInterval(Double(n))
            configure(r)
            habit.records.append(r)
            cases.append((name, r))
        }
        record("new", 0) { _ in }
        record("acknowledged", 1) { $0.acknowledge(sentStamp: $0.stamp) }
        record("acknowledged, then edited", 2) { $0.acknowledge(sentStamp: $0.stamp); $0.touch() }
        record("pulled", 3) { $0.adoptRemoteState() }
        record("held", 4) { $0.hold(.rowError) }
        record("delivered, then held", 5) { $0.acknowledge(sentStamp: $0.stamp); $0.hold(.notOwned) }
        record("held, needsResend", 6) { $0.acknowledge(sentStamp: $0.stamp); $0.hold(.rowError); $0.markNeedsResend() }
        record("held, then edited", 7) { $0.hold(.rowError); $0.touch() }
        record("needsResend", 8) { $0.acknowledge(sentStamp: $0.stamp); $0.markNeedsResend() }
        record("legacy stamp, acknowledged from the wire", 9) {
            $0.updatedAt = legacy
            $0.acknowledge(sentStamp: SyncTimestamp.parse(SyncTimestamp.millisecondString(from: legacy))!)
        }
        record("legacy stamp, delivered at another stamp", 10) {
            $0.updatedAt = legacy
            $0.syncedAt = base
        }
        record("no updatedAt, delivered at its day", 11) { $0.updatedAt = nil; $0.syncedAt = $0.date }
        record("no updatedAt, never delivered", 12) { $0.updatedAt = nil }
        record("no updatedAt, delivered at another stamp", 13) { $0.updatedAt = nil; $0.syncedAt = base }
        record("no updatedAt, held", 14) { $0.updatedAt = nil; $0.hold(.invalidValue) }
        record("clock stepped back", 15) {
            $0.acknowledge(sentStamp: $0.stamp)
            $0.updatedAt = $0.stamp.addingTimeInterval(-600)
        }
        record("restored with its ids", 16) { $0.acknowledge(sentStamp: $0.stamp); $0.restoredAt = base }

        func check(_ phase: String, in context: ModelContext) throws {
            let all = try context.fetch(FetchDescriptor<HabitRecord>())
            let expected = Set(all.filter(\.isPending).map(\.persistentModelID))
            let found = try SyncPendingRows.records(in: context)
            let names = { (ids: Set<PersistentIdentifier>) in
                all.filter { ids.contains($0.persistentModelID) }.map { r in
                    cases.first { $0.1.id == r.id }?.0 ?? "?"
                }.sorted()
            }
            XCTAssertEqual(names(found), names(expected), phase)
            XCTAssertEqual(all.count, cases.count, phase)
        }

        let pendingNames = cases.filter { $0.1.isPending }.map(\.0).sorted()
        XCTAssertEqual(pendingNames, ["acknowledged, then edited", "clock stepped back", "held, then edited",
                                      "legacy stamp, delivered at another stamp", "needsResend", "new",
                                      "no updatedAt, delivered at another stamp", "no updatedAt, never delivered"],
                       "the states cover both answers")

        try check("before the first save", in: context)
        try context.save()
        try check("saved", in: context)

        // Edits since the save, not yet saved: an acknowledged row edited, a pending one delivered.
        cases.first { $0.0 == "acknowledged" }!.1.touch()
        let new = cases.first { $0.0 == "new" }!.1
        new.acknowledge(sentStamp: new.stamp)
        try check("edited since the save", in: context)
        try context.save()

        let cold = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)]))
        try check("reopened cold", in: cold)
    }

    // MARK: - Migrated rows (sub-decision (b))

    /// Rows stamped at least 5 minutes before 1.3.0's last successful sync are delivered; later
    /// ones stay pending; without the key nothing is stamped.
    func testMigratedRowsStampedFiveMinutesBeforeTheLastSyncAreDelivered() throws {
        let lastSync = "2026-09-20T12:00:00Z"
        let old = Habit(name: "Old")
        old.updatedAt = date("2026-09-20T11:00:00.250Z")
        let boundary = Habit(name: "Boundary")
        boundary.updatedAt = date("2026-09-20T11:55:00.000Z")         // exactly 5 min: delivered
        let recent = Habit(name: "Recent")
        recent.updatedAt = date("2026-09-20T11:55:00.001Z")           // inside the window: pending
        let later = Habit(name: "After")
        later.updatedAt = date("2026-09-20T13:00:00Z")
        let legacy = Habit(name: "No updatedAt")
        legacy.createdAt = date("2026-01-01T08:00:00Z")
        legacy.updatedAt = nil
        for h in [old, boundary, recent, later, legacy] { context.insert(h) }

        let oldRecord = HabitRecord(date: date("2026-09-01T00:00:00Z"))
        oldRecord.updatedAt = nil                                     // stamps as its date
        old.records.append(oldRecord)
        let newRecord = HabitRecord(date: date("2026-09-20T00:00:00Z"))
        newRecord.updatedAt = date("2026-09-20T11:59:00Z")
        old.records.append(newRecord)

        let oldGroup = HabitGroup(name: "Old group")
        oldGroup.updatedAt = date("2026-09-10T09:00:00Z")
        let newGroup = HabitGroup(name: "New group")
        newGroup.updatedAt = date("2026-09-20T11:58:00Z")
        context.insert(oldGroup)
        context.insert(newGroup)

        let alreadyDelivered = Habit(name: "Already")
        alreadyDelivered.updatedAt = date("2026-09-01T00:00:00Z")
        alreadyDelivered.syncedAt = date("2026-08-01T00:00:00Z")
        context.insert(alreadyDelivered)
        try context.save()

        let counts = try SyncDeliveryMigration.stampMigratedRows(in: context, lastSyncTime: lastSync)
        XCTAssertEqual(counts, .init(habits: 3, records: 1, groups: 1))

        for delivered in [old, boundary, legacy] as [SyncDeliverable] + [oldRecord, oldGroup] {
            XCTAssertFalse(delivered.isPending)
            XCTAssertTrue(SyncTimestamp.sameMillisecond(delivered.syncedAt, delivered.stamp))
        }
        for pending in [recent, later] as [SyncDeliverable] + [newRecord, newGroup] {
            XCTAssertTrue(pending.isPending)
            XCTAssertNil(pending.syncedAt)
        }
        XCTAssertEqual(alreadyDelivered.syncedAt, date("2026-08-01T00:00:00Z"), "never overwrites an acknowledgement")
    }

    func testWithoutALastSyncTimeNothingIsStamped() throws {
        let habit = Habit(name: "A")
        habit.updatedAt = date("2020-01-01T00:00:00Z")
        context.insert(habit)
        XCTAssertEqual(try SyncDeliveryMigration.stampMigratedRows(in: context, lastSyncTime: nil).total, 0)
        XCTAssertEqual(try SyncDeliveryMigration.stampMigratedRows(in: context, lastSyncTime: "not a date").total, 0)
        XCTAssertTrue(habit.isPending)
    }

    func testTheMigrationRunsOnceAndSaves() throws {
        let habit = Habit(name: "A")
        habit.updatedAt = date("2026-09-01T00:00:00Z")
        context.insert(habit)
        try context.save()
        defaults.set("2026-09-20T12:00:00Z", forKey: SyncDeliveryMigration.lastSyncTimeKey)

        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults),
                       .stamped(.init(habits: 1, records: 0, groups: 0)))
        XCTAssertFalse(context.hasChanges, "saved")
        XCTAssertTrue(defaults.bool(forKey: SyncDeliveryMigration.doneKey))
        XCTAssertNil(defaults.object(forKey: SyncDeliveryMigration.pinnedLastSyncKey))

        // A later edit, then a 1.3.1 sync writing a newer last-sync time: the rule never runs again,
        // or it would mark as delivered rows 1.3.1 has not pushed.
        habit.touch()
        habit.updatedAt = date("2026-09-21T00:00:00Z")
        try context.save()
        defaults.set("2026-09-30T00:00:00Z", forKey: SyncDeliveryMigration.lastSyncTimeKey)
        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults), .alreadyDone)
        XCTAssertTrue(habit.isPending)
    }

    func testAFreshInstallStampsNothingAndIsDone() throws {
        let habit = Habit(name: "A")
        context.insert(habit)
        try context.save()
        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults), .stamped(.init()))
        XCTAssertTrue(defaults.bool(forKey: SyncDeliveryMigration.doneKey))
        XCTAssertTrue(habit.isPending)
    }

    /// A retry after a failed first attempt uses the value 1.3.0 wrote, pinned at that attempt —
    /// not a 1.3.1 sync's that may have overwritten the key in between.
    func testARetryUsesThePinnedValueNotANewerSyncTime() throws {
        let habit = Habit(name: "A")
        habit.updatedAt = date("2026-09-25T00:00:00Z")
        context.insert(habit)
        try context.save()
        defaults.set("2026-09-20T12:00:00Z", forKey: SyncDeliveryMigration.pinnedLastSyncKey) // 1.3.0's
        defaults.set("2026-09-28T12:00:00Z", forKey: SyncDeliveryMigration.lastSyncTimeKey)  // 1.3.1's
        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults), .stamped(.init()))
        XCTAssertTrue(habit.isPending)

        // "" pins "1.3.0 had none".
        defaults.removeObject(forKey: SyncDeliveryMigration.doneKey)
        defaults.set("", forKey: SyncDeliveryMigration.pinnedLastSyncKey)
        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults), .stamped(.init()))
        XCTAssertTrue(habit.isPending)
    }

    /// Owner decision 2026-09-28: the marks the rule infers are for an account 1.3.0 never
    /// recorded, so a store it stamped waits for the first full pull of the account that adopts
    /// it (`SyncMarksProof`). One it stamped nothing in has nothing to prove.
    func testStampedMarksAwaitTheProofAndAStoreWithNoneHasNothingToProve() throws {
        let proof = SyncMarksProof(defaults: defaults)
        let habit = Habit(name: "A")
        habit.updatedAt = date("2026-09-01T00:00:00Z")
        context.insert(habit)
        try context.save()
        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults), .stamped(.init()))
        XCTAssertFalse(proof.isAwaited, "no last-sync time: nothing stamped")

        defaults.removeObject(forKey: SyncDeliveryMigration.doneKey)
        defaults.set("2026-09-20T12:00:00Z", forKey: SyncDeliveryMigration.lastSyncTimeKey)
        XCTAssertEqual(SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults),
                       .stamped(.init(habits: 1, records: 0, groups: 0)))
        XCTAssertTrue(proof.isAwaited)
    }

    /// "Upload these habits to this account": every mark forgotten and saved, holds and
    /// `needsResend` untouched, and nothing left to prove.
    func testForgettingTheMarksSavesAndSettlesTheProof() throws {
        let proof = SyncMarksProof(defaults: defaults)
        proof.require()
        let habit = Habit(name: "A")
        context.insert(habit)
        habit.records.append(HabitRecord(date: date("2026-09-01T00:00:00Z")))
        habit.syncedAt = SyncTimestamp.floorToMillisecond(habit.stamp)
        habit.records.first?.syncedAt = habit.records.first?.stamp
        habit.hold(.notOwned)
        let group = HabitGroup(name: "G")
        context.insert(group)
        group.syncedAt = group.stamp
        group.needsResend = true
        try context.save()

        let counts = try proof.forgetMarks(in: context)

        XCTAssertEqual(counts, .init(habits: 1, records: 1, groups: 1))
        XCTAssertFalse(context.hasChanges)
        XCTAssertFalse(proof.isAwaited)
        XCTAssertNil(habit.syncedAt)
        XCTAssertEqual(habit.activeHold, .notOwned, "a hold is not a mark")
        XCTAssertTrue(group.needsResend)
        XCTAssertTrue(group.isPending)
    }

    // MARK: - Wire models

    func testPushResponseDecodesTheServersShape() throws {
        let json = """
        {"ok":true,"applied":{"habits":2,"entries":5,"groups":0},
         "skipped":{"habits":["h1"],"entries":["e1","e2"],"groups":[]},
         "skippedReasons":{"habits":{"h1":"not_owned"},"entries":{"e1":"unknown_habit","e2":"tombstoned_habit"},"groups":{}}}
        """
        let response = try JSONDecoder().decode(SyncPushResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.applied, .init(habits: 2, entries: 5, groups: 0))
        XCTAssertEqual(response.skipped, .init(habits: ["h1"], entries: ["e1", "e2"]))
        XCTAssertEqual(response.skippedReasons?.entries["e2"], "tombstoned_habit")
    }

    func testPushResponseFromAServerBeforeTheContractDecodes() throws {
        let bare = try JSONDecoder().decode(SyncPushResponse.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertTrue(bare.ok)
        XCTAssertNil(bare.skipped)
        let partial = try JSONDecoder().decode(SyncPushResponse.self, from: Data(#"{"ok":true,"skipped":{"entries":["x"]}}"#.utf8))
        XCTAssertEqual(partial.skipped, .init(entries: ["x"]))
    }

    func testPullTotalsAreOptional() throws {
        let base = #""habits":[],"entries":[],"groups":[],"serverTime":"2026-09-28T00:00:00.000Z""#
        let without = try JSONDecoder().decode(SyncPullResponse.self, from: Data("{\(base)}".utf8))
        XCTAssertNil(without.totals)
        let with = try JSONDecoder().decode(SyncPullResponse.self,
                                            from: Data("{\(base),\"totals\":{\"habits\":1,\"entries\":2,\"groups\":3}}".utf8))
        XCTAssertEqual(with.totals, SyncTotals(habits: 1, entries: 2, groups: 3))
    }

    // MARK: - Migration from the 1.3.0 schema, on disk

    /// A store written with the 1.3.0 model classes (`Stride130Schema`, below), closed, then opened
    /// with today's models: SwiftData lightweight-migrates it. Every row and field must survive,
    /// and the delivery fields must read as their defaults. An in-memory container proves nothing
    /// here: it is created with the new schema and never migrates.
    func testA130StoreOnDiskOpensUnderTheNewSchemaWithEveryRowIntact() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("Stride.store")
        try Stride130Schema.populate(at: url)

        let before = try StoreSnapshot.read130(at: url)
        XCTAssertEqual(before.habits.count, 6)
        XCTAssertEqual(before.records.count, 40)
        XCTAssertEqual(before.groups.count, 3)

        try assertMigrates(storeAt: url, matching: before)

        // The migrated store takes the new fields and keeps them.
        do {
            let container = try Self.openCurrent(at: url)
            let context = ModelContext(container)
            let counts = try SyncDeliveryMigration.stampMigratedRows(
                in: context, lastSyncTime: SyncTimestamp.string(from: Date().addingTimeInterval(3600)))
            XCTAssertEqual(counts.total, 6 + 40 + 3, "every 1.3.0 row predates a sync an hour from now")
            let habit = try XCTUnwrap(context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.name)])).first)
            habit.hold(.notOwned)
            habit.restoredAt = Date(timeIntervalSince1970: 1_789_493_598.5)
            try context.save()
        }
        do {
            let container = try Self.openCurrent(at: url)
            let context = ModelContext(container)
            let habits = try context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.name)]))
            XCTAssertEqual(habits.first?.activeHold, .notOwned)
            XCTAssertEqual(habits.first?.restoredAt, Date(timeIntervalSince1970: 1_789_493_598.5))
            XCTAssertTrue(try context.fetch(FetchDescriptor<HabitRecord>()).allSatisfy { !$0.isPending })
            // Reopening the migrated store must not have lost anything either.
            XCTAssertEqual(try StoreSnapshot.readCurrent(from: context).withoutDeliveryState, before)
        }
    }

    /// The spec's gate: a populated store copied from a REAL device (Xcode → Devices → download
    /// container; 1.2.3 and 1.3.0 share a schema) must open under the 1.3.1 schema before
    /// submission — fresh simulators prove nothing about live stores. Point
    /// `STRIDE_REAL_STORE_PATH` at the container's `Stride.store` (its `-wal` / `-shm` beside it
    /// are copied too; the original is never opened):
    ///
    ///     TEST_RUNNER_STRIDE_REAL_STORE_PATH=/path/to/AppData/.../Stride.store \
    ///       xcodebuild test -scheme StrideTests -destination platform=macOS \
    ///       -only-testing:StrideTests/SyncDeliveryTests/testARealDeviceStoreOpensUnderTheNewSchema
    ///
    /// (xcodebuild passes `TEST_RUNNER_`-prefixed variables to the test process without the prefix.)
    func testARealDeviceStoreOpensUnderTheNewSchema() throws {
        guard let path = ProcessInfo.processInfo.environment["STRIDE_REAL_STORE_PATH"], !path.isEmpty else {
            throw XCTSkip("""
                No real-device store: set STRIDE_REAL_STORE_PATH (via TEST_RUNNER_STRIDE_REAL_STORE_PATH \
                for xcodebuild) to a Stride.store downloaded from a device running 1.2.3 or 1.3.0. \
                Required before submitting 1.3.1 (DEV-PLAN-1.3.md M2, "Migration test").
                """)
        }
        let source = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "no file at \(path)")

        // Two pristine copies: one read with the 1.3.0 classes (the "before"), one migrated.
        let readCopy = try copyStore(source, into: try makeTempDir())
        let migrateCopy = try copyStore(source, into: try makeTempDir())
        let before = try StoreSnapshot.read130(at: readCopy)
        XCTAssertGreaterThan(before.habits.count, 0, "the store should be a populated one")
        try assertMigrates(storeAt: migrateCopy, matching: before)
        print("Real store migrated: \(before.habits.count) habits, \(before.records.count) records, \(before.groups.count) groups")
    }

    private func copyStore(_ source: URL, into dir: URL) throws -> URL {
        let target = dir.appendingPathComponent(source.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
        }
        return target
    }

    private func assertMigrates(storeAt url: URL, matching before: StoreSnapshot,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try Self.openCurrent(at: url)
        let context = ModelContext(container)
        let after = try StoreSnapshot.readCurrent(from: context)
        XCTAssertEqual(after.withoutDeliveryState, before, "a row or field changed in migration", file: file, line: line)

        let habits = try context.fetch(FetchDescriptor<Habit>())
        let records = try context.fetch(FetchDescriptor<HabitRecord>())
        let groups = try context.fetch(FetchDescriptor<HabitGroup>())
        let rows: [SyncDeliverable] = habits + records + groups
        for row in rows {
            XCTAssertNil(row.syncedAt, file: file, line: line)
            XCTAssertNil(row.syncHoldReason, file: file, line: line)
            XCTAssertNil(row.syncHoldStamp, file: file, line: line)
            XCTAssertFalse(row.needsResend, file: file, line: line)
            XCTAssertNil(row.restoredAt, file: file, line: line)
            XCTAssertTrue(row.isPending, "a migrated row is never-delivered until the migrated-rows rule",
                          file: file, line: line)
        }
    }

    static func openCurrent(at url: URL) throws -> ModelContainer {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
    }
}

// MARK: - Store snapshots

/// Every stored field of every row, in plain values, so a store read with the 1.3.0 classes and
/// the same store read after migration compare with one `==`.
struct StoreSnapshot: Equatable {
    struct HabitRow: Equatable {
        var id: UUID, name: String, emoji: String, colorHex: String, createdAt: Date
        var isArchived: Bool, sortOrder: Double, reminderEnabled: Bool, reminderHour: Int
        var reminderMinute: Int, note: String?, updatedAt: Date?, kind: String, targetValue: Double
        var unit: String?, scheduleKind: String, timesPerWeek: Int, activeDaysMask: Int
        var groupId: UUID?
        /// The relationship, as ids: which records hang off this habit.
        var recordIds: [UUID]
    }
    struct RecordRow: Equatable {
        var id: UUID, date: Date, note: String?, updatedAt: Date?, value: Double
    }
    struct GroupRow: Equatable {
        var id: UUID, name: String, colorHex: String, sortOrder: Double, createdAt: Date, updatedAt: Date?
    }
    struct Delivery: Equatable {
        var syncedAt: Date?
        var syncHoldReason: String?
        var syncHoldStamp: Date?
        var needsResend: Bool
        var restoredAt: Date?
    }

    var habits: [HabitRow]
    var records: [RecordRow]
    var groups: [GroupRow]
    /// Only filled when read with the current classes; empty for 1.3.0.
    var delivery: [UUID: Delivery] = [:]

    var withoutDeliveryState: StoreSnapshot {
        var copy = self
        copy.delivery = [:]
        return copy
    }

    /// Sorted by id (then date) so the fetch order of either schema does not matter. Ids are not
    /// unique in SwiftData (no constraint), hence the tiebreak.
    fileprivate static func sorted(_ habits: [HabitRow], _ records: [RecordRow], _ groups: [GroupRow]) -> StoreSnapshot {
        StoreSnapshot(
            habits: habits.map { var h = $0; h.recordIds.sort { $0.uuidString < $1.uuidString }; return h }
                .sorted { ($0.id.uuidString, $0.name) < ($1.id.uuidString, $1.name) },
            records: records.sorted { ($0.id.uuidString, $0.date) < ($1.id.uuidString, $1.date) },
            groups: groups.sorted { ($0.id.uuidString, $0.name) < ($1.id.uuidString, $1.name) })
    }

    @MainActor
    static func read130(at url: URL) throws -> StoreSnapshot {
        let schema = Schema([Stride130Schema.Habit.self, Stride130Schema.HabitRecord.self, Stride130Schema.HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        let habits = try context.fetch(FetchDescriptor<Stride130Schema.Habit>()).map {
            HabitRow(id: $0.id, name: $0.name, emoji: $0.emoji, colorHex: $0.colorHex, createdAt: $0.createdAt,
                     isArchived: $0.isArchived, sortOrder: $0.sortOrder, reminderEnabled: $0.reminderEnabled,
                     reminderHour: $0.reminderHour, reminderMinute: $0.reminderMinute, note: $0.note,
                     updatedAt: $0.updatedAt, kind: $0.kind, targetValue: $0.targetValue, unit: $0.unit,
                     scheduleKind: $0.scheduleKind, timesPerWeek: $0.timesPerWeek,
                     activeDaysMask: $0.activeDaysMask, groupId: $0.groupId, recordIds: $0.records.map(\.id))
        }
        let records = try context.fetch(FetchDescriptor<Stride130Schema.HabitRecord>()).map {
            RecordRow(id: $0.id, date: $0.date, note: $0.note, updatedAt: $0.updatedAt, value: $0.value)
        }
        let groups = try context.fetch(FetchDescriptor<Stride130Schema.HabitGroup>()).map {
            GroupRow(id: $0.id, name: $0.name, colorHex: $0.colorHex, sortOrder: $0.sortOrder,
                     createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        return sorted(habits, records, groups)
    }

    @MainActor
    static func readCurrent(from context: ModelContext) throws -> StoreSnapshot {
        var delivery: [UUID: Delivery] = [:]
        func note(_ row: SyncDeliverable) {
            delivery[row.id] = Delivery(syncedAt: row.syncedAt, syncHoldReason: row.syncHoldReason,
                                        syncHoldStamp: row.syncHoldStamp, needsResend: row.needsResend,
                                        restoredAt: row.restoredAt)
        }
        let habits = try context.fetch(FetchDescriptor<Habit>()).map { h -> HabitRow in
            note(h)
            return HabitRow(id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, createdAt: h.createdAt,
                            isArchived: h.isArchived, sortOrder: h.sortOrder, reminderEnabled: h.reminderEnabled,
                            reminderHour: h.reminderHour, reminderMinute: h.reminderMinute, note: h.note,
                            updatedAt: h.updatedAt, kind: h.kind, targetValue: h.targetValue, unit: h.unit,
                            scheduleKind: h.scheduleKind, timesPerWeek: h.timesPerWeek,
                            activeDaysMask: h.activeDaysMask, groupId: h.groupId, recordIds: h.records.map(\.id))
        }
        let records = try context.fetch(FetchDescriptor<HabitRecord>()).map { r -> RecordRow in
            note(r)
            return RecordRow(id: r.id, date: r.date, note: r.note, updatedAt: r.updatedAt, value: r.value)
        }
        let groups = try context.fetch(FetchDescriptor<HabitGroup>()).map { g -> GroupRow in
            note(g)
            return GroupRow(id: g.id, name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder,
                            createdAt: g.createdAt, updatedAt: g.updatedAt)
        }
        var snapshot = sorted(habits, records, groups)
        snapshot.delivery = delivery
        return snapshot
    }
}

// MARK: - The 1.3.0 schema

/// The stored properties of `Shared/Habit.swift` as it shipped in 1.3.0 (`git show
/// release/1.3.0:Shared/Habit.swift`; 1.2.3 is the same schema), storage only. It is a frozen
/// snapshot on purpose: it must NOT follow the live models — its job is to write a store the way
/// the installed base has one. Entity names come from the class names, so these write `Habit`,
/// `HabitRecord` and `HabitGroup` entities exactly as the app did.
enum Stride130Schema {
    @Model
    final class Habit {
        var id: UUID
        var name: String
        var emoji: String
        var colorHex: String
        var createdAt: Date
        var isArchived: Bool
        var sortOrder: Double
        var reminderEnabled: Bool
        var reminderHour: Int
        var reminderMinute: Int
        var note: String?
        var updatedAt: Date?
        var kind: String = "binary"
        var targetValue: Double = 1
        var unit: String?
        var scheduleKind: String = "daily"
        var timesPerWeek: Int = 7
        var activeDaysMask: Int = 127
        var groupId: UUID?
        @Relationship(deleteRule: .cascade) var records: [HabitRecord]

        init(name: String, emoji: String = "⭐", colorHex: String = "#34C759") {
            self.id = UUID()
            self.name = name
            self.emoji = emoji
            self.colorHex = colorHex
            self.createdAt = Date()
            self.isArchived = false
            self.sortOrder = Date().timeIntervalSince1970
            self.reminderEnabled = false
            self.reminderHour = 20
            self.reminderMinute = 0
            self.note = nil
            self.updatedAt = Date()
            self.kind = "binary"
            self.targetValue = 1
            self.unit = nil
            self.scheduleKind = "daily"
            self.timesPerWeek = 7
            self.activeDaysMask = 127
            self.groupId = nil
            self.records = []
        }
    }

    @Model
    final class HabitRecord {
        var id: UUID
        var date: Date
        var note: String?
        var updatedAt: Date?
        var value: Double = 1

        init(date: Date, note: String? = nil, value: Double = 1) {
            self.id = UUID()
            self.date = date
            self.note = note
            self.updatedAt = Date()
            self.value = value
        }
    }

    @Model
    final class HabitGroup {
        var id: UUID
        var name: String
        var colorHex: String
        var sortOrder: Double
        var createdAt: Date
        var updatedAt: Date?

        init(name: String, colorHex: String = "#34C759", sortOrder: Double = 0) {
            self.id = UUID()
            self.name = name
            self.colorHex = colorHex
            self.sortOrder = sortOrder
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    /// Writes a populated 1.3.0 store at `url` and closes it: every optional both set and nil,
    /// sub-millisecond stamps (1.3.0 never floored), count and binary habits, grouped and not, a
    /// pre-v2 habit with no `updatedAt`, records with notes and without `updatedAt`, and a
    /// lowercase-origin id (what a server-made row looks like after the reconciler parsed it).
    @MainActor
    static func populate(at url: URL) throws {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)

        let groups = ["Health", "Work", "Mind"].enumerated().map { i, name -> HabitGroup in
            let g = HabitGroup(name: name, colorHex: ["#FF3B30", "#007AFF", "#AF52DE"][i], sortOrder: Double(i))
            if i == 2 { g.updatedAt = nil }
            context.insert(g)
            return g
        }

        let day = 86_400.0
        let base = Date(timeIntervalSince1970: 1_780_000_000.123_456)
        var recordCount = 0
        for i in 0..<6 {
            let h = Habit(name: "Habit \(i)", emoji: ["💧", "📚", "🏃", "🧘", "✍️", "⭐"][i], colorHex: "#34C75\(i)")
            h.createdAt = base.addingTimeInterval(Double(i) * 3.000_7)
            h.updatedAt = i == 0 ? nil : base.addingTimeInterval(Double(i) * 1_000.000_3)
            h.isArchived = i == 5
            h.sortOrder = Double(i) + 0.5
            h.reminderEnabled = i.isMultiple(of: 2)
            h.reminderHour = 7 + i
            h.reminderMinute = 5 * i
            h.note = i == 3 ? "note with ünïcödé ✓" : nil
            if i == 1 {
                h.kind = "count"; h.targetValue = 8; h.unit = "glasses"
            }
            if i == 2 { h.scheduleKind = "timesPerWeek"; h.timesPerWeek = 3 }
            if i == 4 { h.scheduleKind = "specificDays"; h.activeDaysMask = 0b0101010 }
            h.groupId = i < 3 ? groups[i].id : nil
            if i == 4 { h.id = UUID(uuidString: "0e7b1c6a-8f7d-4c1e-9a55-2f6c3d4e5f60")! }
            context.insert(h)

            let n = [10, 8, 7, 6, 5, 4][i]
            for d in 0..<n {
                let dayKey = HabitCalendar.dayKey(for: base.addingTimeInterval(-Double(d) * day))
                let r = HabitRecord(date: dayKey, note: d == 1 ? "day \(d)" : nil, value: i == 1 ? Double(d % 9) : 1)
                if d.isMultiple(of: 3) { r.updatedAt = nil }
                h.records.append(r)
                recordCount += 1
            }
        }
        precondition(recordCount == 40)
        try context.save()
    }
}
