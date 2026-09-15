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
        // Instantiate StoreService now so its Transaction.updates listener is running before any
        // network work. It used to be created lazily, and on macOS the default Today tab never
        // touches it, so the listener waited until the launch sync had finished.
        _ = StoreService.shared
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
                    // Entitlements FIRST. Transaction.currentEntitlements is a local read that works
                    // offline and returns in milliseconds. It used to be the last of four awaits,
                    // behind notifications, the sync (up to 10 s waiting for session restore, then
                    // network with default timeouts) and product loading (up to 30 s of retries),
                    // so on a poor connection a Lifetime owner saw Pro locked — "Upgrade to Pro"
                    // in Settings, the paywall instead of Weekly Review — for most of a minute.
                    await StoreService.shared.refreshPurchasedProducts()
                    AnalyticsService.shared.send("appLaunched")
                    await setupNotifications()
                    await syncIfLoggedIn()
                    await StoreService.shared.loadProducts()
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
                        // A subscription can lapse, renew or be refunded while backgrounded;
                        // nothing else re-reads entitlements after launch.
                        await StoreService.shared.refreshPurchasedProducts()
                        await syncIfLoggedIn()
                    }
                }
                #else
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                }
                // A Mac app can stay open for days; re-read entitlements when it comes forward so
                // a lapsed or renewed subscription is reflected without a relaunch.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    Task { @MainActor in await StoreService.shared.refreshPurchasedProducts() }
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
