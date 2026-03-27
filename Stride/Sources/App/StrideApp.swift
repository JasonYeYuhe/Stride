import SwiftUI
import SwiftData
import WidgetKit

@main
struct StrideApp: App {
    let modelContainer: ModelContainer

    init() {
        self.modelContainer = SharedModelContainer.modelContainer
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await setupNotifications()
                }
                .onReceive(NotificationCenter.default.publisher(for: .habitDataChanged)) { _ in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )) { _ in
                    Task { @MainActor in
                        NotificationService.shared.updateBadge(modelContainer: modelContainer)
                    }
                }
                #endif
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 650)
        #endif
    }

    @MainActor
    private func setupNotifications() async {
        // Update badge on launch
        NotificationService.shared.updateBadge(modelContainer: modelContainer)

        // Re-schedule if reminders were previously enabled
        if NotificationService.shared.isReminderEnabled {
            let status = await NotificationService.shared.checkPermission()
            if status == .authorized {
                NotificationService.shared.scheduleReminders()
            }
        }
    }
}

extension Notification.Name {
    static let habitDataChanged = Notification.Name("habitDataChanged")
}
