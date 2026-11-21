import XCTest
@testable import Stride

/// Why the paywall opens (RELEASE-1.4.2.md D4, W0). Settings has two rows that open it, on one
/// sheet keyed by the trigger: Upgrade to Pro passes `.settings`, the "Pro ended on <date>" row
/// with Resubscribe passes `.lapsed`. Before 1.4.2 both set one `showingPaywall`, so W3's subtitle
/// ("Welcome back" for a lapsed user) had nothing to read.
///
/// The rows' buttons set `paywallTrigger = SettingsView.paywallTrigger(for: row)`, so this pins
/// what each button opens without driving StoreKit into a lapsed status. Also here: the two shell
/// requests W0 adds, and the DEBUG switches' parser (D14).
@MainActor
final class PaywallTriggerTests: XCTestCase {

    func testUpgradeOpensSettingsAndTheLapsedRowLapsed() {
        XCTAssertEqual(SettingsView.paywallTrigger(for: .upgrade), .settings)
        XCTAssertEqual(SettingsView.paywallTrigger(for: .lapsed(endedOn: Date(timeIntervalSince1970: 1_790_000_000))), .lapsed)
        let yearly = StrideProduct.yearlyPro.rawValue
        let others: [ProSettingsRow] = [
            .restore, .unlocked, .plan(.lifetime, nil),
            .plan(.subscription(productID: yearly), .renews(Date())), .billingIssue, .stillRenews, .manage,
        ]
        for row in others {
            XCTAssertNil(SettingsView.paywallTrigger(for: row), "\(row) does not open the paywall")
        }
    }

    /// Whatever Settings shows, the rows that open the paywall are exactly Upgrade and the lapsed
    /// row, and they open it with different triggers.
    func testEveryStatusOpensThePaywallOnlyFromUpgradeOrTheLapsedRow() {
        let ended = Date(timeIntervalSince1970: 1_790_000_000)
        let yearly = StrideProduct.yearlyPro.rawValue
        let statuses: [ProStatus] = [
            .never, .lapsed(expiredOn: ended), .lifetime(subscriptionStillRenews: false),
            .lifetime(subscriptionStillRenews: true), .active(productID: yearly, renewsOn: ended, willAutoRenew: true),
            .active(productID: yearly, renewsOn: nil, willAutoRenew: nil), .billingIssue(productID: yearly, graceUntil: ended),
        ]
        for status in statuses {
            for isPro in [false, true] {
                for row in ProSettingsRow.rows(for: status, isPro: isPro) {
                    let trigger = SettingsView.paywallTrigger(for: row)
                    switch row {
                    case .upgrade: XCTAssertEqual(trigger, .settings, "\(status), isPro \(isPro)")
                    case .lapsed: XCTAssertEqual(trigger, .lapsed, "\(status), isPro \(isPro)")
                    default: XCTAssertNil(trigger, "\(row) in \(status), isPro \(isPro)")
                    }
                }
            }
        }
    }

    /// D8's two requests are sheets the shell presents, and the week is part of the request.
    func testTheReviewAndPaywallRequestsAreShellSheets() {
        let monday = Date(timeIntervalSince1970: 1_793_059_200)
        XCTAssertTrue(ShellRequest.weeklyReview(week: nil).isSheet)
        XCTAssertTrue(ShellRequest.weeklyReview(week: monday).isSheet)
        XCTAssertNotEqual(ShellRequest.weeklyReview(week: nil), .weeklyReview(week: monday))
        let paywall = ShellRequest.paywall(trigger: .today, resume: .weeklyReview(week: monday))
        XCTAssertTrue(paywall.isSheet)
        XCTAssertEqual(paywall.id, .paywall(trigger: .today, resume: .weeklyReview(week: monday)))
        XCTAssertNotEqual(paywall, .paywall(trigger: .weeklyReview, resume: .weeklyReview(week: monday)))
        XCTAssertTrue(ShellRequest.paywall(trigger: .analytics, resume: nil).isSheet)
    }

    #if DEBUG
    /// D14's switches: parsed, and a missing or unknown value leaves its switch off.
    func testTheDebugLaunchFlagsParse() {
        XCTAssertEqual(StrideDebugLaunchFlags.parse(["Stride"]), StrideDebugLaunchFlags())
        let all = StrideDebugLaunchFlags.parse(["Stride", "-demo", "-demoPro", "-paywallFixture", "pending",
                                                "-paywallScrollTo", "terms", "-inlineCard", "none"])
        XCTAssertTrue(all.demoPro)
        XCTAssertEqual(all.paywallFixture, "pending")
        XCTAssertEqual(all.paywallScrollTo, .terms)
        XCTAssertEqual(all.inlineCard, .off)
        XCTAssertEqual(StrideDebugLaunchFlags.parse(["-inlineCard", "week"]).inlineCard, .week)
        let unknown = StrideDebugLaunchFlags.parse(["-paywallScrollTo", "nowhere", "-inlineCard", "always", "-paywallFixture"])
        XCTAssertNil(unknown.paywallScrollTo)
        XCTAssertNil(unknown.inlineCard)
        XCTAssertNil(unknown.paywallFixture, "a switch with no value")
        XCTAssertFalse(unknown.demoPro)
        // The binary probe must be longer than the 15 bytes Swift keeps inside instructions.
        XCTAssertEqual(StrideDebugLaunchFlags.sentinel.utf8.count, 24)
    }
    #endif
}
