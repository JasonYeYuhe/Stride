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
/// - what the phase C screens call: the recovery log's count, export and clear
///   (`recoveredEdits`, `exportRecoveredEdits`, `clearRecoveredEdits`); the held rows and their
///   two actions (`heldRows`, `restoreHeldRowsAsNewCopies`, `discardHeldRows`); the restore's
///   owner (`restoreDevice`, `adoptRestoredStore`, used by DataExportService); and the account
///   screen (AccountSwitchView): `settleSignIn` right after a sign-in, `ownerConflict`,
///   `holdings`, "Start from this account's data" (`startFromSignedInAccountsData`) and, for an
///   owner-unknown store, "Upload these habits" (`uploadLocalHabits`). The owner rule itself is
///   `SyncOwnership` in Shared/SyncEngine.swift, so the rehearsal runs it too.
///
/// Also read by phase C UI: the "Sign in again" row reads `needsReauth`; the sync-status line
/// reads `backoff`; Full resync calls `sync(context:options:)` with `.fullResync`.
@MainActor
@Observable
final class SyncService {
    #if DEBUG
    /// The app's instance — or, in StrideAppTests only, the test's own while a hosted test renders
    /// real views that read `shared` (the critic-1 presenter test; `AuthService.shared`).
    static var shared: SyncService { testOverride ?? live }
    static var testOverride: SyncService?
    private static let live = SyncService()
    #else
    static let shared = SyncService()
    #endif

    private(set) var isSyncing = false
    /// When this device last synced, by its own clock — shown in Settings, and nothing else.
    private(set) var lastSyncTime: String?
    private(set) var syncError: String?

    /// The last sync was answered 401. No state was reset: signing into the same account again
    /// resumes. The inline "Sign in again to keep syncing" row on Today (and Settings' Account
    /// section) reads this, together with `AuthService.sessionExpired` — the persisted half, for a
    /// cold launch whose session check finds the token dead before any sync can meet the 401.
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
    /// (doubling 1 min → 6 h, jittered — `SyncBackoffPolicy`; about a minute when no answer came
    /// at all). "Sync Now" and a sign-in always go at once. nil once the window is over.
    var nextAutomaticSync: Date? {
        guard let backoff, backoff.isWaiting(at: Date()) else { return nil }
        return backoff.retryAt
    }
    /// The owner's recovery log, in counts only (`SyncRecoveryLog.Summary`): "Recovered edits (N)"
    /// reads `lines`. nil until first read — Settings calls `refreshRecoveredEdits()` when it
    /// appears; a run that archived and an owner change refresh it too — and nil when the file
    /// could not be read (Settings then shows no count rather than a wrong one).
    private(set) var recoveredEdits: SyncRecoveryLog.Summary?
    /// Signed in as an account that is not this store's owner (or on an owner-unknown store)
    /// while the device holds something to lose (rows, queued deletions, recovery-log lines): no
    /// sync runs until the choice is made. The sign-in flow shows the account screen for it
    /// (`settleSignIn`); a conflict found later by a launch or foreground sync — the user quit
    /// with the screen up — is shown inline in Settings, never as a screen of its own.
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
                // "Sign in again to keep syncing" says it — Today's row, and Settings' Account
                // section in the same words — and nothing else (M2, "Sign-in that stays";
                // acceptance 9). This also set 1.3.0's red "Please log in again" footer, under a
                // green "Signed in", and the footer outlived the session check that signed the
                // device out (E2E S9).
                needsReauth = true
            case .upgradeRequired:
                syncError = transport.displayMessage
            case .backOff(let kind, let answer):
                // The window itself is the engine's (`SyncBackoffStore`, per owner, persisted).
                // A rate limit or the pause switch is shown inline as "Sync paused" — Today's line
                // and the Settings sync section, both from `backoff` — and never as `syncError`
                // (M2 answer table: 429 / 503 `sync_paused`; acceptance (9): "sync paused" and no
                // error). The same test the two rows use, so the three places cannot disagree.
                // Offline, other 5xx and a client bug keep 1.3.0's footer sentence.
                if !SyncBackoffReason(kind, answer: answer).showsSyncPaused {
                    syncError = transport.displayMessage
                }
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

    /// A sign-in completed (`AuthService.verifyToken`, through its `onSignIn`): the session a 401
    /// refused has been replaced, so "Sign in again" has nothing left to ask. Until now the flag
    /// lasted until a sync got through, so the row stayed on Today after the user signed back in —
    /// for good while that sync failed offline, or waited on the account screen's choice. The
    /// sign-in took its snapshot of the row first (`AuthService.signInAgainBeforeSignInKey`), so
    /// the account screen's Cancel still puts the row back (review accounts-2).
    func signedIn() {
        needsReauth = false
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
    /// `clearingRecoveryLog`: the owner's recovered edits go too (phase C: "Erase local data"
    /// clears that owner's log after signing out and erasing). Only once the caller has offered
    /// their export — the log is the only copy of edits a deletion took — so the default keeps
    /// them, under the owner's key, shown again when that account owns the store.
    ///
    /// Also ends Today's "Sign in again to keep syncing" (`SyncSessionSource.localDataErased`):
    /// a signed-out erase after a revoked session used to keep it, persisted, on an empty device.
    func resetSyncState(clearingRecoveryLog: Bool = false) {
        let previousOwner = owners.owner
        signedOut()
        sessions.localDataErased()
        defaults.removeObject(forKey: SyncDefaultsCursorStore.key)
        defaults.removeObject(forKey: SyncDefaultsCursorStore.legacyKey)
        owners.clear()
        deletionQueue.clearAll()
        strikes.clearAll()
        backoffStore.clearAll()
        marks.settle()
        if clearingRecoveryLog, let previousOwner {
            // A clear that fails leaves the lines under the old owner's key, never shown for
            // another account; Settings' Clear can retry once that account owns the store.
            try? recoveryLog.clear(accountID: previousOwner.id)
        }
        refreshRecoveredEdits()
    }

    // MARK: - The owner (account isolation)

    /// The owner rule and the account screen's operations (Shared/SyncEngine.swift), over this
    /// service's stores.
    private var ownership: SyncOwnership {
        SyncOwnership(defaults: defaults, deletionQueue: deletionQueue, recoveryLog: recoveryLog)
    }

    /// Decides whether the signed-in account may sync this store, before a run starts
    /// (`SyncOwnership.decide`):
    ///
    /// - The owner signed in → yes.
    /// - No owner (a fresh 1.3.1 install, an erased store, a 1.3.0 store signed in at its first
    ///   1.3.1 launch that had no rows then — with rows, the session check's answer already made
    ///   its account the owner, `SyncOwnerStore.storedSessionConfirmed(account:)`) → the
    ///   signed-in account adopts the store and its rows. Rows the migrated-rows rule marked
    ///   delivered keep that mark only provisionally: the adopting account's first full pull
    ///   proves it or forgets every mark before its deletion pass (`SyncMarksProof`, run by the
    ///   engine).
    /// - Owner unknown (`SyncOwnerStore.ownerUnknown`: the device reached 1.3.1 signed out, with
    ///   rows) → no, until the account screen's choice: "Upload these habits to this account"
    ///   (`uploadLocalHabits`, which forgets every mark first) or "Start from this account's
    ///   data" (sub-decision (e)).
    /// - Another account, nothing to lose (no rows, no queued deletions, no recovery-log lines) →
    ///   it becomes the owner silently.
    /// - Another account with something to lose → no: `ownerConflict` is set and every sync entry
    ///   point stays blocked, by construction, until the account screen settles it (Export,
    ///   then `startFromSignedInAccountsData`; Cancel signs out).
    ///
    /// Never merges one account's rows into another: an acknowledgement, a cursor and a queued
    /// deletion are true only for the account that gave them.
    private func settleOwner(for session: SyncSession, in context: ModelContext) -> Bool {
        let previous = owners.owner
        let conflict = ownership.settle(for: session.account, in: context)
        ownerConflict = conflict
        if owners.owner != previous {
            // Adopted or switched: the mirrors follow the new owner.
            refreshBackoff()
            refreshRecoveredEdits()
        }
        // Settled — here for `.ready` and for the sync after Start or Upload: a sign-in's
        // account screen is over (review accounts-2).
        if conflict == nil { sessions.signedInAccountOwnsTheStore() }
        return conflict == nil
    }

    /// The store changes hands (`SyncOwnership.handOver`: what was true only for `previous` goes),
    /// and the mirrors follow.
    private func switchOwner(to next: SyncOwner?, from previous: SyncOwner?) {
        ownership.handOver(to: next, from: previous)
        refreshBackoff()
        refreshRecoveredEdits()
    }

    /// The store's owner now. A UserDefaults read, not observed: for a screen deciding what a
    /// confirmation says (Delete Account: does this account's deletion erase this device?).
    var storeOwner: SyncOwner? { owners.owner }

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
    ///
    /// `expectedTotal`: what the confirmation was shown for, as `Summary.archivedTotal`. A sync
    /// between that dialog and the tap can archive more lines — the only copy of an edit the user
    /// never saw, counted or exported — so when the file holds a different total now, nothing is
    /// cleared and this returns false; the refreshed count is on screen for the user to export and
    /// try again. The total, not the line count: at the log's 5 MB cap an append drops the oldest
    /// line as it adds its own, and the count reads the same (review recovery-backup-1). It is
    /// read and the file cleared in one main-actor turn, and archiving happens on the main actor
    /// too, so no line can land in between. A log that cannot be read is not cleared.
    @discardableResult
    func clearRecoveredEdits(expectedTotal: Int? = nil) throws -> Bool {
        defer { refreshRecoveredEdits() }
        if let expectedTotal {
            guard let now = try? recoveryLog.summary(accountID: owners.owner?.id),
                  now.archivedTotal == expectedTotal else { return false }
        }
        try recoveryLog.clear(accountID: owners.owner?.id)
        return true
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

    // MARK: - The account screen (phase C: AccountSwitchView)

    /// What a completed sign-in continues with (`settleSignIn`).
    enum SignInContinuation: Equatable {
        /// Nothing to ask: the owner resumed, the store was adopted, or it changed hands silently.
        /// The caller syncs as it always has.
        case ready
        /// The account screen, as the next step of the sign-in the user started. Every sync entry
        /// point stays blocked until its choice (`ownerConflict` is set).
        case chooseAccountData(SyncOwnerConflict)
        /// Nobody is signed in (the sign-in did not complete, or was undone meanwhile).
        case signedOut
    }

    /// Called by the sign-in flow the moment a token is verified — the typed code in LoginView
    /// and the one-tap link in StrideApp both — BEFORE any sync: settles the owner the way the
    /// next sync would (`settleOwner`), and says whether the flow must continue with the account
    /// screen. Makes no request. Only the sign-in flow shows the screen: a launch or foreground
    /// sync that finds the same conflict blocks silently (M2 acceptance (10): no screen appears
    /// on its own), and Settings shows it inline.
    func settleSignIn(in context: ModelContext) -> SignInContinuation {
        guard let session = sessions.currentSyncSession() else { return .signedOut }
        // The same prerequisite `sync` has: the migrated-rows rule runs before anything reads
        // the store's delivery state. Flag-guarded; StrideApp ran it at launch.
        SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: defaults)
        if settleOwner(for: session, in: context) { return .ready }
        return ownerConflict.map(SignInContinuation.chooseAccountData) ?? .ready
    }

    /// What the device holds that the account screen lists — the rows, the queued deletions and
    /// the recovery-log lines of `conflict`'s owner (nil = the unknown owner). What "Start from
    /// this account's data" would erase.
    func holdings(for conflict: SyncOwnerConflict, in context: ModelContext) -> SyncOwnerHoldings {
        ownership.holdings(owner: conflict.owner, in: context)
    }

    /// The owner's backup file for the screen's "Export a backup" (M1's v2 JSON; its `accountId`
    /// is the OWNER's — whose ids the rows carry — not the account just signed into), and the
    /// owner's recovery-log export, offered when it has lines.
    func backupFile(for conflict: SyncOwnerConflict, container: ModelContainer) -> BackupJSONFile {
        BackupJSONFile(container: container, account: conflict.owner.map { BackupAccount(id: $0.id, email: $0.email) })
    }

    func recoveredEditsFile(for conflict: SyncOwnerConflict) -> RecoveredEditsJSONFile {
        RecoveredEditsJSONFile(log: recoveryLog, accountID: conflict.owner?.id)
    }

    /// "Start from this account's data" (M2, "Different account, something to lose"; also the
    /// owner-unknown store's second choice): the device drops the previous owner's rows and
    /// everything that was true only for that owner (`SyncOwnership.startFromAccountsData`), and
    /// the signed-in account's data comes down in a full pull. The screen offers Export (a v2
    /// backup, plus the recovery log when it has lines) BEFORE this, and confirms.
    ///
    /// Waits out a sync in flight first. Returns false — changing nothing — unless the conflict it
    /// resolves is still the one on screen: signed into `conflict.signedIn` on a store owned by
    /// `conflict.owner`. A sign-out or another sign-in since then must not erase anything.
    /// Otherwise returns whether the sync ran: the erase stands either way (the owner is the new
    /// account — the screen reads `ownerConflict == nil` as done), and a failed pull is retried
    /// like any other.
    @discardableResult
    func startFromSignedInAccountsData(_ conflict: SyncOwnerConflict, in context: ModelContext) async -> Bool {
        await waitUntilIdle()
        guard ownerConflict == conflict,
              ownership.isCurrent(conflict, signedIn: sessions.currentSyncSession()?.account) else { return false }
        do {
            try ownership.startFromAccountsData(conflict, in: context)
        } catch {
            syncError = appLocalized("Unable to save changes. Please try again.")
            return false
        }
        ownerConflict = nil
        refreshBackoff()
        refreshRecoveredEdits()
        return await sync(context: context)
    }

    /// "Upload these habits to this account" — offered only for an owner-unknown store
    /// (sub-decision (e)): every delivery mark is forgotten first, then the signed-in account
    /// adopts the store and a sync uploads it (`SyncOwnership.uploadLocalHabits`). Same guard and
    /// return value as `startFromSignedInAccountsData`; if the marks cannot be saved nothing is
    /// adopted, `syncError` says so, and the screen stays.
    @discardableResult
    func uploadLocalHabits(_ conflict: SyncOwnerConflict, in context: ModelContext) async -> Bool {
        await waitUntilIdle()
        guard conflict.isOwnerUnknown, ownerConflict == conflict,
              ownership.isCurrent(conflict, signedIn: sessions.currentSyncSession()?.account) else { return false }
        do {
            try ownership.uploadLocalHabits(conflict, in: context)
        } catch {
            syncError = appLocalized("Unable to save changes. Please try again.")
            return false
        }
        ownerConflict = nil
        refreshBackoff()
        refreshRecoveredEdits()
        return await sync(context: context)
    }

    // MARK: - Account deletion

    /// After `AuthService.deleteAccount` (the server account is gone, and the device signed out):
    /// "`deleteAccount` erases local data and clears the owner" (M2), plus the deleted account's
    /// recovery log and backoff (`SyncOwnership.accountDeleted`). Only a store that account OWNED
    /// is erased; a store still owned by another account (the deleted one was signed in while
    /// the account screen waited) keeps its rows. Throws when the erase cannot be saved — the
    /// account is gone either way, and Erase Local Data can finish the job.
    func accountDeleted(_ account: SyncAccount, in context: ModelContext) throws {
        stateGeneration += 1
        defer {
            refreshBackoff()
            refreshRecoveredEdits()
        }
        try ownership.accountDeleted(account.id, in: context)
        lastSyncTime = nil
        defaults.removeObject(forKey: lastSyncKey)
    }

    // MARK: - Launch

    /// Once per launch, before the first sync (StrideApp.init): the migrated-rows rule
    /// (`SyncDeliveryMigration`, sub-decision (b); its marks wait for the proof,
    /// `SyncMarksProof`), and — once per install — whether this device
    /// reached 1.3.1 signed out with rows and no owner, which the account screen will need and
    /// which cannot be reconstructed after the first sign-in adopts the store. A stored token
    /// leaves that open until AuthService's session check answers for it
    /// (`SyncOwnerStore.noteFirstLaunch`): a dead one means signed out after all.
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

extension SyncAccount {
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
    /// Erase Local Data has emptied the store and forgotten every account's sync state
    /// (`resetSyncState`): nothing is left to sync, so a lost session is no longer a reason to
    /// ask the user to sign in again (`AuthService.sessionExpired`; the phase C leftovers, the
    /// owner's decision 2).
    func localDataErased()
    /// The signed-in account owns the store now (`settleOwner`): no account screen is pending,
    /// so its Cancel has no "Sign in again" to put back (`AuthService.cancelSignIn`, review
    /// accounts-2).
    func signedInAccountOwnsTheStore()
}

extension SyncSessionSource {
    func localDataErased() {}
    func signedInAccountOwnsTheStore() {}
}

// `SyncAccount`, `SyncOwner`, `SyncOwnerConflict`, `SyncOwnerStore` and the owner rule itself
// (`SyncOwnership`) are in Shared/SyncEngine.swift since phase C, so scripts/sync_rehearsal.sh
// drives the account screen's choices with the app's own code.

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

    func pull(since: String?, deletionsSince: String?, token: String) async -> SyncTransportResponse {
        await record(.pull, await api.syncPull(since: since, deletionsSince: deletionsSince, token: token))
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
