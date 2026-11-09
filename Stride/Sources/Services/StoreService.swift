import StoreKit
import SwiftUI
#if canImport(Sentry)
import Sentry
#endif

/// Product identifiers for Stride Pro subscription.
enum StrideProduct: String, CaseIterable {
    case monthlyPro = "yyh.stride.habittracker.pro.monthly"
    case yearlyPro = "yyh.stride.habittracker.pro.yearly"
    case lifetimePro = "yyh.stride.habittracker.pro.lifetime"

    var displayName: String {
        switch self {
        case .monthlyPro: return "Monthly"
        case .yearlyPro: return "Yearly"
        case .lifetimePro: return "Lifetime"
        }
    }
}

/// Errors the paywall shows to the user.
enum StoreError: LocalizedError {
    /// The App Store returned the purchase, but its signed transaction failed verification on
    /// this device (clock skew, a signature problem — or, rarely, tampering). `underlying` is
    /// StoreKit's `VerificationError`.
    case failedVerification(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            // errorDescription is a nonisolated protocol requirement, so this one cannot go
            // through appLocalized (main-actor). System language rather than the in-app picker.
            return String(localized: "Stride couldn't verify this purchase on your device. If you were charged, tap Restore Purchases — restoring never charges you again.")
        }
    }
}

/// Manages StoreKit 2 subscriptions.
@MainActor
@Observable
final class StoreService {
    static let shared = StoreService()

    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isLoading = false

    var isPro: Bool {
        #if DEBUG
        // `-demoPro` (RELEASE-1.4.2.md D14): the Pro sweep without a purchase. DEBUG-only.
        if StrideDebugLaunchFlags.current.demoPro { return true }
        #endif
        return !purchasedProductIDs.isEmpty
    }

    /// What Settings shows about Pro (RELEASE-1.4.1.md D12): the plan, its renewal date, a
    /// payment problem, a subscription still renewing beside Lifetime, or when Pro ended.
    /// **Display only**: `isPro` stays derived from `Transaction.currentEntitlements` alone, so
    /// no status read — failed, slow or stale — can lock out an entitled user. Recomputed inside
    /// `refreshPurchasedProducts()` (launch, foreground, Mac activation, Settings shown, the
    /// paywall, a purchase) and so on every verified `Transaction.updates`.
    private(set) var proStatus: ProStatus = .never

    @ObservationIgnored
    private var updateListenerTask: Task<Void, Error>?
    /// The subscription group's App Store id, once read (`subscriptionGroupID()`).
    @ObservationIgnored
    private var subscriptionGroupID: String?
    /// What the last status read returned: the provisional `proStatus` that follows a change of
    /// entitlements is resolved against it until the next read comes back.
    @ObservationIgnored
    private var lastStatuses: [SubscriptionStatusMirror]?
    @ObservationIgnored
    private var lastLifetimeRevokedOn: Date?
    /// Bumped by each refresh, so only the newest one writes the status it read: refreshes
    /// interleave at their awaits (a foreground and a `Transaction.updates` at once).
    @ObservationIgnored
    private var statusReadGeneration = 0

    private convenience init() {
        self.init(listensForTransactions: true)
    }

    /// The app has one, `shared`. StrideAppTests make their own over an `SKTestSession`
    /// (StoreKitStatusTests), so the host app's entitlements and status are never theirs.
    init(listensForTransactions: Bool) {
        if listensForTransactions { updateListenerTask = listenForTransactions() }
    }

    /// Ends the `Transaction.updates` listener (a hosted test's own instance, in tearDown).
    func stopListeningForTransactions() {
        updateListenerTask?.cancel()
        updateListenerTask = nil
    }

    /// Why the last load ended without products (RELEASE-1.4.2.md D6): a kind the paywall words
    /// in one sentence, the same for both. The raw detail goes only to the Sentry report
    /// (`reportProductLoad`), never to the screen. Nil while loading and once products load.
    private(set) var loadError: ProductLoadError?
    private var loadAttempts = 0
    private static let maxRetries = 5

    /// `product.subscription?.isEligibleForIntroOffer` by product id, read once per load, before
    /// the products are published (so the paywall never draws "Subscribe" and then swaps in the
    /// trial). A product that is not a subscription, or whose answer was never read, has no
    /// entry: unknown, which the paywall reads as not eligible (D4).
    private(set) var introOfferEligibility: [String: Bool] = [:]

    // MARK: - Load Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        loadAttempts = 0
        await fetchProducts()
    }

    func retryLoadProducts() async {
        products = []
        introOfferEligibility = [:]
        loadError = nil
        loadAttempts = 0
        await fetchProducts()
    }

    private func fetchProducts() async {
        isLoading = true
        defer { isLoading = false }

        let ids = Set(StrideProduct.allCases.map(\.rawValue))
        // The latest attempt's failure. A load that ends without products reports it once
        // (`reportProductLoad`): after the final attempt, and also when the paywall closes during
        // the retries — they take 30 s behind a spinner, and a user who gives up first is the
        // usual case, so "after the final attempt" alone would hear of few broken paywalls.
        // Until 2026-10-22 none reached Sentry: a paywall that could not sell looked healthy.
        var lastFailure: ProductLoadFailure?
        defer {
            if products.isEmpty, let lastFailure { Self.reportProductLoad(lastFailure, attempts: loadAttempts) }
        }

        while loadAttempts < Self.maxRetries {
            guard !Task.isCancelled else { return }
            loadAttempts += 1
            do {
                let storeProducts = try await Product.products(for: ids)
                if storeProducts.isEmpty {
                    lastFailure = .noProducts
                    loadError = .noProducts
                    if loadAttempts < Self.maxRetries {
                        let delay = pow(2.0, Double(loadAttempts)) // 2s, 4s, 8s, 16s
                        try await Task.sleep(for: .seconds(delay))
                        continue
                    }
                } else {
                    // Eligibility first, then the products: one publish, with the trial decided.
                    introOfferEligibility = await Self.introOfferEligibility(of: storeProducts)
                    // The paywall orders by plan kind (PaywallModel), never by price; the price
                    // order stays for anything that lists `products` directly.
                    products = storeProducts.sorted { $0.price < $1.price }
                    loadError = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                lastFailure = .error(error)
                loadError = .storeError
                if loadAttempts < Self.maxRetries {
                    let delay = pow(2.0, Double(loadAttempts))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }
    }

    /// Each subscription's `isEligibleForIntroOffer`, asked once per load. Eligibility is per
    /// subscription group, so Monthly and Yearly answer the same; asking each keeps the mirror
    /// honest if a second group ever appears.
    private static func introOfferEligibility(of products: [Product]) async -> [String: Bool] {
        var answers: [String: Bool] = [:]
        for product in products {
            guard let subscription = product.subscription else { continue }
            answers[product.id] = await subscription.isEligibleForIntroOffer
        }
        return answers
    }

    // MARK: - The paywall's values (RELEASE-1.4.2.md D4)

    /// The loaded products as the pure paywall needs them. A product whose id is not one of
    /// `StrideProduct`'s is left out.
    var paywallMirrors: [PaywallProductMirror] {
        products.compactMap { Self.paywallMirror($0, eligible: introOfferEligibility[$0.id]) }
    }

    /// What the paywall draws: the plans by kind, the selection, the CTA and terms kinds, Yearly's
    /// per-month figure and the savings badge (rounded down, `PaywallModel.savingsPercent`).
    /// With `isPro` it states no trial: a Lifetime owner is "eligible" for Yearly's.
    var paywallModel: PaywallModel { PaywallModel(products: paywallMirrors, isPro: isPro) }

    /// Each loaded product's `displayPrice` by product id, for Settings' trial line
    /// (`ProSettingsRow.trialLine`). Empty until the products load (they can be missing offline):
    /// the line then keeps its date and drops the price.
    var displayPrices: [String: String] {
        Dictionary(products.map { ($0.id, $0.displayPrice) }, uniquingKeysWith: { first, _ in first })
    }

    /// `amount` formatted as the product's own price is (its `priceFormatStyle`: the storefront's
    /// currency and locale), for Yearly's per-month figure. Nil when the product is not loaded.
    func formattedPrice(_ amount: Decimal, productID: String) -> String? {
        products.first { $0.id == productID }.map { $0.priceFormatStyle.format(amount) }
    }

    /// One product as `PaywallProductMirror`; nil for an id that is not `StrideProduct`'s.
    /// `eligible`: what `isEligibleForIntroOffer` answered at load, nil if it was never read.
    nonisolated static func paywallMirror(_ product: Product, eligible: Bool?) -> PaywallProductMirror? {
        let kind: PaywallProductMirror.Kind
        switch StrideProduct(rawValue: product.id) {
        case .monthlyPro: kind = .monthly
        case .yearlyPro: kind = .yearly
        case .lifetimePro: kind = .lifetime
        case nil: return nil
        }
        let style = product.priceFormatStyle
        let currencyCode = style.currencyCode
        var introOffer: PaywallProductMirror.IntroOffer?
        if let offer = product.subscription?.introductoryOffer, let period = periodMirror(offer.period) {
            // An offer of several periods lasts all of them; a free trial is one period.
            let length = SubscriptionPeriodMirror(value: period.value * max(1, offer.periodCount), unit: period.unit)
            introOffer = .init(paymentMode: paymentMode(offer.paymentMode), period: length)
        }
        return PaywallProductMirror(
            id: product.id, kind: kind, price: product.price, displayPrice: product.displayPrice,
            period: product.subscription.flatMap { periodMirror($0.subscriptionPeriod) },
            currencyCode: currencyCode,
            currencyFractionDigits: PaywallProductMirror.fractionDigits(currencyCode: currencyCode, locale: style.locale),
            introOffer: introOffer,
            // Only a subscription has an answer; Lifetime's stays nil, and no rule reads it.
            eligible: product.subscription == nil ? nil : eligible)
    }

    nonisolated static func periodMirror(_ period: Product.SubscriptionPeriod) -> SubscriptionPeriodMirror? {
        let unit: SubscriptionPeriodMirror.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return SubscriptionPeriodMirror(value: period.value, unit: unit)
    }

    nonisolated static func paymentMode(_ mode: Product.SubscriptionOffer.PaymentMode) -> OfferMirror.PaymentMode {
        switch mode {
        case .freeTrial: return .freeTrial
        case .payAsYouGo: return .payAsYouGo
        case .payUpFront: return .payUpFront
        default: return .unknown
        }
    }

    // MARK: - Purchase

    /// True from the start of `purchase(_:)` until it returns, its entitlement refresh included.
    /// The paywall's auto-dismiss on `isPro` (D4) fires only for an entitlement that arrives from
    /// elsewhere while no purchase or restore runs, so the purchase it started can say "Stride
    /// Pro is unlocked" with Continue instead of vanishing.
    private(set) var isPurchasing = false
    /// The same for `restorePurchases()`: its refresh can grant Pro, and the paywall answers it
    /// inline instead of closing.
    private(set) var isRestoring = false

    /// What the purchase did (RELEASE-1.4.2.md D6): bought and granted, cancelled, or pending (Ask
    /// to Buy, or a purchase that needs more from the user; its transaction arrives through
    /// `Transaction.updates` if it completes). Throws for StoreKit's own errors and for an
    /// unverified purchase (`StoreError.failedVerification`), which the paywall shows in its
    /// alert: `PurchaseOutcome.failedVerification` is never returned.
    ///
    /// The adapter of D12: StoreKit's result becomes a `PurchaseResultMirror`, and what it means
    /// is `PurchaseOutcome`'s pure mapping (Shared/PurchaseOutcome.swift), pinned host-less by
    /// PurchaseOutcomeTests and end to end by StoreKitStatusTests.
    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        isPurchasing = true
        defer { isPurchasing = false }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            // StoreKit's own failure, which the paywall shows as "Purchase Error" and nothing
            // recorded (2026-10-22). A cancel is not one, though it can arrive thrown as well as
            // returned; Ask to Buy's pending never throws.
            if !Self.isCancel(error) { Self.reportPurchaseFailure(error, productID: product.id) }
            throw error
        }

        var verificationError: Error?
        let mirror: PurchaseResultMirror
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            await refreshPurchasedProducts()
            mirror = .verified(productID: transaction.productID)

        case .success(.unverified(let transaction, let error)):
            // This used to `return false`, which the paywall treats as a quiet cancel: no alert,
            // no dismissal, "Processing…" just vanished — for a purchase the App Store completed.
            // Apple's guidance is not to grant or finish an unverified transaction, and we
            // don't: left unfinished, StoreKit redelivers it, and it is granted if it verifies
            // then. But the user has to be told, and we have to find out.
            Self.report(error, where: "purchase")
            verificationError = error
            mirror = .unverified(productID: transaction.productID)

        case .userCancelled:
            mirror = .userCancelled

        case .pending:
            mirror = .pending

        @unknown default:
            mirror = .unknown
        }

        let outcome = PurchaseOutcome(mirror)
        if case .failedVerification = outcome {
            throw StoreError.failedVerification(underlying: verificationError)
        }
        return outcome
    }

    // MARK: - Restore

    /// `AppStore.sync()`, then the entitlements again (D6). The answer is for the paywall (and
    /// later Settings) to word inline; a caller may ignore it. Adds no Sentry capture (Data
    /// safety 10).
    ///
    /// `entitledAfter` is read from the real entitlements (`purchasedProductIDs`), never from
    /// `isPro`, which DEBUG's `-demoPro` sets: a sweep run with it still hears "No purchases
    /// found" for an Apple ID that owns nothing.
    @discardableResult
    func restorePurchases() async -> RestoreOutcome {
        isRestoring = true
        defer { isRestoring = false }
        let sync: RestoreSyncResult
        do {
            try await AppStore.sync()
            sync = .synced
        } catch let error as StoreKitError {
            if case .userCancelled = error { sync = .userCancelled } else { sync = .failed }
        } catch {
            sync = .failed
        }
        await refreshPurchasedProducts()
        return RestoreOutcome(sync: sync, entitledAfter: !purchasedProductIDs.isEmpty)
    }

    // MARK: - Check Entitlements

    func refreshPurchasedProducts() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if let transaction = checkVerified(result) {
                purchased.insert(transaction.productID)
            }
        }

        // This now also runs on every foreground / app activation, so don't invalidate every
        // view that reads isPro when nothing changed.
        let entitlementsChanged = purchased != purchasedProductIDs
        if entitlementsChanged {
            purchasedProductIDs = purchased
        }

        // isPro is final here, before any status read: a slow or failing read never holds back
        // a feature. When it changed, the status follows it at once, from what the last read
        // returned; then from a fresh read. (Unchanged, the status already agrees with it, and
        // re-resolving it from the old read would only make a row flicker.)
        statusReadGeneration &+= 1
        let generation = statusReadGeneration
        if entitlementsChanged {
            setProStatus(resolveProStatus(statuses: lastStatuses, lifetimeRevokedOn: lastLifetimeRevokedOn))
        }
        let statuses = await readSubscriptionStatuses()
        var lifetimeRevokedOn: Date?
        if purchasedProductIDs.isEmpty { lifetimeRevokedOn = await lifetimeRevocationDate() }
        guard generation == statusReadGeneration else { return }   // a newer refresh writes
        lastStatuses = statuses
        lastLifetimeRevokedOn = lifetimeRevokedOn
        setProStatus(resolveProStatus(statuses: statuses, lifetimeRevokedOn: lifetimeRevokedOn))
    }

    // MARK: - Subscription Status (D12)

    /// Against the entitlements as they are NOW (`purchasedProductIDs`), never a copy taken before
    /// an await: so `proStatus` never contradicts `isPro`.
    private func resolveProStatus(statuses: [SubscriptionStatusMirror]?, lifetimeRevokedOn: Date?) -> ProStatus {
        ProStatus.resolve(entitledProductIDs: purchasedProductIDs,
                          lifetimeProductID: StrideProduct.lifetimePro.rawValue,
                          statuses: statuses, lifetimeRevokedOn: lifetimeRevokedOn)
    }

    private func setProStatus(_ status: ProStatus) {
        // Only on a change, as purchasedProductIDs: this runs on every foreground.
        if status != proStatus { proStatus = status }
    }

    /// `Product.SubscriptionInfo.status(for:)` for the subscription group, mirrored; nil when
    /// the group is unknown, the call throws, or it answers nothing verifiable. Each status whose
    /// transaction fails verification is reported and left out, as an unverified entitlement is.
    private func readSubscriptionStatuses() async -> [SubscriptionStatusMirror]? {
        guard let groupID = await subscriptionGroupID() else { return nil }
        let statuses: [Product.SubscriptionInfo.Status]
        do {
            statuses = try await Product.SubscriptionInfo.status(for: groupID)
        } catch {
            #if DEBUG
            print("[StoreKit] subscription status unavailable: \(error)")
            #endif
            return nil
        }
        let products = self.products
        let mirrored = statuses.compactMap { Self.mirror($0, products: products) }
        return mirrored.isEmpty ? nil : mirrored
    }

    /// The subscription group's id as the App Store knows it, read from a product
    /// (`product.subscription?.subscriptionGroupID`): the configuration's `stride_pro` is a local
    /// name, not ASC's. From the products already loaded; before they are (the launch reads
    /// entitlements first, and offline they may never load), from this Apple ID's own latest
    /// subscription transaction, which carries the same id and is a local read — a refresh never
    /// makes a products request. Nil for an Apple ID that never subscribed: then there is no
    /// status to read.
    private func subscriptionGroupID() async -> String? {
        if let subscriptionGroupID { return subscriptionGroupID }
        var found = products.lazy.compactMap { $0.subscription?.subscriptionGroupID }.first
        if found == nil {
            for product in [StrideProduct.monthlyPro, .yearlyPro] {
                if case .verified(let transaction)? = await Transaction.latest(for: product.rawValue),
                   let groupID = transaction.subscriptionGroupID {
                    found = groupID
                    break
                }
            }
        }
        subscriptionGroupID = found
        return found
    }

    /// A Lifetime purchase refunded or revoked: its own date, for "Pro ended on" (D12). Asked only
    /// when nothing is entitled.
    private func lifetimeRevocationDate() async -> Date? {
        guard case .verified(let transaction)? = await Transaction.latest(for: StrideProduct.lifetimePro.rawValue) else {
            return nil
        }
        return transaction.revocationDate
    }

    /// StoreKit's status, as the pure mirror. Nil when its transaction fails verification.
    ///
    /// `products`: the loaded products (possibly none), for the offer below iOS 17.2 / macOS 14.2,
    /// where a transaction says only that it was bought under an introductory offer, not which
    /// kind (`offer(of:products:)`). Display only: `isPro` never reads it (D6).
    nonisolated static func mirror(_ status: Product.SubscriptionInfo.Status,
                                   products: [Product]) -> SubscriptionStatusMirror? {
        let transaction: StoreKit.Transaction
        switch status.transaction {
        case .verified(let verified):
            transaction = verified
        case .unverified(let unverified, let error):
            report(error, where: "status \(unverified.productID)")
            return nil
        }
        // Renewal info that fails verification claims nothing: no renewal date or "still renews".
        var renewal: Product.SubscriptionInfo.RenewalInfo?
        if case .verified(let info) = status.renewalInfo { renewal = info }

        let state: SubscriptionStatusMirror.State
        switch status.state {
        case .subscribed: state = .subscribed
        case .expired: state = .expired
        case .inBillingRetryPeriod: state = .inBillingRetryPeriod
        case .inGracePeriod: state = .inGracePeriod
        case .revoked: state = .revoked
        default: state = .unknown
        }
        return SubscriptionStatusMirror(
            productID: transaction.productID, state: state,
            expirationDate: transaction.expirationDate,
            willAutoRenew: renewal?.willAutoRenew,
            gracePeriodExpirationDate: renewal?.gracePeriodExpirationDate,
            revocationDate: transaction.revocationDate,
            offer: offer(of: transaction, products: products))
    }

    /// The offer `transaction` was bought under (D6, G2-3): from `transaction.offer` on iOS 17.2 /
    /// macOS 14.2 and later. Below that only `offerType` exists, and `.introductory` is the free
    /// trial only when the loaded product's own intro offer is one; without the products it is an
    /// ordinary active row.
    nonisolated static func offer(of transaction: StoreKit.Transaction, products: [Product]) -> OfferMirror {
        if #available(iOS 17.2, macOS 14.2, *) {
            return OfferMirror.fromTransactionOffer(type: transaction.offer.map { offerType($0.type) },
                                                    paymentMode: transaction.offer?.paymentMode.map(paymentMode))
        }
        let product = products.first { $0.id == transaction.productID }
        return OfferMirror.fromLegacyOfferType(
            transaction.offerType.map(offerType),
            productIntroPaymentMode: product?.subscription?.introductoryOffer.map { paymentMode($0.paymentMode) })
    }

    nonisolated static func offerType(_ type: StoreKit.Transaction.OfferType) -> OfferMirror.OfferType {
        switch type {
        case .introductory: return .introductory
        case .promotional: return .promotional
        case .code: return .code
        case .winBack: return .winBack
        default: return .unknown
        }
    }

    @available(iOS 17.2, macOS 14.2, *)
    nonisolated static func paymentMode(_ mode: StoreKit.Transaction.Offer.PaymentMode) -> OfferMirror.PaymentMode {
        switch mode {
        case .freeTrial: return .freeTrial
        case .payAsYouGo: return .payAsYouGo
        case .payUpFront: return .payUpFront
        default: return .unknown
        }
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if let transaction = await self.checkVerified(result) {
                    await transaction.finish()
                    await self.refreshPurchasedProducts()
                }
            }
        }
    }

    private func checkVerified(_ result: VerificationResult<StoreKit.Transaction>) -> StoreKit.Transaction? {
        switch result {
        case .unverified(let transaction, let verificationError):
            // Still not granted, still not finished — but no longer invisible. An unverified
            // entitlement or update is exactly the failure a paying user would report as "I
            // bought it and it's still locked", and until now nothing recorded it.
            Self.report(verificationError, where: "verify \(transaction.productID)")
            return nil
        case .verified(let transaction):
            return transaction
        }
    }

    private nonisolated static func report(_ error: Error, where context: String) {
        #if canImport(Sentry)
        _ = SentrySDK.capture(error: error) { scope in
            scope.setTag(value: context, key: "storekit.step")
        }
        #endif
        #if DEBUG
        print("[StoreKit] unverified transaction (\(context)): \(error)")
        #endif
    }

    // MARK: - Paywall failures (2026-10-22)

    /// How a product load's latest attempt failed (`fetchProducts`).
    private enum ProductLoadFailure {
        /// The App Store answered with no products: none live in this storefront, or a product
        /// set that is not configured. No StoreKit error says so.
        case noProducts
        case error(Error)
    }

    /// The domain `reportProductLoad` files an empty answer under, code 0.
    private nonisolated static let noProductsDomain = "Stride.StoreProducts"

    /// A product load that ended without products, once per load: the paywall said "Unable to load
    /// subscription options" and nothing else heard of it.
    private nonisolated static func reportProductLoad(_ failure: ProductLoadFailure, attempts: Int) {
        var tags = ["storekit.attempts": String(attempts)]
        switch failure {
        case .noProducts:
            tags["storekit.failure"] = "empty"
            reportFailure(domain: noProductsDomain, code: 0, step: "products", tags: tags)
        case .error(let error):
            tags["storekit.failure"] = "error"
            tags.merge(underlyingTags(of: error)) { $1 }
            let ns = error as NSError
            reportFailure(domain: ns.domain, code: ns.code, step: "products", tags: tags)
        }
    }

    /// A purchase StoreKit failed (`purchase`): the product's id goes in the step, as `verify` and
    /// `status` name theirs.
    private nonisolated static func reportPurchaseFailure(_ error: Error, productID: String) {
        let ns = error as NSError
        reportFailure(domain: ns.domain, code: ns.code, step: "purchase \(productID)", tags: underlyingTags(of: error))
    }

    private nonisolated static func isCancel(_ error: Error) -> Bool {
        if let storeKit = error as? StoreKitError, case .userCancelled = storeKit { return true }
        return error is CancellationError
    }

    /// A network failure's URL error code: StoreKit's own code says only "network", and offline is
    /// not the same problem as a timeout or a refused certificate.
    private nonisolated static func underlyingTags(of error: Error) -> [String: String] {
        guard let storeKit = error as? StoreKitError, case .networkError(let underlying) = storeKit else { return [:] }
        return ["storekit.underlying_domain": NSURLErrorDomain,
                "storekit.underlying_code": String(underlying.code.rawValue)]
    }

    /// To Sentry as AppStoreLaunch reports a store failure: a fresh NSError carrying only the domain
    /// and code, the step and the rest as tags — nothing from the error's `userInfo`, no Apple ID,
    /// no price. A no-op under XCTest (SentryBootstrap never starts there), in the Mac variant, and
    /// wherever Sentry is not linked.
    private nonisolated static func reportFailure(domain: String, code: Int, step: String,
                                                  tags: [String: String]) {
        #if canImport(Sentry)
        _ = SentrySDK.capture(error: NSError(domain: domain, code: code)) { scope in
            scope.setTag(value: step, key: "storekit.step")
            for (key, value) in tags { scope.setTag(value: value, key: key) }
        }
        #endif
        #if DEBUG
        print("[StoreKit] \(step) failed: \(domain) \(code) \(tags)")
        #endif
    }
}
