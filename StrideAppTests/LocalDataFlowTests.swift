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
    private var recovery: ScratchRecoveryLog!
    /// Where the export-file tests' `StrideExport-*` directories go instead of the host app's tmp.
    private var exportRoot: URL!

    /// The account the stubbed session belongs to (`{"id":1,...}` below).
    private let accountID = "1"
    /// A few days old: inside the engine's cursor lifetime whatever the clock says.
    private let oldCursor = SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-6 * 86_400))
    private var cursors: SyncDefaultsCursorStore { SyncDefaultsCursorStore(defaults: local.defaults) }
    private var owners: SyncOwnerStore { SyncOwnerStore(defaults: local.defaults) }

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
        recovery = ScratchRecoveryLog()
        exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-exports-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        server.stop()
        local.remove()
        appGroup.remove()
        recovery.remove()
        recovery = nil
        try? FileManager.default.removeItem(at: exportRoot)
        exportRoot = nil
        sync = nil
        queue = nil
        tokens = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    /// The real AuthService and SyncService, wired as the app wires them: sign-out ends the
    /// sync session, and SyncService asks AuthService who is signed in. Call after seeding the
    /// token — AuthService checks it when created, as at launch.
    @discardableResult
    private func makeAuth() -> AuthService {
        let auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                               defaults: local.defaults, onSignOut: { [unowned self] in self.sync.signedOut() })
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: auth, recoveryLog: recovery.log)
        return auth
    }

    /// A 1.3.1 device that has synced as account 1: the session's account remembered (so a
    /// failed launch check still knows whose token it is), the store owned by it, a cursor.
    private func seedSyncedDevice() {
        local.defaults.set(["id": accountID, "email": "me@example.com"], forKey: AuthService.sessionAccountKey)
        owners.set(SyncOwner(SyncAccount(id: accountID, email: "me@example.com")))
        cursors.setCursor(oldCursor, for: accountID)
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
        seedSyncedDevice()
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
        XCTAssertNil(cursors.cursor(for: accountID), "the next sign-in does a full pull")
        XCTAssertNil(owners.owner, "an erased store has no owner: the next account adopts it")
        let paths = server.paths.filter { $0 != "/v1/auth/session" }
        XCTAssertEqual(paths, ["/v1/sync/push", "/v1/sync/pull", "/v1/auth/logout"],
                       "unsynced edits reach the account before this device forgets them")
    }

    /// Same state, still offline: the sync fails, so nothing is erased and nothing is signed out.
    /// The user was promised the account keeps everything.
    func testEraseWithASessionErasesNothingWhenTheSyncFails() async throws {
        tokens.save("sess-current")
        seedSyncedDevice()
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        server.on("POST", "/v1/sync/push") { _ in throw URLError(.notConnectedToInternet) }
        try seedStore()
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        let shared = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: exportRoot)

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync, exportRoot: exportRoot)

        XCTAssertEqual(outcome, .syncFailed)
        XCTAssertEqual(try habitCount(), 1)
        XCTAssertEqual(tokens.read(), "sess-current")
        XCTAssertEqual(cursors.cursor(for: accountID), oldCursor)
        XCTAssertEqual(server.paths.filter { $0 != "/v1/auth/session" }, ["/v1/sync/push"], "the push was tried")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path), "nothing erased, no export file removed")
    }

    /// Signed out: nothing to sync or sign out of, no request at all — and the cursor goes
    /// anyway, since after an erase no incremental pull from it can be right.
    func testSignedOutEraseTouchesNoServerAndResetsTheCursor() async throws {
        seedSyncedDevice()
        try seedStore()
        let auth = makeAuth()

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)

        XCTAssertEqual(outcome, .erased)
        XCTAssertEqual(try habitCount(), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitGroup>()), 0)
        XCTAssertNil(cursors.cursor(for: accountID))
        XCTAssertNil(owners.owner)
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// A session found gone at launch leaves the device signed out with Today's "Sign in again to
    /// keep syncing" (`AuthService.sessionExpired`, persisted). Erasing the device leaves nothing
    /// to keep syncing, so the erase ends the row too (phase C leftovers, the owner's decision 2):
    /// it used to stay, on an empty device, until a sign-in.
    func testASignedOutEraseEndsTheSignInAgainRow() async throws {
        local.defaults.set(true, forKey: AuthService.sessionExpiredKey)
        try seedStore()
        let auth = makeAuth()
        XCTAssertTrue(auth.sessionExpired, "precondition: the row a revoked session left")
        XCTAssertFalse(auth.hasStoredSession)

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)

        XCTAssertEqual(outcome, .erased)
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertFalse(local.defaults.bool(forKey: AuthService.sessionExpiredKey), "and not back at the next launch")
        XCTAssertFalse(makeAuth().sessionExpired)
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// A launch or foreground sync already in flight when Erase is tapped: erase waits for it,
    /// then runs its own sync, and signs out only after that one succeeded.
    func testEraseWaitsForASyncInFlightAndRunsItsOwn() async throws {
        tokens.save("sess-current")
        seedSyncedDevice()
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

        // (The stub's pulls are incremental and empty — the device has a cursor — so nothing is
        // deleted by them; this test is about the order of requests only.)
        let inFlight = Task { await sync.sync(context: context) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.paths.contains("/v1/sync/push") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)
        _ = await inFlight.value

        XCTAssertEqual(outcome, .erased)
        let paths = server.paths.filter { $0 != "/v1/auth/session" }
        // The in-flight sync pushed the seeded rows; erase's own sync then had nothing left to
        // push (1.3.1 pushes only pending rows) and pulled.
        XCTAssertEqual(paths, ["/v1/sync/push", "/v1/sync/pull", "/v1/sync/pull", "/v1/auth/logout"])
        XCTAssertNil(cursors.cursor(for: accountID))
        XCTAssertFalse(auth.isLoggedIn)
    }

    // MARK: - Export files in tmp (E2E S-DEL)

    /// The `StrideExport-*` directories under `root`, by name.
    private func exportDirectories(in root: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { $0.hasPrefix(DataExportService.exportDirectoryPrefix) })
    }

    /// Every export ever shared stayed in tmp, a deleted account's backup and recovered edits
    /// included. The launch's cleanup takes every export directory, and nothing else there.
    func testRemovingExportFilesTakesEveryExportDirectoryAndNothingElse() throws {
        _ = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup-2026-09-29.json", in: exportRoot)
        _ = try DataExportService.writeExportFile(Data("[]".utf8), named: "Stride-RecoveredEdits-2026-09-29.json", in: exportRoot)
        let unrelated = exportRoot.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        XCTAssertEqual(exportDirectories(in: exportRoot).count, 2, "precondition")

        XCTAssertEqual(DataExportService.removeExportFiles(in: exportRoot), 2)

        XCTAssertEqual(exportDirectories(in: exportRoot), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(DataExportService.removeExportFiles(in: exportRoot), 0, "nothing left to do")
    }

    /// Erase Local Data removes them with the data they copy — all but the exports of the last
    /// ten minutes (1.4.0, RELEASE-1.4.0.md D6): a share of the backup just made of this data can
    /// still be loading, and that file is the one copy of it. The sweep the erase schedules takes
    /// those once they are past the window, and spares an export made after the erase (here with
    /// its delay shortened, and the spared one backdated as ten minutes on).
    func testAnEraseRemovesTheExportFilesButTheLastTenMinutes() async throws {
        let delay = DataExportService.deferredExportSweepDelay
        DataExportService.deferredExportSweepDelay = .milliseconds(500)
        addTeardownBlock { DataExportService.deferredExportSweepDelay = delay }
        try seedStore()
        let auth = makeAuth()
        let old = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: exportRoot)
        let made = Date().addingTimeInterval(-(DataExportService.exportGracePeriod + 60))
        try FileManager.default.setAttributes([.creationDate: made, .modificationDate: made],
                                              ofItemAtPath: old.deletingLastPathComponent().path)
        let fresh = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: exportRoot)

        let outcome = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync, exportRoot: exportRoot)

        XCTAssertEqual(outcome, .erased)
        XCTAssertEqual(exportDirectories(in: exportRoot), [fresh.deletingLastPathComponent().lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a share of it may still be loading")

        // Ten minutes on, and an export made since the erase.
        let tenMinutesOn = Date().addingTimeInterval(-(DataExportService.exportGracePeriod + 5))
        try FileManager.default.setAttributes([.creationDate: tenMinutesOn, .modificationDate: tenMinutesOn],
                                              ofItemAtPath: fresh.deletingLastPathComponent().path)
        let afterTheErase = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: exportRoot)
        let deadline = ContinuousClock.now + .seconds(10)
        while FileManager.default.fileExists(atPath: fresh.deletingLastPathComponent().path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(exportDirectories(in: exportRoot), [afterTheErase.deletingLastPathComponent().lastPathComponent],
                       "the erase's own deferred sweep took what it spared, and only that")
    }

    // MARK: - Restore

    /// A full pull already awaiting its response when Restore is confirmed. Restoring at once
    /// let that pull land afterwards and delete every restored row the account did not hold;
    /// the restore waits for it instead, and what it restored stays.
    func testRestoreWaitsForASyncInFlight() async throws {
        tokens.save("sess-current")
        server.on("GET", "/v1/auth/session",
                  respond: .ok(#"{"user":{"id":1,"email":"me@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let emptyPull = Self.emptyPull
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .ok(emptyPull)   // the account holds none of the backup's ids
        }
        let document = try backupOfOneHabit()
        makeAuth()

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
        makeAuth()

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
