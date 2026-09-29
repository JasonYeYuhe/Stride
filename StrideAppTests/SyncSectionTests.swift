import XCTest
import SwiftData
@testable import Stride

/// Settings → Sync and the restore / erase flows around it (DEV-PLAN-1.3.md M2, phase C;
/// acceptance 6 and 10), through exactly what the buttons call (`SyncSectionActions`,
/// `DataExportService.restoreChoices` / `restoreHandover` / `eraseLocalData`) against a stubbed
/// server — the SyncServiceTests setup: the real service, engine and APIClient, an in-memory
/// store, a scratch defaults suite and a scratch recovery log.
///
/// SyncServiceTests pins the phase B operations themselves; this file pins what the section
/// shows and that its buttons reach those operations with the right order around sync.
@MainActor
final class SyncSectionTests: XCTestCase {

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
    private let recentCursor = SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400))
    private var actions: SyncSectionActions { SyncSectionActions(sync: sync, context: context) }

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        tokens = InMemoryTokenStore(SyncSession.accountA.token)
        local = ScratchDefaults("section.local")
        appGroup = ScratchDefaults("section.appGroup")
        queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        sessions = FakeSyncSessions(.accountA)
        recovery = ScratchRecoveryLog()
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: sessions, recoveryLog: recovery.log)
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

    private func seedOwnerAndCursor() {
        owners.set(SyncOwner(SyncSession.accountA.account))
        cursors.setCursor(recentCursor, for: owner)
    }

    private func stubHappyServer() {
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))
    }

    private var syncRequests: [StubServer.Request] { server.requests.filter { $0.path.hasPrefix("/v1/sync/") } }
    private var syncPaths: [String] { syncRequests.map(\.path) }

    private func pushed(_ key: String) -> [String] {
        syncRequests.filter { $0.path == "/v1/sync/push" }
            .flatMap { ($0.json?[key] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String }
    }

    private func content(signedIn: Bool = true) throws -> SyncSectionContent {
        SyncSectionContent(held: try sync.heldRows(in: context), recoveredEdits: sync.recoveredEdits?.lines ?? 0,
                           isPaused: false, offersFullResync: signedIn)
    }

    private func appendRecoveredEdit(named name: String = "Edited offline", for account: String?,
                                     into log: SyncRecoveryLog? = nil) throws {
        let row = DataBackup.snapshot(habits: [Habit(name: name)], groups: []).habits[0]
        try (log ?? recovery.log).append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                         accountID: account)
    }

    // MARK: - What the section shows

    /// Nothing held, no recovered edits, signed out: no section at all. Signed in, Full Resync is
    /// the one row. Every held row counts in "N changes can't sync" (Today's number); the content
    /// reasons get a line each, the id reasons a row with buttons.
    func testTheSectionShowsOnlyWhatThereIs() throws {
        XCTAssertTrue(try content(signedIn: false).isEmpty)
        XCTAssertFalse(try content(signedIn: true).isEmpty)

        let refused = Habit(name: "Refused")
        let tooBig = Habit(name: "Huge note")
        let foreign = Habit(name: "Another account's")
        let restored = Habit(name: "Restored, deleted elsewhere")
        let loose = HabitRecord(date: HabitCalendar.dayKey(for: Date()))
        restored.records = [loose]
        for habit in [refused, tooBig, foreign, restored] { context.insert(habit) }
        refused.hold(.rowError)
        tooBig.hold(.tooLarge)
        foreign.hold(.notOwned)
        restored.restoredAt = Date()
        restored.hold(.tombstoned)
        loose.hold(.tombstoned)   // covered by its held habit: not counted again
        try context.save()

        let shown = try content(signedIn: false)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(shown.refused.map(\.reason), [.rowError, .tooLarge])
        XCTAssertEqual(shown.convertible.map(\.reason), [.notOwned, .tombstoned])
        XCTAssertEqual(shown.heldCount, 4, "a held habit counts once, with its check-ins")
        XCTAssertEqual(shown.convertible.last?.counts, SyncRowCounts(groups: 0, habits: 1, entries: 0))
        XCTAssertFalse(shown.offersFullResync)

        // An edit lifts a content hold by itself: the line goes without any action.
        refused.name = "Refused, then edited"
        refused.touch()
        tooBig.note = "Shorter"
        tooBig.touch()
        try context.save()
        XCTAssertEqual(try content().refused, [])
        XCTAssertEqual(try content().heldCount, 2)
    }

    // MARK: - Restore as New Copies / Discard

    /// Acceptance (6): "Restore as New Copies" on a restored habit another device deleted gives it
    /// a fresh id and uploads it in the same tap; the old id is left to its tombstone (no
    /// deletion queued), and the row leaves the section.
    func testRestoreAsNewCopiesUploadsACopyAndTheRowGoes() async throws {
        seedOwnerAndCursor()
        let restored = Habit(name: "Restored, deleted elsewhere")
        restored.records = [HabitRecord(date: HabitCalendar.dayKey(for: Date()))]
        context.insert(restored)
        restored.restoredAt = Date()
        restored.hold(.tombstoned)
        try context.save()
        let oldID = restored.id
        stubHappyServer()

        let outcome = try await actions.restoreAsCopies(.tombstoned)

        XCTAssertEqual(outcome.rows.habits, 1)
        XCTAssertEqual(outcome.rows.entries, 1)
        XCTAssertNotEqual(restored.id, oldID)
        XCTAssertEqual(pushed("habits"), [restored.id.uuidString], "the copy went up, not the old id")
        XCTAssertEqual(pushed("entries"), restored.records.map(\.id.uuidString))
        XCTAssertTrue(queue.pending().isEmpty, "no deletion queued for the old id")
        XCTAssertNil(restored.restoredAt)
        XCTAssertFalse(restored.isPending, "acknowledged")
        XCTAssertTrue(try content(signedIn: false).isEmpty, "nothing left to show")
    }

    /// The same for another account's ids (`not_owned`): a restore that kept them, now copies in
    /// the signed-in account.
    func testRestoreAsNewCopiesOfAnotherAccountsRows() async throws {
        seedOwnerAndCursor()
        let foreign = Habit(name: "From account B")
        context.insert(foreign)
        foreign.hold(.notOwned)
        try context.save()
        let oldID = foreign.id
        stubHappyServer()

        _ = try await actions.restoreAsCopies(.notOwned)

        XCTAssertEqual(pushed("habits").count, 1)
        XCTAssertFalse(pushed("habits").contains(oldID.uuidString))
        XCTAssertEqual(try sync.heldRows(in: context), [])
    }

    /// Discard deletes the held rows here and queues nothing: the old id is another account's row
    /// or a tombstone, and a deletion sent for it would be answered for a row this account never
    /// had. No request at all.
    func testDiscardDeletesTheRowsAndQueuesNothing() async throws {
        seedOwnerAndCursor()
        let restored = Habit(name: "Restored, deleted elsewhere")
        restored.records = [HabitRecord(date: HabitCalendar.dayKey(for: Date()))]
        let kept = Habit(name: "Fine")
        context.insert(restored)
        context.insert(kept)
        restored.restoredAt = Date()
        restored.hold(.tombstoned)
        try context.save()

        let outcome = try await actions.discard(.tombstoned)

        XCTAssertEqual(outcome.rows.habits, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Habit>()).map(\.id), [kept.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 0)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: - Recovered edits

    /// "Recovered Edits (N)" counts the owner's lines; Export hands the owner's file; Clear
    /// empties the log (the view confirms first).
    func testClearEmptiesTheOwnersLog() throws {
        seedOwnerAndCursor()
        try appendRecoveredEdit(for: owner)
        try appendRecoveredEdit(named: "Someone else's", for: "99")
        sync.refreshRecoveredEdits()
        XCTAssertEqual(try content().recoveredEdits, 1)
        XCTAssertEqual(sync.recoveredEditsFile.accountID, owner)

        try actions.clearRecoveredEdits()

        XCTAssertEqual(try content().recoveredEdits, 0)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0)
        XCTAssertEqual(try recovery.log.lineCount(accountID: "99"), 1, "only the owner's lines")
    }

    // MARK: - Full Resync

    /// Full Resync marks every row for resend — `syncedAt` kept — and pulls on the current cursor
    /// BEFORE the resend goes up ("Forced resend waits until deletions are settled"); then the
    /// cursor is cleared so the next sync full-pulls against the repaired server.
    func testFullResyncResendsEveryRowAfterAPullAndClearsTheCursor() async throws {
        seedOwnerAndCursor()
        let group = HabitGroup(name: "Morning")
        let habit = Habit(name: "Read")
        let record = HabitRecord(date: HabitCalendar.dayKey(for: Date()))
        habit.records = [record]
        habit.groupId = group.id
        context.insert(group)
        context.insert(habit)
        try context.save()
        // Delivered long ago: nothing is pending before the resync.
        group.acknowledge(sentStamp: group.stamp)
        habit.acknowledge(sentStamp: habit.stamp)
        record.acknowledge(sentStamp: record.stamp)
        try context.save()
        let delivered = habit.syncedAt
        stubHappyServer()

        let ran = await actions.fullResync()

        XCTAssertTrue(ran)
        XCTAssertEqual(syncPaths, ["/v1/sync/pull", "/v1/sync/push", "/v1/sync/pull"], "the pull comes first")
        XCTAssertEqual(syncRequests.first?.query["since"], recentCursor, "on the live cursor")
        XCTAssertEqual(pushed("groups"), [group.id.uuidString])
        XCTAssertEqual(pushed("habits"), [habit.id.uuidString])
        XCTAssertEqual(pushed("entries"), [record.id.uuidString])
        XCTAssertEqual(habit.syncedAt, delivered, "the evidence of delivery is untouched")
        XCTAssertFalse(habit.needsResend)
        XCTAssertFalse(record.isPending)
        XCTAssertNil(cursors.cursor(for: owner), "the next sync full-pulls")
    }

    /// A sync in flight would turn a plain `sync()` away at once; Full Resync waits it out and
    /// then runs its own.
    func testFullResyncWaitsForASyncInFlight() async throws {
        seedOwnerAndCursor()
        let habit = Habit(name: "Read")
        context.insert(habit)
        try context.save()
        let gate = AsyncGate()
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))
        let slow = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                               deletionQueue: queue, sessions: sessions, recoveryLog: recovery.log,
                               afterSyncRequest: { _, _ in await gate.wait() })
        let context = self.context!
        let first = Task { await slow.sync(context: context) }
        while !slow.isSyncing { await Task.yield() }

        let resync = Task { await SyncSectionActions(sync: slow, context: context).fullResync() }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()

        let firstRan = await first.value
        let resyncRan = await resync.value
        XCTAssertTrue(firstRan)
        XCTAssertTrue(resyncRan, "ran after the one in flight, not turned away")
        XCTAssertNil(cursors.cursor(for: owner))
    }

    // MARK: - Restore choices

    private func backup(from account: SyncAccount?) -> BackupDocument {
        DataBackup.snapshot(habits: [Habit(name: "From a backup")], groups: [],
                            account: account.map { BackupAccount(id: $0.id, email: $0.email) })
    }

    func testRestoreChoicesKeepIDsOnlyForThisAccountsOwnBackup() {
        let a = SyncSession.accountA.account
        let accountA = BackupAccount(id: a.id, email: a.email)

        let own = DataExportService.restoreChoices(for: backup(from: a), sync: sync)
        XCTAssertEqual(own.kind, .sameAccount)
        XCTAssertEqual(own.primary, RestorePlan(identity: .keepIDs, owner: accountA))
        XCTAssertNil(own.keepIDs)

        let other = DataExportService.restoreChoices(for: backup(from: SyncSession.accountB.account), sync: sync)
        XCTAssertEqual(other.kind, .otherAccount(email: "b@example.com"))
        XCTAssertEqual(other.primary, RestorePlan(identity: .newCopies, owner: accountA))
        XCTAssertNil(other.keepIDs, "another account's ids would be answered not_owned")

        let legacy = DataExportService.restoreChoices(for: backup(from: nil), sync: sync)
        XCTAssertEqual(legacy.kind, .noAccount(signedIn: true))
        XCTAssertEqual(legacy.primary.identity, .newCopies)
        XCTAssertEqual(legacy.keepIDs, RestorePlan(identity: .keepIDs, owner: accountA),
                       "a 1.3.0 backup may be this account's own")
    }

    /// Signed out, a file naming an account asks whether this device will use that account next:
    /// "Restore as It Was" keeps the ids and makes it the owner; copies leave no owner.
    func testRestoreChoicesSignedOutAskAboutTheFilesAccount() {
        sessions.session = nil
        let b = SyncSession.accountB.account

        let named = DataExportService.restoreChoices(for: backup(from: b), sync: sync)
        XCTAssertEqual(named.kind, .namedAccountWhileSignedOut(email: "b@example.com"))
        XCTAssertEqual(named.primary, RestorePlan(identity: .newCopies, owner: nil))
        XCTAssertEqual(named.keepIDs, RestorePlan(identity: .keepIDs, owner: BackupAccount(id: b.id, email: b.email)))

        let legacy = DataExportService.restoreChoices(for: backup(from: nil), sync: sync)
        XCTAssertEqual(legacy.kind, .noAccount(signedIn: false))
        XCTAssertEqual(legacy.keepIDs, RestorePlan(identity: .keepIDs, owner: nil))
    }

    // MARK: - The hand-over rule

    /// Phase B's rule for the restore screen: a restore that moves the store away from an owner
    /// with queued deletions or recovered edits goes through the hand-over step. Nothing to
    /// leave behind, or the same owner, restores at once.
    func testARestoreLeavingTheOwnersQueueOrLogBehindNeedsTheHandOver() throws {
        seedOwnerAndCursor()
        sessions.session = nil
        let copies = RestorePlan(identity: .newCopies, owner: nil)
        let keepForA = RestorePlan(identity: .keepIDs, owner: BackupAccount(id: owner, email: "a@example.com"))
        func handover(_ plan: RestorePlan) -> RestoreHandover? {
            DataExportService.restoreHandover(for: plan, sync: sync, deletionQueue: queue, defaults: local.defaults)
        }

        XCTAssertNil(handover(copies), "an empty queue and log: nothing is left behind")

        queue.trackHabit("deleted while signed out")
        XCTAssertEqual(handover(copies), RestoreHandover(
            previousOwner: BackupAccount(id: owner, email: "a@example.com"), queuedDeletions: 1, recoveredEdits: 0))
        XCTAssertNil(handover(keepForA), "the same owner keeps its queue")

        queue.clearAll()
        try appendRecoveredEdit(for: owner)
        XCTAssertEqual(handover(copies)?.recoveredEdits, 1)
        XCTAssertEqual(handover(RestorePlan(identity: .newCopies, owner: BackupAccount(id: "8", email: "b@example.com")))?
            .queuedDeletions, 0, "into another account: the log is left behind too")

        owners.clear()
        XCTAssertNil(handover(copies), "no owner: nothing belongs to anyone")
    }

    /// "Restore Anyway" after the hand-over is the ordinary restore: the store changes hands and
    /// the previous owner's queue goes with it (phase B's `adoptRestoredStore`), which is why the
    /// step exists.
    func testRestoreAnywayHandsTheStoreOverAndDropsTheQueue() async throws {
        seedOwnerAndCursor()
        sessions.session = nil
        queue.trackHabit("deleted while signed out")
        let document = backup(from: nil)
        let choices = DataExportService.restoreChoices(for: document, sync: sync)
        XCTAssertNotNil(DataExportService.restoreHandover(for: choices.primary, sync: sync,
                                                          deletionQueue: queue, defaults: local.defaults))

        try await DataExportService.restore(document, into: context, plan: choices.primary, sync: sync, deletionQueue: queue)

        XCTAssertNil(owners.owner)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 1)
    }

    // MARK: - Erase

    /// Erase clears the owner's recovered edits only when the screen offered their export and
    /// said so (`clearingRecoveredEdits`); otherwise they stay under the owner's key.
    func testEraseClearsTheRecoveredEditsOnlyWhenAsked() async throws {
        tokens.delete()   // signed out: the erase makes no request
        let auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                               defaults: local.defaults, onSignOut: { [unowned self] in self.sync.signedOut() })
        sessions.session = nil
        owners.set(SyncOwner(SyncSession.accountA.account))
        try appendRecoveredEdit(for: owner)
        context.insert(Habit(name: "Local"))
        try context.save()

        let kept = await DataExportService.eraseLocalData(in: context, auth: auth, sync: sync)
        XCTAssertEqual(kept, .erased)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 1, "kept by default")

        owners.set(SyncOwner(SyncSession.accountA.account))
        context.insert(Habit(name: "Local again"))
        try context.save()
        let cleared = await DataExportService.eraseLocalData(in: context, clearingRecoveredEdits: true,
                                                             auth: auth, sync: sync)
        XCTAssertEqual(cleared, .erased)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), 0)
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// The erase's own pre-erase sync can archive an edit: a habit edited here and deleted on
    /// another device goes to the recovery log as the full pull removes it. That line was never
    /// counted in the confirmation or offered for export, and "clear the recovered edits" was
    /// chosen for the one line shown — clearing it now would lose the only copy of an edit the
    /// user never saw (phase C review, F4). The erase stops before signing out: nothing erased,
    /// nothing cleared, the new count on screen.
    func testEraseStopsWhenItsOwnSyncArchivedAnEditTheConfirmationNeverCounted() async throws {
        owners.set(SyncOwner(SyncSession.accountA.account))   // no cursor: the sync full-pulls
        try appendRecoveredEdit(named: "Exported already", for: owner)
        let edited = Habit(name: "Edited offline; deleted on another device")
        context.insert(edited)
        edited.updatedAt = SyncTimestamp.floorToMillisecond(Date())
        edited.syncedAt = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-3_600))
        try context.save()
        stubHappyServer()   // the account's snapshot no longer has the habit
        server.on("GET", "/v1/auth/session",
                  respond: .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        let auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                               defaults: local.defaults, onSignOut: { [unowned self] in self.sync.signedOut() })
        await auth.waitForSessionRestore()
        sync.refreshRecoveredEdits()
        let shown = try XCTUnwrap(sync.recoveredEdits)
        XCTAssertEqual(shown.lines, 1, "what the confirmation counted")

        let outcome = await DataExportService.eraseLocalData(in: context, clearingRecoveredEdits: true,
                                                             recoveredEditTotalShown: shown.archivedTotal,
                                                             auth: auth, sync: sync)

        XCTAssertEqual(outcome, .recoveredEditsChanged)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 2, "the new line is kept, to be offered first")
        XCTAssertEqual(sync.recoveredEdits?.lines, 2, "and counted on screen")
        XCTAssertNotNil(tokens.read(), "still signed in: nothing was erased")
        XCTAssertEqual(owners.owner?.id, owner)
        XCTAssertFalse(server.paths.contains("/v1/auth/logout"))

        // Erase again, confirmed for the two lines: it goes through.
        let again = await DataExportService.eraseLocalData(in: context, clearingRecoveredEdits: true,
                                                           recoveredEditTotalShown: 2, auth: auth, sync: sync)
        XCTAssertEqual(again, .erased)
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0)
        XCTAssertNil(owners.owner)
    }

    /// Clear Recovered Edits, the same window: a sync between the dialog opening and the tap
    /// archives another line — Clear takes only the count it was confirmed for.
    func testClearTakesOnlyTheLinesItWasConfirmedFor() throws {
        owners.set(SyncOwner(SyncSession.accountA.account))
        try appendRecoveredEdit(for: owner)
        sync.refreshRecoveredEdits()
        let shown = try XCTUnwrap(sync.recoveredEdits?.archivedTotal)
        try appendRecoveredEdit(named: "Archived while the dialog was up", for: owner)

        XCTAssertFalse(try actions.clearRecoveredEdits(expectedTotal: shown))
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 2)
        XCTAssertEqual(sync.recoveredEdits?.lines, 2, "the row shows the new count")

        XCTAssertTrue(try actions.clearRecoveredEdits(expectedTotal: 2))
        XCTAssertEqual(try recovery.log.lineCount(accountID: owner), 0)
    }

    // MARK: - The F4 guards at the recovery log's cap

    // Review recovery-backup-1: once the log is at its 5 MB cap, an append drops the oldest line
    // as it adds its own, so a line count taken before and after an archive can be equal — over
    // an edit nobody saw. The guards compare lines + dropped (`Summary.archivedTotal`), which
    // only grows until a clear. Here the cap is `filledToTheCap`'s miniature one.

    /// A line archived while the Clear dialog is up, at the cap: the count did not move, and
    /// Clear still takes nothing.
    func testClearAtTheCapTakesOnlyTheLinesItWasConfirmedFor() throws {
        owners.set(SyncOwner(SyncSession.accountA.account))
        let capped = try recovery.filledToTheCap(accountID: owner)
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: sessions, recoveryLog: capped)
        sync.refreshRecoveredEdits()
        let shown = try XCTUnwrap(sync.recoveredEdits)

        try appendRecoveredEdit(named: "Archived while the dialog was up", for: owner, into: capped)
        XCTAssertEqual(try capped.lineCount(accountID: owner), shown.lines, "precondition: at the cap the count did not move")

        XCTAssertFalse(try actions.clearRecoveredEdits(expectedTotal: shown.archivedTotal))
        XCTAssertEqual(try capped.summary(accountID: owner).dropped, 1, "nothing cleared")
        XCTAssertEqual(try capped.lineCount(accountID: owner), shown.lines)
        XCTAssertEqual(sync.recoveredEdits?.archivedTotal, shown.archivedTotal + 1, "the row's summary is the new one")

        // Confirmed again for what is there now: it clears, dropped count and all.
        XCTAssertTrue(try actions.clearRecoveredEdits(expectedTotal: shown.archivedTotal + 1))
        XCTAssertEqual(try capped.summary(accountID: owner), .empty)
    }

    /// The erase's own pre-erase sync archives an edit into a log at its cap: the count the
    /// confirmation showed comes back unchanged, and the erase still stops.
    func testEraseAtTheCapStopsWhenItsOwnSyncArchivedAnEditTheConfirmationNeverCounted() async throws {
        owners.set(SyncOwner(SyncSession.accountA.account))   // no cursor: the sync full-pulls
        let capped = try recovery.filledToTheCap(accountID: owner)
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: queue, sessions: sessions, recoveryLog: capped)
        let edited = Habit(name: "Edited offline; deleted on another device")
        context.insert(edited)
        edited.updatedAt = SyncTimestamp.floorToMillisecond(Date())
        edited.syncedAt = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-3_600))
        try context.save()
        stubHappyServer()   // the account's snapshot no longer has the habit
        server.on("GET", "/v1/auth/session",
                  respond: .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        let auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                               defaults: local.defaults, onSignOut: { [unowned self] in self.sync.signedOut() })
        await auth.waitForSessionRestore()
        sync.refreshRecoveredEdits()
        let shown = try XCTUnwrap(sync.recoveredEdits)

        let outcome = await DataExportService.eraseLocalData(in: context, clearingRecoveredEdits: true,
                                                             recoveredEditTotalShown: shown.archivedTotal,
                                                             auth: auth, sync: sync)

        XCTAssertEqual(try capped.lineCount(accountID: owner), shown.lines, "at the cap the count did not move…")
        XCTAssertEqual(try capped.summary(accountID: owner).dropped, 1, "…because the sync's line pushed the oldest out")
        XCTAssertEqual(outcome, .recoveredEditsChanged)
        XCTAssertNotNil(tokens.read(), "still signed in: nothing was erased")
        XCTAssertEqual(owners.owner?.id, owner)
        XCTAssertFalse(server.paths.contains("/v1/auth/logout"))

        // Confirmed again for what is there now: the erase goes through.
        let again = await DataExportService.eraseLocalData(in: context, clearingRecoveredEdits: true,
                                                           recoveredEditTotalShown: shown.archivedTotal + 1,
                                                           auth: auth, sync: sync)
        XCTAssertEqual(again, .erased)
        XCTAssertEqual(try capped.summary(accountID: owner), .empty)
    }
}

/// Holds a stubbed exchange until the test opens it — "while a sync is in flight".
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
