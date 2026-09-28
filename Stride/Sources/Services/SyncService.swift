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
/// - the UI state Settings shows (`isSyncing`, `syncError`, `lastSyncTime`) and the automatic
///   retry window.
///
/// Not in this slice, with their hooks: the account screen reads `ownerConflict` and settles
/// ownership (`settleOwner`); the "Sign in again" row reads `needsReauth`; the sync-status
/// line reads `isPaused` / `nextAutomaticSync`; the recovery-log file replaces
/// `SyncMemoryRecoveryLog` (`recoveryLog`); Full resync calls `sync(context:options:)` with
/// `.fullResync`.
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
    /// The server's pause switch (503 `sync_paused`) answered the last sync. For the "sync
    /// paused" line.
    private(set) var isPaused = false
    /// Automatic syncs (launch, foreground) before this are skipped: the server asked this
    /// device to wait (429 / 503 with `Retry-After`), or the last syncs failed and are backing off
    /// (doubling 1 min → 6 h, jittered — `SyncBackoffPolicy`). "Sync Now" and a sign-in always
    /// go at once. In memory: a relaunch tries again.
    private(set) var nextAutomaticSync: Date?
    /// Signed in as an account that is not this store's owner while the device holds something
    /// to lose (rows, queued deletions, recovery-log lines): no sync runs until the choice is
    /// made. The account screen (M2, not in this slice) reads this and settles ownership.
    private(set) var ownerConflict: SyncOwnerConflict?

    enum Trigger {
        /// Sync Now, a sign-in, Erase's pre-erase sync: goes at once, backoff or not.
        case userInitiated
        /// Launch and foreground: skipped while `nextAutomaticSync` is in the future.
        case automatic
    }

    private let lastSyncKey = SyncDeliveryMigration.lastSyncTimeKey

    private let api: APIClient
    private let defaults: UserDefaults
    private let deletionQueue: SyncDeletionQueue
    private let sessionsOverride: (any SyncSessionSource)?
    private let recoveryLog: any SyncRecoveryLogSink
    private let bounds: SyncPushBounds
    private let report: (SyncDiagnosticReport) -> Void
    private let afterSyncRequest: APISyncTransport.Hook?
    @ObservationIgnored private var consecutiveFailures = 0

    /// The defaults are what `shared` uses. StrideAppTests passes an APIClient over a stubbed
    /// URLSession, a throwaway defaults suite and a queue on it, and its own session source, so
    /// a test neither talks to a server nor touches the host app's cursors, owner and queues.
    ///
    /// - Parameters:
    ///   - sessions: who is signed in, with which token. nil = `AuthService.shared`, looked up
    ///     only when needed (a default argument is evaluated off the main actor).
    ///   - recoveryLog: where rows a deletion displaces go before they are deleted. nil = an
    ///     in-memory log. TODO(M2 recovery log): `Shared/SyncRecoveryLog.swift`, the file in
    ///     Application Support, flushed before returning — 1.3.1 must not ship with the
    ///     in-memory one, whose lines are gone when the app exits.
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
        recoveryLog: (any SyncRecoveryLogSink)? = nil,
        bounds: SyncPushBounds = .standard,
        report: ((SyncDiagnosticReport) -> Void)? = nil,
        afterSyncRequest: APISyncTransport.Hook? = nil
    ) {
        self.api = api
        self.defaults = defaults
        self.deletionQueue = deletionQueue
        self.sessionsOverride = sessions
        self.recoveryLog = recoveryLog ?? SyncMemoryRecoveryLog()
        self.bounds = bounds
        self.report = report ?? Self.logDiagnostic
        self.afterSyncRequest = afterSyncRequest
        lastSyncTime = defaults.string(forKey: lastSyncKey)
    }

    private var sessions: any SyncSessionSource { sessionsOverride ?? AuthService.shared }
    private var owners: SyncOwnerStore { SyncOwnerStore(defaults: defaults) }
    private var cursors: SyncDefaultsCursorStore { SyncDefaultsCursorStore(defaults: defaults) }
    private var strikes: SyncUnknownHabitStrikes { SyncUnknownHabitStrikes(defaults: defaults) }

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
        if trigger == .automatic, let next = nextAutomaticSync, Date() < next { return false }
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
            strikes: strikes, recoveryLog: recoveryLog, report: report, bounds: bounds)
        let outcome = await engine.run(in: context, options: options)
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
        switch outcome {
        case .synced:
            let now = SyncTimestamp.string(from: Date())
            lastSyncTime = now
            defaults.set(now, forKey: lastSyncKey)
            needsReauth = false
            isPaused = false
            consecutiveFailures = 0
            nextAutomaticSync = nil
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
            case .backOff(let kind, _):
                consecutiveFailures += 1
                nextAutomaticSync = Date().addingTimeInterval(SyncBackoffPolicy.delay(
                    for: kind, consecutiveFailures: consecutiveFailures, unitRandom: .random(in: 0...1)))
                if case .serverAsked(_, let paused) = kind { isPaused = paused } else { isPaused = false }
                // Spec: a rate limit or a pause is shown inline as "sync paused", never as
                // `syncError`. That line is not in this slice, so until it lands the footer keeps
                // 1.3.0's sentence for both (they are calm, translated sentences, not codes).
                syncError = transport.displayMessage
            case .recoveryLogFailed, .localFailure:
                // The store (or the recovery log) refused a write. Nothing was deleted, no cursor
                // written; the next sync retries.
                syncError = appLocalized("Unable to save changes. Please try again.")
            }
            return false
        }
    }

    // MARK: - Sign-in, sign-out, erase

    /// AuthService, once a sign-in has completed (a magic link verified): a new session. If the
    /// store has no owner yet, its migrated delivery marks can no longer be credited to the
    /// session this device had at its first 1.3.1 launch (`SyncOwnerStore.noteSignIn`).
    func signedIn() {
        owners.noteSignIn()
    }

    /// Bumped by `signedOut()` and `resetSyncState()`. Part of every run's binding: a run that
    /// started before it stops at its next check and writes nothing more — otherwise a launch or
    /// foreground sync still awaiting its pull when the user signs out applied the old account's
    /// rows to the (possibly just erased) store and wrote a cursor after the sign-out.
    @ObservationIgnored private var stateGeneration = 0

    /// Sign-out (AuthService.logout, deleteAccount): ends any run in flight, and nothing more.
    ///
    /// The cursor, the deletion queue, the owner and every row's `syncedAt` and holds stay, so
    /// signing back into the same account resumes and re-uploads nothing (M2, "Same account
    /// again"). 1.3.0 cleared the cursor here and pushed everything on the next sign-in —
    /// into whichever account that was.
    func signedOut() {
        stateGeneration += 1
        lastSyncTime = nil
        defaults.removeObject(forKey: lastSyncKey)
        needsReauth = false
        isPaused = false
        consecutiveFailures = 0
        nextAutomaticSync = nil
        ownerConflict = nil
    }

    /// Erase Local Data (DataExportService), after its sign-out: the store is about to be empty,
    /// so nothing this device knew about any account's server state is true any more.
    ///
    /// Every cursor goes, so the next sign-in full-pulls and the account comes back; before
    /// 1.2.3 an incremental pull from the old cursor left an erased device "Signed in" with no
    /// habits. The owner goes too — an erased store has none, and the next account signed into
    /// adopts it (M2, "No owner") — and with it the deletion queue and the `unknown_habit`
    /// strikes, which belong to that owner.
    func resetSyncState() {
        signedOut()
        defaults.removeObject(forKey: SyncDefaultsCursorStore.key)
        defaults.removeObject(forKey: SyncDefaultsCursorStore.legacyKey)
        owners.clear()
        deletionQueue.clearAll()
        strikes.clearAll()
    }

    // MARK: - The owner (account isolation)

    /// Decides whether the signed-in account may sync this store, before a run starts.
    ///
    /// - The owner signed in → yes.
    /// - No owner (a fresh 1.3.1 install, an erased store, a 1.3.0 store) → the signed-in account
    ///   adopts the store and its rows. Rows the migrated-rows rule marked delivered keep that
    ///   mark only when the adopting session is the one this device had at its first 1.3.1
    ///   launch; otherwise the marks are forgotten first, so adopting means uploading
    ///   (`SyncOwnerStore.MarksAttribution` — kept, they would make the first full pull delete
    ///   every one the new account lacks). TODO(M2 account screen): when `SyncOwnerStore.ownerUnknown`
    ///   (the device updated to 1.3.1 signed out, with rows) the screen offers "Upload these
    ///   habits to this account" and "Start from this account's data" instead (sub-decision (e));
    ///   until it exists this is 1.3.0's behaviour for that device.
    /// - Another account, nothing to lose (no rows, no queued deletions, no recovery-log lines) →
    ///   it becomes the owner silently.
    /// - Another account with something to lose → no: `ownerConflict` is set and every sync entry
    ///   point stays blocked, by construction, until the account screen settles it (Export,
    ///   then "Start from this account's data"; Cancel signs out). TODO(M2 account screen).
    ///
    /// Never merges one account's rows into another: an acknowledgement, a cursor and a queued
    /// deletion are true only for the account that gave them.
    private func settleOwner(for session: SyncSession, in context: ModelContext) -> Bool {
        let owners = self.owners
        guard let owner = owners.owner else {
            if owners.marksAttribution == .unknown {
                do {
                    try SyncDeliveryMigration.forgetDeliveryMarks(in: context)
                } catch {
                    // Not adopted: kept, the marks would let the first full pull delete rows.
                    syncError = appLocalized("Unable to save changes. Please try again.")
                    return false
                }
            }
            owners.set(SyncOwner(session.account))
            ownerConflict = nil
            return true
        }
        if owner.id == session.account.id {
            if owner.email != session.account.email { owners.set(SyncOwner(session.account)) }
            ownerConflict = nil
            return true
        }
        guard hasSomethingToLose(in: context) else {
            // What "Start from this account's data" clears, minus the rows (there are none).
            deletionQueue.clearAll()
            strikes.clearAll()
            owners.set(SyncOwner(session.account))
            ownerConflict = nil
            return true
        }
        ownerConflict = SyncOwnerConflict(owner: owner, signedIn: session.account)
        return false
    }

    /// Rows, queued deletions or recovery-log lines: what "Start from this account's data" would
    /// erase. A store that cannot be counted counts as something to lose.
    private func hasSomethingToLose(in context: ModelContext) -> Bool {
        if !deletionQueue.pending().isEmpty { return true }
        if let log = recoveryLog as? SyncMemoryRecoveryLog, !log.lines.isEmpty { return true }
        do {
            return try context.fetchCount(FetchDescriptor<Habit>()) > 0
                || context.fetchCount(FetchDescriptor<HabitRecord>()) > 0
                || context.fetchCount(FetchDescriptor<HabitGroup>()) > 0
        } catch {
            return true
        }
    }

    // MARK: - Launch

    /// Once per launch, before the first sync (StrideApp.init): the migrated-rows rule
    /// (`SyncDeliveryMigration`, sub-decision (b)), and — once per install — whether this device
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

    /// Whose delivery marks a store with no owner holds (M2 slice review). The migrated-rows rule
    /// (`SyncDeliveryMigration`) marks rows delivered to the account 1.3.0 last synced as, which
    /// 1.3.0 never recorded; the marks are safe to keep only for that account. Set at the first
    /// 1.3.1 launch when the store has rows and no owner; consumed when an account adopts it.
    enum MarksAttribution: String {
        /// A session was stored at the first 1.3.1 launch — 1.3.0's own, whose account its
        /// snapshots went to — and no sign-in has replaced it since. Its adoption keeps them.
        case launchSession = "launch_session"
        /// Signed out at the first launch (a 1.3.0 session that expired deletes the token but
        /// keeps `stride_last_sync_time`), or a sign-in since: the account cannot be named, and
        /// the adoption forgets the marks.
        case unknown
    }
    static let marksAttributionKey = "stride_sync_marks_attribution"

    let defaults: UserDefaults

    var owner: SyncOwner? {
        guard let dict = defaults.dictionary(forKey: Self.ownerKey),
              let id = dict["id"] as? String, let email = dict["email"] as? String else { return nil }
        return SyncOwner(SyncAccount(id: id, email: email))
    }

    var ownerUnknown: Bool { defaults.bool(forKey: Self.ownerUnknownKey) }

    var marksAttribution: MarksAttribution? {
        defaults.string(forKey: Self.marksAttributionKey).flatMap(MarksAttribution.init(rawValue:))
    }

    /// A sign-in completed. Every path by which the launch session ends — sign-out, an expired
    /// session's `{user: null}`, a 401 — leaves the device signed out, and the only way back to a
    /// sync is a new sign-in, so this one hook is where the launch session's claim ends.
    func noteSignIn() {
        guard owner == nil, marksAttribution == .launchSession else { return }
        defaults.set(MarksAttribution.unknown.rawValue, forKey: Self.marksAttributionKey)
    }

    func set(_ owner: SyncOwner) {
        defaults.set(["id": owner.id, "email": owner.email], forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.ownerUnknownKey)
        defaults.removeObject(forKey: Self.marksAttributionKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.ownerUnknownKey)
        defaults.removeObject(forKey: Self.marksAttributionKey)
    }

    func noteFirstLaunch(hasStoredSession: Bool, hasRows: Bool) {
        guard !defaults.bool(forKey: Self.firstLaunchNotedKey) else { return }
        defaults.set(true, forKey: Self.firstLaunchNotedKey)
        guard owner == nil, hasRows else { return }
        if !hasStoredSession {
            defaults.set(true, forKey: Self.ownerUnknownKey)
        }
        let attribution: MarksAttribution = hasStoredSession ? .launchSession : .unknown
        defaults.set(attribution.rawValue, forKey: Self.marksAttributionKey)
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
