import XCTest
import SwiftData
import BackgroundTasks
@testable import Stride

/// Background sync (RELEASE-1.4.0.md D5) as far as anything can check it short of a device: iOS
/// never runs a BGAppRefreshTask on the Simulator, and refuses every submit there (D7). So:
/// - the host's wiring — StrideApp.init registered once and was allowed to, and the built plist
///   permits the code's identifier and the `fetch` mode;
/// - the one submit entry point, through an injected submitter (and once through the real
///   scheduler, for the Simulator's answer the E2E kit asserts);
/// - the task shim's completion rule, with a fake task (BGTask cannot be constructed);
/// - `run(container:)` through the real SyncService over a stub server and an in-memory store,
///   cut short included;
/// - the foreground after a background launch whose session check failed.
///
/// Nothing here reaches the host app's store, Keychain item, defaults, notification store,
/// widgets or server: the run's environment is the test's, and `handle()` — the shipping work,
/// over `SharedModelContainer.opened` and `SyncService.shared` — is never called.
@MainActor
final class BackgroundSyncTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var queue: SyncDeletionQueue!
    private var recovery: ScratchRecoveryLog!

    private let owner = SyncSession.accountA.account

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        tokens = InMemoryTokenStore(SyncSession.accountA.token)
        local = ScratchDefaults("background.local")
        appGroup = ScratchDefaults("background.appGroup")
        queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        recovery = ScratchRecoveryLog()
    }

    override func tearDown() {
        server.stop()
        local.remove()
        appGroup.remove()
        recovery.remove()
        recovery = nil
        queue = nil
        appGroup = nil
        local = nil
        tokens = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// What a run did after its sync.
    private final class Recorder {
        var afterSyncs = 0
    }

    /// `sessions`: nil = account A, signed in.
    private func makeSync(sessions: (any SyncSessionSource)? = nil,
                          afterSyncRequest: APISyncTransport.Hook? = nil) -> SyncService {
        SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults, deletionQueue: queue,
                    sessions: sessions ?? FakeSyncSessions(.accountA), recoveryLog: recovery.log,
                    afterSyncRequest: afterSyncRequest)
    }

    /// The run's environment over the test's SyncService, with the after-sync work recorded.
    private func environment(_ sync: SyncService, _ recorder: Recorder) -> BackgroundSync.Environment {
        BackgroundSync.Environment(syncService: { sync }, afterSync: { _ in recorder.afterSyncs += 1 })
    }

    /// A store owned by account A with a live cursor: the next sync pushes first, then pulls.
    private func seedOwnerAndCursor() {
        SyncOwnerStore(defaults: local.defaults).set(SyncOwner(owner))
        SyncDefaultsCursorStore(defaults: local.defaults)
            .setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400)), for: owner.id)
    }

    private func stubHappyServer() {
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))
    }

    private var backoffStore: SyncBackoffStore { SyncBackoffStore(defaults: local.defaults) }
    private var syncPaths: [String] { server.paths.filter { $0.hasPrefix("/v1/sync/") } }
    private var pushes: [StubServer.Request] { server.requests.filter { $0.path == "/v1/sync/push" } }

    @discardableResult
    private func insertHabit(_ name: String) throws -> Habit {
        let habit = Habit(name: name)
        context.insert(habit)
        try context.save()
        return habit
    }

    private func pushedHabitIDs(_ push: StubServer.Request?) -> [String] {
        ((push?.json?["habits"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }

    /// Polls `condition` on the main actor for up to 5 s.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Host wiring

    /// StrideApp.init registered the launch handler, and the system accepted it — it refuses an
    /// identifier the plist does not permit. A second call answers from the first: the system
    /// kills the app on a second registration, and this suite runs inside the app.
    func testTheHostRegisteredOnceAndASecondCallIsANoOp() {
        XCTAssertEqual(BackgroundSync.registration, true, "registered in StrideApp.init, and permitted")
        XCTAssertTrue(BackgroundSync.register(), "the first call's answer — no second registration")
        XCTAssertEqual(BackgroundSync.registration, true)
    }

    /// The built app's plist — Stride/Stride-Info.plist merged into the generated one — permits
    /// the identifier the code registers and submits, and has the `fetch` mode. A typo on either
    /// side ships a refresh that never runs, with no error anywhere but the log. And the merge
    /// kept the generated keys (the partial plist is merged, not used instead).
    func testThePlistPermitsTheCodesIdentifierAndTheFetchMode() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["BGTaskSchedulerPermittedIdentifiers"] as? [String], [BackgroundSync.taskIdentifier])
        XCTAssertTrue((info["UIBackgroundModes"] as? [String])?.contains("fetch") == true,
                      "\(String(describing: info["UIBackgroundModes"]))")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Stride")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "yyh.stride.habittracker")
        XCTAssertNotNil(info["UIApplicationSceneManifest"])
    }

    // MARK: - Submitting

    /// `Thread.isMainThread`, from a synchronous function: it is unavailable in an async context.
    private nonisolated static func isOnMainThread() -> Bool { Thread.isMainThread }

    /// The one entry point hands the reason to the submitter, off the main thread (iOS 27's async
    /// submit must not be called there), and logs the answer in the form the E2E kit reads:
    /// `ok`, or the refusal's domain and code.
    func testScheduleHandsTheReasonToTheSubmitterOffTheMainThreadAndLogsTheAnswer() async {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [(BackgroundRefresh.Reason, Bool)] = []
            func append(_ reason: BackgroundRefresh.Reason, onMain: Bool) { lock.withLock { recorded.append((reason, onMain)) } }
            var reasons: [BackgroundRefresh.Reason] { lock.withLock { recorded.map(\.0) } }
            var onMain: [Bool] { lock.withLock { recorded.map(\.1) } }
        }
        let calls = Calls()

        let ok = await BackgroundRefresh.schedule(reason: .checkIn, submitter: .init { reason in
            calls.append(reason, onMain: Self.isOnMainThread())
        }).value
        let refused = await BackgroundRefresh.schedule(reason: .sceneBackground, submitter: .init { reason in
            calls.append(reason, onMain: Self.isOnMainThread())
            throw NSError(domain: BGTaskScheduler.errorDomain, code: 1)
        }).value
        let resubmitted = await BackgroundRefresh.schedule(reason: .resubmit, submitter: .init { reason in
            calls.append(reason, onMain: Self.isOnMainThread())
        }).value

        XCTAssertEqual(ok, "refresh submit check-in: ok")
        XCTAssertEqual(refused, "refresh submit scene-background: BGTaskSchedulerErrorDomain/1")
        XCTAssertEqual(resubmitted, "refresh submit resubmit: ok")
        XCTAssertEqual(calls.reasons, [.checkIn, .sceneBackground, .resubmit])
        XCTAssertEqual(calls.onMain, [false, false, false])
    }

    /// The real scheduler, once: the Simulator refuses as Unavailable (1) — "the app is running on
    /// Simulator", BGTaskScheduler.h — the answer the E2E asserts. NotPermitted (3) would mean the
    /// identifier or the mode is missing from the plist. Never run on a device, where it would
    /// leave a pending refresh for the host app.
    func testTheSimulatorAnswersARealSubmitWithUnavailable() async throws {
        #if targetEnvironment(simulator)
        let line = await BackgroundRefresh.schedule(reason: .resubmit).value
        XCTAssertEqual(line, "refresh submit resubmit: BGTaskSchedulerErrorDomain/1")
        #else
        throw XCTSkip("a real submit on a device would schedule a refresh for the host app")
        #endif
    }

    // MARK: - The task shim

    /// A stand-in for the system's BGAppRefreshTask. The expiration handler may be called from any
    /// thread, so its state is locked.
    private final class FakeTask: BackgroundTaskHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?
        private var recorded: [Bool] = []

        var expirationHandler: (() -> Void)? {
            get { lock.withLock { handler } }
            set { lock.withLock { handler = newValue } }
        }
        var completions: [Bool] { lock.withLock { recorded } }
        func setTaskCompleted(success: Bool) { lock.withLock { recorded.append(success) } }

        /// As the system does when the time is up: on a queue of its own.
        func expire() async {
            let handler = expirationHandler
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    handler?()
                    done.resume()
                }
            }
        }
    }

    /// The work completes the task with its result, once; an expiry arriving after that completes
    /// nothing more.
    func testTheWorkCompletesTheTaskOnce() async throws {
        let task = FakeTask()

        BackgroundSync.start(task) { true }
        XCTAssertNotNil(task.expirationHandler, "set before the work could begin")
        try await waitUntil("the work's completion") { !task.completions.isEmpty }
        await task.expire()

        XCTAssertEqual(task.completions, [true])
    }

    /// Expiry completes the task at once with false, from the system's queue and without waiting
    /// for the main actor, and cancels the work; the work, when it ends, completes nothing more.
    func testExpiryCompletesTheTaskAtOnceAndCancelsTheWork() async throws {
        let task = FakeTask()
        final class Work { var sawCancel = false; var ended = false }
        let work = Work()

        BackgroundSync.start(task) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            work.sawCancel = Task.isCancelled
            work.ended = true
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(task.completions.isEmpty, "precondition: the work is still running")

        await task.expire()
        XCTAssertEqual(task.completions, [false], "completed by the expiration handler itself")

        try await waitUntil("the cancelled work to end") { work.ended }
        XCTAssertTrue(work.sawCancel)
        XCTAssertEqual(task.completions, [false], "the work's own completion lost the claim")
    }

    // MARK: - The run

    /// A run is a `.background` sync — the push of what was checked in meanwhile, then the pull —
    /// followed by the work a scene-less launch never attaches (reminders, badge, widgets).
    func testARunPushesAndPullsThenDoesTheAfterSyncWork() async throws {
        seedOwnerAndCursor()
        let habit = try insertHabit("Read")
        stubHappyServer()
        let sync = makeSync()
        let recorder = Recorder()

        let ran = await BackgroundSync.run(container: container, environment: environment(sync, recorder))

        XCTAssertTrue(ran)
        XCTAssertEqual(syncPaths, ["/v1/sync/push", "/v1/sync/pull"])
        XCTAssertEqual(pushedHabitIDs(pushes.first), [habit.id.uuidString])
        XCTAssertEqual(recorder.afterSyncs, 1)
        XCTAssertNil(sync.syncError)
    }

    /// The run's sync is `.background`, not a user's: inside the owner's backoff window (a paused
    /// server's Retry-After) it sends nothing. The reminders, badge and widgets are refreshed all
    /// the same — a day may have changed since the app last ran.
    func testARunInsideTheBackoffWindowSendsNothingAndStillRefreshes() async throws {
        seedOwnerAndCursor()
        backoffStore.recordFailure(.serverAsked(seconds: 600, paused: true), for: owner.id)
        try insertHabit("Read")
        stubHappyServer()
        let sync = makeSync()
        let recorder = Recorder()

        let ran = await BackgroundSync.run(container: container, environment: environment(sync, recorder))

        XCTAssertFalse(ran)
        XCTAssertTrue(server.requests.isEmpty, "the window holds for a background run")
        XCTAssertEqual(recorder.afterSyncs, 1)
    }

    /// A refresh that finds a sync in flight — one this process started before it was suspended —
    /// waits it out and runs its own: the run in flight planned its push before the check-in this
    /// refresh is for, and SyncService turns a second caller away rather than queueing it.
    func testARunWaitsOutASyncInFlightAndPushesWhatCameAfter() async throws {
        seedOwnerAndCursor()
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        let pull = SyncStubBodies.pull()
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .ok(pull)
        }
        try insertHabit("Read")
        let sync = makeSync()
        let recorder = Recorder()

        let inFlight = Task { await sync.sync(context: context) }
        try await waitUntil("the first sync's pull") { server.paths.contains("/v1/sync/pull") }
        XCTAssertTrue(sync.isSyncing)
        // Saved through a context of its own, as a check-in from Siri, a reminder or the widget is.
        let late = Habit(name: "Walk")
        let elsewhere = ModelContext(container)
        elsewhere.insert(late)
        try elsewhere.save()

        let ran = await BackgroundSync.run(container: container, environment: environment(sync, recorder))
        let firstRan = await inFlight.value

        XCTAssertTrue(firstRan)
        XCTAssertTrue(ran, "its own run, after the first one ended")
        XCTAssertEqual(pushes.count, 2, "the in-flight run's push, then the refresh's own")
        XCTAssertEqual(pushedHabitIDs(pushes.last), [late.id.uuidString])
        XCTAssertEqual(recorder.afterSyncs, 1)
    }

    /// iOS cuts the refresh short: the task's work is cancelled mid-run, so the next request gets
    /// no answer. The run stops — no after-sync work, the task is already completed — and leaves
    /// no backoff window and no `syncError`: a window would turn away the foreground sync of a user
    /// who unlocks and opens the app a minute later, and the footer would say "cancelled" to
    /// someone who never asked for a sync (design review, "background-trigger-silent-default").
    /// That foreground sync goes at once.
    func testACancelledRunLeavesNoWindowAndNoErrorAndTheNextAutomaticSyncGoes() async throws {
        seedOwnerAndCursor()
        try insertHabit("Read")
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        // What a cancelled URLSession request reports, should the pull reach the server at all.
        server.on("GET", "/v1/sync/pull") { _ in throw URLError(.cancelled) }
        final class Cut { var done = false }
        let cut = Cut()
        // After the push is answered — mid-run — the task running it is cancelled, as the
        // expiration handler's `work.cancel()` does.
        let sync = makeSync(afterSyncRequest: { _, _ in
            guard !cut.done else { return }
            cut.done = true
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let recorder = Recorder()

        let run = Task { await BackgroundSync.run(container: container, environment: environment(sync, recorder)) }
        let ran = await run.value

        XCTAssertTrue(cut.done, "precondition: the run was cut mid-way")
        XCTAssertTrue(run.isCancelled)
        XCTAssertFalse(ran)
        XCTAssertEqual(recorder.afterSyncs, 0, "a cut-short run stops")
        XCTAssertFalse(sync.isSyncing)
        XCTAssertNil(sync.syncError, "no footer for a run iOS cut short")
        XCTAssertNil(sync.backoff)
        XCTAssertNil(backoffStore.state(for: owner.id), "no window to turn the foreground sync away")

        stubHappyServer()
        let before = server.requests.count
        let foreground = await sync.sync(context: context, trigger: .automatic)
        XCTAssertTrue(foreground, "the next automatic sync goes")
        XCTAssertGreaterThan(server.requests.count, before)
    }

    // MARK: - The session after a background launch

    /// The review's case (design review, "bg-launch-leaves-currentUser-nil"). A background launch
    /// creates AuthService, and its one session check fails offline: no user, the token and its
    /// remembered account still stored. The background run syncs anyway — from the remembered
    /// account. The user then opens the app, which resumes this same process: the foreground pass
    /// asks the server again, now reachable, and ends signed in, and its own sync goes. 1.3.x's
    /// `guard isLoggedIn` turned that sync, and every later one, away for the life of the process.
    func testTheForegroundAfterABackgroundLaunchWhoseCheckFailedSignsInAndSyncs() async throws {
        local.defaults.set(["id": owner.id, "email": owner.email], forKey: AuthService.sessionAccountKey)
        final class Online: @unchecked Sendable {
            private let lock = NSLock()
            private var reachable = false
            var isReachable: Bool {
                get { lock.withLock { reachable } }
                set { lock.withLock { reachable = newValue } }
            }
        }
        let online = Online()
        server.on("GET", "/v1/auth/session") { _ in
            guard online.isReachable else { throw URLError(.notConnectedToInternet) }
            return .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#)
        }
        stubHappyServer()
        seedOwnerAndCursor()
        let api = server.makeClient(tokenStore: tokens)
        let auth = AuthService(api: api, tokenStore: tokens, defaults: local.defaults,
                               onSignOut: {}, onSignIn: {}, onAccountDeleted: { _ in }, reauthRequested: { false })
        let sync = makeSync(sessions: auth)

        // The background launch: the check fails, then the refresh runs.
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isSessionRestored)
        XCTAssertFalse(auth.isLoggedIn, "precondition: the launch check failed offline")
        let first = try insertHabit("Read")
        let recorder = Recorder()
        let ran = await BackgroundSync.run(container: container, environment: environment(sync, recorder))
        XCTAssertTrue(ran, "a background run syncs from the remembered account")
        XCTAssertEqual(pushedHabitIDs(pushes.last), [first.id.uuidString])
        XCTAssertFalse(auth.isLoggedIn, "nothing in the run loads the user")

        // The user opens the app; the network is back.
        online.isReachable = true
        let second = try insertHabit("Walk")
        var reschedules = 0
        await StrideApp.syncIfLoggedIn(container, auth: auth, sync: sync) { _ in reschedules += 1 }

        XCTAssertTrue(auth.isLoggedIn, "the foreground rechecked the stored session")
        XCTAssertEqual(server.paths.filter { $0 == "/v1/auth/session" }.count, 2, "the launch check, then the recheck")
        XCTAssertEqual(pushes.count, 2, "the foreground's own sync went")
        XCTAssertEqual(pushedHabitIDs(pushes.last), [second.id.uuidString])
        XCTAssertEqual(reschedules, 1, "a sync that ran to the end reschedules the reminders")
        XCTAssertNil(sync.syncError)
    }

    /// The foreground pass still syncs when the recheck gets no answer: a stored session and its
    /// account are all a sync needs (SyncService resolves the rest), not a loaded user.
    func testTheForegroundSyncsWithAStoredSessionEvenWhenTheRecheckGetsNoAnswer() async throws {
        local.defaults.set(["id": owner.id, "email": owner.email], forKey: AuthService.sessionAccountKey)
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.timedOut) }
        stubHappyServer()
        seedOwnerAndCursor()
        let auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens, defaults: local.defaults,
                               onSignOut: {}, onSignIn: {}, onAccountDeleted: { _ in }, reauthRequested: { false })
        let sync = makeSync(sessions: auth)
        let habit = try insertHabit("Read")

        await StrideApp.syncIfLoggedIn(container, auth: auth, sync: sync) { _ in }

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertEqual(server.paths.filter { $0 == "/v1/auth/session" }.count, 2, "the launch check, then the recheck")
        XCTAssertEqual(pushedHabitIDs(pushes.last), [habit.id.uuidString])
    }

    /// Signed out — no token — the foreground pass asks nothing and syncs nothing.
    func testTheForegroundDoesNothingWhenNoSessionIsStored() async {
        tokens.delete()
        stubHappyServer()
        let auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens, defaults: local.defaults,
                               onSignOut: {}, onSignIn: {}, onAccountDeleted: { _ in }, reauthRequested: { false })
        let sync = makeSync(sessions: auth)

        await StrideApp.syncIfLoggedIn(container, auth: auth, sync: sync) { _ in XCTFail("no sync ran") }

        XCTAssertTrue(server.requests.isEmpty)
    }
}
