import StoreKit
import SwiftUI

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

    @ObservationIgnored
    private var updateListenerTask: Task<Void, Error>?

    private init() {
        updateListenerTask = listenForTransactions()
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

    // MARK: - Purchase

    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = checkVerified(verification)
            if let transaction {
                await transaction.finish()
                await refreshPurchasedProducts()
                return true
            }
            return false

        case .userCancelled:
            return false

        case .pending:
            return false

        @unknown default:
            return false
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

        purchasedProductIDs = purchased
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
        case .unverified:
            return nil
        case .verified(let transaction):
            return transaction
        }
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
                            .font(.system(size: 56))
                            .foregroundStyle(.yellow.gradient)

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
                                    price: product.displayPrice + (isLifetime ? "" : (isYearly ? "/yr" : "/mo")),
                                    badge: isLifetime ? "BEST VALUE" : (isYearly ? "SAVE" : nil),
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
    }
}

struct PricingCard: View {
    let title: LocalizedStringKey
    let price: String
    var badge: String? = nil
    var subtitle: String? = nil
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.green))
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(price)
                    .font(.title3.bold())
            }
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
}
