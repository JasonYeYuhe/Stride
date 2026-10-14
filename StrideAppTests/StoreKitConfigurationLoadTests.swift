import XCTest
import StoreKit
import StoreKitTest
@testable import Stride

/// The StoreKit configuration loads into an `SKTestSession` inside the hosted tests
/// (RELEASE-1.4.1.md D14, W0) — the precondition for W5's SKTestSession cases (buy, expire →
/// lapsed, lifetime, unverified, billing retry, grace period, refund, Lifetime during an active
/// subscription), which replace the Transaction Manager GUI step of DEV-PLAN-1.3.md M4
/// acceptance (4).
///
/// The file is a resource of this test bundle (project.yml, StrideAppTests `sources`), so it is
/// found with `Bundle(for:)` wherever the bundle runs: this Mac, CI's simulator, or a
/// test-without-building elsewhere. The schemes' `storeKitConfiguration` applies to their run
/// actions only and never reaches a test.
///
/// StoreServiceTests reads the same file as JSON and checks its ids against `StrideProduct`;
/// this asks StoreKit itself, through the session, for every product the app requests.
final class StoreKitConfigurationLoadTests: XCTestCase {
    func testTheConfigurationLoadsIntoATestSessionWithEveryProductTheAppSells() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "Configuration", withExtension: "storekit"),
            "Configuration.storekit is not in the StrideAppTests bundle (project.yml: StrideAppTests sources)")
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()

        let ids = Set(StrideProduct.allCases.map(\.rawValue))
        let products = try await Product.products(for: ids)
        XCTAssertEqual(Set(products.map(\.id)), ids, "every id StoreService asks for is in the session")

        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byID[StrideProduct.lifetimePro.rawValue]?.type, .nonConsumable)
        XCTAssertEqual(byID[StrideProduct.monthlyPro.rawValue]?.type, .autoRenewable)
        XCTAssertEqual(byID[StrideProduct.yearlyPro.rawValue]?.type, .autoRenewable)
        // D12 reads the group id from the product, not from the configuration's local name.
        let groups = Set([StrideProduct.monthlyPro, .yearlyPro].compactMap {
            byID[$0.rawValue]?.subscription?.subscriptionGroupID
        })
        XCTAssertEqual(groups.count, 1, "Monthly and Yearly share one subscription group")
    }
}
