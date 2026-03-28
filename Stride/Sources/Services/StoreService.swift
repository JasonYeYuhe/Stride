import StoreKit
import SwiftUI

/// Product identifiers for Stride Pro subscription.
enum StrideProduct: String, CaseIterable {
    case monthlyPro = "yyh.stride.habittracker.pro.monthly"
    case yearlyPro = "yyh.stride.habittracker.pro.yearly"

    var displayName: String {
        switch self {
        case .monthlyPro: return "Monthly"
        case .yearlyPro: return "Yearly"
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

    // MARK: - Load Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        await fetchProducts()
    }

    func retryLoadProducts() async {
        products = []
        await fetchProducts()
    }

    private func fetchProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let ids = StrideProduct.allCases.map(\.rawValue)
            let storeProducts = try await Product.products(for: ids)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            #if DEBUG
            print("Failed to load products: \(error)")
            #endif
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

                    // Features
                    VStack(alignment: .leading, spacing: 16) {
                        ProFeatureRow(icon: "infinity", color: .green, title: "Unlimited Habits", subtitle: "Track as many habits as you want")
                        ProFeatureRow(icon: "chart.line.uptrend.xyaxis", color: .blue, title: "Advanced Statistics", subtitle: "Deep insights into your progress")
                        ProFeatureRow(icon: "widget.small", color: .purple, title: "Home Screen Widgets", subtitle: "Quick access from your home screen")
                        ProFeatureRow(icon: "bell.badge.fill", color: .orange, title: "Smart Reminders", subtitle: "Never miss a habit again")
                        ProFeatureRow(icon: "icloud.fill", color: .cyan, title: "iCloud Sync", subtitle: "Seamless across all your devices")
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
                            Text("Please check your internet connection and try again.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
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
                                let isYearly = product.id.contains("yearly")
                                PricingCard(
                                    title: isYearly ? "Yearly" : "Monthly",
                                    price: product.displayPrice + (isYearly ? "/yr" : "/mo"),
                                    isPopular: isYearly
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
                        Text("Payment will be charged to your Apple ID account. Subscription automatically renews unless cancelled at least 24 hours before the end of the current period.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 16) {
                            Link("Terms", destination: URL(string: "https://jasonyeyuhe.github.io/Stride/support")!)
                            Link("Privacy", destination: URL(string: "https://jasonyeyuhe.github.io/Stride/privacy")!)
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
    let isPopular: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                        if isPopular {
                            Text("BEST VALUE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.green))
                        }
                    }
                    if isPopular {
                        Text("Save 44%")
                            .font(.caption)
                            .foregroundStyle(.green)
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
                            .stroke(isPopular ? Color.green : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
