import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// Weekly Review, step 1 (RELEASE-1.4.2.md D8, W6) and step 2 (RELEASE-1.5.0.md D6: ‹ ›, the strip,
/// the strength chip, group sections, perfect days, "At risk this week"), hosted: the real WeeklyReviewView over a store
/// and a `StatsCache` of this test's own (`\.statsCache`, as StatsRenderTests), on a fixed clock
/// (`WeeklyReviewView(week:now:)`, DEBUG only), read off the accessibility tree.
///
/// Every day here is in June 2026: Monday 06-01 opens this week, so last week is 05-25 … 05-31 and
/// the week before it 05-18 … 05-24. The clock is a local instant in the runner's zone
/// (`TEST_RUNNER_TZ`), the records and creation days are day-keys, so the same cases hold in Tokyo
/// and in Los Angeles.
@MainActor
final class WeeklyReviewRenderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var cache: StatsCache!
    private var window: UIWindow?
    private var automation: Bool?
    /// As StatsRenderTests: a hosted view's task can outlive its window, and a context whose
    /// container was released traps.
    private static var retiredContainers: [ModelContainer] = []

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        cache = StatsCache()
    }

    override func tearDown() async throws {
        closeWindow()
        if let automation { AccessibilityAutomation.restore(automation) }
        automation = nil
        if let container { Self.retiredContainers.append(container) }
        cache = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The day-key of 2026-`month`-`day`.
    private static func key(_ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    /// The day-keys `first` … `last`, both in 2026.
    private static func keys(_ first: (Int, Int), _ last: (Int, Int)) -> [Date] {
        var result: [Date] = []
        var day = key(first.0, first.1)
        let end = key(last.0, last.1)
        while day <= end {
            result.append(day)
            day = HabitCalendar.utc.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// A local instant in the runner's zone: what the review's clock reads.
    private static func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var order = 0.0

    /// A yes/no daily habit created on the day-key `created`, checked in on each of `checkedIn`,
    /// saved; listed in the order made.
    @discardableResult
    private func habit(_ name: String, created: (Int, Int) = (5, 1), checkedIn: [Date],
                       activeDays: Int? = nil) throws -> Habit {
        let habit = Habit(name: name)
        if let activeDays {
            habit.schedule = .specificDays
            habit.activeDaysMask = activeDays
        }
        habit.createdAt = Self.key(created.0, created.1)
        habit.sortOrder = order
        order += 1
        context.insert(habit)
        habit.records = checkedIn.map { HabitRecord(date: $0) }
        try context.save()
        return habit
    }

    // MARK: - D8: the opening week

    /// Monday 06-01 at 09:00, before any check-in, for a user who never misses: the review opens on
    /// last week, titled "Last week" over its dates, every row and the ring with a rate. 1.4.1 opened
    /// on this week: two dash rows and a dash ring.
    func testOnAMondayBeforeAnyCheckInItOpensLastWeekWithItsDates() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (5, 31)))
        try habit("Read", checkedIn: Self.keys((5, 1), (5, 31)))

        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Run": 100, "Read": 100])
        XCTAssertTrue(has(appLocalized("Last week: \(100)%"), in: window), "the ring speaks last week: \(labels(in: window))")
        XCTAssertTrue(has(appLocalized("Level with the previous week"), in: window), "100 against 100")
    }

    /// Wednesday 06-03 at 09:00, Monday and Tuesday done: still last week, a finished one.
    func testOnAWednesdayItOpensLastWeek() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (6, 2)))
        try habit("Read", checkedIn: Self.keys((5, 1), (6, 2)))

        let window = try show(now: Self.local(6, 3, 9))
        try await expectLastWeek(in: window, rows: ["Run": 100, "Read": 100])
    }

    /// Thursday 06-04 just after midnight: this week, titled "This week so far" over its dates.
    /// Today is not done, so 3 days are counted (Monday to Wednesday): no change line and no
    /// highlight yet, though last week was lower.
    func testOnAThursdayItOpensThisWeekSoFar() async throws {
        try habit("Run", checkedIn: Self.keys((5, 25), (5, 28)) + Self.keys((6, 1), (6, 3)))

        let window = try show(now: Self.local(6, 4, 0, 30))
        try await waitUntil("the review") { self.has(appLocalized("This week so far"), in: window) }
        XCTAssertFalse(has(appLocalized("Last week"), in: window))
        XCTAssertTrue(has(dates(of: Self.key(6, 1)), in: window), "this week's dates: \(labels(in: window))")
        XCTAssertTrue(has(row("Run", 100), in: window), "Monday to Wednesday, 3 of 3: \(labels(in: window))")
        XCTAssertFalse(hasChangeLine(in: window), "3 counted days: no change against 57%: \(labels(in: window))")
        XCTAssertFalse(hasHighlights(in: window))
    }

    /// `.weeklyReview(week: lastMonday)` (Today's card, through the shell): last week, even on a
    /// Thursday that would open this week. A Monday as the shell passes it — a local midnight —
    /// and an earlier week, titled by its dates.
    func testARequestedWeekOpensThatWeek() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (6, 3)))
        let thursday = Self.local(6, 4, 9)

        var window = try show(week: Self.local(5, 25, 0), now: thursday)
        try await expectLastWeek(in: window, rows: ["Run": 100])

        window = try show(week: Self.local(5, 18, 0), now: thursday)
        let earlier = dates(of: Self.key(5, 18))
        try await waitUntil("the earlier week") { self.has(earlier, in: window) }
        XCTAssertFalse(has(appLocalized("Last week"), in: window))
        XCTAssertFalse(has(appLocalized("This week so far"), in: window))
        XCTAssertFalse(has(dates(of: Self.key(5, 25)), in: window))
        XCTAssertTrue(has(row("Run", 100), in: window))

        window = try show(week: Self.key(6, 1), now: thursday)
        try await waitUntil("this week, asked for by its day-key") { self.has(appLocalized("This week so far"), in: window) }
    }

    // MARK: - D8: the change in points, and the highlights

    /// Monday 06-01, last week against the one before: Run 100 → 71 (−29), Read 42 → 100 (+58).
    /// The change line is their mean in points (+14.5, rounded to +15), never "%"; Read is "Most
    /// improved" and Run "Slipped", under "Highlights" (the week is over).
    func testTheChangeInPointsAndTheHighlights() async throws {
        try habit("Run", checkedIn: Self.keys((5, 18), (5, 24)) + Self.keys((5, 25), (5, 29)))
        try habit("Read", checkedIn: Self.keys((5, 18), (5, 20)) + Self.keys((5, 25), (5, 31)))

        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Run": 71, "Read": 100])
        XCTAssertTrue(has(appLocalized("+\(15) points vs previous week"), in: window), "\(labels(in: window))")
        XCTAssertFalse(labels(in: window).contains { $0.contains("%") && $0.contains("vs") }, "no \"%\" change")
        XCTAssertTrue(has(appLocalized("Highlights"), in: window))
        XCTAssertFalse(has(appLocalized("Highlights so far"), in: window))
        XCTAssertEqual(highlight("Most improved", in: window).map { $0.contains("Read") }, true, "\(labels(in: window))")
        XCTAssertEqual(highlight("Slipped", in: window).map { $0.contains("Run") }, true, "\(labels(in: window))")
    }

    /// A level week reads "Level with the previous week", and has no highlight.
    func testALevelWeek() async throws {
        try habit("Run", checkedIn: Self.keys((5, 18), (5, 22)) + Self.keys((5, 25), (5, 29)))

        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Run": 71])
        XCTAssertTrue(has(appLocalized("Level with the previous week"), in: window))
        XCTAssertFalse(hasHighlights(in: window))
    }

    /// The thresholds (D8), Monday 06-01, last week against the one before:
    /// - Ten, begun Thursday 05-21: 3 of 4 (75) → 6 of 7 (85), +10: "Most improved" (10 is enough);
    /// - Nine, begun Wednesday 05-20: 4 of 5 (80) → 5 of 7 (71), −9: not "Slipped";
    /// - High: 100 → 85, −15, the largest drop, but at 85 % this week: never "Slipped";
    /// - Mild: 85 → 71, −14: "Slipped".
    func testTheHighlightThresholds() async throws {
        try habit("Ten", created: (5, 21), checkedIn: Self.keys((5, 21), (5, 23)) + Self.keys((5, 25), (5, 30)))
        try habit("Nine", created: (5, 20), checkedIn: Self.keys((5, 20), (5, 23)) + Self.keys((5, 25), (5, 29)))
        try habit("High", checkedIn: Self.keys((5, 18), (5, 24)) + Self.keys((5, 25), (5, 30)))
        try habit("Mild", checkedIn: Self.keys((5, 18), (5, 23)) + Self.keys((5, 25), (5, 29)))

        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Ten": 85, "Nine": 71, "High": 85, "Mild": 71])
        let improved = try XCTUnwrap(highlight("Most improved", in: window), "\(labels(in: window))")
        XCTAssertTrue(improved.contains("Ten"), improved)
        XCTAssertTrue(improved.contains(appLocalized("+\(10) points vs previous week")), improved)
        let slipped = try XCTUnwrap(highlight("Slipped", in: window), "\(labels(in: window))")
        XCTAssertTrue(slipped.contains("Mild"), "High is at 85 %, Nine moved 9: \(slipped)")
        XCTAssertTrue(slipped.contains(appLocalized("−\(14) points vs previous week")), slipped)
    }

    /// Moves under 10 points, and a drop at 80 % or more: no highlight, and no heading.
    func testNoHighlightWhenNothingQualifies() async throws {
        try habit("Nine", created: (5, 20), checkedIn: Self.keys((5, 20), (5, 23)) + Self.keys((5, 25), (5, 29)))
        try habit("High", checkedIn: Self.keys((5, 18), (5, 24)) + Self.keys((5, 25), (5, 30)))

        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Nine": 71, "High": 85])
        XCTAssertFalse(hasHighlights(in: window), "\(labels(in: window))")
        XCTAssertNil(highlight("Most improved", in: window))
        XCTAssertNil(highlight("Slipped", in: window))
    }

    /// A week not over is compared only from its fourth counted day (D8). Run was 4 of 7 (57) last
    /// week. Tuesday 06-02 evening, this week asked for, Monday and Tuesday done (100): the
    /// "+40"-style change 1.4.1 would print is not said, nor any highlight. Thursday 06-04 after its
    /// check-in, 4 days counted: "+43 points", and "Most improved" under "Highlights so far".
    func testNoChangeOrHighlightBeforeFourCountedDays() async throws {
        try habit("Run", checkedIn: Self.keys((5, 25), (5, 28)) + Self.keys((6, 1), (6, 4)))

        var window = try show(week: Self.key(6, 1), now: Self.local(6, 2, 20))
        try await waitUntil("this week, asked for") { self.has(appLocalized("This week so far"), in: window) }
        XCTAssertTrue(has(row("Run", 100), in: window), "\(labels(in: window))")
        XCTAssertFalse(hasChangeLine(in: window), "2 counted days: \(labels(in: window))")
        XCTAssertFalse(hasHighlights(in: window))

        window = try show(now: Self.local(6, 4, 20))
        try await waitUntil("Thursday's review") { self.has(appLocalized("This week so far"), in: window) }
        XCTAssertTrue(has(appLocalized("+\(43) points vs previous week"), in: window), "\(labels(in: window))")
        XCTAssertTrue(has(appLocalized("Highlights so far"), in: window), "\(labels(in: window))")
        XCTAssertFalse(has(appLocalized("Highlights"), in: window))
        XCTAssertEqual(highlight("Most improved", in: window).map { $0.contains("Run") }, true)
    }

    /// A brand-new user (W6 review, finding 4): a habit created this Monday, viewed on Tuesday,
    /// opens on this week, "so far", with its row (Monday done, 100 %), and no change or highlight
    /// from 1 counted day. Last week would have been one "Not started" row and no ring. Asked for
    /// last week (Today's card), it is that week: the row reads "Not started" — a single element,
    /// so its label and value, never a dash — and there is no ring.
    func testABrandNewUserOpensOnThisWeekAndLastWeekReadsNotStarted() async throws {
        try habit("New", created: (6, 1), checkedIn: [Self.key(6, 1)])

        var window = try show(now: Self.local(6, 2, 9))
        try await waitUntil("this week so far") { self.has(appLocalized("This week so far"), in: window) }
        XCTAssertFalse(has(appLocalized("Last week"), in: window))
        XCTAssertTrue(has(dates(of: Self.key(6, 1)), in: window), "\(labels(in: window))")
        XCTAssertTrue(has(row("New", 100), in: window), "\(labels(in: window))")
        XCTAssertFalse(hasChangeLine(in: window))
        XCTAssertFalse(hasHighlights(in: window))

        window = try show(week: Self.local(5, 25, 0), now: Self.local(6, 2, 9))
        try await waitUntil("last week, asked for") { self.has(appLocalized("Last week"), in: window) }
        let new = try XCTUnwrap(elements(in: window) { ($0.accessibilityLabel ?? "").hasPrefix("⭐ New") }.first,
                                "\(labels(in: window))")
        XCTAssertEqual(new.accessibilityLabel, "⭐ New", "no rate in the label")
        XCTAssertEqual(new.accessibilityValue, appLocalized("Not started"))
        XCTAssertFalse(labels(in: window).contains { $0.hasPrefix(appLocalized("Last week: \(0)%")) }, "no ring")
    }

    /// The clock on an exact UTC midnight (W6 review, finding 5): 2026-06-08 00:00:00 UTC is Sunday
    /// 17:00 in Los Angeles and Monday 09:00 in Tokyo. Run done Monday to Saturday, 3 of 7 the week
    /// before. West of UTC it is Sunday: this week so far, Sunday not yet a miss (100 %), +58
    /// points, "Highlights so far". The stats once keyed the instant itself as Monday's day-key, so
    /// that header sat over 85 % and a finished week's "Highlights". East of UTC it is Monday: last
    /// week, finished, Sunday missed (85 %), +43.
    func testTheClockOnAnExactUTCMidnight() async throws {
        try habit("Run", checkedIn: Self.keys((5, 25), (5, 27)) + Self.keys((6, 1), (6, 6)))
        let edge = Self.key(6, 8)

        let window = try show(now: edge)
        if TimeZone.current.secondsFromGMT(for: edge) < 0 {
            try await waitUntil("Sunday's review") { self.has(appLocalized("This week so far"), in: window) }
            XCTAssertTrue(has(dates(of: Self.key(6, 1)), in: window), "\(labels(in: window))")
            XCTAssertTrue(has(row("Run", 100), in: window), "Sunday not done is no miss: \(labels(in: window))")
            XCTAssertTrue(has(appLocalized("+\(58) points vs previous week"), in: window), "\(labels(in: window))")
            XCTAssertTrue(has(appLocalized("Highlights so far"), in: window), "\(labels(in: window))")
            XCTAssertFalse(has(appLocalized("Highlights"), in: window))
        } else {
            try await expectLastWeek(in: window, week: Self.key(6, 1), rows: ["Run": 85])
            XCTAssertTrue(has(appLocalized("+\(43) points vs previous week"), in: window), "\(labels(in: window))")
            XCTAssertTrue(has(appLocalized("Highlights"), in: window), "\(labels(in: window))")
        }
        XCTAssertEqual(highlight("Most improved", in: window).map { $0.contains("Run") }, true)
    }

    /// Pre-freeze review A3: no change line unless every row the ring counts is compared. Monday
    /// 06-01, last week: Up 3 of 7 (42) → 7 of 7, +58; New, begun Thursday 05-28 and never done,
    /// 0 % with no previous week. The ring is 50 %; "+58 points" would leave New out. Up is still
    /// "Most improved".
    func testNoChangeLineWhenARowTheRingCountsIsNotCompared() async throws {
        try habit("Up", checkedIn: Self.keys((5, 18), (5, 20)) + Self.keys((5, 25), (5, 31)))
        try habit("New", created: (5, 28), checkedIn: [])

        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Up": 100, "New": 0])
        XCTAssertTrue(has(appLocalized("Last week: \(50)%"), in: window), "\(labels(in: window))")
        XCTAssertFalse(hasChangeLine(in: window), "\(labels(in: window))")
        XCTAssertEqual(highlight("Most improved", in: window).map { $0.contains("Up") }, true, "\(labels(in: window))")
    }

    /// Pre-freeze review A6: Monday 06-01 evening, a Mon/Wed/Fri habit created Saturday 05-30 and
    /// done today. Last week had nothing due (no ring, a dash row), so the review opens on this
    /// week, "so far", with the row at 100 %.
    func testItOpensThisWeekWhenLastWeekHasNothingToCount() async throws {
        try habit("Gym", created: (5, 30), checkedIn: [Self.key(6, 1)], activeDays: (1 << 1) | (1 << 3) | (1 << 5))

        let window = try show(now: Self.local(6, 1, 20))
        try await waitUntil("this week so far") { self.has(appLocalized("This week so far"), in: window) }
        XCTAssertFalse(has(appLocalized("Last week"), in: window))
        XCTAssertTrue(has(dates(of: Self.key(6, 1)), in: window), "\(labels(in: window))")
        XCTAssertTrue(has(row("Gym", 100), in: window), "\(labels(in: window))")
    }

    /// The dates as written, not as the view's own helper writes them (W6 review, finding 7): a
    /// formatter one day early west of UTC ("May 24 – 30") fails here, in either zone.
    func testTheDatesAreTheWeeksOwnDays() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (5, 31)))
        let window = try show(now: Self.local(6, 1, 9))
        try await expectLastWeek(in: window, rows: ["Run": 100])
        let written = dates(of: Self.key(5, 25))
        let numbers = written.split { !$0.isNumber }.compactMap { Int($0) }
        XCTAssertTrue(numbers.contains(25) && numbers.contains(31), written)
        XCTAssertFalse(numbers.contains(24) || numbers.contains(30), "a day early: \(written)")
        if appLocale.language.languageCode == .english {
            let spaced = written.unicodeScalars
                .map { [0x2009, 0x202F, 0x00A0].contains($0.value) ? " " : String($0) }.joined()
            XCTAssertEqual(spaced, "May 25 – 31")
        }
    }

    // MARK: - 1.5.0 D6: any week, the strip, the chip, sections, perfect days, at risk

    /// A habit `configure` shapes, created on the day-key `created`, checked in on each of
    /// `checkedIn` (each record `value`), in `group` when given, saved; listed in the order made.
    @discardableResult
    private func habit(_ name: String, created: (Int, Int) = (5, 1), checkedIn: [Date], value: Double = 1,
                       group: HabitGroup? = nil, configure: (Habit) -> Void) throws -> Habit {
        let habit = Habit(name: name)
        configure(habit)
        habit.groupId = group?.id
        habit.createdAt = Self.key(created.0, created.1)
        habit.sortOrder = order
        order += 1
        context.insert(habit)
        habit.records = checkedIn.map { HabitRecord(date: $0, value: value) }
        try context.save()
        return habit
    }

    private static let monWedFri = (1 << 1) | (1 << 3) | (1 << 5)

    /// The mixed account D6 is about, for Saturday 06-06 (this week 06-01 … 06-07, last week
    /// 05-25 … 05-31):
    /// - Run, daily: done every day through Thursday 06-04; Friday missed; today open;
    /// - Gym, Mon/Wed/Fri: this week Monday and Friday, Wednesday missed;
    /// - Yoga, 3×/week: met by Thursday (Mon, Wed, Thu): no miss on any day;
    /// - Swim, 3×/week: one check-in this week, so at risk whatever the hour (2 owed, 2 days left:
    ///   every day left needed, the goal still within reach);
    /// - Water, a count habit (target 8): 8 on Monday, 3 on Tuesday (partial: missed), 8 on Wednesday;
    /// - New, daily, created Wednesday 06-03 and done that day;
    /// - Row, 7×/week: one check-in this week, 6 owed with 2 days left — out of reach, so NOT at
    ///   risk (RELEASE-1.5.0.md D7, integrator's call 2026-11-27).
    private func mixedAccount() throws -> (swim: Habit, yoga: Habit, row: Habit) {
        try habit("Run", checkedIn: Self.keys((5, 18), (6, 4)))
        try habit("Gym", checkedIn: [Self.key(5, 18), Self.key(5, 20), Self.key(5, 22), Self.key(5, 25), Self.key(5, 27),
                                     Self.key(6, 1), Self.key(6, 5)]) {
            $0.schedule = .specificDays
            $0.activeDaysMask = Self.monWedFri
        }
        let yoga = try habit("Yoga", checkedIn: [Self.key(5, 25), Self.key(5, 26), Self.key(6, 1), Self.key(6, 3), Self.key(6, 4)]) {
            $0.schedule = .timesPerWeek
            $0.timesPerWeek = 3
        }
        let swim = try habit("Swim", checkedIn: Self.keys((5, 25), (5, 28)) + [Self.key(6, 1)]) {
            $0.schedule = .timesPerWeek
            $0.timesPerWeek = 3
        }
        let water = try habit("Water", checkedIn: []) {
            $0.habitKind = .count
            $0.targetValue = 8
        }
        water.records = [HabitRecord(date: Self.key(5, 27), value: 8), HabitRecord(date: Self.key(6, 1), value: 8),
                         HabitRecord(date: Self.key(6, 2), value: 3), HabitRecord(date: Self.key(6, 3), value: 8)]
        try context.save()
        try habit("New", created: (6, 3), checkedIn: [Self.key(6, 3)]) { _ in }
        let rowing = try habit("Row", checkedIn: Self.keys((5, 25), (5, 31)) + [Self.key(6, 2)]) {
            $0.schedule = .timesPerWeek
            $0.timesPerWeek = 7
        }
        return (swim, yoga, rowing)
    }

    /// The habits as the review lists them (not archived, by `sortOrder`), with stats built by a
    /// cache of the test's own for `now`'s day: what every expected number is read from.
    private func expected(now: Date) throws -> (habits: [Habit], inputs: [WeeklyReviewMath.HabitInput], stats: [HabitStats]) {
        let habits = try context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { !$0.isArchived },
                                                              sortBy: [SortDescriptor(\.sortOrder)]))
        let stats = StatsCache().stats(for: habits, today: WeeklyReviewMath.today(now: now, calendar: .current),
                                       calendar: .current)
        return (habits, zip(habits, stats).map { WeeklyReviewMath.HabitInput(habit: $0, stats: $1) }, stats)
    }

    /// What the row's one element says of its strip (`WeeklyReviewView.stripValue`), as a string.
    private func stripWords(_ summary: WeeklyReviewMath.StripSummary) -> String {
        let completed = summary.done, total = summary.days, count = summary.rest
        if total == 0 { return "" }
        return count > 0 ? appLocalized("\(completed) of \(total) done, \(count) rest days")
            : appLocalized("\(completed) of \(total) done")
    }

    /// What the strength chip says.
    private func chipWords(_ points: Int) -> String {
        if points > 0 { return appLocalized("Strength +\(points)") }
        if points < 0 {
            let points = -points
            return appLocalized("Strength −\(points)")
        }
        return appLocalized("Strength unchanged")
    }

    /// Every row of `week` against WeeklyReviewMath (D6: "rows = WeeklyReviewMath"): the rate in
    /// the label, the strip's summary as the value of the SAME element (no element for a cell
    /// inside it), the chip after it with the strength change, the perfect days, and the at-risk
    /// rows (this week only).
    private func expectRowsAreTheMath(of week: WeeklyReviewMath.WeekRange, now: Date, isThisWeek: Bool,
                                      in window: UIWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let (habits, inputs, stats) = try expected(now: now)
        let groupOrder = try context.fetch(FetchDescriptor<HabitGroup>(sortBy: [SortDescriptor(\.sortOrder)])).map(\.id)
        let review = WeeklyReviewMath.review(of: inputs, week: week, groupOrder: groupOrder)
        let all = elements(in: window) { _ in true }
        for entry in review.rows {
            let habit = habits[entry.index]
            let id = "review.row.\(habit.id.uuidString)"
            let position = try XCTUnwrap(all.firstIndex { identifier(of: $0) == id }, "\(habit.name)'s row", file: file, line: line)
            let element = all[position]
            let label = entry.rate.map { row(habit.name, StatsInsights.percent($0)) } ?? "⭐ \(habit.name)"
            XCTAssertEqual(element.accessibilityLabel, label, habit.name, file: file, line: line)
            let summary = WeeklyReviewMath.stripSummary(of: stats[entry.index], week: week)
            let value = entry.rate == nil && entry.endsBeforeStart ? appLocalized("Not started") : stripWords(summary)
            XCTAssertEqual(element.accessibilityValue ?? "", value, "\(habit.name)'s strip, one value", file: file, line: line)
            let frame = element.accessibilityFrame
            let inside = all.filter { $0 !== element && !$0.accessibilityFrame.isEmpty && frame.contains($0.accessibilityFrame) }
            XCTAssertEqual(inside.map { $0.accessibilityLabel ?? "?" }, [], "\(habit.name): the strip is one element, no cell is a stop",
                           file: file, line: line)

            let next = position + 1 < all.count ? all[position + 1] : nil
            if let points = WeeklyReviewMath.strengthChangePoints(of: stats[entry.index], week: week) {
                XCTAssertEqual(next.flatMap(identifier(of:)), "review.strength", "\(habit.name)'s chip follows its row",
                               file: file, line: line)
                XCTAssertEqual(next?.accessibilityLabel, chipWords(points), habit.name, file: file, line: line)
            } else {
                XCTAssertNotEqual(next.flatMap(identifier(of:)), "review.strength", "\(habit.name): no chip", file: file, line: line)
            }
        }
        XCTAssertEqual(all.filter { identifier(of: $0)?.hasPrefix("review.row.") == true }.count, review.rows.count,
                       "one row per habit", file: file, line: line)

        let perfect = WeeklyReviewMath.perfectDayCount(of: inputs, week: week)
        let perfectLabel = all.first { identifier(of: $0) == "review.perfectDays" }?.accessibilityLabel
        if perfect > 0 {
            XCTAssertEqual(perfectLabel, appLocalized("\(perfect) perfect days"), file: file, line: line)
        } else {
            XCTAssertNil(perfectLabel, file: file, line: line)
        }

        let reminder = WeeklyReviewView.dailyReminderTime()
        let atRisk = isThisWeek ? review.rows.filter {
            WeeklyReviewMath.isAtRisk(habits[$0.index], stats: stats[$0.index], now: now, calendar: .current,
                                      dailyReminder: reminder)
        }.map { "review.atRisk.\(habits[$0.index].id.uuidString)" } : []
        XCTAssertEqual(all.compactMap(identifier(of:)).filter { $0.hasPrefix("review.atRisk.") }, atRisk,
                       "At risk this week: this week only, WeeklyReviewMath's habits in order", file: file, line: line)
        XCTAssertEqual(has(appLocalized("At risk this week"), in: window), !atRisk.isEmpty, file: file, line: line)
    }

    /// D6 on the mixed account, this week (Saturday 06-06) and last week: every row's numbers are
    /// WeeklyReviewMath's, and the strips say what a user can check: Run "4 of 5 done" beside its
    /// 80 % (Friday missed; today still open, so in neither, as the rate counts it), Gym "2 of 6
    /// done, 3 rest days", Yoga met on Thursday with no miss. Swim is at risk this week, Row (out of
    /// reach) is not, and nothing is "at risk" on last week.
    func testEachRowIsWeeklyReviewMathThisWeekAndLast() async throws {
        let (swim, yoga, rowing) = try mixedAccount()
        let now = Self.local(6, 6, 9)
        let window = try show(now: now)
        try await waitUntil("this week") { self.has(appLocalized("This week so far"), in: window) }
        let thisWeek = WeeklyReviewMath.WeekRange(containingDay: HabitStats.dayNumber(ofKey: Self.key(6, 1)))
        try expectRowsAreTheMath(of: thisWeek, now: now, isThisWeek: true, in: window)

        let values = Dictionary(elements(in: window) { self.identifier(of: $0)?.hasPrefix("review.row.") == true }
            .map { ($0.accessibilityLabel ?? "", $0.accessibilityValue ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(values[row("Run", 80)], appLocalized("\(4) of \(5) done"), "\(values): today open is not a day yet")
        XCTAssertEqual(values[row("Gym", 66)], appLocalized("\(2) of \(6) done, \(3) rest days"), "\(values)")
        XCTAssertEqual(values[row("Yoga", 100)], appLocalized("\(3) of \(6) done"), "\(values)")
        let (_, _, stats) = try expected(now: now)
        XCTAssertFalse(WeeklyReviewMath.dayStates(of: stats[2], week: thisWeek).contains(.missed), "Yoga met: no miss")
        XCTAssertNotNil(element("review.atRisk.\(swim.id.uuidString)", in: window), "Swim owes 2 with 2 days left")
        XCTAssertNil(element("review.atRisk.\(yoga.id.uuidString)", in: window), "Yoga is met")
        XCTAssertNil(element("review.atRisk.\(rowing.id.uuidString)", in: window), "Row owes 6 with 2 days left: out of reach")

        try page("previous", in: window)
        try await waitUntil("last week") { self.has(appLocalized("Last week"), in: window) }
        try expectRowsAreTheMath(of: thisWeek.previous, now: now, isThisWeek: false, in: window)
    }

    /// ‹ and › run from the week of the earliest habit's start to this week, each disabled at its
    /// end, labelled "Previous week" and "Next week" (D6). Paging reads the same cache entries:
    /// no rebuild after the first render.
    func testPagingStopsAtTheBoundsAndRebuildsNothing() async throws {
        try habit("Run", created: (5, 20), checkedIn: Self.keys((5, 20), (6, 3)))
        try habit("Read", created: (5, 27), checkedIn: Self.keys((5, 27), (6, 3)))
        let window = try show(now: Self.local(6, 4, 9))
        try await waitUntil("this week") { self.has(appLocalized("This week so far"), in: window) }
        let previous = try XCTUnwrap(element("review.previousWeek", in: window))
        let next = try XCTUnwrap(element("review.nextWeek", in: window))
        XCTAssertEqual(previous.accessibilityLabel, appLocalized("Previous week"))
        XCTAssertEqual(next.accessibilityLabel, appLocalized("Next week"))
        XCTAssertTrue(isEnabled(previous))
        XCTAssertFalse(isEnabled(next), "this week is the last")
        let built = cache.rebuildCount
        XCTAssertGreaterThan(built, 0)

        try page("previous", in: window)
        try await waitUntil("last week") { self.has(appLocalized("Last week"), in: window) }
        try page("previous", in: window)
        let first = dates(of: Self.key(5, 18))
        try await waitUntil("the week of the earliest start") { self.has(first, in: window) }
        XCTAssertTrue(has(row("Run", 100), in: window), "\(labels(in: window))")
        XCTAssertFalse(isEnabled(try XCTUnwrap(element("review.previousWeek", in: window))), "the earliest week is the first")
        XCTAssertTrue(isEnabled(try XCTUnwrap(element("review.nextWeek", in: window))))

        try page("next", in: window)
        try await waitUntil("last week again") { self.has(appLocalized("Last week"), in: window) }
        try page("next", in: window)
        try await waitUntil("this week again") { self.has(appLocalized("This week so far"), in: window) }
        XCTAssertFalse(isEnabled(try XCTUnwrap(element("review.nextWeek", in: window))))
        XCTAssertEqual(cache.rebuildCount, built, "every week read from the entries built for today")
    }

    /// Sections by group in the groups' order, Ungrouped last, each header with its members' mean
    /// counted rate (WeeklyReviewMath.sections), each member's row under its own header.
    func testSectionsByGroupWithTheirMeanRates() async throws {
        let evening = HabitGroup(name: "Evening", sortOrder: 1)
        let morning = HabitGroup(name: "Morning", sortOrder: 0)
        context.insert(evening)
        context.insert(morning)
        try context.save()
        try habit("Read", checkedIn: Self.keys((5, 25), (5, 31)), group: evening) { _ in }
        try habit("Run", checkedIn: Self.keys((5, 25), (5, 28)), group: morning) { _ in }
        try habit("Stretch", checkedIn: Self.keys((5, 25), (5, 29)), group: morning) { _ in }
        try habit("Floss", checkedIn: Self.keys((5, 25), (5, 26))) { _ in }
        let now = Self.local(6, 1, 9)

        let window = try show(now: now)
        try await waitUntil("last week") { self.has(appLocalized("Last week"), in: window) }
        let (habits, inputs, _) = try expected(now: now)
        let lastWeek = WeeklyReviewMath.WeekRange(containingDay: HabitStats.dayNumber(ofKey: Self.key(5, 25)))
        let sections = WeeklyReviewMath.review(of: inputs, week: lastWeek, groupOrder: [morning.id, evening.id]).sections
        XCTAssertEqual(sections.map(\.groupID), [morning.id, evening.id, nil])

        let all = elements(in: window) { _ in true }
        let headers = all.filter { identifier(of: $0) == "review.section" }
        let titles = ["Morning", "Evening", appLocalized("Ungrouped")]
        XCTAssertEqual(headers.map(\.accessibilityLabel), zip(titles, sections).map { title, section in
            appLocalized("\(title), \(StatsInsights.percent(section.rate!)) percent")
        })
        XCTAssertEqual(headers.first?.accessibilityLabel, appLocalized("\("Morning"), \(64) percent"), "Run 57, Stretch 71")
        // Each member's row between its header and the next.
        let ids = all.compactMap(identifier(of:)).filter { $0 == "review.section" || $0.hasPrefix("review.row.") }
        var expectedOrder: [String] = []
        for section in sections {
            expectedOrder.append("review.section")
            expectedOrder += section.members.map { "review.row.\(habits[$0].id.uuidString)" }
        }
        XCTAssertEqual(ids, expectedOrder)
        try expectRowsAreTheMath(of: lastWeek, now: now, isThisWeek: false, in: window)
    }

    /// Data safety 1 for the review's tap (D6): "At risk this week" dismisses the review (the
    /// shell's request goes), selects Today, re-anchors it to today — a day picked in the strip is
    /// let go — and names the habit for Today to focus. Nothing is written: the same rows, every
    /// `updatedAt` unchanged, no pending change. Today then consumes the id once.
    func testTheAtRiskTapSetsTheShellAndWritesNothing() async throws {
        let (swim, _, _) = try mixedAccount()
        let now = Self.local(6, 6, 9)
        let shell = ShellState(launchArguments: [], now: Self.local(6, 4, 12))
        shell.selection = .stats
        shell.todayDate = Self.local(6, 3, 12)   // a day picked in Today's strip, two days ago
        shell.request = .weeklyReview(week: nil)
        let before = try storeSnapshot()

        let window = try show(now: now, shell: shell)
        try await waitUntil("Swim at risk") { self.element("review.atRisk.\(swim.id.uuidString)", in: window) != nil }
        let tap = try XCTUnwrap(element("review.atRisk.\(swim.id.uuidString)", in: window))
        XCTAssertEqual(tap.accessibilityLabel, "⭐ Swim")
        XCTAssertTrue(tap.accessibilityTraits.contains(.button))
        XCTAssertTrue(tap.accessibilityActivate(), "the tap")

        XCTAssertNil(shell.request, "the review is dismissed")
        XCTAssertEqual(shell.selection, .today)
        XCTAssertEqual(shell.todayDate, now, "Today re-anchored to today")
        XCTAssertEqual(shell.todayAnchor, now)
        XCTAssertEqual(shell.todayFocusHabitID, swim.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(context.hasChanges, "nothing pending")
        XCTAssertEqual(try storeSnapshot(), before, "row counts and every updatedAt unchanged")

        XCTAssertEqual(shell.consumeTodayFocus(), swim.id)
        XCTAssertNil(shell.todayFocusHabitID, "consumed once")
        XCTAssertNil(shell.consumeTodayFocus())
    }

    /// `-openReview <yyyy-mm-dd>` (D6, beside this|last): the week containing that day, for Pro;
    /// Pro off, the paywall resuming it, as every other way in (D8). A day after this week opens
    /// this week; anything that is not a real date asks for nothing. Hosted, the review opens on
    /// that week, titled by its dates.
    func testTheOpenReviewDateArgumentAndProOff() async throws {
        let thursday = Self.local(6, 4, 9)
        func asked(_ value: String, isPro: Bool) -> ShellRequest? {
            StrideApp.launchReviewRequest(arguments: ["Stride", "-openReview", value], now: thursday,
                                          calendar: .current, isPro: isPro)
        }
        XCTAssertEqual(asked("2026-05-20", isPro: true), .weeklyReview(week: Self.key(5, 18)))
        XCTAssertEqual(asked("2026-05-24", isPro: true), .weeklyReview(week: Self.key(5, 18)), "a Sunday")
        XCTAssertEqual(asked("2026-05-25", isPro: true), .weeklyReview(week: Self.key(5, 25)), "a Monday")
        XCTAssertEqual(asked("2026-05-20", isPro: false),
                       .paywall(trigger: .weeklyReview, resume: .weeklyReview(week: Self.key(5, 18))))
        XCTAssertEqual(asked("2027-01-04", isPro: true), .weeklyReview(week: Self.key(6, 1)), "later: this week")
        XCTAssertEqual(asked("this", isPro: true), .weeklyReview(week: Self.key(6, 1)))
        for bad in ["2026-02-30", "2026-5-20", "20260520", "yesterday", ""] {
            XCTAssertNil(asked(bad, isPro: true), bad)
        }

        // Pro off, the review's button and Today's card still latch the paywall (D8, unchanged).
        let shell = ShellState(launchArguments: [])
        XCTAssertTrue(shell.issue(.weeklyReviewButton, isPro: false))
        XCTAssertEqual(shell.request, .paywall(trigger: .weeklyReview, resume: .weeklyReview(week: nil)))

        try habit("Run", checkedIn: Self.keys((5, 1), (6, 3)))
        let window = try show(week: Self.key(5, 18), now: thursday)
        let shown = dates(of: Self.key(5, 18))
        try await waitUntil("the week of 05-20") { self.has(shown, in: window) }
        XCTAssertTrue(has(row("Run", 100), in: window))
        XCTAssertFalse(has(appLocalized("At risk this week"), in: window))
    }

    /// Every row's updatedAt by its identity, and the row counts: what Data safety 1 compares.
    private struct StoreSnapshot: Equatable {
        let counts: [Int]
        let stamps: [PersistentIdentifier: Date?]
    }

    private func storeSnapshot() throws -> StoreSnapshot {
        let habits = try context.fetch(FetchDescriptor<Habit>())
        let records = try context.fetch(FetchDescriptor<HabitRecord>())
        let groups = try context.fetch(FetchDescriptor<HabitGroup>())
        var stamps: [PersistentIdentifier: Date?] = [:]
        for h in habits { stamps[h.persistentModelID] = h.updatedAt }
        for r in records { stamps[r.persistentModelID] = r.updatedAt }
        for g in groups { stamps[g.persistentModelID] = g.updatedAt }
        return StoreSnapshot(counts: [habits.count, records.count, groups.count], stamps: stamps)
    }

    private func page(_ direction: String, in window: UIWindow) throws {
        let button = try XCTUnwrap(element("review.\(direction)Week", in: window), direction)
        XCTAssertTrue(isEnabled(button), direction)
        XCTAssertTrue(button.accessibilityActivate(), direction)
    }

    private func isEnabled(_ element: NSObject) -> Bool {
        !element.accessibilityTraits.contains(.notEnabled)
    }

    /// The element whose accessibility identifier is `id`.
    private func element(_ id: String, in window: UIWindow) -> NSObject? {
        elements(in: window) { self.identifier(of: $0) == id }.first
    }

    /// An element's accessibility identifier, which SwiftUI's elements answer without adopting
    /// UIAccessibilityIdentification in their type (as PaywallRenderTests).
    private func identifier(of element: NSObject) -> String? {
        if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    // MARK: - Expectations

    /// "Last week" over the dates of the week of `week` (05-25 … 05-31 unless given), never "This
    /// week so far", and each habit's row with its rate: no dash row.
    private func expectLastWeek(in window: UIWindow, week: Date? = nil, rows: [String: Int],
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let week = week ?? Self.key(5, 25)
        try await waitUntil("last week's review") { self.has(appLocalized("Last week"), in: window) }
        XCTAssertFalse(has(appLocalized("This week so far"), in: window), file: file, line: line)
        XCTAssertTrue(has(dates(of: week), in: window),
                      "last week's dates \(dates(of: week)): \(labels(in: window))", file: file, line: line)
        for (name, percent) in rows {
            XCTAssertTrue(has(row(name, percent), in: window), "\(name) at \(percent): \(labels(in: window))",
                          file: file, line: line)
        }
        let expected = Set(rows.map { row($0.key, $0.value) })
        XCTAssertEqual(labels(in: window).filter { $0.hasPrefix("⭐ ") }.count, rows.count,
                       "one row per habit: \(labels(in: window))", file: file, line: line)
        XCTAssertTrue(labels(in: window).filter { $0.hasPrefix("⭐ ") }.allSatisfy(expected.contains),
                      "a row without a rate: \(labels(in: window))", file: file, line: line)
    }

    /// The row's VoiceOver label for a habit at `percent`.
    private func row(_ name: String, _ percent: Int) -> String {
        appLocalized("\("⭐") \(name), \(percent) percent")
    }

    /// The review's dates for the week of `monday`, a day-key, as the view writes them.
    private func dates(of monday: Date) -> String {
        WeeklyReviewView.dates(of: WeeklyReviewMath.WeekRange(containingDay: HabitStats.dayNumber(ofKey: monday)),
                               today: Self.key(6, 1), locale: appLocale)
    }

    private func hasChangeLine(in window: UIWindow) -> Bool {
        var lines: Set<String> = [appLocalized("Level with the previous week")]
        for points in 1...100 {
            lines.insert(appLocalized("+\(points) points vs previous week"))
            lines.insert(appLocalized("−\(points) points vs previous week"))
        }
        return labels(in: window).contains(where: lines.contains)
    }

    private func hasHighlights(in window: UIWindow) -> Bool {
        has(appLocalized("Highlights"), in: window) || has(appLocalized("Highlights so far"), in: window)
    }

    /// The highlight row whose label starts with `title` ("Most improved", "Slipped").
    private func highlight(_ title: String.LocalizationValue, in window: UIWindow) -> String? {
        let prefix = appLocalized(title)
        return labels(in: window).first { $0.hasPrefix(prefix) && $0 != prefix }
    }

    // MARK: - Hosting

    /// The review at `now`, opened on `week` when given, over this test's store and cache, in the
    /// picked language's locale, in a window of its own on the host app's scene (replacing any
    /// earlier one), with the accessibility tree built.
    private func show(week: Date? = nil, now: Date, shell: ShellState? = nil) throws -> UIWindow {
        closeWindow()
        if automation == nil {
            automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AnyView(
            WeeklyReviewView(week: week, now: now, shell: shell)
                .modelContainer(container)
                .environment(\.statsCache, cache)
                .environment(\.locale, LanguageManager.shared.locale ?? .current)))
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func closeWindow() {
        guard let window else { return }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene?.windows.first { $0 !== window }?.makeKey()
        self.window = nil
    }

    private func has(_ label: String, in window: UIWindow) -> Bool {
        !elements(in: window) { $0.accessibilityLabel == label }.isEmpty
    }

    private func labels(in window: UIWindow) -> [String] {
        elements(in: window) { _ in true }.compactMap(\.accessibilityLabel)
    }

    /// The distinct accessibility elements under `root` that `matches`, in tree order.
    private func elements(in root: NSObject, where matches: (NSObject) -> Bool) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        collect(in: root, where: matches, seen: &seen, found: &found, depth: 0)
        return found
    }

    private func collect(in root: NSObject, where matches: (NSObject) -> Bool,
                         seen: inout Set<ObjectIdentifier>, found: inout [NSObject], depth: Int) {
        guard depth < 80 else { return }
        if root.isAccessibilityElement, matches(root), seen.insert(ObjectIdentifier(root)).inserted {
            found.append(root)
        }
        if root.accessibilityElementsHidden { return }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView {
            guard !view.isHidden else { return }
            children += view.subviews
        }
        for child in children {
            collect(in: child, where: matches, seen: &seen, found: &found, depth: depth + 1)
        }
    }

    /// Lets SwiftUI and UIKit run until `condition` holds, or fails after five seconds.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting: \(what)")
                throw XCTSkip("timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
