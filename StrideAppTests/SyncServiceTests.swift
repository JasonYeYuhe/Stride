import XCTest
import SwiftData
@testable import Stride

/// `SyncService.sync` end to end against a stubbed server: the real service, the real engine
/// (Shared/SyncEngine.swift), the real APIClient and reconciler, an in-memory store (the
/// SyncReconcileTests pattern), and a scratch defaults suite for the cursors, the owner and the
/// deletion queues.
///
/// StrideTests runs the engine against a fake server model; what only this file can prove is the
/// app's half: the transport over APIClient (the exact chunk bytes, the run's captured token,
/// the client header, the answers' status and `Retry-After`), the owner gate, the run binding
/// through a real sign-out and sign-in, and the UI state Settings shows.
@MainActor
final class SyncServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var queue: SyncDeletionQueue!
    private var sessions: FakeSyncSessions!
    private var sync: SyncService!

    private let owner = SyncSession.accountA.account.id
    private var cursors: SyncDefaultsCursorStore { SyncDefaultsCursorStore(defaults: local.defaults) }
    private var owners: SyncOwnerStore { SyncOwnerStore(defaults: local.defaults) }
    /// Inside the engine's cursor lifetime whatever the clock says, so a seeded cursor is used,
    /// not expired.
    private let recentCursor = SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400))

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        tokens = InMemoryTokenStore(SyncSession.accountA.token)
        local = ScratchDefaults("sync.local")
        appGroup = ScratchDefaults("sync.appGroup")
        queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        sessions = FakeSyncSessions(.accountA)
        sync = makeSync()
    }

    override func tearDown() {
        server.stop()
        local.remove()
        appGroup.remove()
        sync = nil
        sessions = nil
        queue = nil
        tokens = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSync(sessions: (any SyncSessionSource)? = nil, bounds: SyncPushBounds = .standard,
                          afterSyncRequest: APISyncTransport.Hook? = nil) -> SyncService {
        SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults, deletionQueue: queue,
                    sessions: sessions ?? self.sessions, bounds: bounds, afterSyncRequest: afterSyncRequest)
    }

    /// A store owned by account A with a live cursor: the next sync pushes first.
    private func seedOwnerAndCursor() {
        owners.set(SyncOwner(SyncSession.accountA.account))
        cursors.setCursor(recentCursor, for: owner)
    }

    private func stubHappyServer(serverTime: String = "2026-09-26T10:00:00.000Z") {
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull(serverTime: serverTime)))
    }

    private var syncRequests: [StubServer.Request] { server.requests.filter { $0.path.hasPrefix("/v1/sync/") } }
    private var syncPaths: [String] { syncRequests.map(\.path) }

    private func waitForRequest(_ path: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.paths.contains(path) {
            guard ContinuousClock.now < deadline else { return XCTFail("no request to \(path)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Ordering and delivery

    /// A device with no cursor full-pulls first (settling deletions before anything is sent),
    /// then pushes, then pulls on the new cursor. The pushed habit is acknowledged at the stamp
    /// it was sent with, so it is not pending — and a second sync with no edits pushes nothing
    /// (acceptance: "a second sync with no edits pushes 0/0/0").
    func testFirstSyncFullPullsPushesPullsAndASecondSyncPushesNothing() async throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        let echo = SyncStubBodies.pull(habits: [SyncStubBodies.habit(habit)])
        let empty = SyncStubBodies.pull()
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        // The full pull comes before the push, so the server has nothing yet; the pull after the
        // push returns what the push sent, as the real server would.
        server.on("GET", "/v1/sync/pull") { request in .ok(request.query["since"] == nil ? empty : echo) }

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        XCTAssertNil(sync.syncError)
        XCTAssertNotNil(sync.lastSyncTime)
        XCTAssertEqual(syncPaths, ["/v1/sync/pull", "/v1/sync/push", "/v1/sync/pull"])
        let requests = syncRequests
        guard requests.count == 3 else { return XCTFail("\(requests.count) requests") }
        XCTAssertNil(requests[0].query["since"], "no cursor: a full pull first")
        XCTAssertEqual(requests[2].query["since"], "2026-09-26T09:59:00.000Z")
        let pushed = try XCTUnwrap(requests[1].json?["habits"] as? [[String: Any]])
        XCTAssertEqual(pushed.map { $0["id"] as? String }, [habit.id.uuidString])
        // 1.3.1 sends millisecond stamps; the server's LWW guard compares them.
        let updatedAt = try XCTUnwrap(pushed.first?["updatedAt"] as? String)
        XCTAssertNotNil(updatedAt.range(of: #"\.\d{3}Z$"#, options: .regularExpression), updatedAt)
        for request in requests {
            XCTAssertEqual(request.authorization, "Bearer tok-123", request.path)
            XCTAssertNotNil(request.header("X-Stride-Client"), request.path)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id],
                       "the never-delivered habit survived the full pull before its push")
        XCTAssertFalse(habit.isPending, "acknowledged")
        XCTAssertEqual(habit.syncedAt, habit.stamp)
        XCTAssertEqual(owners.owner?.id, owner, "no owner: the signed-in account adopts the store")

        let second = await sync.sync(context: context)

        XCTAssertTrue(second)
        XCTAssertEqual(syncPaths.count, 4)
        XCTAssertEqual(syncPaths.last, "/v1/sync/pull", "nothing pending: no push request at all")
    }

    /// One tap → the next push carries exactly that entry and no habit (acceptance). 1.3.0 sent
    /// every row of the store on every sync.
    func testOneEditedCheckInPushesExactlyThatEntry() async throws {
        let habit = Habit(name: "Read")
        let record = HabitRecord(date: HabitCalendar.dayKey(for: Date()))
        habit.records = [record]
        context.insert(habit)
        try context.save()
        stubHappyServer()
        await sync.sync(context: context)
        XCTAssertFalse(record.isPending)

        record.value = 2
        record.touch()
        try context.save()
        await sync.sync(context: context)

        let lastPush = try XCTUnwrap(syncRequests.last { $0.path == "/v1/sync/push" }?.json)
        XCTAssertEqual((lastPush["entries"] as? [[String: Any]])?.map { $0["id"] as? String }, [record.id.uuidString])
        XCTAssertEqual((lastPush["habits"] as? [Any])?.count, 0)
        XCTAssertEqual((lastPush["groups"] as? [Any])?.count, 0)
        XCTAssertFalse(record.isPending)
    }

    /// A push that fails — offline, 5xx — must leave everything as it was: the deletions still
    /// queued (until 1.2.3 the queue was cleared before the push, so one failed push lost the
    /// deletion and the habit came back on every other device), the cursor where it was, the
    /// rows pending, and no pull.
    func testFailedPushKeepsTheQueueAndTheCursorAndDoesNotPull() async {
        seedOwnerAndCursor()
        queue.trackHabit("habit-deleted-offline")
        server.on("POST", "/v1/sync/push", respond: .init(status: 500, body: #"{"error":"Internal error"}"#))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))

        let ran = await sync.sync(context: context)

        XCTAssertFalse(ran)
        XCTAssertEqual(sync.syncError, "Internal error")
        XCTAssertEqual(syncPaths, ["/v1/sync/push"])
        XCTAssertEqual(queue.pending().habits, ["habit-deleted-offline"])
        XCTAssertEqual(cursors.cursor(for: owner), recentCursor)
        XCTAssertNil(sync.lastSyncTime)
        XCTAssertFalse(sync.isSyncing, "a failed sync must not leave the service stuck")
    }

    /// A deletion queued while the push is in flight was not in that push, so acknowledging it
    /// would lose it for good. Only the ids actually sent may be removed.
    func testSuccessfulSyncAcknowledgesOnlyTheIdsItSent() async throws {
        seedOwnerAndCursor()
        queue.trackHabit("sent")
        queue.trackSharedEntry("sent-by-widget")
        let queue = self.queue!
        server.on("POST", "/v1/sync/push") { _ in
            // The user deletes another habit while this request is on the wire.
            queue.trackHabit("deleted-during-push")
            return .ok(SyncStubBodies.pushOK)
        }
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))

        await sync.sync(context: context)

        XCTAssertNil(sync.syncError)
        let body = try XCTUnwrap(syncRequests.first?.json)
        XCTAssertEqual(body["deletedHabitIds"] as? [String], ["sent"])
        XCTAssertEqual(body["deletedEntryIds"] as? [String], ["sent-by-widget"])
        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch(habits: ["deleted-during-push"]))
    }

    // MARK: - Cursor

    /// The cursor is the server's clock minus the 60 s overlap (never this device's clock),
    /// stored per owner, and the next pull sends it as a real query item — not a path component,
    /// which percent-encoded the `?` and 404'd every incremental pull once.
    func testCursorIsServerTimeMinusOverlapPerOwnerAndIsSentOnTheNextPull() async throws {
        stubHappyServer(serverTime: "2026-09-26T10:00:00.000Z")

        await sync.sync(context: context)
        XCTAssertNil(sync.syncError)
        // Counts guarded before indexing: an out-of-range index crashes the HOST app (Stride.app),
        // not just this test.
        guard syncRequests.count == 2 else { return XCTFail("first sync: \(syncPaths)") }
        XCTAssertNil(syncRequests[0].query["since"], "no cursor yet: a full pull")
        XCTAssertEqual(cursors.cursor(for: owner), "2026-09-26T09:59:00.000Z")
        XCTAssertNil(local.defaults.string(forKey: SyncDefaultsCursorStore.legacyKey),
                     "1.3.0's owner-less key is not written")

        await sync.sync(context: context)
        guard syncRequests.count == 3 else { return XCTFail("second sync: \(syncPaths)") }
        XCTAssertEqual(syncRequests[2].path, "/v1/sync/pull")
        XCTAssertEqual(syncRequests[2].query["since"], "2026-09-26T09:59:00.000Z")
    }

    /// The push went through, so its deletions are acknowledged — but the pull did not, so the
    /// cursor must stay put: advancing it would skip everything written since the old one.
    func testFailedPullDoesNotAdvanceTheCursor() async {
        seedOwnerAndCursor()
        queue.trackGroup("group-gone")
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull") { _ in throw URLError(.timedOut) }

        let ran = await sync.sync(context: context)

        XCTAssertFalse(ran)
        XCTAssertNotNil(sync.syncError, "offline reads as the system's description, as in 1.3.0")
        XCTAssertEqual(cursors.cursor(for: owner), recentCursor)
        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch(), "the push itself was accepted")
    }

    /// `409 cursor_expired` on the pull: drop the cursor and full-pull; the answer's code must
    /// survive the transport (1.3.0's APIClient threw it away with the status).
    func testCursorExpiredFullPullsOnTheSameSync() async throws {
        seedOwnerAndCursor()
        let expired = recentCursor
        server.on("GET", "/v1/sync/pull") { request in
            request.query["since"] == expired
                ? .init(status: 409, body: #"{"error":"cursor_expired","code":"cursor_expired","message":"Full sync required."}"#)
                : .ok(SyncStubBodies.pull())
        }

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        // Nothing to push; the pull on the expired cursor is answered 409 and the same pull
        // step drops it and full-pulls.
        XCTAssertEqual(syncRequests.map { $0.query["since"] }, [expired, nil])
        XCTAssertEqual(cursors.cursor(for: owner), "2026-09-26T09:59:00.000Z")
    }

    // MARK: - Answers and the Settings footer

    /// `syncError` is the Settings footer. The server answers this build (it sends
    /// X-Stride-Client) with the machine code in `error` — `{error:"rate_limited", code, message}`
    /// — and the footer must read as a sentence, not "rate_limited". The server's
    /// `retryAfterSeconds` sets the automatic-retry window; Sync Now still goes at once.
    func testRateLimitedSyncShowsASentenceAndWaitsAsTheServerAsked() async {
        seedOwnerAndCursor()
        queue.trackHabit("gone")
        server.on("POST", "/v1/sync/push", respond: .init(status: 429, body: #"""
        {"error":"rate_limited","code":"rate_limited",
         "message":"Too many sync requests, please try again later","retryAfterSeconds":30}
        """#))

        await sync.sync(context: context)

        let shown = sync.syncError
        XCTAssertEqual(shown, appLocalized("Too many sync requests. Please try again in a few minutes."))
        XCTAssertFalse(shown?.contains("rate_limited") ?? true)
        let wait = sync.nextAutomaticSync.map { $0.timeIntervalSinceNow } ?? 0
        XCTAssertEqual(wait, 30, accuracy: 5)
        XCTAssertFalse(sync.isPaused, "a rate limit is not the pause switch")

        let automatic = await sync.sync(context: context, trigger: .automatic)
        XCTAssertFalse(automatic)
        XCTAssertEqual(syncRequests.count, 1, "an automatic sync inside the window sends nothing")

        await sync.sync(context: context)
        XCTAssertEqual(syncRequests.count, 2, "Sync Now retries at once")
    }

    /// 503 `sync_paused` with only a `Retry-After` header: the header reaches the engine.
    func testSyncPausedReadsRetryAfterFromTheHeader() async {
        seedOwnerAndCursor()
        server.on("GET", "/v1/sync/pull", respond: .init(
            status: 503, body: #"{"error":"sync_paused","code":"sync_paused","message":"Sync is paused."}"#,
            headers: ["Retry-After": "120"]))

        await sync.sync(context: context)

        XCTAssertTrue(sync.isPaused)
        XCTAssertEqual(sync.nextAutomaticSync.map { $0.timeIntervalSinceNow } ?? 0, 120, accuracy: 5)
        XCTAssertEqual(sync.syncError, appLocalized("Sync is paused for maintenance. Your data is safe on this device and will sync when the pause ends."))
    }

    /// A code this build has no sentence for shows the server's `message`. `invalid_payload` is a
    /// client bug: the rows are not what is wrong, so nothing is held and they stay pending.
    func testInvalidPayloadShowsTheServersMessageAndHoldsNothing() async throws {
        seedOwnerAndCursor()
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        server.on("POST", "/v1/sync/push", respond: .init(status: 400, body: #"""
        {"error":"invalid_payload","code":"invalid_payload","message":"Sync data was malformed (\"habits\" must be an array)."}
        """#))

        await sync.sync(context: context)

        XCTAssertEqual(sync.syncError, #"Sync data was malformed ("habits" must be an array)."#)
        XCTAssertNil(habit.syncHoldReason)
        XCTAssertTrue(habit.isPending)
        XCTAssertNotNil(sync.nextAutomaticSync, "backing off")
    }

    /// 401: `needsReauth`, and nothing is reset — not the token (the sync transport never
    /// deletes it, unlike 1.3.0's), the cursor, the queue or any row's delivery state — so
    /// signing into the same account again resumes where it stopped.
    func testUnauthorizedStopsAsNeedsReauthAndResetsNothing() async throws {
        seedOwnerAndCursor()
        queue.trackHabit("gone")
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        server.on("POST", "/v1/sync/push", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))

        let ran = await sync.sync(context: context)

        XCTAssertFalse(ran)
        XCTAssertTrue(sync.needsReauth)
        XCTAssertEqual(sync.syncError, appLocalized("Please log in again"))
        XCTAssertEqual(tokens.read(), SyncSession.accountA.token)
        XCTAssertEqual(cursors.cursor(for: owner), recentCursor)
        XCTAssertEqual(queue.pending().habits, ["gone"])
        XCTAssertNil(habit.syncedAt)
        XCTAssertEqual(owners.owner?.id, owner)
    }

    /// The migrated-rows rule runs before the first 1.3.1 sync: a row older than 1.3.0's last
    /// sync was in that sync's snapshot, so it counts as delivered — and when the account no
    /// longer has it (deleted on another device), the first full pull removes it instead of this
    /// device uploading it again. A row newer than that sync is pushed. The marks stand because
    /// the snapshot holds another row this device delivered (the proof, `SyncMarksProof`); one
    /// that held none would have them forgotten and the row re-sent, to be answered `tombstoned`.
    func testMigratedRowsCountAsDeliveredOnTheFirstSync() async throws {
        let lastSync130 = Date().addingTimeInterval(-3_600)
        local.defaults.set(SyncTimestamp.string(from: lastSync130), forKey: SyncDeliveryMigration.lastSyncTimeKey)
        let old = Habit(name: "Deleted on the iPad")
        old.createdAt = SyncTimestamp.floorToMillisecond(lastSync130.addingTimeInterval(-86_400))
        old.updatedAt = old.createdAt
        let kept = Habit(name: "Still on the account")
        kept.createdAt = old.createdAt
        kept.updatedAt = old.createdAt
        let new = Habit(name: "Made after the last 1.3.0 sync")
        context.insert(old)
        context.insert(kept)
        context.insert(new)
        try context.save()
        let newID = new.id, keptID = kept.id
        let snapshot = SyncStubBodies.pull(habits: [SyncStubBodies.habit(kept)])
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull") { request in .ok(request.query["since"] == nil ? snapshot : SyncStubBodies.pull()) }

        await sync.sync(context: context)

        let pushed = try XCTUnwrap(syncRequests.first { $0.path == "/v1/sync/push" }?.json?["habits"] as? [[String: Any]])
        XCTAssertEqual(pushed.map { $0["id"] as? String }, [newID.uuidString])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id)), [keptID, newID])
    }

    /// A 1.3.0 store with one row stamped by the migrated-rows rule's cutoff and one after it,
    /// and 1.3.0's last-sync time. Returns (older, newer) ids.
    private func seedMigratedStore() throws -> (old: UUID, new: UUID) {
        let lastSync130 = Date().addingTimeInterval(-3_600)
        local.defaults.set(SyncTimestamp.string(from: lastSync130), forKey: SyncDeliveryMigration.lastSyncTimeKey)
        let old = Habit(name: "In 1.3.0's last snapshot")
        old.createdAt = SyncTimestamp.floorToMillisecond(lastSync130.addingTimeInterval(-86_400))
        old.updatedAt = old.createdAt
        let new = Habit(name: "Made after the last 1.3.0 sync")
        context.insert(old)
        context.insert(new)
        try context.save()
        return (old.id, new.id)
    }

    private var pushedHabitIDs: Set<String> {
        Set(syncRequests.filter { $0.path == "/v1/sync/push" }
            .flatMap { ($0.json?["habits"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String })
    }

    private var marks: SyncMarksProof { SyncMarksProof(defaults: local.defaults) }

    /// The first full pull proves the account (owner decision, 2026-09-28). A dormant 1.3.0
    /// device whose session EXPIRED (1.3.0 deletes the token and keeps `stride_last_sync_time`)
    /// updates, and the user signs back into the same account. Its snapshot holds a habit this
    /// device delivered, so the migrated marks are this account's and stand: nothing is deleted,
    /// and only the row made after the last 1.3.0 sync goes up.
    func testAnExpiredSessionsStoreSignedIntoTheSameAccountIsProvenAndUploadsOnlyTheNewerRow() async throws {
        let (oldID, newID) = try seedMigratedStore()
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: false)
        XCTAssertTrue(marks.isAwaited, "the migration stamped a row: its marks wait for the proof")
        let old = try XCTUnwrap(try context.fetch(FetchDescriptor<Habit>()).first { $0.id == oldID })
        let snapshot = SyncStubBodies.pull(habits: [SyncStubBodies.habit(old)])
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull") { request in .ok(request.query["since"] == nil ? snapshot : SyncStubBodies.pull()) }

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        XCTAssertEqual(syncPaths, ["/v1/sync/pull", "/v1/sync/push", "/v1/sync/pull"])
        XCTAssertNil(syncRequests.first?.query["since"], "the proof is a full pull, before any push")
        XCTAssertEqual(pushedHabitIDs, [newID.uuidString])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id)), [oldID, newID])
        XCTAssertEqual(owners.owner?.id, owner)
        XCTAssertFalse(marks.isAwaited, "decided")
    }

    /// M2 slice review R1, now under the owner's rule. The first launch found a stored token
    /// (so the slice's interim rule would have credited the marks to it), but the account that
    /// adopts the store is another: its snapshot holds none of this device's rows, so every mark
    /// is forgotten before the deletion pass — nothing is deleted, and both rows are uploaded.
    /// Kept, the marks made that pull delete every migrated row, with no recovery-log line.
    func testAMigratedStoreAdoptedByAnotherAccountForgetsItsMarksAndUploadsEveryRow() async throws {
        let (oldID, newID) = try seedMigratedStore()
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        sessions.session = .accountB
        stubHappyServer()

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        XCTAssertNil(syncRequests.first?.query["since"])
        XCTAssertEqual(pushedHabitIDs, [oldID.uuidString, newID.uuidString])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id)), [oldID, newID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).filter(\.isPending).count, 0,
                       "both acknowledged by the push")
        XCTAssertEqual(owners.owner?.id, SyncSession.accountB.account.id)
        XCTAssertFalse(marks.isAwaited)
    }

    /// The proving pull never came back (offline): nothing was decided, so the next sync — even
    /// automatic, and even with a cursor stored for the owner by then — is a full pull again.
    func testTheProofWaitsForAFullPullThatCameBack() async throws {
        let (oldID, _) = try seedMigratedStore()
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: false)
        server.on("GET", "/v1/sync/pull", respond: .init(status: 503, body: #"{"error":"server_error"}"#))

        let failed = await sync.sync(context: context)
        XCTAssertFalse(failed)
        XCTAssertTrue(marks.isAwaited)
        XCTAssertEqual(pushedHabitIDs, [], "nothing goes up before the proof")
        cursors.setCursor(recentCursor, for: owner)
        let before = syncRequests.count
        stubHappyServer()

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        XCTAssertNil(syncRequests.dropFirst(before).first?.query["since"], "full, whatever the cursor")
        XCTAssertTrue(pushedHabitIDs.contains(oldID.uuidString), "an empty account holds none of the rows: uploaded")
        XCTAssertFalse(marks.isAwaited)
    }

    // MARK: - The owner gate (account isolation)

    /// Signed into B on a device holding A's habits: no request at all, from any entry point,
    /// until the account screen settles it. 1.3.0 pushed A's habits into B's account here.
    func testAnotherAccountWithLocalDataMakesNoRequest() async throws {
        seedOwnerAndCursor()
        context.insert(Habit(name: "A's habit"))
        try context.save()
        sessions.session = .accountB
        stubHappyServer()

        let userInitiated = await sync.sync(context: context)
        let automatic = await sync.sync(context: context, trigger: .automatic)

        XCTAssertFalse(userInitiated)
        XCTAssertFalse(automatic)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(sync.ownerConflict, SyncOwnerConflict(owner: SyncOwner(SyncSession.accountA.account),
                                                            signedIn: SyncSession.accountB.account))
        XCTAssertEqual(owners.owner?.id, owner, "the owner does not change until the user chooses")
        XCTAssertNil(sync.syncError)
    }

    /// Nothing to lose — no rows, no queued deletions — and B simply becomes the owner. Its
    /// requests carry B's token; A's cursor is never used for B.
    func testAnotherAccountOnAnEmptyDeviceSwitchesSilently() async throws {
        seedOwnerAndCursor()
        sessions.session = .accountB
        stubHappyServer()

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        XCTAssertEqual(owners.owner?.id, SyncSession.accountB.account.id)
        XCTAssertNil(sync.ownerConflict)
        XCTAssertEqual(syncRequests.map(\.authorization), ["Bearer tok-B", "Bearer tok-B"])
        XCTAssertNil(syncRequests.first?.query["since"], "B has no cursor: a full pull, not A's")
        XCTAssertEqual(cursors.cursor(for: owner), recentCursor, "A's cursor is A's")
    }

    // MARK: - The run binding (review 2)

    private nonisolated static func verifyResponse(id: Int, email: String, token: String) -> String {
        #"{"ok":true,"user":{"id":\#(id),"email":"\#(email)","created_at":"2026-09-01 10:00:00"},"sessionToken":"\#(token)"}"#
    }

    /// The real AuthService over the same stub, sharing the token store, with sign-out wired to
    /// `service()` as the app wires it to `SyncService.shared`. Magic tokens "magic-A" / "magic-B"
    /// sign into account 7 (tok-A) / 8 (tok-B).
    private func makeAuth(onSignOut: @escaping @MainActor () -> Void,
                          onSignIn: @escaping @MainActor () -> Void = {}) -> AuthService {
        server.on("POST", "/v1/auth/verify") { request in
            switch request.json?["token"] as? String {
            case "magic-A": return .ok(Self.verifyResponse(id: 7, email: "a@example.com", token: "tok-A"))
            case "magic-A2": return .ok(Self.verifyResponse(id: 7, email: "a@example.com", token: "tok-A2"))
            case "magic-B": return .ok(Self.verifyResponse(id: 8, email: "b@example.com", token: "tok-B"))
            default: return .init(status: 400, body: #"{"error":"Invalid or expired login link"}"#)
            }
        }
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        tokens.delete()
        return AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                           defaults: local.defaults, onSignOut: onSignOut, onSignIn: onSignIn)
    }

    /// Sign out of A and into B while chunk 1 is in flight: chunk 2 is never sent, nothing is
    /// acknowledged, the deletion queue and A's cursor are as they were, and no request carries
    /// B's token. A chunked run spans many awaits; 1.3.0 guarded only its pull, and every request
    /// read the token from the keychain — so a later chunk would have carried A's rows on B's
    /// session.
    func testSigningIntoAnotherAccountMidRunSendsNoFurtherChunkAndAcknowledgesNothing() async throws {
        var service: SyncService?
        let auth = makeAuth(onSignOut: { service?.signedOut() })
        var switched = false
        let sync = makeSync(sessions: auth, bounds: SyncPushBounds(habits: 1)) { endpoint, _ in
            guard endpoint == .push, !switched else { return }
            switched = true
            await auth.logout()
            _ = await auth.verifyToken("magic-B")
        }
        service = sync
        let signedIn = await auth.verifyToken("magic-A")
        XCTAssertTrue(signedIn)

        let first = Habit(name: "One"), second = Habit(name: "Two")
        context.insert(first)
        context.insert(second)
        try context.save()
        queue.trackHabit("deleted-offline")
        stubHappyServer()

        let ran = await sync.sync(context: context)

        XCTAssertFalse(ran)
        XCTAssertTrue(switched)
        XCTAssertNil(sync.syncError, "a sign-out is not an error to show")
        XCTAssertEqual(auth.userEmail, "b@example.com", "precondition: B is signed in now")
        XCTAssertEqual(syncPaths, ["/v1/sync/pull", "/v1/sync/push"], "chunk 2 was never sent")
        XCTAssertFalse(server.requests.contains { $0.authorization == "Bearer tok-B" }, "no request on B's session")
        XCTAssertTrue(syncRequests.allSatisfy { $0.authorization == "Bearer tok-A" })
        XCTAssertNil(first.syncedAt, "chunk 1's answer arrived after the switch: not acknowledged")
        XCTAssertNil(second.syncedAt)
        XCTAssertEqual(queue.pending().habits, ["deleted-offline"])
        XCTAssertEqual(cursors.cursor(for: "7"), "2026-09-26T09:59:00.000Z", "A's cursor as the full pull left it")
        XCTAssertNil(cursors.cursor(for: "8"))

        // And B, holding A's rows, is not synced at all until the account screen decides.
        let asB = await sync.sync(context: context)
        XCTAssertFalse(asB)
        XCTAssertEqual(syncPaths.count, 2)
        XCTAssertEqual(sync.ownerConflict?.signedIn.id, "8")
    }

    /// Sign out and back into the SAME account: everything resumes. The cursor and every row's
    /// `syncedAt` survive the sign-out, so the next sync with no edits pushes nothing and pulls
    /// incrementally. 1.3.0 cleared the cursor and re-uploaded the whole store.
    func testSigningBackIntoTheSameAccountResumesWithoutReuploading() async throws {
        var service: SyncService?
        let auth = makeAuth(onSignOut: { service?.signedOut() })
        let sync = makeSync(sessions: auth)
        service = sync
        _ = await auth.verifyToken("magic-A")
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        stubHappyServer()
        await sync.sync(context: context)
        XCTAssertFalse(habit.isPending)
        let cursor = try XCTUnwrap(cursors.cursor(for: "7"))
        let requestsBefore = syncRequests.count

        await auth.logout()
        XCTAssertEqual(cursors.cursor(for: "7"), cursor, "sign-out keeps the cursor")
        XCTAssertNotNil(habit.syncedAt, "sign-out keeps the delivery state")
        _ = await auth.verifyToken("magic-A2")
        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        let after = Array(syncRequests.dropFirst(requestsBefore))
        XCTAssertEqual(after.map(\.path), ["/v1/sync/pull"], "no edits: no push")
        XCTAssertEqual(after.first?.query["since"], cursor)
        XCTAssertEqual(after.first?.authorization, "Bearer tok-A2", "the new session's token")
    }

    // MARK: - Overlap with sign-out and with callers that need the result

    /// `sync` says whether THIS call ran. The second of two overlapping calls did not, and used
    /// to look like a success to Erase Local Data (syncError stayed nil).
    func testSyncReportsWhetherThisCallRan() async throws {
        seedOwnerAndCursor()
        let body = SyncStubBodies.pull()
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .ok(body)
        }

        let first = Task { await sync.sync(context: context) }
        try await waitForRequest("/v1/sync/pull")
        let overlapping = await sync.sync(context: context)
        let firstRan = await first.value

        XCTAssertFalse(overlapping)
        XCTAssertTrue(firstRan)
        XCTAssertEqual(syncPaths, ["/v1/sync/pull"])

        server.on("GET", "/v1/sync/pull", respond: .init(status: 500, body: #"{"error":"boom"}"#))
        let failed = await sync.sync(context: context)
        XCTAssertFalse(failed)
    }

    /// Erase's pre-erase sync: it waits out a sync already in flight (which may have started
    /// before the edits it must push), then runs its own and reports that one.
    func testSyncAfterInFlightWaitsThenRunsItsOwn() async throws {
        seedOwnerAndCursor()
        let body = SyncStubBodies.pull()
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .ok(body)
        }

        let inFlight = Task { await sync.sync(context: context) }
        try await waitForRequest("/v1/sync/pull")
        let own = await sync.syncAfterInFlight(context: context)
        _ = await inFlight.value

        XCTAssertTrue(own)
        XCTAssertEqual(syncPaths, ["/v1/sync/pull", "/v1/sync/pull"])
    }

    /// A launch or foreground sync still awaiting its pull when the user signs out: its response
    /// used to be applied to the store and its cursor written AFTER the sign-out — the account's
    /// rows reappeared on an erased device, or the next sign-in pulled incrementally from that
    /// cursor and never re-downloaded the account.
    func testASyncInFlightAtSignOutWritesNothingAfterIt() async throws {
        let body = SyncStubBodies.pull(habits: [SyncStubBodies.habit(Habit(name: "From the account"))])
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .ok(body)
        }

        let inFlight = Task { await sync.sync(context: context) }
        try await waitForRequest("/v1/sync/pull")
        sessions.session = nil
        sync.signedOut()   // what AuthService.logout calls
        let ran = await inFlight.value

        XCTAssertFalse(ran)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 0, "nothing applied after sign-out")
        XCTAssertNil(cursors.cursor(for: owner), "no cursor written after sign-out")
        XCTAssertNil(sync.lastSyncTime)
        XCTAssertNil(sync.syncError, "signing out is not an error to show")
        XCTAssertFalse(sync.isSyncing)

        // Signed back in, the next sync is an ordinary full pull again.
        sessions.session = .accountA
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))
        let next = await sync.sync(context: context)
        XCTAssertTrue(next)
        XCTAssertNil(syncRequests.dropFirst().first?.query["since"])
    }

    /// Erase Local Data's reset (after its sign-out): every cursor, the owner, the queue — an
    /// empty store belongs to nobody, and the next account's first sync is a full pull.
    func testResetSyncStateForgetsCursorsOwnerAndQueue() {
        seedOwnerAndCursor()
        queue.trackHabit("gone")

        sync.resetSyncState()

        XCTAssertNil(cursors.cursor(for: owner))
        XCTAssertNil(owners.owner)
        XCTAssertTrue(queue.pending().isEmpty)
    }

    /// An erased store has no delivery marks, so none wait for a proof.
    func testResetSyncStateSettlesTheMarksProof() {
        marks.require()
        sync.resetSyncState()
        XCTAssertFalse(marks.isAwaited)
    }
}
