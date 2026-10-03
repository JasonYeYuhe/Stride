import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab: Int = {
        if let idx = CommandLine.arguments.firstIndex(of: "-tab"),
           idx + 1 < CommandLine.arguments.count,
           let tab = Int(CommandLine.arguments[idx + 1]) {
            return tab
        }
        return 0
    }()
    @State private var showingAddHabit = false
    // `-paywall` opens the Pro paywall on launch so scripts/a11y_sweep.sh can capture it at every
    // text size without tapping through a Pro-locked card. DEBUG-only on purpose: launch arguments
    // cannot reach a store build anyway (only Xcode, simctl and XCUITest pass them), but compiling
    // it out keeps release free of any sheet that appears without a user action.
    #if DEBUG
    @State private var showingLaunchPaywall = CommandLine.arguments.contains("-paywall")
    #endif

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if DEBUG
        layout.sheet(isPresented: $showingLaunchPaywall) { ProPaywallView() }
        #else
        layout
        #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingAddHabit) {
            AddHabitView()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("New Habit") { showingAddHabit = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        #else
        if sizeClass == .regular {
            // iPad: Sidebar layout
            NavigationSplitView {
                VStack(spacing: 0) {
                    // The element type must be spelled out: without it the titles infer as
                    // String, which picks Label's StringProtocol overload and renders the
                    // raw key instead of the translation.
                    ForEach([
                        (0, "Today", "checkmark.circle.fill"),
                        (1, "Statistics", "chart.bar.fill"),
                        (2, "Settings", "gear")
                    ] as [(Int, LocalizedStringKey, String)], id: \.0) { item in
                        Button {
                            selectedTab = item.0
                        } label: {
                            Label(item.1, systemImage: item.2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                                .background(selectedTab == item.0 ? Color.green.opacity(0.15) : Color.clear)
                                .foregroundStyle(selectedTab == item.0 ? .green : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTab == item.0 ? .isSelected : [])
                    }
                    Spacer()
                }
                .navigationTitle("Stride")
            } detail: {
                NavigationStack {
                    detailView
                }
            }
            .tint(.green)
        } else {
            // iPhone: Tab layout
            TabView(selection: $selectedTab) {
                NavigationStack {
                    TodayView()
                }
                .tabItem {
                    Label("Today", systemImage: "checkmark.circle.fill")
                }
                .tag(0)

                NavigationStack {
                    StatsView()
                }
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
                .tag(1)

                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
            }
            .tint(.green)
        }
        #endif
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case 0: TodayView()
        case 1: StatsView()
        case 2: SettingsView()
        default: TodayView()
        }
    }
}

#if os(macOS)
struct SidebarView: View {
    @Binding var selectedTab: Int

    var body: some View {
        List(selection: $selectedTab) {
            Label("Today", systemImage: "checkmark.circle.fill")
                .tag(0)
            Label("Statistics", systemImage: "chart.bar.fill")
                .tag(1)
            Label("Settings", systemImage: "gear")
                .tag(2)
        }
        .navigationTitle("Stride")
        .listStyle(.sidebar)
    }
}
#endif
