import XCTest
import Foundation

/// `PurchaseOutcome` and `ProStatus.resolve` (RELEASE-1.4.1.md D12), host-less: the pure
/// mappings in Shared/PurchaseOutcome.swift, which StoreKit's own types cannot reach in a test.
/// **Owner: W5.** Scaffolded by W0: no tests yet.
///
/// TODO(W5): verified → purchased; unverified → failedVerification, never cancelled; pending;
/// cancelled; lifetime; active with and without dates; "entitled, status unavailable → active,
/// never lapsed"; billing retry and grace → billingIssue; expired with no entitlement → lapsed;
/// revoked/refunded → lapsed with its own date; Lifetime with a still-renewing subscription.
final class PurchaseOutcomeTests: XCTestCase {}
