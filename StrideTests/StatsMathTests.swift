import XCTest
import SwiftData
import Foundation

/// Tests for the streak and completion-rate math behind the Stats tab, the Pro trend chart and
/// Weekly Review. Every case below uses a user who did exactly what the habit asked, and checks
/// the app says so. Before 1.2.3 several of them did not:
/// - a Mon/Wed/Fri habit never missed for six weeks showed "Best Streak 1 day" beside a current
///   streak of 18, because the best streak required literally consecutive calendar days;
/// - a "3 times a week" goal met every single week scored a 30-day rate of 43%, because the
///   rate treated it as due all seven days.
///
/// Dates are fixed UTC day-keys (2026-06-01 is a Monday), so none of this depends on the day or
/// the time zone the tests run in.
@MainActor
final class StatsMathTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let utc = HabitCalendar.utc

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

    // MARK: - Helpers

    private func day(_ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func habit(_ schedule: HabitSchedule, timesPerWeek: Int = 7, activeDays: Int = 127) -> Habit {
        let h = Habit(name: "Habit")
        h.schedule = schedule
        h.timesPerWeek = timesPerWeek
        h.activeDaysMask = activeDays
        h.createdAt = day(1, 1)   // well before every range below
        context.insert(h)
        return h
    }

    private func checkIn(_ h: Habit, on dates: [Date]) {
        for d in dates { h.records.append(HabitRecord(date: d)) }
    }

    /// Mon, Wed and Fri of `weeks` consecutive weeks starting Monday 2026-06-01.
    private func monWedFri(weeks: Int) -> [Date] {
        (0..<weeks).flatMap { w in [0, 2, 4].map { utc.date(byAdding: .day, value: 7 * w + $0, to: day(6, 1))! } }
    }

    private let monWedFriMask = (1 << 1) | (1 << 3) | (1 << 5)   // bit 0 = Sunday

    // MARK: - Best streak

    /// "Gym — Mon/Wed/Fri", never missed for six weeks. Rest days must neither count nor break
    /// the run, exactly as they don't for the current streak shown beside it.
    func testBestStreakSkipsRestDaysForSpecificDays() {
        let h = habit(.specificDays, activeDays: monWedFriMask)
        checkIn(h, on: monWedFri(weeks: 6))
        let saturdayAfter = day(7, 11)

        XCTAssertEqual(h.currentStreak(from: saturdayAfter), 18, "precondition: the current streak already handles rest days")
        XCTAssertEqual(h.bestStreak(), 18, "was 1: no two completed days are ever adjacent")
    }

    /// "Yoga — 3 times a week", met six weeks running. Its streak is counted in weeks.
    func testBestStreakCountsWeeksForTimesPerWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: monWedFri(weeks: 6))

        XCTAssertEqual(h.currentStreak(from: day(7, 11)), 6, "precondition: current streak counts weeks")
        XCTAssertEqual(h.bestStreak(), 6, "must be in weeks too, not a count of adjacent days")
    }

    /// A 10-day run, a two-day gap, then 3 days. Best is the old run, current is the new one.
    func testBestStreakKeepsTheLongestRunAfterABreak() {
        let h = habit(.daily)
        checkIn(h, on: (1...10).map { day(6, $0) } + (13...15).map { day(6, $0) })

        XCTAssertEqual(h.currentStreak(from: day(6, 16)), 3)
        XCTAssertEqual(h.bestStreak(), 10)
    }

    // MARK: - Completion rate

    /// "Run — 3 times a week", done Mon/Wed/Fri every week, measured over the 30 days ending the
    /// Saturday after. Hitting the goal every week is 100%; it used to read 43% (13 of 30 days).
    func testThirtyDayRateForAWeeklyGoalMetEveryWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: monWedFri(weeks: 6))
        let end = day(7, 11)
        let start = utc.date(byAdding: .day, value: -29, to: end)!

        XCTAssertEqual(h.completionRate(from: start, to: end), 1.0, accuracy: 0.0001)
    }

    /// One run a week against a goal of three, over four whole weeks: a third.
    func testRateForAWeeklyGoalMissedEveryWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: [day(6, 1), day(6, 8), day(6, 15), day(6, 22)])

        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 28)), 1.0 / 3.0, accuracy: 0.0001)
    }

    /// Mon–Wed done, measured across the whole Mon–Sun week on Wednesday. Thursday to Sunday
    /// haven't happened; they must not be scored as misses. (The 8-week trend's last bar.)
    func testRateDoesNotCountDaysThatHaveNotHappened() {
        let h = habit(.daily)
        checkIn(h, on: [day(6, 1), day(6, 2), day(6, 3)])

        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 7), now: day(6, 3)), 1.0, accuracy: 0.0001)
        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 7), now: day(6, 7)), 3.0 / 7.0, accuracy: 0.0001,
                       "once the week is over, the missing days do count")
    }

    /// A week only partly inside the range still credits a goal met earlier in that week.
    func testWeeklyGoalMetEarlyInAWeekThatStartsBeforeTheRange() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: [day(6, 1), day(6, 2), day(6, 3)])   // Mon–Wed of that week

        // Range starts Saturday of the same week.
        XCTAssertEqual(h.completionRate(from: day(6, 6), to: day(6, 7), now: day(6, 7)), 1.0, accuracy: 0.0001)
    }

    func testCountHabitDaysBelowTargetDoNotCountAsCompleted() {
        let h = habit(.daily)
        h.kind = HabitKind.count.rawValue
        h.targetValue = 8
        h.records.append(HabitRecord(date: day(6, 1), value: 1))
        h.records.append(HabitRecord(date: day(6, 2), value: 8))

        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 2), now: day(6, 2)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(h.bestStreak(), 1)
    }
}
