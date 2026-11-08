import Foundation

/// The paywall as values (RELEASE-1.4.2.md D4). **A W0 stub: W2 fills it.**
///
/// What W2 builds here, pure (no StoreKit: Shared/ is compiled into the widget):
/// - inputs: one mirror per product (id, plan kind, price, display price, period, currency code
///   and its fraction digits, the intro offer's payment mode and period, `eligible: Bool?`) and
///   `isPro`, which suppresses any trial;
/// - outputs: the plan order by kind (Yearly, Monthly, Lifetime — never by price), the default
///   selection (Yearly), the CTA kind, the terms kind, Yearly's per-month figure rounded up to
///   the currency's minor unit, and the savings figure rounded down;
/// - the fixtures `-paywallFixture <state>` selects (D14; StrideDebugLaunchFlags).
///
/// It returns values, never words: ProPaywallView (W3) owns the catalog keys.
struct PaywallModel: Equatable {}
