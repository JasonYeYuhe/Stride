import XCTest
import SwiftData
import Foundation

/// Tests for `HabitCheckIn`, the single check-in routine now shared by the list, the widget,
/// the watch and Siri. The two bugs pinned here lived in the widget/watch and Siri copies:
/// a tap that deleted a partially logged count habit's day, and a "complete" that added a
/// second record for the same day.
@MainActor
final class HabitCheckInTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let today = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 16))!

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    private func countHabit(target: Double, logged: Double?) throws -> Habit {
        let habit = Habit(name: "Drink Water")
        habit.kind = HabitKind.count.rawValue
        habit.targetValue = target
        context.insert(habit)
        if let logged { habit.records.append(HabitRecord(date: today, value: logged)) }
        try context.save()
        return habit
    }

    private func recordsToday(_ habit: Habit) -> [HabitRecord] {
        habit.records.filter { HabitCalendar.record($0.date, isOnSameDayAs: today) }
    }

    // MARK: - Yes/no habits

    func testBinaryTapChecksThenUnchecks() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)

        let first = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(first, .init(isCompleted: true, loggedValue: 1))
        try context.save()
        let recordID = try XCTUnwrap(habit.record(on: today)).id.uuidString

        let second = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(second, .init(deletedRecordIDs: [recordID], isCompleted: false, loggedValue: 0))
        try context.save()

        // Re-fetch before asserting, as the app always does (@Query, and a fresh ModelContext per
        // widget/Siri invocation). `records` has no inverse relationship, so the in-memory array on
        // an already-loaded Habit keeps the deleted object until the habit is fetched again —
        // measured: right after the save `habit.records.count` was still 1, after the fetch 0.
        // This is why `tap` states its result for a deletion instead of recomputing it.
        let refetched = try XCTUnwrap(context.fetch(FetchDescriptor<Habit>()).first)
        XCTAssertNil(refetched.record(on: today), "the record must really be gone from the store")

        // And a third tap checks it again — it must not 'delete' a ghost of the old record.
        let third = HabitCheckIn.tap(refetched, on: today, in: context)
        XCTAssertEqual(third, .init(isCompleted: true, loggedValue: 1))
    }

    // MARK: - Count habits (the widget / watch bug)

    /// "Drink Water" at 6 of 8. The widget drew this as an empty circle and a tap DELETED the
    /// day — six units gone, and a tombstone queued to delete them on every other device.
    func testCountTapOnAPartialDayAddsOneAndNeverDeletes() throws {
        let habit = try countHabit(target: 8, logged: 6)
        let recordID = try XCTUnwrap(habit.record(on: today)).id

        let result = HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()

        XCTAssertTrue(result.deletedRecordIDs.isEmpty, "a count tap must never delete, or queue a tombstone")
        XCTAssertEqual(result.loggedValue, 7)
        XCTAssertFalse(result.isCompleted)
        XCTAssertEqual(recordsToday(habit).count, 1)
        XCTAssertEqual(habit.record(on: today)?.id, recordID, "the same record gains the unit")
    }

    func testCountTapOnAnEmptyDayStartsAtOne() throws {
        let habit = try countHabit(target: 8, logged: nil)
        let result = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(result, .init(isCompleted: false, loggedValue: 1))
        XCTAssertEqual(recordsToday(habit).count, 1)
    }

    func testCountTapReachingTheTargetCompletesTheDay() throws {
        let habit = try countHabit(target: 3, logged: 2)
        XCTAssertTrue(HabitCheckIn.tap(habit, on: today, in: context).isCompleted)
    }

    func testRepeatedCountTapsKeepExactlyOneRecordForTheDay() throws {
        let habit = try countHabit(target: 8, logged: nil)
        for _ in 0..<10 { HabitCheckIn.tap(habit, on: today, in: context) }
        try context.save()
        XCTAssertEqual(recordsToday(habit).count, 1)
        XCTAssertEqual(habit.loggedValue(on: today), 10)
    }

    // MARK: - "Complete a habit" (the Siri bug)

    /// "Drink Water" at 5 of 8, then "Hey Siri, complete Drink Water". The intent appended a
    /// second record for the same day; the app then showed 5/8 or 1/8 at random.
    func testMarkDoneOnAPartialCountDayAddsToTheSameRecord() throws {
        let habit = try countHabit(target: 8, logged: 5)

        let result = try XCTUnwrap(HabitCheckIn.markDone(habit, on: today, in: context))
        try context.save()

        XCTAssertEqual(result.loggedValue, 6)
        XCTAssertEqual(recordsToday(habit).count, 1, "never a second record for the same day")
    }

    func testMarkDoneOnACompleteCountDayChangesNothing() throws {
        let habit = try countHabit(target: 8, logged: 8)
        XCTAssertNil(HabitCheckIn.markDone(habit, on: today, in: context))
        XCTAssertEqual(habit.loggedValue(on: today), 8)
    }

    /// Siri must never un-check a habit the way a second tap does.
    func testMarkDoneOnACheckedBinaryHabitDoesNotUncheckIt() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        habit.records.append(HabitRecord(date: today))
        try context.save()

        XCTAssertNil(HabitCheckIn.markDone(habit, on: today, in: context))
        XCTAssertNotNil(habit.record(on: today))
    }

    func testMarkDoneChecksAnUncheckedBinaryHabit() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        let result = try XCTUnwrap(HabitCheckIn.markDone(habit, on: today, in: context))
        XCTAssertTrue(result.isCompleted)
        XCTAssertEqual(recordsToday(habit).count, 1)
    }

    func testTapsOnDifferentDaysAreIndependent() throws {
        let habit = try countHabit(target: 8, logged: 4)
        let yesterday = HabitCalendar.utc.date(byAdding: .day, value: -1, to: today)!
        HabitCheckIn.tap(habit, on: yesterday, in: context)
        XCTAssertEqual(habit.loggedValue(on: today), 4)
        XCTAssertEqual(habit.loggedValue(on: yesterday), 1)
    }

    // MARK: - A deleted record still listed in habit.records (the ghost)

    /// Every record of this habit that the STORE holds for today, asked through a fresh context
    /// so nothing this test's context remembers can answer for it.
    private func storedToday(_ habit: Habit) throws -> [HabitRecord] {
        let id = habit.id
        let fresh = ModelContext(container)
        let stored = try fresh.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first
        return stored?.records.filter { HabitCalendar.record($0.date, isOnSameDayAs: today) } ?? []
    }

    /// Uncheck, save, check again — on the SAME Habit object, as TodayView's row does when the
    /// second tap comes before anything refetches the habit. Measured before the fix: after the
    /// save `habit.records` still listed the deleted record, so the re-tap "deleted" it again,
    /// answered unchecked, handed back the old id for a second tombstone, and the store kept no
    /// record — the check-in the user just made was silently not there.
    func testABinaryReTapAfterASavedUntapChecksTheDayAgain() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()

        let untap = HabitCheckIn.tap(habit, on: today, in: context)
        let untappedID = try XCTUnwrap(untap.deletedRecordIDs.first)
        try context.save()
        XCTAssertTrue(try storedToday(habit).isEmpty)

        let retap = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(retap, .init(isCompleted: true, loggedValue: 1),
                       "the re-tap checks the day; it must not delete the old record a second time")
        try context.save()

        let stored = try storedToday(habit)
        XCTAssertEqual(stored.count, 1, "the re-tap's check-in is in the store")
        XCTAssertNotEqual(stored.first?.id.uuidString, untappedID, "a new record, not the deleted one")

        // And the next tap unchecks THAT record.
        let third = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(third.deletedRecordIDs, stored.map(\.id.uuidString))
        try context.save()
        XCTAssertTrue(try storedToday(habit).isEmpty)
    }

    /// A count day taken to zero by "remove one" (TodayView deletes the record at 1), saved, then
    /// "+1". Before the fix the unit went onto the deleted record — nothing saved it — and the
    /// tap reported the old value plus one.
    func testACountTapAfterTheDayWasRemovedStartsAgainAtOne() throws {
        let habit = try countHabit(target: 8, logged: 1)
        let removed = try XCTUnwrap(habit.record(on: today))
        let removedID = removed.id
        context.delete(removed)   // TodayView.decrementCount at 1 / resetCount
        try context.save()

        let result = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(result, .init(isCompleted: false, loggedValue: 1))
        try context.save()

        let stored = try storedToday(habit)
        XCTAssertEqual(stored.map(\.value), [1], "the unit is in the store, on one record")
        XCTAssertNotEqual(stored.first?.id, removedID)
    }

    /// Same after a reset at 6 of 8, where the ghost's stale value is far from the truth.
    func testACountTapAfterAResetReportsTheNewValueNotTheOldOne() throws {
        let habit = try countHabit(target: 8, logged: 6)
        context.delete(try XCTUnwrap(habit.record(on: today)))
        try context.save()

        let result = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(result.loggedValue, 1, "not 7: the six units were reset")
        try context.save()
        XCTAssertEqual(try storedToday(habit).map(\.value), [1])
    }

    /// Siri after an untap on the same object: the ghost read as "already done", so nothing was
    /// checked.
    func testMarkDoneAfterASavedUntapChecksTheDay() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()
        HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()

        let result = try XCTUnwrap(HabitCheckIn.markDone(habit, on: today, in: context),
                                   "the day is not done, so markDone must act")
        XCTAssertTrue(result.isCompleted)
        try context.save()
        XCTAssertEqual(try storedToday(habit).count, 1)
    }

    /// The widget's pattern: its intent untaps in a context of its own and saves; the app's
    /// context still holds the Habit it loaded before. There the ghost looks entirely live (in a
    /// context, not deleted — measured), so only the store can tell. The app's next tap acts on
    /// what the store holds: it checks the day, instead of "deleting" a record that is gone and
    /// queueing its tombstone a second time.
    func testAnUntapSavedInTheWidgetsContextDoesNotLeaveAGhostForTheApp() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()
        XCTAssertNotNil(habit.record(on: today))   // loaded here, as the app's list has it

        let widget = ModelContext(container)
        let habitID = habit.id
        let widgetHabit = try XCTUnwrap(widget.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == habitID })).first)
        XCTAssertEqual(HabitCheckIn.tap(widgetHabit, on: today, in: widget).deletedRecordIDs.count, 1)
        try widget.save()

        let appTap = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(appTap, .init(isCompleted: true, loggedValue: 1))
        try context.save()
        XCTAssertEqual(try storedToday(habit).count, 1)
    }

    /// Widget to widget: each intent opens a fresh context, so an untap then a tap check the day.
    func testWidgetUntapThenTapInFreshContextsChecksTheDay() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()
        let habitID = habit.id

        func widgetTap() throws -> HabitCheckIn.Result {
            let widget = ModelContext(container)
            let found = try XCTUnwrap(widget.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == habitID })).first)
            let result = HabitCheckIn.tap(found, on: today, in: widget)
            try widget.save()
            return result
        }
        XCTAssertFalse(try widgetTap().isCompleted)
        XCTAssertEqual(try widgetTap(), .init(isCompleted: true, loggedValue: 1))
        XCTAssertEqual(try storedToday(habit).count, 1)
    }

    // MARK: - A reminder's Mark Done / Add 1 (1.4.0, RELEASE-1.4.0.md D4)

    /// Mark Done on an unchecked yes/no habit checks the day.
    func testFromReminderChecksAnUncheckedBinaryHabit() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        try context.save()

        let result = try XCTUnwrap(HabitCheckIn.fromReminder(habit, on: today, in: context))
        try context.save()

        XCTAssertEqual(result, .init(isCompleted: true, loggedValue: 1))
        XCTAssertEqual(try storedToday(habit).count, 1)
    }

    /// Mark Done on a day already checked — in the app, the widget or another device before the
    /// banner was tapped — changes nothing: no second record, and above all no un-check.
    func testFromReminderOnACheckedBinaryHabitChangesNothing() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        habit.records.append(HabitRecord(date: today))
        try context.save()
        let recordID = try XCTUnwrap(habit.record(on: today)).id

        XCTAssertNil(HabitCheckIn.fromReminder(habit, on: today, in: context))
        try context.save()

        XCTAssertEqual(try storedToday(habit).map(\.id), [recordID])
    }

    /// Add 1 on "Drink Water" at 3 of 8: 4 of 8, the same record.
    func testFromReminderAddsOneToACountHabit() throws {
        let habit = try countHabit(target: 8, logged: 3)
        let recordID = try XCTUnwrap(habit.record(on: today)).id

        let result = try XCTUnwrap(HabitCheckIn.fromReminder(habit, on: today, in: context))
        try context.save()

        XCTAssertEqual(result, .init(isCompleted: false, loggedValue: 4))
        XCTAssertEqual(try storedToday(habit).map(\.id), [recordID])
        XCTAssertEqual(try storedToday(habit).first?.value, 4)
    }

    /// The button says "Add 1", so it adds one past the target too — unlike Siri's "complete",
    /// which stops at the target. And an empty day starts at one.
    func testFromReminderAddsPastTheTargetAndStartsAnEmptyDay() throws {
        let full = try countHabit(target: 8, logged: 8)
        XCTAssertEqual(HabitCheckIn.fromReminder(full, on: today, in: context)?.loggedValue, 9)
        let empty = try countHabit(target: 8, logged: nil)
        XCTAssertEqual(HabitCheckIn.fromReminder(empty, on: today, in: context),
                       .init(isCompleted: false, loggedValue: 1))
    }

    /// The design review's data-loss case ("stale-category-addone-untoggles-binary"): a count
    /// habit at 3 units is edited to yes/no — it now reads as done — and its old banner still
    /// offers "Add 1". The write follows the CURRENT kind, so the day is left exactly as it is: no
    /// deletion, no tombstone, the units kept. Through `tap`, as a router carrying the button's kind
    /// would have done, the record and its units were deleted on every device.
    func testAStaleAddOneOnAHabitThatBecameYesNoDeletesNothing() throws {
        let habit = try countHabit(target: 8, logged: 3)
        let recordID = try XCTUnwrap(habit.record(on: today)).id
        habit.habitKind = .binary
        try context.save()

        XCTAssertNil(HabitCheckIn.fromReminder(habit, on: today, in: context))
        try context.save()

        let stored = try storedToday(habit)
        XCTAssertEqual(stored.map(\.id), [recordID])
        XCTAssertEqual(stored.first?.value, 3)
    }

    /// The other way round: a stale "Mark Done" on a habit that became a count habit adds one unit.
    func testAStaleMarkDoneOnAHabitThatBecameCountAddsOne() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        habit.records.append(HabitRecord(date: today))
        habit.habitKind = .count
        habit.targetValue = 3
        try context.save()

        XCTAssertEqual(HabitCheckIn.fromReminder(habit, on: today, in: context)?.loggedValue, 2)
    }

    /// An archived habit's reminders were removed when it was archived; a banner left behind writes
    /// nothing.
    func testFromReminderOnAnArchivedHabitWritesNothing() throws {
        let habit = Habit(name: "Meditate")
        habit.isArchived = true
        context.insert(habit)
        try context.save()

        XCTAssertNil(HabitCheckIn.fromReminder(habit, on: today, in: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try storedToday(habit).count, 0)
    }

    /// End to end with the resolver: the default 20:00 reminder in New York, delivered at exactly
    /// 2026-07-16T00:00:00Z, checks the 15th and leaves the 16th empty — the review's blocker.
    func testTheTwentyHundredEasternReminderChecksItsOwnDay() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let delivered = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 7, day: 16))!
        let fifteenth = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let habit = Habit(name: "Meditate")
        context.insert(habit)

        let day = ReminderDay.resolve(userInfo: [:], deliveredAt: delivered, respondedAt: delivered.addingTimeInterval(30),
                                      calendar: newYork)
        XCTAssertEqual(day, fifteenth)
        XCTAssertNotNil(HabitCheckIn.fromReminder(habit, on: day, in: context))
        try context.save()

        XCTAssertEqual(habit.records.map(\.date), [fifteenth])
        XCTAssertNil(habit.record(on: delivered), "tomorrow untouched")
    }
}

/// The D4 setters (RELEASE-1.4.1.md D4, D7, Data safety 1 and 2; 2026-10-15 decision 7): every
/// setter on an empty day, one record, a ghost, a record another context deleted, and same-day
/// duplicates; no-ops that leave the stamp alone; and the confirmation on every path that would
/// delete a note. Host-less: what HabitEntryCommit adds (the save, its undo, the tombstones after
/// it) is StrideAppTests/HabitEntryCommitTests, apart from the journal itself (bottom).
@MainActor
final class HabitCheckInSetterTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let today = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 16))!

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: Helpers

    /// A saved habit whose day `today` holds `records` (in that insertion order).
    private func habit(_ kind: HabitKind = .binary, target: Double = 8, records: [HabitRecord] = []) throws -> Habit {
        let habit = Habit(name: kind == .count ? "Drink Water" : "Meditate")
        habit.habitKind = kind
        if kind == .count { habit.targetValue = target }
        context.insert(habit)
        for record in records { habit.records.append(record) }
        try context.save()
        return habit
    }

    private func record(value: Double = 1, note: String? = nil, stampOffset: TimeInterval = 0) -> HabitRecord {
        let record = HabitRecord(date: today, note: note, value: value)
        record.updatedAt = SyncTimestamp.floorToMillisecond(Date(timeIntervalSince1970: 1_790_000_000 + stampOffset))
        return record
    }

    /// The habit's records for `today` as the STORE holds them, through a fresh context.
    private func stored(_ habit: Habit) throws -> [HabitRecord] {
        let id = habit.id
        let fresh = ModelContext(container)
        let found = try fresh.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first
        return (found?.records ?? []).filter { HabitCalendar.record($0.date, isOnSameDayAs: today) }
    }

    private struct NotWritten: Error, CustomStringConvertible {
        let change: HabitCheckIn.Change
        var description: String { "expected a write, got \(change)" }
    }

    /// The setter's write; a thrown error (failing the test) when it wrote nothing.
    private func written(_ change: HabitCheckIn.Change) throws -> HabitCheckIn.Written {
        guard case .changed(let written) = change else { throw NotWritten(change: change) }
        return written
    }

    // MARK: No record

    func testSettersOnAnEmptyDay() throws {
        let yesNo = try habit()
        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setNote("a note", on: today, of: yesNo, in: context), .noChange,
                       "never a note-only yes/no record (D7)")
        XCTAssertEqual(HabitCheckIn.setChecked(nil, on: today, of: yesNo, in: context), .noChange)
        XCTAssertFalse(context.hasChanges)

        let checked = try written(HabitCheckIn.setChecked(true, on: today, of: yesNo, in: context))
        XCTAssertEqual(checked, .init(deletedRecordIDs: [], isCompleted: true, loggedValue: 1, isCheckIn: true))
        try context.save()
        XCTAssertEqual(try stored(yesNo).map(\.value), [1])

        let count = try habit(.count)
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: count, in: context), .noChange, "never a value-0 record")
        XCTAssertEqual(HabitCheckIn.setValue(-3, on: today, of: count, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(.nan, on: today, of: count, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(.infinity, on: today, of: count, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setNote("x", on: today, of: count, in: context), .noChange)
        let three = try written(HabitCheckIn.setValue(3, on: today, of: count, in: context))
        XCTAssertEqual(three, .init(deletedRecordIDs: [], isCompleted: false, loggedValue: 3, isCheckIn: true))
        try context.save()
        XCTAssertEqual(try stored(count).map(\.value), [3])
    }

    // MARK: One record

    func testANoOpLeavesTheStampAlone() throws {
        let yesNo = try habit(records: [record(note: "felt good")])
        let count = try habit(.count, records: [record(value: 5, note: "kept")])
        let yesNoStamp = try XCTUnwrap(yesNo.records.first?.updatedAt)
        let countStamp = try XCTUnwrap(count.records.first?.updatedAt)

        XCTAssertEqual(HabitCheckIn.setChecked(true, on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(1, on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setNote("felt good", on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setNote(nil, on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(5, on: today, of: count, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(nil, on: today, of: count, in: context), .noChange)
        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: count, in: context), .noChange,
                       "5 of 8 is already not checked: its units are left alone")
        XCTAssertEqual(HabitCheckIn.setNote("kept", on: today, of: count, in: context), .noChange)

        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(yesNo.records.first?.updatedAt, yesNoStamp)
        XCTAssertEqual(count.records.first?.updatedAt, countStamp)
    }

    /// An edit moves the stamp, so the row is pending again (SyncDelivery.swift `isPending`).
    func testAnEditChangesTheStampAndMakesTheRowPending() throws {
        let count = try habit(.count, records: [record(value: 2)])
        let kept = try XCTUnwrap(count.records.first)
        kept.acknowledge(sentStamp: kept.stamp)
        try context.save()
        XCTAssertFalse(kept.isPending)
        let before = kept.stamp

        let four = try written(HabitCheckIn.setValue(4, on: today, of: count, in: context))
        XCTAssertEqual(four, .init(deletedRecordIDs: [], isCompleted: false, loggedValue: 4, isCheckIn: true))
        XCTAssertGreaterThan(kept.stamp, before)
        XCTAssertTrue(kept.isPending)
        try context.save()

        kept.acknowledge(sentStamp: kept.stamp)
        let noted = try written(HabitCheckIn.setNote("after lunch", on: today, of: count, in: context))
        XCTAssertFalse(noted.isCheckIn, "a note is not a check-in")
        XCTAssertTrue(kept.isPending)
        try context.save()
        XCTAssertEqual(try stored(count).map(\.note), ["after lunch"])

        let lower = try written(HabitCheckIn.setValue(3, on: today, of: count, in: context))
        XCTAssertFalse(lower.isCheckIn, "a lower value is not a check-in")
        let cleared = try written(HabitCheckIn.setNote("", on: today, of: count, in: context))
        XCTAssertEqual(cleared.loggedValue, 3)
        try context.save()
        XCTAssertEqual(try stored(count).map(\.note), [nil])
        XCTAssertEqual(try stored(count).map(\.id), [kept.id], "the same record throughout")
    }

    func testUncheckingDeletesTheRecordAndReturnsItsID() throws {
        let yesNo = try habit(records: [record()])
        let id = try XCTUnwrap(yesNo.records.first).id.uuidString
        XCTAssertEqual(try written(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context)),
                       .init(deletedRecordIDs: [id], isCompleted: false, loggedValue: 0, isCheckIn: false))
        try context.save()
        XCTAssertTrue(try stored(yesNo).isEmpty)

        let count = try habit(.count, records: [record(value: 8)])
        let countID = try XCTUnwrap(count.records.first).id.uuidString
        XCTAssertEqual(try written(HabitCheckIn.setChecked(false, on: today, of: count, in: context)).deletedRecordIDs,
                       [countID], "a complete count day un-checked is deleted")
        try context.save()
        XCTAssertTrue(try stored(count).isEmpty)
    }

    func testCheckingACountHabitRaisesItToTheTargetAndNeverLowersIt() throws {
        let count = try habit(.count, records: [record(value: 3)])
        XCTAssertEqual(try written(HabitCheckIn.setChecked(true, on: today, of: count, in: context)).loggedValue, 8)
        let over = try habit(.count, records: [record(value: 11)])
        XCTAssertEqual(HabitCheckIn.setChecked(true, on: today, of: over, in: context), .noChange)
    }

    // MARK: Deleting a noted check-in asks first (D7), on every path

    func testDeletingANotedRecordNeedsConfirmationOnEveryPath() throws {
        let yesNo = try habit(records: [record(note: "ran in the rain")])
        let count = try habit(.count, records: [record(value: 1, note: "one glass, at last")])

        // Today's toggle and History's un-check.
        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context), .needsConfirmation(.removeNote))
        // The stepper to 0 and Today's decrement at 1.
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: count, in: context), .needsConfirmation(.removeNote))
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: yesNo, in: context), .needsConfirmation(.removeNote))
        // Reset (Today's resetCount is setValue(0)) on a day well past 1.
        let full = try habit(.count, records: [record(value: 8, note: "all eight")])
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: full, in: context), .needsConfirmation(.removeNote))
        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: full, in: context), .needsConfirmation(.removeNote))
        // The widget's tap on a noted yes/no row: it cannot ask, so it writes nothing.
        let tap = HabitCheckIn.tap(yesNo, on: today, in: context)
        XCTAssertEqual(tap, .init(isCompleted: true, loggedValue: 1, needsConfirmation: .removeNote))
        XCTAssertFalse(context.hasChanges, "nothing was written on any path")

        // Confirmed, the delete goes ahead.
        let id = try XCTUnwrap(yesNo.records.first).id.uuidString
        XCTAssertEqual(try written(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context, confirmed: .removeNote)).deletedRecordIDs,
                       [id])
        // A confirmation for something else is not this one.
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: count, in: context, confirmed: .combineNotes),
                       .needsConfirmation(.removeNote))
        XCTAssertEqual(try written(HabitCheckIn.setValue(0, on: today, of: count, in: context, confirmed: .removeNote)).loggedValue, 0)
        try context.save()
        XCTAssertTrue(try stored(yesNo).isEmpty)
        XCTAssertTrue(try stored(count).isEmpty)
        XCTAssertEqual(try stored(full).map(\.note), ["all eight"])
    }

    /// A decrement above 1 keeps the record and its note: no question.
    func testANotedCountDaySteppedDownButNotToZeroAsksNothing() throws {
        let count = try habit(.count, records: [record(value: 3, note: "kept")])
        XCTAssertEqual(try written(HabitCheckIn.setValue(2, on: today, of: count, in: context)).loggedValue, 2)
        XCTAssertEqual(count.records.first?.note, "kept")
    }

    // MARK: Ghosts and another context's deletion

    /// Deleted and saved in this context: the Habit still lists it, with no context.
    func testSettersOnAGhostActOnTheStore() throws {
        let yesNo = try habit(records: [record()])
        let ghost = try XCTUnwrap(yesNo.records.first)
        let ghostID = ghost.id
        context.delete(ghost)
        try context.save()
        XCTAssertTrue(yesNo.records.contains { $0 === ghost }, "the ghost is still listed")

        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context), .noChange,
                       "no second deletion of the ghost, no second tombstone")
        XCTAssertEqual(HabitCheckIn.setNote("x", on: today, of: yesNo, in: context), .noChange)
        XCTAssertEqual(try written(HabitCheckIn.setChecked(true, on: today, of: yesNo, in: context)).deletedRecordIDs, [])
        try context.save()
        let stored = try stored(yesNo)
        XCTAssertEqual(stored.count, 1, "setChecked on a ghost creates a fresh record")
        XCTAssertNotEqual(stored.first?.id, ghostID)

        let count = try habit(.count, records: [record(value: 6)])
        let countGhost = try XCTUnwrap(count.records.first)
        context.delete(countGhost)
        try context.save()
        XCTAssertEqual(try written(HabitCheckIn.setValue(2, on: today, of: count, in: context)).loggedValue, 2,
                       "a fresh record at the value asked, not the ghost's 6 + anything")
        try context.save()
        XCTAssertEqual(try self.stored(count).map(\.value), [2])
    }

    /// The widget's pattern, without the app ever having read the record: the app's context
    /// loaded the habit and its records as faults, the widget deleted the record and saved in a
    /// context of its own. Any read of the record's date there would fault (W1, "Crash safety");
    /// every setter asks the store first, so none crashes, and each acts on what the store holds.
    func testARecordDeletedByAnotherContextNeitherCrashesNorCounts() throws {
        let seeded = try habit(records: [record()])
        let countSeeded = try habit(.count, records: [record(value: 4)])
        let ids = [seeded.id, countSeeded.id]

        let app = ModelContext(container)
        let appHabits = try app.fetch(FetchDescriptor<Habit>(predicate: #Predicate { ids.contains($0.id) }))
        let yesNo = try XCTUnwrap(appHabits.first { $0.id == seeded.id })
        let count = try XCTUnwrap(appHabits.first { $0.id == countSeeded.id })
        XCTAssertEqual(yesNo.records.count + count.records.count, 2)   // faults; no attribute read

        let widget = ModelContext(container)
        for habit in try widget.fetch(FetchDescriptor<Habit>()) {
            for record in habit.records { widget.delete(record) }
        }
        try widget.save()

        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: app), .noChange)
        XCTAssertEqual(HabitCheckIn.setValue(0, on: today, of: count, in: app), .noChange)
        XCTAssertEqual(HabitCheckIn.setNote("x", on: today, of: yesNo, in: app), .noChange)
        XCTAssertEqual(HabitCheckIn.setChecked(nil, on: today, of: count, in: app), .noChange)
        XCTAssertNil(HabitCheckIn.liveRecords(of: count, on: today).first)
        XCTAssertEqual(try written(HabitCheckIn.setValue(1, on: today, of: count, in: app)).loggedValue, 1)
        XCTAssertEqual(HabitCheckIn.tap(yesNo, on: today, in: app), .init(isCompleted: true, loggedValue: 1))
        try app.save()
        XCTAssertEqual(try stored(yesNo).count, 1)
        XCTAssertEqual(try stored(count).map(\.value), [1])
    }

    /// Another context saved the record after this one loaded it — a reminder's Add 1, Siri, the
    /// widget. A ModelContext does not take that in, and its save writes the object's whole state,
    /// so the setters adopt the store's fields first: a note written here keeps the other
    /// context's unit, and a value written here keeps the other context's note.
    func testAWriteKeepsWhatAnotherContextSavedSince() throws {
        let count = try habit(.count, records: [record(value: 3, note: "mine")])
        let kept = try XCTUnwrap(count.records.first)
        XCTAssertEqual(kept.value, 3)   // read here, as Today's row has

        let id = count.id
        let other = ModelContext(container)
        let theirs = try XCTUnwrap(other.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first?.records.first)
        theirs.value = 4                 // the reminder's Add 1
        theirs.note = "theirs"
        theirs.touch()
        try other.save()
        let theirStamp = theirs.stamp

        let noted = try written(HabitCheckIn.setNote("theirs, then mine", on: today, of: count, in: context))
        XCTAssertEqual(noted.loggedValue, 4)
        XCTAssertGreaterThan(kept.stamp, theirStamp, "the new stamp follows the stored one")
        try context.save()
        XCTAssertEqual(try stored(count).map(\.value), [4], "the other context's unit is kept")
        XCTAssertEqual(try stored(count).map(\.note), ["theirs, then mine"])

        theirs.note = "theirs again"
        theirs.touch()
        try other.save()
        _ = try written(HabitCheckIn.setValue(6, on: today, of: count, in: context))
        try context.save()
        XCTAssertEqual(try stored(count).map(\.note), ["theirs again"], "the other context's note is kept")

        // Already what the store holds once adopted: no write, no stamp.
        theirs.value = 9
        theirs.touch()
        try other.save()
        XCTAssertEqual(HabitCheckIn.setValue(9, on: today, of: count, in: context), .noChange)
        XCTAssertEqual(kept.value, 9)
    }

    // MARK: Same-day duplicates (decision 7)

    /// [2, 8] → setValue(3): the record D2 reads (8) is kept and set to 3, the other deleted —
    /// whichever was inserted first, and whichever comes first in `records` after the save.
    func testDuplicatesMergeIntoTheKeptRecordInBothOrders() throws {
        for order in [[2.0, 8.0], [8.0, 2.0]] {
            let records = order.map { record(value: $0) }
            let count = try habit(.count, records: records)
            let keptID = try XCTUnwrap(records.first { $0.value == 8 }).id
            let otherID = try XCTUnwrap(records.first { $0.value == 2 }).id

            let three = try written(HabitCheckIn.setValue(3, on: today, of: count, in: context))
            XCTAssertEqual(three, .init(deletedRecordIDs: [otherID.uuidString], isCompleted: false, loggedValue: 3,
                                        isCheckIn: false), "order \(order)")
            try context.save()
            let stored = try stored(count)
            XCTAssertEqual(stored.map(\.value), [3], "order \(order)")
            XCTAssertEqual(stored.map(\.id), [keptID], "order \(order): the 8 is the one kept")
        }
    }

    /// Equal values: the newer stamp is kept, as D2 reads it.
    func testEqualDuplicatesKeepTheNewerStamp() throws {
        let older = record(value: 4, stampOffset: 0)
        let newer = record(value: 4, stampOffset: 60)
        let count = try habit(.count, records: [newer, older])
        XCTAssertEqual(try written(HabitCheckIn.setValue(5, on: today, of: count, in: context)).deletedRecordIDs,
                       [older.id.uuidString])
        try context.save()
        XCTAssertEqual(try stored(count).map(\.id), [newer.id])
    }

    func testUncheckingAYesNoDayWithTwoRecordsDeletesBoth() throws {
        let records = [record(stampOffset: 0), record(stampOffset: 5)]
        let yesNo = try habit(records: records)
        let change = try written(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context))
        XCTAssertEqual(Set(change.deletedRecordIDs), Set(records.map(\.id.uuidString)))
        XCTAssertEqual(change.deletedRecordIDs.count, 2)
        try context.save()
        XCTAssertTrue(try stored(yesNo).isEmpty, "none left: one survivor would keep the day checked")
    }

    /// Any setter merges first — even one with nothing else to do.
    func testANoOpSetterStillMergesTheDay() throws {
        let records = [record(stampOffset: 0), record(stampOffset: 5)]
        let yesNo = try habit(records: records)
        let merged = try written(HabitCheckIn.setChecked(true, on: today, of: yesNo, in: context))
        XCTAssertEqual(merged, .init(deletedRecordIDs: [records[0].id.uuidString], isCompleted: true, loggedValue: 1,
                                     isCheckIn: false))
        try context.save()
        XCTAssertEqual(try stored(yesNo).map(\.id), [records[1].id])
    }

    /// One note among the duplicates moves onto the kept record; the same note twice is one.
    func testOneNoteMovesOntoTheKeptRecord() throws {
        let kept = record(value: 8)
        let other = record(value: 2, note: "from the iPad")
        let count = try habit(.count, records: [other, kept])
        XCTAssertEqual(try written(HabitCheckIn.setValue(9, on: today, of: count, in: context)).deletedRecordIDs,
                       [other.id.uuidString])
        try context.save()
        let stored = try stored(count)
        XCTAssertEqual(stored.map(\.id), [kept.id])
        XCTAssertEqual(stored.map(\.note), ["from the iPad"])

        let same = try habit(records: [record(note: "same", stampOffset: 0), record(note: "same", stampOffset: 9)])
        XCTAssertEqual(try written(HabitCheckIn.setChecked(true, on: today, of: same, in: context)).deletedRecordIDs.count, 1)
        try context.save()
        XCTAssertEqual(try self.stored(same).map(\.note), ["same"])
    }

    /// Two different notes: asked first, on every setter; confirmed, joined one per line, the
    /// kept record's first.
    func testTwoDifferentNotesNeedConfirmationThenCombine() throws {
        let kept = record(value: 8, note: "phone: after the run")
        let other = record(value: 2, note: "iPad: before bed")
        let count = try habit(.count, records: [other, kept])

        XCTAssertEqual(HabitCheckIn.setValue(3, on: today, of: count, in: context), .needsConfirmation(.combineNotes))
        XCTAssertEqual(HabitCheckIn.setChecked(true, on: today, of: count, in: context), .needsConfirmation(.combineNotes))
        XCTAssertEqual(HabitCheckIn.setValue(nil, on: today, of: count, in: context), .needsConfirmation(.combineNotes))
        XCTAssertEqual(HabitCheckIn.setNote("new", on: today, of: count, in: context), .needsConfirmation(.combineNotes))
        XCTAssertEqual(HabitCheckIn.setValue(3, on: today, of: count, in: context, confirmed: .removeNote),
                       .needsConfirmation(.combineNotes))
        XCTAssertFalse(context.hasChanges)

        let combined = try written(HabitCheckIn.setValue(3, on: today, of: count, in: context, confirmed: .combineNotes))
        XCTAssertEqual(combined.deletedRecordIDs, [other.id.uuidString])
        try context.save()
        let stored = try stored(count)
        XCTAssertEqual(stored.map(\.id), [kept.id])
        XCTAssertEqual(stored.map(\.value), [3])
        XCTAssertEqual(stored.map(\.note), ["phone: after the run\niPad: before bed"])
    }

    /// Writing a note over the kept record's keeps another record's different note, on confirmation.
    func testANewNoteOnADuplicateDayKeepsTheOtherNote() throws {
        let kept = record(value: 1, note: "mine", stampOffset: 9)
        let other = record(value: 1, note: "theirs", stampOffset: 0)
        let yesNo = try habit(records: [other, kept])
        XCTAssertEqual(HabitCheckIn.setNote("edited", on: today, of: yesNo, in: context), .needsConfirmation(.combineNotes))
        _ = try written(HabitCheckIn.setNote("edited", on: today, of: yesNo, in: context, confirmed: .combineNotes))
        try context.save()
        XCTAssertEqual(try stored(yesNo).map(\.note), ["edited\ntheirs"])

        // The other record's note equal to the new text: nothing to ask.
        let again = try habit(records: [record(note: "theirs", stampOffset: 0), record(note: "mine", stampOffset: 9)])
        XCTAssertEqual(try written(HabitCheckIn.setNote("theirs", on: today, of: again, in: context)).deletedRecordIDs.count, 1)
    }

    /// Unchecking a duplicate day where any record carries a note asks to remove it.
    func testUncheckingADuplicateDayWithANoteAsks() throws {
        let yesNo = try habit(records: [record(stampOffset: 0), record(note: "noted", stampOffset: 5)])
        XCTAssertEqual(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context), .needsConfirmation(.removeNote))
        XCTAssertEqual(HabitCheckIn.tap(yesNo, on: today, in: context).needsConfirmation, .removeNote)
        XCTAssertEqual(try written(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context, confirmed: .removeNote))
                        .deletedRecordIDs.count, 2)
    }

    // MARK: The tap on duplicates

    /// The widget's un-check deletes every record of the day; its count tap adds to the kept one
    /// and deletes nothing.
    func testTheTapActsOnTheKeptRecord() throws {
        let yesNoRecords = [record(stampOffset: 0), record(stampOffset: 5)]
        let yesNo = try habit(records: yesNoRecords)
        let untap = HabitCheckIn.tap(yesNo, on: today, in: context)
        XCTAssertEqual(Set(untap.deletedRecordIDs), Set(yesNoRecords.map(\.id.uuidString)))
        XCTAssertFalse(untap.isCompleted)
        try context.save()
        XCTAssertTrue(try stored(yesNo).isEmpty)

        let small = record(value: 2), large = record(value: 7)
        let count = try habit(.count, records: [small, large])
        let tap = HabitCheckIn.tap(count, on: today, in: context)
        XCTAssertEqual(tap, .init(isCompleted: true, loggedValue: 8))
        try context.save()
        XCTAssertEqual(try stored(count).map(\.value).sorted(), [2, 8], "the 7 gained the unit; nothing deleted")
        XCTAssertEqual(HabitCheckIn.markDone(count, on: today, in: context), nil, "8 of 8 is done")
    }

    // MARK: The journal (HabitEntryCommit's undo)

    /// Each kind of change, reverted: the store ends exactly as it was, every field included.
    func testTheJournalTakesBackDeletesEditsAndInserts() throws {
        let noted = record(value: 1, note: "keep me")
        noted.acknowledge(sentStamp: noted.stamp)
        let yesNo = try habit(records: [noted])
        let before = (id: noted.id, value: noted.value, note: noted.note, stamp: noted.updatedAt, synced: noted.syncedAt)

        let undo = HabitCheckIn.Undo()
        _ = try written(HabitCheckIn.setChecked(false, on: today, of: yesNo, in: context, confirmed: .removeNote, undo: undo))
        undo.revert(in: context)
        XCTAssertTrue(undo.isEmpty)
        try context.save()
        let back = try XCTUnwrap(try stored(yesNo).first)
        XCTAssertEqual(try stored(yesNo).count, 1)
        XCTAssertEqual(back.id, before.id)
        XCTAssertEqual(back.value, before.value)
        XCTAssertEqual(back.note, before.note)
        XCTAssertEqual(back.updatedAt, before.stamp)
        XCTAssertEqual(back.syncedAt, before.synced)
        XCTAssertFalse(back.isPending, "re-inserted as it was: nothing for sync to send")

        let count = try habit(.count, records: [record(value: 3, note: "three")])
        let kept = try XCTUnwrap(count.records.first)
        let stamp = kept.updatedAt
        let edit = HabitCheckIn.Undo()
        _ = try written(HabitCheckIn.setValue(5, on: today, of: count, in: context, undo: edit))
        _ = try written(HabitCheckIn.setNote("five", on: today, of: count, in: context, undo: edit))
        edit.revert(in: context)
        XCTAssertEqual(kept.value, 3)
        XCTAssertEqual(kept.note, "three")
        XCTAssertEqual(kept.updatedAt, stamp)

        let empty = try habit(.count)
        let insert = HabitCheckIn.Undo()
        _ = try written(HabitCheckIn.setValue(2, on: today, of: empty, in: context, undo: insert))
        insert.revert(in: context)
        try context.save()
        XCTAssertTrue(try stored(empty).isEmpty)
        XCTAssertNil(empty.record(on: today))
    }

    /// An edit then a delete of the same record in one journal brings it back as it was BEFORE the
    /// edit; an insert then a delete leaves nothing.
    func testTheJournalComposesWithinOneCommit() throws {
        let count = try habit(.count, records: [record(value: 3, note: "three")])
        let kept = try XCTUnwrap(count.records.first)
        let stamp = kept.updatedAt
        let undo = HabitCheckIn.Undo()
        _ = try written(HabitCheckIn.setValue(5, on: today, of: count, in: context, undo: undo))
        _ = try written(HabitCheckIn.setValue(0, on: today, of: count, in: context, confirmed: .removeNote, undo: undo))
        undo.revert(in: context)
        try context.save()
        let back = try XCTUnwrap(try stored(count).first)
        XCTAssertEqual(back.value, 3)
        XCTAssertEqual(back.note, "three")
        XCTAssertEqual(back.updatedAt, stamp)

        let empty = try habit()
        let twice = HabitCheckIn.Undo()
        _ = try written(HabitCheckIn.setChecked(true, on: today, of: empty, in: context, undo: twice))
        _ = try written(HabitCheckIn.setChecked(false, on: today, of: empty, in: context, undo: twice))
        XCTAssertTrue(twice.isEmpty)
        try context.save()
        XCTAssertTrue(try stored(empty).isEmpty)
    }
}

/// The widget's noted row and its app route (RELEASE-1.4.1.md D7): `HistoryLink` builds and
/// parses `stride://history?habit=<UUID>&day=<yyyy-MM-dd>`, and `AppURLRoute` keeps it apart from
/// the sign-in link. Anything that opens a URL can reach the app, so the rejections matter as much
/// as the round trip — and a login link must still route to sign-in, never to History.
final class HistoryLinkTests: XCTestCase {

    private let habitID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let token = "3f2b8c1e9a7d4c05b6e1f0a2d3c4b5a69788f1e2d3c4b5a6978801a2b3c4d5e6"

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func key(_ year: Int, _ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A string Foundation cannot parse fails the test instead of counting as a rejection.
    private func target(_ string: String, file: StaticString = #filePath,
                        line: UInt = #line) -> (habitID: UUID, day: Date)? {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)", file: file, line: line)
            return nil
        }
        return HistoryLink.target(of: url, calendar: calendar("America/Los_Angeles"))
    }

    // MARK: - The link

    func testTheLinkNamesTheHabitAndTheKeysDate() {
        XCTAssertEqual(HistoryLink.url(habitID: habitID, dayKey: key(2026, 9, 16)).absoluteString,
                       "stride://history?habit=6F9619FF-8B86-D011-B42D-00C04FC964FF&day=2026-09-16")
    }

    /// The day comes back as noon of that date in the device's calendar — a local instant, what
    /// `ShellRequest.history` takes — and keys back to the same day in every zone, including on a
    /// day a DST change shortens (Los Angeles, 2026-03-08) and lengthens (2026-11-01), and across
    /// the date line.
    func testItRoundTripsInEveryZone() throws {
        for zone in ["America/Los_Angeles", "Asia/Tokyo", "UTC", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let calendar = calendar(zone)
            for dayKey in [key(2026, 9, 16), key(2026, 3, 8), key(2026, 11, 1), key(2024, 2, 29), key(2026, 12, 31)] {
                let url = HistoryLink.url(habitID: habitID, dayKey: dayKey)
                let parsed = try XCTUnwrap(HistoryLink.target(of: url, calendar: calendar), "\(zone) \(dayKey)")
                XCTAssertEqual(parsed.habitID, habitID)
                XCTAssertEqual(HabitCalendar.dayKey(forInstant: parsed.day, calendar: calendar), dayKey, zone)
                XCTAssertEqual(calendar.component(.hour, from: parsed.day), 12, zone)
                XCTAssertEqual(AppURLRoute.of(url, calendar: calendar), .history(habitID: habitID, day: parsed.day))
            }
        }
    }

    /// A lower-case id is the same habit, and the scheme and host are case-insensitive.
    func testCaseDoesNotMatterWhereURLsIgnoreIt() {
        XCTAssertEqual(target("stride://history?habit=6f9619ff-8b86-d011-b42d-00c04fc964ff&day=2026-09-16")?.habitID, habitID)
        XCTAssertEqual(target("STRIDE://History?habit=6F9619FF-8B86-D011-B42D-00C04FC964FF&day=2026-09-16")?.habitID, habitID)
        XCTAssertNotNil(target("stride://history?day=2026-09-16&habit=6F9619FF-8B86-D011-B42D-00C04FC964FF"), "either order")
    }

    func testAnythingButExactlyOneHistoryLinkIsRejected() {
        let id = habitID.uuidString
        let rejected = [
            "https://history?habit=\(id)&day=2026-09-16",                       // another scheme
            "stridex://history?habit=\(id)&day=2026-09-16",
            "stride://login?habit=\(id)&day=2026-09-16",                        // another host
            "stride://history/?habit=\(id)&day=2026-09-16",                     // a path
            "stride://history/x?habit=\(id)&day=2026-09-16",
            "stride://history:80?habit=\(id)&day=2026-09-16",                   // a port
            "stride://me@history?habit=\(id)&day=2026-09-16",                   // a user
            "stride://history?habit=\(id)&day=2026-09-16#x",                    // a fragment
            "stride://history?habit=\(id)",                                     // an item missing
            "stride://history?day=2026-09-16",
            "stride://history",
            "stride://history?habit=\(id)&habit=\(id)&day=2026-09-16",          // twice
            "stride://history?habit=\(id)&day=2026-09-16&day=2026-09-16",
            "stride://history?habit=\(id)&day=2026-09-16&utm=1",                // an extra item
            "stride://history?habit=&day=2026-09-16",                           // empty values
            "stride://history?habit=\(id)&day=",
            "stride://history?habit&day=2026-09-16",
            "stride://history?habit=not-a-uuid&day=2026-09-16",
            "stride://history?habit=6F9619FF8B86D011B42D00C04FC964FF&day=2026-09-16",   // no dashes
            "stride://history?habit=%7B\(id)%7D&day=2026-09-16",                // braces
            "stride://history?habit=\(id)&day=2026-9-16",                       // the date's shape
            "stride://history?habit=\(id)&day=20260916",
            "stride://history?habit=\(id)&day=2026-09-16T12:00",
            "stride://history?habit=\(id)&day=%202026-09-16",
            "stride://history?habit=\(id)&day=2026-09-1x",
            "stride://history?habit=\(id)&day=%EF%BC%92026-09-16",              // a full-width digit
            "stride://history?habit=\(id)&day=2026-02-30",                      // dates that do not exist
            "stride://history?habit=\(id)&day=2026-02-29",
            "stride://history?habit=\(id)&day=2026-13-01",
            "stride://history?habit=\(id)&day=2026-00-10",
            "stride://history?habit=\(id)&day=2026-04-31",
            "stride://history?habit=\(id)&day=0000-01-01",
        ]
        for string in rejected {
            XCTAssertNil(target(string), string)
        }
    }

    // MARK: - Kept apart from sign-in

    /// A login link still routes to sign-in, never to History; a history link never to sign-in;
    /// and neither shape on the other's scheme or host is taken for either.
    func testALoginLinkStillRoutesToSignIn() throws {
        let calendar = calendar("America/Los_Angeles")
        func route(_ string: String) throws -> AppURLRoute {
            AppURLRoute.of(try XCTUnwrap(URL(string: string), string), calendar: calendar)
        }
        XCTAssertEqual(try route("https://stride-api.colorarchive.me/login?token=\(token)"), .signIn)
        XCTAssertEqual(try route("HTTPS://Stride-API.ColorArchive.me/login?utm_source=mail&token=\(token)"), .signIn)
        guard case .history = try route("stride://history?habit=\(habitID.uuidString)&day=2026-09-16") else {
            return XCTFail("a history link opens History")
        }
        XCTAssertEqual(try route("stride://login?token=\(token)"), .other, "the custom scheme never signs in")
        XCTAssertEqual(try route("stride://history?token=\(token)"), .other)
        XCTAssertEqual(try route("https://stride-api.colorarchive.me/history?habit=\(habitID.uuidString)&day=2026-09-16"),
                       .other, "History is never reached over https")
        XCTAssertEqual(try route("https://stride-api.colorarchive.me/login?token=\(token)&habit=\(habitID.uuidString)&day=2026-09-16"),
                       .signIn, "a login link with extra items is still only a login link")
        XCTAssertEqual(try route("https://example.com/"), .other)
    }

    // MARK: - Which widget rows open it

    private func row(isCount: Bool = false, isCompleted: Bool = true, hasNote: Bool = true,
                     id: String? = nil) -> WidgetTimelinePlan.Row {
        WidgetTimelinePlan.Row(habitId: id ?? habitID.uuidString, name: "Read", emoji: "📚", colorHex: "#007AFF",
                               isCount: isCount, isCompleted: isCompleted, progress: isCompleted ? 1 : 0,
                               streak: 3, streakInWeeks: false, hasNote: hasNote)
    }

    /// Only a checked, noted yes/no row: un-checking it from the extension would delete the note.
    /// A count row's tap adds one and never deletes, so it stays a button; an unchecked or
    /// note-less row stays a toggle.
    func testOnlyACheckedNotedYesNoRowOpensHistory() {
        let day = key(2026, 9, 16)
        XCTAssertEqual(HistoryLink.url(for: row(), dayKey: day), HistoryLink.url(habitID: habitID, dayKey: day))
        XCTAssertNil(HistoryLink.url(for: row(hasNote: false), dayKey: day))
        XCTAssertNil(HistoryLink.url(for: row(isCompleted: false), dayKey: day))
        XCTAssertNil(HistoryLink.url(for: row(isCount: true), dayKey: day))
        XCTAssertNil(HistoryLink.url(for: row(id: "1"), dayKey: day), "the gallery's placeholder rows")
    }

    /// The link of the plan's midnight entry names tomorrow, the day that entry shows.
    func testTheMidnightEntrysRowsLinkToTheirOwnDay() throws {
        let calendar = calendar("America/Los_Angeles")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 21))!
        let input = WidgetTimelinePlan.RowInput(habitId: habitID.uuidString, name: "Read", emoji: "📚",
                                                colorHex: "#007AFF", isCount: false, streakInWeeks: false,
                                                status: { _ in .init(isCompleted: true, progress: 1, streak: 1, hasNote: true) })
        let plan = WidgetTimelinePlan(now: now, calendar: calendar, rows: [input])
        let urls = plan.entries.map { HistoryLink.url(for: $0.rows[0], dayKey: $0.dayKey)?.absoluteString }
        XCTAssertEqual(urls, ["stride://history?habit=\(habitID.uuidString)&day=2026-09-16",
                              "stride://history?habit=\(habitID.uuidString)&day=2026-09-17"])
    }
}
