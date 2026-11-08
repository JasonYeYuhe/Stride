import Foundation

// The paywall as values (RELEASE-1.4.2.md D4, W2).
//
// Pure, as everything in Shared/ is: no StoreKit (Shared/ is compiled into the widget), no
// `appLocalized`, no words. StoreService's adapter fills one `PaywallProductMirror` per loaded
// `Product`; `PaywallModel` turns them, with `isPro`, into the plan order, the selection, the CTA
// kind, the terms kind, Yearly's per-month figure and the savings figure. ProPaywallView (W3)
// owns every catalog key and formats every number with the product's `priceFormatStyle`.
// PaywallModelTests pin it host-less, on macOS in CI.

/// A subscription period, mirrored from StoreKit's `Product.SubscriptionPeriod` (value and unit).
struct SubscriptionPeriodMirror: Hashable {
    enum Unit: Hashable {
        case day, week, month, year
    }

    var value: Int
    var unit: Unit

    init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// Its length in whole days, for day and week periods: P1W and P7D are both 7. Nil for months
    /// and years, whose length in days varies, and for an empty period. The trial copy counts in
    /// days ("Start %lld-day free trial"), so an offer that cannot be said in days is not stated.
    var days: Int? {
        guard value > 0 else { return nil }
        switch unit {
        case .day: return value
        case .week: return value * 7
        case .month, .year: return nil
        }
    }
}

/// One loaded product, as the paywall needs it (D4). StoreService fills it from StoreKit's
/// `Product`; nothing here can read StoreKit.
struct PaywallProductMirror: Hashable {
    /// The plan. Its case order is the paywall's order: Yearly, Monthly, Lifetime — by kind,
    /// **never by price** (StoreService sorts its products by price, and the local StoreKit file
    /// has tied Lifetime and Yearly at 19.99).
    enum Kind: Int, CaseIterable, Comparable, Hashable {
        case yearly, monthly, lifetime

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `product.subscription?.introductoryOffer`, mirrored.
    struct IntroOffer: Hashable {
        var paymentMode: OfferMirror.PaymentMode
        var period: SubscriptionPeriodMirror

        init(paymentMode: OfferMirror.PaymentMode, period: SubscriptionPeriodMirror) {
            self.paymentMode = paymentMode
            self.period = period
        }
    }

    /// `product.id`.
    var id: String
    var kind: Kind
    /// `product.price`, in the storefront's currency.
    var price: Decimal
    /// `product.displayPrice`: the billed price, as the App Store formats it.
    var displayPrice: String
    /// `product.subscription?.subscriptionPeriod`; nil for Lifetime.
    var period: SubscriptionPeriodMirror?
    /// `product.priceFormatStyle.currencyCode`.
    var currencyCode: String
    /// The currency's minor-unit digits (`fractionDigits(currencyCode:locale:)` with
    /// `priceFormatStyle`'s code and locale): 2 for USD and EUR, 0 for JPY and KRW.
    var currencyFractionDigits: Int
    var introOffer: IntroOffer?
    /// `product.subscription?.isEligibleForIntroOffer`. Nil when it was not asked or could not be
    /// read: unknown counts as not eligible. Eligibility is per subscription group, so a former
    /// Monthly subscriber is ineligible for Yearly's trial.
    var eligible: Bool?

    init(id: String, kind: Kind, price: Decimal, displayPrice: String, period: SubscriptionPeriodMirror?,
         currencyCode: String, currencyFractionDigits: Int, introOffer: IntroOffer? = nil, eligible: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.price = price
        self.displayPrice = displayPrice
        self.period = period
        self.currencyCode = currencyCode
        self.currencyFractionDigits = currencyFractionDigits
        self.introOffer = introOffer
        self.eligible = eligible
    }

    /// The currency's minor-unit digits as Foundation formats it in `locale` (the product's
    /// `priceFormatStyle.locale`): what the adapter passes as `currencyFractionDigits`.
    static func fractionDigits(currencyCode: String, locale: Locale) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        return max(0, formatter.maximumFractionDigits)
    }
}

/// The paywall, as values: what each plan card shows, which one is selected, and what the one
/// CTA and the terms beside it say for the selection (D4). The view words all of it.
struct PaywallModel: Equatable {
    /// One plan card.
    struct Plan: Equatable, Identifiable {
        /// The product's id.
        let id: String
        let kind: PaywallProductMirror.Kind
        let price: Decimal
        /// The billed price, the largest price text on the card.
        let displayPrice: String
        let currencyCode: String
        /// Yearly only: its price / 12, rounded **up** to the currency's minor unit (whole yen
        /// and won), so the small "%@/month" never undercuts what twelve months cost. The view
        /// formats it with the product's `priceFormatStyle`.
        let perMonthPrice: Decimal?
        /// Yearly only: the whole percent it saves against twelve Monthly payments, rounded
        /// **down** ("SAVE 44%"). Nil without Monthly, or when Yearly saves nothing.
        let savingsPercent: Int?
        /// Yearly only, when the trial shows (`PaywallModel.trialDays`): its length in days.
        let trialDays: Int?
    }

    /// The buy button's words, by kind.
    enum CTA: Equatable {
        /// "Start %lld-day free trial".
        case startTrial(days: Int)
        /// "Subscribe": Monthly, or Yearly without a trial.
        case subscribe
        /// "Buy Lifetime".
        case buyLifetime
    }

    /// The selected plan's terms, beside the CTA. Each price is the selected plan's
    /// `displayPrice`.
    enum Terms: Equatable {
        /// "Free for %lld days, then %@/year. Renews automatically unless cancelled at least 24
        /// hours before the trial ends."
        case trial(days: Int)
        /// "%@/year. Renews automatically unless cancelled …"
        case renewsYearly
        /// "%@/month. Renews automatically unless cancelled …"
        case renewsMonthly
        /// "One payment of %@. No subscription."
        case oneTime
    }

    /// Yearly, Monthly, Lifetime — whichever loaded, by kind, at most one of each.
    let plans: [Plan]
    /// When true there is no trial at all: StoreKit calls a Lifetime owner eligible for Yearly's
    /// trial (Lifetime is outside the subscription group). Presenters already show the paywall
    /// only without Pro; this is the second guard.
    let isPro: Bool
    /// The selected card's id: Yearly by default, else the first plan; nil with no plans.
    private(set) var selectedPlanID: String?

    init(products: [PaywallProductMirror], isPro: Bool) {
        self.isPro = isPro
        var byKind: [PaywallProductMirror.Kind: PaywallProductMirror] = [:]
        for product in products where byKind[product.kind] == nil {
            byKind[product.kind] = product   // the first of each kind
        }
        let monthly = byKind[.monthly]
        plans = PaywallProductMirror.Kind.allCases.compactMap { kind in
            guard let product = byKind[kind] else { return nil }
            let isYearly = kind == .yearly
            return Plan(
                id: product.id, kind: kind, price: product.price, displayPrice: product.displayPrice,
                currencyCode: product.currencyCode,
                perMonthPrice: isYearly
                    ? Self.perMonthPrice(yearlyPrice: product.price, fractionDigits: product.currencyFractionDigits)
                    : nil,
                savingsPercent: isYearly
                    ? monthly.flatMap { Self.savingsPercent(monthlyPrice: $0.price, yearlyPrice: product.price) }
                    : nil,
                trialDays: Self.trialDays(of: product, isPro: isPro))
        }
        selectedPlanID = (plans.first { $0.kind == .yearly } ?? plans.first)?.id
    }

    /// Tapping a card selects it; an id that is not a plan changes nothing.
    mutating func select(_ planID: String) {
        guard plans.contains(where: { $0.id == planID }) else { return }
        selectedPlanID = planID
    }

    var selectedPlan: Plan? { plans.first { $0.id == selectedPlanID } }

    /// The trial's days when the paywall states one (Yearly's), else nil.
    var trialDays: Int? { plans.first { $0.kind == .yearly }?.trialDays }

    /// The CTA for the selected plan; nil with no plans.
    var cta: CTA? { selectedPlan.map(Self.cta(for:)) }

    /// The terms for the selected plan; nil with no plans.
    var terms: Terms? { selectedPlan.map(Self.terms(for:)) }

    static func cta(for plan: Plan) -> CTA {
        switch plan.kind {
        case .lifetime: return .buyLifetime
        case .monthly: return .subscribe
        case .yearly: return plan.trialDays.map(CTA.startTrial(days:)) ?? .subscribe
        }
    }

    static func terms(for plan: Plan) -> Terms {
        switch plan.kind {
        case .lifetime: return .oneTime
        case .monthly: return .renewsMonthly
        case .yearly: return plan.trialDays.map(Terms.trial(days:)) ?? .renewsYearly
        }
    }

    /// The trial is stated only when all hold (D4): the product is Yearly; its intro offer is a
    /// free trial; `isEligibleForIntroOffer` returned `true` (unknown counts as no); `isPro` is
    /// false; and its period can be said in days.
    static func trialDays(of product: PaywallProductMirror, isPro: Bool) -> Int? {
        guard !isPro, product.kind == .yearly, product.eligible == true,
              let offer = product.introOffer, offer.paymentMode == .freeTrial else { return nil }
        return offer.period.days
    }

    /// `yearlyPrice / 12`, rounded up to `fractionDigits` (0 for whole units).
    static func perMonthPrice(yearlyPrice: Decimal, fractionDigits: Int) -> Decimal {
        var perMonth = yearlyPrice / 12
        var rounded = Decimal()
        NSDecimalRound(&rounded, &perMonth, max(0, fractionDigits), .up)
        return rounded
    }

    /// Whole percent Yearly saves over twelve Monthly payments: 1 − yearly / (12 × monthly),
    /// rounded DOWN so the badge never promises more than the prices deliver (2.99 and 19.99 save
    /// 44.28 % → 44; 49.6 % → 49). Nil when Monthly costs nothing or Yearly saves nothing. The
    /// same rule as `StoreService.savingsPercent`.
    static func savingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
        let twelveMonths = monthlyPrice * 12
        guard twelveMonths > 0 else { return nil }
        var fraction = (1 - yearlyPrice / twelveMonths) * 100
        var percent = Decimal()
        NSDecimalRound(&percent, &fraction, 0, .down)
        let whole = NSDecimalNumber(decimal: percent).intValue
        return whole > 0 ? whole : nil
    }
}

/// What the paywall is doing (D4's States), apart from the plans: ProPaywallView (W3) holds one
/// and words it; each has a fixture.
enum PaywallPhase: Equatable {
    case loading
    /// "Stride Pro options couldn't load. Check your connection and try again." with Try Again.
    /// The raw detail goes only to Sentry.
    case loadFailed(ProductLoadError)
    /// The plans, ready to buy.
    case ready
    case purchasing
    /// "Waiting for approval. Stride Pro unlocks when it's approved."
    case pending
    /// Restore's answer, inline: restored, no purchases found, couldn't reach the App Store.
    /// `.cancelled` shows nothing.
    case restore(RestoreOutcome)
    /// A purchase that failed, through the existing alert.
    case purchaseFailed
    /// "Stride Pro is unlocked" with Continue, which calls `onUnlock`.
    case unlocked
}

#if DEBUG
/// The paywall states `-paywallFixture <name>` draws (D14), as pure data: W3 draws them, W8's
/// sweeps and Mac captures launch them. DEBUG-only, as the switch that selects them. The prices
/// stand in for StoreKit's (the US storefront's; `yen` for a currency without a minor unit).
enum PaywallFixture: String, CaseIterable {
    // Loading the plans.
    case loading
    case loadFailed
    // The plans, by what the trial depends on.
    /// Eligible for Yearly's 7-day free trial (P1W): the trial CTA, terms and badge.
    case trial
    /// The offer exists, but this Apple ID is ineligible (an earlier subscription in the group).
    case ineligible
    /// The offer exists, but eligibility could not be read: no trial words.
    case unknownEligibility
    /// No intro offer: the paywall before the owner creates it (D5), and 1.4.2's state at review.
    case noOffer
    /// A Pro user (a Lifetime owner reached it): no trial, whatever StoreKit says.
    case pro
    /// The trial in yen, with no minor unit (¥3,000 a year is ¥250 a month).
    case yen
    // A purchase or a restore under way, or done.
    case purchasing
    case pending
    case restored
    case nothingFound
    case restoreFailed
    case purchaseFailed
    case unlocked

    /// `-paywallFixture`'s value; nil when absent or unknown.
    init?(launchValue: String?) {
        guard let launchValue, let fixture = PaywallFixture(rawValue: launchValue) else { return nil }
        self = fixture
    }

    var phase: PaywallPhase {
        switch self {
        case .loading: return .loading
        case .loadFailed: return .loadFailed(.storeError)
        case .trial, .ineligible, .unknownEligibility, .noOffer, .pro, .yen: return .ready
        case .purchasing: return .purchasing
        case .pending: return .pending
        case .restored: return .restore(.restored)
        case .nothingFound: return .restore(.nothingFound)
        case .restoreFailed: return .restore(.failed)
        case .purchaseFailed: return .purchaseFailed
        case .unlocked: return .unlocked
        }
    }

    var products: [PaywallProductMirror] {
        switch self {
        case .loading, .loadFailed: return []
        case .ineligible: return Self.dollars(eligible: false)
        case .unknownEligibility: return Self.dollars(eligible: nil)
        case .noOffer: return Self.dollars(eligible: true, offer: nil)
        case .yen: return Self.yenProducts
        case .trial, .pro, .purchasing, .pending, .restored, .nothingFound, .restoreFailed, .purchaseFailed, .unlocked:
            return Self.dollars(eligible: true)
        }
    }

    var isPro: Bool { self == .pro }

    var model: PaywallModel { PaywallModel(products: products, isPro: isPro) }

    static let monthlyID = "yyh.stride.habittracker.pro.monthly"
    static let yearlyID = "yyh.stride.habittracker.pro.yearly"
    static let lifetimeID = "yyh.stride.habittracker.pro.lifetime"

    /// Yearly's free trial as Configuration.storekit has it (D16): P1W.
    static let sevenDayTrial = PaywallProductMirror.IntroOffer(
        paymentMode: .freeTrial, period: SubscriptionPeriodMirror(value: 1, unit: .week))

    /// Ordered by price, as StoreService loads them.
    private static func dollars(eligible: Bool?, offer: PaywallProductMirror.IntroOffer? = sevenDayTrial)
        -> [PaywallProductMirror] {
        [
            PaywallProductMirror(id: monthlyID, kind: .monthly, price: Decimal(string: "2.99")!, displayPrice: "$2.99",
                                 period: .init(value: 1, unit: .month), currencyCode: "USD", currencyFractionDigits: 2,
                                 eligible: eligible),
            PaywallProductMirror(id: yearlyID, kind: .yearly, price: Decimal(string: "19.99")!, displayPrice: "$19.99",
                                 period: .init(value: 1, unit: .year), currencyCode: "USD", currencyFractionDigits: 2,
                                 introOffer: offer, eligible: eligible),
            PaywallProductMirror(id: lifetimeID, kind: .lifetime, price: Decimal(string: "39.99")!, displayPrice: "$39.99",
                                 period: nil, currencyCode: "USD", currencyFractionDigits: 2),
        ]
    }

    private static var yenProducts: [PaywallProductMirror] {
        [
            PaywallProductMirror(id: monthlyID, kind: .monthly, price: 450, displayPrice: "¥450",
                                 period: .init(value: 1, unit: .month), currencyCode: "JPY", currencyFractionDigits: 0,
                                 eligible: true),
            PaywallProductMirror(id: yearlyID, kind: .yearly, price: 3000, displayPrice: "¥3,000",
                                 period: .init(value: 1, unit: .year), currencyCode: "JPY", currencyFractionDigits: 0,
                                 introOffer: sevenDayTrial, eligible: true),
            PaywallProductMirror(id: lifetimeID, kind: .lifetime, price: 6000, displayPrice: "¥6,000",
                                 period: nil, currencyCode: "JPY", currencyFractionDigits: 0),
        ]
    }
}
#endif
