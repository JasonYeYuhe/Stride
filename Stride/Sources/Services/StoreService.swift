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
        !purchasedProductIDs.isEmpty
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

    private(set) var loadError: String?
    private var loadAttempts = 0
    private static let maxRetries = 5

    // MARK: - Load Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        loadAttempts = 0
        await fetchProducts()
    }

    func retryLoadProducts() async {
        products = []
        loadError = nil
        loadAttempts = 0
        await fetchProducts()
    }

    private func fetchProducts() async {
        isLoading = true
        defer { isLoading = false }

        let ids = Set(StrideProduct.allCases.map(\.rawValue))

        while loadAttempts < Self.maxRetries {
            guard !Task.isCancelled else { return }
            loadAttempts += 1
            do {
                let storeProducts = try await Product.products(for: ids)
                if storeProducts.isEmpty {
                    loadError = "No products returned by the App Store (attempt \(loadAttempts)/\(Self.maxRetries))"
                    if loadAttempts < Self.maxRetries {
                        let delay = pow(2.0, Double(loadAttempts)) // 2s, 4s, 8s, 16s
                        try await Task.sleep(for: .seconds(delay))
                        continue
                    }
                } else {
                    products = storeProducts.sorted { $0.price < $1.price }
                    loadError = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
                if loadAttempts < Self.maxRetries {
                    let delay = pow(2.0, Double(loadAttempts))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }
    }

    // MARK: - Yearly Saving

    /// Whole percent the yearly plan saves over twelve months of the monthly one, from the
    /// storefront's real prices: 1 − yearly / (12 × monthly), rounded DOWN so the badge never
    /// promises more than the prices deliver (2.99/mo and 19.99/yr save 44.28% → "SAVE 44%";
    /// 49.6% would read 49, not 50). Nil — no badge — when either product is missing or the
    /// yearly plan saves nothing. The badge used to be a bare "SAVE" with no figure; a hard-coded figure would go
    /// stale the first time a price tier or storefront changed.
    var yearlySavingsPercent: Int? {
        guard let monthly = products.first(where: { $0.id == StrideProduct.monthlyPro.rawValue }),
              let yearly = products.first(where: { $0.id == StrideProduct.yearlyPro.rawValue }) else {
            return nil
        }
        return Self.savingsPercent(monthlyPrice: monthly.price, yearlyPrice: yearly.price)
    }

    /// `Product.price` is a `Decimal` in the storefront's currency; both products share it.
    nonisolated static func savingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
        let twelveMonths = monthlyPrice * 12
        guard twelveMonths > 0 else { return nil }
        var fraction = (1 - yearlyPrice / twelveMonths) * 100
        var percent = Decimal()
        NSDecimalRound(&percent, &fraction, 0, .down)
        let whole = NSDecimalNumber(decimal: percent).intValue
        return whole > 0 ? whole : nil
    }

    // MARK: - Purchase

    /// True when the product was bought and granted; false for a cancel or a pending purchase
    /// (Ask to Buy), which the paywall leaves open in silence. Throws for StoreKit's own errors and
    /// for an unverified purchase (`StoreError.failedVerification`), which the paywall shows.
    ///
    /// The adapter of D12: StoreKit's result becomes a `PurchaseResultMirror`, and what it means
    /// is `PurchaseOutcome`'s pure mapping (Shared/PurchaseOutcome.swift), pinned host-less by
    /// PurchaseOutcomeTests and end to end by StoreKitStatusTests.
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()

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

        switch PurchaseOutcome(mirror) {
        case .purchased:
            return true
        case .cancelled, .pending:
            return false
        case .failedVerification:
            throw StoreError.failedVerification(underlying: verificationError)
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshPurchasedProducts()
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
        let mirrored = statuses.compactMap(Self.mirror)
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
    private nonisolated static func mirror(_ status: Product.SubscriptionInfo.Status) -> SubscriptionStatusMirror? {
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
            revocationDate: transaction.revocationDate)
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
}

// MARK: - Pro Paywall View

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let store = StoreService.shared

    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "crown.fill")
                            .scaledSystemFont(size: 56, relativeTo: .largeTitle)
                            .foregroundStyle(.yellow.gradient)
                            .accessibilityHidden(true)
                            // Decoration: uncapped it pushes the feature list off the first
                            // screen at the largest sizes.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)

                        Text("Stride Pro")
                            .font(.largeTitle.bold())

                        Text("Unlock the full experience")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // Features (everything else — habits, reminders, widgets,
                    // sync, quantitative & flexible habits — is free)
                    VStack(alignment: .leading, spacing: 16) {
                        ProFeatureRow(icon: "folder.fill", color: .blue, title: "Habit Groups", subtitle: "Organize habits into collapsible groups")
                        ProFeatureRow(icon: "chart.line.uptrend.xyaxis", color: .green, title: "Advanced Analytics", subtitle: "8-week trends, insights & weekly review")
                    }
                    .padding(.horizontal, 24)

                    // Pricing
                    if store.isLoading {
                        ProgressView()
                            .padding()
                    } else if store.products.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Unable to load subscription options.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let error = store.loadError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("Please check your internet connection and try again.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            Button("Try Again") {
                                Task { await store.retryLoadProducts() }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.green))
                        }
                        .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(store.products) { product in
                                let isLifetime = product.id.contains("lifetime")
                                let isYearly = product.id.contains("yearly")
                                PricingCard(
                                    title: isLifetime ? "Lifetime" : (isYearly ? "Yearly" : "Monthly"),
                                    price: product.displayPrice + (isLifetime ? "" : (isYearly ? appLocalized("/yr") : appLocalized("/mo"))),
                                    badge: isLifetime ? "BEST VALUE" : (isYearly ? yearlyBadge : nil),
                                    subtitle: isLifetime ? "One-time purchase — yours forever" : (isYearly ? "Billed annually" : nil),
                                    highlighted: isLifetime
                                ) {
                                    purchaseProduct(product)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // Restore
                    Button("Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    // Legal
                    VStack(spacing: 4) {
                        Text("Payment will be charged to your Apple ID account. The Monthly and Yearly plans auto-renew unless cancelled at least 24 hours before the end of the period; Lifetime is a one-time purchase.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 16) {
                            Link("Terms of Use", destination: URL(string: "https://jasonyeyuhe.github.io/stride-site/terms")!)
                            Link("Privacy Policy", destination: URL(string: "https://jasonyeyuhe.github.io/stride-site/privacy")!)
                        }
                        .font(.caption2)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .background(Color.appBackground)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await store.loadProducts()
                await store.refreshPurchasedProducts()
            }
            // A Lifetime owner can land here from a feature that was still locked on a cold
            // start; once the entitlement read comes back, stop selling them what they own.
            .onChange(of: store.isPro) { _, isPro in
                if isPro { dismiss() }
            }
            .alert("Purchase Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .overlay {
                if isPurchasing {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Processing...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    /// "SAVE 44%": the interpolation is typed as a LocalizedStringKey here, outside the ternary
    /// that picks it, so the runtime key is "SAVE %lld%%" — never a pre-formatted String.
    private var yearlyBadge: LocalizedStringKey? {
        guard let percent = store.yearlySavingsPercent else { return nil }
        return "SAVE \(percent)%"
    }

    private func purchaseProduct(_ product: Product) {
        isPurchasing = true
        Task {
            do {
                let success = try await store.purchase(product)
                isPurchasing = false
                if success {
                    dismiss()
                }
            } catch {
                isPurchasing = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - Supporting Views

struct ProFeatureRow: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // The icon is decorative; the two lines are one feature.
        .accessibilityElement(children: .combine)
    }
}

struct PricingCard: View {
    let title: LocalizedStringKey
    let price: String
    var badge: LocalizedStringKey? = nil
    var subtitle: LocalizedStringKey? = nil
    var highlighted: Bool = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            Group {
                // Title, badge and price side by side left each a third of the card at the
                // accessibility sizes: "Life/tim/e", "BEST VALU/E", "$19.9/9". From AX1 up each
                // gets its own line; below it the layout is the one the store screenshots show.
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        if let badge { badgeView(badge) }
                        subtitleView
                        Text(price)
                            .font(.title3.bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.headline)
                                if let badge { badgeView(badge) }
                            }
                            subtitleView
                        }
                        Spacer()
                        Text(price)
                            .font(.title3.bold())
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.appSecondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(highlighted ? Color.green : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func badgeView(_ badge: LocalizedStringKey) -> some View {
        Text(badge)
            .scaledSystemFont(size: 9, weight: .bold, relativeTo: .caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.green))
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
