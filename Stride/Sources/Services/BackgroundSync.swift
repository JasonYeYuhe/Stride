import Foundation
import SwiftData
import os.log
#if os(iOS)
import BackgroundTasks
import UIKit
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
    /// - the work, with its result (`handle()`, whose resubmit went in before its run);
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
    /// the resubmit that keeps the chain going — at most one refresh is pending, and it is used up
    /// by running — then the run over the store this launch opened.
    @MainActor
    static func handle() async -> Bool {
        await handle(container: SharedModelContainer.opened, environment: .live)
    }

    /// `handle()` over what it is given, for the hosted tests.
    ///
    /// - **The resubmit goes in first, before the run**, as Apple's own refresh handlers schedule
    ///   the next refresh first. Until the W3 review it went in after the run, and a run that
    ///   expired never got there in time: the expiration handler completes the task, the system
    ///   may suspend the process the moment it is, and the cancelled run still had to unwind
    ///   through the engine before reaching the resubmit — so the chain could end on exactly the
    ///   slow network a refresh is most needed on, leaving every later widget check-in unsent until
    ///   the app was next opened. A submit replaces the pending request, so going first costs at
    ///   most one refresh that finds nothing new.
    /// - **Only while a session is stored:** "signed in" here means a token in the Keychain
    ///   (`hasStoredSession`), never `isLoggedIn`. A background launch's session check can fail
    ///   offline and leave `currentUser` nil while every sync still runs from the remembered
    ///   account (design review, "bg-launch-leaves-currentUser-nil"); keyed on `isLoggedIn`, the
    ///   first offline refresh would end the chain. Read before the run, so a run that finds the
    ///   session gone (and deletes the token) has already asked for one more refresh; that one
    ///   syncs nothing and asks for no other.
    /// - **Its answer is waited for after the run, for at most `answerWait`**, before the task is
    ///   completed. A run that ends at once — inside the backoff window, or with the store not
    ///   open — would otherwise complete the task while the detached submit may not yet have
    ///   reached the scheduler. Bounded, because iOS 27's async submit may answer "after an
    ///   arbitrary amount of delay" (BGTaskScheduler.h): unbounded, a slow answer would hold a
    ///   finished run open until expiry, which reports it as failed. Not waited for at all once
    ///   the task has expired: the expiration handler has already completed it.
    @MainActor
    static func handle(container: ModelContainer?, environment: Environment,
                       answerWait: Duration = .seconds(2)) async -> Bool {
        let resubmit = environment.sessionStored()
            ? BackgroundRefresh.schedule(reason: .resubmit, submitter: environment.submitter)
            : nil
        var synced = false
        if let container {
            synced = await run(container: container, environment: environment)
        } else {
            // The launch could not open the store (it reported that itself). Nothing to sync from;
            // a later launch may open it, so the chain is still kept.
            logger.error("background sync: the store is not open")
        }
        if let resubmit, !Task.isCancelled {
            await waitForAnswer(resubmit, upTo: answerWait)
        }
        let result = synced ? "synced" : "not synced"
        logger.notice("background sync: \(result, privacy: .public)")
        return synced
    }

    /// Returns once `submit` has answered or `limit` has passed, whichever comes first. A submit
    /// that never answers leaves its waiter behind, ending when the submit does.
    private static func waitForAnswer(_ submit: Task<String, Never>, upTo limit: Duration) async {
        let first = CompletionClaim()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task.detached {
                _ = await submit.value
                if first.claim() { done.resume() }
            }
            Task.detached {
                try? await Task.sleep(for: limit)
                if first.claim() { done.resume() }
            }
        }
    }

    // MARK: - The run

    /// What a run reaches outside itself, so a hosted test reaches none of the host app's.
    ///
    /// After the sync comes what a scene-less background launch never attaches — StrideApp's
    /// launch `.task`, its didSave observer and its foreground hooks all hang off a window — in
    /// two parts, because a run can be cancelled (its task expired) after a sync that pulled:
    /// - `refreshAfterSync`, synchronous and cheap, runs whenever the sync returned. A pull the
    ///   widget never hears of leaves it drawing the old day, and the widget's toggle acts on the
    ///   store, not on what it shows: a tap on a habit another device checked off then DELETES
    ///   that check-in and queues its tombstone for every device (verification, major). Until the
    ///   fix pass the reload sat behind the cancellation guard with the rest, so a task that
    ///   expired just after a pull skipped it.
    /// - `afterSync`, awaited, only while not cancelled: the task is completed already otherwise.
    struct Environment {
        var syncService: @MainActor () -> SyncService
        /// The widgets' timelines, then `refreshAfterDataChange` — the badge's quick set, the
        /// snoozes and banners of what was checked in elsewhere (D3, D4).
        var refreshAfterSync: @MainActor (ModelContainer) -> Void
        /// The reminders, replaced whole (a pull can change a habit's kind, days or time), then
        /// the badge, awaited.
        var afterSync: @MainActor (ModelContainer) async -> Void
        /// Whether a session is stored, for the resubmit (`handle`).
        var sessionStored: @MainActor () -> Bool
        /// The scheduler, for the resubmit.
        var submitter: BackgroundRefresh.Submitter

        /// The app's own: the refresh's, and since the fix pass a reminder action's sync too
        /// (`NotificationActionHandler.Environment.live`).
        static var live: Environment {
            Environment(
                syncService: { SyncService.shared },
                refreshAfterSync: { container in
                    WidgetCenter.shared.reloadAllTimelines()
                    NotificationService.shared.refreshAfterDataChange(modelContainer: container)
                },
                afterSync: { container in
                    let notifications = NotificationService.shared
                    // Every reminder is replaced whole (D4), and the prune — awaited, the process
                    // may be suspended right after — removes what no habit wants any more. Only
                    // while the app is not active: a habit sheet can be saving then, and a prune
                    // computed meanwhile finds the sheet's own reminder, added a moment later,
                    // missing from its keep set and removes it (`scheduleAllHabitReminders`). A
                    // refresh runs in the background, but a reminder's action can be answered with
                    // Stride frontmost (an older banner from Notification Center) — and the user
                    // can bring Stride forward during either run. The launch pass prunes later.
                    if UIApplication.shared.applicationState == .active {
                        notifications.scheduleAllHabitReminders(modelContainer: container)
                    } else {
                        await notifications.rescheduleAllHabitRemindersAndWait(modelContainer: container)
                    }
                    // The badge, awaited: the refresh pass sets it fire-and-forget.
                    await notifications.updateBadgeAndWait(modelContainer: container)
                },
                sessionStored: { AuthService.shared.hasStoredSession },
                submitter: .live)
        }
    }

    /// One background run over `container`: a `.background` sync on its `mainContext`, then
    /// `refreshAfterSync` and `afterSync`. True when the sync ran to the end. The refresh's work,
    /// and on iOS a reminder action's sync (`NotificationActionHandler`), whose launch is just as
    /// scene-less.
    ///
    /// It first waits out a sync already in flight — one this process started before it was
    /// suspended, say — and then runs its own: a run in flight planned its push before what this
    /// run is for was written, and SyncService turns a second caller away rather than queueing
    /// it. `.background`: skipped inside the owner's backoff window, and a run iOS cuts short
    /// leaves no window and no error behind (D5).
    ///
    /// Cancelled (the task expired), it stops after the sync's current step. If the sync returned,
    /// the widgets and the refresh pass still go — synchronous, so done before the process can be
    /// suspended — and nothing awaited does: the task has already been completed.
    @MainActor
    static func run(container: ModelContainer, environment: Environment = .live) async -> Bool {
        let service = environment.syncService()
        await service.waitUntilIdle()
        guard !Task.isCancelled else { return false }
        let synced = await service.sync(context: container.mainContext, trigger: .background)
        environment.refreshAfterSync(container)
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
/// threads, and the first to claim it completes it. Also the once-only resume of
/// `waitForAnswer`, whose answer and deadline race the same way.
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
/// - `resubmit`: the refresh handler, first thing, before its run (`BackgroundSync.handle`).
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
    /// was logged. Callers on the main actor need not wait — the refresh handler does, for a
    /// bounded time after its run, so its resubmit is in before it completes the task.
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
