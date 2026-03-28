import XCTest
import SwiftData
import Foundation

@MainActor
final class HabitTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func makeHabit(name: String = "Test", emoji: String = "⭐", colorHex: String = "#34C759") -> Habit {
        let habit = Habit(name: name, emoji: emoji, colorHex: colorHex)
        context.insert(habit)
        return habit
    }

    private func addRecord(to habit: Habit, daysAgo: Int) {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        let record = HabitRecord(date: date)
        context.insert(record)
        habit.records.append(record)
    }

    // MARK: - Creation

    func testHabitCreationDefaults() {
        let habit = makeHabit(name: "Meditate")

        XCTAssertEqual(habit.name, "Meditate")
        XCTAssertEqual(habit.emoji, "⭐")
        XCTAssertEqual(habit.colorHex, "#34C759")
        XCTAssertFalse(habit.isArchived)
        XCTAssertTrue(habit.records.isEmpty)
        XCTAssertNotNil(habit.id)
    }

    func testHabitCreationCustom() {
        let habit = makeHabit(name: "Run", emoji: "🏃", colorHex: "#FF3B30")

        XCTAssertEqual(habit.name, "Run")
        XCTAssertEqual(habit.emoji, "🏃")
        XCTAssertEqual(habit.colorHex, "#FF3B30")
    }

    // MARK: - isCompletedOn

    func testIsCompletedOnToday() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 0)

        XCTAssertTrue(habit.isCompletedOn(Date()))
    }

    func testIsCompletedOnYesterday() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 1)

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        XCTAssertTrue(habit.isCompletedOn(yesterday))
    }

    func testIsNotCompletedOnMissingDate() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 2)

        // Yesterday has no record
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        XCTAssertFalse(habit.isCompletedOn(yesterday))
    }

    func testIsCompletedOnNoRecords() {
        let habit = makeHabit()
        XCTAssertFalse(habit.isCompletedOn(Date()))
    }

    // MARK: - currentStreak

    func testCurrentStreakEmpty() {
        let habit = makeHabit()
        XCTAssertEqual(habit.currentStreak(), 0)
    }

    func testCurrentStreakSingleDayToday() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 0)

        XCTAssertEqual(habit.currentStreak(), 1)
    }

    func testCurrentStreakSingleDayYesterday() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 1)

        XCTAssertEqual(habit.currentStreak(), 1)
    }

    func testCurrentStreakMultiDay() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 0)
        addRecord(to: habit, daysAgo: 1)
        addRecord(to: habit, daysAgo: 2)

        XCTAssertEqual(habit.currentStreak(), 3)
    }

    func testCurrentStreakGapBreaks() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 0)
        addRecord(to: habit, daysAgo: 1)
        // gap at daysAgo: 2
        addRecord(to: habit, daysAgo: 3)

        XCTAssertEqual(habit.currentStreak(), 2)
    }

    func testCurrentStreakYesterdayContinues() {
        let habit = makeHabit()
        // No record today, but yesterday + day before
        addRecord(to: habit, daysAgo: 1)
        addRecord(to: habit, daysAgo: 2)
        addRecord(to: habit, daysAgo: 3)

        XCTAssertEqual(habit.currentStreak(), 3)
    }

    func testCurrentStreakTwoDaysAgoDoesNotCount() {
        let habit = makeHabit()
        // Only 2 days ago, no today or yesterday
        addRecord(to: habit, daysAgo: 2)

        XCTAssertEqual(habit.currentStreak(), 0)
    }

    // MARK: - bestStreak

    func testBestStreakEmpty() {
        let habit = makeHabit()
        XCTAssertEqual(habit.bestStreak(), 0)
    }

    func testBestStreakSingleRecord() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 5)

        XCTAssertEqual(habit.bestStreak(), 1)
    }

    func testBestStreakConsecutive() {
        let habit = makeHabit()
        addRecord(to: habit, daysAgo: 3)
        addRecord(to: habit, daysAgo: 2)
        addRecord(to: habit, daysAgo: 1)
        addRecord(to: habit, daysAgo: 0)

        XCTAssertEqual(habit.bestStreak(), 4)
    }

    func testBestStreakWithGaps() {
        let habit = makeHabit()
        // First streak: 3 days
        addRecord(to: habit, daysAgo: 10)
        addRecord(to: habit, daysAgo: 9)
        addRecord(to: habit, daysAgo: 8)
        // Gap
        // Second streak: 2 days
        addRecord(to: habit, daysAgo: 5)
        addRecord(to: habit, daysAgo: 4)

        XCTAssertEqual(habit.bestStreak(), 3)
    }

    func testBestStreakLatestIsLongest() {
        let habit = makeHabit()
        // First streak: 2 days
        addRecord(to: habit, daysAgo: 10)
        addRecord(to: habit, daysAgo: 9)
        // Gap
        // Second streak: 4 days
        addRecord(to: habit, daysAgo: 3)
        addRecord(to: habit, daysAgo: 2)
        addRecord(to: habit, daysAgo: 1)
        addRecord(to: habit, daysAgo: 0)

        XCTAssertEqual(habit.bestStreak(), 4)
    }

    // MARK: - completionRate

    func testCompletionRateFullMonth() {
        let habit = makeHabit()
        for day in 0..<30 {
            addRecord(to: habit, daysAgo: day)
        }

        XCTAssertEqual(habit.completionRate(days: 30), 1.0, accuracy: 0.01)
    }

    func testCompletionRatePartial() {
        let habit = makeHabit()
        // Complete every other day in the last 10 days
        for day in stride(from: 0, to: 10, by: 2) {
            addRecord(to: habit, daysAgo: day)
        }

        // 5 completions out of 10 days (or fewer if habit is newer)
        let rate = habit.completionRate(days: 10)
        XCTAssertGreaterThan(rate, 0.0)
        XCTAssertLessThanOrEqual(rate, 1.0)
    }

    func testCompletionRateNoRecords() {
        let habit = makeHabit()
        let rate = habit.completionRate(days: 30)
        XCTAssertEqual(rate, 0.0, accuracy: 0.01)
    }

    // MARK: - completionsPerWeekday

    func testCompletionsPerWeekdayEmpty() {
        let habit = makeHabit()
        let weekdays = habit.completionsPerWeekday()
        XCTAssertTrue(weekdays.isEmpty)
    }

    func testCompletionsPerWeekdayCounts() {
        let habit = makeHabit()
        // Add records for the last 7 days (each day = different weekday)
        for day in 0..<7 {
            addRecord(to: habit, daysAgo: day)
        }

        let weekdays = habit.completionsPerWeekday()
        // Should have 7 unique weekday keys, each with count 1
        XCTAssertEqual(weekdays.count, 7)
        for (_, count) in weekdays {
            XCTAssertEqual(count, 1)
        }
    }

    func testCompletionsPerWeekdayMultipleSameDay() {
        let habit = makeHabit()
        // Two records exactly 7 days apart land on the same weekday
        addRecord(to: habit, daysAgo: 0)
        addRecord(to: habit, daysAgo: 7)

        let weekdays = habit.completionsPerWeekday()
        let todayWeekday = Calendar.current.component(.weekday, from: Date())
        XCTAssertEqual(weekdays[todayWeekday], 2)
    }
}
