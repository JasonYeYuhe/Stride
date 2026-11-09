import StoreKit
import SwiftUI

// MARK: - Pro Paywall View

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    let store = StoreService.shared

    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""

    /// Why it was opened (RELEASE-1.4.2.md D4). W3 words the header's subtitle by it and puts its
    /// feature row first; until then it is only stored.
    let trigger: PaywallTrigger
    /// What the presenter resumes once Stride Pro is unlocked: W3's Continue calls it (D4). Not
    /// called yet.
    let onUnlock: () -> Void

    /// Every presenter passes its trigger (W0); `.settings` is the default only so that a new
    /// presenter compiles before it picks one.
    init(trigger: PaywallTrigger = .settings, onUnlock: @escaping () -> Void = {}) {
        self.trigger = trigger
        self.onUnlock = onUnlock
    }

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

                    // Features: exactly what Pro is (RELEASE-1.4.1.md D11), the same three things
                    // as Settings' upsell and the store's STRIDE PRO block, and the same Advanced
                    // Analytics sentence as Statistics' locked card. "Your top 5 streaks", never
                    // "your best streaks": the free detail card keeps its Best Streak tile.
                    // Everything else — habits, reminders, widgets, sync, measurable and flexible
                    // habits, the Strength tile, History — is free.
                    // LocalizationSourceScanTests.testProClaimsNameExactlyD11sSet pins the rows.
                    VStack(alignment: .leading, spacing: 16) {
                        ProFeatureRow(icon: "folder.fill", color: .blue, title: "Habit Groups", subtitle: "Organize habits into collapsible groups")
                        ProFeatureRow(icon: "chart.line.uptrend.xyaxis", color: .green, title: "Advanced Analytics", subtitle: "Insights, the 8-week trend, the strength chart and your top 5 streaks")
                        ProFeatureRow(icon: "calendar.badge.clock", color: .orange, title: "Weekly Review", subtitle: "A look back at how your week went")
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
        #if os(macOS)
        // A ScrollView has no ideal height, and a Mac sheet sized to it is a sliver. Here, not at
        // the call sites: Stats, Weekly Review's menu item, New Habit's groups and Settings all
        // present it (sheet audit, 2026-10-22). History's size; the legal lines scroll.
        .frame(minWidth: 460, idealWidth: 520, minHeight: 620)
        #endif
    }

    /// "SAVE 44%": the interpolation is typed as a LocalizedStringKey here, outside the ternary
    /// that picks it, so the runtime key is "SAVE %lld%%" — never a pre-formatted String.
    private var yearlyBadge: LocalizedStringKey? {
        guard let percent = store.paywallModel.plans.first(where: { $0.kind == .yearly })?.savingsPercent else { return nil }
        return "SAVE \(percent)%"
    }

    private func purchaseProduct(_ product: Product) {
        isPurchasing = true
        Task {
            do {
                let outcome = try await store.purchase(product)
                isPurchasing = false
                if case .purchased = outcome {
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
