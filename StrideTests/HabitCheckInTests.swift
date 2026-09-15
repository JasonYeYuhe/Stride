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
}
