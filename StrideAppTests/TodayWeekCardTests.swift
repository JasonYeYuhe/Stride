import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// Today's "Your week" card drawn (RELEASE-1.4.2.md D12, W7), its state in UserDefaults, and the
/// review prompt's no-call guarantee under `-demo` and test flags (N3).
///
/// - The card: the real `TodayWeekCard`, Pro and free copy, read off the accessibility tree; its
///   buttons through their accessibility actions. And `TodayCards.card` over a store and a
///   `StatsCache` of this test's own: the number is the review's for last week.
/// - The prompt: the real `ReviewPrompter` — the same code in Release, no `#if DEBUG` in it or in
///   `ReviewPromptRule` — with every other condition true, under launch arguments and XCTest
///   environments: the system's request is never made. A control case with none of them asks once.
@MainActor
final class TodayWeekCardTests: XCTestCase {

    private var window: UIWindow?
    private var automation: Bool?
    private var scratch: ScratchDefaults!

    override func setUp() async throws {
        try await super.setUp()
        scratch = ScratchDefaults("todayWeekCard")
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        if let automation { AccessibilityAutomation.restore(automation) }
        automation = nil
        scratch.remove()
        scratch = nil
        try await super.tearDown()
    }

    private static func mondayNumber(_ month: Int, _ day: Int) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.utc.date(from: DateComponents(year: 2026, month: month, day: day))!)
    }

    private let week = WeeklyReviewMath.WeekRange(containingDay: TodayWeekCardTests.mondayNumber(6, 1))

    // MARK: - The card's copy

    func testProCopyStatesLastWeeksPercent() async throws {
        let window = try show(InlinePrompts.WeekCard(shownWeek: week, copy: .pro(percent: 82)))
        try await waitUntil("the Pro card") { self.has(appLocalized("Last week: \(82)%"), in: window) }
        XCTAssertTrue(has(appLocalized("See your Weekly Review"), in: window), "\(labels(in: window))")
        XCTAssertTrue(has(appLocalized("Hide until next week"), in: window))
        XCTAssertFalse(has(appLocalized("Your Weekly Review is ready"), in: window))
        XCTAssertFalse(has(appLocalized("Don't show again"), in: window))
    }

    /// The free line has no number anywhere on the card.
    func testFreeCopyHasNoNumber() async throws {
        let window = try show(InlinePrompts.WeekCard(shownWeek: week, copy: .free))
        try await waitUntil("the free card") { self.has(appLocalized("Your Weekly Review is ready"), in: window) }
        XCTAssertTrue(has(appLocalized("See your Weekly Review"), in: window))
        XCTAssertTrue(has(appLocalized("Don't show again"), in: window))
        let all = labels(in: window)
        XCTAssertFalse(all.joined().contains(where: \.isNumber), "a number on the free card: \(all)")
        XCTAssertFalse(all.contains { $0.contains("%") })
    }

    func testTheButtonsOpenAndDismiss() async throws {
        var opened = 0, dismissed = 0
        let window = try show(InlinePrompts.WeekCard(shownWeek: week, copy: .free),
                              onOpen: { opened += 1 }, onDismiss: { dismissed += 1 })
        let open = try await element(labelled: appLocalized("See your Weekly Review"), in: window)
        XCTAssertTrue(open.accessibilityActivate())
        let close = try await element(labelled: appLocalized("Don't show again"), in: window)
        XCTAssertTrue(close.accessibilityActivate())
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(dismissed, 1)
    }

    // MARK: - The card from the store

    /// On a Monday, a habit done every day last week: Pro's card says 100 %, the review's number for
    /// last week; a free user's has no number; on the Wednesday there is none; DEBUG's `none` hides
    /// it and `week` forces it.
    func testTheCardReadsLastWeeksReview() throws {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let utc = HabitCalendar.utc
        let habit = Habit(name: "Run")
        habit.createdAt = utc.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        context.insert(habit)
        var day = utc.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let end = utc.date(from: DateComponents(year: 2026, month: 5, day: 31))!
        while day <= end {
            habit.records.append(HabitRecord(date: day))
            day = utc.date(byAdding: .day, value: 1, to: day)!
        }
        try context.save()
        let cache = StatsCache()
        let calendar = Calendar.current
        let monday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!

        XCTAssertEqual(TodayCards.card(habits: [habit], cache: cache, now: monday, calendar: calendar, isPro: true,
                                       state: .empty),
                       .week(.init(shownWeek: week, copy: .pro(percent: 100))))
        XCTAssertEqual(TodayCards.card(habits: [habit], cache: cache, now: monday, calendar: calendar, isPro: false,
                                       state: .empty),
                       .week(.init(shownWeek: week, copy: .free)))
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9))!
        XCTAssertNil(TodayCards.card(habits: [habit], cache: cache, now: wednesday, calendar: calendar, isPro: true,
                                     state: .empty))
        XCTAssertNil(TodayCards.card(habits: [habit], cache: cache, now: monday, calendar: calendar, isPro: true,
                                     state: .empty, override: .hidden))
        XCTAssertNotNil(TodayCards.card(habits: [habit], cache: cache, now: wednesday, calendar: calendar, isPro: true,
                                        state: .empty, override: .forced))
        XCTAssertNil(TodayCards.card(habits: [], cache: cache, now: monday, calendar: calendar, isPro: true,
                                     state: .empty), "no habits: no rate, no card")
        withExtendedLifetime(container) {}
    }

    /// The dismissal state round-trips through its defaults, and starts empty.
    func testTheDismissalStateLivesInItsDefaults() {
        let store = InlinePromptStore(defaults: scratch.defaults)
        XCTAssertEqual(store.state, .empty)
        let state = InlinePrompts.DismissalState(proHiddenWeek: 20_605, freeWeeksShown: [20_598, 20_605], freeEnded: true)
        store.save(state)
        XCTAssertEqual(InlinePromptStore(defaults: scratch.defaults).state, state)
        store.save(.empty)
        XCTAssertEqual(store.state, .empty)
    }

    // MARK: - The review prompt (N3): never under -demo or test flags

    private static let app = "/private/var/containers/Bundle/Application/X/Stride.app/Stride"

    private let milestone = ReviewPromptRule.CheckIn(unit: .day, completesDay: true, isToday: true,
                                                     streakBefore: 6, streakAfter: 7)

    /// A prompter whose every other condition holds: installed 10 days ago, onboarded, nothing asked
    /// in this version.
    private func prompter(arguments: [String], environment: [String: String] = [:]) -> ReviewPrompter {
        let now = Date()
        scratch.defaults.set(now.addingTimeInterval(-10 * 86_400), forKey: ReviewPrompter.installDateKey)
        scratch.defaults.set(true, forKey: ReviewPrompter.onboardingCompletedKey)
        scratch.defaults.removeObject(forKey: ReviewPrompter.promptedVersionKey)
        return ReviewPrompter(defaults: scratch.defaults, arguments: arguments, environment: environment,
                              appVersion: "1.4.2", now: { now })
    }

    func testTheControlCaseAsksOnceThisVersion() {
        var requests = 0
        let prompter = prompter(arguments: [Self.app])
        XCTAssertEqual(prompter.afterCheckIn(milestone, sheetShowing: false) { requests += 1 }, .ask)
        XCTAssertEqual(requests, 1, "with no flag, the same path asks: the no-call cases below can fail")
        XCTAssertEqual(prompter.afterCheckIn(milestone, sheetShowing: false) { requests += 1 },
                       .skip(.alreadyAskedThisVersion))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(scratch.defaults.string(forKey: ReviewPrompter.promptedVersionKey), "1.4.2")
    }

    func testNeverUnderDemoOrUITestFlags() {
        let flagSets: [[String]] = [
            ["-demo"], ["-demo", "-demoPro"], ["-demo", "-demoScenario", "details"], ["-paywall"],
            ["-demo", "-stride_onboarding_completed", "YES", "-tab", "0"], ["-inlineCard", "week"],
            ["-paywallFixture", "ready"], ["-UITesting"], ["-NSDocumentRevisionsDebugMode", "YES"],
        ]
        for flags in flagSets {
            var requests = 0
            let decision = prompter(arguments: [Self.app] + flags).afterCheckIn(milestone, sheetShowing: false) {
                requests += 1
            }
            XCTAssertEqual(decision, .skip(.automatedRun), "\(flags)")
            XCTAssertEqual(requests, 0, "\(flags)")
            XCTAssertNil(scratch.defaults.string(forKey: ReviewPrompter.promptedVersionKey), "\(flags): nothing recorded")
        }
        for key in ReviewPromptRule.xcTestEnvironmentKeys {
            var requests = 0
            _ = prompter(arguments: [Self.app], environment: [key: "/x"]).afterCheckIn(milestone, sheetShowing: false) {
                requests += 1
            }
            XCTAssertEqual(requests, 0, key)
        }
    }

    /// The app's own prompter, as Today builds it, in this hosted run: an XCTest process, so it never
    /// asks, whatever the state of the host's defaults.
    func testTheLivePrompterNeverAsksInThisRun() {
        let live = ReviewPrompter.live
        XCTAssertTrue(live.context(sheetShowing: false).automatedRun)
        var requests = 0
        let decision = ReviewPrompter(defaults: scratch.defaults, arguments: live.arguments,
                                      environment: live.environment, appVersion: "1.4.2", now: { Date() })
            .afterCheckIn(milestone, sheetShowing: false) { requests += 1 }
        XCTAssertEqual(decision, .skip(.automatedRun))
        XCTAssertEqual(requests, 0)
    }

    /// The install date is recorded once and never moved.
    func testTheInstallDateIsRecordedOnce() {
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        var clock = first
        let prompter = ReviewPrompter(defaults: scratch.defaults, arguments: [Self.app], environment: [:],
                                      appVersion: "1.4.2", now: { clock })
        XCTAssertNil(prompter.installDate)
        prompter.recordInstallDateIfNeeded()
        clock = first.addingTimeInterval(86_400)
        prompter.recordInstallDateIfNeeded()
        XCTAssertEqual(prompter.installDate, first)
        // A milestone the next day: too soon, and nothing asked.
        var requests = 0
        scratch.defaults.set(true, forKey: ReviewPrompter.onboardingCompletedKey)
        XCTAssertEqual(prompter.afterCheckIn(milestone, sheetShowing: false) { requests += 1 }, .skip(.tooSoonAfterInstall))
        XCTAssertEqual(requests, 0)
    }

    // MARK: - Hosting

    private func show(_ card: InlinePrompts.WeekCard, onOpen: @escaping () -> Void = {},
                      onDismiss: @escaping () -> Void = {}) throws -> UIWindow {
        if automation == nil {
            automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        }
        let view = TodayWeekCard(card: card, onOpen: onOpen, onDismiss: onDismiss)
            .padding()
            .environment(\.locale, LanguageManager.shared.locale ?? .current)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        let controller = UIHostingController(rootView: AnyView(view))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = self.window ?? UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func has(_ label: String, in window: UIWindow) -> Bool {
        labels(in: window).contains(label)
    }

    private func element(labelled label: String, in window: UIWindow) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil(label) {
            found = self.elements(in: window) { $0.accessibilityLabel == label }.first
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func labels(in window: UIWindow) -> [String] {
        elements(in: window) { _ in true }.compactMap(\.accessibilityLabel)
    }

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
