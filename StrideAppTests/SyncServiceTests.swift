import XCTest
import SwiftData
@testable import Stride

/// `SyncService.sync` end to end against a stubbed server: the real service, the real APIClient,
/// the real reconciler, an in-memory store (the SyncReconcileTests pattern), and a scratch
/// defaults suite for the cursor and the deletion queues.
///
/// StrideTests covers the pieces — SyncDeletionQueue, SyncCursor, SyncReconciler — but not the
/// ordering that makes them safe together, which lives only in this service: push before pull,
/// acknowledge only after the push is accepted, advance the cursor only after both succeeded.
@MainActor
final class SyncServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var queue: SyncDeletionQueue!
    private var sync: SyncService!

    /// The persisted key. Asserted by name on purpose: renaming it silently turns every
    /// installed app's next sync into a full pull.
    private let cursorKey = "stride_sync_cursor"

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        local = ScratchDefaults("sync.local")
        appGroup = ScratchDefaults("sync.appGroup")
        queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        sync = SyncService(
            api: server.makeClient(tokenStore: InMemoryTokenStore("tok-123")),
            defaults: local.defaults,
            deletionQueue: queue
        )
    }

    override func tearDown() {
        server.stop()
        local.remove()
        appGroup.remove()
        sync = nil
        queue = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func pullBody(serverTime: String = "2026-09-26T10:00:00.000Z") -> String {
        #"""
        {"habits":[],"entries":[],"groups":[],"deletedHabitIds":[],"deletedEntryIds":[],
         "deletedGroupIds":[],"serverTime":"\#(serverTime)","totals":{"habits":0,"entries":0,"groups":0}}
        """#
    }

    private func stubHappyServer(serverTime: String = "2026-09-26T10:00:00.000Z") {
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.pullBody(serverTime: serverTime)))
    }

    // MARK: - Ordering

    /// Push first, then pull. Pulling first would let a full pull's reconciliation delete a
    /// habit created on this device that the server has not seen yet — the reconciler removes
    /// local rows a full pull does not contain.
    func testPushesBeforePulling() async throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        // The pull returns what the push just sent, as the real server would.
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        server.on("GET", "/v1/sync/pull", respond: .ok(#"""
        {"habits":[{"id":"\#(habit.id.uuidString)","name":"Read","emoji":"⭐",
                    "colorHex":"#34C759","isArchived":false,"sortOrder":0,
                    "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}],
         "entries":[],"groups":[],"serverTime":"2026-09-26T10:00:00.000Z"}
        """#))

        await sync.sync(context: context)

        XCTAssertNil(sync.syncError)
        XCTAssertEqual(server.paths, ["/v1/sync/push", "/v1/sync/pull"])
        let pushed = try XCTUnwrap(server.requests.first?.json?["habits"] as? [[String: Any]])
        XCTAssertEqual(pushed.first?["id"] as? String, habit.id.uuidString)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id],
                       "the habit survived the full pull that followed its push")
    }

    /// A push that fails — offline, 5xx, 401 — must leave everything as it was: the deletions
    /// still queued (until 1.2.3 the queue was cleared before the push, so one failed push lost
    /// the deletion and the habit came back on every other device), the cursor where it was,
    /// and no pull.
    func testFailedPushKeepsTheQueueAndTheCursorAndDoesNotPull() async {
        queue.trackHabit("habit-deleted-offline")
        local.defaults.set("2026-09-20T00:00:00.000Z", forKey: cursorKey)
        server.on("POST", "/v1/sync/push", respond: .init(status: 500, body: #"{"error":"Internal error"}"#))
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.pullBody()))

        await sync.sync(context: context)

        XCTAssertNotNil(sync.syncError)
        XCTAssertEqual(server.paths, ["/v1/sync/push"])
        XCTAssertEqual(queue.pending().habits, ["habit-deleted-offline"])
        XCTAssertEqual(local.defaults.string(forKey: cursorKey), "2026-09-20T00:00:00.000Z")
        XCTAssertNil(sync.lastSyncTime)
        XCTAssertFalse(sync.isSyncing, "a failed sync must not leave the service stuck")
    }

    /// A deletion queued while the push is in flight was not in that push, so acknowledging it
    /// would lose it for good. Only the ids actually sent may be removed.
    func testSuccessfulSyncAcknowledgesOnlyTheIdsItSent() async throws {
        queue.trackHabit("sent")
        queue.trackSharedEntry("sent-by-widget")
        let queue = self.queue!
        server.on("POST", "/v1/sync/push") { _ in
            // The user deletes another habit while this request is on the wire.
            queue.trackHabit("deleted-during-push")
            return .ok(#"{"ok":true}"#)
        }
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.pullBody()))

        await sync.sync(context: context)

        XCTAssertNil(sync.syncError)
        let body = try XCTUnwrap(server.requests.first?.json)
        XCTAssertEqual(body["deletedHabitIds"] as? [String], ["sent"])
        XCTAssertEqual(body["deletedEntryIds"] as? [String], ["sent-by-widget"])
        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch(habits: ["deleted-during-push"]))
    }

    // MARK: - Cursor

    /// The first sync pulls everything; the cursor it stores is the server's clock minus the
    /// 60 s overlap (never this device's clock), and the next pull sends it as a real query
    /// item — not a path component, which percent-encoded the `?` and 404'd every incremental
    /// pull once.
    func testCursorIsServerTimeMinusOverlapAndIsSentOnTheNextPull() async throws {
        stubHappyServer(serverTime: "2026-09-26T10:00:00.000Z")

        await sync.sync(context: context)
        XCTAssertNil(sync.syncError)
        // Counts guarded before indexing: an out-of-range index crashes the HOST app (Stride.app,
        // with Sentry running), not just this test.
        guard server.requests.count == 2 else { return XCTFail("first sync: \(server.requests.count) requests, expected push + pull") }
        XCTAssertNil(server.requests[1].query["since"], "no cursor yet: a full pull")
        XCTAssertEqual(local.defaults.string(forKey: cursorKey), "2026-09-26T09:59:00.000Z")

        await sync.sync(context: context)
        guard server.requests.count == 4 else { return XCTFail("second sync: \(server.requests.count) requests in total, expected 4") }
        let secondPull = server.requests[3]
        XCTAssertEqual(secondPull.path, "/v1/sync/pull")
        XCTAssertEqual(secondPull.query["since"], "2026-09-26T09:59:00.000Z")
    }

    /// The push went through, so its deletions are acknowledged — but the pull did not, so the
    /// cursor must stay put: advancing it would skip everything written since the old one.
    func testFailedPullDoesNotAdvanceTheCursor() async {
        queue.trackGroup("group-gone")
        local.defaults.set("2026-09-20T00:00:00.000Z", forKey: cursorKey)
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        server.on("GET", "/v1/sync/pull") { _ in throw URLError(.timedOut) }

        await sync.sync(context: context)

        XCTAssertNotNil(sync.syncError)
        XCTAssertEqual(local.defaults.string(forKey: cursorKey), "2026-09-20T00:00:00.000Z")
        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch(), "the push itself was accepted")
    }

    // MARK: - The Settings footer

    /// `syncError` is the Settings footer. The server answers this build (it sends
    /// X-Stride-Client) with the machine code in `error` — `{error:"rate_limited", code, message}`
    /// — and the footer must read as a sentence, not "rate_limited".
    func testRateLimitedSyncShowsASentenceNotTheCode() async {
        server.on("POST", "/v1/sync/push", respond: .init(status: 429, body: #"""
        {"error":"rate_limited","code":"rate_limited",
         "message":"Too many sync requests, please try again later","retryAfterSeconds":30}
        """#))

        await sync.sync(context: context)

        let shown = sync.syncError
        XCTAssertEqual(shown, appLocalized("Too many sync requests. Please try again in a few minutes."))
        XCTAssertNotEqual(shown, "rate_limited")
        XCTAssertFalse(shown?.contains("rate_limited") ?? true)
    }

    /// A code this build has no sentence for shows the server's `message`.
    func testUnknownCodeShowsTheServersMessage() async {
        server.on("POST", "/v1/sync/push", respond: .init(status: 400, body: #"""
        {"error":"invalid_payload","code":"invalid_payload","message":"Sync data was malformed (\"habits\" must be an array)."}
        """#))

        await sync.sync(context: context)

        XCTAssertEqual(sync.syncError, #"Sync data was malformed ("habits" must be an array)."#)
    }

    // MARK: - Overlap with sign-out and with callers that need the result

    private static func pullBody(withHabit id: UUID) -> String {
        #"""
        {"habits":[{"id":"\#(id.uuidString)","name":"From the account","emoji":"⭐",
                    "colorHex":"#34C759","isArchived":false,"sortOrder":0,
                    "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}],
         "entries":[],"groups":[],"serverTime":"2026-09-26T10:00:00.000Z"}
        """#
    }

    private func waitForRequest(_ path: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.paths.contains(path) {
            guard ContinuousClock.now < deadline else { return XCTFail("no request to \(path)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `sync` says whether THIS call pushed and pulled. The second of two overlapping calls did
    /// neither, and used to look like a success to Erase Local Data (syncError stayed nil).
    func testSyncReportsWhetherThisCallRan() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let body = Self.pullBody()
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .ok(body)
        }

        let first = Task { await sync.sync(context: context) }
        try await waitForRequest("/v1/sync/push")
        let overlapping = await sync.sync(context: context)
        let firstRan = await first.value

        XCTAssertFalse(overlapping)
        XCTAssertTrue(firstRan)
        XCTAssertEqual(server.paths, ["/v1/sync/push", "/v1/sync/pull"])

        server.on("POST", "/v1/sync/push", respond: .init(status: 500, body: #"{"error":"boom"}"#))
        let failed = await sync.sync(context: context)
        XCTAssertFalse(failed)
    }

    /// Erase's pre-erase sync: it waits out a sync already in flight (which may have started
    /// before the edits it must push), then runs its own and reports that one.
    func testSyncAfterInFlightWaitsThenRunsItsOwn() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let body = Self.pullBody()
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .ok(body)
        }

        let inFlight = Task { await sync.sync(context: context) }
        try await waitForRequest("/v1/sync/push")
        let own = await sync.syncAfterInFlight(context: context)
        _ = await inFlight.value

        XCTAssertTrue(own)
        XCTAssertEqual(server.paths, ["/v1/sync/push", "/v1/sync/pull", "/v1/sync/push", "/v1/sync/pull"])
    }

    /// A launch or foreground sync still awaiting its pull when the user signs out (or erases):
    /// its response used to be applied to the store and its cursor written AFTER sign-out had
    /// cleared it — the account's rows reappeared on an erased device, or the next sign-in
    /// pulled incrementally from that cursor and never re-downloaded the account.
    func testASyncInFlightAtSignOutWritesNothingAfterIt() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let body = Self.pullBody(withHabit: UUID())
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .ok(body)
        }

        let inFlight = Task { await sync.sync(context: context) }
        try await waitForRequest("/v1/sync/pull")
        sync.resetSyncState()   // what AuthService.logout calls
        let ran = await inFlight.value

        XCTAssertFalse(ran)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 0, "nothing applied after sign-out")
        XCTAssertNil(local.defaults.string(forKey: cursorKey), "no cursor written after sign-out")
        XCTAssertNil(sync.lastSyncTime)
        XCTAssertNil(sync.syncError, "signing out is not an error to show")
        XCTAssertFalse(sync.isSyncing)

        // The next sync is an ordinary full pull again.
        stubHappyServer()
        let next = await sync.sync(context: context)
        XCTAssertTrue(next)
        XCTAssertNil(server.requests.last?.query["since"])
    }
}
