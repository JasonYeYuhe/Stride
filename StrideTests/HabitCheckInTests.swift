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
        XCTAssertEqual(first, .init(deletedRecordID: nil, isCompleted: true, loggedValue: 1))
        try context.save()
        let recordID = try XCTUnwrap(habit.record(on: today)).id.uuidString

        let second = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(second, .init(deletedRecordID: recordID, isCompleted: false, loggedValue: 0))
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
        XCTAssertEqual(third, .init(deletedRecordID: nil, isCompleted: true, loggedValue: 1))
    }

    // MARK: - Count habits (the widget / watch bug)

    /// "Drink Water" at 6 of 8. The widget drew this as an empty circle and a tap DELETED the
    /// day — six units gone, and a tombstone queued to delete them on every other device.
    func testCountTapOnAPartialDayAddsOneAndNeverDeletes() throws {
        let habit = try countHabit(target: 8, logged: 6)
        let recordID = try XCTUnwrap(habit.record(on: today)).id

        let result = HabitCheckIn.tap(habit, on: today, in: context)
        try context.save()

        XCTAssertNil(result.deletedRecordID, "a count tap must never delete, or queue a tombstone")
        XCTAssertEqual(result.loggedValue, 7)
        XCTAssertFalse(result.isCompleted)
        XCTAssertEqual(recordsToday(habit).count, 1)
        XCTAssertEqual(habit.record(on: today)?.id, recordID, "the same record gains the unit")
    }

    func testCountTapOnAnEmptyDayStartsAtOne() throws {
        let habit = try countHabit(target: 8, logged: nil)
        let result = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(result, .init(deletedRecordID: nil, isCompleted: false, loggedValue: 1))
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
        let untappedID = try XCTUnwrap(untap.deletedRecordID)
        try context.save()
        XCTAssertTrue(try storedToday(habit).isEmpty)

        let retap = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(retap, .init(deletedRecordID: nil, isCompleted: true, loggedValue: 1),
                       "the re-tap checks the day; it must not delete the old record a second time")
        try context.save()

        let stored = try storedToday(habit)
        XCTAssertEqual(stored.count, 1, "the re-tap's check-in is in the store")
        XCTAssertNotEqual(stored.first?.id.uuidString, untappedID, "a new record, not the deleted one")

        // And the next tap unchecks THAT record.
        let third = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(third.deletedRecordID, stored.first?.id.uuidString)
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
        XCTAssertEqual(result, .init(deletedRecordID: nil, isCompleted: false, loggedValue: 1))
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
        XCTAssertNotNil(HabitCheckIn.tap(widgetHabit, on: today, in: widget).deletedRecordID)
        try widget.save()

        let appTap = HabitCheckIn.tap(habit, on: today, in: context)
        XCTAssertEqual(appTap, .init(deletedRecordID: nil, isCompleted: true, loggedValue: 1))
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
        XCTAssertEqual(try widgetTap(), .init(deletedRecordID: nil, isCompleted: true, loggedValue: 1))
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

        XCTAssertEqual(result, .init(deletedRecordID: nil, isCompleted: true, loggedValue: 1))
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

        XCTAssertEqual(result, .init(deletedRecordID: nil, isCompleted: false, loggedValue: 4))
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
                       .init(deletedRecordID: nil, isCompleted: false, loggedValue: 1))
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
