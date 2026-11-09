import XCTest
import SwiftUI
@testable import Stride

/// The paywall (RELEASE-1.4.2.md D4, W3), hosted: ProPaywallView drawn from each `PaywallFixture`
/// (the same data `-paywallFixture` launches), in a window of its own on the host app's scene,
/// read off the accessibility tree as VoiceOver reads it (`AccessibilityAutomation`, as
/// StatsRenderTests). No StoreKit: a fixture's paywall reads no product, buys nothing and never
/// auto-dismisses.
///
/// - Each fixture's CTA and terms, in the catalog's words, and the states' own lines.
/// - The selection: Yearly, Monthly, Lifetime by kind, Yearly selected (the `.selected` trait);
///   a tap on a card changes the CTA and the terms.
/// - The billed price is the largest price text; Yearly's per-month figure is smaller.
/// - No trial word when the trial is not stated (ineligible, unknown, Pro, no offer), outside the
///   legal line, whose trial clause holds with or without one.
/// - The bar: CTA, terms and the Terms and Privacy links pinned on the first screen at the
///   default size, on an iPhone and in an iPad's sheet; the end of the scroll at AX5.
/// - Continue calls `onUnlock`; the subtitle and the first feature row follow the trigger.
///
/// The phone is an iPhone 17 Pro's window (402 × 874 pt); the iPad is a page sheet on a 13"
/// iPad (704 × 1000 pt, regular width). Each is a SwiftUI frame of that size at the window's top
/// left, so the checks hold on whichever simulator runs the suite.
///
/// DEBUG-only, as `PaywallFixture` and the fixture initializer are (the hosted suite builds Debug).
#if DEBUG
@MainActor
final class PaywallRenderTests: XCTestCase {

    private var window: UIWindow?
    private var automation: Bool?

    private static let phone = CGSize(width: 402, height: 874)
    private static let padSheet = CGSize(width: 704, height: 1000)

    override func setUp() async throws {
        try await super.setUp()
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
        if let automation { AccessibilityAutomation.restore(automation) }
        automation = nil
        try await super.tearDown()
    }

    // MARK: - The words

    private let yearlyPrice = "$19.99"
    private var startTrial: String { appLocalized("Start \(7)-day free trial") }
    private var subscribe: String { appLocalized("Subscribe") }
    private func trialTerms(_ price: String) -> String {
        appLocalized("Free for \(7) days, then \(price)/year. Renews automatically unless cancelled at least 24 hours before the trial ends.")
    }
    private func yearlyTerms(_ price: String) -> String {
        appLocalized("\(price)/year. Renews automatically unless cancelled at least 24 hours before the end of the period.")
    }

    // MARK: - Fixtures: CTA, terms, states

    /// Every fixture's CTA and terms (or their absence), and the line its state adds.
    func testEachFixtureSaysItsCTAAndTerms() async throws {
        let pending = appLocalized("Waiting for approval. Stride Pro unlocks when it's approved.")
        let cases: [(PaywallFixture, cta: String?, terms: String?, line: String?)] = [
            (.trial, startTrial, trialTerms(yearlyPrice), nil),
            (.ineligible, subscribe, yearlyTerms(yearlyPrice), nil),
            (.unknownEligibility, subscribe, yearlyTerms(yearlyPrice), nil),
            (.noOffer, subscribe, yearlyTerms(yearlyPrice), nil),
            (.pro, subscribe, yearlyTerms(yearlyPrice), nil),
            (.yen, startTrial, trialTerms("¥3,000"), nil),
            (.purchasing, startTrial, trialTerms(yearlyPrice), nil),
            (.pending, startTrial, trialTerms(yearlyPrice), pending),
            (.restored, startTrial, trialTerms(yearlyPrice), appLocalized("Purchases restored")),
            (.nothingFound, startTrial, trialTerms(yearlyPrice), appLocalized("No purchases found for this Apple ID")),
            (.restoreFailed, startTrial, trialTerms(yearlyPrice), appLocalized("Couldn't reach the App Store")),
            (.loading, nil, nil, nil),
            (.loadFailed, nil, nil, appLocalized("Stride Pro options couldn't load. Check your connection and try again.")),
            (.unlocked, nil, nil, appLocalized("Stride Pro is unlocked")),
        ]
        XCTAssertEqual(Set(cases.map(\.0)).union([.purchaseFailed]), Set(PaywallFixture.allCases),
                       "every fixture is drawn here (purchaseFailed in its own test)")
        for test in cases {
            let window = try show(test.0)
            let what = "\(test.0)"
            try await waitUntil("\(what) drawn") {
                if let cta = test.cta { return self.element("paywall.bar.cta", in: window)?.accessibilityLabel == cta }
                if let line = test.line { return !self.elements(in: window, labelled: line).isEmpty }
                return !self.elements(in: window) { self.identifier(of: $0) == "paywall.subtitle" }.isEmpty
            }
            let cta = element("paywall.bar.cta", in: window)
            XCTAssertEqual(cta?.accessibilityLabel, test.cta, "\(what): the CTA")
            XCTAssertEqual(element("paywall.bar.terms", in: window)?.accessibilityLabel, test.terms, "\(what): the terms")
            if let line = test.line {
                XCTAssertFalse(elements(in: window, labelled: line).isEmpty, "\(what): \"\(line)\"")
            }
            switch test.0 {
            case .purchasing:
                XCTAssertTrue(cta?.accessibilityTraits.contains(.notEnabled) ?? false, "purchasing: the CTA waits")
            case .loadFailed:
                XCTAssertFalse(elements(in: window, labelled: appLocalized("Try Again")).isEmpty, "loadFailed: Try Again")
            case .unlocked:
                XCTAssertEqual(element("paywall.bar.continue", in: window)?.accessibilityLabel, appLocalized("Continue"))
                XCTAssertTrue(elements(in: window) { self.identifier(of: $0) == "paywall.plan" }.isEmpty, "unlocked sells nothing")
            default:
                if test.cta != nil {
                    XCTAssertFalse(cta?.accessibilityTraits.contains(.notEnabled) ?? true, "\(what): the CTA is enabled")
                }
            }
        }
    }

    /// A failed purchase says so through the existing alert, over the plans.
    func testAFailedPurchaseShowsThePurchaseErrorAlert() async throws {
        let window = try show(.purchaseFailed)
        try await waitUntil("the Purchase Error alert") {
            (window.rootViewController?.presentedViewController as? UIAlertController)?.title == appLocalized("Purchase Error")
        }
        XCTAssertEqual(element("paywall.bar.cta", in: window)?.accessibilityLabel, startTrial)
    }

    // MARK: - Plans and selection

    /// The plan cards in the order they are drawn.
    private func planCards(in window: UIWindow) -> [NSObject] {
        elements(in: window) { self.identifier(of: $0) == "paywall.plan" }
            .sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY }
    }

    private func isSelected(_ element: NSObject) -> Bool { element.accessibilityTraits.contains(.selected) }

    /// Yearly, Monthly, Lifetime — by kind, though StoreService loads them by price — with Yearly
    /// selected; a tap on a card selects it and the one CTA and its terms follow. Lifetime no
    /// longer says "BEST VALUE".
    func testTheSelectedPlanDrivesTheCTAAndTerms() async throws {
        let window = try show(.trial)
        try await waitUntil("three plans") { self.planCards(in: window).count == 3 }
        var cards = planCards(in: window)
        let titles = [appLocalized("Yearly"), appLocalized("Monthly"), appLocalized("Lifetime")]
        for (card, title) in zip(cards, titles) {
            XCTAssertTrue((card.accessibilityLabel ?? "").hasPrefix(title), "\(title) in order: \(card.accessibilityLabel ?? "")")
        }
        XCTAssertEqual(cards.map(isSelected), [true, false, false], "Yearly is selected")
        XCTAssertFalse((cards[2].accessibilityLabel ?? "").contains(appLocalized("BEST VALUE")), "Lifetime has no badge")

        XCTAssertTrue(cards[1].accessibilityActivate(), "a tap on Monthly")
        try await waitUntil("Monthly selected") { self.element("paywall.bar.cta", in: window)?.accessibilityLabel == self.subscribe }
        XCTAssertEqual(element("paywall.bar.terms", in: window)?.accessibilityLabel,
                       appLocalized("\("$2.99")/month. Renews automatically unless cancelled at least 24 hours before the end of the period."))
        cards = planCards(in: window)
        XCTAssertEqual(cards.map(isSelected), [false, true, false], "Monthly is selected")

        XCTAssertTrue(cards[2].accessibilityActivate(), "a tap on Lifetime")
        try await waitUntil("Lifetime selected") {
            self.element("paywall.bar.cta", in: window)?.accessibilityLabel == appLocalized("Buy Lifetime")
        }
        XCTAssertEqual(element("paywall.bar.terms", in: window)?.accessibilityLabel,
                       appLocalized("One payment of \("$39.99"). No subscription."))
        XCTAssertEqual(planCards(in: window).map(isSelected), [false, false, true], "Lifetime is selected")
    }

    /// The billed price is the largest price text on each card; Yearly's per-month figure
    /// ("$1.67/month", 19.99 / 12 rounded up; "¥250/month" in yen) is smaller, at the default
    /// size and at AX5.
    func testTheBilledPriceIsTheLargestPriceText() async throws {
        for (fixture, billed, perMonth) in [(PaywallFixture.trial, "$19.99", "$1.67"), (.yen, "¥3,000", "¥250")] {
            let window = try show(fixture)
            try await waitUntil("\(fixture)'s plans") { self.planCards(in: window).count == 3 }
            let yearly = try XCTUnwrap(planCards(in: window).first?.accessibilityLabel)
            XCTAssertTrue(yearly.contains(billed + appLocalized("/yr")), "\(fixture): the billed price on Yearly: \(yearly)")
            XCTAssertTrue(yearly.contains(appLocalized("\(perMonth)/month")), "\(fixture): the per-month figure: \(yearly)")
            XCTAssertTrue(yearly.contains(appLocalized("SAVE \(44)%")), "\(fixture): the savings badge: \(yearly)")
        }
        for size in [DynamicTypeSize.large, .accessibility5] {
            let billed = idealSize(of: Text(verbatim: "$19.99/yr").font(PricingCard.billedPriceFont), at: size)
            let perMonth = idealSize(of: Text(verbatim: "$1.67/month").font(PricingCard.perMonthFont), at: size)
            XCTAssertGreaterThan(billed.height, perMonth.height, "\(size): the billed price's text is the largest")
        }
    }

    /// No trial word unless the trial is stated: ineligible, unknown eligibility, Pro and no offer
    /// all read without one — everywhere but the legal line, whose clause ("If a free trial is
    /// offered…") is true with or without an offer (D16). The eligible fixture is the control.
    func testNoTrialWordWhenTheTrialIsNotStated() async throws {
        func trialWords(in window: UIWindow) -> [String] {
            elements(in: window) { self.identifier(of: $0) != "paywall.legal" }
                .compactMap(\.accessibilityLabel)
                .filter { $0.lowercased().contains("trial") }
        }
        let control = try show(.trial)
        try await waitUntil("the trial's plans") { self.planCards(in: control).count == 3 }
        XCTAssertFalse(trialWords(in: control).isEmpty, "the control states the trial (an English host)")

        for fixture in [PaywallFixture.ineligible, .unknownEligibility, .pro, .noOffer] {
            let window = try show(fixture)
            try await waitUntil("\(fixture)'s plans") { self.planCards(in: window).count == 3 }
            XCTAssertEqual(trialWords(in: window), [], "\(fixture) states no trial")
            XCTAssertEqual(element("paywall.bar.cta", in: window)?.accessibilityLabel, subscribe, "\(fixture)")
        }
    }

    // MARK: - The bar

    /// The frame `show` draws in, in screen coordinates.
    private func container(_ size: CGSize) -> CGRect { CGRect(origin: .zero, size: size) }

    /// At the default size the CTA, the terms and both links are pinned in the bar, on the first
    /// screen, CTA first, terms right under it, links last — on an iPhone and in an iPad's sheet.
    func testTheBarHoldsTheCTATermsAndLinksAtTheDefaultSize() async throws {
        for size in [Self.phone, Self.padSheet] {
            let window = try show(.trial, size: size)
            let what = "\(Int(size.width)) × \(Int(size.height)) pt"
            try await waitUntil("\(what): the bar") {
                ["cta", "terms", "termsOfUse", "privacyPolicy"].allSatisfy {
                    !(self.element("paywall.bar.\($0)", in: window)?.accessibilityFrame.isEmpty ?? true)
                }
            }
            XCTAssertNil(element("paywall.scroll.cta", in: window), "\(what): not in the scroll content")
            let frames = try ["cta", "terms", "termsOfUse", "privacyPolicy"].map {
                try XCTUnwrap(element("paywall.bar.\($0)", in: window)?.accessibilityFrame, "\(what): \($0)")
            }
            for (name, frame) in zip(["CTA", "terms", "Terms of Use", "Privacy Policy"], frames) {
                XCTAssertTrue(container(size).insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(what): \(name) on the first screen (\(frame))")
            }
            XCTAssertGreaterThanOrEqual(frames[1].minY, frames[0].maxY - 0.5, "\(what): the terms right under the CTA")
            XCTAssertGreaterThanOrEqual(frames[2].minY, frames[1].maxY - 0.5, "\(what): the links under the terms")
            let yearly = try XCTUnwrap(planCards(in: window).first?.accessibilityFrame)
            XCTAssertGreaterThan(frames[0].minY, yearly.minY, "\(what): the bar is under the first card")
        }
    }

    /// At AX5 the bar would cover the cards: it is the end of the scroll content instead, after
    /// the last plan card, the terms under the CTA and the links under them.
    func testAtAX5TheBarIsTheEndOfTheScroll() async throws {
        for size in [Self.phone, Self.padSheet] {
            let window = try show(.trial, size: size, dynamicType: .accessibility5)
            let what = "AX5, \(Int(size.width)) × \(Int(size.height)) pt"
            try await waitUntil("\(what): the CTA in the scroll") { self.element("paywall.scroll.cta", in: window) != nil }
            XCTAssertNil(element("paywall.bar.cta", in: window), "\(what): nothing pinned")
            let cta = try XCTUnwrap(element("paywall.scroll.cta", in: window)?.accessibilityFrame)
            let terms = try XCTUnwrap(element("paywall.scroll.terms", in: window)?.accessibilityFrame)
            let link = try XCTUnwrap(element("paywall.scroll.termsOfUse", in: window)?.accessibilityFrame)
            XCTAssertNotNil(element("paywall.scroll.privacyPolicy", in: window), "\(what): Privacy Policy")
            let lastCard = try XCTUnwrap(planCards(in: window).last?.accessibilityFrame)
            XCTAssertGreaterThanOrEqual(cta.minY, lastCard.maxY - 0.5, "\(what): the CTA after the cards")
            XCTAssertGreaterThanOrEqual(terms.minY, cta.maxY - 0.5, "\(what): the terms under the CTA")
            XCTAssertGreaterThanOrEqual(link.minY, terms.maxY - 0.5, "\(what): the links under the terms")
        }
    }

    /// The Terms of Use and Privacy Policy links: links, by the catalog's names, to the site's
    /// pages.
    func testTheTermsAndPrivacyLinks() async throws {
        let window = try show(.trial)
        try await waitUntil("the links") { self.element("paywall.bar.privacyPolicy", in: window) != nil }
        let terms = try XCTUnwrap(element("paywall.bar.termsOfUse", in: window))
        let privacy = try XCTUnwrap(element("paywall.bar.privacyPolicy", in: window))
        XCTAssertEqual(terms.accessibilityLabel, appLocalized("Terms of Use"))
        XCTAssertEqual(privacy.accessibilityLabel, appLocalized("Privacy Policy"))
        XCTAssertTrue(terms.accessibilityTraits.contains(.link) || terms.accessibilityTraits.contains(.button))
        XCTAssertTrue(privacy.accessibilityTraits.contains(.link) || privacy.accessibilityTraits.contains(.button))
        XCTAssertEqual(ProPaywallView.termsOfUseURL.absoluteString, "https://jasonyeyuhe.github.io/stride-site/terms")
        XCTAssertEqual(ProPaywallView.privacyPolicyURL.absoluteString, "https://jasonyeyuhe.github.io/stride-site/privacy")
    }

    // MARK: - Unlocked, triggers, dismissal

    /// "Stride Pro is unlocked": Continue calls `onUnlock`, what the presenter resumes.
    func testContinueCallsOnUnlock() async throws {
        var unlocked = 0
        let window = try show(.unlocked, onUnlock: { unlocked += 1 })
        try await waitUntil("Continue") { self.element("paywall.bar.continue", in: window) != nil }
        XCTAssertNil(element("paywall.bar.terms", in: window), "no terms once unlocked")
        XCTAssertTrue(try XCTUnwrap(element("paywall.bar.continue", in: window)).accessibilityActivate(), "Continue")
        try await waitUntil("onUnlock") { unlocked == 1 }
    }

    /// The header's subtitle follows the trigger, and so does the first feature row; the other two
    /// keep D11's order.
    func testTheSubtitleAndTheFirstFeatureFollowTheTrigger() async throws {
        let subtitles: [PaywallTrigger: String] = [
            .analytics: appLocalized("See what's changing, not just where you are"),
            .weeklyReview: appLocalized("See how your week went"),
            .today: appLocalized("See how your week went"),
            .groups: appLocalized("Organize your habits into groups"),
            .settings: appLocalized("Almost everything is free. Pro adds three things."),
            .onboarding: appLocalized("Almost everything is free. Pro adds three things."),
            .lapsed: appLocalized("Welcome back"),
        ]
        let titles: [ProPaywallView.ProFeature: String] = [
            .habitGroups: appLocalized("Habit Groups"),
            .advancedAnalytics: appLocalized("Advanced Analytics"),
            .weeklyReview: appLocalized("Weekly Review"),
        ]
        for trigger in PaywallTrigger.allCases {
            let window = try show(.trial, trigger: trigger)
            let features = { self.elements(in: window) { self.identifier(of: $0) == "paywall.feature" }
                .sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY } }
            try await waitUntil("\(trigger): the features") { features().count == 3 }
            XCTAssertEqual(element("paywall.subtitle", in: window)?.accessibilityLabel, subtitles[trigger], "\(trigger)")
            let drawn = features().map { row in
                titles.first { (row.accessibilityLabel ?? "").hasPrefix($0.value) }?.key
            }
            XCTAssertEqual(drawn, ProPaywallView.featureOrder(for: trigger).map(Optional.some), "\(trigger)")
        }
    }

    /// The trigger's row first, the others in D11's order.
    func testTheFeatureOrderPerTrigger() {
        typealias F = ProPaywallView.ProFeature
        let expected: [PaywallTrigger: [F]] = [
            .analytics: [.advancedAnalytics, .habitGroups, .weeklyReview],
            .weeklyReview: [.weeklyReview, .habitGroups, .advancedAnalytics],
            .today: [.weeklyReview, .habitGroups, .advancedAnalytics],
            .groups: [.habitGroups, .advancedAnalytics, .weeklyReview],
            .settings: [.habitGroups, .advancedAnalytics, .weeklyReview],
            .onboarding: [.habitGroups, .advancedAnalytics, .weeklyReview],
            .lapsed: [.habitGroups, .advancedAnalytics, .weeklyReview],
        ]
        for trigger in PaywallTrigger.allCases {
            XCTAssertEqual(ProPaywallView.featureOrder(for: trigger), expected[trigger], "\(trigger)")
        }
    }

    /// D4's dismissal: an entitlement closes the paywall only when it arrives from elsewhere —
    /// never during its own purchase or restore, nor once it is pending (it becomes unlocked) or
    /// unlocked (Continue closes it).
    func testTheAutoDismissFiresOnlyForAnEntitlementFromElsewhere() {
        let idle: [PaywallPhase] = [.loading, .loadFailed(.noProducts), .ready, .restore(.nothingFound), .purchaseFailed]
        for phase in idle {
            XCTAssertTrue(ProPaywallView.autoDismisses(phase: phase, isPurchasing: false, isRestoring: false), "\(phase)")
            XCTAssertFalse(ProPaywallView.autoDismisses(phase: phase, isPurchasing: true, isRestoring: false), "\(phase), buying")
            XCTAssertFalse(ProPaywallView.autoDismisses(phase: phase, isPurchasing: false, isRestoring: true), "\(phase), restoring")
        }
        for phase in [PaywallPhase.purchasing, .pending, .unlocked] {
            XCTAssertFalse(ProPaywallView.autoDismisses(phase: phase, isPurchasing: false, isRestoring: false), "\(phase)")
        }
    }

    // MARK: - Hosting

    /// The paywall of `fixture` in a `size` frame at the window's top left, in a window of its own
    /// (reused across calls in one test).
    private func show(_ fixture: PaywallFixture, trigger: PaywallTrigger = .settings, size: CGSize = phone,
                      dynamicType: DynamicTypeSize = .large, onUnlock: @escaping () -> Void = {}) throws -> UIWindow {
        let view = ProPaywallView(trigger: trigger, fixture: fixture, onUnlock: onUnlock)
            .dynamicTypeSize(dynamicType)
            .environment(\.horizontalSizeClass, size.width >= 600 ? .regular : .compact)
            .environment(\.locale, LanguageManager.shared.locale ?? .current)
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        let controller = UIHostingController(rootView: AnyView(view))
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.rootViewController = controller
            return window
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    /// `view` at its ideal size (a text on one line) at `size`.
    private func idealSize(of view: some View, at size: DynamicTypeSize) -> CGSize {
        let measured = UIHostingController(rootView: view.fixedSize().dynamicTypeSize(size))
        return measured.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    private func element(_ identifier: String, in window: UIWindow) -> NSObject? {
        elements(in: window) { self.identifier(of: $0) == identifier }.first
    }

    private func elements(in window: UIWindow, labelled label: String) -> [NSObject] {
        elements(in: window) { $0.accessibilityLabel == label }
    }

    /// An element's accessibility identifier, which SwiftUI's elements answer without adopting
    /// UIAccessibilityIdentification in their type.
    private func identifier(of element: NSObject) -> String? {
        if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
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
#endif
