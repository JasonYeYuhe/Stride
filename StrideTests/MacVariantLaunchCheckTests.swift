import XCTest
import Foundation

/// The Mac test variant's launch conditions (`MacVariantLaunchCheck`, Shared/SharedModelContainer.swift;
/// RELEASE-1.4.0.md D7). Only the variant build (`STRIDE_MAC_VARIANT`) traps on them; the conditions
/// themselves are always compiled, so they are pinned here with values, never this process's own.
final class MacVariantLaunchCheckTests: XCTestCase {

    private let home = "/Users/someone/Library/Containers/yyh.stride.habittracker.mactest/Data"
    private var variantStore: URL { URL(fileURLWithPath: home + "/Documents/Stride.store") }

    private func violations(sandbox: String? = "yyh.stride.habittracker.mactest", store: URL? = nil,
                            home: String? = nil, bundle: String? = "yyh.stride.habittracker.mactest") -> [String] {
        MacVariantLaunchCheck.violations(sandboxContainerID: sandbox, storeURL: store ?? variantStore,
                                         homeDirectory: home ?? self.home, bundleIdentifier: bundle)
    }

    /// Sandboxed, its store under its own container, its own bundle id: it may launch.
    func testTheVariantAsBuiltPasses() {
        XCTAssertEqual(violations(), [])
        XCTAssertEqual(violations(home: home + "/"), [], "a home with a trailing slash")
    }

    /// Not sandboxed: nothing keeps the process out of the real App Group container or Keychain.
    func testAnUnsandboxedProcessIsRefused() {
        XCTAssertEqual(violations(sandbox: nil).count, 1)
        XCTAssertEqual(violations(sandbox: "").count, 1)
    }

    /// The real store — the App Group's, or anywhere outside the variant's container — is refused,
    /// and so is a sibling directory that merely starts with the same characters.
    func testAStoreOutsideItsOwnHomeIsRefused() {
        let real = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/group.yyh.stride.habittracker/Stride.store")
        XCTAssertEqual(violations(store: real).count, 1)
        XCTAssertEqual(violations(store: URL(fileURLWithPath: home + "2/Documents/Stride.store")).count, 1)
        XCTAssertEqual(violations(store: URL(fileURLWithPath: "/Users/someone/Documents/Stride.store"),
                                  home: "/Users/someone/Library/Containers/x/Data").count, 1)
    }

    /// The real app's bundle id (a flag build without the id override) would share the real
    /// Keychain item; a missing one cannot be told apart from it.
    func testTheRealBundleIDIsRefused() {
        XCTAssertEqual(MacVariantLaunchCheck.realBundleIdentifier, "yyh.stride.habittracker")
        XCTAssertEqual(violations(bundle: "yyh.stride.habittracker").count, 1)
        XCTAssertEqual(violations(bundle: nil).count, 1)
    }

    /// Everything wrong at once is reported at once, in the trap's one message.
    func testEveryViolationIsReported() {
        let real = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/group.yyh.stride.habittracker/Stride.store")
        XCTAssertEqual(violations(sandbox: nil, store: real, bundle: "yyh.stride.habittracker").count, 3)
    }
}
