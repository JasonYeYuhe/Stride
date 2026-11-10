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
        let config = try storeKitConfiguration()

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

    /// SKTestSession reads the configuration's `version` as the `{major, minor}` object Xcode
    /// writes. With the hand-written `"version" : 2` the file had until 1.4.1, a session on
    /// iOS 18.5 loaded nothing — no error, no products — so every StoreKitStatusTests case skipped
    /// on every runtime and none had ever run (W5-SK-1; a `{major 2}` or `{major 4}` object loads).
    /// This needs no StoreKit, so it holds on the iOS 26.3+ runtimes where SKTestSession cannot
    /// load any file at all.
    func testTheStoreKitConfigurationHasTheVersionObjectSKTestSessionReads() throws {
        let config = try storeKitConfiguration()
        let version = try XCTUnwrap(config["version"] as? [String: Any],
                                    "\"version\" must be {\"major\", \"minor\"}, not \(config["version"] ?? "missing")")
        XCTAssertNotNil(version["major"] as? Int, "version.major")
        XCTAssertNotNil(version["minor"] as? Int, "version.minor")
    }

    /// The hosted test runs in the simulator, which reads the Mac's filesystem, so the
    /// configuration is read from the repo rather than copied into a bundle.
    private func storeKitConfiguration() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Stride/Configuration.storekit")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
