import SwiftUI
import SwiftData
import WidgetKit

@main
struct StrideApp: App {
    let modelContainer: ModelContainer
    private var languageManager = LanguageManager.shared

    init() {
        self.modelContainer = SharedModelContainer.modelContainer
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, languageManager.locale ?? .current)
                .task {
                    await setupNotifications()
                    await syncIfLoggedIn()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .habitDataChanged)
                        .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
                ) { _ in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )) { _ in
                    Task { @MainActor in
                        NotificationService.shared.updateBadge(modelContainer: modelContainer)
                        await syncIfLoggedIn()
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
    private func syncIfLoggedIn() async {
        guard AuthService.shared.isLoggedIn else { return }
        let context = modelContainer.mainContext
        await SyncService.shared.sync(context: context)
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
