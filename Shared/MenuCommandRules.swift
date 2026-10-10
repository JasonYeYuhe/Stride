import Foundation

/// When the Mac's menu commands are enabled, and what Weekly Review opens (RELEASE-1.4.0.md D3).
/// Pure, so the rules are pinned host-less; the `Commands` in Stride/Sources only read them.
///
/// Each rule is the one the same action already follows on screen, so a menu item can never offer
/// what the window would refuse, nor refuse what the window in front offers: Sync Now is
/// Settings' Sync Now row, Weekly Review is Stats' toolbar button.
enum MenuCommandRules {
    /// The menu items, by what they do.
    enum Command: CaseIterable, Sendable {
        /// File → New Habit ⌘N.
        case newHabit
        /// File → Sync Now ⌘R.
        case syncNow
        /// File → Export Backup… ⇧⌘E (JSON).
        case exportBackup
        /// File → Export as CSV….
        case exportCSV
        /// View → Today ⌘1.
        case today
        /// View → Statistics ⌘2.
        case statistics
        /// View → Weekly Review ⇧⌘R.
        case weeklyReview
        /// Window → Stride ⌘0: brings the main window back, or opens it.
        case showMainWindow
    }

    /// What the rules read, as the menu sees it at the moment it is drawn.
    struct State: Equatable, Sendable {
        /// A main window is focused and published its commands (`@FocusedValue` non-nil). With
        /// Settings or no window in front, nothing acts on a window that is not there. Sync Now
        /// does not read it: it acts on no window (see `isEnabled`).
        var hasFocusedMainWindow: Bool
        /// Settings' `SettingsAccountState.showsAccountActions`: an account is loaded, the reauth
        /// state included.
        var showsAccountActions: Bool
        var isSyncing: Bool
        /// Unarchived habits.
        var habitCount: Int
    }

    static func isEnabled(_ command: Command, in state: State) -> Bool {
        switch command {
        case .showMainWindow:
            // Always: it is the way back to a closed main window. With Settings open and the main
            // window closed, a Dock click opens nothing (AppKit reopens only when no window is
            // visible), and File → New Window is gone with ⌘N (design review,
            // "mac-main-window-unrecoverable").
            return true
        case .newHabit, .exportBackup, .exportCSV, .today, .statistics:
            return state.hasFocusedMainWindow
        case .syncNow:
            // Not window-scoped. It is exactly Settings' Sync Now row (D3), and that row lives in
            // the Settings window: the first cut also required a focused main window, so with
            // Settings key — the moment someone is looking at the row — File → Sync Now ⌘R was
            // grey beside an enabled row in the window in front (W1 code review). A sync needs no
            // window: `SyncService.shared` on `SharedModelContainer.opened`'s main context, as
            // the launch and activation syncs run. An owner conflict it returns goes to
            // `AccountChoiceRouter`, whose sheet hangs off the main window.
            return syncNowEnabled(showsAccountActions: state.showsAccountActions, isSyncing: state.isSyncing)
        case .weeklyReview:
            return state.hasFocusedMainWindow && weeklyReviewEnabled(habitCount: state.habitCount)
        }
    }

    /// Settings' Sync Now row: shown with an account loaded, disabled while a sync runs.
    static func syncNowEnabled(showsAccountActions: Bool, isSyncing: Bool) -> Bool {
        showsAccountActions && !isSyncing
    }

    /// Stats' toolbar button exists only with habits: with none, the review has nothing to show,
    /// and for a free user it opened the paywall to sell a feature that would then be empty.
    static func weeklyReviewEnabled(habitCount: Int) -> Bool {
        habitCount > 0
    }

    /// What Weekly Review opens.
    enum WeeklyReviewDestination: Equatable, Sendable {
        case review
        case paywall
    }

    /// Pro opens the review; anyone else gets the paywall, as Stats' button does.
    static func weeklyReviewDestination(isPro: Bool) -> WeeklyReviewDestination {
        isPro ? .review : .paywall
    }
}
