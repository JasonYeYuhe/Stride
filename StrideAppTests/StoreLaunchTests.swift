import XCTest
import SwiftData
import CoreData
import SwiftUI
import UIKit
import os
@testable import Stride

/// The app over a store that would not open (upgrade race, E2E U123).
///
/// Until 1.3.1 a failed open fell back to a new, empty store: the app drew "Start Your Journey",
/// the one-time delivery migration spent its flag on the empty store, and the launch synced. Now
/// `AppStoreLaunch` keeps the failure, and `StoreGateView` — what StrideApp's window and the Mac's
/// Settings show — draws only the error screen until a Try Again opens the real store. Everything
/// that touches data is in the gate's content (StrideApp's launch task syncs, sets the badge and
/// reloads the widget there), so these tests watch the content with a probe: while the store is
/// unavailable it is never built, so none of it can run.
@MainActor
final class StoreLaunchTests: XCTestCase {

    private var hostedWindow: UIWindow?

    /// Containers a hosted view used, kept for the life of the process: SwiftUI can run a view's
    /// task after its window is gone, and a ModelContext whose container was released traps.
    private static var retiredContainers: [ModelContainer] = []

    override func tearDown() {
        if let window = hostedWindow {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
            hostedWindow = nil
        }
        super.tearDown()
    }

    private static let failure = StoreOpenFailure(domain: NSCocoaErrorDomain, code: 134110,
                                                  underlyingDomain: NSCocoaErrorDomain, underlyingCode: 134100,
                                                  attempts: 7)

    private func memoryContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        Self.retiredContainers.append(container)
        return container
    }

    /// What the launch did, in order.
    private final class Probe {
        var events: [String] = []
    }

    /// The app's stand-in: its task is where StrideApp's launch sync, badge and widget reload run.
    private struct ProbeApp: View {
        let probe: Probe
        var body: some View {
            Text(verbatim: "The app")
                .task { probe.events.append("app task") }
        }
    }

    private func makeLaunch(_ probe: Probe, open: @escaping AppStoreLaunch.Open) -> AppStoreLaunch {
        AppStoreLaunch(open: open,
                       prepare: { _ in probe.events.append("prepare") },
                       report: { probe.events.append("report \($0.code)") })
    }

    // MARK: - Tests

    func testAStoreThatWillNotOpenShowsTheErrorScreenAndRunsNothing() async throws {
        let probe = Probe()
        let failure = Self.failure
        let launch = makeLaunch(probe) { .failure(failure) }
        XCTAssertNil(launch.container)
        XCTAssertEqual(launch.failure, Self.failure)
        XCTAssertEqual(probe.events, ["report 134110"], "reported, and no launch work: neither migration ran")

        let window = try host(launch, probe)
        _ = try await element(labeled: appLocalized("Stride couldn't open your data"), in: window)
        _ = try await element(labeled: appLocalized("Try Again"), in: window)
        XCTAssertNil(findElement(labeled: "The app", in: window))
        // Time for any task SwiftUI would have started.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(probe.events, ["report 134110"], "the app was never built: no sync, no badge, no widget reload")
    }

    func testTryAgainOpensTheStoreRunsTheLaunchWorkThenShowsTheApp() async throws {
        let probe = Probe()
        let container = try memoryContainer()
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let failure = Self.failure
        let launch = makeLaunch(probe) {
            let attempt = opens.withLock { $0 += 1; return $0 }
            return attempt == 1 ? .failure(failure) : .success(container)
        }
        let window = try host(launch, probe)
        let retry = try await element(labeled: appLocalized("Try Again"), in: window)
        XCTAssertTrue(retry.accessibilityActivate(), "the button's tap")

        _ = try await element(labeled: "The app", in: window)
        try await waitUntil("the app's launch task") { probe.events.contains("app task") }
        XCTAssertTrue(launch.container === container)
        XCTAssertEqual(opens.withLock { $0 }, 2)
        XCTAssertEqual(probe.events, ["report 134110", "prepare", "app task"],
                       "the launch work once, on the opened store, before anything of the app runs")
        XCTAssertNil(findElement(labeled: appLocalized("Stride couldn't open your data"), in: window))
    }

    /// A Try Again that fails again stays on the error screen, reported again, with nothing run.
    func testATryAgainThatFailsStaysOnTheErrorScreen() async {
        let probe = Probe()
        let failure = Self.failure
        let launch = makeLaunch(probe) { .failure(failure) }
        await launch.retry()
        XCTAssertNil(launch.container)
        XCTAssertFalse(launch.isRetrying)
        XCTAssertEqual(probe.events, ["report 134110", "report 134110"])
    }

    // MARK: - The error screen's second line (review round)

    /// The remedy line for `failure`, as the screen shows it in the picked language.
    private func remedy(_ advice: StoreUnavailableAdvice, _ failure: StoreOpenFailure) -> String {
        let domain = failure.domain, code = failure.code
        switch advice {
        case .tryAgain:
            return ""
        case .freeStorage:
            return appLocalized("Your device may be out of storage. Free up some space, then tap Try Again. (Error \(domain) \(code))")
        case .reinstallIfSynced:
            return appLocalized("If it still fails and you sync with a Stride account, delete Stride, install it again and sign in: your synced habits come back. Without an account, contact support first — deleting Stride also deletes the habits on this device. (Error \(domain) \(code))")
        }
    }

    /// A damaged file (Cocoa 259, what SwiftData throws for testAnUnreadableStoreIsReportedAndLeftAsItWas)
    /// is not the race: waiting and restarting cannot mend it. The first screen already names the
    /// code and the remedy, with Contact Support — and still opens nothing else.
    func testAFailureThatIsNotTheRaceNamesItsCodeAndTheRemedy() async throws {
        let probe = Probe()
        let damaged = StoreOpenFailure(domain: NSCocoaErrorDomain, code: 259, attempts: 7)
        let launch = makeLaunch(probe) { .failure(damaged) }
        XCTAssertEqual(launch.advice, .reinstallIfSynced)

        let window = try host(launch, probe)
        _ = try await element(labeled: appLocalized("Stride couldn't open your data"), in: window)
        _ = try await element(labeled: remedy(.reinstallIfSynced, damaged), in: window)
        _ = try await element(labeled: appLocalized("Contact Support"), in: window)
        _ = try await element(labeled: appLocalized("Try Again"), in: window)
        XCTAssertNil(findElement(labeled: "The app", in: window))
        XCTAssertEqual(probe.events, ["report 259"], "reported, and nothing run")
    }

    /// A full device: free some space — first time and every time.
    func testAFullDeviceIsToldToFreeStorage() async throws {
        let probe = Probe()
        let full = StoreOpenFailure(domain: NSCocoaErrorDomain, code: 134110, underlyingDomain: NSSQLiteErrorDomain,
                                    underlyingCode: 13, attempts: 7)
        let launch = makeLaunch(probe) { .failure(full) }
        XCTAssertEqual(launch.advice, .freeStorage)
        let window = try host(launch, probe)
        _ = try await element(labeled: remedy(.freeStorage, full), in: window)
        _ = try await element(labeled: appLocalized("Contact Support"), in: window)
    }

    /// The race's signature gets the calm line alone, the first time. A Try Again that fails the
    /// same way adds the code and the remedy: waiting has had its chance.
    func testTheRaceGetsTheRemedyOnlyOnceTryAgainFailsTheSameWay() async throws {
        let probe = Probe()
        let failure = Self.failure
        let launch = makeLaunch(probe) { .failure(failure) }
        XCTAssertEqual(launch.advice, .tryAgain)

        let window = try host(launch, probe)
        let retry = try await element(labeled: appLocalized("Try Again"), in: window)
        XCTAssertNil(findElement(labeled: remedy(.reinstallIfSynced, failure), in: window))
        XCTAssertNil(findElement(labeled: appLocalized("Contact Support"), in: window))

        XCTAssertTrue(retry.accessibilityActivate(), "the button's tap")
        _ = try await element(labeled: remedy(.reinstallIfSynced, failure), in: window)
        _ = try await element(labeled: appLocalized("Contact Support"), in: window)
        XCTAssertEqual(launch.advice, .reinstallIfSynced)
        XCTAssertEqual(probe.events, ["report 134110", "report 134110"])
    }

    /// The ordinary launch: the store opens, the launch work runs once, and a Try Again (there is
    /// no button, but nothing may run twice) opens nothing.
    func testAStoreThatOpensRunsTheLaunchWorkOnce() async throws {
        let probe = Probe()
        let container = try memoryContainer()
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let launch = makeLaunch(probe) {
            opens.withLock { $0 += 1 }
            return .success(container)
        }
        XCTAssertTrue(launch.container === container)
        await launch.retry()
        XCTAssertEqual(opens.withLock { $0 }, 1)
        XCTAssertEqual(probe.events, ["prepare"])
    }

    /// The host app's own launch (StrideApp.init, in this process) opened the store the one-time
    /// migrations and the sync accept (`SharedModelContainer.isRealStore`), also as the sync sees
    /// it, through a context. Were the guard ever to refuse the app's own store, no install would
    /// migrate or sync again — and every other test here uses stores of its own.
    func testTheAppsOwnStoreIsTheRealStore() throws {
        let container = try XCTUnwrap(SharedModelContainer.opened, "the host app's launch opened its store")
        XCTAssertTrue(SharedModelContainer.isRealStore(container))
        XCTAssertTrue(SharedModelContainer.isRealStore(container.mainContext.container))
        XCTAssertTrue(SharedModelContainer.isRealStore(ModelContext(container).container))
    }

    // MARK: - Hosting

    /// The gate as StrideApp's window shows it, in the picked language's locale, in a window of
    /// its own on the host app's scene.
    private func host(_ launch: AppStoreLaunch, _ probe: Probe) throws -> UIWindow {
        // SwiftUI builds the elements an assistive technology reads only while one is running;
        // this is how XCUITest has it build them in an app under test.
        let automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        addTeardownBlock { @MainActor in AccessibilityAutomation.restore(automation) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: StoreGateView(launch: launch) { _ in
            ProbeApp(probe: probe)
        }
        .environment(\.locale, LanguageManager.shared.locale ?? .current))
        window.makeKeyAndVisible()
        hostedWindow = window
        return window
    }

    /// The accessibility element labelled `label` under `root`, as VoiceOver would reach it.
    private func findElement(labeled label: String, in root: NSObject) -> NSObject? {
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children {
            if let found = findElement(labeled: label, in: child) { return found }
        }
        return nil
    }

    private func element(labeled label: String, in root: NSObject) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil("an element labelled “\(label)”") {
            found = self.findElement(labeled: label, in: root)
            return found != nil
        }
        return try XCTUnwrap(found)
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
