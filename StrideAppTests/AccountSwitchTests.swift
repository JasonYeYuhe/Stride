import XCTest
import SwiftData
import SwiftUI
import UIKit
@testable import Stride

/// The account screen's half of M2 account isolation (DEV-PLAN-1.3.md M2, "Account isolation";
/// Acceptance (5)), through the real AuthService sign-in, the real SyncService and engine, and a
/// stubbed server: what the screen calls (`settleSignIn`, `startFromSignedInAccountsData`,
/// `uploadLocalHabits`, Cancel's `logout`) and what must NOT happen until it is called — any
/// sync request, from any entry point. The screen's layout is checked by the screenshot
/// scenarios (`-demoScenario accountConflict | accountUnknownOwner`); here it is the rules.
///
/// Accounts: "magic-A" signs into 7 / a@example.com (tok-A), "magic-B" into 8 / b@example.com
/// (tok-B), as in SyncServiceTests.
@MainActor
final class AccountSwitchTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var queue: SyncDeletionQueue!
    private var recovery: ScratchRecoveryLog!
    private var sync: SyncService!
    private var auth: AuthService!

    private let accountA = SyncAccount(id: "7", email: "a@example.com")
    private let accountB = SyncAccount(id: "8", email: "b@example.com")
    private var owners: SyncOwnerStore { SyncOwnerStore(defaults: local.defaults) }
    private var cursors: SyncDefaultsCursorStore { SyncDefaultsCursorStore(defaults: local.defaults) }
    private var backoff: SyncBackoffStore { SyncBackoffStore(defaults: local.defaults) }
    private var marks: SyncMarksProof { SyncMarksProof(defaults: local.defaults) }
    private let recentCursor = SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400))

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        tokens = InMemoryTokenStore()
        local = ScratchDefaults("account.local")
        appGroup = ScratchDefaults("account.appGroup")
        queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        recovery = ScratchRecoveryLog()
        stubAuth()
        auth = makeAuth()
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: auth, recoveryLog: recovery.log)
    }

    override func tearDown() {
        // Before the server stops: closing a hosted sheet runs its onDismiss sync.
        tearDownHostedToday()
        server.stop()
        local.remove()
        appGroup.remove()
        recovery.remove()
        recovery = nil
        sync = nil
        auth = nil
        queue = nil
        tokens = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// A login link's token must look like one (`LoginLink.isPlausibleToken`: 16+ characters).
    private nonisolated static let linkTokenB = "magic-link-for-account-B"

    private nonisolated static func verifyResponse(id: Int, email: String, token: String) -> String {
        #"{"ok":true,"user":{"id":\#(id),"email":"\#(email)","created_at":"2026-09-01 10:00:00"},"sessionToken":"\#(token)"}"#
    }

    private func stubAuth() {
        server.on("POST", "/v1/auth/verify") { request in
            switch request.json?["token"] as? String {
            case "magic-A": return .ok(Self.verifyResponse(id: 7, email: "a@example.com", token: "tok-A"))
            case "magic-A2": return .ok(Self.verifyResponse(id: 7, email: "a@example.com", token: "tok-A2"))
            case "magic-B", Self.linkTokenB:
                return .ok(Self.verifyResponse(id: 8, email: "b@example.com", token: "tok-B"))
            default: return .init(status: 400, body: #"{"error":"Invalid or expired login link"}"#)
            }
        }
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        server.on("POST", "/v1/auth/delete-account", respond: .ok(#"{"ok":true}"#))
    }

    /// The real AuthService over the stub, wired to `sync` as the app wires it to
    /// `SyncService.shared` — sign-out, sign-in, account deletion and the 401 flag included.
    private func makeAuth() -> AuthService {
        AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens, defaults: local.defaults,
                    onSignOut: { [weak self] in self?.sync?.signedOut() },
                    onSignIn: { [weak self] in self?.sync?.signedIn() },
                    onAccountDeleted: { [weak self] account in
                        guard let self else { return }
                        try? self.sync.accountDeleted(account, in: self.context)
                    },
                    reauthRequested: { [weak self] in self?.sync?.needsReauth ?? false })
    }

    /// `/v1/auth/session` as the server answers it for `user` (nil: `{user: null}`).
    private nonisolated static func sessionResponse(id: Int?, email: String = "") -> String {
        guard let id else { return #"{"user":null}"# }
        return #"{"user":{"id":\#(id),"email":"\#(email)","created_at":"2026-09-01 10:00:00"}}"#
    }

    private func signIn(_ magic: String) async {
        let ok = await auth.verifyToken(magic)
        XCTAssertTrue(ok, "precondition: \(magic) signs in")
    }

    /// A's store: one habit with a check-in, a queued deletion, a recovered edit, a backoff
    /// window and a live cursor — everything "Start from this account's data" must clear.
    @discardableResult
    private func seedAsStore() throws -> Habit {
        owners.set(SyncOwner(accountA))
        cursors.setCursor(recentCursor, for: accountA.id)
        let habit = Habit(name: "A's habit")
        context.insert(habit)
        habit.records = [HabitRecord(date: Date())]
        try context.save()
        queue.trackHabit("a-deleted-offline")
        let row = DataBackup.snapshot(habits: [Habit(name: "A's recovered edit")], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: accountA.id)
        backoff.recordFailure(.transient, for: accountA.id)
        return habit
    }

    private func stubSyncServer(pullHabits: [String] = []) {
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull") { request in
            .ok(request.query["since"] == nil ? SyncStubBodies.pull(habits: pullHabits) : SyncStubBodies.pull())
        }
    }

    private var syncRequests: [StubServer.Request] { server.requests.filter { $0.path.hasPrefix("/v1/sync/") } }

    private var pushedHabitIDs: Set<String> {
        Set(syncRequests.filter { $0.path == "/v1/sync/push" }
            .flatMap { ($0.json?["habits"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String })
    }

    private func conflict(after continuation: SyncService.SignInContinuation,
                          file: StaticString = #filePath, line: UInt = #line) throws -> SyncOwnerConflict {
        guard case .chooseAccountData(let conflict) = continuation else {
            XCTFail("expected the account screen, got \(continuation)", file: file, line: line)
            throw XCTSkip("no conflict")
        }
        return conflict
    }

    // MARK: - The gate

    /// Signed into B on a device holding A's habits: the sign-in continues with the account
    /// screen, and NO entry point makes a sync request until its choice — Sync Now, the launch /
    /// foreground sync, Full resync, Erase's sync-after-in-flight, "Restore as new copies" on a
    /// held row, and another sign-in continuation. 1.3.0 pushed A's habits into B's account here
    /// (the data-leak fix, Acceptance (5): "no sync request from that device until the choice").
    func testTheOwnerGateBlocksEveryEntryPointUntilTheChoice() async throws {
        try seedAsStore()
        let held = Habit(name: "Held not_owned")
        context.insert(held)
        held.syncHoldReason = SyncHoldReason.notOwned.rawValue
        held.syncHoldStamp = held.stamp
        try context.save()
        stubSyncServer()
        await signIn("magic-B")

        let conflict = try conflict(after: sync.settleSignIn(in: context))

        XCTAssertEqual(conflict, SyncOwnerConflict(owner: SyncOwner(accountA), signedIn: accountB))
        XCTAssertFalse(conflict.isOwnerUnknown)
        XCTAssertEqual(sync.ownerConflict, conflict)
        let userInitiated = await sync.sync(context: context)
        let automatic = await sync.sync(context: context, trigger: .automatic)
        let fullResync = await sync.sync(context: context, options: .fullResync)
        let afterInFlight = await sync.syncAfterInFlight(context: context)
        let converted = try await sync.restoreHeldRowsAsNewCopies(.notOwned, in: context)
        XCTAssertEqual(sync.settleSignIn(in: context), .chooseAccountData(conflict), "asked again, the same question")

        XCTAssertEqual([userInitiated, automatic, fullResync, afterInFlight], [false, false, false, false])
        XCTAssertEqual(converted.rows.habits, 1, "precondition: the conversion ran, and would have synced")
        XCTAssertEqual(syncRequests.count, 0, "no sync request of any kind: \(syncRequests.map(\.path))")
        XCTAssertEqual(server.paths, ["/v1/auth/verify"])
        XCTAssertEqual(owners.owner?.id, accountA.id, "the owner does not change until the user chooses")
        XCTAssertEqual(cursors.cursor(for: accountA.id), recentCursor)
        XCTAssertEqual(queue.pending().habits, ["a-deleted-offline"])
        XCTAssertNil(sync.syncError, "a pending choice is not an error")
    }

    /// The one-tap link ends in the same place as a typed code: `handleLoginLink` signs in, and
    /// the continuation StrideApp asks for is the account screen with the same conflict.
    func testALoginLinkContinuesWithTheSameScreen() async throws {
        try seedAsStore()
        stubSyncServer()
        let url = try XCTUnwrap(URL(string: "https://stride-api.colorarchive.me/login?token=\(Self.linkTokenB)"))

        let outcome = await auth.handleLoginLink(url)
        let conflict = try conflict(after: sync.settleSignIn(in: context))

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(conflict.signedIn, accountB)
        XCTAssertEqual(conflict.owner?.id, accountA.id)
        let ran = await sync.sync(context: context)   // StrideApp's post-link sync
        XCTAssertFalse(ran)
        XCTAssertTrue(syncRequests.isEmpty)
    }

    // MARK: - Export, then Start from this account's data

    /// The screen's order: Export (A's v2 backup, naming A, and A's recovered edits), then Start
    /// — A's rows, queue, cursor, backoff and recovery log go, B owns the store, and B's data
    /// comes down in a FULL pull on B's token. Nothing of A's is pushed into B.
    func testExportThenStartErasesAndFullPullsTheNewAccount() async throws {
        try seedAsStore()
        cursors.setCursor(recentCursor, for: accountB.id)   // B synced on this device long ago
        let fromB = Habit(name: "B's habit")
        stubSyncServer(pullHabits: [SyncStubBodies.habit(fromB)])
        await signIn("magic-B")
        let conflict = try conflict(after: sync.settleSignIn(in: context))

        // Export a backup — written as the screen's button writes it: the OWNER's account in the
        // file, and A's rows in it.
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-exports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: exportRoot) }
        let backup = sync.backupFile(for: conflict)
        XCTAssertEqual(backup, .backup(account: BackupAccount(id: accountA.id, email: accountA.email)))
        let backupFile = try await DataExportService.write(backup, container: container, sync: sync, in: exportRoot)
        let document = try DataBackup.decode(try Data(contentsOf: backupFile.url))
        XCTAssertEqual(document.accountId, accountA.id)
        XCTAssertEqual(document.habits.map(\.name), ["A's habit"])
        // …and the recovery log, which has a line.
        XCTAssertEqual(sync.holdings(for: conflict, in: context),
                       SyncOwnerHoldings(habits: 1, checkIns: 1, groups: 0, queuedDeletions: 1, recoveredEdits: 1))
        let edits = sync.recoveredEditsFile(for: conflict)
        XCTAssertEqual(edits, .recoveredEdits(accountID: accountA.id))
        let editsFile = try await DataExportService.write(edits, container: container, sync: sync, in: exportRoot)
        let export = try SyncRecoveryLog.decodeExport(try Data(contentsOf: editsFile.url))
        XCTAssertEqual(export.accountId, accountA.id)
        XCTAssertEqual(export.items.count, 1)
        XCTAssertEqual(editsFile.recoveredEditsTotal, 1)
        XCTAssertTrue(syncRequests.isEmpty, "exporting makes no request")

        let ran = await sync.startFromSignedInAccountsData(conflict, in: context)

        XCTAssertTrue(ran)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.name), ["B's habit"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 0, "A's check-in went with it")
        XCTAssertEqual(owners.owner?.id, accountB.id)
        XCTAssertNil(sync.ownerConflict)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 0)
        XCTAssertNil(backoff.state(for: accountA.id))
        XCTAssertNil(cursors.cursor(for: accountA.id))
        XCTAssertEqual(syncRequests.map(\.path), ["/v1/sync/pull", "/v1/sync/pull"], "nothing of A's pushed")
        XCTAssertNil(syncRequests.first?.query["since"], "a full pull, not B's old cursor")
        XCTAssertTrue(syncRequests.allSatisfy { $0.authorization == "Bearer tok-B" })
        XCTAssertFalse(pushedHabitIDs.contains { _ in true })
    }

    // MARK: - Cancel

    /// Cancel signs out of B and changes nothing else: A's rows, owner, cursor, queue, recovered
    /// edits and backoff are as they were, and no sync request was made. Signing back into A
    /// afterwards resumes.
    ///
    /// "Leaves this device as it is" includes Today's "Sign in again" (review accounts-2). Here A's
    /// session was found gone at launch, and B's sign-in came from that row: the sign-in ended the
    /// row (a user was loaded), and a plain Log Out as the Cancel cleared it again, so A's pending
    /// edits sat behind a bare "Sign In" — the 1.3.0 state the row exists to end. The app is quit
    /// on the account screen and launched again before the Cancel — the screen cannot be swiped
    /// away, and Settings' owner-choice row reopens it — so what the Cancel restores must outlive
    /// the process that signed in.
    func testCancelSignsOutAndLeavesTheStoreAndTheOwner() async throws {
        let habit = try seedAsStore()
        tokens.save("tok-A-revoked")
        server.on("GET", "/v1/auth/session") { request in
            .ok(request.authorization == "Bearer tok-B" ? Self.sessionResponse(id: 8, email: "b@example.com")
                                                          : Self.sessionResponse(id: nil))
        }
        relaunchAuth()
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.sessionExpired, "precondition: A's session was found gone at launch")
        stubSyncServer()
        await signIn("magic-B")
        XCTAssertFalse(auth.sessionExpired, "a sign-in ends the row…")
        _ = try conflict(after: sync.settleSignIn(in: context))

        // Quit on the account screen, launched again: B's session checks out, the launch sync
        // meets the conflict and blocks with no request, and Settings offers the screen again.
        relaunchAuth()
        await auth.waitForSessionRestore()
        XCTAssertEqual(auth.userEmail, "b@example.com")
        let launchSync = await sync.sync(context: context, trigger: .automatic)
        XCTAssertFalse(launchSync)
        XCTAssertNotNil(sync.ownerConflict, "Settings' owner-choice row")
        XCTAssertFalse(auth.sessionExpired)

        await auth.cancelSignIn()   // AccountSwitchView's Cancel, reopened from Settings

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read())
        XCTAssertNil(sync.ownerConflict)
        XCTAssertTrue(auth.sessionExpired, "…and the Cancel that undid the sign-in brings it back for A")
        XCTAssertTrue(local.defaults.bool(forKey: AuthService.sessionExpiredKey), "persisted, as the launch check left it")
        XCTAssertEqual(SyncStatusLine.today(auth: auth, sync: sync, counts: .init()), .signInAgain)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id])
        XCTAssertEqual(cursors.cursor(for: accountA.id), recentCursor)
        XCTAssertEqual(queue.pending().habits, ["a-deleted-offline"])
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 1)
        XCTAssertNotNil(backoff.state(for: accountA.id))
        XCTAssertTrue(syncRequests.isEmpty)

        await signIn("magic-A")
        XCTAssertTrue(local.defaults.bool(forKey: AuthService.signInAgainBeforeSignInKey), "taken at this sign-in too")
        XCTAssertEqual(sync.settleSignIn(in: context), .ready, "A owns it: no screen")
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertNil(local.defaults.object(forKey: AuthService.signInAgainBeforeSignInKey),
                     "the owner settled: nothing left for a Cancel to put back")

        // A deliberate Log Out leaves no row to bring back: B's sign-in and Cancel add none.
        await auth.logout()
        await signIn("magic-B")
        _ = try conflict(after: sync.settleSignIn(in: context))
        await auth.cancelSignIn()   // AccountSwitchView's Cancel
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertNil(SyncStatusLine.today(auth: auth, sync: sync, counts: .init()))
        XCTAssertNil(local.defaults.object(forKey: AuthService.signInAgainBeforeSignInKey))
    }

    /// Review accounts-2, the other way the row comes up: a sync of this launch answered 401
    /// (`SyncService.needsReauth`, in memory — `sessionExpired` stays false). The row's tap checks
    /// the session, offline, so the login sheet opens with A's dead token still stored; back
    /// online the user signs into B, meets the account screen and cancels. That sign-in replaced
    /// A's token without ever checking it, so no later launch would raise the row, and the
    /// Cancel's Log Out ends `needsReauth`: the Cancel must put the row back, persisted. The
    /// sign-in itself ended the 401's row at once (the next test).
    func testCancelAfterASignInFromA401sRowBringsTheRowBack() async throws {
        let habit = try seedAsStore()
        tokens.save("tok-A")
        server.on("GET", "/v1/auth/session", respond: .ok(Self.sessionResponse(id: 7, email: "a@example.com")))
        relaunchAuth()
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isLoggedIn, "precondition: A signed in at launch")
        let refused = StubServer.Response(status: 401, body: #"{"error":"Unauthorized"}"#)
        server.on("POST", "/v1/sync/push", respond: refused)
        server.on("GET", "/v1/sync/pull", respond: refused)
        await sync.sync(context: context)   // the foreground sync meets the revoked session
        XCTAssertTrue(sync.needsReauth)
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertEqual(todayLine(), .signInAgain)

        // The row's tap, offline: the check says nothing, so the sheet opens on the dead token.
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        let flow = SignInAgainFlow(auth: auth, sync: sync)
        await flow.start(context: context)
        XCTAssertTrue(flow.showingLogin)
        XCTAssertTrue(auth.hasStoredSession, "A's token is still stored, never checked")

        // Back online: B's code in the sheet, the account screen, Cancel.
        stubSyncServer()
        await signIn("magic-B")
        XCTAssertTrue(local.defaults.bool(forKey: AuthService.signInAgainBeforeSignInKey), "the 401's row, remembered")
        XCTAssertFalse(sync.needsReauth, "the sign-in ended it")
        _ = try conflict(after: sync.settleSignIn(in: context))
        await auth.cancelSignIn()   // AccountSwitchView's Cancel

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read())
        XCTAssertTrue(auth.sessionExpired, "the row the sign-in came from is back")
        XCTAssertTrue(local.defaults.bool(forKey: AuthService.sessionExpiredKey), "persisted: a relaunch keeps it")
        XCTAssertEqual(todayLine(), .signInAgain)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id])
        XCTAssertEqual(queue.pending().habits, ["a-deleted-offline"])
    }

    /// A sign-in ends a 401's "Sign in again" at once. `needsReauth` used to last until a sync got
    /// through, so after the user signed back in the row stayed on Today — for good while that
    /// sync failed offline. The Cancel of the previous test still puts it back: the sign-in takes
    /// its snapshot of the row before it clears the flag.
    func testASignInEndsA401sSignInAgainEvenWhenTheNextSyncFails() async throws {
        try seedAsStore()
        tokens.save("tok-A")
        server.on("GET", "/v1/auth/session", respond: .ok(Self.sessionResponse(id: 7, email: "a@example.com")))
        relaunchAuth()
        await auth.waitForSessionRestore()
        let refused = StubServer.Response(status: 401, body: #"{"error":"Unauthorized"}"#)
        server.on("POST", "/v1/sync/push", respond: refused)
        server.on("GET", "/v1/sync/pull", respond: refused)
        await sync.sync(context: context)
        XCTAssertTrue(sync.needsReauth)
        XCTAssertEqual(todayLine(), .signInAgain)

        // Offline from here: nothing the sign-in is followed by can get through.
        server.on("POST", "/v1/sync/push") { _ in throw URLError(.notConnectedToInternet) }
        server.on("GET", "/v1/sync/pull") { _ in throw URLError(.notConnectedToInternet) }
        await signIn("magic-A2")   // the same account, a new session

        XCTAssertFalse(sync.needsReauth, "the refused session is replaced")
        XCTAssertNotEqual(todayLine(), .signInAgain)
        XCTAssertEqual(sync.settleSignIn(in: context), .ready)
        let ran = await sync.sync(context: context)
        XCTAssertFalse(ran, "offline")
        XCTAssertFalse(sync.needsReauth)
        XCTAssertNotEqual(todayLine(), .signInAgain, "and it stays gone while the sync fails")
    }

    // MARK: - Owner unknown (sub-decision (e))

    /// A 1.3.0 store with rows its last snapshot pushed, updated to 1.3.1 signed out (its session
    /// expired: 1.3.0 deletes the token and keeps `stride_last_sync_time`). The next sign-in
    /// offers BOTH choices — the device cannot tell whose rows these are — and nothing syncs
    /// until one is made. "Upload these habits" forgets every delivery mark first, so the full
    /// pull (which holds none of them) deletes nothing and both rows go up.
    func testAnUnknownOwnerOffersBothChoicesAndUploadForgetsTheMarks() async throws {
        let (oldID, newID) = try seedMigratedStore()
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: false)
        XCTAssertTrue(owners.ownerUnknown)
        XCTAssertTrue(marks.isAwaited)
        stubSyncServer()
        await signIn("magic-A")

        let conflict = try conflict(after: sync.settleSignIn(in: context))
        XCTAssertTrue(conflict.isOwnerUnknown, "the screen offers Upload as well as Start")
        XCTAssertEqual(conflict.signedIn, accountA)
        let blocked = await sync.sync(context: context)
        XCTAssertFalse(blocked)
        XCTAssertTrue(syncRequests.isEmpty)

        let ran = await sync.uploadLocalHabits(conflict, in: context)

        XCTAssertTrue(ran)
        XCTAssertFalse(marks.isAwaited, "settled by the choice")
        XCTAssertFalse(owners.ownerUnknown)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertNil(sync.ownerConflict)
        XCTAssertNil(syncRequests.first?.query["since"], "the adoption's pull is full")
        XCTAssertEqual(syncRequests.map(\.path), ["/v1/sync/pull", "/v1/sync/push", "/v1/sync/pull"])
        XCTAssertEqual(pushedHabitIDs, [oldID.uuidString, newID.uuidString],
                       "every mark forgotten: the row 1.3.0 had pushed goes up again too")
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id)), [oldID, newID],
                       "nothing deleted by its absence from the snapshot")
    }

    /// The same store's other choice: Start erases it, clears the queue it had, and full-pulls.
    func testAnUnknownOwnersStartFromThisAccountsDataErasesAndFullPulls() async throws {
        _ = try seedMigratedStore()
        queue.trackEntry("deleted-under-1.3.0")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: false)
        let fromA = Habit(name: "A's habit on the server")
        stubSyncServer(pullHabits: [SyncStubBodies.habit(fromA)])
        await signIn("magic-A")
        let conflict = try conflict(after: sync.settleSignIn(in: context))

        let ran = await sync.startFromSignedInAccountsData(conflict, in: context)

        XCTAssertTrue(ran)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.name), ["A's habit on the server"])
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertFalse(owners.ownerUnknown)
        XCTAssertFalse(marks.isAwaited)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertTrue(pushedHabitIDs.isEmpty)
        XCTAssertNil(syncRequests.first?.query["since"])
    }

    /// Upload is only for an unknown owner: for a known one it would be the keep-and-add 1.3.1
    /// does not offer. Refused, nothing changes, no request.
    func testUploadIsRefusedForAKnownOwner() async throws {
        try seedAsStore()
        stubSyncServer()
        await signIn("magic-B")
        let conflict = try conflict(after: sync.settleSignIn(in: context))

        let ran = await sync.uploadLocalHabits(conflict, in: context)

        XCTAssertFalse(ran)
        XCTAssertEqual(sync.ownerConflict, conflict)
        XCTAssertEqual(owners.owner?.id, accountA.id)
        XCTAssertTrue(syncRequests.isEmpty)
    }

    /// An owner-unknown store emptied since its first launch has nothing to ask about: adopted
    /// silently, and the flag goes.
    func testAnEmptiedOwnerUnknownStoreIsAdoptedSilently() async throws {
        let (oldID, newID) = try seedMigratedStore()
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: false)
        for habit in try context.fetch(FetchDescriptor<Habit>()) where [oldID, newID].contains(habit.id) {
            context.delete(habit)
        }
        try context.save()
        stubSyncServer()
        await signIn("magic-A")

        XCTAssertEqual(sync.settleSignIn(in: context), .ready)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertFalse(owners.ownerUnknown)
    }

    /// A stored token at the first 1.3.1 launch is not evidence of being signed in: a 1.2.3 device
    /// keeps its dead token (1.3.0 started deleting them), and a device that auto-updated while
    /// dormant holds the one that expired. Decided on "a token is stored", the launch check then
    /// deleted it and left rows, no owner and no flag — and the next account signed into adopted
    /// A's never-pushed habit silently and uploaded it into B (phase C review, F1). Now the check's
    /// `{user: null}` settles the question as signed out: owner-unknown, and B's sign-in asks.
    func testADeadTokenAtTheFirstLaunchLeavesTheOwnerUnknown() async throws {
        _ = try seedMigratedStore()
        tokens.save("tok-A-expired")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        XCTAssertFalse(owners.ownerUnknown, "undecided until the token is checked")
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        stubSyncServer()

        relaunchAuth()
        await auth.waitForSessionRestore()

        XCTAssertNil(tokens.read(), "the dead token is deleted, as since 1.3.0")
        XCTAssertTrue(owners.ownerUnknown)
        XCTAssertTrue(auth.sessionExpired, "Today's \"Sign in again\" row outlives the launch")
        await signIn("magic-B")
        XCTAssertFalse(auth.sessionExpired, "a sign-in ends it")
        let conflict = try conflict(after: sync.settleSignIn(in: context))
        XCTAssertTrue(conflict.isOwnerUnknown)
        XCTAssertEqual(conflict.signedIn, accountB)
        let blocked = await sync.sync(context: context)
        XCTAssertFalse(blocked)
        XCTAssertTrue(syncRequests.isEmpty, "nothing of the old rows went to B before the choice")
    }

    /// The same first launch with a token that is still alive: signed in at the first 1.3.1
    /// launch, so that account adopts the store as before (its marks wait for the proof).
    func testALiveTokenAtTheFirstLaunchIsAdoptedAsBefore() async throws {
        _ = try seedMigratedStore()
        tokens.save("tok-A")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        server.on("GET", "/v1/auth/session",
                  respond: .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#))

        relaunchAuth()
        await auth.waitForSessionRestore()

        XCTAssertFalse(owners.ownerUnknown)
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertEqual(sync.settleSignIn(in: context), .ready)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertTrue(marks.isAwaited, "adopted without the screen: the first full pull proves the marks")
    }

    /// The launch check never answered (offline), and a typed code then replaced the token: whose
    /// token it was is still unknown, so its store's rows are too.
    func testATokenReplacedBeforeItWasCheckedLeavesTheOwnerUnknown() async throws {
        _ = try seedMigratedStore()
        tokens.save("tok-A-unchecked")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        stubSyncServer()
        relaunchAuth()
        await auth.waitForSessionRestore()
        XCTAssertFalse(owners.ownerUnknown, "an unanswered check decides nothing")

        await signIn("magic-B")

        XCTAssertTrue(owners.ownerUnknown)
        let conflict = try conflict(after: sync.settleSignIn(in: context))
        XCTAssertTrue(conflict.isOwnerUnknown)
        XCTAssertTrue(syncRequests.isEmpty)
    }

    /// The first launch's check did not answer (offline, or past `waitForSessionRestore`'s 10 s),
    /// so no launch sync ran. Later a login link rechecks the stored token and the server names
    /// A: the device WAS signed in at its first 1.3.1 launch, so A owns the store from that answer
    /// on. It used to only close the question and leave the store owner-less until a sync reached
    /// `settleOwner` — and the link path runs none. A Log Out in that gap, then B's link, adopted
    /// A's rows with no account screen, and B's first sync uploaded the ones A never pushed
    /// (review accounts-1).
    func testASessionConfirmedAfterAFailedFirstLaunchCheckMakesItsAccountTheOwner() async throws {
        _ = try seedMigratedStore()
        tokens.save("tok-A")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        stubSyncServer()
        relaunchAuth()
        await auth.waitForSessionRestore()
        XCTAssertFalse(auth.isLoggedIn, "precondition: the launch check failed")
        XCTAssertNil(owners.owner)

        // Online again. B's link is tapped; the stored token is asked about first, and it is A's.
        server.on("GET", "/v1/auth/session",
                  respond: .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        let link = try XCTUnwrap(URL(string: "https://stride-api.colorarchive.me/login?token=\(Self.linkTokenB)"))
        let ignored = await auth.handleLoginLink(link)

        XCTAssertEqual(ignored, .ignoredAlreadySignedIn)
        XCTAssertEqual(owners.owner, SyncOwner(accountA), "the server named the first launch's session")
        XCTAssertFalse(owners.ownerUnknown)
        XCTAssertTrue(marks.isAwaited, "its marks still wait for A's first full pull")

        await auth.logout()
        let signedIn = await auth.handleLoginLink(link)   // the same link, never spent
        XCTAssertEqual(signedIn, .signedIn)

        let conflict = try conflict(after: sync.settleSignIn(in: context))
        XCTAssertEqual(conflict, SyncOwnerConflict(owner: SyncOwner(accountA), signedIn: accountB))
        let ran = await sync.sync(context: context)   // StrideApp's post-link sync
        XCTAssertFalse(ran)
        XCTAssertTrue(syncRequests.isEmpty, "nothing of A's went to B: \(syncRequests.map(\.path))")
        XCTAssertTrue(pushedHabitIDs.isEmpty)
    }

    /// F1's way back in is Today's "Sign in again" row: the launch check found the session dead,
    /// and the next sign-in meets Upload / Start (the owner's decision 1). The row's tap opens
    /// the login sheet, and the sign-in ends the row — `setUser` clears `sessionExpired` — so the
    /// sheet cannot be the row's: it was, and it closed with the row before its account step
    /// appeared, leaving the device signed in with every sync blocked (review critic-1). The flow
    /// is TodayView's (`SignInAgainFlow`): its sheet is still up once the row is gone, the next
    /// step is the account screen, and the sheet's close runs the sync the choice unblocked.
    func testTheSignInAgainSheetOutlivesTheRowAndContinuesWithTheAccountStep() async throws {
        let (oldID, newID) = try seedMigratedStore()
        tokens.save("tok-A-expired")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        stubSyncServer()
        relaunchAuth()
        await auth.waitForSessionRestore()
        let flow = SignInAgainFlow(auth: auth, sync: sync)
        XCTAssertEqual(todayLine(), .signInAgain, "precondition: the cold launch's row")

        await flow.start(context: context)   // the row's tap
        XCTAssertTrue(flow.showingLogin, "the dead token is gone: straight to the login sheet")
        XCTAssertFalse(flow.isChecking)

        await signIn("magic-A")   // the sheet's Verify
        XCTAssertNotEqual(todayLine(), .signInAgain, "the sign-in ends the row…")
        XCTAssertTrue(flow.showingLogin, "…and the sheet stays: it is not the row's")

        let conflict = try conflict(after: sync.settleSignIn(in: context))   // LoginView.continueSignIn
        XCTAssertTrue(conflict.isOwnerUnknown, "the sheet's next step: Upload / Start")
        XCTAssertEqual(conflict.signedIn, accountA)
        XCTAssertTrue(syncRequests.isEmpty)

        let uploaded = await sync.uploadLocalHabits(conflict, in: context)   // the step's choice
        XCTAssertTrue(uploaded)
        XCTAssertEqual(pushedHabitIDs, [oldID.uuidString, newID.uuidString])
        flow.showingLogin = false   // the step's onFinish closes the sheet
        let requests = syncRequests.count
        let ranOnClose = await flow.loginClosed(context: context)
        XCTAssertTrue(ranOnClose, "the close's sync runs")
        XCTAssertEqual(syncRequests.count, requests + 1, "a quiet sync: one pull")
    }

    /// Review critic-1, the presenter itself. The previous test holds the flow's state; this one
    /// hosts the real TodayView in a window, as the app shows it, so a refactor that hangs the
    /// login sheet on the row again — the pre-fix structure, which every other test passes — fails
    /// here: the sign-in removes the row, and SwiftUI closes a sheet whose presenter left the
    /// hierarchy before its account step appears. From a cold launch whose check found the session
    /// gone ({user: null}, F1's owner-unknown store), the row is tapped — its accessibility action,
    /// what VoiceOver's double-tap sends — and the sheet opens on LoginView; the sign-in the sheet
    /// is for runs. Once the row has left the hierarchy the window's root still presents the same
    /// sheet, and it shows the account step (Upload / Start), with no sync request before it.
    func testTodaysSignInAgainSheetOutlivesTheRowOnScreenAndShowsTheAccountStep() async throws {
        _ = try seedMigratedStore()
        tokens.save("tok-A-expired")
        SyncService.prepareLaunch(context: context, defaults: local.defaults, hasStoredSession: true)
        server.on("GET", "/v1/auth/session", respond: .ok(Self.sessionResponse(id: nil)))
        stubSyncServer()
        relaunchAuth()
        await auth.waitForSessionRestore()
        XCTAssertEqual(todayLine(), .signInAgain, "precondition: the cold launch's row")

        // TodayView, LoginView and AccountSwitchView read `shared`: while they are up, `shared` is
        // this test's pair, over the stub server and scratch defaults (tearDown puts them back).
        AuthService.testOverride = auth
        SyncService.testOverride = sync
        // SwiftUI builds the elements an assistive technology reads only while one is running;
        // this is how XCUITest has it build them in an app under test.
        let automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        addTeardownBlock { @MainActor in AccessibilityAutomation.restore(automation) }
        let window = try hostToday()
        addTeardownBlock { @MainActor [self] in await closeHostedToday() }

        let rowLabel = appLocalized("Sign in again to keep syncing")
        let row = try await element(labeled: rowLabel, in: window)
        XCTAssertTrue(row.accessibilityActivate(), "the row's tap")
        try await waitUntil("the login sheet opens") { window.rootViewController?.presentedViewController != nil }
        let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController)
        _ = try await element(labeled: appLocalized("Email address"), in: sheet.view)   // LoginView's first step

        await signIn("magic-A")   // the sheet's Verify
        XCTAssertNotEqual(todayLine(), .signInAgain, "the sign-in ends the row…")
        try await waitUntil("the row left Today") { self.findElement(labeled: rowLabel, in: window) == nil }
        let accountStep = appLocalized("This device has habits that aren't linked to an account.")
        _ = try await element(labeled: accountStep, in: sheet.view)
        // SwiftUI has had the row's removal to act on: a presenter that went with it closes the
        // sheet within a few frames (it did, with the sheet hung on the row as before the fix).
        // Watched for a second, not sampled once.
        for _ in 0..<20 {
            guard window.rootViewController?.presentedViewController === sheet else {
                return XCTFail("…and the sheet stays up: TodayView presents it, not the row")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(findElement(labeled: accountStep, in: sheet.view), "still on the account step")
        XCTAssertEqual(sync.ownerConflict?.isOwnerUnknown, true, "the account step: Upload / Start")
        XCTAssertTrue(syncRequests.isEmpty, "no sync request before the choice")
    }

    // MARK: Hosting a real view

    private var hostedWindow: UIWindow?

    /// TodayView as the app shows it (inside a NavigationStack, over this test's store, in the
    /// picked language's locale as StrideApp sets it — so its text and `appLocalized` agree), in a
    /// window of its own on the host app's scene, key and visible, so SwiftUI presents its sheets.
    private func hostToday() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { TodayView() }
            .modelContainer(container)
            .environment(\.locale, LanguageManager.shared.locale ?? .current))
        window.makeKeyAndVisible()
        hostedWindow = window
        return window
    }

    /// Containers a hosted view used, kept for the life of the process: SwiftUI can run a view's
    /// task after its window is gone, and a ModelContext whose container was released traps.
    private static var retiredContainers: [ModelContainer] = []

    /// Closes what `hostToday` put up, before `tearDown` releases the store (a teardown block of
    /// the test that hosted it). Signed out first: closing the login sheet runs its onDismiss,
    /// which syncs a signed-in account — against a store `tearDown` is about to release, and that
    /// sync trapped in SwiftData during the next test.
    private func closeHostedToday() async {
        guard let window = hostedWindow else { return }
        if auth?.isLoggedIn == true { await auth.logout() }
        if window.rootViewController?.presentedViewController != nil {
            window.rootViewController?.dismiss(animated: false)
            let deadline = ContinuousClock.now + .seconds(5)
            while window.rootViewController?.presentedViewController != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try? await Task.sleep(for: .milliseconds(200))   // the onDismiss task: signed out, it returns
        if let container { Self.retiredContainers.append(container) }
        tearDownHostedToday()
    }

    /// Gives the app its window and services back (also `tearDown`'s, should a test stop before
    /// its teardown blocks).
    private func tearDownHostedToday() {
        if let window = hostedWindow {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
            hostedWindow = nil
            if let container { Self.retiredContainers.append(container) }
        }
        AuthService.testOverride = nil
        SyncService.testOverride = nil
    }

    /// The accessibility element labelled `label` under `root`, as VoiceOver would reach it.
    private func findElement(labeled label: String, in root: NSObject) -> NSObject? {
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children {
            if let found = findElement(labeled: label, in: child) { return found }
        }
        return nil
    }

    private func element(labeled label: String, in root: NSObject) async throws -> NSObject {
        var found: NSObject?
        try await waitUntil("an element labelled “\(label)”") {
            found = self.findElement(labeled: label, in: root)
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    /// Lets SwiftUI and UIKit run until `condition` holds, or fails after five seconds.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting: \(what)")
                throw XCTSkip("timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// What Today would draw now.
    private func todayLine() -> SyncStatusLine? {
        let counts = (try? SyncStatusCounts.read(in: context, deletions: queue.pending())) ?? .init()
        return SyncStatusLine.today(auth: auth, sync: sync, counts: counts)
    }

    /// A launch: a new AuthService (it checks the stored token when created) and the SyncService
    /// that asks it who is signed in.
    private func relaunchAuth() {
        auth = makeAuth()
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: auth, recoveryLog: recovery.log)
    }

    // MARK: - Nothing to lose, the same account

    /// A's store with nothing in it: B simply becomes the owner — no screen — and its sync uses
    /// B's token and a full pull, never A's cursor.
    func testAnEmptyStoreSwitchesSilently() async throws {
        owners.set(SyncOwner(accountA))
        cursors.setCursor(recentCursor, for: accountA.id)
        stubSyncServer()
        await signIn("magic-B")

        XCTAssertEqual(sync.settleSignIn(in: context), .ready)
        XCTAssertEqual(owners.owner, SyncOwner(accountB))
        XCTAssertNil(sync.ownerConflict)
        XCTAssertNil(cursors.cursor(for: accountA.id))
        let ran = await sync.sync(context: context)
        XCTAssertTrue(ran)
        XCTAssertNil(syncRequests.first?.query["since"])
        XCTAssertTrue(syncRequests.allSatisfy { $0.authorization == "Bearer tok-B" })
    }

    /// Sign out of A and back into A: no screen, and the next sync with no edits pushes 0/0/0 —
    /// one incremental pull on the kept cursor (Acceptance (5): "signing back into A instead
    /// resumes, and its next sync with no edits pushes 0/0/0").
    func testTheSameAccountResumesAndPushesNothing() async throws {
        stubSyncServer()
        await signIn("magic-A")
        XCTAssertEqual(sync.settleSignIn(in: context), .ready)
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        await sync.sync(context: context)
        XCTAssertFalse(habit.isPending)
        let cursor = try XCTUnwrap(cursors.cursor(for: accountA.id))
        let before = syncRequests.count

        await auth.logout()
        await signIn("magic-A2")
        XCTAssertEqual(sync.settleSignIn(in: context), .ready)
        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        let after = Array(syncRequests.dropFirst(before))
        XCTAssertEqual(after.map(\.path), ["/v1/sync/pull"], "no edits: no push")
        XCTAssertEqual(after.first?.query["since"], cursor)
        XCTAssertEqual(after.first?.authorization, "Bearer tok-A2")
    }

    // MARK: - Account deletion, erase

    /// "`deleteAccount` erases local data and clears the owner", and the deleted account's
    /// recovery log and backoff go with it: nobody can sign into it again to see them.
    func testDeleteAccountErasesAndClearsTheOwnerTheLogAndTheBackoff() async throws {
        try seedAsStore()
        await signIn("magic-A")

        try await auth.deleteAccount()

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 0)
        XCTAssertNil(owners.owner)
        XCTAssertFalse(owners.ownerUnknown)
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 0)
        XCTAssertNil(backoff.state(for: accountA.id))
        XCTAssertNil(sync.backoff)
        XCTAssertNil(cursors.cursor(for: accountA.id))
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertTrue(syncRequests.isEmpty)
    }

    /// Delete Account answered 401: the session was already gone (revoked, or the account deleted
    /// on another device). APIClient deletes the token on a 401, and the device used to stay
    /// "signed in" with no token — every sync returned quietly, and Today kept its last "Synced"
    /// line with no way back in (review accounts-3). It ends the session here as the launch
    /// check's `{user: null}` does: signed out, "Sign in again" on Today. Nothing local goes: the
    /// server refused, and A's rows wait for A.
    func testADeleteAccountAnswered401EndsTheSessionAndShowsSignInAgain() async throws {
        let habit = try seedAsStore()
        await signIn("magic-A")
        server.on("POST", "/v1/auth/delete-account", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))
        stubSyncServer()

        do {
            try await auth.deleteAccount()
            XCTFail("a refused deletion throws")
        } catch APIError.unauthorized {
        } catch {
            XCTFail("expected unauthorized, got \(error)")
        }

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read())
        XCTAssertNil(auth.currentSyncSession())
        XCTAssertTrue(auth.sessionExpired)
        XCTAssertEqual(SyncStatusLine.today(auth: auth, sync: sync, counts: .init()), .signInAgain)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id])
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 1)
        XCTAssertEqual(cursors.cursor(for: accountA.id), recentCursor)
        let ran = await sync.sync(context: context)
        XCTAssertFalse(ran)
        XCTAssertTrue(syncRequests.isEmpty)

        await signIn("magic-A")
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertEqual(sync.settleSignIn(in: context), .ready, "A signs back in and resumes")
    }

    /// B deleted while the account screen waited over A's habits: A's store is not B's to erase.
    func testDeletingAnAccountThatDoesNotOwnTheStoreLeavesItsRows() async throws {
        let habit = try seedAsStore()
        await signIn("magic-B")
        _ = try conflict(after: sync.settleSignIn(in: context))

        try await auth.deleteAccount()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id])
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 1)
        XCTAssertNil(sync.ownerConflict)
    }

    /// Delete Account's last step (phase C leftovers, the owner's decision 3): the account that
    /// owns this store is about to erase it, recovered edits included, so the step offers the
    /// backup and the recovered edits before its button — the export an alert could not hold.
    func testDeleteAccountStepOffersTheExportWhenTheAccountOwnsTheStore() async throws {
        try seedAsStore()
        await signIn("magic-A")

        let step = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))

        XCTAssertEqual(step.email, "a@example.com")
        XCTAssertTrue(step.erasesDevice)
        XCTAssertTrue(step.offersBackup)
        XCTAssertTrue(step.offersRecoveredEdits, "A's log has a line, and the deletion clears it")

        // The log is counted again when the step opens, not taken from Settings' last read.
        try recovery.log.clear(accountID: accountA.id)
        let again = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))
        XCTAssertFalse(again.offersRecoveredEdits)
        XCTAssertTrue(again.offersBackup)
    }

    /// Delete My Account is bound to what was exported, as Clear and Erase are (1.4.0,
    /// RELEASE-1.4.0.md D6). Export Recovered Edits in the step, then a sync archives a line: the
    /// recheck refuses and rebuilds the step with the new count — and tapped again "as shown" it
    /// used to go through, deleting the line the export never held. It refuses until the export
    /// holds it.
    func testDeleteAccountWaitsUntilTheExportHoldsEveryRecoveredEdit() async throws {
        try seedAsStore()
        await signIn("magic-A")
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-exports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: exportRoot) }
        let step = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))
        let exported = try await DataExportService.write(sync.recoveredEditsFile, container: container,
                                                         sync: sync, in: exportRoot)
        XCTAssertEqual(exported.recoveredEditsTotal, 1)
        let row = DataBackup.snapshot(habits: [Habit(name: "Archived after the export")], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: accountA.id)

        let first = await step.recheck(sync: sync, context: context)
        let rebuilt = try XCTUnwrap(first, "the total moved")
        XCTAssertTrue(rebuilt.recoveredEditsChanged)
        XCTAssertEqual(rebuilt.recoveredEditLines, 2)
        let refusedAgain = await rebuilt.recheck(sync: sync, context: context)
        XCTAssertNotNil(refusedAgain, "confirmed as shown, but the export holds 1 of the 2")

        _ = try await DataExportService.write(sync.recoveredEditsFile, container: container, sync: sync, in: exportRoot)
        let goAhead = await rebuilt.recheck(sync: sync, context: context)
        XCTAssertNil(goAhead, "the export holds both")
    }

    /// B signed in over A's store (the account screen left without a choice): B's deletion
    /// leaves A's rows and A's log alone (`testDeletingAnAccountThatDoesNotOwnTheStoreLeavesItsRows`),
    /// so the step neither says this device is erased nor offers an export of A's data.
    func testDeleteAccountStepOffersNothingForAnotherOwnersStore() async throws {
        try seedAsStore()
        await signIn("magic-B")
        _ = try conflict(after: sync.settleSignIn(in: context))

        let step = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))

        XCTAssertEqual(step.email, "b@example.com")
        XCTAssertFalse(step.erasesDevice)
        XCTAssertFalse(step.offersBackup)
        XCTAssertFalse(step.offersRecoveredEdits)
    }

    /// The step's rules on their own: an empty store has no backup to offer; a log that could not
    /// be counted (nil) is offered, as on the restore hand-over; signed out there is no step.
    func testDeleteAccountStepRules() {
        let empty = DeleteAccountStep(email: "a@example.com", erasesDevice: true, hasLocalData: false, recoveredEdits: .empty)
        XCTAssertFalse(empty.offersBackup)
        XCTAssertFalse(empty.offersRecoveredEdits)
        let unreadable = DeleteAccountStep(email: "a@example.com", erasesDevice: true, hasLocalData: false, recoveredEdits: nil)
        XCTAssertTrue(unreadable.offersRecoveredEdits)
        let otherOwner = DeleteAccountStep(email: "b@example.com", erasesDevice: false, hasLocalData: true, recoveredEdits: nil)
        XCTAssertFalse(otherOwner.offersBackup)
        XCTAssertFalse(otherOwner.offersRecoveredEdits)

        XCTAssertFalse(auth.isLoggedIn, "precondition")
        XCTAssertNil(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))
    }

    /// The F4 window on Delete Account (review M2-1): the step counted A's log on Continue; a sync
    /// before Delete My Account archives another line. The deletion clears the log unasked, so the
    /// tap must not delete — the step comes back with the new count and its export — until the
    /// count it offered is the count on disk again.
    func testDeleteAccountStepRechecksTheRecoveredEditsBeforeTheDeletion() async throws {
        try seedAsStore()
        await signIn("magic-A")
        let step = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))
        XCTAssertEqual(step.recoveredEditLines, 1)
        let unchanged = await step.recheck(sync: sync, context: context)
        XCTAssertNil(unchanged, "the count it offered is still on disk: delete")

        let row = DataBackup.snapshot(habits: [Habit(name: "Archived after Continue")], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: accountA.id)

        let rebuilt = await step.recheck(sync: sync, context: context)
        let changed = try XCTUnwrap(rebuilt, "a line nobody offered: do not delete")
        XCTAssertEqual(changed.recoveredEditLines, 2)
        XCTAssertTrue(changed.recoveredEditsChanged)
        XCTAssertTrue(changed.offersRecoveredEdits)
        XCTAssertTrue(changed.offersBackup)
        XCTAssertEqual(changed.id, step.id, "the same sheet, updated in place")
        XCTAssertEqual(sync.recoveredEdits?.lines, 2)
        let confirmed = await changed.recheck(sync: sync, context: context)
        XCTAssertNil(confirmed, "shown the two lines: delete")

        // A log emptied meanwhile has nothing to lose; another owner's store loses no lines.
        try recovery.log.clear(accountID: accountA.id)
        let emptied = await changed.recheck(sync: sync, context: context)
        XCTAssertNil(emptied)
        let otherOwner = DeleteAccountStep(email: "b@example.com", erasesDevice: false, hasLocalData: true, recoveredEdits: .empty)
        let untouched = await otherOwner.recheck(sync: sync, context: context)
        XCTAssertNil(untouched)
    }

    /// The same recheck with the recovery log at its cap (review recovery-backup-1): an append
    /// there drops the oldest line as it adds its own, so the count the step offered comes back
    /// unchanged over a line nobody offered. The step compares lines + dropped, which only grows
    /// until a clear.
    func testDeleteAccountStepAtTheCapRechecksWhatArrivedNotOnlyTheCount() async throws {
        try seedAsStore()
        try recovery.log.clear(accountID: accountA.id)
        let capped = try recovery.filledToTheCap(accountID: accountA.id)
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: auth, recoveryLog: capped)
        await signIn("magic-A")
        let step = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))

        let row = DataBackup.snapshot(habits: [Habit(name: "Archived after Continue")], groups: []).habits[0]
        try capped.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                          accountID: accountA.id)
        XCTAssertEqual(try capped.lineCount(accountID: accountA.id), step.recoveredEditLines,
                       "precondition: at the cap the count did not move")

        let rebuilt = await step.recheck(sync: sync, context: context)
        let changed = try XCTUnwrap(rebuilt, "a line nobody offered: do not delete")
        XCTAssertTrue(changed.recoveredEditsChanged)
        XCTAssertTrue(changed.offersRecoveredEdits)
        let confirmed = await changed.recheck(sync: sync, context: context)
        XCTAssertNil(confirmed, "shown what is on disk now: delete")
    }

    /// E2E S-DEL: the sync that archived a line after Continue had also removed the store's last
    /// habit, and the rebuilt step still offered Export as JSON — an empty backup — because it
    /// kept Continue's answer. It reads the store again: recovered edits only.
    func testDeleteAccountStepRebuiltOverAnEmptiedStoreOffersNoBackup() async throws {
        let habit = try seedAsStore()
        await signIn("magic-A")
        let step = try XCTUnwrap(DeleteAccountStep.current(auth: auth, sync: sync, hasLocalData: true))
        XCTAssertTrue(step.offersBackup, "precondition")

        // What that sync did: the habit went (deleted on another device), its edit was archived.
        context.delete(habit)
        try context.save()
        let row = DataBackup.snapshot(habits: [Habit(name: "A's habit, edited here")], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: accountA.id)
        XCTAssertFalse(DeleteAccountStep.hasLocalData(in: context))

        let rebuilt = await step.recheck(sync: sync, context: context)

        let changed = try XCTUnwrap(rebuilt)
        XCTAssertFalse(changed.offersBackup, "nothing left to back up")
        XCTAssertTrue(changed.offersRecoveredEdits)
        XCTAssertTrue(changed.recoveredEditsChanged)

        // A group alone is something to back up.
        context.insert(HabitGroup(name: "Morning"))
        try context.save()
        XCTAssertTrue(DeleteAccountStep.hasLocalData(in: context))
    }

    /// Erase Local Data's API: the owner's recovered edits go only when the caller asks (after
    /// offering their export); by default they stay under the owner's key.
    func testResetSyncStateClearsTheOwnersRecoveryLogOnlyWhenAsked() throws {
        try seedAsStore()
        sync.resetSyncState()
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 1)

        owners.set(SyncOwner(accountA))
        sync.resetSyncState(clearingRecoveryLog: true)
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 0)
        XCTAssertNil(owners.owner)
    }

    // MARK: - DEBUG screenshot scenarios

    #if DEBUG
    func testTheDemoScenariosPresentTheScreenWithFakeAccounts() {
        let conflict = AccountChoiceRouter.demoRequest(arguments: ["Stride", "-demo", "-demoScenario", "accountConflict"])
        XCTAssertEqual(conflict?.isDemo, true)
        XCTAssertNotNil(conflict?.conflict.owner)
        let unknown = AccountChoiceRouter.demoRequest(arguments: ["Stride", "-demoScenario", "accountUnknownOwner"])
        XCTAssertEqual(unknown?.conflict.isOwnerUnknown, true)
        XCTAssertNil(AccountChoiceRouter.demoRequest(arguments: ["Stride", "-demoScenario", "plurals"]))
        XCTAssertNil(AccountChoiceRouter.demoRequest(arguments: ["Stride"]))
    }
    #endif

    // MARK: - Fixtures

    /// A 1.3.0 store with one row older than 1.3.0's last sync (the migrated-rows rule marks it
    /// delivered) and one newer. Returns (older, newer) ids.
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
}

/// The accessibility runtime's automation mode (libAccessibility's `_AXSAutomationEnabled` /
/// `_AXSSetAutomationEnabled`), which XCUITest switches on in an app under UI test. With it on,
/// SwiftUI builds the accessibility elements of what it draws, so a hosted test can find a view by
/// its label and press a button through its accessibility action. Private and test-only: nil when
/// the symbols are not there, and the test says so rather than passing without its check.
@MainActor
enum AccessibilityAutomation {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    private static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)

    private static var functions: (get: Getter, set: Setter)? {
        guard let library, let get = dlsym(library, "_AXSAutomationEnabled"),
              let set = dlsym(library, "_AXSSetAutomationEnabled") else { return nil }
        return (unsafeBitCast(get, to: Getter.self), unsafeBitCast(set, to: Setter.self))
    }

    /// Switches it on; returns whether it was on before, for `restore`.
    static func enable() -> Bool? {
        guard let functions else { return nil }
        let before = functions.get() != 0
        functions.set(1)
        return before
    }

    static func restore(_ before: Bool) {
        functions?.set(before ? 1 : 0)
    }
}
