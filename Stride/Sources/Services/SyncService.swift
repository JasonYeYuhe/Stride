import Foundation
import SwiftData
import SwiftUI
import os.log

/// The app's side of sync: a thin wrapper around `SyncEngine` (Shared/SyncEngine.swift).
///
/// The engine — the chunked push with per-chunk acknowledgement, the per-answer rules, the
/// cursor and forced-resend ordering, the reconciler — lives in Shared/ so that the host-less
/// StrideTests and scripts/sync_rehearsal.sh run the very code the app runs (DEV-PLAN-1.3.md
/// M2). Testing a hand-copied replica is how the reconciler drifted before 1.2.3. What stays
/// here is only what needs the app:
/// - the transport over `APIClient` (`APISyncTransport`), with the token the run captured;
/// - the run gate: the signed-in account (AuthService) and the store's **owner**, so a push or
///   pull runs only while the signed-in account is the owner — checked by the engine at the
///   start of a run and again before every request and after every await;
/// - the UI state Settings shows (`isSyncing`, `syncError`, `lastSyncTime`), mirrors of the
///   per-owner backoff (`backoff`, `nextAutomaticSync`, `isPaused`);
/// - what the phase C screens call, none of which has UI yet: the recovery log's count, export
///   and clear (`recoveredEdits`, `exportRecoveredEdits`, `clearRecoveredEdits`); the held rows
///   and their two actions (`heldRows`, `restoreHeldRowsAsNewCopies`, `discardHeldRows`); the
///   restore's owner (`restoreDevice`, `adoptRestoredStore`, used by DataExportService); and the
///   account screen's "Start from this account's data" (`startFromSignedInAccountsData`).
///
/// Still phase C, with their hooks: the account screen reads `ownerConflict`; the "Sign in again"
/// row reads `needsReauth`; the sync-status line reads `backoff`; Full resync calls
/// `sync(context:options:)` with `.fullResync`.
@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private(set) var isSyncing = false
    /// When this device last synced, by its own clock — shown in Settings, and nothing else.
    private(set) var lastSyncTime: String?
    private(set) var syncError: String?

    /// The last sync was answered 401. No state was reset: signing into the same account again
    /// resumes. The inline "Sign in again to keep syncing" row on Today reads this (not in this
    /// slice; until it exists the Settings footer says "Please log in again", as 1.3.0 did).
    private(set) var needsReauth = false
    /// The owner's backoff as last read from `SyncBackoffStore` — why automatic syncs wait
    /// (`reason`: offline, server error, rate limited, paused, client bug) and since when. The
    /// phase C status line reads it. A mirror: the store (UserDefaults, per owner) is the truth,
    /// and survives a relaunch, which the slice's in-memory window did not — a paused server was
    /// asked again by every device that was opened.
    private(set) var backoff: SyncBackoffState?
    /// The server's pause switch (503 `sync_paused`) answered the last sync. For the "sync
    /// paused" line.
    var isPaused: Bool { backoff?.reason == .paused }
    /// Automatic syncs (launch, foreground) before this are skipped: the server asked this
    /// device to wait (429 / 503 with `Retry-After`), or the last syncs failed and are backing off
    /// (doubling 1 min → 6 h, jittered — `SyncBackoffPolicy`). "Sync Now" and a sign-in always
    /// go at once. nil once the window is over.
    var nextAutomaticSync: Date? {
        guard let backoff, backoff.isWaiting(at: Date()) else { return nil }
        return backoff.retryAt
    }
    /// The owner's recovery log, in counts only (`SyncRecoveryLog.Summary`): "Recovered edits (N)"
    /// reads `lines`. nil until first read — Settings calls `refreshRecoveredEdits()` when it
    /// appears; a run that archived and an owner change refresh it too — and nil when the file
    /// could not be read (Settings then shows no count rather than a wrong one).
    private(set) var recoveredEdits: SyncRecoveryLog.Summary?
    /// Signed in as an account that is not this store's owner while the device holds something
    /// to lose (rows, queued deletions, recovery-log lines): no sync runs until the choice is
    /// made. The account screen (M2, not in this slice) reads this and settles ownership.
    private(set) var ownerConflict: SyncOwnerConflict?

    enum Trigger {
        /// Sync Now, a sign-in, Erase's pre-erase sync: goes at once, backoff or not.
        case userInitiated
        /// Launch and foreground (and M3's background refresh, and any post-edit sync): skipped
        /// while the owner's backoff window is open.
        case automatic

        var backoff: SyncBackoffTrigger { self == .automatic ? .automatic : .manual }
    }

    private let lastSyncKey = SyncDeliveryMigration.lastSyncTimeKey

    private let api: APIClient
    private let defaults: UserDefaults
    private let deletionQueue: SyncDeletionQueue
    private let sessionsOverride: (any SyncSessionSource)?
    /// The file log (per owner, in Application Support). Never the in-memory sink: 1.3.1 promises
    /// that an edit a deletion takes is on disk before the row goes.
    let recoveryLog: SyncRecoveryLog
    private let bounds: SyncPushBounds
    private let report: (SyncDiagnosticReport) -> Void
    private let afterSyncRequest: APISyncTransport.Hook?

    /// The defaults are what `shared` uses. StrideAppTests passes an APIClient over a stubbed
    /// URLSession, a throwaway defaults suite and a queue on it, and its own session source, so
    /// a test neither talks to a server nor touches the host app's cursors, owner and queues.
    ///
    /// - Parameters:
    ///   - sessions: who is signed in, with which token. nil = `AuthService.shared`, looked up
    ///     only when needed (a default argument is evaluated off the main actor).
    ///   - recoveryLog: where rows a deletion displaces go before they are deleted. nil = the file
    ///     log in the app's Application Support (`SyncRecoveryLog.defaultDirectory`). Tests pass
    ///     one over a temporary directory, so they never write into the host app's.
    ///   - bounds: the planner's chunk bounds; tests shrink them to make several chunks.
    ///   - report: sync diagnostics (ids, codes, counts only). nil = the unified log; see
    ///     `logDiagnostic` for why not Sentry yet.
    ///   - afterSyncRequest: a test seam, called after each sync request is answered and before
    ///     the engine reads the answer — "while chunk 1 is in flight".
    init(
        api: APIClient = .shared,
        defaults: UserDefaults = .standard,
        deletionQueue: SyncDeletionQueue = .live,
        sessions: (any SyncSessionSource)? = nil,
        recoveryLog: SyncRecoveryLog? = nil,
        bounds: SyncPushBounds = .standard,
        report: ((SyncDiagnosticReport) -> Void)? = nil,
        afterSyncRequest: APISyncTransport.Hook? = nil
    ) {
        self.api = api
        self.defaults = defaults
        self.deletionQueue = deletionQueue
        self.sessionsOverride = sessions
        self.recoveryLog = recoveryLog ?? SyncRecoveryLog()
        self.bounds = bounds
        self.report = report ?? Self.logDiagnostic
        self.afterSyncRequest = afterSyncRequest
        lastSyncTime = defaults.string(forKey: lastSyncKey)
        // The window a previous launch left (a paused server's Retry-After): shown at once, and
        // the next automatic sync honours it. The recovered-edits count is read when Settings
        // asks (`refreshRecoveredEdits`), not here: `shared` is made at launch, and a file read
        // on that path buys nothing.
        refreshBackoff()
    }

    private var sessions: any SyncSessionSource { sessionsOverride ?? AuthService.shared }
    private var owners: SyncOwnerStore { SyncOwnerStore(defaults: defaults) }
    private var cursors: SyncDefaultsCursorStore { SyncDefaultsCursorStore(defaults: defaults) }
    private var strikes: SyncUnknownHabitStrikes { SyncUnknownHabitStrikes(defaults: defaults) }
    private var marks: SyncMarksProof { SyncMarksProof(defaults: defaults) }
    private var backoffStore: SyncBackoffStore { SyncBackoffStore(defaults: defaults) }

    // MARK: - Deletion Tracking

    // Queued in SyncDeletionQueue (Shared/) and sent with the next push. They are removed
    // only after the server accepts the chunk that carried them — see the type's comment.

    /// Track a deleted habit ID for next sync push.
    func trackDeletedHabit(_ id: String) { deletionQueue.trackHabit(id) }

    /// Track a deleted entry ID for next sync push.
    func trackDeletedEntry(_ id: String) { deletionQueue.trackEntry(id) }

    /// Track a deleted group ID for next sync push.
    func trackDeletedGroup(_ id: String) { deletionQueue.trackGroup(id) }

    // MARK: - Sync

    /// One sync run through the engine: (a full pull first when there is no cursor) → the push,
    /// chunk by chunk → a pull → the cursor.
    ///
    /// Returns true only when THIS call ran to the end. False when it did nothing — signed out,
    /// another sync already running, an automatic sync inside the retry window, an account that
    /// is not the owner — as well as when it stopped. Erase Local Data used to read success off
    /// `syncError == nil`, which the "already syncing" return leaves as the in-flight sync reset
    /// it: it took a sync it never ran for a successful one and erased under it. Anything that
    /// must know goes through `syncAfterInFlight(context:)`.
    @discardableResult
    func sync(context: ModelContext, trigger: Trigger = .userInitiated, options: SyncRunOptions = []) async -> Bool {
        // Claimed before the first suspension, so a caller that saw `isSyncing == false` and
        // calls in the same main-actor turn (syncAfterInFlight) is never the one turned away.
        guard !isSyncing else { return false }
        // The fast path of the engine's own check (`SyncEngine.run(trigger:)`): an automatic sync
        // inside the owner's window does not even flip `isSyncing`, so Settings shows no spinner
        // for a sync that is not going to happen. Only while the owner is the one signed in: B
        // signing into a device A owned may be about to adopt it (`settleOwner`), and A's window
        // is not B's. The engine asks the same store again with the run's binding — the rule.
        if trigger == .automatic, let owner = owners.owner,
           sessions.currentSyncSession()?.account.id == owner.id,
           !backoffStore.mayRun(.automatic, ownerID: owner.id) {
            refreshBackoff()
            return false
        }
        isSyncing = true
        defer { isSyncing = false }

        guard await sessions.resolveSyncSession() != nil,
              // Read again after the await: what counts is who is signed in now.
              let session = sessions.currentSyncSession()
        else { return false }

        // Before the first 1.3.1 sync, every time: flag-guarded, so a bool read after the first.
        // It must precede the first run — a full pull deletes delivered rows the server lacks,
        // and until this runs no migrated row counts as delivered (sub-decision (b)). StrideApp
        // also runs it at launch; this call covers any path that syncs first.
        if SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults) == .failed {
            syncError = appLocalized("Unable to save changes. Please try again.")
            return false
        }
        guard settleOwner(for: session, in: context) else { return false }

        syncError = nil
        let transport = APISyncTransport(api: api, afterExchange: afterSyncRequest)
        let engine = SyncEngine(
            transport: transport, gate: self, cursorStore: cursors, deletionQueue: deletionQueue,
            strikes: strikes, marks: marks, recoveryLog: recoveryLog, backoff: backoffStore,
            report: report, bounds: bounds)
        let outcome = await engine.run(in: context, options: options, trigger: trigger.backoff)
        return finish(outcome, transport: transport)
    }

    /// Waits for a sync already in flight to finish, then runs one of its own and reports
    /// whether that one succeeded. For callers that act on the result (Erase Local Data): the
    /// in-flight sync may have started before the edits they need pushed.
    func syncAfterInFlight(context: ModelContext) async -> Bool {
        await waitUntilIdle()
        return await sync(context: context)
    }

    /// Returns once no sync is running (or the task is cancelled). Restore waits here: a full
    /// pull already awaiting its response would otherwise land after the restore and delete
    /// every restored row the account does not hold (SyncReconciler's full-pull pass).
    func waitUntilIdle() async {
        while isSyncing && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The run's outcome as UI state. The Settings footer keeps 1.3.0's wording: the server's
    /// sentence, or this build's own for the codes it knows (`APIError.displayMessage`) — never
    /// a raw code.
    private func finish(_ outcome: SyncRunOutcome, transport: APISyncTransport) -> Bool {
        // The engine wrote the outcome to the store under the run's owner; mirror it. Not after
        // a run a sign-out ended: the engine wrote nothing for it, and `signedOut()` has just
        // cleared the mirror for a device that is now signed out.
        if case .stopped(.bindingChanged, _) = outcome {} else { refreshBackoff() }
        if (outcome.summary?.archived ?? 0) > 0 { refreshRecoveredEdits() }
        switch outcome {
        case .synced:
            let now = SyncTimestamp.string(from: Date())
            lastSyncTime = now
            defaults.set(now, forKey: lastSyncKey)
            needsReauth = false
            return true

        case .blocked:
            return false

        case .stopped(let reason, _):
            switch reason {
            case .bindingChanged:
                // Not an error to show: the session this sync served is gone, on purpose (a
                // sign-out, an erase, another account). Nothing after it was written.
                break
            case .needsReauth:
                needsReauth = true
                syncError = appLocalized("Please log in again")
            case .upgradeRequired:
                syncError = transport.displayMessage
            case .backOff:
                // The window itself is the engine's (`SyncBackoffStore`, per owner, persisted).
                // Spec: a rate limit or a pause is shown inline as "sync paused", never as
                // `syncError`. That line is phase C, so until it lands the footer keeps 1.3.0's
                // sentence for both (they are calm, translated sentences, not codes).
                syncError = transport.displayMessage
            case .recoveryLogFailed, .localFailure:
                // The store (or the recovery log) refused a write. Nothing was deleted, no cursor
                // written; the next sync retries.
                syncError = appLocalized("Unable to save changes. Please try again.")
            }
            return false
        }
    }

    // MARK: - Sign-out, erase

    /// Bumped by `signedOut()` and `resetSyncState()`. Part of every run's binding: a run that
    /// started before it stops at its next check and writes nothing more — otherwise a launch or
    /// foreground sync still awaiting its pull when the user signs out applied the old account's
    /// rows to the (possibly just erased) store and wrote a cursor after the sign-out.
    @ObservationIgnored private var stateGeneration = 0

    /// Sign-out (AuthService.logout, deleteAccount): ends any run in flight, and nothing more.
    ///
    /// The cursor, the deletion queue, the owner, the backoff, the recovery log and every row's
    /// `syncedAt` and holds stay, so signing back into the same account resumes and re-uploads
    /// nothing (M2, "Same account again"). 1.3.0 cleared the cursor here and pushed everything on
    /// the next sign-in — into whichever account that was. The backoff is stored with the owner
    /// like the cursor; the sign-in's own sync is user-initiated and goes whatever it says.
    func signedOut() {
        stateGeneration += 1
        lastSyncTime = nil
        defaults.removeObject(forKey: lastSyncKey)
        needsReauth = false
        ownerConflict = nil
        // Nothing to show while signed out; the store keeps the window for the owner.
        backoff = nil
    }

    /// Erase Local Data (DataExportService), after its sign-out: the store is about to be empty,
    /// so nothing this device knew about any account's server state is true any more.
    ///
    /// Every cursor goes, so the next sign-in full-pulls and the account comes back; before
    /// 1.2.3 an incremental pull from the old cursor left an erased device "Signed in" with no
    /// habits. The owner goes too — an erased store has none, and the next account signed into
    /// adopts it (M2, "No owner") — and with it the deletion queue, the `unknown_habit`
    /// strikes and every owner's backoff, which belong to the server state it described. An
    /// empty store has no delivery marks to prove.
    ///
    /// The recovery log stays. It is not server state but the only copy of edits a deletion
    /// took, and Erase offers no export of it (the account screen's "Start from this account's
    /// data" does, and clears it); it has its own Clear. Its lines are the owner's, so they show
    /// again when that account owns the store.
    func resetSyncState() {
        signedOut()
        defaults.removeObject(forKey: SyncDefaultsCursorStore.key)
        defaults.removeObject(forKey: SyncDefaultsCursorStore.legacyKey)
        owners.clear()
        deletionQueue.clearAll()
        strikes.clearAll()
        backoffStore.clearAll()
        marks.settle()
        refreshRecoveredEdits()
    }

    // MARK: - The owner (account isolation)

    /// Decides whether the signed-in account may sync this store, before a run starts.
    ///
    /// - The owner signed in → yes.
    /// - No owner (a fresh 1.3.1 install, an erased store, a 1.3.0 store) → the signed-in account
    ///   adopts the store and its rows, whichever account it is. Rows the migrated-rows rule
    ///   marked delivered keep that mark only provisionally: the adopting account's first full
    ///   pull proves it (a row this device delivered is in the snapshot) or forgets every mark
    ///   before its deletion pass (`SyncMarksProof`, run by the engine) — so adopting a store
    ///   whose marks were another account's uploads it rather than deleting it. TODO(M2 account
    ///   screen): when `SyncOwnerStore.ownerUnknown` (the device updated to 1.3.1 signed out,
    ///   with rows) the screen offers "Upload these habits to this account" — which must call
    ///   `SyncMarksProof.forgetMarks(in:)` before adopting — and "Start from this account's
    ///   data" instead (sub-decision (e)); until it exists this is 1.3.0's behaviour for that
    ///   device, with the proof in place of 1.3.0's merge.
    /// - Another account, nothing to lose (no rows, no queued deletions, no recovery-log lines) →
    ///   it becomes the owner silently.
    /// - Another account with something to lose → no: `ownerConflict` is set and every sync entry
    ///   point stays blocked, by construction, until the account screen settles it (Export,
    ///   then `startFromSignedInAccountsData`; Cancel signs out). The screen is phase C.
    ///
    /// Never merges one account's rows into another: an acknowledgement, a cursor and a queued
    /// deletion are true only for the account that gave them.
    private func settleOwner(for session: SyncSession, in context: ModelContext) -> Bool {
        let owners = self.owners
        guard let owner = owners.owner else {
            owners.set(SyncOwner(session.account))
            ownerConflict = nil
            return true
        }
        if owner.id == session.account.id {
            if owner.email != session.account.email { owners.set(SyncOwner(session.account)) }
            ownerConflict = nil
            return true
        }
        guard hasSomethingToLose(in: context, owner: owner) else {
            // What "Start from this account's data" clears, minus the rows (there are none) and
            // the recovery log (it has no lines, or this would be a conflict).
            switchOwner(to: SyncOwner(session.account), from: owner)
            ownerConflict = nil
            return true
        }
        ownerConflict = SyncOwnerConflict(owner: owner, signedIn: session.account)
        return false
    }

    /// The store changes hands while it holds nothing of `previous`'s (it is empty, or was just
    /// erased or restored into): what belonged to `previous` goes — its queued deletions, the
    /// `unknown_habit` strikes, its backoff and its cursor — and `next` becomes the owner. An
    /// acknowledgement, a queued deletion and a server's "wait" are true only for the account
    /// that gave them.
    ///
    /// The cursor goes with the queue because it is only true together with it: "this device
    /// holds the account's state as of C, minus the deletions still queued". A restore into an
    /// empty store drops a queue that may not be empty (rows deleted while signed out, then a
    /// backup restored naming no account), and if `previous` later adopts the store again, an
    /// incremental pull from C never returns those rows — they were not changed since C — while
    /// their deletions never reach the server: the device and the account drift apart until the
    /// cursor ages out (phase B review, R1). Without a cursor that return is a full pull, and the
    /// device converges on what the account holds. So a cursor exists only for the store's
    /// owner; `next`'s is cleared too, in case one outlived an earlier hand-over.
    private func switchOwner(to next: SyncOwner?, from previous: SyncOwner?) {
        if let previous, previous.id != next?.id {
            deletionQueue.clearAll()
            strikes.clearAll()
            backoffStore.clear(for: previous.id)
            let cursors = self.cursors
            cursors.setCursor(nil, for: previous.id)
            if let next { cursors.setCursor(nil, for: next.id) }
        }
        if let next { owners.set(next) } else { owners.clear() }
        refreshBackoff()
        refreshRecoveredEdits()
    }

    /// Rows, queued deletions or the owner's recovery-log lines: what "Start from this account's
    /// data" would erase. A store — or a log — that cannot be counted counts as something to lose.
    private func hasSomethingToLose(in context: ModelContext, owner: SyncOwner) -> Bool {
        if !deletionQueue.pending().isEmpty { return true }
        if ((try? recoveryLog.lineCount(accountID: owner.id)) ?? 1) > 0 { return true }
        do {
            return try context.fetchCount(FetchDescriptor<Habit>()) > 0
                || context.fetchCount(FetchDescriptor<HabitRecord>()) > 0
                || context.fetchCount(FetchDescriptor<HabitGroup>()) > 0
        } catch {
            return true
        }
    }

    // MARK: - Backoff mirror

    /// Reads the owner's backoff into `backoff`. The owner, not whoever is signed in: the window
    /// belongs to the account whose server state the runs were about, and a signed-in account
    /// that is not the owner cannot sync anyway.
    private func refreshBackoff() {
        backoff = owners.owner.flatMap { backoffStore.state(for: $0.id) }
    }

    // MARK: - Recovered edits (phase C: Settings → sync section → "Recovered edits (N)")

    // Every call names the store's OWNER: the engine archives under the run's owner, which is
    // the store's owner (a run only goes while they are the same). While another account is
    // signed in and the account screen is up, the owner's lines are exactly what that screen
    // offers to export before "Start from this account's data" clears them.

    /// Re-reads the count (Settings' onAppear). A file that cannot be read leaves nil — no count
    /// rather than a wrong one; the hold-nothing rule means a failed read never loses a line.
    func refreshRecoveredEdits() {
        recoveredEdits = try? recoveryLog.summary(accountID: owners.owner?.id)
    }

    /// Export as JSON: the owner's log as one document (`SyncRecoveryExport`), for a ShareLink
    /// (`RecoveredEditsJSONFile` in DataExportService) or the account screen's Export. Local
    /// only — it holds names and notes, so it never goes near a diagnostic report.
    func exportRecoveredEdits(exportedAt: Date = Date()) throws -> Data {
        try recoveryLog.exportData(accountID: owners.owner?.id, exportedAt: exportedAt)
    }

    /// The export as a ShareLink item, named `Stride-RecoveredEdits-<date>.json`.
    var recoveredEditsFile: RecoveredEditsJSONFile {
        RecoveredEditsJSONFile(log: recoveryLog, accountID: owners.owner?.id)
    }

    /// Clear: the owner's lines and dropped count are gone. The UI confirms first — this is the
    /// only copy of those edits.
    func clearRecoveredEdits() throws {
        defer { refreshRecoveredEdits() }
        try recoveryLog.clear(accountID: owners.owner?.id)
    }

    // MARK: - Held rows (phase C: the sync section's inline rows)

    /// One inline row: the rows held for `reason`, counted (a held habit stands for all of its
    /// check-ins, which are not counted again — `SyncCopies.heldRows`).
    struct HeldRows: Equatable {
        var reason: SyncHoldReason
        var counts: SyncRowCounts
        /// "Restore as new copies" / "Discard" apply: the id itself is what the server refused
        /// (`not_owned`, `tombstoned`). The other reasons are about the row's content, which a
        /// new id would re-send into the same refusal; an edit lifts those, and they are only
        /// counted ("2 changes can't sync").
        var canRestoreAsCopies: Bool { SyncCopies.convertibleReasons.contains(reason) }
    }

    /// Every hold reason with at least one held row, in `SyncHoldReason`'s order. `tombstoned`
    /// is "N restored habits were deleted on another device"; `not_owned` is a restore that kept
    /// another account's ids, or an owner-unknown device's upload.
    func heldRows(in context: ModelContext) throws -> [HeldRows] {
        try SyncHoldReason.allCases.compactMap { reason in
            let held = try SyncCopies.heldRows(in: context, reasons: [reason])
            return held.isEmpty ? nil : HeldRows(reason: reason, counts: held.counts)
        }
    }

    /// "Restore as new copies" for the rows held for `reason`: fresh ids in place
    /// (`SyncCopies.reidentify`), then a sync, so the copies reach the account without a second
    /// tap. Waits out a sync in flight first — a run acknowledging an old id while it is
    /// re-identified would mark the NEW row delivered. Nothing suspends between the wait and the
    /// conversion (both on the main actor), so no run can start in between.
    ///
    /// The caller reschedules reminders and reloads widgets (`Outcome.habitIDs` maps a widget
    /// configured on a converted habit), as it does after a restore. A reason that is not
    /// `canRestoreAsCopies` converts nothing: its rows come back in `Outcome.ignored`.
    @discardableResult
    func restoreHeldRowsAsNewCopies(_ reason: SyncHoldReason, in context: ModelContext) async throws -> SyncCopies.Outcome {
        await waitUntilIdle()
        let outcome = try SyncCopies.reidentify(try SyncCopies.heldRows(in: context, reasons: [reason]), in: context)
        if outcome.rows.total > 0 { await sync(context: context) }
        return outcome
    }

    /// "Discard" for the rows held for `reason`: deleted on this device, nothing queued, nothing
    /// archived (the user chose it on rows the list showed; a restored row's backup file still
    /// has it — but a `not_owned` row from an owner-unknown upload may exist nowhere else, which
    /// the confirmation must say). Same wait as `restoreHeldRowsAsNewCopies`.
    @discardableResult
    func discardHeldRows(_ reason: SyncHoldReason, in context: ModelContext) async throws -> SyncCopies.Outcome {
        await waitUntilIdle()
        return try SyncCopies.discard(try SyncCopies.heldRows(in: context, reasons: [reason]), in: context)
    }

    // MARK: - Restore's owner (DataExportService.restoreDecision / restore)

    /// Where a restore happens, for `DataBackup.restoreDecision`: signed in as an account this
    /// device knows, or signed out — with `next`, the account the user says this device will use
    /// next (the restore screen asks only when the file names one).
    func restoreDevice(next: BackupAccount? = nil) -> RestoreDevice {
        guard let session = sessions.currentSyncSession() else { return .signedOut(next: next) }
        return .signedIn(BackupAccount(id: session.account.id, email: session.account.email))
    }

    /// After a restore has saved: the store's owner becomes `owner` (`RestorePlan.owner`).
    ///
    /// - Copies restored while signed into B, or B's own backup with its ids → B owns the store,
    ///   so the next sync pushes them with no second sign-in (review 2: the first draft left no
    ///   owner, and the gate then blocked every sync until a sign-in that never came).
    /// - Restored while signed out without naming an account → no owner: the next account signed
    ///   into adopts the rows (M2, "No owner").
    ///
    /// The store was empty (restore refuses any other), so it holds nothing of a previous
    /// owner's rows: its queued deletions, strikes, backoff and cursor go, as in the silent
    /// switch. Deletions queued while signed out are dropped with the rest, so if that account
    /// adopts the store again its first sync is a full pull, and the habits those deletions named
    /// come back from the account (visible, never a silent drift — `switchOwner`). A restore that
    /// keeps the store's own owner changes nothing.
    func adoptRestoredStore(owner: BackupAccount?) {
        let next = owner.map { SyncOwner(SyncAccount(id: $0.id, email: $0.email)) }
        let previous = owners.owner
        if let next, next == previous { return }
        switchOwner(to: next, from: previous)
        ownerConflict = nil
    }

    // MARK: - The account screen (phase C)

    /// "Start from this account's data" (M2, "Different account, something to lose"): the
    /// device drops the previous owner's rows and everything that was true only for that owner,
    /// and the signed-in account's data comes down in a full pull. The screen offers Export (a
    /// v2 backup, plus `exportRecoveredEdits` when `recoveredEdits` has lines) BEFORE this.
    ///
    /// In order: wait out a sync in flight; erase the local rows (`DataBackup.eraseLocalData`);
    /// clear the deletion queue, the strikes, and the previous owner's cursor, backoff and
    /// recovery log; clear the new owner's cursor too — an erased store pulled incrementally from
    /// an old cursor would come back without the account's older rows (the 1.2.3 "signed in, no
    /// habits" bug); settle the marks proof (an empty store has no marks); make the signed-in
    /// account the owner; sync (a full pull, since it has no cursor).
    ///
    /// Returns false — changing nothing — unless the conflict it resolves is still the one on
    /// screen: signed into `conflict.signedIn` on a store owned by `conflict.owner`. A sign-out
    /// or another sign-in since then must not erase anything. Otherwise returns whether the sync
    /// ran (the erase stands either way; a failed pull is retried like any other).
    @discardableResult
    func startFromSignedInAccountsData(_ conflict: SyncOwnerConflict, in context: ModelContext) async -> Bool {
        await waitUntilIdle()
        guard ownerConflict == conflict, owners.owner == conflict.owner,
              sessions.currentSyncSession()?.account == conflict.signedIn else { return false }
        do {
            try DataBackup.eraseLocalData(in: context)
        } catch {
            syncError = appLocalized("Unable to save changes. Please try again.")
            return false
        }
        // Past the erase: the previous owner's log is not "something to lose" any more for the
        // screen's purposes — the user exported it or chose not to. A clear that fails leaves the
        // lines under the old owner's key, never read for the new one.
        try? recoveryLog.clear(accountID: conflict.owner.id)
        let cursors = self.cursors
        cursors.setCursor(nil, for: conflict.owner.id)
        cursors.setCursor(nil, for: conflict.signedIn.id)
        marks.settle()
        switchOwner(to: SyncOwner(conflict.signedIn), from: conflict.owner)
        ownerConflict = nil
        return await sync(context: context)
    }

    // MARK: - Launch

    /// Once per launch, before the first sync (StrideApp.init): the migrated-rows rule
    /// (`SyncDeliveryMigration`, sub-decision (b); its marks wait for the proof,
    /// `SyncMarksProof`), and — once per install — whether this device
    /// reached 1.3.1 signed out with rows and no owner, which the account screen will need and
    /// which cannot be reconstructed after the first sign-in adopts the store.
    static func prepareLaunch(context: ModelContext, defaults: UserDefaults, hasStoredSession: Bool) {
        SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults)
        let hasRows = ((try? context.fetchCount(FetchDescriptor<Habit>())) ?? 0) > 0
            || ((try? context.fetchCount(FetchDescriptor<HabitGroup>())) ?? 0) > 0
        SyncOwnerStore(defaults: defaults).noteFirstLaunch(hasStoredSession: hasStoredSession, hasRows: hasRows)
    }

    // MARK: - Diagnostics

    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Sync")

    /// Where sync diagnostics go for now: the unified log, codes and counts public, ids private.
    ///
    /// TODO(M2): the spec reports held rows and client-bug answers to Sentry (ids, reason codes,
    /// counts, the build — never names, notes or values; `SyncDiagnosticReport` has no field for
    /// content). docs/privacy.html lists exactly what the app sends Sentry, per version, and a
    /// sync report is not on it, so the capture waits for that page to say so.
    static func logDiagnostic(_ report: SyncDiagnosticReport) {
        let status = report.status.map(String.init) ?? "-"
        let counts = report.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let ids = report.reasons.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        logger.notice("sync \(report.event, privacy: .public) code=\(report.code ?? "-", privacy: .public) status=\(status, privacy: .public) counts=\(counts, privacy: .public) ids=\(ids, privacy: .private)")
    }
}

// MARK: - The run gate

extension SyncService: SyncRunGate {
    /// Asked by the engine at the start of a run and again before every request and after every
    /// await. `.ready` only while a session is stored AND its account is this store's owner; the
    /// binding carries that session's token (every request of the run uses it, never the
    /// keychain's current one) and `stateGeneration`. A sign-out, a sign-in to another account
    /// or an erase between two chunks therefore ends the run before its next request or write.
    func current() -> SyncGateState {
        guard let session = sessions.currentSyncSession() else { return .signedOut }
        guard let owner = owners.owner, owner.id == session.account.id else { return .ownerUnsettled }
        return .ready(SyncRunBinding(ownerID: owner.id, token: session.token, generation: stateGeneration))
    }
}

// MARK: - Session and owner

/// A server account: `APIUser.id` as a string (the owner key everywhere sync stores per-account
/// state) and its email, for display.
struct SyncAccount: Equatable, Sendable {
    var id: String
    var email: String

    init(id: String, email: String) {
        self.id = id
        self.email = email
    }

    init(_ user: APIUser) {
        self.init(id: String(user.id), email: user.email)
    }
}

/// The stored session: its token and the account it belongs to.
struct SyncSession: Equatable, Sendable {
    var token: String
    var account: SyncAccount
}

/// Who is signed in (AuthService in the app; a fake in tests).
@MainActor
protocol SyncSessionSource: AnyObject {
    /// Now, without waiting: the gate's question, asked many times per run.
    func currentSyncSession() -> SyncSession?
    /// Before a run: may wait for the launch session check or ask the server who a stored token
    /// belongs to.
    func resolveSyncSession() async -> SyncSession?
}

/// The account whose data this store holds (M2 account isolation). Its id is the key of the
/// per-owner cursor (`SyncDefaultsCursorStore`); the email is for the account screen.
struct SyncOwner: Equatable {
    var id: String
    var email: String

    init(_ account: SyncAccount) {
        id = account.id
        email = account.email
    }
}

/// Signed in as `signedIn` on a store owned by `owner`, with something to lose.
struct SyncOwnerConflict: Equatable {
    var owner: SyncOwner
    var signedIn: SyncAccount
}

/// The owner record, in the same defaults as the cursors (`UserDefaults.standard` in the app).
struct SyncOwnerStore {
    static let ownerKey = "stride_sync_owner"
    /// Set once, at the first 1.3.1 launch, when the device was signed out with rows and no
    /// owner: 1.3.0 records no account and clears its cursor on sign-out, so those rows may be a
    /// previous account's or nobody's (M2, "Owner unknown").
    static let ownerUnknownKey = "stride_sync_owner_unknown"
    static let firstLaunchNotedKey = "stride_sync_owner_first_launch_noted"

    let defaults: UserDefaults

    var owner: SyncOwner? {
        guard let dict = defaults.dictionary(forKey: Self.ownerKey),
              let id = dict["id"] as? String, let email = dict["email"] as? String else { return nil }
        return SyncOwner(SyncAccount(id: id, email: email))
    }

    var ownerUnknown: Bool { defaults.bool(forKey: Self.ownerUnknownKey) }

    func set(_ owner: SyncOwner) {
        defaults.set(["id": owner.id, "email": owner.email], forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.ownerUnknownKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.ownerUnknownKey)
    }

    func noteFirstLaunch(hasStoredSession: Bool, hasRows: Bool) {
        guard !defaults.bool(forKey: Self.firstLaunchNotedKey) else { return }
        defaults.set(true, forKey: Self.firstLaunchNotedKey)
        guard owner == nil, hasRows, !hasStoredSession else { return }
        defaults.set(true, forKey: Self.ownerUnknownKey)
    }
}

// MARK: - Transport

/// `SyncTransport` over `APIClient`: the exact chunk bytes, the run's token, the client header
/// (added by APIClient on every request). Keeps the last exchange so the Settings footer can
/// say what stopped a run in 1.3.0's words.
@MainActor
final class APISyncTransport: SyncTransport {
    typealias Hook = @MainActor (SyncEndpoint, SyncTransportResponse) async -> Void

    private let api: APIClient
    private let afterExchange: Hook?
    private(set) var lastExchange: APIClient.SyncExchange?

    init(api: APIClient, afterExchange: Hook? = nil) {
        self.api = api
        self.afterExchange = afterExchange
    }

    func push(body: Data, token: String) async -> SyncTransportResponse {
        await record(.push, await api.syncPush(body: body, token: token))
    }

    func pull(since: String?, token: String) async -> SyncTransportResponse {
        await record(.pull, await api.syncPull(since: since, token: token))
    }

    private func record(_ endpoint: SyncEndpoint, _ exchange: APIClient.SyncExchange) async -> SyncTransportResponse {
        lastExchange = exchange
        await afterExchange?(endpoint, exchange.response)
        return exchange.response
    }

    /// The footer's text for the answer that stopped the run (always the last one): the
    /// system's words for no answer, otherwise `APIError.displayMessage` over the server's body.
    var displayMessage: String {
        guard let exchange = lastExchange else { return appLocalized("Request failed") }
        switch exchange.failure {
        case .invalidResponse: return APIError.displayMessage(for: APIError.invalidResponse)
        case .transport(let description): return description
        case nil: break
        }
        guard let status = exchange.response.status else { return appLocalized("Request failed") }
        return APIError.displayMessage(for: APIClient.serverError(status: status, body: exchange.response.body))
    }
}
