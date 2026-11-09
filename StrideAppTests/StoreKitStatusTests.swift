import XCTest
import StoreKit
import StoreKitTest
@testable import Stride

/// `StoreService.proStatus` through StoreKit itself (RELEASE-1.4.1.md D12, D14; gate 4), hosted,
/// on an `SKTestSession` over the bundled Configuration.storekit (StoreKitConfigurationLoadTests):
/// the StoreKit adapter — `purchase(_:)`, the entitlements, `Product.SubscriptionInfo.status(for:)`
/// with the group id read from the product, `Transaction.latest(for:)` — end to end, where
/// PurchaseOutcomeTests pins the pure mappings host-less. These replace the Transaction Manager
/// GUI step of DEV-PLAN-1.3.md M4 acceptance (4).
///
/// Each test has its own `StoreService` (`init(listensForTransactions:)`), never the host app's
/// `shared`, and the session is cleared before and after. Settings' rows are read through
/// `ProSettingsRow.rows`, what SettingsView draws.
///
/// **Where StoreKit testing does not work, these skip, saying why — they never pass against the
/// real store or hang the gate.** On iOS 26.3+ simulators every `SKTestSession` write fails
/// ("Error saving configuration file … SKInternalErrorDomain Code=3", Apple Developer Forums
/// thread 826364, FB22774836; measured 2026-10-15 with Xcode 27.0 on the iOS 26.5 runtime): the
/// configuration never loads, `Product.products(for:)` answers from the sandbox App Store, and a
/// purchase raises the Apple ID sheet that `disableDialogs` should have suppressed, and waits on it
/// forever. So `setUp` checks that the session took effect — the product's subscription group is
/// the configuration's own `stride_pro`, which the App Store's never is — and that it starts with
/// no entitlement, and every StoreKit call that can raise a dialog runs under a time limit.
///
/// **So the gate's own run is on an older runtime** (RELEASE-1.4.1.md gate 4), and a skip there
/// fails it (scripts/ci/run_hosted_tests.sh, "Skips"):
///
///     STRIDE_HOSTED_ALL=1 STRIDE_HOSTED_NO_SKIPS=StoreKitStatusTests,StoreKitConfigurationLoadTests \
///       scripts/ci/run_hosted_tests.sh <an iOS 18.5 simulator> \
///       -only-testing:StrideAppTests/StoreKitStatusTests -only-testing:StrideAppTests/StoreKitConfigurationLoadTests
///
/// On iOS 18.5 all of them run and pass (2026-10-15, Xcode 27.0). Until then they had never run
/// anywhere: Configuration.storekit's hand-written `"version" : 2`, not the `{major, minor}`
/// object Xcode writes, made the session load nothing there — no error, no products — so they
/// skipped on every runtime (W5-SK-1; StoreServiceTests now pins the format on every runtime).
@MainActor
final class StoreKitStatusTests: XCTestCase {

    private var session: SKTestSession!
    private var store: StoreService!

    private let monthlyID = StrideProduct.monthlyPro.rawValue
    private let lifetimeID = StrideProduct.lifetimePro.rawValue
    /// Configuration.storekit's subscription group id. Only a session that loaded the file
    /// reports it; the App Store's group id is a number.
    private static let configurationGroupID = "stride_pro"
    /// How long a StoreKit change may take to show. It only bounds a failure: on a Mac loaded by
    /// parallel builds (load average 79, 2026-10-15) a session change took most of 15 s to apply,
    /// and one `Transaction.updates` delivery took longer.
    private static let patience: Duration = .seconds(30)

    override func setUp() async throws {
        try await super.setUp()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Configuration", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        store = StoreService(listensForTransactions: false)
        try await requireAWorkingSession()
    }

    /// Skips (the class doc says why) unless the session's configuration is what StoreKit
    /// answers from, and it starts with nothing bought.
    private func requireAWorkingSession() async throws {
        let products: [Product]
        do {
            products = try await completing("loading the products", within: 15) {
                try await Product.products(for: [StrideProduct.monthlyPro.rawValue])
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("SKTestSession did not take effect on this simulator: Product.products(for:) threw \(error).")
        }
        let group = products.first?.subscription?.subscriptionGroupID
        guard group == Self.configurationGroupID else {
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            throw XCTSkip("""
                SKTestSession did not take effect on this simulator (\(os)): \(monthlyID) came back \
                as \(products.count) product(s) with subscription group \(group ?? "none"), not \
                Configuration.storekit's "\(Self.configurationGroupID)", so StoreKit is not answering \
                from the session (iOS 26.3+ simulators: FB22774836, every session write fails with \
                SKInternalErrorDomain Code=3, and the sandbox App Store answers instead). Gate 4 runs \
                these on an iOS 18.5 simulator with STRIDE_HOSTED_NO_SKIPS (the class doc).
                """)
        }
        await store.refreshPurchasedProducts()
        guard !store.isPro else {
            throw XCTSkip("SKTestSession.clearTransactions() left an entitlement (\(store.purchasedProductIDs.sorted())): the session cannot start clean on this runtime.")
        }
    }

    override func tearDown() async throws {
        store?.stopListeningForTransactions()
        store = nil
        if let session {
            try? await session.setSimulatedError(nil, forAPI: .verification)
            session.clearTransactions()
            session.resetToDefaultState()
        }
        session = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func product(_ id: StrideProduct) async throws -> Product {
        let products = try await completing("loading \(id.rawValue)", within: 15) {
            try await Product.products(for: [id.rawValue])
        }
        return try XCTUnwrap(products.first, "\(id.rawValue) is not in the session")
    }

    /// The paywall's path, `StoreService.purchase(_:)`, under a time limit.
    private func buy(_ id: StrideProduct) async throws -> PurchaseOutcome {
        let product = try await product(id)
        let store = self.store!
        return try await completing("buying \(id.rawValue)") { try await store.purchase(product) }
    }

    /// Resumes once, from whichever of the call and its time limit finishes first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool { lock.withLock { defer { resumed = true }; return !resumed } }
    }

    /// `body`'s result, or a skip once `seconds` pass: a StoreKit call that does not come back is
    /// waiting on a dialog nobody will answer (the class doc), and the hosted gate must not wait
    /// with it. A task group cannot be used: it waits for every child, the hung one included.
    private func completing<T: Sendable>(_ what: String, within seconds: Int = 30,
                                         _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let result: Result<T, Error>? = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            Task { @MainActor in
                let outcome: Result<T, Error>
                do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
                if once.claim() { continuation.resume(returning: outcome) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        guard let result else {
            throw XCTSkip("StoreKit testing: \(what) did not finish in \(seconds) s — a dialog SKTestSession.disableDialogs should suppress is waiting on this simulator.")
        }
        return try result.get()
    }

    private var rows: [ProSettingsRow] { ProSettingsRow.rows(for: store.proStatus, isPro: store.isPro) }

    /// StoreKit applies a session change (an expiry, a refund, a renewal) on its own queue:
    /// refreshes until `condition` holds, and `isPro` is `expectedPro` when one is given, or fails
    /// after `timeout`.
    ///
    /// Why both: `proStatus` comes from `Product.SubscriptionInfo.status` and `isPro` from
    /// `Transaction.currentEntitlements` (D12 keeps it there by design), and StoreKit updates the
    /// two separately. On iOS 18.5 (2026-10-20, gate 4) a test that waited for the status alone
    /// read `isPro` a moment before the entitlement caught up: billing retry showed
    /// `.billingIssue` with `isPro` still true in one run, and an expiry stayed `.active` past
    /// the patience in another while parallel builds loaded the Mac. Each test passed on the other run.
    private func refresh(until condition: () -> Bool, isPro expectedPro: Bool? = nil,
                         timeout: Duration = StoreKitStatusTests.patience,
                         _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        repeat {
            await store.refreshPurchasedProducts()
            if condition(), expectedPro.map({ store.isPro == $0 }) ?? true { return }
            try? await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        XCTFail("\(what): still \(store.proStatus), isPro \(store.isPro)", file: file, line: line)
    }

    private func testTransaction(_ productID: String) throws -> SKTestTransaction {
        try XCTUnwrap(session.allTransactions().last { $0.productIdentifier == productID },
                      "no session transaction for \(productID)")
    }

    // MARK: - Buy

    /// "Monthly shows the plan and renewal date" (gate 4): bought through the paywall's path.
    func testBuyingMonthlyShowsThePlanAndItsRenewalDate() async throws {
        let bought = try await buy(.monthlyPro)

        XCTAssertEqual(bought, .purchased(productID: monthlyID))
        XCTAssertTrue(store.isPro)
        guard case .active(let productID, let renewsOn?, let willAutoRenew) = store.proStatus else {
            return XCTFail("bought Monthly: \(store.proStatus)")
        }
        XCTAssertEqual(productID, monthlyID)
        XCTAssertEqual(willAutoRenew, true)
        XCTAssertGreaterThan(renewsOn, Date(), "the renewal date is ahead")
        XCTAssertEqual(rows, [.unlocked, .plan(.subscription(productID: monthlyID), .renews(renewsOn)), .manage])
    }

    /// Auto-renew switched off in Apple's sheet: the plan says when it expires instead.
    func testAutoRenewOffShowsTheExpiryDate() async throws {
        _ = try await buy(.monthlyPro)
        try session.disableAutoRenewForTransaction(identifier: try testTransaction(monthlyID).identifier)

        await refresh(until: {
            if case .active(_, _, false) = store.proStatus { return true } else { return false }
        }, "auto-renew off")
        guard case .active(_, let expires?, false) = store.proStatus else { return }
        XCTAssertEqual(rows, [.unlocked, .plan(.subscription(productID: monthlyID), .expires(expires)), .manage])
    }

    /// A purchase made outside this process — Ask to Buy approved, another device — reaches the
    /// status through `Transaction.updates`, with nobody calling refresh.
    func testATransactionUpdateRecomputesTheStatus() async throws {
        store.stopListeningForTransactions()
        store = StoreService(listensForTransactions: true)
        let session = self.session!, monthlyID = self.monthlyID
        _ = try await completing("an outside purchase") {
            _ = try await session.buyProduct(identifier: monthlyID)
            return true
        }

        let deadline = ContinuousClock.now + Self.patience
        while ContinuousClock.now < deadline {
            if case .active = store.proStatus { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .active(let productID, _, _) = store.proStatus else {
            return XCTFail("after an outside purchase: \(store.proStatus), isPro \(store.isPro), session transactions \(session.allTransactions().map(\.productIdentifier))")
        }
        XCTAssertEqual(productID, monthlyID)
        XCTAssertTrue(store.isPro)
    }

    // MARK: - Expire, refund

    /// "On expiry: one lapsed row and locked cards, nothing else" (gate 4).
    func testAnExpiredSubscriptionIsOneLapsedRowAndLocked() async throws {
        _ = try await buy(.monthlyPro)
        try session.expireSubscription(productIdentifier: monthlyID)

        await refresh(until: {
            if case .lapsed = store.proStatus { return true } else { return false }
        }, isPro: false, "expired")
        XCTAssertFalse(store.isPro, "locked")
        guard case .lapsed(let expiredOn) = store.proStatus else { return }
        XCTAssertLessThanOrEqual(expiredOn, Date().addingTimeInterval(60))
        XCTAssertEqual(rows, [.lapsed(endedOn: expiredOn), .restore])
    }

    /// `refundTransaction`: lapsed, with the refund's own date — not the month-later expiry.
    func testARefundIsLapsedOnTheRefundsDate() async throws {
        let before = Date().addingTimeInterval(-60)
        _ = try await buy(.monthlyPro)
        try session.refundTransaction(identifier: try testTransaction(monthlyID).identifier)

        await refresh(until: {
            if case .lapsed = store.proStatus { return true } else { return false }
        }, isPro: false, "refunded")
        XCTAssertFalse(store.isPro)
        guard case .lapsed(let endedOn) = store.proStatus else { return }
        XCTAssertGreaterThan(endedOn, before)
        XCTAssertLessThan(endedOn, Date().addingTimeInterval(24 * 3600), "the refund's date, not the renewal a month out")
        XCTAssertEqual(rows, [.lapsed(endedOn: endedOn), .restore])
    }

    /// A refunded Lifetime ends Pro too, on its own date.
    func testARefundedLifetimeIsLapsed() async throws {
        _ = try await buy(.lifetimePro)
        XCTAssertEqual(store.proStatus, .lifetime(subscriptionStillRenews: false))
        try session.refundTransaction(identifier: try testTransaction(lifetimeID).identifier)

        await refresh(until: {
            if case .lapsed = store.proStatus { return true } else { return false }
        }, isPro: false, "Lifetime refunded")
        XCTAssertFalse(store.isPro)
    }

    // MARK: - Lifetime

    /// "Lifetime never shows as lapsed" (gate 4), and has no Manage row of its own.
    func testLifetimeIsLifetime() async throws {
        let bought = try await buy(.lifetimePro)

        XCTAssertEqual(bought, .purchased(productID: lifetimeID))
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.proStatus, .lifetime(subscriptionStillRenews: false))
        XCTAssertEqual(rows, [.unlocked, .plan(.lifetime, nil)])
    }

    /// Lifetime bought during an active subscription: Lifetime, plus "A subscription still renews"
    /// and Manage — the user would otherwise keep paying (gate 4). Once the subscription expires,
    /// still Lifetime, never lapsed.
    func testLifetimeBoughtDuringAnActiveSubscription() async throws {
        _ = try await buy(.monthlyPro)
        _ = try await buy(.lifetimePro)

        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.proStatus, .lifetime(subscriptionStillRenews: true))
        XCTAssertEqual(rows, [.unlocked, .plan(.lifetime, nil), .stillRenews, .manage])

        try session.expireSubscription(productIdentifier: monthlyID)
        await refresh(until: { store.proStatus == .lifetime(subscriptionStillRenews: false) }, "subscription expired")
        XCTAssertTrue(store.isPro)
    }

    // MARK: - Unverified

    /// An unverified purchase is an error the paywall shows, never a quiet cancel — and grants
    /// nothing.
    func testAnUnverifiedPurchaseThrowsAndGrantsNothing() async throws {
        let lifetime = try await product(.lifetimePro)
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)

        let store = self.store!
        do {
            let bought = try await completing("an unverified purchase") { try await store.purchase(lifetime) }
            XCTFail("an unverified purchase returned \(bought) instead of throwing")
        } catch let skip as XCTSkip {
            throw skip
        } catch StoreError.failedVerification {
            // The paywall's alert.
        } catch {
            XCTFail("an unverified purchase threw \(error), not failedVerification")
        }
        await store.refreshPurchasedProducts()
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.proStatus, .never)
        XCTAssertEqual(rows, [.upgrade, .restore])
    }

    // MARK: - Billing retry, grace period

    /// Billing retry with no grace period: no entitlement while Apple retries, so the payment row,
    /// Manage and Restore — never lapsed.
    func testBillingRetryShowsThePaymentRow() async throws {
        session.shouldEnterBillingRetryOnRenewal = true
        _ = try await buy(.monthlyPro)
        try session.forceRenewalOfSubscription(productIdentifier: monthlyID)

        await refresh(until: {
            if case .billingIssue = store.proStatus { return true } else { return false }
        }, isPro: false, "billing retry")
        guard case .billingIssue(let productID, let graceUntil) = store.proStatus else { return }
        XCTAssertEqual(productID, monthlyID)
        XCTAssertNil(graceUntil, "no grace period")
        XCTAssertFalse(store.isPro, "billing retry without a grace period is not entitled")
        XCTAssertEqual(rows, [.plan(.subscription(productID: monthlyID), nil), .billingIssue, .manage, .restore])
        XCTAssertFalse(rows.contains { if case .lapsed = $0 { return true } else { return false } })
    }

    /// The grace period: still Pro, the payment row, Manage, and when Pro ends unless the payment
    /// goes through.
    func testAGracePeriodIsAPaymentProblemWhileStillPro() async throws {
        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        _ = try await buy(.monthlyPro)
        try session.forceRenewalOfSubscription(productIdentifier: monthlyID)

        await refresh(until: {
            if case .billingIssue(_, _?) = store.proStatus { return true } else { return false }
        }, isPro: true, "grace period")
        XCTAssertTrue(store.isPro, "entitled through the grace period")
        guard case .billingIssue(let productID, let graceUntil?) = store.proStatus else { return }
        XCTAssertEqual(productID, monthlyID)
        XCTAssertEqual(rows, [.unlocked, .plan(.subscription(productID: monthlyID), .expires(graceUntil)),
                              .billingIssue, .manage])
    }

    // MARK: - The trial, Ask to Buy, Restore (RELEASE-1.4.2.md D4, D6, D16; W2)

    private let yearlyID = StrideProduct.yearlyPro.rawValue

    /// The paywall's load on this test's store: the products, and each subscription's intro-offer
    /// eligibility, read once.
    private func loadThePaywall() async throws {
        let store = self.store!
        try await completing("loading the paywall's products", within: 30) { await store.retryLoadProducts() }
        XCTAssertEqual(Set(store.products.map(\.id)), Set(StrideProduct.allCases.map(\.rawValue)), "every product loaded")
    }

    private var trialLine: ProSettingsRow.TrialLine? {
        ProSettingsRow.trialLine(for: store.proStatus, isPro: store.isPro, displayPrices: store.displayPrices)
    }

    /// A clean session is eligible for Yearly's 7-day free trial (D16's P1W): the paywall states
    /// it, on Yearly, selected.
    func testACleanSessionIsEligibleForYearlysTrial() async throws {
        try await loadThePaywall()

        XCTAssertEqual(store.introOfferEligibility[yearlyID], true)
        let yearly = try XCTUnwrap(store.paywallMirrors.first { $0.kind == .yearly })
        XCTAssertEqual(yearly.introOffer, PaywallProductMirror.IntroOffer(
            paymentMode: .freeTrial, period: SubscriptionPeriodMirror(value: 1, unit: .week)))
        XCTAssertEqual(yearly.eligible, true)
        XCTAssertEqual(yearly.currencyCode, "USD")
        XCTAssertEqual(yearly.currencyFractionDigits, 2)

        let model = store.paywallModel
        XCTAssertEqual(model.plans.map(\.kind), [.yearly, .monthly, .lifetime], "by kind, never by price")
        XCTAssertEqual(model.selectedPlan?.kind, .yearly)
        XCTAssertEqual(model.trialDays, 7)
        XCTAssertEqual(model.cta, .startTrial(days: 7))
        XCTAssertEqual(model.terms, .trial(days: 7))
        XCTAssertEqual(model.plans.first?.perMonthPrice, Decimal(string: "1.67"), "19.99 / 12, rounded up")
        XCTAssertEqual(model.plans.first?.savingsPercent, 44)
        XCTAssertEqual(store.displayPrices[StrideProduct.lifetimePro.rawValue], "$39.99")
        XCTAssertNil(store.loadError)
    }

    /// Buying the trial: Pro at once, and Settings' trial row with its first charge — the trial's
    /// end, a week out — and the loaded price. The plan row carries no date of its own.
    func testBuyingTheTrialShowsTheTrialRowWithItsFirstCharge() async throws {
        try await loadThePaywall()
        let bought = try await buy(.yearlyPro)

        XCTAssertEqual(bought, .purchased(productID: yearlyID))
        XCTAssertTrue(store.isPro)
        guard case .trial(let productID, let firstCharge?, let willAutoRenew) = store.proStatus else {
            return XCTFail("bought Yearly's trial: \(store.proStatus)")
        }
        XCTAssertEqual(productID, yearlyID)
        XCTAssertEqual(willAutoRenew, true)
        let days = firstCharge.timeIntervalSinceNow / 86_400
        XCTAssertGreaterThan(days, 6, "the first charge is the trial's end, a week out (\(firstCharge))")
        XCTAssertLessThan(days, 8, "the first charge is the trial's end, a week out (\(firstCharge))")
        XCTAssertEqual(rows, [.unlocked, .plan(.subscription(productID: yearlyID), nil), .manage])
        XCTAssertEqual(trialLine, .firstCharge(on: firstCharge, price: "$19.99"))
        XCTAssertNil(store.paywallModel.trialDays, "Pro states no trial")
    }

    /// Past the trial's week (an accelerated session clock), Yearly renews: an ordinary active
    /// row, no longer the trial, and Pro throughout.
    func testTheTrialRenewsOnceItsWeekIsOver() async throws {
        // iOS 18.5 run: at one renewal every 10 s the trial may already have renewed by the time
        // the purchase's own refresh reads the status, so the `.trial` check right after the
        // buy can race and fail without a bug; if it does, read the session's transactions
        // (an introductory one, then a renewal) before changing the rate or the check.
        session.timeRate = .oneRenewalEveryTenSeconds
        try await loadThePaywall()
        _ = try await buy(.yearlyPro)
        if case .trial = store.proStatus {} else { XCTFail("bought Yearly's trial: \(store.proStatus)") }

        await refresh(until: {
            if case .active(let productID, _, _) = store.proStatus { return productID == yearlyID } else { return false }
        }, isPro: true, timeout: .seconds(60), "the trial renewed")
        XCTAssertNil(trialLine)
    }

    /// Auto-renew switched off during the trial: "Trial ends on <date>" while it lasts, then one
    /// lapsed row and locked cards once it ends.
    func testAutoRenewOffDuringTheTrialEndsItThenLapses() async throws {
        try await loadThePaywall()
        _ = try await buy(.yearlyPro)
        try session.disableAutoRenewForTransaction(identifier: try testTransaction(yearlyID).identifier)

        await refresh(until: {
            if case .trial(_, _?, false) = store.proStatus { return true } else { return false }
        }, isPro: true, "auto-renew off in the trial")
        guard case .trial(_, let ends?, false) = store.proStatus else { return }
        XCTAssertEqual(trialLine, .endsOn(ends))

        try session.expireSubscription(productIdentifier: yearlyID)
        await refresh(until: {
            if case .lapsed = store.proStatus { return true } else { return false }
        }, isPro: false, "the trial ended")
        guard case .lapsed(let endedOn) = store.proStatus else { return }
        XCTAssertEqual(rows, [.lapsed(endedOn: endedOn), .restore])
        XCTAssertNil(trialLine)
    }

    /// Eligibility is per subscription group: an Apple ID that had Monthly is ineligible for
    /// Yearly's trial, and the paywall then states none ("Subscribe", the renewal terms). In ONE
    /// process, as a Mac app left open lives it: the products load once while eligible, Monthly
    /// is bought and lapses, and the paywall's next appearance (`preparePaywall`, which does not
    /// reload the products) must not sell the trial from the first answer (Guideline 3.1.2).
    func testAnEarlierMonthlyMakesYearlysTrialIneligible() async throws {
        try await loadThePaywall()
        XCTAssertEqual(store.paywallModel.trialDays, 7, "a clean session is eligible")

        _ = try await buy(.monthlyPro)
        XCTAssertFalse(store.isCheckingEligibility)
        XCTAssertEqual(store.introOfferEligibility[yearlyID], false, "read again when the entitlements changed")
        try session.expireSubscription(productIdentifier: monthlyID)
        await refresh(until: {
            if case .lapsed = store.proStatus { return true } else { return false }
        }, isPro: false, "Monthly expired")

        let store = self.store!
        try await completing("the paywall's next appearance") { await store.preparePaywall() }
        XCTAssertFalse(store.isCheckingEligibility)
        XCTAssertEqual(store.introOfferEligibility[yearlyID], false)
        let model = store.paywallModel
        XCTAssertNil(model.trialDays)
        XCTAssertEqual(model.cta, .subscribe)
        XCTAssertEqual(model.terms, .renewsYearly)
    }

    /// Ask to Buy: the purchase is pending and grants nothing; once approved, Pro arrives.
    func testAskToBuyIsPendingThenApproved() async throws {
        session.askToBuyEnabled = true
        try await loadThePaywall()
        let outcome = try await buy(.yearlyPro)

        XCTAssertEqual(outcome, .pending)
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.isPurchasing, "the purchase returned")

        let pending = try XCTUnwrap(session.allTransactions().last { $0.productIdentifier == yearlyID && $0.pendingAskToBuyConfirmation },
                                    "the Ask to Buy transaction")
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        await refresh(until: { store.isPro }, isPro: true, "Ask to Buy approved")
        XCTAssertTrue(rows.contains(.unlocked))
    }

    /// Restore with nothing bought: "No purchases found", and still no Pro.
    func testRestoreWithNothingFindsNothing() async throws {
        let store = self.store!
        let outcome = try await completing("restoring") { await store.restorePurchases() }

        XCTAssertEqual(outcome, .nothingFound)
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(store.isRestoring)
    }

    /// Restore after Lifetime was bought outside this store (another device): restored, Pro.
    func testRestoreWithLifetimeRestoresIt() async throws {
        // iOS 18.5 run: a session purchase is already in `currentEntitlements` before
        // `AppStore.sync()`, so this passes whenever the sync itself succeeds — it cannot fail on
        // the restore logic alone (`RestoreOutcome`'s mapping is PurchaseOutcomeTests'). Watch
        // for `.failed` here: that is the sync, not the entitlement, under SKTestSession.
        let session = self.session!, lifetimeID = self.lifetimeID
        _ = try await completing("Lifetime bought elsewhere") {
            _ = try await session.buyProduct(identifier: lifetimeID)
            return true
        }
        let store = self.store!
        let outcome = try await completing("restoring") { await store.restorePurchases() }

        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(store.isPro)
        XCTAssertEqual(store.proStatus, .lifetime(subscriptionStillRenews: false))
    }
}

/// Settings' Manage Subscription and Redeem Code on iOS (D12, O9): no StoreKit needed, so not
/// in StoreKitStatusTests, which skips where StoreKit testing does not work. The Mac's branch is
/// pinned by PurchaseOutcomeTests, which runs on macOS.
final class SubscriptionManagementIOSTests: XCTestCase {
    func testOnIOSManageIsTheSheetAndRedeemIsHidden() {
        XCTAssertEqual(SubscriptionManagement.manageRoute(on: .current), .sheet)
        XCTAssertFalse(SubscriptionManagement.showsRedeemCode(on: .current))
    }
}
