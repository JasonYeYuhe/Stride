import SwiftUI
import SwiftData
import WidgetKit

@main
struct StrideApp: App {
    /// The store, or why it could not be opened. Everything that touches data hangs off its
    /// `ready` state (upgrade race, E2E U123: a failed open used to fall back to an empty store).
    private let storeLaunch: AppStoreLaunch
    private var languageManager = LanguageManager.shared
    /// The account screen for a one-tap sign-in with no login sheet open (AccountChoiceRouter).
    private var accountRouter = AccountChoiceRouter.shared
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "stride_onboarding_completed")
    #if os(iOS)
    /// The app's phase — in an `App`, every scene's together: `.background` once the last one is.
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init() {
        #if STRIDE_MAC_VARIANT
        // The Mac test variant (scripts/mac_variant/) traps here unless it is sandboxed, its store
        // is inside its own container and its bundle id is not the real app's — before anything
        // below opens a store or reads the Keychain (RELEASE-1.4.0.md D7).
        MacVariantLaunchCheck.enforce()
        #endif
        SentryBootstrap.start()   // crash/hang reporting; no-op until SentryDSN is set
        // The real store, or the error screen — never another store. The app is the only process
        // that may create or migrate it; once it has, the widget is told it may open it too
        // (SharedModelContainer.openForApp). Blocks up to ~3 s only while a store that exists
        // fails to open.
        self.storeLaunch = AppStoreLaunch(
            open: { SharedModelContainer.openForApp(reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() }) },
            prepare: Self.prepareStore,
            report: AppStoreLaunch.reportToSentry)
        // The reminder actions (RELEASE-1.4.0.md D4): the delegate and the Mark Done / Add 1 /
        // Snooze categories, here and not in a `.task`. A button on a lock-screen banner launches a
        // terminated app in the background with no scene at all, and its response goes to whoever
        // is the delegate when launch finishes. After the store open, which the handler writes to.
        NotificationActionHandler.install()
        #if os(iOS)
        // The background refresh's launch handler (RELEASE-1.4.0.md D5), here for the same reason:
        // registration must be complete before launch finishes, and a refresh launches the app in
        // the background with no scene. Once per process; the hosted tests run inside this app,
        // and a second registration would get it killed (BackgroundSync.register).
        BackgroundSync.register()
        #if DEBUG
        BackgroundSync.runIfRequestedByLaunchArgument()
        #endif
        #else
        // One main window (RELEASE-1.4.0.md D3). ⌘N is New Habit now, not New Window, and without
        // this the window's tab bar (View → Show Tab Bar) still offered a + that opened a second
        // main window — with its own launch sync, its own copy of every app-level sheet. Before
        // any window exists: AppKit reads it when a window is created.
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
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
        // `-demoScenario accountConflict | accountUnknownOwner`: the account screen with fake
        // accounts and no network sign-in, for screenshots (AccountChoiceRouter.demoRequest).
        AccountChoiceRouter.shared.request = AccountChoiceRouter.demoRequest()
        #endif
        // Instantiate StoreService now so its Transaction.updates listener is running before any
        // network work. It used to be created lazily, and on macOS the default Today tab never
        // touches it, so the listener waited until the launch sync had finished.
        _ = StoreService.shared
    }

    /// The launch's data work, once, on the real store and before anything syncs — so only after
    /// the open succeeded (AppStoreLaunch): on a store opened in its place these one-time
    /// migrations would spend their per-install flags (E2E U123). Each also refuses any store but
    /// the real one itself (`SharedModelContainer.isRealStore`).
    @MainActor
    private static func prepareStore(_ modelContainer: ModelContainer) {
        // Re-anchor legacy local-midnight records to UTC day-keys before any
        // streak math or sync runs (idempotent — see SharedModelContainer).
        SharedModelContainer.migrateRecordDayKeysIfNeeded(modelContainer)
        // Before any sync: the 1.3.1 migrated-rows rule (rows a 1.3.0 snapshot already pushed
        // count as delivered, so a full pull may delete them if another device did) and the
        // owner-unknown note. Once per install each; the Keychain read is the one AuthService
        // makes anyway. See SyncService.prepareLaunch.
        SyncService.prepareLaunch(context: modelContainer.mainContext, defaults: .standard,
                                  hasStoredSession: KeychainSessionTokenStore().read() != nil)
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
        #endif
    }

    var body: some Scene {
        windowGroup
        #if os(macOS)
        Settings {
            StoreGateView(launch: storeLaunch) { modelContainer in
                SettingsView()
                    // The window's title, as 1.3.x's SettingsView set it itself: since 1.4.0 the
                    // shell titles its places, and SettingsView sets none (RELEASE-1.4.0.md D2).
                    .navigationTitle("Settings")
                    .modelContainer(modelContainer)
            }
            .environment(\.locale, languageManager.locale ?? .current)
            // A bare List has no size of its own, and since 1.4.0 this window is the Mac's only
            // Settings (D2): room for the account rows and the export buttons' inline lines
            // without a scroll at first sight (D3).
            .frame(minWidth: 460, idealWidth: 520, minHeight: 520)
        }
        #endif
    }

    private var windowGroup: some Scene {
        #if os(macOS)
        // An id, so Window → Stride ⌘0 can open the main window again when none is left
        // (`MainWindows`, D3). Still a WindowGroup, not a single `Window`, which could change
        // whether closing the window quits the app and what a login link arriving with no window
        // open does; both stay as in 1.3.x this way (design review,
        // "mac-main-window-unrecoverable").
        WindowGroup(id: MainWindows.id) {
            mainWindowContent
                .countsAsMainWindow()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 650)
        .commands { StrideCommands() }
        #else
        WindowGroup {
            mainWindowContent
        }
        // Leaving the app asks for a background refresh (D5), so what is still unsent — a check-in
        // whose push was cut off by the suspension, or one the widget makes later in its own
        // process, which is not known to be allowed to submit — reaches the server without the
        // app being opened. Once per trip to the background, not per window: the App's phase is
        // every scene's together. Only while a session is stored (`scheduleIfSignedIn`).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            BackgroundRefresh.scheduleIfSignedIn(reason: .sceneBackground)
        }
        #endif
    }

    /// A main window's content: the app over its store, or the store's error screen.
    private var mainWindowContent: some View {
        StoreGateView(launch: storeLaunch) { modelContainer in
            app(over: modelContainer)
        }
        .environment(\.locale, languageManager.locale ?? .current)
    }

    /// The app itself, over the opened store.
    private func app(over modelContainer: ModelContainer) -> some View {
        ContentView()
            .task {
                // Entitlements FIRST. Transaction.currentEntitlements is a local read that works
                // offline and returns in milliseconds. It used to be the last of four awaits,
                // behind notifications, the sync (up to 10 s waiting for session restore, then
                // network with default timeouts) and product loading (up to 30 s of retries),
                // so on a poor connection a Lifetime owner saw Pro locked — "Upgrade to Pro"
                // in Settings, the paywall instead of Weekly Review — for most of a minute.
                await StoreService.shared.refreshPurchasedProducts()
                await setupNotifications(modelContainer)
                await syncIfLoggedIn(modelContainer)
                await StoreService.shared.loadProducts()
            }
            // Every SwiftData save in the app, not a list of call sites. Only check-ins used to
            // reload the widget, so adding, deleting, archiving, renaming or reordering a habit —
            // or a sync pulling in another device's check-ins — left it stale until its next
            // scheduled refresh at midnight; a deleted habit stayed listed, and tapping it did
            // nothing. A new save site can't forget this.
            //
            // 1.4.0: and the badge, the snoozes and the banners (RELEASE-1.4.0.md D3, D4). A
            // check-in from the widget runs in another process and one from another device
            // arrives by sync; neither passes through `CheckInEffects`, so this pass is what
            // cancels a snooze, withdraws a banner and recounts the badge for them.
            .onReceive(
                NotificationCenter.default.publisher(for: .habitDataChanged)
                    .merge(with: NotificationCenter.default.publisher(for: ModelContext.didSave))
                    .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            ) { _ in
                WidgetCenter.shared.reloadAllTimelines()
                NotificationService.shared.refreshAfterDataChange(modelContainer: modelContainer)
            }
            // The day changed under a running app (midnight, or the wake after it): yesterday's
            // banners go, the badge counts the new day's habits as remaining again, and a snooze
            // cancelled for "done today" is judged on the new today. Posted on no particular
            // thread, hence the hop.
            .onReceive(
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                NotificationService.shared.refreshAfterDataChange(modelContainer: modelContainer)
                NotificationService.shared.pruneDeliveredBeforeToday()
            }
            // One-tap sign-in: the magic link in the email is a universal link
            // (`https://stride-api.colorarchive.me/login?token=…`, the associated-domains
            // entitlement + the server's AASA file). Which modifier receives it depends on the
            // platform and launch path — macOS delivers universal links as a browsing-web
            // user activity, which `.onOpenURL` never sees — so both are wired, and
            // AuthService ignores a second delivery of the same tap. Links that fail to
            // open the app (Gmail's link proxy, in-app mail browsers) land on the /login
            // page with the token to paste, as before.
            .onOpenURL { url in handleLoginLink(url, modelContainer) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                handleLoginLink(url, modelContainer)
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
                    // The badge, and the snoozes and banners of what the widget or another device
                    // checked in meanwhile; then banners from before today (D4).
                    NotificationService.shared.refreshAfterDataChange(modelContainer: modelContainer)
                    NotificationService.shared.pruneDeliveredBeforeToday()
                    // A subscription can lapse, renew or be refunded while backgrounded;
                    // nothing else re-reads entitlements after launch.
                    await StoreService.shared.refreshPurchasedProducts()
                    await syncIfLoggedIn(modelContainer)
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
                    // The Dock badge, the snoozes and the banners, as iOS on willEnterForeground
                    // (RELEASE-1.4.0.md D3, D4).
                    NotificationService.shared.refreshAfterDataChange(modelContainer: modelContainer)
                    NotificationService.shared.pruneDeliveredBeforeToday()
                    await StoreService.shared.refreshPurchasedProducts()
                    await syncIfLoggedIn(modelContainer)
                }
            }
            #endif
            .modelContainer(modelContainer)
    }

    @MainActor
    private func syncIfLoggedIn(_ modelContainer: ModelContainer) async {
        await Self.syncIfLoggedIn(modelContainer, auth: .shared, sync: .shared) { modelContainer in
            // A pull can change a habit's kind, days or reminder time, and pending requests keep
            // what they were scheduled with: a Mon/Wed/Fri habit made daily on the phone kept its
            // three weekday triggers here, and a kind change kept the other button, until the next
            // cold launch — on iOS, days (RELEASE-1.4.0.md D4; design review,
            // "stale-category-addone-untoggles-binary"). Every habit's requests are replaced
            // whole. No prune: that stays with the launch pass, see `scheduleAllHabitReminders`.
            NotificationService.shared.scheduleAllHabitReminders(modelContainer: modelContainer)
        }
    }

    /// The launch and foreground sync (iOS willEnterForeground, macOS didBecomeActive), with the
    /// services injected for the hosted tests. `afterSync` runs only after a sync that ran to the
    /// end.
    ///
    /// Since 1.4.0 a background launch can leave this process with a stored session and no user —
    /// its one session check failed offline — and the user's next open resumes that process
    /// (RELEASE-1.4.0.md D5; design review, "bg-launch-leaves-currentUser-nil"). 1.3.x's
    /// `guard isLoggedIn` then turned every foreground sync away for the life of the process, while
    /// background runs kept syncing from the remembered account. So, in this order:
    /// 1. ask the server about the stored session again when no user is known
    ///    (`recheckStoredSessionIfNeeded`) — signs the device back in, or finds the session gone;
    /// 2. wait out a sync in flight, so a stale background run cannot turn this one away (it
    ///    returns false to a second caller rather than queueing it);
    /// 3. sync when there is a session to sync with (`currentSyncSession`: the stored token and
    ///    its account, loaded user or not), not only when a user is loaded — the sync resolves the
    ///    session itself, as background runs and Erase's pre-erase sync always have. A recheck
    ///    that got no answer therefore still attempts the push.
    ///
    /// One pass at a time per SyncService: a call that finds one already rechecking, waiting or
    /// syncing returns at once, and that pass's sync covers it. Shipped builds got this from
    /// SyncService turning the second of two overlapping syncs away; step 2's wait queues callers
    /// instead, and passes overlap routinely: the window's `.task` and didBecomeActive at a Mac
    /// launch, each ⌘-Tab back during a slow sync, a willEnterForeground during the iOS launch
    /// sync. Each would have queued a full sync of its own after the one in flight, and sent its
    /// own recheck while no user was loaded (W3 review). Keyed by the instance, so a hosted test's
    /// services never meet the host app's own launch pass.
    @MainActor
    static func syncIfLoggedIn(_ modelContainer: ModelContainer, auth: AuthService, sync: SyncService,
                               afterSync: (ModelContainer) -> Void) async {
        let pass = ObjectIdentifier(sync)
        guard foregroundPasses.insert(pass).inserted else { return }
        defer { foregroundPasses.remove(pass) }
        await auth.recheckStoredSessionIfNeeded()
        await sync.waitUntilIdle()
        guard auth.currentSyncSession() != nil else { return }
        // Automatic: skipped while the server has asked this device to wait, or failures are
        // backing off. Sync Now in Settings still goes at once.
        if await sync.sync(context: modelContainer.mainContext, trigger: .automatic) {
            afterSync(modelContainer)
        }
    }

    /// The SyncServices a foreground pass is under way for (`syncIfLoggedIn`).
    @MainActor private static var foregroundPasses: Set<ObjectIdentifier> = []

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
    private func handleLoginLink(_ url: URL, _ modelContainer: ModelContainer) {
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
    private func setupNotifications(_ modelContainer: ModelContainer) async {
        // The badge on launch, with the snoozes and banners of habits already done today, and the
        // banners delivered before today (RELEASE-1.4.0.md D3, D4).
        NotificationService.shared.refreshAfterDataChange(modelContainer: modelContainer)
        NotificationService.shared.pruneDeliveredBeforeToday()

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
