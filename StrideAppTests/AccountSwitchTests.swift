import XCTest
import SwiftData
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
    /// `SyncService.shared` — sign-out and account deletion included.
    private func makeAuth() -> AuthService {
        AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens, defaults: local.defaults,
                    onSignOut: { [weak self] in self?.sync?.signedOut() },
                    onAccountDeleted: { [weak self] account in
                        guard let self else { return }
                        try? self.sync.accountDeleted(account, in: self.context)
                    })
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

        // Export a backup: the OWNER's account in the file, and A's rows in it.
        let backup = sync.backupFile(for: conflict, container: container)
        XCTAssertEqual(backup.account, BackupAccount(id: accountA.id, email: accountA.email))
        let document = try DataBackup.decode(try DataExportService.backupJSONData(from: context, account: backup.account))
        XCTAssertEqual(document.accountId, accountA.id)
        XCTAssertEqual(document.habits.map(\.name), ["A's habit"])
        // …and the recovery log, which has a line.
        XCTAssertEqual(sync.holdings(for: conflict, in: context),
                       SyncOwnerHoldings(habits: 1, checkIns: 1, groups: 0, queuedDeletions: 1, recoveredEdits: 1))
        let edits = sync.recoveredEditsFile(for: conflict)
        XCTAssertEqual(edits.accountID, accountA.id)
        let export = try SyncRecoveryLog.decodeExport(try recovery.log.exportData(accountID: edits.accountID))
        XCTAssertEqual(export.items.count, 1)
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
    func testCancelSignsOutAndLeavesTheStoreAndTheOwner() async throws {
        let habit = try seedAsStore()
        stubSyncServer()
        await signIn("magic-B")
        _ = try conflict(after: sync.settleSignIn(in: context))

        await auth.logout()   // AccountSwitchView's Cancel

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read())
        XCTAssertNil(sync.ownerConflict)
        XCTAssertEqual(owners.owner, SyncOwner(accountA))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [habit.id])
        XCTAssertEqual(cursors.cursor(for: accountA.id), recentCursor)
        XCTAssertEqual(queue.pending().habits, ["a-deleted-offline"])
        XCTAssertEqual(try recovery.log.lineCount(accountID: accountA.id), 1)
        XCTAssertNotNil(backoff.state(for: accountA.id))
        XCTAssertTrue(syncRequests.isEmpty)

        await signIn("magic-A")
        XCTAssertEqual(sync.settleSignIn(in: context), .ready, "A owns it: no screen")
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
