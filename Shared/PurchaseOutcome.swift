import Foundation

// What a purchase did, and what Pro looks like to the user, as pure values
// (RELEASE-1.4.1.md D12, W5).
//
// No StoreKit here, on purpose: StoreKit's results cannot be built in a test
// (StoreServiceTests.swift says why), and Shared/ also compiles into the widget,
// scripts/demo_check and scripts/sync_rehearsal. StoreService keeps the adapter — the
// `purchase(_:)` switch, `checkVerified` and the status reads — and translates StoreKit's values
// into the mirror types below; PurchaseOutcomeTests (StrideTests, host-less, on macOS in CI)
// cover the mappings and Settings' rows, and the hosted SKTestSession tests (StoreKitStatusTests)
// cover the adapter.
//
// Shared/ rules: no user-facing text (SettingsView words the rows), no `appCalendar`.
//
// 1.4.2 (RELEASE-1.4.2.md D6, W2) adds Restore's outcome, the products' load-error kind, the
// offer on the status mirror (`OfferMirror`, with its below-17.2 fallback) and the trial's
// status and Settings line.

/// StoreKit's answer to a purchase, mirrored: `Product.PurchaseResult` with its
/// `VerificationResult` already unwrapped by the adapter.
enum PurchaseResultMirror: Equatable {
    case verified(productID: String)
    /// The App Store completed it, but the signed transaction failed verification on device.
    case unverified(productID: String)
    case userCancelled
    case pending
    /// `@unknown default`.
    case unknown
}

/// What the paywall does with a purchase. An unverified purchase is an error the user is told
/// about, never a quiet cancel (the 1.2.x bug: `purchase(_:)` returned false, which the paywall
/// treats as a cancel — no alert, no dismissal, "Processing…" just vanished, for a purchase the
/// App Store completed).
enum PurchaseOutcome: Equatable {
    case purchased(productID: String)
    case cancelled
    /// Ask to Buy, or a purchase that needs more from the user (SCA): nothing is granted yet; the
    /// transaction arrives through `Transaction.updates` if it completes.
    case pending
    case failedVerification(productID: String)

    init(_ result: PurchaseResultMirror) {
        switch result {
        case .verified(let productID): self = .purchased(productID: productID)
        case .unverified(let productID): self = .failedVerification(productID: productID)
        case .pending: self = .pending
        // A future result StoreKit adds is not a purchase this version can grant; nothing was
        // taken from the user that the paywall has to report.
        case .userCancelled, .unknown: self = .cancelled
        }
    }
}

/// How `AppStore.sync()` ended, mirrored (RELEASE-1.4.2.md D6).
enum RestoreSyncResult: Equatable {
    case synced
    /// `StoreKitError.userCancelled`: the user closed the Apple Account sheet (G2-10).
    case userCancelled
    /// Any other error: offline, the App Store unreachable.
    case failed
}

/// What Restore Purchases did (D6), for the paywall and Settings to word inline: "Purchases
/// restored", "No purchases found for this Apple ID", "Couldn't reach the App Store"; a cancel
/// shows nothing.
enum RestoreOutcome: Equatable {
    case restored
    case nothingFound
    case cancelled
    case failed

    /// - Parameters:
    ///   - sync: how `AppStore.sync()` ended.
    ///   - entitledAfter: whether `Transaction.currentEntitlements` holds a verified Stride Pro
    ///     product after the refresh that follows the sync (the real entitlements, never DEBUG's
    ///     `-demoPro`).
    ///
    /// A failed or cancelled sync says so, whatever is entitled: the sync restored nothing.
    init(sync: RestoreSyncResult, entitledAfter: Bool) {
        switch sync {
        case .synced: self = entitledAfter ? .restored : .nothingFound
        case .userCancelled: self = .cancelled
        case .failed: self = .failed
        }
    }
}

/// Why the paywall's products did not load (D6): a kind for the view to word ("Stride Pro options
/// couldn't load. Check your connection and try again."), in place of the raw text `loadError`
/// holds today. The raw detail goes only to the existing Sentry report.
enum ProductLoadError: Equatable {
    /// The App Store answered with no products (none live in this storefront, or not configured).
    case noProducts
    /// StoreKit threw: offline, a timeout, a store error.
    case storeError
}

/// The offer a subscription transaction was bought under, as Settings needs it (D6). StoreService's
/// adapter (`mirror(_:products:)`) fills it on each `SubscriptionStatusMirror`.
///
/// Only the **introductory** offer counts, on every OS: Stride creates no promotional, code or
/// win-back offer (D16), and below iOS 17.2 / macOS 14.2 the other kinds' payment mode cannot be
/// read at all, so one purchase reads the same on every version.
enum OfferMirror: Equatable {
    /// The introductory free trial.
    case freeTrial
    /// An introductory offer not known to be free (a paid intro price, or a mode StoreKit did not
    /// say): an ordinary active row.
    case introductoryPrice
    /// No introductory offer.
    case none

    /// `Transaction.OfferType`, mirrored.
    enum OfferType: Equatable {
        case introductory, promotional, code, winBack, unknown
    }

    /// `Transaction.Offer.PaymentMode` and `Product.SubscriptionOffer.PaymentMode`, mirrored.
    enum PaymentMode: Hashable {
        case freeTrial, payAsYouGo, payUpFront, unknown
    }

    /// iOS 17.2 / macOS 14.2 and later: from `transaction.offer`, its type and payment mode (both
    /// nil when the transaction has no offer).
    static func fromTransactionOffer(type: OfferType?, paymentMode: PaymentMode?) -> OfferMirror {
        introductory(type, paymentMode)
    }

    /// Below iOS 17.2 / macOS 14.2 only `transaction.offerType` exists, and `.introductory` does
    /// not say which kind: it is the trial only when the loaded product's
    /// `subscription?.introductoryOffer?.paymentMode` is `.freeTrial` (nil when the products have
    /// not loaded or the product has no intro offer); otherwise an ordinary active row (G2-3).
    static func fromLegacyOfferType(_ type: OfferType?, productIntroPaymentMode: PaymentMode?) -> OfferMirror {
        introductory(type, productIntroPaymentMode)
    }

    private static func introductory(_ type: OfferType?, _ mode: PaymentMode?) -> OfferMirror {
        guard type == .introductory else { return .none }
        return mode == .freeTrial ? .freeTrial : .introductoryPrice
    }
}

/// One subscription's status, mirrored from `Product.SubscriptionInfo.Status` and its
/// verified transaction and renewal info. A status whose transaction fails verification is not
/// mirrored at all (the adapter reports it and drops it).
struct SubscriptionStatusMirror: Equatable {
    enum State: Equatable {
        case subscribed
        case expired
        case inBillingRetryPeriod
        case inGracePeriod
        case revoked
        case unknown
    }

    var productID: String
    var state: State
    /// The transaction's expiration (the renewal date while it renews).
    var expirationDate: Date?
    /// From the renewal info; nil when it could not be verified.
    var willAutoRenew: Bool?
    var gracePeriodExpirationDate: Date?
    /// Set for a refund or a revocation.
    var revocationDate: Date?
    /// The offer the transaction was bought under (1.4.2 D6). `.freeTrial` on a subscribed status:
    /// the user is in the trial, and `expirationDate` is the first charge.
    var offer: OfferMirror

    init(productID: String, state: State, expirationDate: Date? = nil, willAutoRenew: Bool? = nil,
         gracePeriodExpirationDate: Date? = nil, revocationDate: Date? = nil, offer: OfferMirror = .none) {
        self.productID = productID
        self.state = state
        self.expirationDate = expirationDate
        self.willAutoRenew = willAutoRenew
        self.gracePeriodExpirationDate = gracePeriodExpirationDate
        self.revocationDate = revocationDate
        self.offer = offer
    }

    /// Apple is still charging, or trying to: the "payment problem" states.
    var hasBillingIssue: Bool { state == .inBillingRetryPeriod || state == .inGracePeriod }

    /// It will renew, or Apple will keep trying to charge it: a live state whose renewal info
    /// says so. Unverified renewal info (`willAutoRenew == nil`) claims nothing.
    var stillRenews: Bool {
        (state == .subscribed || hasBillingIssue) && willAutoRenew == true
    }

    /// When an ended subscription ended: an expiry's date, a refund's or revocation's own date.
    var endDate: Date? {
        switch state {
        case .expired: return expirationDate
        case .revoked: return revocationDate ?? expirationDate
        case .subscribed, .inBillingRetryPeriod, .inGracePeriod, .unknown: return nil
        }
    }
}

/// What Settings shows about Pro (D12). Display only: `StoreService.isPro` stays derived from
/// `Transaction.currentEntitlements`, so nothing here can lock out an entitled user.
enum ProStatus: Equatable {
    /// Lifetime is owned. `subscriptionStillRenews`: a subscription bought before (or beside)
    /// it still auto-renews — Settings' "A subscription still renews" row with Manage (gate 4).
    case lifetime(subscriptionStillRenews: Bool)
    /// Entitled to a subscription. Both optionals nil when its status could not be read: an
    /// entitled subscriber is never shown as lapsed, and no date is shown.
    case active(productID: String, renewsOn: Date?, willAutoRenew: Bool?)
    /// Entitled through the introductory free trial (RELEASE-1.4.2.md D6). `firstChargeOn` is the
    /// trial's end (the transaction's expiration); `willAutoRenew` is nil when the renewal info
    /// could not be verified, and then claims nothing: no date, no charge.
    case trial(productID: String, firstChargeOn: Date?, willAutoRenew: Bool?)
    /// Billing retry or grace period: "Payment problem — update your payment method" + Manage.
    /// `graceUntil`: while in the grace period, when Pro ends unless the payment goes through.
    case billingIssue(productID: String, graceUntil: Date?)
    /// No Pro entitlement, and the status says it expired (or was refunded/revoked: its own
    /// date): one row, "Pro ended on <date> — Resubscribe".
    case lapsed(expiredOn: Date)
    /// Never had Pro, or nothing to say.
    case never

    /// D12's mapping.
    /// - Parameters:
    ///   - entitledProductIDs: verified `Transaction.currentEntitlements` product ids.
    ///   - lifetimeProductID: the NonConsumable's id (outside the subscription group).
    ///   - statuses: from `Product.SubscriptionInfo.status(for:)` with the group id read from
    ///     `product.subscription?.subscriptionGroupID` (the local `stride_pro` is not ASC's);
    ///     nil when that call threw or returned nothing. Empty counts as nil.
    ///   - lifetimeRevokedOn: the refund or revocation date of a Lifetime purchase that is no
    ///     longer entitled (`Transaction.latest(for:)`), else nil.
    ///
    /// The rules, in order:
    /// 1. Lifetime entitled → `.lifetime`; it never lapses, whatever a subscription says.
    /// 2. A subscription entitled → `.billingIssue` when a status is in the grace period (or
    ///    billing retry), else `.active` from the subscribed status — preferring the entitled
    ///    product's — or `.trial` when that status was bought under the free trial (1.4.2 D6).
    ///    When no status agrees (unavailable, unverified, stale), `.active` with no date: an
    ///    entitled subscriber is never lapsed.
    /// 3. Nothing entitled → `.billingIssue` while Apple retries the charge; `.never` while a
    ///    status still says subscribed (the entitlement failed verification: Restore is the way
    ///    back, not "ended"); else `.lapsed` at the latest end date — an expiry, or a refund or
    ///    revocation at its own date, a Lifetime refund included; `.never` with nothing ended.
    static func resolve(entitledProductIDs: Set<String>, lifetimeProductID: String,
                        statuses: [SubscriptionStatusMirror]?,
                        lifetimeRevokedOn: Date? = nil) -> ProStatus {
        let statuses = statuses ?? []

        if entitledProductIDs.contains(lifetimeProductID) {
            return .lifetime(subscriptionStillRenews: statuses.contains(where: \.stillRenews))
        }

        let entitledSubscriptions = entitledProductIDs.subtracting([lifetimeProductID])
        if let fallback = entitledSubscriptions.sorted().first {
            if let issue = statuses.first(where: \.hasBillingIssue) {
                return .billingIssue(productID: issue.productID, graceUntil: graceEnd(of: issue))
            }
            let subscribed = statuses.filter { $0.state == .subscribed }
            if let live = subscribed.first(where: { entitledSubscriptions.contains($0.productID) }) ?? subscribed.first {
                if live.offer == .freeTrial {
                    return .trial(productID: live.productID, firstChargeOn: live.expirationDate,
                                  willAutoRenew: live.willAutoRenew)
                }
                return .active(productID: live.productID, renewsOn: live.expirationDate, willAutoRenew: live.willAutoRenew)
            }
            return .active(productID: fallback, renewsOn: nil, willAutoRenew: nil)
        }

        if let issue = statuses.first(where: \.hasBillingIssue) {
            return .billingIssue(productID: issue.productID, graceUntil: graceEnd(of: issue))
        }
        if statuses.contains(where: { $0.state == .subscribed }) { return .never }
        let ends = statuses.compactMap(\.endDate) + [lifetimeRevokedOn].compactMap { $0 }
        if let latest = ends.max() { return .lapsed(expiredOn: latest) }
        return .never
    }

    /// The grace period's end, only while in it: after it, billing retry has no access to end.
    private static func graceEnd(of status: SubscriptionStatusMirror) -> Date? {
        status.state == .inGracePeriod ? status.gracePeriodExpirationDate : nil
    }
}

/// One row of Settings' Stride Pro section (D12), in order, as values: SettingsView words and
/// draws them, so PurchaseOutcomeTests pin what each status shows — gate 4 — on macOS and iOS
/// alike, without rendering Settings.
enum ProSettingsRow: Hashable {
    /// What the plan row names.
    enum Plan: Hashable {
        case lifetime
        case subscription(productID: String)
    }

    /// The plan row's date line.
    enum DateLine: Hashable {
        /// "Renews on <date>".
        case renews(Date)
        /// "Expires on <date>": auto-renew is off, or the grace period ends then.
        case expires(Date)
    }

    /// "Upgrade to Pro" and its claim line; opens the paywall.
    case upgrade
    /// "Restore Purchases".
    case restore
    /// "Stride Pro" / "All features unlocked": only while entitled.
    case unlocked
    /// "Plan" = Monthly, Yearly or Lifetime, with its date line when one can be said.
    case plan(Plan, DateLine?)
    /// "Payment problem — update your payment method".
    case billingIssue
    /// "A subscription still renews": a Lifetime owner still paying for a subscription.
    case stillRenews
    /// "Manage Subscription" (`SubscriptionManagement.manageRoute`).
    case manage
    /// One row: "Pro ended on <date>" with "Resubscribe", which opens the paywall.
    case lapsed(endedOn: Date)

    /// The rows for `status`, given what `isPro` says now. The two are read at different moments
    /// (StoreService sets the entitlements first, the status after its read), so a disagreement
    /// resolves toward the entitlement, which is the truth for every feature: an entitled user
    /// whose status says nothing Pro-shaped sees "All features unlocked", never "ended"; a user
    /// with no entitlement is never told Pro is active (a billing retry is the one non-entitled
    /// Pro state).
    ///
    /// Every set without the entitlement ends with Restore Purchases, as Settings had it before
    /// 1.4.1: it is the way back for a purchase this device has not seen (Lifetime bought on
    /// another device while a subscription is in billing retry, a renewal whose entitlement
    /// failed verification). A billing retry gets Manage for the payment and Restore, but not the
    /// upsell: the plan row already names the user's subscription, and the payment, not another
    /// purchase, is what brings Pro back (any locked feature still opens the paywall).
    static func rows(for status: ProStatus, isPro: Bool) -> [ProSettingsRow] {
        switch status {
        case .lifetime(let stillRenews):
            guard isPro else { return [.upgrade, .restore] }
            return stillRenews ? [.unlocked, .plan(.lifetime, nil), .stillRenews, .manage]
                               : [.unlocked, .plan(.lifetime, nil)]
        case .active(let productID, let renewsOn, let willAutoRenew):
            guard isPro else { return [.upgrade, .restore] }
            return [.unlocked, .plan(.subscription(productID: productID), dateLine(renewsOn, willAutoRenew)), .manage]
        case .trial(let productID, _, _):
            // The plan row carries no date line: the trial's own line (`trialLine`) says when the
            // first charge comes, or when the trial ends.
            guard isPro else { return [.upgrade, .restore] }
            return [.unlocked, .plan(.subscription(productID: productID), nil), .manage]
        case .billingIssue(let productID, let graceUntil):
            let plan = ProSettingsRow.plan(.subscription(productID: productID), graceUntil.map(DateLine.expires))
            return isPro ? [.unlocked, plan, .billingIssue, .manage] : [plan, .billingIssue, .manage, .restore]
        case .lapsed(let endedOn):
            return isPro ? [.unlocked] : [.lapsed(endedOn: endedOn), .restore]
        case .never:
            return isPro ? [.unlocked] : [.upgrade, .restore]
        }
    }

    /// Renews or expires only when the renewal info says which; no date otherwise.
    private static func dateLine(_ date: Date?, _ willAutoRenew: Bool?) -> DateLine? {
        guard let date, let willAutoRenew else { return nil }
        return willAutoRenew ? .renews(date) : .expires(date)
    }

    /// What `trialLine` says (RELEASE-1.4.2.md D6).
    enum TrialLine: Hashable {
        /// "Free trial · first charge of %@ on %@" (price, date); without a loaded price, "Free
        /// trial · first charge on %@".
        case firstCharge(on: Date, price: String?)
        /// "Trial ends on %@": auto-renew is off.
        case endsOn(Date)
        /// "Free trial": the renewal info could not be verified (or there is no date), so no date
        /// and no charge is claimed, as `dateLine` does.
        case undated
    }

    /// The free trial's line, drawn under the plan row that `rows(for:isPro:)` gives a `.trial`
    /// status (that plan row has no date line of its own), with Manage after it. Nil for every
    /// other status, and without the entitlement (whose rows are the upsell).
    /// - Parameter displayPrices: the loaded products' `displayPrice` by product id; empty when
    ///   the products have not loaded (they load at launch and can be missing offline). Without
    ///   the trial product's price the line keeps the date and drops the price.
    static func trialLine(for status: ProStatus, isPro: Bool, displayPrices: [String: String]) -> TrialLine? {
        guard isPro, case .trial(let productID, let firstChargeOn, let willAutoRenew) = status else { return nil }
        guard let firstChargeOn, let willAutoRenew else { return .undated }
        return willAutoRenew ? .firstCharge(on: firstChargeOn, price: displayPrices[productID]) : .endsOn(firstChargeOn)
    }
}

/// Where Settings' Manage Subscription goes, and whether Redeem Code shows (D12, O9). Pure, so
/// the macOS branches are pinned by StrideTests, which run on macOS in CI (gate 10.3).
enum SubscriptionManagement {
    /// Apple's subscription settings, for where `manageSubscriptionsSheet` is unavailable: the
    /// Mac (the modifier is iOS-only), and the iPhone app running on a Mac.
    static let accountSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    /// O9: no App Store offer code ships in 1.4.1, so Redeem Code is hidden everywhere. Set this
    /// when one does — Settings then needs its row and the "Redeem Code" catalog key.
    static let offerCodesShip = false

    enum Platform: Equatable {
        /// `appOnMac`: the iPhone/iPad app on an Apple-silicon Mac (`isiOSAppOnMac`).
        case iOS(appOnMac: Bool)
        case macOS(majorVersion: Int)

        /// Where this build runs.
        static var current: Platform {
            #if os(macOS)
            return .macOS(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            #else
            return .iOS(appOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
            #endif
        }
    }

    enum Route: Equatable {
        /// `manageSubscriptionsSheet(isPresented:)`, in the app.
        case sheet
        /// Opened in the App Store.
        case url(URL)
    }

    static func manageRoute(on platform: Platform) -> Route {
        switch platform {
        case .iOS(appOnMac: false): return .sheet
        case .iOS(appOnMac: true), .macOS: return .url(accountSubscriptionsURL)
        }
    }

    /// Redeem Code (`offerCodeRedemption`): only when an offer code ships, on iOS and on
    /// macOS 15+ (where the modifier exists); hidden otherwise — on an older Mac, and for the
    /// iPhone app on a Mac, whose macOS version it cannot vouch for.
    static func showsRedeemCode(on platform: Platform, offerCodesShip: Bool = offerCodesShip) -> Bool {
        guard offerCodesShip else { return false }
        switch platform {
        case .iOS(let appOnMac): return !appOnMac
        case .macOS(let major): return major >= 15
        }
    }
}
