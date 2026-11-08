import XCTest
import Foundation

/// `PaywallModel` (RELEASE-1.4.2.md D4, W2), host-less on macOS in CI: the plan order and
/// selection, when the trial is stated, its day count, Yearly's per-month figure and the savings
/// badge, from product mirrors StoreKit's own types never reach. ProPaywallView (W3) words what
/// this returns; StoreServiceTests and the SKTestSession tests cover the adapter that fills it.
final class PaywallModelTests: XCTestCase {

    private let monthlyID = "yyh.stride.habittracker.pro.monthly"
    private let yearlyID = "yyh.stride.habittracker.pro.yearly"
    private let lifetimeID = "yyh.stride.habittracker.pro.lifetime"

    private let week = SubscriptionPeriodMirror(value: 1, unit: .week)

    private func trialOffer(_ period: SubscriptionPeriodMirror) -> PaywallProductMirror.IntroOffer {
        .init(paymentMode: .freeTrial, period: period)
    }

    private func product(_ kind: PaywallProductMirror.Kind, _ price: String, display: String? = nil,
                         currency: String = "USD", digits: Int = 2,
                         offer: PaywallProductMirror.IntroOffer? = nil, eligible: Bool? = nil) -> PaywallProductMirror {
        let id: String
        let period: SubscriptionPeriodMirror?
        switch kind {
        case .monthly: (id, period) = (monthlyID, SubscriptionPeriodMirror(value: 1, unit: .month))
        case .yearly: (id, period) = (yearlyID, SubscriptionPeriodMirror(value: 1, unit: .year))
        case .lifetime: (id, period) = (lifetimeID, nil)
        }
        return PaywallProductMirror(id: id, kind: kind, price: Decimal(string: price)!, displayPrice: display ?? "$\(price)",
                                    period: period, currencyCode: currency, currencyFractionDigits: digits,
                                    introOffer: offer, eligible: eligible)
    }

    /// The three US products, Yearly with the 7-day trial, in StoreService's price order.
    private func products(eligible: Bool?, offer: PaywallProductMirror.IntroOffer?? = nil) -> [PaywallProductMirror] {
        let yearlyOffer = offer ?? trialOffer(week)
        return [product(.monthly, "2.99", eligible: eligible),
                product(.yearly, "19.99", offer: yearlyOffer, eligible: eligible),
                product(.lifetime, "39.99")]
    }

    // MARK: - The trial

    /// D4: trial words only when Yearly's intro offer is a free trial, eligibility returned true
    /// and the user is not Pro. Ineligible (an earlier Monthly) and unknown both read as no.
    func testTheTrialShowsOnlyWhenEligibilityIsTrue() {
        let eligible = PaywallModel(products: products(eligible: true), isPro: false)
        XCTAssertEqual(eligible.trialDays, 7)
        XCTAssertEqual(eligible.selectedPlan?.trialDays, 7)
        XCTAssertEqual(eligible.cta, .startTrial(days: 7))
        XCTAssertEqual(eligible.terms, .trial(days: 7))

        for answer in [false, nil] as [Bool?] {
            let model = PaywallModel(products: products(eligible: answer), isPro: false)
            let label = "eligible \(answer.map(String.init) ?? "unknown")"
            XCTAssertNil(model.trialDays, label)
            XCTAssertTrue(model.plans.allSatisfy { $0.trialDays == nil }, label)
            XCTAssertEqual(model.cta, .subscribe, label)
            XCTAssertEqual(model.terms, .renewsYearly, label)
        }
    }

    /// No intro offer (today's state, until the owner creates it, D5), or an intro offer that is
    /// not free: no trial words, even when eligible.
    func testNoTrialWithoutAFreeTrialOffer() {
        let paid = PaywallProductMirror.IntroOffer(paymentMode: .payUpFront, period: week)
        for offer in [nil, paid] as [PaywallProductMirror.IntroOffer?] {
            let model = PaywallModel(products: products(eligible: true, offer: .some(offer)), isPro: false)
            XCTAssertNil(model.trialDays, "\(String(describing: offer))")
            XCTAssertEqual(model.cta, .subscribe)
            XCTAssertEqual(model.terms, .renewsYearly)
        }
    }

    /// `isPro` returns no trial at all: StoreKit calls a Lifetime owner eligible for Yearly's trial.
    func testIsProGivesNoTrial() {
        let model = PaywallModel(products: products(eligible: true), isPro: true)
        XCTAssertNil(model.trialDays)
        XCTAssertTrue(model.plans.allSatisfy { $0.trialDays == nil })
        XCTAssertEqual(model.cta, .subscribe)
        XCTAssertEqual(model.terms, .renewsYearly)
    }

    /// The day count comes from the offer's period: P1W and P7D are both 7 days. A period that
    /// cannot be said in days is not stated (Stride creates only P1W, D16).
    func testP1WAndP7DAreBothSevenDays() {
        let p1w = SubscriptionPeriodMirror(value: 1, unit: .week)
        let p7d = SubscriptionPeriodMirror(value: 7, unit: .day)
        XCTAssertEqual(p1w.days, 7)
        XCTAssertEqual(p7d.days, 7)
        for period in [p1w, p7d] {
            let model = PaywallModel(products: products(eligible: true, offer: .some(trialOffer(period))), isPro: false)
            XCTAssertEqual(model.trialDays, 7, "\(period)")
            XCTAssertEqual(model.cta, .startTrial(days: 7))
            XCTAssertEqual(model.terms, .trial(days: 7))
        }
        XCTAssertEqual(SubscriptionPeriodMirror(value: 2, unit: .week).days, 14)
        let month = SubscriptionPeriodMirror(value: 1, unit: .month)
        XCTAssertNil(month.days)
        XCTAssertNil(PaywallModel(products: products(eligible: true, offer: .some(trialOffer(month))), isPro: false).trialDays)
    }

    // MARK: - Yearly's per-month figure and the savings badge

    /// `price / 12` rounded UP to the currency's minor unit, the digits as Foundation formats the
    /// currency (what the adapter passes): cents for USD and EUR, whole yen and won. All but the
    /// real 19.99 are prices where rounding to the nearest unit would go down.
    func testPerMonthIsRoundedUpToTheMinorUnit() {
        let cases: [(currency: String, locale: String, yearly: String, digits: Int, perMonth: String)] = [
            ("USD", "en_US", "24.99", 2, "2.09"),   // 2.0825
            ("USD", "en_US", "19.99", 2, "1.67"),   // 1.66583…
            ("EUR", "de_DE", "24.99", 2, "2.09"),
            ("EUR", "fr_FR", "20.41", 2, "1.71"),   // 1.70083…
            ("JPY", "ja_JP", "3100", 0, "259"),     // 258.33…
            ("KRW", "ko_KR", "25000", 0, "2084"),   // 2083.33…
        ]
        for c in cases {
            let digits = PaywallProductMirror.fractionDigits(currencyCode: c.currency, locale: Locale(identifier: c.locale))
            XCTAssertEqual(digits, c.digits, c.currency)
            let model = PaywallModel(products: [product(.yearly, c.yearly, currency: c.currency, digits: digits)], isPro: false)
            XCTAssertEqual(model.plans.first?.perMonthPrice, Decimal(string: c.perMonth), "\(c.currency) \(c.yearly)")
        }
        // An exact twelfth stays exact; only Yearly has the figure.
        XCTAssertEqual(PaywallModel.perMonthPrice(yearlyPrice: 3000, fractionDigits: 0), 250)
        XCTAssertEqual(PaywallModel.perMonthPrice(yearlyPrice: Decimal(string: "24")!, fractionDigits: 2), 2)
        let all = PaywallModel(products: products(eligible: true), isPro: false)
        XCTAssertEqual(all.plans.map(\.perMonthPrice), [Decimal(string: "1.67"), nil, nil])
    }

    /// The badge's percent is rounded DOWN: 2.99 and 19.99 save 44.28 % → 44; 49.6 % → 49. None
    /// without Monthly or with no saving, and only on Yearly.
    func testSavingsAreRoundedDown() {
        XCTAssertEqual(PaywallModel.savingsPercent(monthlyPrice: Decimal(string: "2.99")!, yearlyPrice: Decimal(string: "19.99")!), 44)
        XCTAssertEqual(PaywallModel.savingsPercent(monthlyPrice: 10, yearlyPrice: Decimal(string: "60.48")!), 49)
        XCTAssertEqual(PaywallModel.savingsPercent(monthlyPrice: 450, yearlyPrice: 3000), 44)   // 44.44 %
        XCTAssertNil(PaywallModel.savingsPercent(monthlyPrice: 2, yearlyPrice: 24))
        XCTAssertNil(PaywallModel.savingsPercent(monthlyPrice: 0, yearlyPrice: 24))

        let model = PaywallModel(products: products(eligible: true), isPro: false)
        XCTAssertEqual(model.plans.map(\.savingsPercent), [44, nil, nil])
        let noMonthly = PaywallModel(products: [product(.yearly, "19.99"), product(.lifetime, "39.99")], isPro: false)
        XCTAssertEqual(noMonthly.plans.map(\.savingsPercent), [nil, nil])
    }

    // MARK: - Order and selection

    /// By kind, never by price: the local StoreKit file ties Lifetime and Yearly at 19.99, and
    /// StoreService sorts by price, so either may come first. Yearly is first and selected.
    func testYearlyIsFirstAndSelectedWithTiedLifetimeAndYearlyPrices() {
        let monthly = product(.monthly, "2.99")
        let yearly = product(.yearly, "19.99")
        let lifetime = product(.lifetime, "19.99")
        for input in [[monthly, lifetime, yearly], [monthly, yearly, lifetime], [lifetime, yearly, monthly]] {
            let model = PaywallModel(products: input, isPro: false)
            XCTAssertEqual(model.plans.map(\.kind), [.yearly, .monthly, .lifetime], "\(input.map(\.kind))")
            XCTAssertEqual(model.plans.map(\.id), [yearlyID, monthlyID, lifetimeID])
            XCTAssertEqual(model.selectedPlanID, yearlyID)
        }
    }

    /// Tapping a card selects it, and the one CTA and the terms follow the selection.
    func testTheCTAAndTermsFollowTheSelection() {
        var model = PaywallModel(products: products(eligible: true), isPro: false)
        model.select(monthlyID)
        XCTAssertEqual(model.cta, .subscribe)
        XCTAssertEqual(model.terms, .renewsMonthly)
        model.select(lifetimeID)
        XCTAssertEqual(model.cta, .buyLifetime)
        XCTAssertEqual(model.terms, .oneTime)
        model.select("not.a.product")
        XCTAssertEqual(model.selectedPlanID, lifetimeID, "an unknown id changes nothing")
        model.select(yearlyID)
        XCTAssertEqual(model.cta, .startTrial(days: 7))

        // Without Yearly the first plan is selected; with no plans, nothing.
        XCTAssertEqual(PaywallModel(products: [product(.lifetime, "39.99"), product(.monthly, "2.99")], isPro: false)
            .selectedPlanID, monthlyID)
        let empty = PaywallModel(products: [], isPro: false)
        XCTAssertNil(empty.selectedPlanID)
        XCTAssertNil(empty.cta)
        XCTAssertNil(empty.terms)
    }

    // MARK: - Fixtures (D14's `-paywallFixture`)

    /// Every state D4 lists has a fixture, and the trial fixtures say what their names say.
    func testTheFixturesCoverD4sStates() {
        let phases = PaywallFixture.allCases.map(\.phase)
        for state in [PaywallPhase.loading, .loadFailed(.storeError), .ready, .purchasing, .pending,
                      .restore(.restored), .restore(.nothingFound), .restore(.failed), .purchaseFailed, .unlocked] {
            XCTAssertTrue(phases.contains(state), "no fixture for \(state)")
        }
        XCTAssertEqual(PaywallFixture.trial.model.cta, .startTrial(days: 7))
        for fixture in [PaywallFixture.ineligible, .unknownEligibility, .noOffer, .pro] {
            XCTAssertNil(fixture.model.trialDays, "\(fixture)")
            XCTAssertEqual(fixture.model.plans.count, 3, "\(fixture)")
        }
        XCTAssertTrue(PaywallFixture.loading.model.plans.isEmpty)
        XCTAssertEqual(PaywallFixture.yen.model.plans.first?.perMonthPrice, 250)
        XCTAssertEqual(PaywallFixture(launchValue: "pending"), .pending)
        XCTAssertNil(PaywallFixture(launchValue: "nowhere"))
        XCTAssertNil(PaywallFixture(launchValue: nil))
    }
}
