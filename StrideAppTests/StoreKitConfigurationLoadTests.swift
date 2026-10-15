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
/// StoreServiceTests reads the same file as JSON and checks its ids against `StrideProduct` and
/// its format; this asks StoreKit itself, through the session, for every product the app
/// requests.
///
/// It must hear the session, not the App Store: until W5-SK-1 it passed on the iOS 26.5 runtime,
/// where SKTestSession cannot load any configuration (StoreKitStatusTests' class doc) and the
/// sandbox App Store answered with the real products, while on iOS 18.5 the same file loaded
/// nothing. So the subscription group must be the configuration's own "stride_pro"; an answer from
/// the App Store (its group id is a number) is a skip, saying why, and no products at all is a
/// failure — the session read nothing from the file.
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
        let answeredGroups = Set(products.compactMap { $0.subscription?.subscriptionGroupID })
        if !answeredGroups.isEmpty, !answeredGroups.contains(Self.configurationGroupID) {
            throw XCTSkip("""
                The App Store answered (subscription group \(answeredGroups.sorted())), not the \
                session: SKTestSession cannot load a configuration on this runtime (iOS 26.3+ \
                simulators, FB22774836), so this cannot show that the file loads.
                """)
        }
        XCTAssertEqual(Set(products.map(\.id)), ids,
                       "every id StoreService asks for is in the session (none: the session read nothing from the file)")

        let byID = Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byID[StrideProduct.lifetimePro.rawValue]?.type, .nonConsumable)
        XCTAssertEqual(byID[StrideProduct.monthlyPro.rawValue]?.type, .autoRenewable)
        XCTAssertEqual(byID[StrideProduct.yearlyPro.rawValue]?.type, .autoRenewable)
        // D12 reads the group id from the product, not from the configuration's local name.
        let groups = Set([StrideProduct.monthlyPro, .yearlyPro].compactMap {
            byID[$0.rawValue]?.subscription?.subscriptionGroupID
        })
        XCTAssertEqual(groups, [Self.configurationGroupID], "Monthly and Yearly share the configuration's subscription group")
    }

    /// Configuration.storekit's subscription group id; the App Store's is a number.
    private static let configurationGroupID = "stride_pro"
}
