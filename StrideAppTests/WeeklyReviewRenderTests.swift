import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// Weekly Review, step 1 (RELEASE-1.4.2.md D8, W6), hosted: the real WeeklyReviewView over a store
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
    private func habit(_ name: String, created: (Int, Int) = (5, 1), checkedIn: [Date]) throws -> Habit {
        let habit = Habit(name: name)
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
    private func show(week: Date? = nil, now: Date) throws -> UIWindow {
        closeWindow()
        if automation == nil {
            automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AnyView(
            WeeklyReviewView(week: week, now: now)
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
