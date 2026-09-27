import XCTest
import SwiftData
@testable import Stride

/// Erase Local Data and Restore from Backup as Settings runs them (DataExportService), against a
/// stubbed server: the real AuthService, SyncService and APIClient sharing one token store, as
/// they share the Keychain item in the app, and a scratch defaults suite for the cursor.
///
/// StrideTests proves the store half (DataBackup.eraseLocalData / restore). What only this file
/// can prove is the order around sync and sign-in that decides whether the account comes back.
@MainActor
final class LocalDataFlowTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var queue: SyncDeletionQueue!
    private var sync: SyncService!

    private let cursorKey = "stride_sync_cursor"
    private let oldCursor = "2026-09-20T10:00:00.000Z"

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        tokens = InMemoryTokenStore()
        local = ScratchDefaults("flow.local")
        appGroup = ScratchDefaults("flow.appGroup")
        queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue)
    }

    override func tearDown() {
        server.stop()
        local.remove()
        appGroup.remove()
        sync = nil
        queue = nil
        tokens = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func makeAuth() -> AuthService {
        let sync = self.sync!
        return AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                           resetSyncState: { sync.resetSyncState() })
    }

    private static let emptyPull = #"""
    {"habits":[],"entries":[],"groups":[],"serverTime":"2026-09-26T10:00:00.000Z"}
    """#

    private func seedStore() throws {
        let habit = Habit(name: "Read")
        habit.records.append(HabitRecord(date: HabitCalendar.dayKey(for: Date())))
        context.insert(habit)
        context.insert(HabitGroup(name: "Morning"))
        try context.save()
    }

    private func habitCount() throws -> Int { try context.fetchCount(FetchDescriptor<Habit>()) }

    // MARK: - Erase

    /// The launch session check failed offline: no user loaded, but the token and the old
    /// cursor are still stored. Erase used to decide on `isLoggedIn` alone, skip the sync and
    /// the sign-out, and leave both behind — the next online launch was signed in again and
    /// pulled incrementally from the old cursor into an empty store, never re-downloading the
    /// account. It must treat the stored token as a session: sync, sign out, clear the cursor.
    func testEraseWithAStoredTokenButNoUserSyncsSignsOutAndClearsTheCursor() async throws {
        tokens.save("sess-current")
        local.defaults.set(oldCursor, forKey: cursorKey)
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.timedOut) }
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.emptyPull))
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        try seedStore()
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        XCTAssertFalse(auth.isLoggedIn, "precondition: no user loaded")

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)

        XCTAssertEqual(outcome, .erased)
        XCTAssertEqual(try habitCount(), 0)
        XCTAssertNil(tokens.read(), "signed out")
        XCTAssertNil(local.defaults.string(forKey: cursorKey), "the next sign-in does a full pull")
        let paths = server.paths.filter { $0 != "/v1/auth/session" }
        XCTAssertEqual(paths, ["/v1/sync/push", "/v1/sync/pull", "/v1/auth/logout"],
                       "unsynced edits reach the account before this device forgets them")
    }

    /// Same state, still offline: the sync fails, so nothing is erased and nothing is signed out.
    /// The user was promised the account keeps everything.
    func testEraseWithASessionErasesNothingWhenTheSyncFails() async throws {
        tokens.save("sess-current")
        local.defaults.set(oldCursor, forKey: cursorKey)
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        server.on("POST", "/v1/sync/push") { _ in throw URLError(.notConnectedToInternet) }
        try seedStore()
        let auth = makeAuth()
        await auth.waitForSessionRestore()

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)

        XCTAssertEqual(outcome, .syncFailed)
        XCTAssertEqual(try habitCount(), 1)
        XCTAssertEqual(tokens.read(), "sess-current")
        XCTAssertEqual(local.defaults.string(forKey: cursorKey), oldCursor)
    }

    /// Signed out: nothing to sync or sign out of, no request at all — and the cursor goes
    /// anyway, since after an erase no incremental pull from it can be right.
    func testSignedOutEraseTouchesNoServerAndResetsTheCursor() async throws {
        local.defaults.set(oldCursor, forKey: cursorKey)
        try seedStore()
        let auth = makeAuth()

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)

        XCTAssertEqual(outcome, .erased)
        XCTAssertEqual(try habitCount(), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitGroup>()), 0)
        XCTAssertNil(local.defaults.string(forKey: cursorKey))
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// A launch or foreground sync already in flight when Erase is tapped: erase waits for it,
    /// then runs its own sync, and signs out only after that one succeeded.
    func testEraseWaitsForASyncInFlightAndRunsItsOwn() async throws {
        tokens.save("sess-current")
        server.on("GET", "/v1/auth/session",
                  respond: .ok(#"{"user":{"id":1,"email":"me@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let emptyPull = Self.emptyPull
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return .ok(emptyPull)
        }
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        try seedStore()
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isLoggedIn)

        // (The stub's empty full pulls also clear the seeded habit, which a real server would
        // return after the push; this test is about the order of requests only.)
        let inFlight = Task { await sync.sync(context: context) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.paths.contains("/v1/sync/push") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)
        _ = await inFlight.value

        XCTAssertEqual(outcome, .erased)
        let paths = server.paths.filter { $0 != "/v1/auth/session" }
        XCTAssertEqual(paths, ["/v1/sync/push", "/v1/sync/pull", "/v1/sync/push", "/v1/sync/pull",
                               "/v1/auth/logout"])
        XCTAssertNil(local.defaults.string(forKey: cursorKey))
        XCTAssertFalse(auth.isLoggedIn)
    }

    // MARK: - Restore

    /// A full pull already awaiting its response when Restore is confirmed. Restoring at once
    /// let that pull land afterwards and delete every restored row the account did not hold;
    /// the restore waits for it instead, and what it restored stays.
    func testRestoreWaitsForASyncInFlight() async throws {
        tokens.save("sess-current")
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let emptyPull = Self.emptyPull
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .ok(emptyPull)   // the account holds none of the backup's ids
        }
        let document = try backupOfOneHabit()

        let inFlight = Task { await sync.sync(context: context) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.paths.contains("/v1/sync/pull") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await DataExportService.restore(document, into: context, sync: sync, deletionQueue: queue)
        _ = await inFlight.value

        XCTAssertEqual(try habitCount(), 1, "the late full pull did not remove the restored habit")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 1)
    }

    /// The deletion the restore undoes is still queued; restoring withdraws it, so the next
    /// sign-in's push does not tombstone the restored habit on the server.
    func testRestoreWithdrawsTheQueuedDeletionItUndoes() async throws {
        let document = try backupOfOneHabit()
        let habit = try XCTUnwrap(document.habits.first)
        queue.trackHabit(habit.id.uuidString)
        queue.trackSharedEntry(try XCTUnwrap(habit.records.first).id.uuidString)

        try await DataExportService.restore(document, into: context, sync: sync, deletionQueue: queue)

        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch())
    }

    private func backupOfOneHabit() throws -> BackupDocument {
        let source = try ModelContainer(for: Schema([Habit.self, HabitRecord.self, HabitGroup.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let habit = Habit(name: "Meditate")
        habit.records.append(HabitRecord(date: HabitCalendar.dayKey(for: Date())))
        source.mainContext.insert(habit)
        try source.mainContext.save()
        return try DataBackup.snapshot(of: source.mainContext)
    }
}
