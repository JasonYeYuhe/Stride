import SwiftUI
import SwiftData

/// The shell (RELEASE-1.4.0.md D2): a sidebar and one detail stack at regular width and on the
/// Mac, the tab bar on a compact iPhone, both over this window's `ShellState`.
struct ContentView: View {
    /// This window's shell, above the size-class branch: a crossing between the two layouts
    /// rebuilds the layout, not the date, the anchor, the Stats habit or the selection.
    @State private var shell: ShellState
    @Environment(\.scenePhase) private var scenePhase
    private var store = StoreService.shared
    // `-paywall` opens the Pro paywall on launch so scripts/a11y_sweep.sh can capture it at every
    // text size without tapping through a Pro-locked card. DEBUG-only on purpose: launch arguments
    // cannot reach a store build anyway (only Xcode, simctl and XCUITest pass them), but compiling
    // it out keeps release free of any sheet that appears without a user action.
    #if DEBUG
    @State private var showingLaunchPaywall = CommandLine.arguments.contains("-paywall")
    #endif

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @Environment(\.openSettings) private var openSettings
    #endif

    /// - Parameter shell: injected by the hosted shell tests; the app starts from the launch
    ///   arguments (`-tab N`). Only the first value counts, as for any `@State`.
    init(shell: ShellState? = nil) {
        _shell = State(initialValue: shell ?? ShellState())
    }

    var body: some View {
        #if DEBUG
        shellBody.sheet(isPresented: $showingLaunchPaywall) { ProPaywallView() }
        #else
        shellBody
        #endif
    }

    /// The Mac always counts as regular (D2): it gets the 680 pt cap and the width-derived
    /// heatmap, and a narrow window falls back to the phone-sized cell on its own.
    private var usesRegularLayout: Bool {
        #if os(macOS)
        return true
        #else
        return sizeClass == .regular
        #endif
    }

    /// Everything that must outlive a size-class crossing hangs here, above `layout`'s branch.
    private var shellBody: some View {
        layout
            .environment(\.shellUsesRegularLayout, usesRegularLayout)
            // What the window was asked to present (W6's menu commands), here so it does not
            // depend on the tab that would otherwise show it: ⇧⌘R before Stats was ever opened
            // has no StatsView to present from. Cleared when dismissed. An export request is not
            // a sheet; it never shows here.
            .sheet(item: sheetRequest) { request in
                requestedSheet(request)
            }
            // Re-anchoring Today (`ShellState.reanchor`) — here, never inside a tab and never only
            // while Today shows. Coming back to the app the next morning,
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { shell.reanchor(now: Date()) }
            }
            // midnight passing while it is open (posted on no particular thread, hence the hop),
            .onReceive(
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                shell.reanchor(now: Date())
            }
            // and Today being opened, as the 1.3.x `switch` did implicitly by recreating TodayView
            // on every visit: a day change neither hook above delivered still never reaches a
            // check-in. Free within the day (`reanchor` writes nothing then).
            .onChange(of: shell.selection) { _, tab in
                if tab == .today { shell.reanchor(now: Date()) }
            }
            #if os(macOS)
            .onAppear { openSettingsIfTheLaunchAskedForIt() }
            #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        splitView
        #else
        if sizeClass == .regular {
            // iPad, and a Plus/Pro Max iPhone in landscape.
            splitView
        } else {
            // iPhone: Tab layout. A TabView keeps each tab's state on its own.
            tabView
        }
        #endif
    }

    // MARK: - Regular width and the Mac

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(shell: shell)
        } detail: {
            // ONE NavigationStack, the detail column's root as in 1.3.x, around the kept tabs. A
            // stack per tab would nest navigation containers in the column, and SwiftUI has no way
            // to withdraw a hidden stack's title (design review, "d2-per-tab-stack-title"). So the
            // title is set here, from the shell, once — the tabs set none of their own.
            NavigationStack {
                keptTabs
                    .navigationTitle(title(for: shell.selection))
                    #if os(iOS)
                    // One bar now spans up to three scroll views, and a large title's collapse
                    // would follow whichever registered first — possibly a hidden one.
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            }
        }
        .navigationSplitViewStyle(.balanced)
        // iPad: the default (automatic) column visibility. Forcing `.all` leaves a 424 pt
        // detail beside the sidebar on an iPad mini in portrait.
        #if os(iOS)
        .tint(.green)
        #endif
    }

    /// The places visited so far, each created on its first visit and kept: switching back to one
    /// finds its scroll position, its open group headers and its in-flight work where they were.
    /// The 1.3.x `switch` rebuilt the view on every switch. The `if`s only ever turn true
    /// (`ShellState.visited` only grows), so they create a tab once and never swap one; showing
    /// and hiding is done by modifier values (`shellTab(isActive:)`), never by an `if`/`else` on
    /// the selection, which would rebuild the subtree and lose all of it.
    private var keptTabs: some View {
        ZStack {
            if shell.isCreated(.today) {
                TodayView(shell: shell)
                    .shellTab(isActive: shell.selection == .today)
            }
            if shell.isCreated(.stats) {
                StatsView(shell: shell)
                    .shellTab(isActive: shell.selection == .stats)
            }
            #if os(iOS)
            // The Mac's Settings is its own window (Stride → Settings…), not a place here.
            if shell.isCreated(.settings) {
                SettingsView()
                    .shellTab(isActive: shell.selection == .settings)
            }
            #endif
        }
    }

    // MARK: - Compact iPhone

    #if os(iOS)
    /// The tab bar, bound to the same selection as the sidebar, so a rotation into regular width
    /// lands on the same place. Each stack's root takes its title from the shell, as the kept
    /// tabs' single stack does.
    private var tabView: some View {
        TabView(selection: $shell.selection) {
            NavigationStack {
                TodayView(shell: shell)
                    .navigationTitle(title(for: .today))
            }
            .environment(\.shellTabIsActive, shell.selection == .today)
            .tabItem {
                Label("Today", systemImage: "checkmark.circle.fill")
            }
            .tag(ShellTab.today)

            NavigationStack {
                StatsView(shell: shell)
                    .navigationTitle(title(for: .stats))
            }
            .environment(\.shellTabIsActive, shell.selection == .stats)
            .tabItem {
                Label("Stats", systemImage: "chart.bar.fill")
            }
            .tag(ShellTab.stats)

            NavigationStack {
                SettingsView()
                    .navigationTitle(title(for: .settings))
            }
            .environment(\.shellTabIsActive, shell.selection == .settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(ShellTab.settings)
        }
        .tint(.green)
    }
    #endif

    // MARK: - Titles and requests

    /// Every place's title, from the shell. Today's is its date's ("Today", "Yesterday" or the
    /// date), in the picked language.
    private func title(for tab: ShellTab) -> Text {
        switch tab {
        case .today: return Text(verbatim: shell.todayTitle)
        case .stats: return Text("Statistics")
        case .settings: return Text("Settings")
        }
    }

    /// `shell.request` when it is a sheet; dismissing it clears the request.
    private var sheetRequest: Binding<ShellRequest?> {
        Binding(
            get: { shell.request.flatMap { $0.isSheet ? $0 : nil } },
            set: { newValue in
                if newValue == nil, shell.request?.isSheet == true { shell.request = nil }
            })
    }

    @ViewBuilder
    private func requestedSheet(_ request: ShellRequest) -> some View {
        switch request {
        case .newHabit:
            AddHabitView()
        case .weeklyReview:
            // As Stats' button: the review for Pro, the paywall for anyone else. Read when the
            // sheet is built, so a purchase made since the request was issued counts.
            switch MenuCommandRules.weeklyReviewDestination(isPro: store.isPro) {
            case .review: WeeklyReviewView()
            case .paywall: ProPaywallView()
            }
        case .export:
            EmptyView()
        }
    }

    // MARK: - Mac launch

    #if os(macOS)
    /// Once per process, not per window: a second main window parses the same `-tab 2`.
    @MainActor private static var launchOpenedSettings = false

    /// `-tab 2` on the Mac (scripts and the E2E kit): Today in the main window, and the Settings
    /// window opened, since Settings is no longer a place in the sidebar (D2).
    private func openSettingsIfTheLaunchAskedForIt() {
        guard shell.opensSettingsAtLaunch, !Self.launchOpenedSettings else { return }
        Self.launchOpenedSettings = true
        openSettings()
    }
    #endif
}

private extension View {
    /// A kept tab, shown or hidden (D2). Hidden: invisible; untouchable; out of VoiceOver's and
    /// Full Keyboard Access's reach, its shortcuts disabled with it (`.disabled`); and told so,
    /// for its toolbar items and its "when shown" work (`\.shellTabIsActive`). Values only, so
    /// the tab's identity, @State and scroll position never change with the selection.
    func shellTab(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .disabled(!isActive)
            .environment(\.shellTabIsActive, isActive)
    }
}

/// The sidebar, both platforms (D2). Today and Statistics, and on iOS Settings — the Mac's
/// Settings is its own window.
struct SidebarView: View {
    @Bindable var shell: ShellState

    var body: some View {
        list
            .navigationTitle("Stride")
            .listStyle(.sidebar)
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        // The macOS 13 non-optional initializer, "a single row that cannot be deselected", as
        // 1.3.x's SidebarView had. With an optional selection a click in the empty area under the
        // rows, or a ⌘-click on the selected one, writes nil and AppKit drops the highlight —
        // and dropping the nil afterwards would leave the detail beside an unhighlighted sidebar
        // (design review, "d2-mac-sidebar-deselect").
        List(selection: $shell.selection) {
            rows
        }
        #else
        // iOS has only the optional form. A sidebar row is not deselected by a tap, but a nil
        // that ever arrives keeps the place that is showing rather than leaving none.
        List(selection: Binding<ShellTab?>(
            get: { shell.selection },
            set: { if let tab = $0 { shell.selection = tab } })) {
            rows
        }
        #endif
    }

    private var rows: some View {
        ForEach(ShellTab.sidebarRows()) { tab in
            row(tab)
                .tag(tab)
        }
    }

    @ViewBuilder
    private func row(_ tab: ShellTab) -> some View {
        switch tab {
        case .today: Label("Today", systemImage: "checkmark.circle.fill")
        case .stats: Label("Statistics", systemImage: "chart.bar.fill")
        case .settings: Label("Settings", systemImage: "gear")
        }
    }
}
