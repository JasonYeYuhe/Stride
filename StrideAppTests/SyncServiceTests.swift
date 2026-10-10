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
    private var recovery: ScratchRecoveryLog!
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
        recovery = ScratchRecoveryLog()
        sync = makeSync()
    }

    override func tearDown() {
        server.stop()
        local.remove()
        appGroup.remove()
        recovery.remove()
        recovery = nil
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
                    sessions: sessions ?? self.sessions, recoveryLog: recovery.log, bounds: bounds,
                    afterSyncRequest: afterSyncRequest)
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

    /// A rate limit is "Sync paused" inline (Today's line, the Settings sync section — both read
    /// `backoff`), never the red `syncError` footer (M2 answer table: 429 → "sync paused" inline;
    /// never `syncError`). The server's `retryAfterSeconds` sets the automatic-retry window; Sync
    /// Now still goes at once.
    func testRateLimitedSyncShowsSyncPausedAndWaitsAsTheServerAsked() async {
        seedOwnerAndCursor()
        queue.trackHabit("gone")
        server.on("POST", "/v1/sync/push", respond: .init(status: 429, body: #"""
        {"error":"rate_limited","code":"rate_limited",
         "message":"Too many sync requests, please try again later","retryAfterSeconds":30}
        """#))

        await sync.sync(context: context)

        XCTAssertNil(sync.syncError, "a rate limit is not an error to show")
        XCTAssertEqual(sync.backoff?.reason, .rateLimited)
        XCTAssertTrue(sync.backoff?.reason.showsSyncPaused ?? false, "the inline rows say \"Sync paused\"")
        let wait = sync.nextAutomaticSync.map { $0.timeIntervalSinceNow } ?? 0
        XCTAssertEqual(wait, 30, accuracy: 5)
        XCTAssertFalse(sync.isPaused, "a rate limit is not the pause switch")

        let automatic = await sync.sync(context: context, trigger: .automatic)
        XCTAssertFalse(automatic)
        XCTAssertEqual(syncRequests.count, 1, "an automatic sync inside the window sends nothing")

        await sync.sync(context: context)
        XCTAssertEqual(syncRequests.count, 2, "Sync Now retries at once")
    }

    /// 503 `sync_paused` with only a `Retry-After` header: the header reaches the engine, and the
    /// pause is "Sync paused" inline with no error (acceptance (9)).
    func testSyncPausedReadsRetryAfterFromTheHeader() async {
        seedOwnerAndCursor()
        server.on("GET", "/v1/sync/pull", respond: .init(
            status: 503, body: #"{"error":"sync_paused","code":"sync_paused","message":"Sync is paused."}"#,
            headers: ["Retry-After": "120"]))

        await sync.sync(context: context)

        XCTAssertTrue(sync.isPaused)
        XCTAssertEqual(sync.nextAutomaticSync.map { $0.timeIntervalSinceNow } ?? 0, 120, accuracy: 5)
        XCTAssertNil(sync.syncError, "the pause switch is not an error to show")
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
    /// signing into the same account again resumes where it stopped. And no `syncError`: the
    /// "Sign in again" row says it (E2E S9 — the red "Please log in again" footer sat under a
    /// green "Signed in"); an earlier run's error does not stay up either.
    func testUnauthorizedStopsAsNeedsReauthAndResetsNothing() async throws {
        seedOwnerAndCursor()
        queue.trackHabit("gone")
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        server.on("POST", "/v1/sync/push", respond: .init(status: 500, body: #"{"error":"Internal error"}"#))
        await sync.sync(context: context)
        XCTAssertEqual(sync.syncError, "Internal error", "precondition: an earlier run's footer")
        server.on("POST", "/v1/sync/push", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))

        let ran = await sync.sync(context: context)

        XCTAssertFalse(ran)
        XCTAssertTrue(sync.needsReauth)
        XCTAssertNil(sync.syncError)
        XCTAssertEqual(tokens.read(), SyncSession.accountA.token)
        XCTAssertEqual(cursors.cursor(for: owner), recentCursor)
        XCTAssertEqual(queue.pending().habits, ["gone"])
        XCTAssertNil(habit.syncedAt)
        XCTAssertEqual(owners.owner?.id, owner)
    }

    /// The migrated-rows rule runs before the first 1.3.1 sync: a row older than 1.3.0's last
    /// sync was in that sync's snapshot, so it counts as delivered, and one the account still
    /// holds is not uploaded again. The marks stand because the snapshot holds a row this device
    /// delivered (the proof, `SyncMarksProof`). A marked row the account no longer has was deleted
    /// on another device after that sync: the pull asks for the account's deletions since the
    /// cursor 1.3.0 kept (review data-safety-1) — through APIClient, on the wire — and the server
    /// lists it, so it goes as an incremental pull would have removed it: quietly, not resent and
    /// not in Recovered Edits. Only the row made after the last 1.3.0 sync goes up.
    func testMigratedRowsCountAsDeliveredOnTheFirstSync() async throws {
        let lastSync130 = Date().addingTimeInterval(-3_600)
        let cursor130 = SyncTimestamp.millisecondString(from: lastSync130.addingTimeInterval(-SyncCursor.overlap))
        local.defaults.set(SyncTimestamp.string(from: lastSync130), forKey: SyncDeliveryMigration.lastSyncTimeKey)
        local.defaults.set(cursor130, forKey: SyncDefaultsCursorStore.legacyKey)
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
        let oldID = old.id, newID = new.id, keptID = kept.id
        let snapshot = withDeletionsSince(SyncStubBodies.pull(habits: [SyncStubBodies.habit(kept)]), habitIDs: [oldID])
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull") { request in .ok(request.query["since"] == nil ? snapshot : SyncStubBodies.pull()) }

        await sync.sync(context: context)

        let pulls = syncRequests.filter { $0.path == "/v1/sync/pull" }
        XCTAssertNil(pulls.first?.query["since"], "the proof is a full pull")
        XCTAssertEqual(pulls.first?.query["deletionsSince"], cursor130, "1.3.0's cursor, as the migration pinned it")
        XCTAssertTrue(pulls.dropFirst().allSatisfy { $0.query["deletionsSince"] == nil }, "only that pull asks")
        XCTAssertEqual(pushedHabitIDs, [newID.uuidString], "never the row the account holds, nor the one it deleted")
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id)), [keptID, newID])
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0, "nobody edited it here: nothing to recover")
        XCTAssertFalse(marks.isAwaited)
        XCTAssertFalse(marks.isUnverified)
        XCTAssertNil(marks.deletionsSince, "the pin goes with the flag")
    }

    /// `body` with the `deletionsSince` a server >= 1.3.1 adds to a full pull that asked.
    private func withDeletionsSince(_ body: String, habitIDs: [UUID]) -> String {
        var json = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
        json["deletionsSince"] = ["complete": true, "habitIds": habitIDs.map(\.uuidString), "entryIds": [String](),
                                  "groupIds": [String]()] as [String: Any]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), as: UTF8.self)
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

    /// The first full pull proves the account (owner decision, 2026-09-28). A 1.3.0 device still
    /// holding a session at its first 1.3.1 launch adopts no owner-unknown flag — but a stored
    /// token is not evidence that its account is the one the marks were inferred for, so they
    /// wait for the proof. Its snapshot holds a habit this device delivered, so the marks are this
    /// account's and stand: nothing is deleted, and only the row made after the last 1.3.0 sync
    /// goes up. (A device whose session EXPIRED reaches 1.3.1 signed out: owner unknown, and its
    /// next sign-in goes through the account screen — AccountSwitchTests.)
    func testAStoreSignedInAtItsFirstLaunchIsProvenAndUploadsOnlyTheNewerRow() async throws {
        let (oldID, newID) = try seedMigratedStore()
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
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
        // Signed in at the first launch: an owner-unknown store would wait for the account
        // screen instead (AccountSwitchTests), and this test is about the proof.
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
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
        XCTAssertNil(cursors.cursor(for: owner),
                     "A's cursor went with A's ownership: A full-pulls if it ever owns the store again")
    }

    // MARK: - Backoff (phase B: per owner, persisted)

    private var backoffStore: SyncBackoffStore { SyncBackoffStore(defaults: local.defaults) }

    private static let pausedBody = #"{"error":"sync_paused","code":"sync_paused","message":"Sync is paused."}"#

    /// The window a paused server gave outlives the process: a relaunched app (a new
    /// SyncService over the same defaults) shows "paused" at once and its automatic sync sends
    /// nothing — the slice kept the window in memory, so every device that was opened asked the
    /// paused server again. Sync Now still goes at once, and its success clears the window.
    func testTheBackoffWindowSurvivesARelaunchAndSyncNowGoesAtOnce() async {
        seedOwnerAndCursor()
        server.on("GET", "/v1/sync/pull", respond: .init(status: 503, body: Self.pausedBody,
                                                         headers: ["Retry-After": "600"]))
        await sync.sync(context: context, trigger: .automatic)
        XCTAssertTrue(sync.isPaused)

        let relaunched = makeSync()
        XCTAssertTrue(relaunched.isPaused, "read back from the store at launch")
        XCTAssertEqual(relaunched.backoff?.reason, .paused)
        XCTAssertEqual(relaunched.nextAutomaticSync.map { $0.timeIntervalSinceNow } ?? 0, 600, accuracy: 5)
        let before = syncRequests.count
        let automatic = await relaunched.sync(context: context, trigger: .automatic)
        XCTAssertFalse(automatic)
        XCTAssertEqual(syncRequests.count, before, "an automatic sync inside the window sends nothing")
        XCTAssertFalse(relaunched.isSyncing)

        stubHappyServer()
        let manual = await relaunched.sync(context: context)
        XCTAssertTrue(manual, "Sync Now goes at once")
        XCTAssertNil(relaunched.backoff)
        XCTAssertFalse(relaunched.isPaused)
        XCTAssertNil(backoffStore.state(for: owner), "success resets")
        let again = await relaunched.sync(context: context, trigger: .automatic)
        XCTAssertTrue(again)
    }

    // MARK: - The background trigger (1.4.0, RELEASE-1.4.0.md D5)

    /// Counts the session resolves: `sync` awaits one only after it has claimed `isSyncing`, so
    /// zero resolves means the call returned on the fast path, before the flag ever flipped.
    private final class CountingSessions: SyncSessionSource {
        var session: SyncSession?
        private(set) var resolves = 0
        init(_ session: SyncSession?) { self.session = session }
        func currentSyncSession() -> SyncSession? { session }
        func resolveSyncSession() async -> SyncSession? {
            resolves += 1
            return session
        }
    }

    /// A `.background` sync inside the owner's window takes the same fast path as an automatic
    /// one: no spinner, no session resolve, no request — not Sync Now's "go at once", which is
    /// what `trigger == .automatic` made of any third trigger.
    func testABackgroundSyncInsideTheWindowTakesTheFastPath() async {
        seedOwnerAndCursor()
        backoffStore.recordFailure(.serverAsked(seconds: 600, paused: true), for: owner)
        stubHappyServer()
        let counting = CountingSessions(.accountA)
        let sync = makeSync(sessions: counting)

        let ran = await sync.sync(context: context, trigger: .background)

        XCTAssertFalse(ran)
        XCTAssertEqual(counting.resolves, 0, "returned before claiming isSyncing")
        XCTAssertFalse(sync.isSyncing)
        XCTAssertTrue(server.requests.isEmpty, "a background sync inside the window sends nothing")
        XCTAssertTrue(sync.isPaused, "the window is read back for the status line")

        let manual = await sync.sync(context: context)
        XCTAssertTrue(manual, "Sync Now still goes at once")
        XCTAssertEqual(counting.resolves, 1)
    }

    /// A background run that got no answer — iOS cancelling the refresh as its time ran out
    /// arrives as a cancelled request, which APIClient reports as no answer — shows no error and
    /// leaves no window: the footer would have said "cancelled" to someone who never asked for a
    /// sync, and the window would have turned away the foreground sync that follows. That one
    /// goes at once here, and — not being a background run — shows and records its own failure.
    func testABackgroundSyncWithNoAnswerShowsNoErrorAndLeavesNoWindow() async {
        seedOwnerAndCursor()
        queue.trackHabit("gone")
        server.on("POST", "/v1/sync/push") { _ in throw URLError(.cancelled) }
        server.on("GET", "/v1/sync/pull") { _ in throw URLError(.cancelled) }

        let ran = await sync.sync(context: context, trigger: .background)

        XCTAssertFalse(ran)
        XCTAssertEqual(syncRequests.count, 1, "the request went and got no answer")
        XCTAssertNil(sync.syncError, "no footer for a background run cut short")
        XCTAssertNil(sync.backoff)
        XCTAssertNil(backoffStore.state(for: owner), "no window: the next foreground sync goes")

        server.on("POST", "/v1/sync/push") { _ in throw URLError(.notConnectedToInternet) }
        let foreground = await sync.sync(context: context, trigger: .automatic)
        XCTAssertFalse(foreground)
        XCTAssertEqual(syncRequests.count, 2, "the automatic sync was not turned away")
        XCTAssertNotNil(sync.syncError, "a foreground no-answer keeps 1.3.0's footer")
        XCTAssertEqual(backoffStore.state(for: owner)?.reason, .offline)
    }

    /// What the server actually answers still counts on a background run: a 5xx sets the footer
    /// and the window as for any run (D5: "a 429, a 5xx and the pause switch are still recorded").
    func testABackgroundSyncStillRecordsAServerError() async {
        seedOwnerAndCursor()
        queue.trackHabit("gone")
        server.on("POST", "/v1/sync/push", respond: .init(status: 502, body: "<html>Bad Gateway</html>"))

        let ran = await sync.sync(context: context, trigger: .background)

        XCTAssertFalse(ran)
        XCTAssertNotNil(sync.syncError)
        XCTAssertEqual(sync.backoff?.reason, .serverError)
        XCTAssertEqual(backoffStore.state(for: owner)?.reason, .serverError)
    }

    /// Account A's window never holds back B: B signing into a device A owned, with nothing to
    /// lose, adopts it silently and its automatic sync goes; A's window goes with A's queue.
    func testASilentSwitchLeavesThePreviousOwnersWindowBehind() async {
        seedOwnerAndCursor()
        backoffStore.recordFailure(.serverAsked(seconds: 3_600, paused: true), for: owner)
        sessions.session = .accountB
        stubHappyServer()

        let ran = await sync.sync(context: context, trigger: .automatic)

        XCTAssertTrue(ran)
        XCTAssertEqual(syncRequests.map(\.authorization), ["Bearer tok-B", "Bearer tok-B"])
        XCTAssertNil(backoffStore.state(for: owner), "A's window went with the store")
        XCTAssertNil(sync.backoff)
    }

    // MARK: - The file recovery log (phase B)

    /// A habit whose check-in is held here, deleted on another device: the pull archives it into
    /// the FILE (the app's sink since phase B) before deleting it, and the phase C row can count,
    /// export and clear it.
    private func archiveOneHeldHabit() async throws -> Habit {
        seedOwnerAndCursor()
        let habit = Habit(name: "Edited offline")
        context.insert(habit)
        habit.hold(.rowError)
        try context.save()
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull(deletedHabitIds: [habit.id.uuidString])))
        let ran = await sync.sync(context: context)
        XCTAssertTrue(ran)
        return habit
    }

    func testAPullArchivesIntoTheFileLogAndSettingsCanCountExportAndClearIt() async throws {
        _ = try await archiveOneHeldHabit()

        XCTAssertEqual(syncPaths, ["/v1/sync/pull"], "a held row is not pushed")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 0, "deleted after archiving")
        XCTAssertEqual(sync.recoveredEdits?.lines, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recovery.directory.path)
            .filter { $0.hasSuffix(".jsonl") }, ["account-7.jsonl"], "the owner's own file")

        let export = try SyncRecoveryLog.decodeExport(try sync.exportRecoveredEdits())
        XCTAssertEqual(export.accountId, owner)
        XCTAssertEqual(export.items.map(\.habit?.name), ["Edited offline"])
        XCTAssertEqual(export.items.first?.reason, .deletedElsewhere)
        XCTAssertEqual(sync.recoveredEditsFile, .recoveredEdits(accountID: owner))
        XCTAssertThrowsError(try DataBackup.decode(try sync.exportRecoveredEdits()), "not a backup")

        try sync.clearRecoveredEdits()
        XCTAssertEqual(sync.recoveredEdits?.lines, 0)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0)
    }

    /// Recovery-log lines are something to lose: an empty store whose log holds A's recovered
    /// edits is not handed to B silently — the lines would be read for no one again.
    func testRecoveredEditsCountAsSomethingToLose() async throws {
        seedOwnerAndCursor()
        let row = DataBackup.snapshot(habits: [Habit(name: "Recovered")], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: owner)
        sessions.session = .accountB
        stubHappyServer()

        let ran = await sync.sync(context: context)

        XCTAssertFalse(ran)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(sync.ownerConflict?.owner?.id, owner)
    }

    // MARK: - Held rows (phase B API; the rows are phase C UI)

    func testHeldRowsAreListedByReasonAndRestoreAsNewCopiesUploadsTheCopy() async throws {
        seedOwnerAndCursor()
        let restored = Habit(name: "Restored, deleted elsewhere")
        let refused = Habit(name: "Refused")
        context.insert(restored)
        context.insert(refused)
        restored.restoredAt = Date()
        restored.hold(.tombstoned)
        refused.hold(.rowError)
        try context.save()
        let oldID = restored.id

        let listed = try sync.heldRows(in: context)
        XCTAssertEqual(listed.map(\.reason), [.rowError, .tombstoned])
        XCTAssertEqual(listed.map(\.counts.habits), [1, 1])
        XCTAssertEqual(listed.map(\.canRestoreAsCopies), [false, true])

        stubHappyServer()
        let outcome = try await sync.restoreHeldRowsAsNewCopies(.tombstoned, in: context)

        XCTAssertEqual(outcome.rows.habits, 1)
        XCTAssertNotEqual(restored.id, oldID)
        XCTAssertEqual(outcome.habitIDs[oldID], restored.id)
        XCTAssertEqual(pushedHabitIDs, [restored.id.uuidString], "the copy went up in the same call")
        XCTAssertFalse(restored.isPending)
        XCTAssertTrue(queue.pending().isEmpty, "no deletion queued for the old id")
        XCTAssertEqual(try sync.heldRows(in: context).map(\.reason), [.rowError])
    }

    func testDiscardHeldRowsDeletesThemAndQueuesNothing() async throws {
        seedOwnerAndCursor()
        let foreign = Habit(name: "Another account's")
        context.insert(foreign)
        foreign.records = [HabitRecord(date: HabitCalendar.dayKey(for: Date()))]
        foreign.hold(.notOwned)
        try context.save()

        let outcome = try await sync.discardHeldRows(.notOwned, in: context)

        XCTAssertEqual(outcome.rows.habits, 1)
        XCTAssertEqual(outcome.rows.entries, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 0)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertTrue(server.requests.isEmpty, "nothing to send")
    }

    // MARK: - Restore's owner (phase B API; the screen is phase C)

    private func backup(from account: SyncAccount?, habit name: String) -> (BackupDocument, UUID) {
        let habit = Habit(name: name)
        let doc = DataBackup.snapshot(habits: [habit], groups: [],
                                      account: account.map { BackupAccount(id: $0.id, email: $0.email) })
        return (doc, habit.id)
    }

    /// Review 2: copies restored while signed into B make B the owner, and the next sync pushes
    /// them with no second sign-in — even on a device A owned (the store was empty).
    func testRestoringCopiesWhileSignedIntoBMakesBTheOwnerAndTheNextSyncPushesThem() async throws {
        seedOwnerAndCursor()
        queue.trackHabit("A's deletion")
        sessions.session = .accountB
        let (doc, originalID) = backup(from: SyncSession.accountA.account, habit: "From A")

        let decision = DataExportService.restoreDecision(for: doc, sync: sync)
        XCTAssertEqual(decision.plan, RestorePlan(identity: .newCopies, owner: BackupAccount(id: "8", email: "b@example.com")))
        XCTAssertNil(decision.keepIDsInstead)
        try await DataExportService.restore(doc, into: context, plan: decision.plan, sync: sync, deletionQueue: queue)

        XCTAssertEqual(owners.owner?.id, "8")
        XCTAssertTrue(queue.pending().isEmpty, "A's queued deletion was A's")
        stubHappyServer()
        let ran = await sync.sync(context: context)
        XCTAssertTrue(ran)
        XCTAssertNil(sync.ownerConflict)
        let pushed = pushedHabitIDs
        XCTAssertEqual(pushed.count, 1)
        XCTAssertFalse(pushed.contains(originalID.uuidString), "a new copy, not A's id")
        XCTAssertTrue(syncRequests.allSatisfy { $0.authorization == "Bearer tok-B" })
    }

    /// Signed out, a restore that names no account leaves the store without an owner, for the
    /// next sign-in to adopt; naming the file's own account as the next one keeps the ids and
    /// makes it the owner.
    func testRestoringWhileSignedOutLeavesNoOwnerUnlessTheUserNamesTheAccount() async throws {
        seedOwnerAndCursor()
        sessions.session = nil
        let (doc, originalID) = backup(from: SyncSession.accountB.account, habit: "From B")

        let unnamed = DataExportService.restoreDecision(for: doc, sync: sync)
        XCTAssertEqual(unnamed.plan, RestorePlan(identity: .newCopies, owner: nil))
        let named = DataExportService.restoreDecision(
            for: doc, next: BackupAccount(id: "8", email: "b@example.com"), sync: sync)
        XCTAssertEqual(named.plan.identity, .keepIDs)

        try await DataExportService.restore(doc, into: context, plan: unnamed.plan, sync: sync, deletionQueue: queue)
        XCTAssertNil(owners.owner, "for the next sign-in to adopt")
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<Habit>()).first)
        XCTAssertNotEqual(restored.id, originalID)
        XCTAssertNil(restored.restoredAt, "copies are new rows")
    }

    /// Phase B review R1. A's device, signed out: the user deletes every habit (queued for A),
    /// then restores a 1.3.0 backup naming no account. The restore leaves no owner and drops A's
    /// queue — a queue belongs to one account — so A's cursor must go with it. Otherwise A signing
    /// back in adopts the store and pulls incrementally from that cursor: the habits it deleted
    /// have not changed since, so they never come back here, while their deletions never reach
    /// the server — device and account drift apart until the cursor ages out. Without the cursor
    /// the adoption full-pulls, and the device shows what the account holds.
    func testARestoreThatDropsTheOwnersQueuedDeletionsAlsoDropsItsCursor() async throws {
        seedOwnerAndCursor()
        sessions.session = nil
        let deletedOffline = Habit(name: "Deleted while signed out")
        queue.trackHabit(deletedOffline.id.uuidString)
        let (doc, _) = backup(from: nil, habit: "From a 1.3.0 backup")

        let decision = DataExportService.restoreDecision(for: doc, sync: sync)
        XCTAssertEqual(decision.plan, RestorePlan(identity: .newCopies, owner: nil))
        try await DataExportService.restore(doc, into: context, plan: decision.plan, sync: sync, deletionQueue: queue)
        XCTAssertNil(owners.owner)
        XCTAssertTrue(queue.pending().isEmpty, "A's queue went with A's ownership")
        XCTAssertNil(cursors.cursor(for: owner), "and so did the cursor that assumed it")

        sessions.session = .accountA
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull(habits: [SyncStubBodies.habit(deletedOffline)])))
        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        XCTAssertEqual(owners.owner?.id, owner, "A adopted the owner-less store")
        XCTAssertEqual(syncPaths.first, "/v1/sync/pull")
        XCTAssertNil(syncRequests.first?.query["since"], "a full pull, not A's pre-restore cursor")
        XCTAssertEqual(pushedHabitIDs.count, 1, "the copy went up")
        let ids = Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id))
        XCTAssertTrue(ids.contains(deletedOffline.id), "the account still holds it, and now so does the device")
        XCTAssertEqual(ids.count, 2)
    }

    /// The same drop on a restore made signed in: the store changes hands (A → B), and A's cursor
    /// goes with A's queue, so A full-pulls if it ever owns the store again.
    func testARestoreIntoAnotherAccountLeavesThePreviousOwnerNoCursor() async throws {
        seedOwnerAndCursor()
        queue.trackHabit("A's deletion")
        sessions.session = .accountB
        cursors.setCursor(recentCursor, for: SyncSession.accountB.account.id)   // from an earlier hand-over
        let (doc, _) = backup(from: SyncSession.accountA.account, habit: "From A")

        try await DataExportService.restore(doc, into: context,
                                            plan: DataExportService.restoreDecision(for: doc, sync: sync).plan,
                                            sync: sync, deletionQueue: queue)

        XCTAssertEqual(owners.owner?.id, SyncSession.accountB.account.id)
        XCTAssertNil(cursors.cursor(for: owner))
        XCTAssertNil(cursors.cursor(for: SyncSession.accountB.account.id),
                     "a cursor exists only for the owner of the store it described")
    }

    /// A backup records the store's owner — signed in or not — so a restore can tell whose ids
    /// the file carries. Settings' Export as JSON (`ExportFile.ownerBackup`) names the same owner,
    /// read at the tap (ExportTests).
    func testBackupsRecordTheStoresOwner() throws {
        owners.set(SyncOwner(SyncSession.accountA.account))
        let account = DataExportService.storeOwnerAccount(defaults: local.defaults)
        XCTAssertEqual(account, BackupAccount(id: "7", email: "a@example.com"))
        let data = try DataExportService.backupJSONData(from: context, account: account)
        XCTAssertEqual(try DataBackup.decode(data).accountId, "7")
        owners.clear()
        XCTAssertNil(DataExportService.storeOwnerAccount(defaults: local.defaults))
    }

    // MARK: - "Start from this account's data" (phase B API; the account screen is phase C)

    func testStartFromThisAccountsDataErasesAsDataAndEverythingOfItsThenFullPullsB() async throws {
        seedOwnerAndCursor()
        context.insert(Habit(name: "A's habit"))
        try context.save()
        queue.trackHabit("A's deletion")
        let row = DataBackup.snapshot(habits: [Habit(name: "A's recovered edit")], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: owner)
        backoffStore.recordFailure(.transient, for: owner)
        cursors.setCursor(recentCursor, for: "8")   // B synced on this device once, long ago
        sessions.session = .accountB
        let fromB = Habit(name: "B's habit")
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull(habits: [SyncStubBodies.habit(fromB)])))
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))

        let blocked = await sync.sync(context: context)
        XCTAssertFalse(blocked)
        let conflict = try XCTUnwrap(sync.ownerConflict)
        XCTAssertTrue(server.requests.isEmpty)

        let ran = await sync.startFromSignedInAccountsData(conflict, in: context)

        XCTAssertTrue(ran)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.name), ["B's habit"])
        XCTAssertEqual(owners.owner?.id, "8")
        XCTAssertNil(sync.ownerConflict)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0)
        XCTAssertNil(backoffStore.state(for: owner))
        XCTAssertNil(cursors.cursor(for: owner))
        XCTAssertEqual(syncPaths, ["/v1/sync/pull", "/v1/sync/pull"], "nothing of A's pushed")
        XCTAssertNil(syncRequests.first?.query["since"], "a full pull, not B's old cursor")
        XCTAssertTrue(syncRequests.allSatisfy { $0.authorization == "Bearer tok-B" })
    }

    /// The screen's choice applies only to the conflict it showed: after a sign-out (or another
    /// sign-in) it erases nothing.
    func testStartFromThisAccountsDataDoesNothingOnceTheConflictIsGone() async throws {
        seedOwnerAndCursor()
        context.insert(Habit(name: "A's habit"))
        try context.save()
        sessions.session = .accountB
        await sync.sync(context: context)
        let conflict = try XCTUnwrap(sync.ownerConflict)
        sessions.session = nil

        let ran = await sync.startFromSignedInAccountsData(conflict, in: context)

        XCTAssertFalse(ran)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 1)
        XCTAssertEqual(owners.owner?.id, owner)
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

    /// An erased store has no delivery marks, so none wait for a proof, or for the pass after it,
    /// and 1.3.0's pinned cursor goes with them.
    func testResetSyncStateSettlesTheMarksProof() {
        marks.require()
        marks.pinDeletionsSince("2026-09-20T11:59:00.000Z")
        sync.resetSyncState()
        XCTAssertFalse(marks.isAwaited)
        XCTAssertFalse(marks.isUnverified)
        XCTAssertNil(local.defaults.object(forKey: SyncMarksProof.deletionsSinceKey))
    }
}
