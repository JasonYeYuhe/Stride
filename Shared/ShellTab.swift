import Foundation

/// The shell's three places (RELEASE-1.4.0.md D2). The raw values are the `-tab N` launch
/// argument's numbers, which scripts/a11y_sweep.sh and the E2E kit pass: they must not change.
///
/// Pure, in Shared, so the parsing and the per-platform rows are pinned host-less. Titles and
/// icons stay with the views in Stride/Sources, where the localization scan sees them.
enum ShellTab: Int, CaseIterable, Hashable, Identifiable, Sendable {
    case today = 0
    case stats = 1
    case settings = 2

    var id: Int { rawValue }

    /// The tab a launch asks for with `-tab N`. Missing, a missing value, not a whole number, or a
    /// number with no tab → Today: the old shell stored the raw Int and its `switch` fell through to
    /// Today for anything unknown, while the iPad sidebar highlighted nothing — a launch argument
    /// must never be able to leave the shell with no selection.
    static func fromLaunchArguments(_ arguments: [String] = CommandLine.arguments) -> ShellTab {
        guard let flag = arguments.firstIndex(of: "-tab"), flag + 1 < arguments.count,
              let number = Int(arguments[flag + 1]), let tab = ShellTab(rawValue: number)
        else { return .today }
        return tab
    }

    /// The sidebar's rows, top to bottom. The Mac has no Settings row: Settings is its own window
    /// (Stride → Settings…, ⌘,), and a second SettingsView in the sidebar kept a second copy of
    /// the reminder toggle's state (the M3 code map). iPad keeps the row; compact iPhone has
    /// its tab bar.
    static func sidebarRows(on platform: ShellPlatform = .current) -> [ShellTab] {
        switch platform {
        case .iOS: return [.today, .stats, .settings]
        case .macOS: return [.today, .stats]
        }
    }

    /// What a launch with `-tab N` shows on `platform`: the tab itself when the platform has a row
    /// for it; otherwise Today, with the Settings window opened (`-tab 2` on the Mac).
    static func launchSelection(_ arguments: [String] = CommandLine.arguments,
                                on platform: ShellPlatform = .current) -> (selection: ShellTab, opensSettingsWindow: Bool) {
        let tab = fromLaunchArguments(arguments)
        if sidebarRows(on: platform).contains(tab) { return (tab, false) }
        return (.today, tab == .settings)
    }
}

/// Which shell the build draws, as a value the tests can pass either way. Not `#if os` at each
/// call site, so both platforms' rules run in one test run.
enum ShellPlatform: Equatable, Sendable {
    case iOS
    case macOS

    static var current: ShellPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}
