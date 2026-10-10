import Foundation
import SwiftData

// S21 — the account screen, at the engine level (DEV-PLAN-1.3.md M2 Acceptance (5); phase C).
// The rehearsal has no UI, so it drives what the screen's buttons call: the owner rule and its
// operations are `SyncOwnership` in Shared/SyncEngine.swift — the code SyncService runs, not a
// copy — and this device's gate answers the engine exactly as `SyncService.current()` does
// (`.ready` only while the signed-in account is the store's owner). What only the app can show
// (the screen, its order, Cancel's real sign-out) is covered by StrideAppTests/AccountSwitchTests.

/// A 1.3.1 device whose sync gate is the owner rule, with a session that can change: signed
/// out, or into any rehearsal account.
@MainActor
final class OwnerGatedDevice: StoreDevice {
    /// `SyncService.current()`: signed out → `.signedOut`; signed in as the owner → `.ready` with
    /// that session's token; otherwise `.ownerUnsettled`.
    final class Gate: SyncRunGate {
        var answer: () -> SyncGateState = { .signedOut }
        func current() -> SyncGateState { answer() }
    }

    let transport = HTTPTransport(clientHeader: Rehearsal.client131)
    let queue: SyncDeletionQueue
    let cursors: SyncDefaultsCursorStore
    let log: SyncRecoveryLog
    private let gate = Gate()
    private(set) var engine: SyncEngine!
    /// Who is signed in. Changing it is a sign-out (and a sign-in): the generation moves, as
    /// `SyncService.signedOut()` moves `stateGeneration`.
    var signedIn: Account? { didSet { generation += 1 } }
    private var generation = 0

    var ownership: SyncOwnership { SyncOwnership(defaults: defaults, deletionQueue: queue, recoveryLog: log) }
    var owner: SyncOwner? { ownership.owners.owner }

    init(_ name: String) {
        let suite = StoreDevice.makeSuite()
        queue = SyncDeletionQueue(local: suite.defaults, shared: nil)
        cursors = SyncDefaultsCursorStore(defaults: suite.defaults)
        log = SyncRecoveryLog(directory: Rehearsal.root.appendingPathComponent("recovery-logs", isDirectory: true)
            .appendingPathComponent(suite.name, isDirectory: true))
        super.init(name: name, suite: suite)
        engine = SyncEngine(transport: transport, gate: gate, cursorStore: cursors, deletionQueue: queue,
                            strikes: SyncUnknownHabitStrikes(defaults: suite.defaults),
                            marks: SyncMarksProof(defaults: suite.defaults), recoveryLog: log,
                            backoff: SyncBackoffStore(defaults: suite.defaults), report: { _ in })
        gate.answer = { [unowned self] in
            guard let account = self.signedIn else { return .signedOut }
            guard let owner = self.owner, owner.id == account.owner else { return .ownerUnsettled }
            return .ready(SyncRunBinding(ownerID: owner.id, token: account.token, generation: self.generation))
        }
    }

    func syncAccount(_ account: Account) -> SyncAccount { SyncAccount(id: account.owner, email: account.email) }

    /// `SyncService.sync`: the owner is settled first (`SyncOwnership.settle` — a conflict makes
    /// no request), then the engine runs, and asks the gate again itself. nil = blocked by the
    /// conflict before the engine was reached.
    func sync(options: SyncRunOptions = [], trigger: SyncBackoffTrigger = .manual) async -> (conflict: SyncOwnerConflict?, outcome: SyncRunOutcome?) {
        guard let account = signedIn else { return (nil, await engine.run(in: context, options: options, trigger: trigger)) }
        if let conflict = ownership.settle(for: syncAccount(account), in: context) { return (conflict, nil) }
        return (nil, await engine.run(in: context, options: options, trigger: trigger))
    }
}

extension Scenarios {
    func accountScreen() async throws {
        let x = try Account.create(), y = try Account.create()
        let d = OwnerGatedDevice("D")
        let yPhone = Device131("Y's phone", account: y)
        defer { d.remove(); yPhone.remove() }
        yPhone.habit("Y's habit", days: [0, 1])
        try yPhone.save()
        guard isSynced(await yPhone.sync()) else { throw Missing(description: "Y's phone did not sync") }

        // D belongs to X, fully synced.
        d.signedIn = x
        let read = d.habit("X: Read", days: [0, 1, 2])
        d.habit("X: Run", days: [0])
        try d.save()
        let first = await d.sync()
        guard first.conflict == nil, let o = first.outcome, isSynced(o) else {
            throw Missing(description: "X's first sync: \(first)")
        }
        let xCursor = d.cursors.cursor(for: x.owner)

        // Sign out of X, into Y: the screen, and not one request from any trigger.
        d.signedIn = nil
        d.signedIn = y
        let mark = d.transport.mark()
        let decision = d.ownership.decide(for: d.syncAccount(y), in: d.context)
        let manual = await d.sync()
        let automatic = await d.sync(trigger: .automatic)
        let resync = await d.sync(options: .fullResync)
        let direct = await d.engine.run(in: d.context, options: [], trigger: .manual)   // past the wrapper
        var blockedByEngine = false
        if case .blocked(.ownerUnsettled) = direct { blockedByEngine = true }
        let conflict = manual.conflict
        report.check("sign-in to another account on a device holding X's habits → the account screen, and no sync request from any trigger",
                     decision == .choose(SyncOwnerConflict(owner: SyncOwner(d.syncAccount(x)), signedIn: d.syncAccount(y)))
                        && conflict != nil && automatic.conflict == conflict && resync.conflict == conflict
                        && blockedByEngine && d.transport.since(mark).isEmpty && d.owner?.id == x.owner,
                     "decision \(decision); engine alone: \(describe(direct)); requests since the sign-in: \(d.transport.since(mark).count)")

        // Cancel: sign out of Y. The store, its owner and X's cursor are untouched; back into X it
        // resumes, and a sync with no edits pushes 0/0/0 on the kept cursor.
        d.signedIn = nil
        d.signedIn = x
        let resumeMark = d.transport.mark()
        let resumed = await d.sync()
        let exResume = d.transport.since(resumeMark)
        let habitsAfterResume = try d.habits().count
        report.check("Cancel, then back into X: resumes on X's cursor and pushes 0/0/0",
                     resumed.conflict == nil && resumed.outcome.map(isSynced) == true && pushes(exResume).isEmpty
                        && xCursor != nil && exResume.first?.since == xCursor
                        && habitsAfterResume == 2,
                     describe(exResume))

        // An offline edit under X that never reaches X, then Y again: Export first, then Start.
        read.note = "offline under X"
        read.touch()
        d.habit("X: never pushed", days: [3])
        try d.save()
        d.signedIn = nil
        d.signedIn = y
        let startConflict = try unwrap(await d.sync().conflict, "the screen for Y")
        // The account the screen's Export writes, taken as the app takes it: from the conflict's
        // owner (`SyncService.backupFile(for:)`). Built by hand from X, the check could not fail
        // (review recovery-backup-3); built this way, it fails when the screen would record any
        // account but the store's owner, X, while Y is signed in.
        let exportAccount = startConflict.owner.map { BackupAccount(id: $0.id, email: $0.email) }
        let backup = try DataBackup.decode(try DataBackup.encode(
            DataBackup.snapshot(of: d.context, account: exportAccount)))
        let exported = Set(backup.habits.map(\.name))
        report.check("Export first: the backup names X and holds every habit on the device, the never-pushed one included",
                     exportAccount?.id == x.owner && backup.accountId == x.owner && backup.accountEmail == x.email
                        && exported == ["X: Read", "X: Run", "X: never pushed"],
                     "accountId \(backup.accountId ?? "none"); \(exported.sorted())")

        let xIDs = Set(try d.habits().map(\.id.uuidString))
        try d.ownership.startFromAccountsData(startConflict, in: d.context)
        let startMark = d.transport.mark()
        let started = await d.sync()
        let exStart = d.transport.since(startMark)
        let onY = try await serverSnapshot(y)
        let names = Set(try d.habits().map(\.name))
        let yIDs = Set(onY.habits.map { SyncReconciler.canonicalID($0.id) })
        report.check("Start from this account's data: a full pull on Y's token; none of X's habits left on D or in Y's account",
                     started.outcome.map(isSynced) == true && exStart.first?.since == nil && pushes(exStart).isEmpty
                        && exStart.allSatisfy { $0.token == y.token } && names == ["Y's habit"]
                        && yIDs.isDisjoint(with: xIDs) && d.owner?.id == y.owner && d.queue.pending().isEmpty
                        && d.cursors.cursor(for: x.owner) == nil,
                     "\(describe(exStart)); D \(names.sorted()); Y's account \(onY.habits.map(\.name).sorted())")
    }

    /// The owner-unknown store's "Upload these habits to this account": a 1.3.0 store opened
    /// signed out (its session expired, so 1.3.1 cannot tell whose rows these are), signed back
    /// into the account it last synced as. Every migrated mark is forgotten first, so the full
    /// pull deletes nothing by absence: it re-marks what the account already holds (applying
    /// remote state acknowledges a row), and the push uploads the rest — here the habit made
    /// after the last 1.3.0 sync.
    func accountScreenUnknownOwnerUpload() async throws {
        let x = try Account.create()
        let old = SnapshotDevice("D on 1.3.0", shape: .v130, account: x)
        let d = OwnerGatedDevice("D on 1.3.1, signed out")
        defer { old.remove(); d.remove() }
        old.age(old.habit("Read", days: [0, 1]))
        try old.save()
        let synced = try await old.sync()
        guard synced.push == 200, synced.pull == 200 else { throw Missing(description: "1.3.0 sync: \(synced)") }
        let lastSync130 = SyncTimestamp.string(from: Date())
        old.habit("Made after the last 1.3.0 sync", days: [3])   // offline, never pushed
        try old.save()
        try d.open130Store(from: old)
        d.defaults.set(lastSync130, forKey: SyncDeliveryMigration.lastSyncTimeKey)
        _ = SyncDeliveryMigration.runOnceIfNeeded(in: d.context, defaults: d.defaults)
        d.ownership.owners.noteFirstLaunch(hasStoredSession: false, hasRows: true)

        d.signedIn = x
        let mark = d.transport.mark()
        let asked = await d.sync()
        let conflict = try unwrap(asked.conflict, "the owner-unknown screen")
        report.check("owner unknown: the sign-in asks (Upload or Start) and makes no request",
                     conflict.isOwnerUnknown && d.transport.since(mark).isEmpty && d.marks.isAwaited,
                     "conflict \(conflict); requests \(d.transport.since(mark).count)")

        try d.ownership.uploadLocalHabits(conflict, in: d.context)
        let uploaded = await d.sync()
        let ex = d.transport.since(mark)
        let onX = try await serverSnapshot(x)
        let onD = Set(try d.habits().map(\.name))
        let pending = try d.context.fetch(FetchDescriptor<Habit>()).filter(\.isPending).count
        let both: Set<String> = ["Read", "Made after the last 1.3.0 sync"]
        report.check("Upload: marks forgotten first, the full pull deletes nothing, and what the account lacks goes up",
                     uploaded.outcome.map(isSynced) == true && ex.first?.since == nil && !d.marks.isAwaited
                        && totalPushed(ex).habits == 1 && totalPushed(ex).entries == 1 && pending == 0
                        && onD == both && d.logItems().isEmpty
                        && Set(onX.habits.map(\.name)) == both && onX.habits.count == 2
                        && d.owner?.id == x.owner && !d.ownership.owners.ownerUnknown,
                     "\(describe(ex)); pushed \(totalPushed(ex)); X's account \(onX.habits.map(\.name))")
    }
}

extension OwnerGatedDevice {
    var marks: SyncMarksProof { SyncMarksProof(defaults: defaults) }
    func logItems() -> [SyncRecoveryItem] {
        ((try? log.read(accountID: owner?.id).lines) ?? []).compactMap(\.item)
    }
}
