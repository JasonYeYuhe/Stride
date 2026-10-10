import Foundation
import SwiftData
import os.log
#if os(iOS)
import BackgroundTasks
import WidgetKit
#endif

// Background sync (RELEASE-1.4.0.md D5): iOS only. BGTaskScheduler is `API_UNAVAILABLE(macos)`,
// and this file compiles into StrideMac too, where it is empty: the Mac syncs on activation and
// after a reminder's action, under a ProcessInfo activity (NotificationActionHandler).
#if os(iOS)

/// The BGAppRefreshTask that pushes what was checked in while Stride was not in front — a
/// reminder's Mark Done, the widget, a check-in made just before the app was suspended — and
/// pulls what other devices did, without the user opening the app.
///
/// - **Registered once per process, in `StrideApp.init`** (`register()`): the system kills the app
///   on a second registration of the same identifier (BGTaskScheduler.h), and the hosted tests run
///   inside the app, whose init has already registered. The result is kept, so a second call is a
///   no-op that answers the first call's result.
/// - **On the main queue, asserted.** `using: .main`, and `MainActor.assumeIsolated` inside. With
///   `nil` the system runs the launch handler on a background queue, while a closure literal
///   written in the main-actor `App.init` is statically main-actor in this Swift 5.9 module, so
///   the compiler would accept main-actor work there that runs off the main thread — on the
///   SwiftData `mainContext` (design review, "bg-handler-off-main"). If the queue is ever changed,
///   `assumeIsolated` traps at once instead of racing.
/// - **`start(_:)` is a thin shim over `run(container:)`**, which the hosted tests and the DEBUG
///   `-runBackgroundSync` launch argument drive: a `BGTask` cannot be constructed (BGTask.h), and
///   the Simulator never runs one.
enum BackgroundSync {
    /// The one refresh task. It must be in `BGTaskSchedulerPermittedIdentifiers` in
    /// Stride/Stride-Info.plist, or `register` returns false and every submit fails — silently,
    /// since submit errors only reach the log. A hosted test checks this constant against the
    /// built app's plist, and scripts/ci/product_checks.sh checks the plist itself.
    static let taskIdentifier = "yyh.stride.habittracker.sync"

    fileprivate static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "BackgroundSync")

    /// What `register()` answered, nil before it ran.
    @MainActor private(set) static var registration: Bool?

    /// StrideApp.init. Registration must be complete before the app finishes launching, and a
    /// background launch has no scene, so no `.task` would ever run it.
    @MainActor
    @discardableResult
    static func register() -> Bool {
        if let registration { return registration }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                start(task)
            }
        }
        registration = registered
        if !registered {
            logger.fault("background sync: registration refused — is \(taskIdentifier, privacy: .public) missing from BGTaskSchedulerPermittedIdentifiers?")
        }
        return registered
    }

    // MARK: - The task

    /// The launch handler. Starts the work and returns at once; the task is completed exactly
    /// once, by whichever comes first:
    /// - the work, with its result, after the resubmit (`handle()`);
    /// - the expiration handler, with false. It does only thread-safe work — cancel, then
    ///   complete — and never waits for the main actor: its queue is undocumented, and completing
    ///   late "may result in the system killing your app" (BGTask.h). A sync that is cancelled
    ///   gets no answer to its next request, and a `.background` run records no backoff and no
    ///   error for that (`SyncService.Trigger.background`), so the next foreground sync still goes.
    ///
    /// `body` is the work, injectable so a hosted test can drive both paths with a fake task.
    @MainActor
    static func start(_ task: BackgroundTaskHandle,
                      body: @escaping @MainActor () async -> Bool = { await BackgroundSync.handle() }) {
        let completion = CompletionClaim()
        // Created first, but it cannot begin before this main-actor turn ends — after the
        // expiration handler below is set.
        let work = Task { @MainActor in
            let success = await body()
            if completion.claim() {
                task.setTaskCompleted(success: success)
            }
        }
        task.expirationHandler = expirationHandler(cancelling: work, completion: completion, task: task)
    }

    /// Built outside any actor, so the closure is not main-actor isolated, even statically.
    private static func expirationHandler(cancelling work: Task<Void, Never>, completion: CompletionClaim,
                                          task: BackgroundTaskHandle) -> () -> Void {
        {
            work.cancel()
            if completion.claim() {
                task.setTaskCompleted(success: false)
            }
            logger.notice("background sync: expired")
        }
    }

    /// The work of one refresh, the same from the system's task and from `-runBackgroundSync`:
    /// the run over the store this launch opened, then the resubmit that keeps the chain going —
    /// at most one refresh is pending, and it is used up by running.
    ///
    /// The resubmit happens before the task is completed (the system may suspend the process the
    /// moment it is), and only while a session is stored: "signed in" here means a token in the
    /// Keychain (`hasStoredSession`), never `isLoggedIn`. A background launch's session check can
    /// fail offline and leave `currentUser` nil while every sync still runs from the remembered
    /// account (design review, "bg-launch-leaves-currentUser-nil"); keyed on `isLoggedIn`, the
    /// first offline refresh would end the chain. Read after the run: a run whose session was
    /// found gone has deleted the token, and nothing is left to sync.
    @MainActor
    static func handle() async -> Bool {
        var synced = false
        if let container = SharedModelContainer.opened {
            synced = await run(container: container)
        } else {
            // The launch could not open the store (it reported that itself). Nothing to sync from;
            // a later launch may open it, so the chain is still kept.
            logger.error("background sync: the store is not open")
        }
        if AuthService.shared.hasStoredSession {
            _ = await BackgroundRefresh.schedule(reason: .resubmit).value
        }
        let result = synced ? "synced" : "not synced"
        logger.notice("background sync: \(result, privacy: .public)")
        return synced
    }

    // MARK: - The run

    /// What a run reaches outside itself, so a hosted test reaches none of the host app's.
    struct Environment {
        var syncService: @MainActor () -> SyncService
        /// After the sync: what a scene-less background launch never attaches — StrideApp's
        /// launch `.task`, its didSave observer and its foreground hooks all hang off a window.
        var afterSync: @MainActor (ModelContainer) async -> Void

        static var live: Environment {
            Environment(
                syncService: { SyncService.shared },
                afterSync: { container in
                    let notifications = NotificationService.shared
                    // A pull can change a habit's kind, days or time (D4): every reminder is
                    // replaced whole, and the prune — awaited, the process may be suspended right
                    // after — removes what no habit wants any more. Safe here, unlike after a
                    // foreground sync: no habit sheet can be saving while the app is in the
                    // background (`scheduleAllHabitReminders`).
                    await notifications.rescheduleAllHabitRemindersAndWait(modelContainer: container)
                    // The snoozes and banners of what another device or the widget checked in
                    // meanwhile, as on every foreground (D3, D4).
                    notifications.refreshAfterDataChange(modelContainer: container)
                    // The badge, awaited: the refresh pass sets it fire-and-forget.
                    await notifications.updateBadgeAndWait(modelContainer: container)
                    WidgetCenter.shared.reloadAllTimelines()
                })
        }
    }

    /// One background run over `container`: a `.background` sync on its `mainContext`, then
    /// `afterSync`. True when the sync ran to the end.
    ///
    /// It first waits out a sync already in flight — one this process started before it was
    /// suspended, say — and then runs its own, as the reminder action does: a run in flight
    /// planned its push before what this refresh is for was written, and SyncService turns a
    /// second caller away rather than queueing it. `.background`: skipped inside the owner's
    /// backoff window, and a run iOS cuts short leaves no window and no error behind (D5).
    ///
    /// Cancelled (the task expired), it stops after the sync's current step and does nothing
    /// more: the task has already been completed.
    @MainActor
    static func run(container: ModelContainer, environment: Environment = .live) async -> Bool {
        let service = environment.syncService()
        await service.waitUntilIdle()
        guard !Task.isCancelled else { return false }
        let synced = await service.sync(context: container.mainContext, trigger: .background)
        guard !Task.isCancelled else { return false }
        await environment.afterSync(container)
        return synced
    }

    #if DEBUG
    /// `-runBackgroundSync`: the refresh's work right after launch, with no BGTask — the Simulator
    /// never runs one (D7). The E2E kit reads the server's sync line and this process's
    /// `refresh submit resubmit: BGTaskSchedulerErrorDomain/1` (Unavailable, the Simulator's
    /// answer; NotPermitted, 3, would mean the plist and the identifier disagree).
    @MainActor
    static func runIfRequestedByLaunchArgument() {
        guard CommandLine.arguments.contains("-runBackgroundSync") else { return }
        logger.notice("background sync: started by -runBackgroundSync")
        Task { @MainActor in
            _ = await handle()
        }
    }
    #endif
}

/// What `BackgroundSync.start` needs of a task: a `BGTask`, or a test's fake (BGTask has no public
/// initializer).
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: BackgroundTaskHandle {}

/// The task is completed once: the work and the expiration handler race for it, from different
/// threads, and the first to claim it completes it.
final class CompletionClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

// MARK: - Submitting

/// Asks for the next background refresh — the only place that does (D5). The system keeps at most
/// one pending refresh request and a new submit replaces it, so submitting often costs nothing.
///
/// Reasons, each logged as `refresh submit <reason>: ok | <domain>/<code>` at notice level, the
/// line the E2E kit asserts (the Simulator answers `BGTaskSchedulerErrorDomain/1`, Unavailable):
/// - `scene-background`: the app's last scene went to the background with a session stored
///   (StrideApp). A widget check-in made after that is covered by this pending request: whether a
///   WidgetKit extension may submit is unverified, and only the app is launched for the task.
/// - `check-in`: one made in this process — Today, Siri, a reminder's action (`CheckInEffects`).
/// - `resubmit`: the refresh handler, before it completes (`BackgroundSync.handle`).
///
/// Errors are logged, never shown: Background App Refresh switched off, Low Power Mode and the
/// Simulator all refuse, and the foreground sync still delivers.
enum BackgroundRefresh {
    enum Reason: String, Sendable {
        case sceneBackground = "scene-background"
        case checkIn = "check-in"
        case resubmit = "resubmit"
    }

    /// Hands one request to the system and throws its refusal. Injected, so the hosted tests can
    /// see each submit without one ever reaching the scheduler.
    struct Submitter: Sendable {
        var submit: @Sendable (Reason) async throws -> Void

        /// The scheduler's own. No `earliestBeginDate`: the request exists to deliver a check-in
        /// soon, and the system decides when anyway. iOS 27 deprecates the synchronous submit for
        /// an async one that "must not be called from the main thread" (BGTaskScheduler.h) —
        /// `schedule` always calls this from a detached task.
        static let live = Submitter { _ in
            let request = BGAppRefreshTaskRequest(identifier: BackgroundSync.taskIdentifier)
            if #available(iOS 27, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
        }
    }

    /// Submits off the main actor, in a detached task, and returns it; its value is the line that
    /// was logged. Callers on the main actor need not wait — the refresh handler does, so its
    /// resubmit is in before it completes the task.
    @discardableResult
    static func schedule(reason: Reason, submitter: Submitter = .live) -> Task<String, Never> {
        Task.detached(priority: .utility) {
            await submit(reason, with: submitter)
        }
    }

    /// `schedule` when a session is stored — the only "signed in" a background sync needs
    /// (`BackgroundSync.handle` says why it is never `isLoggedIn`). Signed out, a refresh would
    /// launch the app to sync nothing.
    @MainActor
    static func scheduleIfSignedIn(reason: Reason) {
        guard AuthService.shared.hasStoredSession else { return }
        schedule(reason: reason)
    }

    /// Not isolated to any actor: it runs inside `schedule`'s detached task.
    private static func submit(_ reason: Reason, with submitter: Submitter) async -> String {
        let answer: String
        do {
            try await submitter.submit(reason)
            answer = "ok"
        } catch {
            let error = error as NSError
            answer = "\(error.domain)/\(error.code)"
        }
        let line = "refresh submit \(reason.rawValue): \(answer)"
        BackgroundSync.logger.notice("\(line, privacy: .public)")
        return line
    }
}

#endif
