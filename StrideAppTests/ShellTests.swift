import XCTest
import SwiftUI
import SwiftData
@testable import Stride

/// The shell (RELEASE-1.4.0.md D2; D7, "the shell"): the real ContentView in a window of its own,
/// at regular width through the hosting controller's trait override, over an injected
/// ShellState and an in-memory store.
///
/// "Keeps the date" is true by construction once the date lives in ShellState, so these tests
/// watch what a regression to the 1.3.x `switch` would break (design review,
/// "shell-hosted-test-shape"): a tab's root is created ONCE however often the selection moves
/// (`ShellTabLifetime`, a `@StateObject` — @State survives exactly as long); a hidden tab is out of
/// VoiceOver's reach and contributes no toolbar item; a size-class crossing rebuilds the layout
/// but not the selection, the day, its anchor or the Stats habit; a request the shell presents
/// needs no tab to have been visited; and Today is re-anchored on the day change and on being
/// opened, whether or not it exists.
///
/// The views read the app's shared services (AuthService, SyncService, StoreService); signed out
/// or not, Today and Stats only read them here. Settings, whose refreshes write, is never opened.
@MainActor
final class ShellTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var host: UIHostingController<AnyView>?
    private var window: UIWindow?
    private var automation: Bool?

    /// Two habits: Stats' toolbar item exists only with habits, and the second one is a pick
    /// that differs from Stats' default (the first).
    private let first = "Shell Probe Read"
    private let second = "Shell Probe Walk"
    private var secondID: UUID!

    /// Containers a hosted view used, kept for the life of the process: SwiftUI can run a view's
    /// task after its window is gone, and a ModelContext whose container was released traps.
    private static var retiredContainers: [ModelContainer] = []

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        let read = Habit(name: first)
        read.sortOrder = 0
        let walk = Habit(name: second)
        walk.sortOrder = 1
        context.insert(read)
        context.insert(walk)
        try context.save()
        secondID = walk.id
        // SwiftUI builds the elements an assistive technology reads only while one is running;
        // this is how XCUITest has it build them in an app under test.
        automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
    }

    override func tearDown() async throws {
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
        }
        window = nil
        host = nil
        if let automation { AccessibilityAutomation.restore(automation) }
        if let container { Self.retiredContainers.append(container) }
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Keep-alive

    /// Acceptance (1)'s "Today → Stats → Today keeps scroll position", by the thing that holds the
    /// scroll position: the tab's view. Each tab is created on its first visit and never again,
    /// Stats not before it is opened. After every switch exactly one tab's toolbar item is in the
    /// window, and the hidden tab's content is out of the accessibility tree.
    ///
    /// Checked against mutations (W5): a `switch` detail fails the creation counts; an ungated
    /// toolbar item fails the toolbar count; both tabs drawn fails the content check. Removing
    /// only `.accessibilityHidden` does not: on the iOS 26.5 runtime SwiftUI also leaves
    /// opacity-0 content out of the tree. The modifier says it on every version; this holds the
    /// outcome.
    func testTabsAreCreatedOnceAndHiddenTabsAreOutOfReach() async throws {
        let shell = ShellState(launchArguments: [])
        let window = try await hostShell(shell)
        try await waitUntil("Today is created") { shell.tabCreations[.today] == 1 }
        XCTAssertNil(shell.tabCreations[.stats], "Stats is created on its first visit, not at launch")
        try await expectShowing(.today, in: window)

        shell.selection = .stats
        try await waitUntil("Stats is created") { shell.tabCreations[.stats] == 1 }
        try await expectShowing(.stats, in: window)

        shell.selection = .today
        try await expectShowing(.today, in: window)

        shell.selection = .stats
        try await expectShowing(.stats, in: window)

        XCTAssertEqual(shell.tabCreations[.today], 1, "Today kept, not rebuilt: its @State and scroll position survive")
        XCTAssertEqual(shell.tabCreations[.stats], 1, "Stats kept, not rebuilt")
        XCTAssertNil(shell.tabCreations[.settings], "Settings never opened, never created")
    }

    // MARK: - Size-class crossing

    /// A Pro Max rotating, an iPad window resized into compact width and back: the layout is
    /// rebuilt (the tab bar's Stats is a new view), the shell is not. Stats still shows the habit
    /// picked before the crossing — the view reads it from the shell.
    func testACompactRegularCrossingKeepsTheSelectionDayAnchorAndHabit() async throws {
        let shell = ShellState(launchArguments: [])
        shell.selection = .stats
        shell.statsHabitID = secondID
        let picked = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: shell.todayAnchor))
        shell.todayDate = picked   // a day picked in the week strip
        let anchor = shell.todayAnchor
        let window = try await hostShell(shell)
        try await waitUntil("Stats is created") { shell.tabCreations[.stats] == 1 }
        _ = try await element(labeled: appLocalized("\(second), selected"), in: window)

        host?.traitOverrides.horizontalSizeClass = .compact
        try await waitUntil("the tab bar's Stats replaces the split view's") { shell.tabCreations[.stats] == 2 }
        assertUnchanged(shell, picked: picked, anchor: anchor)
        _ = try await element(labeled: appLocalized("\(second), selected"), in: window)

        host?.traitOverrides.horizontalSizeClass = .regular
        try await waitUntil("the split view's Stats is back") { shell.tabCreations[.stats] == 3 }
        assertUnchanged(shell, picked: picked, anchor: anchor)
        _ = try await element(labeled: appLocalized("\(second), selected"), in: window)
    }

    private func assertUnchanged(_ shell: ShellState, picked: Date, anchor: Date,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(shell.selection, .stats, file: file, line: line)
        XCTAssertEqual(shell.todayDate, picked, "the picked day", file: file, line: line)
        XCTAssertEqual(shell.todayAnchor, anchor, file: file, line: line)
        XCTAssertEqual(shell.statsHabitID, secondID, "the picked habit", file: file, line: line)
    }

    // MARK: - Requests

    /// View → Weekly Review before Stats was ever opened (W6's ⇧⌘R): the shell presents it, so no
    /// tab has to exist to present it — the review for Pro, the paywall otherwise, as Stats' own
    /// button. Dismissing it clears the request, so the next one presents again.
    func testAWeeklyReviewRequestIsPresentedBeforeStatsWasEverVisited() async throws {
        let shell = ShellState(launchArguments: [])
        let window = try await hostShell(shell)
        try await waitUntil("Today is created") { shell.tabCreations[.today] == 1 }

        shell.request = .weeklyReview
        try await waitUntil("the sheet is presented") { self.host?.presentedViewController != nil }
        let sheet = try XCTUnwrap(host?.presentedViewController)
        // WeeklyReviewView's Done, or the paywall's Restore Purchases.
        let marker = StoreService.shared.isPro ? appLocalized("Done") : appLocalized("Restore Purchases")
        _ = try await element(labeled: marker, in: sheet.view)
        XCTAssertNil(shell.tabCreations[.stats], "presented with no StatsView behind it")
        XCTAssertEqual(shell.selection, .today, "and without moving the window to Stats")

        try await dismissSheet()
        try await waitUntil("the dismissal clears the request") { shell.request == nil }

        shell.request = .weeklyReview
        try await waitUntil("a second request is presented again") { self.host?.presentedViewController != nil }
        _ = try await element(labeled: marker, in: try XCTUnwrap(host?.presentedViewController).view)
        try await dismissSheet()
        try await waitUntil("cleared again") { shell.request == nil }
        _ = window
    }

    /// An export request is the Mac menu's (W6): written first, then a save panel. It is never a
    /// sheet here.
    func testAnExportRequestIsNotPresentedAsASheet() async throws {
        let shell = ShellState(launchArguments: [])
        _ = try await hostShell(shell)
        try await waitUntil("Today is created") { shell.tabCreations[.today] == 1 }
        shell.request = .export(.csv)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(host?.presentedViewController)
        XCTAssertEqual(shell.request, .export(.csv), "left for its own presenter")
        XCTAssertEqual(ShellRequest.Export.csv.file, .csv)
        XCTAssertEqual(ShellRequest.Export.json.file, .ownerBackup)
    }

    // MARK: - Re-anchoring

    /// Midnight passes with Today open since yesterday: the shell moves it to the new day, and the
    /// title still says Today — of the new day.
    func testTheDayChangeReanchorsToday() async throws {
        let shell = ShellState(launchArguments: [])
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        shell.todayDate = yesterday
        shell.todayAnchor = yesterday   // "today" when the screen was last anchored
        _ = try await hostShell(shell)
        try await waitUntil("Today is created") { shell.tabCreations[.today] == 1 }
        XCTAssertEqual(shell.todayTitle, appLocalized("Today"), "yesterday's Today, before the change")

        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        try await waitUntil("re-anchored to the new day") { Calendar.current.isDateInToday(shell.todayDate) }
        XCTAssertTrue(Calendar.current.isDateInToday(shell.todayAnchor))
        XCTAssertEqual(shell.todayTitle, appLocalized("Today"))
    }

    /// The bug TodaySelection exists for, on the path the 1.3.x `switch` covered by recreating
    /// TodayView: launched on Stats yesterday, Today never created, opened today. It must open on
    /// today, not credit check-ins to yesterday.
    func testOpeningTodayReanchorsItEvenIfItWasNeverCreated() async throws {
        let shell = ShellState(launchArguments: ["Stride", "-tab", "1"])
        XCTAssertEqual(shell.selection, .stats)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        shell.todayDate = yesterday
        shell.todayAnchor = yesterday
        _ = try await hostShell(shell)
        try await waitUntil("Stats is created") { shell.tabCreations[.stats] == 1 }
        XCTAssertNil(shell.tabCreations[.today])
        XCTAssertFalse(Calendar.current.isDateInToday(shell.todayDate), "precondition: still yesterday")

        shell.selection = .today
        try await waitUntil("re-anchored as Today opens") { Calendar.current.isDateInToday(shell.todayDate) }
        try await waitUntil("Today is created") { shell.tabCreations[.today] == 1 }
    }

    /// Within the same day re-anchoring writes nothing: a day picked in the strip stays picked.
    func testReanchorWithinTheDayKeepsAPickedDay() throws {
        let shell = ShellState(launchArguments: [])
        let picked = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: shell.todayAnchor))
        shell.todayDate = picked
        shell.reanchor(now: shell.todayAnchor.addingTimeInterval(60))
        XCTAssertEqual(shell.todayDate, picked)
    }

    // MARK: - Selection

    /// The sidebar's selection is never empty, and never a place the platform has no row for: the
    /// Mac's keep-alive stack has no Settings slot, so landing there is Today (as `-tab 2` is).
    func testTheSelectionAlwaysNamesAPlaceTheShellHas() {
        let mac = ShellState(launchArguments: ["Stride", "-tab", "2"], platform: .macOS)
        XCTAssertEqual(mac.selection, .today)
        XCTAssertTrue(mac.opensSettingsAtLaunch)
        mac.selection = .settings
        XCTAssertEqual(mac.selection, .today)
        XCTAssertTrue(mac.isCreated(.today))

        let iPad = ShellState(launchArguments: ["Stride", "-tab", "2"], platform: .iOS)
        XCTAssertEqual(iPad.selection, .settings)
        XCTAssertFalse(iPad.opensSettingsAtLaunch)
        XCTAssertEqual(iPad.visited, [.settings])
        iPad.selection = .stats
        XCTAssertEqual(iPad.visited, [.settings, .stats])
    }

    // MARK: - Hosting

    /// ContentView as the app shows it (over this test's store, in the picked language's locale),
    /// in a window of its own on the host app's scene, key and visible so SwiftUI presents its
    /// sheets — at regular width: an iPhone host is compact, and the override is what the split
    /// view and ContentView's branch both read.
    private func hostShell(_ shell: ShellState) async throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(
            ContentView(shell: shell)
                .modelContainer(container)
                .environment(\.locale, LanguageManager.shared.locale ?? .current)))
        host.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
        try await waitUntil("the regular-width branch: a split view, not the tab bar") { Self.containsSplitView(host) }
        return window
    }

    /// Whether `controller` holds the split view NavigationSplitView builds — the regular branch.
    private static func containsSplitView(_ controller: UIViewController) -> Bool {
        if controller is UISplitViewController { return true }
        return controller.children.contains { containsSplitView($0) }
    }

    /// The place `tab` is showing: its toolbar item is the window's only one of the two, and the
    /// other tab's content is not in the accessibility tree.
    private func expectShowing(_ tab: ShellTab, in window: UIWindow,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let newHabit = appLocalized("New Habit")
        let weeklyReview = appLocalized("Weekly Review")
        // Today's row and Stats' chip for the same habit: each exists only in its own tab.
        let todayRow = appLocalized("\(first), not completed")
        let statsChip = appLocalized("\(first), selected")
        let (shownItem, hiddenItem) = tab == .today ? (newHabit, weeklyReview) : (weeklyReview, newHabit)
        let (shownContent, hiddenContent) = tab == .today ? (todayRow, statsChip) : (statsChip, todayRow)

        try await waitUntil("\(tab)'s toolbar item and content") {
            self.count(labeled: shownItem, in: window) == 1 && self.count(labeled: shownContent, in: window) >= 1
                && self.count(labeled: hiddenItem, in: window) == 0 && self.count(labeled: hiddenContent, in: window) == 0
        }
        XCTAssertEqual(count(labeled: shownItem, in: window), 1, "exactly one primary action", file: file, line: line)
        XCTAssertEqual(count(labeled: hiddenItem, in: window), 0, "the hidden tab's toolbar item is withdrawn",
                       file: file, line: line)
        XCTAssertEqual(count(labeled: hiddenContent, in: window), 0, "the hidden tab is accessibility-hidden",
                       file: file, line: line)
    }

    /// Closes the presented sheet as a swipe does: UIKit dismisses it and tells the presentation
    /// controller's delegate (SwiftUI), which clears what presented it.
    private func dismissSheet() async throws {
        let sheet = try XCTUnwrap(host?.presentedViewController)
        let controller = sheet.presentationController
        sheet.dismiss(animated: false)
        if let controller { controller.delegate?.presentationControllerDidDismiss?(controller) }
        try await waitUntil("the sheet is gone") { self.host?.presentedViewController == nil }
    }

    /// The distinct accessibility elements labelled `label` under `root`, as VoiceOver would
    /// reach them.
    private func count(labeled label: String, in root: NSObject) -> Int {
        var seen = Set<ObjectIdentifier>()
        collect(labeled: label, in: root, into: &seen, depth: 0)
        return seen.count
    }

    private func collect(labeled label: String, in root: NSObject, into seen: inout Set<ObjectIdentifier>, depth: Int) {
        guard depth < 80 else { return }
        if root.isAccessibilityElement, root.accessibilityLabel == label { seen.insert(ObjectIdentifier(root)) }
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
            collect(labeled: label, in: child, into: &seen, depth: depth + 1)
        }
    }

    private func element(labeled label: String, in root: NSObject) async throws -> Int {
        var found = 0
        try await waitUntil("an element labelled “\(label)”") {
            found = self.count(labeled: label, in: root)
            return found > 0
        }
        return found
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
