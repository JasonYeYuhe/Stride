import SwiftUI
import SwiftData
import WidgetKit

@main
struct StrideApp: App {
    let modelContainer: ModelContainer
    private var languageManager = LanguageManager.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "stride_onboarding_completed")

    init() {
        SentryBootstrap.start()   // crash/hang reporting; no-op until SentryDSN is set
        self.modelContainer = SharedModelContainer.modelContainer
        // Re-anchor legacy local-midnight records to UTC day-keys before any
        // streak math or sync runs (idempotent — see SharedModelContainer).
        SharedModelContainer.migrateRecordDayKeysIfNeeded(modelContainer)
        if CommandLine.arguments.contains("-demo") {
            DemoData.populate(container: modelContainer)
        }
    }

    var body: some Scene {
        windowGroup
        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(modelContainer)
                .environment(\.locale, languageManager.locale ?? .current)
        }
        #endif
    }

    private var windowGroup: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, languageManager.locale ?? .current)
                .task {
                    AnalyticsService.shared.send("appLaunched")
                    await setupNotifications()
                    await syncIfLoggedIn()
                    await StoreService.shared.loadProducts()
                    // Read existing entitlements on every cold launch so isPro reflects
                    // prior purchases (incl. the lifetime non-consumable) before any view
                    // appears. Without this, a paying user lands on Today/Stats with Pro
                    // features locked until they happen to open Settings or the paywall.
                    await StoreService.shared.refreshPurchasedProducts()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .habitDataChanged)
                        .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
                ) { _ in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                #if os(iOS)
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )) { _ in
                    Task { @MainActor in
                        NotificationService.shared.updateBadge(modelContainer: modelContainer)
                        await syncIfLoggedIn()
                    }
                }
                #else
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
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
        await AuthService.shared.waitForSessionRestore()
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

        // Re-schedule per-habit reminders
        NotificationService.shared.rescheduleAllHabitReminders(modelContainer: modelContainer)
    }
}

extension Notification.Name {
    static let habitDataChanged = Notification.Name("habitDataChanged")
}
