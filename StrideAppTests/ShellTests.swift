import XCTest
import SwiftUI
import Observation
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
/// or not, Today and Stats only read them here. Settings is opened by one test, the one that needs
/// it, over a NotificationService of its own (a recording center, throwaway defaults); its other
/// "when shown" refreshes re-read what the host app reads anyway (the recovered-edits count, the
/// entitlements).
@MainActor
final class ShellTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var host: UIHostingController<AnyView>?
    private var window: UIWindow?
    private var automation: Bool?
    /// The defaults behind `NotificationService.testOverride`, while a test has one. Undone in
    /// tearDown, after the window is gone, so no Settings left on screen reaches the real one.
    private var notificationDefaults: ScratchDefaults?

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
        if let notificationDefaults {
            NotificationService.testOverride = nil
            notificationDefaults.remove()
            self.notificationDefaults = nil
        }
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

    // MARK: - Settings, shown again

    /// Settings' Reminders rows are copies of NotificationService, read when the view is created.
    /// The 1.3.x `switch` created Settings on every visit; the shell keeps it, so the rows are read
    /// again each time it is shown — and reading writes nothing back (W5 review). Each step is
    /// another window, or the Settings app, changing something while this window shows Today.
    ///
    /// The last step is the write-back that hurts: the reminder switched on elsewhere, then
    /// permission revoked. A copied "on" handed to the toggle's handler asks for permission, is
    /// refused, bounces the toggle off and switches the reminder off for every window.
    ///
    /// Read off the accessibility tree: a switch's value is "1" or "0", and the time is matched by
    /// its digits, which the short time keeps in every language the app has ("7:00 AM", "7:00",
    /// "오전 7:00").
    func testSettingsRereadsItsReminderRowsEachTimeItIsShownAndWritesNothingBack() async throws {
        let scratch = ScratchDefaults("shell.reminders")
        notificationDefaults = scratch
        let center = RecordingCenter()
        let service = NotificationService(center: center, defaults: scratch.defaults)
        service.isReminderEnabled = true   // at the default 20:00, the morning one off
        center.status = .denied            // switched on, then refused in the Settings app
        NotificationService.testOverride = service

        let daily = appLocalized("Daily Reminder")
        let morning = appLocalized("Morning Motivation")   // its label goes on: ", Daily at 8:00 AM"
        let warning = appLocalized("Notifications are disabled. Go to Settings → Stride to enable.")
        let onFooter = appLocalized("You'll receive a reminder to check your habits at the time above.")

        let shell = ShellState(launchArguments: [])
        shell.selection = .settings
        let window = try await hostShell(shell)
        let switchValue = { (prefix: String) -> String? in
            self.elements(in: window) { $0.accessibilityLabel?.hasPrefix(prefix) == true }.first?.accessibilityValue
        }
        let showsSeven = { () -> Bool in
            !self.elements(in: window) { $0.accessibilityLabel?.contains("7:00") == true }.isEmpty
        }
        try await scrollToTop(daily, in: window)
        try await waitUntil("on at 20:00, the morning one off, and the warning") {
            switchValue(daily) == "1" && switchValue(morning) == "0" && !showsSeven()
                && self.count(labeled: warning, in: window) == 1
        }

        // Notifications allowed again in the Settings app. The check used to set the warning,
        // never clear it.
        try await showToday(shell, in: window)
        center.status = .authorized
        shell.selection = .settings
        try await waitUntil("the warning is gone") {
            self.count(labeled: warning, in: window) == 0 && self.count(labeled: onFooter, in: window) == 1
        }

        // Another window moves the reminder to 07:00 and switches the morning one on.
        try await showToday(shell, in: window)
        service.reminderHour = 7
        service.isMorningMotivationEnabled = true
        var events = center.events
        shell.selection = .settings
        try await waitUntil("07:00, the morning one on") { showsSeven() && switchValue(morning) == "1" }
        try await Task.sleep(for: .milliseconds(500))   // time for a write-back to happen
        XCTAssertEqual(center.events, events, "nothing written back: no reschedule")
        XCTAssertEqual(service.reminderHour, 7)
        XCTAssertTrue(service.isMorningMotivationEnabled)

        // Another window switches the reminder off.
        try await showToday(shell, in: window)
        service.isReminderEnabled = false
        shell.selection = .settings
        try await waitUntil("the reminder shows off") {
            switchValue(daily) == "0" && !showsSeven() && self.count(labeled: onFooter, in: window) == 0
        }

        // Another window switches it on again, and then permission is revoked.
        try await showToday(shell, in: window)
        service.isReminderEnabled = true
        center.status = .denied
        events = center.events
        shell.selection = .settings
        try await waitUntil("on, with the warning") {
            switchValue(daily) == "1" && self.count(labeled: warning, in: window) == 1
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(center.events, events, "no permission request, no reschedule")
        XCTAssertTrue(service.isReminderEnabled, "the reminder is still on, for every window")
        XCTAssertEqual(switchValue(daily), "1", "and the switch did not bounce off")
    }

    /// Moves the window to Today and waits until Settings is hidden (out of the accessibility
    /// tree), so the next change is made while it is not showing.
    private func showToday(_ shell: ShellState, in window: UIWindow) async throws {
        shell.selection = .today
        try await waitUntil("Today is showing") {
            self.count(labeled: appLocalized("New Habit"), in: window) == 1
                && self.count(labeled: appLocalized("Daily Reminder"), in: window) == 0
        }
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

    /// Within the same day re-anchoring writes nothing — not the day, not the anchor, not an equal
    /// value. Every activation of the scene and every switch to Today calls it, and Observation
    /// reports an assignment whether or not the value changed, so a write here redraws every view
    /// that reads the day each time; the guard in `reanchor` exists for that.
    ///
    /// Watched by Observation itself, and with the anchor asserted: a day picked in the strip
    /// stays picked whether `reanchor` runs, skips or is gone, so the day alone proves nothing
    /// (W5 review). From just after one midnight to just before the next, on a calendar and clock
    /// of the test's own: the most a day can stretch.
    func testReanchorWithinTheDayWritesNothing() throws {
        let anchor = try instant(day: 14, 0, 0, 30)
        let lateThatDay = try instant(day: 14, 23, 59, 30)
        let pickedInTheStrip = try instant(day: 11, 9, 0)
        for picked in [anchor, pickedInTheStrip] {   // today showing, and a day picked
            let shell = ShellState(launchArguments: [], now: anchor)
            shell.todayDate = picked
            let wrote = expectation(description: "a write to Today's day or its anchor")
            wrote.isInverted = true
            withObservationTracking {
                _ = shell.todayDate
                _ = shell.todayAnchor
            } onChange: {
                wrote.fulfill()
            }
            shell.reanchor(now: lateThatDay, calendar: Self.calendar)
            wait(for: [wrote], timeout: 0.1)
            XCTAssertEqual(shell.todayDate, picked)
            XCTAssertEqual(shell.todayAnchor, anchor, "the anchor stays where it was")
        }
    }

    /// A minute apart on the clock, a day apart on the calendar: the anchor moves to the new day,
    /// Today with it when today was showing, and a day picked in the strip stays picked. The
    /// guard is on the calendar day, not on elapsed time, which would let this minute through.
    func testReanchorAcrossMidnightMovesTheAnchor() throws {
        let lastMinute = try instant(day: 14, 23, 59, 30)
        let firstMinute = try instant(day: 15, 0, 0, 30)

        let showingToday = ShellState(launchArguments: [], now: lastMinute)
        showingToday.reanchor(now: firstMinute, calendar: Self.calendar)
        XCTAssertEqual(showingToday.todayDate, firstMinute, "today was showing: the new today is")
        XCTAssertEqual(showingToday.todayAnchor, firstMinute)

        let picked = try instant(day: 12, 9, 0)
        let showingPicked = ShellState(launchArguments: [], now: lastMinute)
        showingPicked.todayDate = picked
        showingPicked.reanchor(now: firstMinute, calendar: Self.calendar)
        XCTAssertEqual(showingPicked.todayDate, picked, "still in the week strip: still picked")
        XCTAssertEqual(showingPicked.todayAnchor, firstMinute)
    }

    /// The re-anchoring tests' calendar: one zone whatever the machine's, and not UTC+9, the zone
    /// this project's machine runs in and the one that hides day-boundary bugs best.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return calendar
    }()

    /// An instant in October 2026 on `calendar`.
    private func instant(day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) throws -> Date {
        try XCTUnwrap(Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                                              hour: hour, minute: minute, second: second)))
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

    /// Scrolls the list holding the element labelled `label` until that element is at its top, so
    /// the rows under it are on screen: a List builds only the cells it shows, and only those are
    /// in the accessibility tree.
    private func scrollToTop(_ label: String, in window: UIWindow) async throws {
        var target: NSObject?
        try await waitUntil("the list is laid out") { !self.scrollableViews(in: window).isEmpty }
        for _ in 0..<40 {
            target = firstElement(labeled: label, in: window)
            if target != nil { break }
            // Not built yet: half a screen further down, in every list that scrolls.
            for scrollView in scrollableViews(in: window) {
                let y = min(scrollView.contentOffset.y + scrollView.bounds.height / 2, maxOffset(of: scrollView))
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let element = try XCTUnwrap(target, "an element labelled “\(label)” in a list")
        let frame = element.accessibilityFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let scrollView = try XCTUnwrap(scrollableViews(in: window).last {
            $0.convert($0.bounds, to: nil).contains(center)
        }, "the list holding “\(label)”")
        let top = scrollView.convert(scrollView.bounds, to: nil).minY + scrollView.adjustedContentInset.top
        let y = min(max(scrollView.contentOffset.y + frame.minY - top - 8, -scrollView.adjustedContentInset.top),
                    maxOffset(of: scrollView))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
        try await waitUntil("“\(label)” still on screen") { self.count(labeled: label, in: window) == 1 }
    }

    private func maxOffset(of scrollView: UIScrollView) -> CGFloat {
        max(-scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
    }

    /// The visible scroll views under `root` whose content is taller than they are, outermost first.
    private func scrollableViews(in root: UIView) -> [UIScrollView] {
        guard !root.isHidden, root.alpha > 0 else { return [] }
        var found: [UIScrollView] = []
        if let scrollView = root as? UIScrollView, scrollView.contentSize.height > scrollView.bounds.height + 1 {
            found.append(scrollView)
        }
        for subview in root.subviews { found += scrollableViews(in: subview) }
        return found
    }

    /// The first accessibility element labelled `label` under `root`.
    private func firstElement(labeled label: String, in root: NSObject) -> NSObject? {
        elements(in: root) { $0.accessibilityLabel == label }.first
    }

    /// The distinct accessibility elements labelled `label` under `root`, as VoiceOver would
    /// reach them.
    private func count(labeled label: String, in root: NSObject) -> Int {
        elements(in: root) { $0.accessibilityLabel == label }.count
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
