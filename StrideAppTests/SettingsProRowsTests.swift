import XCTest
import SwiftUI
@testable import Stride

/// Settings' Stride Pro rows, drawn (RELEASE-1.4.2.md D6, W7): the real `SettingsProRows` in a
/// List, for every `ProStatus` with and without the entitlement, the trial with and without loaded
/// products, and Restore's answers inline. Read off the accessibility tree. PurchaseOutcomeTests
/// (StrideTests) pin which rows each status gets; this pins the words they are drawn with.
@MainActor
final class SettingsProRowsTests: XCTestCase {

    private var window: UIWindow?
    private var automation: Bool?

    private let yearly = StrideProduct.yearlyPro.rawValue
    private let monthly = StrideProduct.monthlyPro.rawValue
    private let date = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18
    private let prices = [StrideProduct.yearlyPro.rawValue: "$19.99", StrideProduct.monthlyPro.rawValue: "$2.99"]

    override func setUp() async throws {
        try await super.setUp()
        automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        if let automation { AccessibilityAutomation.restore(automation) }
        automation = nil
        try await super.tearDown()
    }

    private var dateLabel: String { SettingsProRows.proDate(date) }

    // MARK: - Every status

    func testNeverAndLapsedSellPro() async throws {
        try await expect(.never, isPro: false, has: ["Upgrade to Pro", "Restore Purchases"], lacks: ["Stride Pro"])
        try await expect(.lapsed(expiredOn: date), isPro: false,
                         has: [appLocalized("Pro ended on \(dateLabel)"), "Resubscribe", "Restore Purchases"],
                         lacks: ["Upgrade to Pro"])
        // Entitled although the status says nothing Pro-shaped: unlocked, never "ended".
        for status in [ProStatus.never, .lapsed(expiredOn: date)] {
            try await expect(status, isPro: true, has: ["All features unlocked"],
                             lacks: ["Upgrade to Pro", "Restore Purchases", "Resubscribe"])
        }
    }

    func testLifetime() async throws {
        try await expect(.lifetime(subscriptionStillRenews: false), isPro: true,
                         has: ["All features unlocked", "Lifetime"], lacks: ["Manage Subscription"])
        try await expect(.lifetime(subscriptionStillRenews: true), isPro: true,
                         has: ["Lifetime", "A subscription still renews", "Manage Subscription"])
    }

    func testActiveSubscriptions() async throws {
        try await expect(.active(productID: yearly, renewsOn: date, willAutoRenew: true), isPro: true,
                         has: ["Yearly", appLocalized("Renews on \(dateLabel)"), "Manage Subscription"])
        try await expect(.active(productID: monthly, renewsOn: date, willAutoRenew: false), isPro: true,
                         has: ["Monthly", appLocalized("Expires on \(dateLabel)")])
        try await expect(.active(productID: yearly, renewsOn: nil, willAutoRenew: nil), isPro: true,
                         has: ["Yearly", "Manage Subscription"], lacks: ["Renews on", "Expires on"])
        try await expect(.active(productID: yearly, renewsOn: date, willAutoRenew: true), isPro: false,
                         has: ["Upgrade to Pro", "Restore Purchases"], lacks: ["Yearly"])
    }

    func testBillingIssue() async throws {
        for isPro in [true, false] {
            try await expect(.billingIssue(productID: yearly, graceUntil: date), isPro: isPro,
                             has: ["Payment problem — update your payment method", "Manage Subscription",
                                   appLocalized("Expires on \(dateLabel)")])
        }
    }

    // MARK: - The trial (D6)

    func testTheTrialWithProductsStatesTheFirstCharge() async throws {
        let price = "$19.99"
        try await expect(.trial(productID: yearly, firstChargeOn: date, willAutoRenew: true), isPro: true,
                         has: ["Yearly", appLocalized("Free trial · first charge of \(price) on \(dateLabel)"),
                               "Manage Subscription"],
                         lacks: ["Renews on"])
    }

    /// Offline, the products have not loaded: the line keeps the date and drops the price.
    func testTheTrialWithoutProductsKeepsTheDateAndDropsThePrice() async throws {
        try await expect(.trial(productID: yearly, firstChargeOn: date, willAutoRenew: true), isPro: true,
                         prices: [:],
                         has: [appLocalized("Free trial · first charge on \(dateLabel)"), "Manage Subscription"],
                         lacks: ["$19.99", "first charge of"])
    }

    func testATrialWithAutoRenewOffEndsOnItsDate() async throws {
        try await expect(.trial(productID: yearly, firstChargeOn: date, willAutoRenew: false), isPro: true,
                         has: [appLocalized("Trial ends on \(dateLabel)")], lacks: ["first charge"])
    }

    /// Unverified renewal info claims nothing: "Free trial", no date and no charge.
    func testATrialWithUnverifiedRenewalInfoHasNoDate() async throws {
        try await expect(.trial(productID: yearly, firstChargeOn: date, willAutoRenew: nil), isPro: true,
                         has: [appLocalized("Free trial")], lacks: [dateLabel, "first charge", "Trial ends"])
        try await expect(.trial(productID: yearly, firstChargeOn: nil, willAutoRenew: true), isPro: true,
                         has: [appLocalized("Free trial")], lacks: ["first charge"])
    }

    // MARK: - Restore, inline (D6)

    func testRestoreAnswersInline() async throws {
        try await expect(.never, isPro: false, restore: .nothingFound,
                         has: ["No purchases found for this Apple ID", "Restore Purchases"])
        try await expect(.never, isPro: false, restore: .failed, has: ["Couldn't reach the App Store"])
        // Restored: the entitlement arrived, so the answer sits under "All features unlocked".
        try await expect(.lifetime(subscriptionStillRenews: false), isPro: true, restore: .restored,
                         has: ["Purchases restored", "All features unlocked"], lacks: ["Restore Purchases"])
        // A cancelled Apple Account sheet says nothing.
        try await expect(.never, isPro: false, restore: .cancelled, has: ["Restore Purchases"],
                         lacks: ["Purchases restored", "No purchases found", "Couldn't reach"])
    }

    /// The Restore row runs Settings' restore; while it runs it is disabled.
    func testTheRestoreRowCallsRestore() async throws {
        var restores = 0
        let window = try show(.never, isPro: false, onRestore: { restores += 1 })
        let button = try await element(labelled: appLocalized("Restore Purchases"), in: window)
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(restores, 1)
    }

    /// Upgrade opens `.settings`, Resubscribe `.lapsed` (the triggers PaywallTriggerTests pin).
    func testThePaywallRowsPassTheirTriggers() async throws {
        var opened: [PaywallTrigger] = []
        var window = try show(.never, isPro: false, onPaywall: { opened.append($0) })
        let upgrade = try await element(containing: appLocalized("Upgrade to Pro"), in: window)
        XCTAssertTrue(upgrade.accessibilityActivate())
        window = try show(.lapsed(expiredOn: date), isPro: false, onPaywall: { opened.append($0) })
        let lapsed = try await element(containing: appLocalized("Resubscribe"), in: window)
        XCTAssertTrue(lapsed.accessibilityActivate())
        XCTAssertEqual(opened, [.settings, .lapsed])
    }

    // MARK: - Helpers

    private func expect(_ status: ProStatus, isPro: Bool, prices: [String: String]? = nil,
                        restore: RestoreOutcome? = nil, has: [String], lacks: [String] = [],
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let window = try show(status, isPro: isPro, prices: prices ?? self.prices, restore: restore)
        let wanted = has.map { appLocalized(String.LocalizationValue($0)) }
        try await waitUntil("\(status) isPro \(isPro)") {
            let all = self.labels(in: window).joined(separator: "\n")
            return wanted.allSatisfy { all.contains($0) }
        }
        let all = labels(in: window).joined(separator: "\n")
        for text in wanted {
            XCTAssertTrue(all.contains(text), "\(status), isPro \(isPro): no \"\(text)\" in \(all)", file: file, line: line)
        }
        for text in lacks.map({ appLocalized(String.LocalizationValue($0)) }) {
            XCTAssertFalse(all.contains(text), "\(status), isPro \(isPro): \"\(text)\" in \(all)", file: file, line: line)
        }
    }

    private func show(_ status: ProStatus, isPro: Bool, prices: [String: String]? = nil, restore: RestoreOutcome? = nil,
                      onPaywall: @escaping (PaywallTrigger) -> Void = { _ in },
                      onRestore: @escaping () -> Void = {}) throws -> UIWindow {
        let view = List {
            Section {
                SettingsProRows(status: status, isPro: isPro, displayPrices: prices ?? self.prices,
                                restoreOutcome: restore, isRestoring: false,
                                onPaywall: onPaywall, onRestore: onRestore, onManage: {})
            }
        }
        .environment(\.locale, LanguageManager.shared.locale ?? .current)
        let controller = UIHostingController(rootView: AnyView(view))
        if let window {
            window.rootViewController = controller
            return window
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func element(labelled label: String, in window: UIWindow) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil(label) {
            found = self.elements(in: window) { $0.accessibilityLabel == label }.first
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func element(containing text: String, in window: UIWindow) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil(text) {
            found = self.elements(in: window) { ($0.accessibilityLabel ?? "").contains(text) }.first
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func labels(in window: UIWindow) -> [String] {
        elements(in: window) { _ in true }.compactMap { element in
            [element.accessibilityLabel, element.accessibilityValue].compactMap { $0 }.joined(separator: ", ")
        }
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
