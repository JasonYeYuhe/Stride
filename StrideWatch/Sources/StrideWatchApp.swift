import SwiftUI
import SwiftData

@main
struct StrideWatchApp: App {
    let modelContainer: ModelContainer

    init() {
        self.modelContainer = SharedModelContainer.modelContainer
        if CommandLine.arguments.contains("-demo") {
            DemoData.populate(container: modelContainer)
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchTodayView()
        }
        .modelContainer(modelContainer)
    }
}
