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
    /// Each marker (`lifetime`, `yearly`) still names exactly one id. The paywall labelled
    /// products by these substrings until 1.4.2; it now reads the kind from `StrideProduct`.
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

    /// RELEASE-1.4.2.md D16: the local file prices Lifetime at 39.99 (it tied Yearly at 19.99
    /// until 1.4.2, which is why the paywall orders by kind, never price), describes Yearly
    /// without a savings figure the paywall computes itself, and gives Yearly the one intro offer
    /// Stride makes: a 7-day free trial (P1W). Monthly has none, and no other offer kind exists.
    /// The SKTestSession cases (StoreKitStatusTests) buy this trial.
    func testTheConfigurationHasD16sPricesAndYearlysFreeTrial() throws {
        let config = try storeKitConfiguration()
        let products = config["products"] as? [[String: Any]] ?? []
        let lifetime = try XCTUnwrap(products.first { $0["productID"] as? String == StrideProduct.lifetimePro.rawValue })
        XCTAssertEqual(lifetime["displayPrice"] as? String, "39.99")

        let groups = config["subscriptionGroups"] as? [[String: Any]] ?? []
        let subscriptions = groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
        func subscription(_ product: StrideProduct) throws -> [String: Any] {
            try XCTUnwrap(subscriptions.first { $0["productID"] as? String == product.rawValue }, product.rawValue)
        }
        let monthly = try subscription(.monthlyPro)
        let yearly = try subscription(.yearlyPro)
        XCTAssertEqual(monthly["displayPrice"] as? String, "2.99")
        XCTAssertEqual(yearly["displayPrice"] as? String, "19.99")

        let offer = try XCTUnwrap(yearly["introductoryOffer"] as? [String: Any], "Yearly's intro offer")
        XCTAssertEqual(offer["paymentMode"] as? String, "free")
        XCTAssertEqual(offer["subscriptionPeriod"] as? String, "P1W")
        XCTAssertTrue(monthly["introductoryOffer"] is NSNull || monthly["introductoryOffer"] == nil, "Monthly has no intro offer")
        for sub in [monthly, yearly] {
            XCTAssertEqual((sub["adHocOffers"] as? [Any])?.count ?? 0, 0, "no promotional offers (D16)")
            XCTAssertEqual((sub["codeOffers"] as? [Any])?.count ?? 0, 0, "no offer codes (D16)")
        }

        let descriptions = (yearly["localizations"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        XCTAssertEqual(descriptions, ["Full access billed yearly"])
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
