import StoreKit
import SwiftUI

// MARK: - Pro Paywall View

/// The paywall (RELEASE-1.4.2.md D4): what Stride Pro is, three plan cards, and one buy button
/// with the selected plan's terms beside it.
///
/// - **Values, not words, come from the model.** `StoreService.paywallModel` (or, in DEBUG, a
///   `PaywallFixture`) gives the plan order (Yearly, Monthly, Lifetime: by kind, never price), the
///   selection, the CTA and terms kinds, Yearly's per-month figure and the savings badge. This
///   view owns every catalog key; only prices come from StoreKit.
/// - **Selection.** Yearly is selected first; tapping a card selects it; the one CTA under the
///   cards buys the selection.
/// - **The bar.** The CTA, the selected plan's terms and the Terms and Privacy links sit in a bar
///   pinned to the bottom (`safeAreaInset`), so they are on the first screen. At accessibility
///   sizes, or wherever the bar would take more than `barShareLimit` of the height (a probe
///   `ViewThatFits` decides), the bar is the end of the scroll content instead.
/// - **States** (`PaywallPhase`): loading, load failed, ready, purchasing, pending, restore's
///   answer inline, a failed purchase through the alert, unlocked with Continue.
/// - **Dismissal.** An entitlement that arrives while this paywall's own purchase or restore is
///   not running (another device, a cold start's late read) closes it: there is nothing left to
///   sell. Its own purchase ends on "Stride Pro is unlocked" with Continue instead.
struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let store = StoreService.shared

    /// Why it was opened (D4): the header's subtitle and which feature row comes first.
    let trigger: PaywallTrigger
    /// What the presenter resumes once Stride Pro is unlocked. Continue dismisses the paywall and
    /// then calls it, in that order, so a presenter that swaps the sheet for the request it
    /// resumes (the shell, D8) ends on that request, and one that passes nothing just closes.
    let onUnlock: () -> Void

    /// This paywall's own step, when it has one: a purchase, Ask to Buy, Restore's answer, a
    /// failed purchase, unlocked. Nil follows the store: loading, load failed or ready.
    @State private var action: PaywallPhase?
    /// The card the user tapped; nil keeps the model's default (Yearly).
    @State private var selectedPlanID: String?
    @State private var showError = false
    @State private var errorMessage = ""
    /// Restore granted Pro: the unlocked state says so.
    @State private var unlockedByRestore = false
    /// The probe's answer (`barFitProbe`): the bar fits in `barShareLimit` of the height.
    @State private var barFits = true

    #if DEBUG
    /// `-paywallFixture <state>` (D14), or PaywallRenderTests' fixture: the paywall drawn from
    /// pure data, with no StoreKit read, no purchase and no auto-dismiss.
    private let fixture: PaywallFixture?
    #endif

    /// Every presenter passes its trigger (W0); `.settings` is the default only so that a new
    /// presenter compiles before it picks one.
    init(trigger: PaywallTrigger = .settings, onUnlock: @escaping () -> Void = {}) {
        self.trigger = trigger
        self.onUnlock = onUnlock
        #if DEBUG
        fixture = PaywallFixture(launchValue: StrideDebugLaunchFlags.current.paywallFixture)
        #endif
    }

    #if DEBUG
    /// A fixture's paywall (PaywallRenderTests); nil draws the store, as in the app.
    init(trigger: PaywallTrigger = .settings, fixture: PaywallFixture?, onUnlock: @escaping () -> Void = {}) {
        self.trigger = trigger
        self.onUnlock = onUnlock
        self.fixture = fixture
    }
    #endif

    // MARK: - What it shows

    /// The plans as values, with the user's selection applied.
    private var model: PaywallModel {
        var model: PaywallModel
        #if DEBUG
        model = fixture?.model ?? store.paywallModel
        #else
        model = store.paywallModel
        #endif
        if let selectedPlanID { model.select(selectedPlanID) }
        return model
    }

    private var isFixture: Bool {
        #if DEBUG
        fixture != nil
        #else
        false
        #endif
    }

    private var phase: PaywallPhase {
        #if DEBUG
        if let fixture { return action ?? fixture.phase }
        #endif
        if let action { return action }
        if !model.plans.isEmpty { return .ready }
        // Between retries `loadError` holds the last attempt's failure while `isLoading` stays
        // true: still loading. Before the first load starts, neither is set: loading too.
        if !store.isLoading, let loadError = store.loadError { return .loadFailed(loadError) }
        return .loading
    }

    /// The bar is the end of the scroll content: at accessibility sizes (D4), or where it would
    /// take more than `barShareLimit` of the height (a phone in landscape at a large size).
    private var barInline: Bool { dynamicTypeSize.isAccessibilitySize || !barFits }

    /// The most of the paywall's height the pinned bar may take before it moves into the scroll
    /// content: the plan cards keep the rest.
    static let barShareLimit: CGFloat = 0.45

    // MARK: - Body

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                page
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !barInline { bar(.pinned) }
                    }
                    .background(alignment: .bottom) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            barFitProbe(height: geometry.size.height * Self.barShareLimit)
                        }
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
                if isFixture {
                    showFixtureAlert()
                    return
                }
                await store.loadProducts()
                await store.refreshPurchasedProducts()
            }
            .onChange(of: store.isPro) { _, isPro in
                guard isPro, !isFixture else { return }
                if phase == .pending {
                    // The Ask to Buy this paywall started was approved while it stayed open.
                    action = .unlocked
                } else if Self.autoDismisses(phase: phase, isPurchasing: store.isPurchasing,
                                             isRestoring: store.isRestoring) {
                    // A Lifetime owner can land here from a feature that was still locked on a
                    // cold start, or Pro arrives from another device: stop selling what they own.
                    dismiss()
                }
            }
            .alert("Purchase Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .overlay {
                if phase == .purchasing {
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
        // present it (sheet audit, 2026-10-22). 520, as History's and New Habit's (2026-11-09):
        // the sheet is about 65 pt taller than this with its toolbar, and at 620 History's was
        // taller than a minimum-size (700-pt) main window below its toolbar, its Done bar half
        // off the bottom edge. At 520 their bottom buttons end 60 pt inside that window, so the
        // pinned bar (CTA, terms, links: about 130 pt here) is on screen with the plan cards
        // scrolling above it; a larger window lets the sheet grow (min, not fixed).
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520)
        #endif
    }

    /// The scrolling page: header, features, plans (or a state), Restore, and the legal lines.
    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    features
                    switch phase {
                    case .loading:
                        ProgressView()
                            .padding()
                    case .loadFailed:
                        loadFailed
                    case .unlocked:
                        unlocked
                    case .ready, .purchasing, .pending, .restore, .purchaseFailed:
                        plans
                        restore
                    }
                    if barInline { bar(.inline) }
                    if phase != .unlocked { legal }
                }
                .padding(.bottom, 20)
            }
            #if DEBUG
            .task { await scrollToLaunchAnchor(proxy) }
            #endif
        }
    }

    // MARK: - Header and features

    private var header: some View {
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
                .accessibilityAddTraits(.isHeader)

            triggerSubtitle
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("paywall.subtitle")
        }
        .padding(.top, 20)
        .padding(.horizontal, 24)
    }

    /// The header's subtitle, by why the paywall opened (D4). LocalizationSourceScanTests pins
    /// these with D11's claims: W12 changes them in the same commit as the rest.
    @ViewBuilder
    private var triggerSubtitle: some View {
        switch trigger {
        case .analytics: Text("See what's changing, not just where you are")
        case .weeklyReview, .today: Text("See how your week went")
        case .groups: Text("Organize your habits into groups")
        case .settings, .onboarding: Text("Almost everything is free. Pro adds three things.")
        case .lapsed: Text("Welcome back")
        }
    }

    /// D11's three things, in D11's order: the case order is the source order of the rows below.
    enum ProFeature: CaseIterable {
        case habitGroups, advancedAnalytics, weeklyReview
    }

    /// The trigger's row first, the other two in D11's order; no lead for Settings, onboarding
    /// and the lapsed row.
    static func featureOrder(for trigger: PaywallTrigger) -> [ProFeature] {
        let lead: ProFeature?
        switch trigger {
        case .groups: lead = .habitGroups
        case .analytics: lead = .advancedAnalytics
        case .weeklyReview, .today: lead = .weeklyReview
        case .settings, .onboarding, .lapsed: lead = nil
        }
        guard let lead else { return ProFeature.allCases }
        return [lead] + ProFeature.allCases.filter { $0 != lead }
    }

    // Features: exactly what Pro is (RELEASE-1.4.1.md D11), the same three things as Settings'
    // upsell and the store's STRIDE PRO block, and the same Advanced Analytics sentence as
    // Statistics' locked card. "Your top 5 streaks", never "your best streaks": the free detail
    // card keeps its Best Streak tile. Everything else — habits, reminders, widgets, sync,
    // measurable and flexible habits, the Strength tile, History — is free.
    // LocalizationSourceScanTests.testProClaimsNameExactlyD11sSet pins the rows: each literal is
    // written once, in D11's order; the trigger only permutes them at run time.
    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.featureOrder(for: trigger), id: \.self) { feature in
                switch feature {
                case .habitGroups:
                    ProFeatureRow(icon: "folder.fill", color: .blue, title: "Habit Groups", subtitle: "Organize habits into collapsible groups")
                case .advancedAnalytics:
                    ProFeatureRow(icon: "chart.line.uptrend.xyaxis", color: .green, title: "Advanced Analytics", subtitle: "Insights, the 8-week trend, the strength chart and your top 5 streaks")
                case .weeklyReview:
                    ProFeatureRow(icon: "calendar.badge.clock", color: .orange, title: "Weekly Review", subtitle: "A look back at how your week went")
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Plans

    private var plans: some View {
        let model = self.model
        return VStack(spacing: 12) {
            ForEach(model.plans) { plan in
                planCard(plan, isSelected: plan.id == model.selectedPlanID)
            }
        }
        .padding(.horizontal, 24)
        .paywallAnchor("plans")
    }

    /// One card. Lifetime keeps its title and subtitle but no badge and no highlight of its own:
    /// the highlight is the selection's.
    @ViewBuilder
    private func planCard(_ plan: PaywallModel.Plan, isSelected: Bool) -> some View {
        let select = { selectedPlanID = plan.id }
        switch plan.kind {
        case .yearly:
            PricingCard(title: "Yearly", price: plan.displayPrice + appLocalized("/yr"),
                        perMonth: perMonthPrice(plan), badge: savingsBadge(plan), trialBadge: trialBadge(plan),
                        subtitle: "Billed annually", isSelected: isSelected, action: select)
        case .monthly:
            PricingCard(title: "Monthly", price: plan.displayPrice + appLocalized("/mo"),
                        isSelected: isSelected, action: select)
        case .lifetime:
            PricingCard(title: "Lifetime", price: plan.displayPrice,
                        subtitle: "One-time purchase — yours forever", isSelected: isSelected, action: select)
        }
    }

    /// "SAVE 44%": typed as a LocalizedStringKey here, so the runtime key is "SAVE %lld%%" —
    /// never a pre-formatted String.
    private func savingsBadge(_ plan: PaywallModel.Plan) -> LocalizedStringKey? {
        guard let percent = plan.savingsPercent else { return nil }
        return "SAVE \(percent)%"
    }

    /// "7-day free trial", only when the model states the trial (eligible, a free-trial offer,
    /// not Pro). The day count comes from the offer, through the stringsdict.
    private func trialBadge(_ plan: PaywallModel.Plan) -> LocalizedStringKey? {
        guard let days = plan.trialDays else { return nil }
        return "\(days)-day free trial"
    }

    /// Yearly's price / 12, rounded up by the model, formatted as the product's own price
    /// (`priceFormatStyle`); a fixture formats it for the US storefront its prices stand in for.
    private func perMonthPrice(_ plan: PaywallModel.Plan) -> String? {
        guard let amount = plan.perMonthPrice else { return nil }
        #if DEBUG
        if isFixture {
            return amount.formatted(.currency(code: plan.currencyCode).locale(Locale(identifier: "en_US")))
        }
        #endif
        return store.formattedPrice(amount, productID: plan.id)
    }

    // MARK: - Restore

    private var restore: some View {
        VStack(spacing: 6) {
            Button("Restore Purchases", action: restorePurchases)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .disabled(store.isRestoring || phase == .purchasing)
            if case .restore(let outcome) = phase {
                restoreAnswer(outcome)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.restoreAnswer")
            }
        }
        .padding(.horizontal, 24)
    }

    /// Restore's answer, inline (D6). A cancelled Apple Account sheet says nothing.
    @ViewBuilder
    private func restoreAnswer(_ outcome: RestoreOutcome) -> some View {
        switch outcome {
        case .restored: Text("Purchases restored")
        case .nothingFound: Text("No purchases found for this Apple ID")
        case .failed: Text("Couldn't reach the App Store")
        case .cancelled: EmptyView()
        }
    }

    // MARK: - States

    /// Both `ProductLoadError` kinds read the same: the raw detail went to Sentry.
    private var loadFailed: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Stride Pro options couldn't load. Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                guard !isFixture else { return }
                Task { await store.retryLoadProducts() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(.horizontal, 24)
    }

    private var unlocked: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Stride Pro is unlocked")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if unlockedByRestore {
                Text("Purchases restored")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - The bar

    enum BarPlacement {
        /// Pinned to the bottom (`safeAreaInset`).
        case pinned
        /// The end of the scroll content.
        case inline
        /// The invisible copy `barFitProbe` measures.
        case probe

        /// The accessibility identifiers' prefix, for the hosted render tests and the sweeps.
        var identifierPrefix: String {
            switch self {
            case .pinned: return "paywall.bar"
            case .inline: return "paywall.scroll"
            case .probe: return "paywall.probe"
            }
        }
    }

    /// The CTA, the selected plan's terms right under it, and the Terms and Privacy links; while
    /// Ask to Buy waits, its line above the CTA. Unlocked, it holds Continue alone.
    @ViewBuilder
    private func bar(_ placement: BarPlacement) -> some View {
        let model = self.model
        let phase = self.phase
        let id = placement.identifierPrefix
        VStack(spacing: 10) {
            if phase == .unlocked {
                Button {
                    dismiss()
                    onUnlock()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .accessibilityIdentifier("\(id).continue")
            } else {
                if phase == .pending {
                    Text("Waiting for approval. Stride Pro unlocks when it's approved.")
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("\(id).pending")
                }
                if let plan = model.selectedPlan, let cta = model.cta, let terms = model.terms {
                    Button(action: buySelectedPlan) {
                        ctaLabel(cta)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(phase == .purchasing)
                    .accessibilityIdentifier("\(id).cta")
                    .paywallAnchor(placement == .inline ? "cta" : nil)

                    termsText(terms, price: plan.displayPrice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(id).terms")
                        .paywallAnchor(placement == .inline ? "terms" : nil)
                }
                links(id)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, placement == .pinned ? 8 : 0)
        .frame(maxWidth: .infinity)
        .background {
            if placement == .pinned {
                Rectangle()
                    .fill(.bar)
                    .overlay(alignment: .top) { Divider() }
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    @ViewBuilder
    private func ctaLabel(_ cta: PaywallModel.CTA) -> some View {
        switch cta {
        case .startTrial(let days): Text("Start \(days)-day free trial")
        case .subscribe: Text("Subscribe")
        case .buyLifetime: Text("Buy Lifetime")
        }
    }

    /// The selected plan's terms (D4); `price` is its billed price as the App Store formats it.
    @ViewBuilder
    private func termsText(_ terms: PaywallModel.Terms, price: String) -> some View {
        switch terms {
        case .trial(let days):
            Text("Free for \(days) days, then \(price)/year. Renews automatically unless cancelled at least 24 hours before the trial ends.")
        case .renewsYearly:
            Text("\(price)/year. Renews automatically unless cancelled at least 24 hours before the end of the period.")
        case .renewsMonthly:
            Text("\(price)/month. Renews automatically unless cancelled at least 24 hours before the end of the period.")
        case .oneTime:
            Text("One payment of \(price). No subscription.")
        }
    }

    static let termsOfUseURL = URL(string: "https://jasonyeyuhe.github.io/stride-site/terms")!
    static let privacyPolicyURL = URL(string: "https://jasonyeyuhe.github.io/stride-site/privacy")!

    /// Terms of Use and Privacy Policy, side by side where they fit, else one above the other.
    private func links(_ id: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { termsLink(id); privacyLink(id) }
            VStack(spacing: 8) { termsLink(id); privacyLink(id) }
        }
        .font(.caption)
    }

    private func termsLink(_ id: String) -> some View {
        Link("Terms of Use", destination: Self.termsOfUseURL)
            .accessibilityIdentifier("\(id).termsOfUse")
    }

    private func privacyLink(_ id: String) -> some View {
        Link("Privacy Policy", destination: Self.privacyPolicyURL)
            .accessibilityIdentifier("\(id).privacyPolicy")
    }

    /// Whether the bar fits in `barShareLimit` of the height: a `ViewThatFits` given exactly that
    /// height, over an invisible copy of the bar, answers by which child appears. Measured apart
    /// from where the bar is drawn, so moving it never changes the answer.
    private func barFitProbe(height: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            bar(.probe)
                .onAppear { barFits = true }
            Color.clear
                .onAppear { barFits = false }
        }
        .frame(height: max(0, height), alignment: .bottom)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Legal

    /// The legal lines (D4): how billing works, and the trial clause, which is true with or
    /// without an offer (D16's words), so it shows whether or not a trial is stated.
    private var legal: some View {
        VStack(spacing: 4) {
            Text("Payment will be charged to your Apple ID account. The Monthly and Yearly plans auto-renew unless cancelled at least 24 hours before the end of the period; Lifetime is a one-time purchase.")
            Text("If a free trial is offered, you are charged when it ends unless you cancel at least 24 hours before it ends. Any unused part of a trial ends when you subscribe.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.legal")
    }

    // MARK: - Actions

    /// D4's dismissal rule: an entitlement closes the paywall only when it arrives from
    /// elsewhere, never during this paywall's own purchase or restore, and never once it has
    /// something to say about them (pending, restore's answer stays readable until then, unlocked).
    static func autoDismisses(phase: PaywallPhase, isPurchasing: Bool, isRestoring: Bool) -> Bool {
        guard !isPurchasing, !isRestoring else { return false }
        switch phase {
        case .loading, .loadFailed, .ready, .restore, .purchaseFailed: return true
        case .purchasing, .pending, .unlocked: return false
        }
    }

    private func buySelectedPlan() {
        guard !isFixture, let plan = model.selectedPlan,
              let product = store.products.first(where: { $0.id == plan.id }) else { return }
        action = .purchasing
        Task {
            do {
                switch try await store.purchase(product) {
                case .purchased: action = .unlocked
                case .pending: action = .pending
                case .cancelled, .failedVerification: action = nil
                }
            } catch {
                action = nil
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func restorePurchases() {
        guard !isFixture else { return }
        Task {
            let outcome = await store.restorePurchases()
            switch outcome {
            case .restored where store.isPro:
                unlockedByRestore = true
                action = .unlocked
            case .cancelled:
                action = nil
            default:
                action = .restore(outcome)
            }
        }
    }

    /// `purchaseFailed`'s fixture: the alert a failed purchase shows.
    private func showFixtureAlert() {
        #if DEBUG
        guard fixture?.phase == .purchaseFailed else { return }
        errorMessage = StoreError.failedVerification(underlying: nil).localizedDescription
        showError = true
        #endif
    }

    #if DEBUG
    /// `-paywallScrollTo cta|terms|plans` (D14) scrolls once, on launch, so scripts/a11y_sweep.sh
    /// can capture what sits below the fold: `simctl` cannot scroll. `cta` and `terms` are in the
    /// scroll content only when the bar is (accessibility sizes); pinned, they need no scroll.
    private func scrollToLaunchAnchor(_ proxy: ScrollViewProxy) async {
        guard let target = StrideDebugLaunchFlags.current.paywallScrollTo else { return }
        // After the first layout pass (and the sheet's presentation): a scrollTo issued before
        // the target has a frame does nothing, silently.
        try? await Task.sleep(for: .milliseconds(800))
        proxy.scrollTo(target.rawValue, anchor: .top)
    }
    #endif
}

private extension View {
    /// A scroll target for `-paywallScrollTo` (D14). Release builds return the view untouched, so
    /// the anchor cannot change identity or layout there.
    @ViewBuilder
    func paywallAnchor(_ name: String?) -> some View {
        #if DEBUG
        if let name { id(name) } else { self }
        #else
        self
        #endif
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
            Spacer(minLength: 0)
        }
        // The icon is decorative; the two lines are one feature.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.feature")
    }
}

/// One plan: a button that selects it (D4). The billed price is the largest price text; Yearly
/// adds its per-month figure under it, smaller.
struct PricingCard: View {
    let title: LocalizedStringKey
    /// The billed price, "$19.99/yr".
    let price: String
    /// Yearly's price per month, already formatted ("$1.67").
    var perMonth: String? = nil
    var badge: LocalizedStringKey? = nil
    var trialBadge: LocalizedStringKey? = nil
    var subtitle: LocalizedStringKey? = nil
    var isSelected: Bool = false
    let action: () -> Void

    /// The billed price's font, the largest price text on the card (PaywallRenderTests).
    static let billedPriceFont: Font = .title3.bold()
    /// The per-month figure's.
    static let perMonthFont: Font = .caption

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Group {
                    // Title, badges and price side by side left each a third of the card at the
                    // accessibility sizes: "Life/tim/e", "$19.9/9". From AX1 up each gets its own
                    // line; below it the layout is the one the store screenshots show.
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                            badges
                            subtitleView
                            priceView(alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title)
                                    .font(.headline)
                                badges
                                subtitleView
                            }
                            Spacer(minLength: 8)
                            priceView(alignment: .trailing)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.appSecondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
                    )
            )
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paywall.plan")
    }

    private func priceView(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(price)
                .font(Self.billedPriceFont)
            if let perMonth {
                Text("\(perMonth)/month")
                    .font(Self.perMonthFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        if badge != nil || trialBadge != nil {
            HStack(spacing: 6) {
                if let trialBadge { badgeView(trialBadge) }
                if let badge { badgeView(badge) }
            }
        }
    }

    private func badgeView(_ badge: LocalizedStringKey) -> some View {
        Text(badge)
            .scaledSystemFont(size: 9, weight: .bold, relativeTo: .caption2)
            // Black on the green fill: white reads at 2.2:1 there (ColorContrast).
            .foregroundStyle(Color.content(onFillHex: "#34C759"))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(hex: "#34C759") ?? .green))
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
