import XCTest
import Foundation

/// The shell's tabs, the `-tab N` launch argument and the per-platform sidebar
/// (`ShellTab`, Shared/ShellTab.swift; RELEASE-1.4.0.md D2), and the Mac's menu rules
/// (`MenuCommandRules`, Shared/MenuCommandRules.swift; D3).
final class ShellTabTests: XCTestCase {

    // MARK: - ShellTab

    /// The raw values are what scripts/a11y_sweep.sh and the E2E kit pass as `-tab N`.
    func testRawValuesArePinned() {
        XCTAssertEqual(ShellTab.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(ShellTab.today.rawValue, 0)
        XCTAssertEqual(ShellTab.stats.rawValue, 1)
        XCTAssertEqual(ShellTab.settings.rawValue, 2)
    }

    func testTabArgumentsParse() {
        XCTAssertEqual(ShellTab.fromLaunchArguments(["Stride", "-tab", "0"]), .today)
        XCTAssertEqual(ShellTab.fromLaunchArguments(["Stride", "-tab", "1"]), .stats)
        XCTAssertEqual(ShellTab.fromLaunchArguments(["Stride", "-tab", "2"]), .settings)
        XCTAssertEqual(ShellTab.fromLaunchArguments(["Stride", "-demo", "-tab", "1", "-paywall"]), .stats)
        XCTAssertEqual(ShellTab.fromLaunchArguments(["Stride", "-tab", "1", "-tab", "2"]), .stats, "the first one")
    }

    /// Missing, a flag with no value, garbage and numbers with no tab are all Today. The old
    /// shell kept the raw Int: its `switch` fell back to Today while the iPad sidebar highlighted
    /// nothing.
    func testMissingGarbageAndOutOfRangeAreToday() {
        let today: [[String]] = [
            [], ["Stride"], ["Stride", "-tab"], ["Stride", "-tab", ""], ["Stride", "-tab", "stats"],
            ["Stride", "-tab", "1.0"], ["Stride", "-tab", " 1"], ["Stride", "-tab", "3"], ["Stride", "-tab", "-1"],
            ["Stride", "-tab", "99999999999999999999"], ["Stride", "tab", "1"], ["Stride", "-Tab", "1"],
            ["Stride", "-tab", "-demo"],
        ]
        for arguments in today {
            XCTAssertEqual(ShellTab.fromLaunchArguments(arguments), .today, "\(arguments)")
        }
    }

    /// The Mac sidebar has no Settings row — Settings is its own window — and iOS keeps it.
    func testSidebarRowsPerPlatform() {
        XCTAssertEqual(ShellTab.sidebarRows(on: .iOS), [.today, .stats, .settings])
        XCTAssertEqual(ShellTab.sidebarRows(on: .macOS), [.today, .stats])
        #if os(macOS)
        XCTAssertEqual(ShellPlatform.current, .macOS)
        XCTAssertEqual(ShellTab.sidebarRows(), [.today, .stats])
        #else
        XCTAssertEqual(ShellPlatform.current, .iOS)
        XCTAssertEqual(ShellTab.sidebarRows(), [.today, .stats, .settings])
        #endif
    }

    /// `-tab 2` on the Mac selects Today and opens the Settings window; on iOS it is the tab.
    func testLaunchSelectionPerPlatform() {
        let settings = ["Stride", "-tab", "2"]
        XCTAssertTrue(ShellTab.launchSelection(settings, on: .macOS) == (.today, true))
        XCTAssertTrue(ShellTab.launchSelection(settings, on: .iOS) == (.settings, false))
        for platform in [ShellPlatform.iOS, .macOS] {
            XCTAssertTrue(ShellTab.launchSelection(["Stride", "-tab", "1"], on: platform) == (.stats, false))
            XCTAssertTrue(ShellTab.launchSelection(["Stride"], on: platform) == (.today, false))
            XCTAssertTrue(ShellTab.launchSelection(["Stride", "-tab", "7"], on: platform) == (.today, false))
        }
    }

    // MARK: - MenuCommandRules (D3)

    private func state(window: Bool = true, account: Bool = true, syncing: Bool = false,
                       habits: Int = 3) -> MenuCommandRules.State {
        MenuCommandRules.State(hasFocusedMainWindow: window, showsAccountActions: account,
                               isSyncing: syncing, habitCount: habits)
    }

    /// Settings' Sync Now row exactly: an account loaded, and no sync running.
    func testSyncNowRule() {
        XCTAssertTrue(MenuCommandRules.syncNowEnabled(showsAccountActions: true, isSyncing: false))
        XCTAssertFalse(MenuCommandRules.syncNowEnabled(showsAccountActions: true, isSyncing: true))
        XCTAssertFalse(MenuCommandRules.syncNowEnabled(showsAccountActions: false, isSyncing: false))
        XCTAssertFalse(MenuCommandRules.syncNowEnabled(showsAccountActions: false, isSyncing: true))
        XCTAssertTrue(MenuCommandRules.isEnabled(.syncNow, in: state()))
        XCTAssertFalse(MenuCommandRules.isEnabled(.syncNow, in: state(syncing: true)))
        XCTAssertFalse(MenuCommandRules.isEnabled(.syncNow, in: state(account: false)))
    }

    /// Stats' toolbar button: none with no habits. Pro opens the review, anyone else the paywall.
    func testWeeklyReviewRules() {
        XCTAssertFalse(MenuCommandRules.weeklyReviewEnabled(habitCount: 0))
        XCTAssertTrue(MenuCommandRules.weeklyReviewEnabled(habitCount: 1))
        XCTAssertFalse(MenuCommandRules.isEnabled(.weeklyReview, in: state(habits: 0)))
        XCTAssertTrue(MenuCommandRules.isEnabled(.weeklyReview, in: state(habits: 1)))
        XCTAssertEqual(MenuCommandRules.weeklyReviewDestination(isPro: true), .review)
        XCTAssertEqual(MenuCommandRules.weeklyReviewDestination(isPro: false), .paywall)
    }

    /// With no main window focused (Settings in front, or no window), only Window → Stride — the
    /// way back — and Sync Now, which acts on no window, are enabled. With one, every command
    /// follows its own rule.
    func testWindowScopedCommandsNeedAFocusedMainWindow() {
        for command in MenuCommandRules.Command.allCases {
            XCTAssertEqual(MenuCommandRules.isEnabled(command, in: state(window: false)),
                           command == .showMainWindow || command == .syncNow, "\(command)")
            XCTAssertTrue(MenuCommandRules.isEnabled(command, in: state()), "\(command)")
        }
        let empty = state(account: false, syncing: true, habits: 0)
        XCTAssertEqual(MenuCommandRules.Command.allCases.filter { MenuCommandRules.isEnabled($0, in: empty) },
                       [.newHabit, .exportBackup, .exportCSV, .today, .statistics, .showMainWindow])
    }

    /// Settings key, the main window behind it or closed: the menu's Sync Now is the Settings
    /// window's row, enabled and disabled with it. The first cut greyed ⌘R out here, beside an
    /// enabled row in the window in front (W1 code review).
    func testSyncNowFollowsSettingsRowWithSettingsKey() {
        for account in [true, false] {
            for syncing in [true, false] {
                XCTAssertEqual(MenuCommandRules.isEnabled(.syncNow, in: state(window: false, account: account, syncing: syncing)),
                               MenuCommandRules.syncNowEnabled(showsAccountActions: account, isSyncing: syncing),
                               "account \(account), syncing \(syncing)")
                XCTAssertEqual(MenuCommandRules.isEnabled(.syncNow, in: state(window: false, account: account, syncing: syncing)),
                               MenuCommandRules.isEnabled(.syncNow, in: state(window: true, account: account, syncing: syncing)),
                               "the main window's focus never changes it")
            }
        }
        XCTAssertTrue(MenuCommandRules.isEnabled(.syncNow, in: state(window: false)))
        XCTAssertFalse(MenuCommandRules.isEnabled(.syncNow, in: state(window: false, syncing: true)))
        XCTAssertFalse(MenuCommandRules.isEnabled(.syncNow, in: state(window: false, account: false)))
    }
}
