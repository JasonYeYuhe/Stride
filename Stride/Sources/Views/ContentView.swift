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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

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
        if sizeClass == .regular {
            // iPad: Sidebar layout
            NavigationSplitView {
                VStack(spacing: 0) {
                    ForEach([
                        (0, "Today", "checkmark.circle.fill"),
                        (1, "Statistics", "chart.bar.fill"),
                        (2, "Settings", "gear")
                    ], id: \.0) { item in
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
                    }
                    Spacer()
                }
                .navigationTitle("Stride")
            } detail: {
                detailView
            }
            .tint(.green)
        } else {
            // iPhone: Tab layout
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
