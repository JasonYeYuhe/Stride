import XCTest
import StoreKit
import StoreKitTest
@testable import Stride

/// `StoreService.proStatus` through StoreKit itself (RELEASE-1.4.1.md D12, D14), hosted, on an
/// `SKTestSession` over the bundled Configuration.storekit (StoreKitConfigurationLoadTests).
/// **Owner: W5.** Scaffolded by W0: no tests yet.
///
/// TODO(W5): buy; expire → lapsed; lifetime; unverified; billing retry; grace period;
/// `refundTransaction`; Lifetime bought during an active subscription.
@MainActor
final class StoreKitStatusTests: XCTestCase {}
