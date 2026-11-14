import XCTest
import SwiftData

/// RELEASE-1.4.2.md D14 and W8: `-demo -demoPro` seeds `DemoData.Scenario.pro`, and every Pro surface
/// the sweep and the store screenshots capture must have something true to show on whatever weekday
/// they are taken. Each check runs on all seven days of one week, in the zone the test runner is in
/// (CI and the gates run Tokyo and Los Angeles, `TEST_RUNNER_TZ`).
final class DemoDataProScenarioTests: XCTestCase {

    private struct Seeded {
        let container: ModelContainer
        let habits: [Habit]
        let groups: [HabitGroup]
        let now: Date
        let calendar = Calendar.current

        func habit(_ name: String) -> Habit { habits.first { $0.name == name }! }

        /// Built for the review's day (`WeeklyReviewMath.today`), as the app builds them.
        func stats(_ name: String) -> HabitStats {
            habit(name).makeStats(today: WeeklyReviewMath.today(now: now, calendar: calendar), calendar: calendar)
        }

        var weekday: Int { (calendar.component(.weekday, from: now) + 5) % 7 }
    }

    /// 12:00 local on Monday 16 November 2026, plus `offset` days.
    private static func noon(_ offset: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16 + offset, hour: 12))!
    }

    @MainActor
    private static func seed(_ offset: Int) throws -> Seeded {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let now = noon(offset)
        DemoData.populate(container: container, scenario: .pro, now: now)
        let context = container.mainContext
        let habits = try context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.sortOrder)]))
        let groups = try context.fetch(FetchDescriptor<HabitGroup>(sortBy: [SortDescriptor(\.sortOrder)]))
        return Seeded(container: container, habits: habits, groups: groups, now: now)
    }

    func testTheSwitchesPickTheScenario() {
        XCTAssertEqual(DemoData.Scenario.fromLaunchArguments(["-demo"]), .standard)
        XCTAssertEqual(DemoData.Scenario.fromLaunchArguments(["-demo", "-demoPro"]), .pro)
        XCTAssertEqual(DemoData.Scenario.fromLaunchArguments(["-demo", "-demoScenario", "pro"]), .pro)
        XCTAssertEqual(DemoData.Scenario.fromLaunchArguments(["-demo", "-demoPro", "-demoScenario", "details"]), .details)
    }

    @MainActor
    func testTwoGroupsAndFiveHabitsInOrder() throws {
        let seeded = try Self.seed(0)
        XCTAssertEqual(seeded.groups.map(\.name), ["Health", "Mind"])
        XCTAssertEqual(seeded.habits.map(\.name), ["Morning Run", "Drink Water", "Read 30 min", "Yoga", "Journal"])
        XCTAssertTrue(seeded.habits.allSatisfy { $0.groupId != nil })
        XCTAssertEqual(seeded.habit("Yoga").schedule, .timesPerWeek)
    }

    /// Statistics' habit: the record line, momentum up, toughest on Sunday; both long Strength tiles.
    @MainActor
    func testMorningRunHasThreeInsightLinesEveryDay() throws {
        for offset in 0..<7 {
            let seeded = try Self.seed(offset)
            let stats = seeded.stats("Morning Run")
            let lines = StatsInsights.insightLines(for: stats)
            XCTAssertEqual(lines.count, 3, "day \(offset): \(lines)")
            guard lines.count == 3 else { continue }
            if case .record(let gap, let inWeeks) = lines[0] {
                XCTAssertEqual(gap.record, 14, "day \(offset)")
                XCTAssertFalse(inWeeks)
            } else {
                XCTFail("day \(offset): first line \(lines[0])")
            }
            if case .momentum(let momentum) = lines[1] {
                XCTAssertEqual(momentum.direction, .up, "day \(offset)")
            } else {
                XCTFail("day \(offset): second line \(lines[1])")
            }
            XCTAssertEqual(lines[2], .toughest(1), "day \(offset): toughest on Sunday")
            XCTAssertEqual(StatsInsights.strengthChanges(for: stats), [.thirtyDays, .ninetyDays], "day \(offset)")
        }
    }

    /// D7 on a habit started 10 days ago.
    @MainActor
    func testDrinkWaterIsTenDaysOld() throws {
        for offset in 0..<7 {
            let seeded = try Self.seed(offset)
            let stats = seeded.stats("Drink Water")
            XCTAssertEqual(StatsInsights.ageInDays(startDay: stats.startDay, today: stats.today, calendar: seeded.calendar),
                           10, "day \(offset)")
            XCTAssertEqual(StatsInsights.strengthChanges(for: stats), [.sinceStart], "day \(offset)")
        }
    }

    /// Last week's review: a rate, Read as most improved, Journal as slipped, by group; Journal's
    /// notes. The Today card needs only last week's rate (InlinePromptsTests pin the rest).
    @MainActor
    func testLastWeeksReviewHasBothHighlights() throws {
        for offset in 0..<7 {
            let seeded = try Self.seed(offset)
            let inputs = seeded.habits.map {
                WeeklyReviewMath.HabitInput(habit: $0, stats: seeded.stats($0.name))
            }
            let lastWeek = InlinePrompts.lastWeek(now: seeded.now, calendar: seeded.calendar)
            let review = WeeklyReviewMath.review(of: inputs, week: lastWeek, groupOrder: seeded.groups.map(\.id))
            XCTAssertNotNil(review.overall, "day \(offset)")
            XCTAssertTrue(review.isFinished)
            XCTAssertEqual(review.mostImproved.map { seeded.habits[$0].name }, "Read 30 min", "day \(offset)")
            XCTAssertEqual(review.slipped.map { seeded.habits[$0].name }, "Journal", "day \(offset)")
            XCTAssertEqual(review.sections.map(\.groupID), seeded.groups.map(\.id))
            let notes = seeded.habit("Journal").records.filter { lastWeek.contains($0.date) }.compactMap(\.note)
            XCTAssertEqual(notes.count, 3, "day \(offset)")
            if seeded.weekday <= 1 {
                XCTAssertNotNil(InlinePrompts.card(now: seeded.now, calendar: seeded.calendar, isPro: true,
                                                   lastWeekRate: review.overall, state: .init()),
                                "day \(offset): the Monday/Tuesday card")
            }
        }
    }

    /// The 3-times-a-week habit is at risk once fewer days are left than check-ins owed: Friday on.
    @MainActor
    func testYogaIsAtRiskFromFriday() throws {
        for offset in 0..<7 {
            let seeded = try Self.seed(offset)
            let goal = WeeklyReviewMath.weekGoal(of: seeded.stats("Yoga"), now: seeded.now, calendar: seeded.calendar)
            XCTAssertEqual(goal?.done, 0, "day \(offset)")
            XCTAssertEqual(goal?.isAtRisk, seeded.weekday >= 4, "day \(offset)")
        }
    }
}
