import SwiftUI
import SwiftData
import WidgetKit

@main
struct StrideApp: App {
    let modelContainer: ModelContainer
    private var languageManager = LanguageManager.shared
    /// The account screen for a one-tap sign-in with no login sheet open (AccountChoiceRouter).
    private var accountRouter = AccountChoiceRouter.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "stride_onboarding_completed")

    init() {
        SentryBootstrap.start()   // crash/hang reporting; no-op until SentryDSN is set
        self.modelContainer = SharedModelContainer.modelContainer
        // Re-anchor legacy local-midnight records to UTC day-keys before any
        // streak math or sync runs (idempotent — see SharedModelContainer).
        SharedModelContainer.migrateRecordDayKeysIfNeeded(modelContainer)
        // Before any sync: the 1.3.1 migrated-rows rule (rows a 1.3.0 snapshot already pushed
        // count as delivered, so a full pull may delete them if another device did) and the
        // owner-unknown note. Once per install each; the Keychain read is the one AuthService
        // makes anyway. See SyncService.prepareLaunch.
        SyncService.prepareLaunch(context: modelContainer.mainContext, defaults: .standard,
                                  hasStoredSession: KeychainSessionTokenStore().read() != nil)
        // Copies of the user's data that nothing else ever removed, off the main thread: the
        // export files earlier share sheets wrote to tmp — backups, recovered edits, a deleted
        // account's among them (E2E S-DEL) — and the answers and cookies earlier builds left in
        // the shared URL cache and cookie store, the live session token among them (E2E S9). No
        // share sheet is open yet, and this build's requests use neither store.
        Task.detached(priority: .utility) {
            DataExportService.removeExportFiles()
            APIClient.purgeStoredHTTPState()
        }
        #if DEBUG
        // DEBUG-only, like `-paywall`: populate() erases the store (habits, check-ins, groups)
        // without queueing tombstones, and this file is compiled into StrideMac too, where
        // `open -a Stride --args -demo` reaches a Release build. There it wiped a real store,
        // and on a signed-in account the next push spread the demo set to every device. Every
        // caller (a11y_sweep.sh) builds Debug.
        if CommandLine.arguments.contains("-demo") {
            // `-demoScenario plurals|weekly` picks the plural acceptance data set.
            DemoData.populate(container: modelContainer, scenario: .fromLaunchArguments())
        }
        // `-demoScenario accountConflict | accountUnknownOwner`: the account screen with fake
        // accounts and no network sign-in, for screenshots (AccountChoiceRouter.demoRequest).
        AccountChoiceRouter.shared.request = AccountChoiceRouter.demoRequest()
        #endif
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
                    await setupNotifications()
                    await syncIfLoggedIn()
                    await StoreService.shared.loadProducts()
                }
                // Every SwiftData save in the app, not a list of call sites. Only check-ins used to
                // reload the widget, so adding, deleting, archiving, renaming or reordering a habit —
                // or a sync pulling in another device's check-ins — left it stale until its next
                // scheduled refresh at midnight; a deleted habit stayed listed, and tapping it did
                // nothing. A new save site can't forget this.
                .onReceive(
                    NotificationCenter.default.publisher(for: .habitDataChanged)
                        .merge(with: NotificationCenter.default.publisher(for: ModelContext.didSave))
                        .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
                ) { _ in
                    WidgetCenter.shared.reloadAllTimelines()
                }
                // One-tap sign-in: the magic link in the email is a universal link
                // (`https://stride-api.colorarchive.me/login?token=…`, the associated-domains
                // entitlement + the server's AASA file). Which modifier receives it depends on the
                // platform and launch path — macOS delivers universal links as a browsing-web
                // user activity, which `.onOpenURL` never sees — so both are wired, and
                // AuthService ignores a second delivery of the same tap. Links that fail to
                // open the app (Gmail's link proxy, in-app mail browsers) land on the /login
                // page with the token to paste, as before.
                .onOpenURL { url in handleLoginLink(url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    handleLoginLink(url)
                }
                // Deliver links to the window that is already open. Without this, macOS opens a
                // second main window for every incoming URL (WindowGroup's default).
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // The account screen as the continuation of a one-tap sign-in (handleLoginLink).
                // Never presented by a launch or foreground sync: those block silently.
                .sheet(item: Bindable(accountRouter).request) { request in
                    AccountChoiceSheet(request: request) { accountRouter.request = nil }
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
                // a lapsed or renewed subscription is reflected without a relaunch — and sync, as
                // iOS does on willEnterForeground. Without it nothing on the Mac met a revoked
                // session's 401 or the pause switch's 503 until a relaunch or Sync Now, so Today's
                // "Sign in again" row and "Sync paused" (acceptance (9)) never showed on a Mac left
                // open (review critic-3). Automatic: it waits out the owner's backoff window.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    Task { @MainActor in
                        await StoreService.shared.refreshPurchasedProducts()
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
        await AuthService.shared.waitForSessionRestore()
        guard AuthService.shared.isLoggedIn else { return }
        let context = modelContainer.mainContext
        // Automatic: skipped while the server has asked this device to wait, or failures are
        // backing off. Sync Now in Settings still goes at once.
        await SyncService.shared.sync(context: context, trigger: .automatic)
    }

    /// Signs in from a login link when signed out, then syncs — the same sync SettingsView runs
    /// when `isLoggedIn` turns true, needed here because Settings may not be on screen (or, on
    /// macOS, open at all). SyncService ignores the second of two overlapping syncs.
    ///
    /// Between the two, the owner is settled (`SyncService.settleSignIn`) exactly as a typed
    /// code settles it in LoginView: a link into an account that does not own this device's
    /// habits continues with the account screen, and the sync after it is blocked until the
    /// choice (it makes no request). If the login sheet is open — waiting on "Check your email"
    /// — it shows the screen itself, in its own sheet; otherwise it is presented here.
    @MainActor
    private func handleLoginLink(_ url: URL) {
        Task { @MainActor in
            guard await AuthService.shared.handleLoginLink(url) == .signedIn else { return }
            let context = modelContainer.mainContext
            if accountRouter.loginFlowsOpen == 0,
               case .chooseAccountData(let conflict) = SyncService.shared.settleSignIn(in: context) {
                accountRouter.request = AccountChoiceRequest(conflict: conflict)
                return
            }
            await SyncService.shared.sync(context: context)
        }
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
