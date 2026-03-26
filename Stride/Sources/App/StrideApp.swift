import SwiftUI
import SwiftData

@main
struct StrideApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Habit.self, HabitRecord.self])
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 650)
        #endif
    }
}
