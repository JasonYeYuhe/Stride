import XCTest
@testable import Stride

/// What of StoreService can be tested without driving StoreKit: the product catalogue.
///
/// Purchase outcomes are not reachable yet — `purchase(_:)` takes a StoreKit `Product` and
/// switches on `Product.PurchaseResult` inline, and neither can be constructed in a test
/// without an SKTestSession. M4's `PurchaseOutcome` extraction (a pure mapping from the result
/// to granted / cancelled / pending / failed-verification) is what makes the 1.2.x "unverified
/// purchase shown as a quiet cancel" bug testable here.
final class StoreServiceTests: XCTestCase {

    /// The ids the app asks the App Store for must be exactly the ones in the StoreKit
    /// configuration used for local testing (and, through scripts/setup_iap.py, in App Store
    /// Connect). A one-character mismatch loads no product for that plan — the paywall shows
    /// two cards, or none — and nothing else fails.
    ///
    /// The paywall also labels products by substring (`contains("lifetime")`,
    /// `contains("yearly")`), so each marker must match exactly one id.
    func testProductIdsMatchTheStoreKitConfigurationAndThePaywallLabels() throws {
        // The hosted test runs in the simulator, which reads the Mac's filesystem, so the
        // configuration is read from the repo rather than copied into a bundle.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Stride/Configuration.storekit")
        let config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

        var configured = Set<String>()
        for product in config["products"] as? [[String: Any]] ?? [] {
            if let id = product["productID"] as? String { configured.insert(id) }
        }
        for group in config["subscriptionGroups"] as? [[String: Any]] ?? [] {
            for sub in group["subscriptions"] as? [[String: Any]] ?? [] {
                if let id = sub["productID"] as? String { configured.insert(id) }
            }
        }

        let ids = StrideProduct.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids), configured)
        XCTAssertEqual(ids.filter { $0.contains("lifetime") }, [StrideProduct.lifetimePro.rawValue])
        XCTAssertEqual(ids.filter { $0.contains("yearly") }, [StrideProduct.yearlyPro.rawValue])
    }
}
