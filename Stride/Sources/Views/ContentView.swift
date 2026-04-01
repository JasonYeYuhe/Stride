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

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            detailView
        }
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
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "checkmark.circle.fill")
                }
                .tag(0)

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
        .tint(.green)
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
