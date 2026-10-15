import XCTest
import Foundation

/// `PurchaseOutcome`, `ProStatus.resolve`, Settings' Pro rows and `SubscriptionManagement`
/// (RELEASE-1.4.1.md D12, O9; gates 4 and 10.3), host-less: the pure mappings in
/// Shared/PurchaseOutcome.swift, which StoreKit's own types cannot reach in a test. StrideTests
/// runs on macOS in CI, so the Mac branches are pinned on the platform they are for;
/// StoreKitStatusTests (hosted, SKTestSession) covers the StoreKit adapter.
final class PurchaseOutcomeTests: XCTestCase {

    private let monthly = "yyh.stride.habittracker.pro.monthly"
    private let yearly = "yyh.stride.habittracker.pro.yearly"
    private let lifetime = "yyh.stride.habittracker.pro.lifetime"

    private let renewal = Date(timeIntervalSince1970: 1_792_000_000)    // October 2026
    private let earlier = Date(timeIntervalSince1970: 1_790_000_000)
    private let later = Date(timeIntervalSince1970: 1_793_000_000)

    private func resolve(_ entitled: Set<String>, _ statuses: [SubscriptionStatusMirror]?,
                         lifetimeRevokedOn: Date? = nil) -> ProStatus {
        ProStatus.resolve(entitledProductIDs: entitled, lifetimeProductID: lifetime, statuses: statuses,
                          lifetimeRevokedOn: lifetimeRevokedOn)
    }

    private func status(_ productID: String, _ state: SubscriptionStatusMirror.State, expires: Date? = nil,
                        renews: Bool? = nil, grace: Date? = nil, revoked: Date? = nil) -> SubscriptionStatusMirror {
        SubscriptionStatusMirror(productID: productID, state: state, expirationDate: expires, willAutoRenew: renews,
                                 gracePeriodExpirationDate: grace, revocationDate: revoked)
    }

    // MARK: - PurchaseOutcome

    func testAVerifiedPurchaseIsPurchased() {
        XCTAssertEqual(PurchaseOutcome(.verified(productID: monthly)), .purchased(productID: monthly))
    }

    /// The 1.2.x bug: an unverified purchase the App Store completed read as a quiet cancel.
    func testAnUnverifiedPurchaseIsAnErrorNeverACancel() {
        let outcome = PurchaseOutcome(.unverified(productID: lifetime))
        XCTAssertEqual(outcome, .failedVerification(productID: lifetime))
        XCTAssertNotEqual(outcome, .cancelled)
    }

    func testPendingStaysPendingAndCancelOrUnknownIsACancel() {
        XCTAssertEqual(PurchaseOutcome(.pending), .pending)
        XCTAssertEqual(PurchaseOutcome(.userCancelled), .cancelled)
        XCTAssertEqual(PurchaseOutcome(.unknown), .cancelled)
    }

    // MARK: - ProStatus.resolve

    func testNoEntitlementAndNoStatusIsNever() {
        XCTAssertEqual(resolve([], nil), .never)
        XCTAssertEqual(resolve([], []), .never)
    }

    func testLifetimeComesFromTheEntitlements() {
        XCTAssertEqual(resolve([lifetime], nil), .lifetime(subscriptionStillRenews: false))
        XCTAssertEqual(resolve([lifetime], [status(monthly, .expired, expires: earlier)]),
                       .lifetime(subscriptionStillRenews: false))
    }

    /// Gate 4: Lifetime never shows as lapsed — whatever the subscription group says, refunds and
    /// expiries included.
    func testLifetimeNeverShowsAsLapsed() {
        for statuses in [[status(monthly, .expired, expires: earlier)],
                         [status(yearly, .revoked, expires: later, revoked: earlier)]] {
            guard case .lifetime = resolve([lifetime], statuses) else {
                return XCTFail("lifetime resolved as \(resolve([lifetime], statuses))")
            }
        }
    }

    /// Lifetime bought while a subscription still auto-renews: the "still renews" row (gate 4).
    /// Renewal info that could not be verified claims nothing.
    func testLifetimeWithASubscriptionStillRenewing() {
        XCTAssertEqual(resolve([lifetime, monthly], [status(monthly, .subscribed, expires: renewal, renews: true)]),
                       .lifetime(subscriptionStillRenews: true))
        XCTAssertEqual(resolve([lifetime], [status(monthly, .inBillingRetryPeriod, expires: earlier, renews: true)]),
                       .lifetime(subscriptionStillRenews: true), "Apple keeps trying to charge it")
        XCTAssertEqual(resolve([lifetime, monthly], [status(monthly, .subscribed, expires: renewal, renews: false)]),
                       .lifetime(subscriptionStillRenews: false))
        XCTAssertEqual(resolve([lifetime, monthly], [status(monthly, .subscribed, expires: renewal, renews: nil)]),
                       .lifetime(subscriptionStillRenews: false))
        XCTAssertEqual(resolve([lifetime, monthly], nil), .lifetime(subscriptionStillRenews: false))
    }

    func testAnEntitledSubscriptionIsActiveWithItsRenewal() {
        XCTAssertEqual(resolve([monthly], [status(monthly, .subscribed, expires: renewal, renews: true)]),
                       .active(productID: monthly, renewsOn: renewal, willAutoRenew: true))
        XCTAssertEqual(resolve([yearly], [status(yearly, .subscribed, expires: renewal, renews: false)]),
                       .active(productID: yearly, renewsOn: renewal, willAutoRenew: false))
    }

    /// D12's safety rule, and the plan review's finding: a status read that throws or returns
    /// nothing — offline, a StoreKit hiccup — must never show an entitled subscriber as lapsed.
    func testEntitledStatusUnavailableIsActiveNeverLapsed() {
        XCTAssertEqual(resolve([monthly], nil), .active(productID: monthly, renewsOn: nil, willAutoRenew: nil))
        XCTAssertEqual(resolve([monthly], []), .active(productID: monthly, renewsOn: nil, willAutoRenew: nil))
        // A stale status that says expired or refunded does not override the entitlement either.
        for stale in [status(monthly, .expired, expires: earlier),
                      status(monthly, .revoked, expires: renewal, revoked: earlier),
                      status(monthly, .unknown)] {
            let resolved = resolve([monthly], [stale])
            XCTAssertEqual(resolved, .active(productID: monthly, renewsOn: nil, willAutoRenew: nil), "\(stale.state)")
            if case .lapsed = resolved { XCTFail("an entitled subscriber was shown as lapsed") }
        }
    }

    /// The entitled product's status wins over another in the group (a crossgrade in flight).
    func testTheEntitledProductsStatusIsTheOneShown() {
        let statuses = [status(monthly, .subscribed, expires: earlier, renews: false),
                        status(yearly, .subscribed, expires: later, renews: true)]
        XCTAssertEqual(resolve([yearly], statuses), .active(productID: yearly, renewsOn: later, willAutoRenew: true))
    }

    func testBillingRetryAndGraceAreABillingIssue() {
        // Grace period: still entitled, with the date Pro ends unless the payment goes through.
        XCTAssertEqual(resolve([monthly], [status(monthly, .inGracePeriod, expires: earlier, renews: true, grace: later)]),
                       .billingIssue(productID: monthly, graceUntil: later))
        // Billing retry: the entitlement is gone, but Apple is still trying: not lapsed.
        XCTAssertEqual(resolve([], [status(monthly, .inBillingRetryPeriod, expires: earlier, renews: true, grace: earlier)]),
                       .billingIssue(productID: monthly, graceUntil: nil))
        // An entitled subscriber whose status is in billing retry (it can briefly disagree).
        XCTAssertEqual(resolve([yearly], [status(yearly, .inBillingRetryPeriod, expires: earlier)]),
                       .billingIssue(productID: yearly, graceUntil: nil))
    }

    func testExpiredWithNoEntitlementIsLapsedOnItsDate() {
        XCTAssertEqual(resolve([], [status(monthly, .expired, expires: earlier, renews: false)]), .lapsed(expiredOn: earlier))
    }

    /// Revoked or refunded maps to lapsed, with its own date — not the expiry it would have had.
    func testARefundIsLapsedOnTheRefundsDate() {
        XCTAssertEqual(resolve([], [status(yearly, .revoked, expires: later, revoked: earlier)]), .lapsed(expiredOn: earlier))
        XCTAssertEqual(resolve([], [status(yearly, .revoked, expires: later)]), .lapsed(expiredOn: later),
                       "no revocation date: the expiry")
        XCTAssertEqual(resolve([], nil, lifetimeRevokedOn: earlier), .lapsed(expiredOn: earlier), "a Lifetime refund")
    }

    func testTheLatestEndIsTheOneShown() {
        XCTAssertEqual(resolve([], [status(monthly, .expired, expires: earlier), status(yearly, .expired, expires: later)]),
                       .lapsed(expiredOn: later))
        XCTAssertEqual(resolve([], [status(monthly, .expired, expires: earlier)], lifetimeRevokedOn: later),
                       .lapsed(expiredOn: later))
    }

    /// No entitlement but a status that says subscribed: the entitlement failed verification.
    /// Restore is the way back; "ended" would be false.
    func testSubscribedWithoutAnEntitlementIsNotLapsed() {
        XCTAssertEqual(resolve([], [status(monthly, .subscribed, expires: renewal, renews: true)]), .never)
        XCTAssertEqual(resolve([], [status(monthly, .subscribed, expires: renewal), status(yearly, .expired, expires: earlier)]),
                       .never)
    }

    func testAnEndedStatusWithNoDateSaysNothing() {
        XCTAssertEqual(resolve([], [status(monthly, .expired)]), .never)
        XCTAssertEqual(resolve([], [status(monthly, .unknown, expires: earlier)]), .never)
    }

    // MARK: - Settings' rows (gate 4)

    private func rows(_ status: ProStatus, isPro: Bool) -> [ProSettingsRow] {
        ProSettingsRow.rows(for: status, isPro: isPro)
    }

    func testFreeShowsTheUpsellAndRestore() {
        XCTAssertEqual(rows(.never, isPro: false), [.upgrade, .restore])
    }

    /// "Monthly shows the plan and renewal date"; auto-renew off says when it expires; renewal
    /// info that could not be read says no date.
    func testAnActiveSubscriptionShowsItsPlanItsDateAndManage() {
        XCTAssertEqual(rows(.active(productID: monthly, renewsOn: renewal, willAutoRenew: true), isPro: true),
                       [.unlocked, .plan(.subscription(productID: monthly), .renews(renewal)), .manage])
        XCTAssertEqual(rows(.active(productID: yearly, renewsOn: renewal, willAutoRenew: false), isPro: true),
                       [.unlocked, .plan(.subscription(productID: yearly), .expires(renewal)), .manage])
        XCTAssertEqual(rows(.active(productID: monthly, renewsOn: nil, willAutoRenew: nil), isPro: true),
                       [.unlocked, .plan(.subscription(productID: monthly), nil), .manage])
        XCTAssertEqual(rows(.active(productID: monthly, renewsOn: renewal, willAutoRenew: nil), isPro: true),
                       [.unlocked, .plan(.subscription(productID: monthly), nil), .manage])
    }

    /// "On expiry: one lapsed row and locked cards, nothing else": no plan, payment or Manage row.
    /// Restore stays, as on every screen without Pro.
    func testLapsedIsOneRowAndNothingElse() {
        let shown = rows(.lapsed(expiredOn: earlier), isPro: false)
        XCTAssertEqual(shown, [.lapsed(endedOn: earlier), .restore])
        XCTAssertEqual(shown.filter { if case .lapsed = $0 { return true } else { return false } }.count, 1)
        XCTAssertFalse(shown.contains(.manage))
        XCTAssertFalse(shown.contains(.billingIssue))
    }

    /// "An entitled subscriber never sees the lapsed row" — whatever the status says while the two
    /// are read at different moments.
    func testAnEntitledUserNeverSeesTheLapsedRow() {
        for status in [ProStatus.lapsed(expiredOn: earlier), .never] {
            XCTAssertEqual(rows(status, isPro: true), [.unlocked], "\(status)")
        }
    }

    /// The other way round: no entitlement is never told Pro is active.
    func testNoEntitlementIsNeverShownAsActive() {
        XCTAssertEqual(rows(.active(productID: monthly, renewsOn: renewal, willAutoRenew: true), isPro: false),
                       [.upgrade, .restore])
        XCTAssertEqual(rows(.lifetime(subscriptionStillRenews: false), isPro: false), [.upgrade, .restore])
    }

    func testBillingRetryAndGraceShowThePaymentRowAndManage() {
        XCTAssertEqual(rows(.billingIssue(productID: monthly, graceUntil: later), isPro: true),
                       [.unlocked, .plan(.subscription(productID: monthly), .expires(later)), .billingIssue, .manage])
        XCTAssertEqual(rows(.billingIssue(productID: monthly, graceUntil: nil), isPro: false),
                       [.plan(.subscription(productID: monthly), nil), .billingIssue, .manage])
    }

    /// "Lifetime with a renewing subscription shows the Manage row"; plain Lifetime has none.
    func testLifetimeShowsManageOnlyWhileASubscriptionStillRenews() {
        XCTAssertEqual(rows(.lifetime(subscriptionStillRenews: false), isPro: true), [.unlocked, .plan(.lifetime, nil)])
        XCTAssertEqual(rows(.lifetime(subscriptionStillRenews: true), isPro: true),
                       [.unlocked, .plan(.lifetime, nil), .stillRenews, .manage])
    }

    // MARK: - Manage Subscription and Redeem Code (gate 10.3)

    private let accountURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    func testManageIsApplesPageOnTheMacAndTheSheetOnIOS() {
        XCTAssertEqual(SubscriptionManagement.accountSubscriptionsURL, accountURL)
        for major in [14, 15, 26, 27] {
            XCTAssertEqual(SubscriptionManagement.manageRoute(on: .macOS(majorVersion: major)), .url(accountURL))
        }
        XCTAssertEqual(SubscriptionManagement.manageRoute(on: .iOS(appOnMac: false)), .sheet)
        XCTAssertEqual(SubscriptionManagement.manageRoute(on: .iOS(appOnMac: true)), .url(accountURL),
                       "the iPhone app on a Mac")
    }

    /// O9: no offer code ships in 1.4.1, so Redeem Code is hidden on every platform; once one
    /// does, it shows on iOS and macOS 15+, never below macOS 15.
    func testRedeemCodeIsHiddenWithoutAnOfferCodeAndBelowMacOS15() {
        XCTAssertFalse(SubscriptionManagement.offerCodesShip)
        for platform in [SubscriptionManagement.Platform.iOS(appOnMac: false), .iOS(appOnMac: true),
                         .macOS(majorVersion: 14), .macOS(majorVersion: 15), .macOS(majorVersion: 27)] {
            XCTAssertFalse(SubscriptionManagement.showsRedeemCode(on: platform), "\(platform)")
        }
        XCTAssertTrue(SubscriptionManagement.showsRedeemCode(on: .iOS(appOnMac: false), offerCodesShip: true))
        XCTAssertTrue(SubscriptionManagement.showsRedeemCode(on: .macOS(majorVersion: 15), offerCodesShip: true))
        XCTAssertFalse(SubscriptionManagement.showsRedeemCode(on: .macOS(majorVersion: 14), offerCodesShip: true))
        XCTAssertFalse(SubscriptionManagement.showsRedeemCode(on: .iOS(appOnMac: true), offerCodesShip: true))
    }

    /// The branch this build takes where it runs: on macOS (CI's StrideTests, the Mac Settings
    /// window) Manage is the URL and Redeem is hidden.
    func testTheRunningPlatformsBranch() {
        #if os(macOS)
        guard case .macOS(let major) = SubscriptionManagement.Platform.current else {
            return XCTFail("a macOS build reports \(SubscriptionManagement.Platform.current)")
        }
        XCTAssertGreaterThanOrEqual(major, 14)
        XCTAssertEqual(SubscriptionManagement.manageRoute(on: .current), .url(accountURL))
        #else
        guard case .iOS = SubscriptionManagement.Platform.current else {
            return XCTFail("an iOS build reports \(SubscriptionManagement.Platform.current)")
        }
        #endif
        XCTAssertFalse(SubscriptionManagement.showsRedeemCode(on: .current))
    }
}
