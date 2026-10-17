import SwiftUI
import Observation

/// One window's shell (RELEASE-1.4.0.md D2): which place is showing, Today's day, the Stats habit,
/// and the one thing the window was asked to present.
///
/// `@State` in ContentView, so each scene has its own and two iPad windows do not mirror each
/// other — never a singleton. It sits ABOVE the size-class branch: a compact↔regular crossing
/// (a Pro Max rotated, iPad Split View or Stage Manager resizing) builds the other layout from
/// scratch, and in 1.3.x that crossing — like every sidebar switch at regular width and on the
/// Mac, where the detail was a `switch` that rebuilt the view — reset Today to today and Stats to
/// its first habit. A sheet a tab presented is still dismissed by the crossing, as in 1.3.x; one
/// the shell presents (`request`) is not.
@MainActor
@Observable
final class ShellState {
    /// Never optional: a shell with no place selected draws a blank detail with no title and no
    /// toolbar (design review, "d2-mac-sidebar-deselect"). The sidebars and the compact TabView
    /// bind to it directly; the iOS List's optional selection drops a nil (`SidebarView`).
    var selection: ShellTab {
        didSet {
            // Nothing in 1.4.0 assigns a place the platform has no row for, but the Mac's
            // keep-alive stack has no Settings slot (Settings is its own window there): landing on
            // one would leave no tab active, so it is Today instead, as `-tab 2` is.
            if !ShellTab.sidebarRows(on: platform).contains(selection) { selection = .today }
            visited.insert(selection)
        }
    }

    /// The places created so far. At regular width and on the Mac a tab is created on its first
    /// visit and then kept, hidden while another one shows (ContentView's keep-alive stack), so
    /// Stats' queries and Settings' refreshes cost nothing until someone opens them. Only grows.
    private(set) var visited: Set<ShellTab>

    /// Whether `tab`'s view exists: visited, or selected this moment.
    func isCreated(_ tab: ShellTab) -> Bool {
        tab == selection || visited.contains(tab)
    }

    /// The day Today shows and checks in to. Was TodayView's `@State selectedDate`.
    var todayDate: Date
    /// The day it was "today" when `todayDate` was last re-anchored (`TodaySelection`). Was
    /// TodayView's `@State selectionAnchor`.
    var todayAnchor: Date

    /// The habit Stats shows; nil until one is picked (Stats then shows the first). An id, not a
    /// Habit: holding the @Model object kept it alive outside the @Query result set, and nothing
    /// cleared it when that habit was deleted — in Settings, or with no user action at all by a
    /// sync tombstone from another device. The next render then read properties of an invalidated
    /// model. StatsView resolves the id against its live query, which can't do that.
    var statsHabitID: UUID?

    /// What this window was asked to present (the Mac's menu commands, W6). An item, cleared when
    /// its presentation is dismissed — never a Bool that can stick at true and swallow the next
    /// ask (D2). ContentView presents it above the size-class branch.
    var request: ShellRequest?

    /// `-tab 2` on the Mac: Settings is a window there, not a place in this one, so the launch
    /// selects Today and ContentView opens the Settings window (`ShellTab.launchSelection`).
    let opensSettingsAtLaunch: Bool

    private let platform: ShellPlatform

    #if DEBUG
    /// How many times SwiftUI created each tab's root view for this shell (`ShellTabLifetime`). A
    /// hosted test reads it: keep-alive means one creation per tab however often the selection
    /// moves. Not observed — it is written while SwiftUI builds the view.
    @ObservationIgnored var tabCreations: [ShellTab: Int] = [:]
    #endif

    /// - Parameters:
    ///   - launchArguments: read for `-tab N` (scripts/a11y_sweep.sh and the E2E kit pass it).
    ///   - platform: whose rows apply — the Mac has no Settings place.
    ///   - now: Today's first day, and its anchor.
    init(launchArguments: [String] = CommandLine.arguments, platform: ShellPlatform = .current,
         now: Date = Date()) {
        let launch = ShellTab.launchSelection(launchArguments, on: platform)
        self.platform = platform
        self.selection = launch.selection
        self.visited = [launch.selection]
        self.opensSettingsAtLaunch = launch.opensSettingsWindow
        self.todayDate = now
        self.todayAnchor = now
    }

    /// Moves Today to the new day once the calendar day has changed under it, by the
    /// `TodaySelection` rule: today stays today, a day picked in the week strip stays picked
    /// while the strip still shows it.
    ///
    /// ContentView calls it above the size-class branch — the scene becoming active, the
    /// calendar day changing, Today becoming the selected place — and never only while Today is
    /// showing. The 1.3.x `switch` shell re-anchored implicitly by recreating TodayView on every
    /// visit; a kept-alive Today is not recreated, and a Today that was never created, or that a
    /// size-class crossing tore down, has no hooks of its own to run. Without this it would open
    /// on yesterday at the next visit and credit check-ins to it — the bug TodaySelection exists
    /// for.
    ///
    /// Within the same day it writes nothing, so the scene's every activation does not redraw
    /// every view that reads the date (Observation reports every assignment, equal or not).
    func reanchor(now: Date, calendar: Calendar = .current) {
        guard !calendar.isDate(now, inSameDayAs: todayAnchor) else { return }
        todayDate = TodaySelection.reanchored(selected: todayDate, shownOn: todayAnchor, now: now, calendar: calendar)
        todayAnchor = now
    }

    /// Today's title: "Today", "Yesterday" or the date. Judged against the anchor, not the clock:
    /// the anchor is what re-anchoring moves, so the title is redrawn exactly when the day it
    /// names changes (the clock moving past midnight redraws nothing by itself), and it can never
    /// say "Yesterday" over a date the screen still treats as today.
    ///
    /// The ContentView title of every layout; 1.3.x's TodayView set it from its own state. In the
    /// picked language (`appLocalized`, `appLocale`): a Japanese-picked app on an English device
    /// drew an English title over a Japanese screen.
    var todayTitle: String {
        let calendar = Calendar.current
        if calendar.isDate(todayDate, inSameDayAs: todayAnchor) {
            return appLocalized("Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayAnchor),
           calendar.isDate(todayDate, inSameDayAs: yesterday) {
            return appLocalized("Yesterday")
        }
        let formatter = DateFormatter()
        formatter.locale = appLocale
        formatter.dateStyle = .medium
        return formatter.string(from: todayDate)
    }
}

/// What a window can be asked to present (RELEASE-1.4.0.md D2, D3). Identifiable so the shell
/// presents it with `.sheet(item:)`, which clears it on dismiss.
enum ShellRequest: Hashable, Identifiable {
    /// File → New Habit ⌘N.
    case newHabit
    /// View → Weekly Review ⇧⌘R: the review for Pro, the paywall otherwise
    /// (`MenuCommandRules.weeklyReviewDestination`), whether or not Stats was ever opened.
    case weeklyReview
    /// File → Export Backup… / Export as CSV…: written first, then a save panel (D3, D6).
    case export(Export)

    enum Export: Hashable {
        case json
        case csv

        /// Settings' rows write the same files: the backup naming the store's owner, the CSV.
        var file: ExportFile {
            switch self {
            case .json: return .ownerBackup
            case .csv: return .csv
            }
        }
    }

    var id: Self { self }

    /// Whether the shell presents it as a sheet. An export is not one: its file is written
    /// before anything is presented, and then it is a save panel (`fileMover`), which the Mac's
    /// menu Export brings with it (W6).
    var isSheet: Bool {
        switch self {
        case .newHabit, .weeklyReview: return true
        case .export: return false
        }
    }
}

/// The 680 pt reading width of Today and Stats at regular width and on the Mac (D2).
enum ShellLayout {
    static let readableWidth: CGFloat = 680
}

extension EnvironmentValues {
    /// False for a tab the shell keeps alive but hides (D2). Its toolbar items are gated on it
    /// inside the builder, and "when shown" work (Settings' refreshes) keys a `.task(id:)` on
    /// it. True everywhere outside the shell — the Mac's Settings window, a sheet, a test hosting
    /// a view on its own — where the view is only ever on screen when it is shown.
    var shellTabIsActive: Bool {
        get { self[ShellTabIsActiveKey.self] }
        set { self[ShellTabIsActiveKey.self] = newValue }
    }

    /// The shell's regular-width layout: the iPad (and a Pro Max in landscape) at regular width,
    /// and the Mac, which always counts as regular (D2). ContentView sets it from the size class
    /// it branches on, so the tabs follow the shell's own decision rather than reading a size
    /// class of their own in a split view column. False outside the shell.
    var shellUsesRegularLayout: Bool {
        get { self[ShellRegularLayoutKey.self] }
        set { self[ShellRegularLayoutKey.self] = newValue }
    }
}

private struct ShellTabIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private struct ShellRegularLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension View {
    /// Today's and Stats' content at regular width and on the Mac: at most 680 pt, centred. The
    /// cap goes INSIDE the ScrollView (the AccountSwitchView pattern), so the whole detail width
    /// still scrolls and the indicator stays at the window's edge; capping the ScrollView itself
    /// leaves dead, non-scrolling margins on a 13-inch iPad. A no-op at compact width, where
    /// phones keep their layout exactly.
    func shellReadableWidth(_ regular: Bool) -> some View {
        frame(maxWidth: regular ? ShellLayout.readableWidth : nil)
            .frame(maxWidth: regular ? .infinity : nil)
    }
}

#if DEBUG
/// Counts each creation of a tab's root view into its shell's `tabCreations`, for the hosted
/// shell tests. Held as a `@StateObject`, whose initializer SwiftUI runs once per view lifetime
/// — unlike `@State`'s initial value, which is built again on every init of the struct and then
/// thrown away — so the count is creations, not redraws.
final class ShellTabLifetime: ObservableObject {
    init(_ tab: ShellTab, shell: ShellState) {
        MainActor.assumeIsolated { shell.tabCreations[tab, default: 0] += 1 }
    }
}
#endif
