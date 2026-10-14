import Foundation

// What a purchase did, and what Pro looks like to the user, as pure values
// (RELEASE-1.4.1.md D12). **Owner: W5.** Scaffolded by W0: the types are the API sketch and
// every mapping is a stub returning a neutral value; nothing calls them yet.
//
// No StoreKit here, on purpose: StoreKit's results cannot be built in a test
// (StoreServiceTests.swift says why), and Shared/ also compiles into the widget,
// scripts/demo_check and scripts/sync_rehearsal. StoreService keeps the adapter — the
// `purchase(_:)` switch and `checkVerified` — and translates StoreKit's values into the mirror
// types below; PurchaseOutcomeTests (StrideTests, host-less) cover the mappings, and the hosted
// SKTestSession tests cover the adapter.
//
// Shared/ rules: no user-facing text (Settings words the rows, W5), no `appCalendar`.

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
/// about, never a quiet cancel (the 1.2.x bug, StoreService.purchase).
enum PurchaseOutcome: Equatable {
    case purchased(productID: String)
    case cancelled
    case pending
    case failedVerification(productID: String)

    init(_ result: PurchaseResultMirror) {
        // TODO(W5): verified → purchased, unverified → failedVerification (never cancelled),
        // userCancelled/unknown → cancelled, pending → pending.
        self = .pending
    }
}

/// One subscription's status, mirrored from `Product.SubscriptionInfo.Status` and its
/// verified transaction and renewal info.
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
    /// Billing retry or grace period: "Payment problem — update your payment method" + Manage.
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
    ///     nil when that call threw or returned nothing.
    static func resolve(entitledProductIDs: Set<String>, lifetimeProductID: String,
                        statuses: [SubscriptionStatusMirror]?) -> ProStatus {
        // TODO(W5): D12 — lifetime from the entitlements; entitled + statuses nil → active with
        // nil dates; billing retry / grace → billingIssue; lapsed only with no Pro entitlement
        // and an expired (or revoked, with its date) status.
        .never
    }
}
