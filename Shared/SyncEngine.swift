import Foundation
import SwiftData

// The 1.3.1 sync run (DEV-PLAN-1.3.md M2): chunked push with per-chunk acknowledgement, the
// per-answer rules, the cursor-age and forced-resend ordering, and a run bound to one account
// across its awaits.
//
// In Shared/, behind a small transport protocol, so that the host-less StrideTests run the
// real engine and scripts/sync_rehearsal.sh compiles Shared/ into a macOS tool and drives the
// SAME engine against a local server. `SyncService` (Stride/Sources) is the app's thin wrapper:
// an APIClient-backed transport, the owner / token / generation capture, UI state. Testing a
// hand-copied replica instead of the real code is how the reconciler drifted before 1.2.3.
//
// It runs on the main actor, store work included, and stays there after the M2 large-account
// work (StrideTests/SyncPerformanceTests; DEV-PLAN-1.3.md M2 progress log). What made a large
// account slow was quadratic work in the planner, resolver and reconciler, now gone; what is
// left is mostly SwiftData saving the rows a step changed, and a save belongs to the context's
// own actor: `ModelContext` is not Sendable, and the context is the app's `mainContext`, the one
// the UI's unsaved edits live in — the reconciler saves those first so a rollback never takes a
// check-in. Reconciling on a background context instead would mean a second context the UI
// learns about only by merge, and a new class of races with the user's taps. The pure steps
// (decoding a pull, parsing its stamps) now cost about 0.1 s for 54,750 entries, too little to be
// worth another suspension point in a run that re-checks its binding after every one.
//
// Plugged in since the slice (phase B): the recovery-log file (`Shared/SyncRecoveryLog.swift`)
// implements `SyncRecoveryLogSink`, and the per-owner backoff (`Shared/SyncBackoff.swift`) is
// consulted and written HERE, with the run's own binding — so the app, StrideTests and the
// rehearsal share one rule instead of each wrapper keeping a window of its own. Still to come
// (phase C): the owner gate UI decides what `SyncRunGate.current()` returns; the sync-status
// line reads `SyncBackoffStore.state(for:)`; Settings → Full resync is `SyncRunOptions.fullResync`.

// MARK: - Transport

/// What one sync request came back with. `status == nil` means no HTTP answer at all (offline,
/// timeout, DNS, TLS); the engine never needs to know which.
struct SyncTransportResponse: Equatable, Sendable {
    var status: Int?
    var body = Data()
    /// The `Retry-After` header, as sent.
    var retryAfter: String? = nil

    static let noAnswer = SyncTransportResponse(status: nil)
}

/// The two requests a sync run makes, with the token the run captured when it started.
///
/// Every request carries THAT token, never "whoever is signed in now": `APIClient` reads the
/// token from the keychain on every request, so a later chunk of a run that started under
/// account A would otherwise carry A's rows on B's session after a switch mid-run (review 2).
/// Implementations add the client header (`X-Stride-Client`) themselves; the server gates the
/// millisecond pull, the row caps and `cursor_expired` on it.
@MainActor
protocol SyncTransport: AnyObject {
    /// POST /v1/sync/push with exactly `body` — the bytes the planner measured against the
    /// 1 MB bound (`SyncPushChunk.body`). Never re-encode.
    func push(body: Data, token: String) async -> SyncTransportResponse
    /// GET /v1/sync/pull, `?since=` when `since` is non-nil (a full pull otherwise).
    func pull(since: String?, token: String) async -> SyncTransportResponse
}

// MARK: - Run binding (the owner check)

/// What a run is bound to, captured when it starts: the store's owner (the server user id), the
/// session token, and the wrapper's state generation (bumped by sign-out, erase and account
/// deletion).
struct SyncRunBinding: Equatable, Sendable {
    var ownerID: String
    var token: String
    var generation: Int
}

enum SyncGateState: Equatable, Sendable {
    /// Signed in as the store's owner.
    case ready(SyncRunBinding)
    case signedOut
    /// Signed in, but not as the owner — or the owner is not settled yet (a device with rows and
    /// an unknown or different owner, until the user chooses). Account isolation: every sync
    /// entry point is blocked by construction until ownership is settled, not call site by call
    /// site.
    case ownerUnsettled
}

/// The hook the app (and the rehearsal tool) answers: may a run go, and as whom.
///
/// Asked once at the start of a run and again before every request and after every await,
/// before any acknowledgement, deletion-queue change, reconcile or cursor write. Anything but
/// `.ready` with the captured binding ends the run acknowledging nothing
/// (`SyncStopReason.bindingChanged`).
@MainActor
protocol SyncRunGate: AnyObject {
    func current() -> SyncGateState
}

// MARK: - Cursor store

/// The `?since` for the next pull, per owner: a cursor is true only for the account whose
/// server state it walked (account isolation — "none of it is ever read for another account").
@MainActor
protocol SyncCursorStore: AnyObject {
    func cursor(for ownerID: String) -> String?
    func setCursor(_ cursor: String?, for ownerID: String)
}

/// The UserDefaults cursor store: one dictionary, owner id → cursor.
@MainActor
final class SyncDefaultsCursorStore: SyncCursorStore {
    /// A new key, not 1.3.0's `stride_sync_cursor`: that one belongs to nobody in particular.
    /// The first 1.3.1 sync therefore full-pulls, which is the settling pass the migrated-rows
    /// rule wants anyway. `adoptLegacyCursor` is there if the wrapper decides otherwise.
    static let key = "stride_sync_cursors_by_owner"
    static let legacyKey = "stride_sync_cursor"

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func cursor(for ownerID: String) -> String? {
        (defaults.dictionary(forKey: Self.key)?[ownerID] as? String)
    }

    func setCursor(_ cursor: String?, for ownerID: String) {
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        if let cursor { all[ownerID] = cursor } else { all.removeValue(forKey: ownerID) }
        if all.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(all, forKey: Self.key) }
    }

    /// Moves 1.3.0's owner-less cursor to `ownerID` — only for a device the wrapper knows was
    /// signed into that account when 1.3.1 first launched.
    func adoptLegacyCursor(for ownerID: String) {
        guard let legacy = defaults.string(forKey: Self.legacyKey) else { return }
        if cursor(for: ownerID) == nil { setCursor(legacy, for: ownerID) }
        defaults.removeObject(forKey: Self.legacyKey)
    }
}

// MARK: - Recovery log

/// Why a row went to the recovery log.
enum SyncRecoveryReason: String, Codable, Sendable {
    /// A pull deleted it: `deleted*Ids`, full-pull absence, or its habit's cascade.
    case deletedElsewhere = "deleted_elsewhere"
    /// A push was answered `tombstoned` / `tombstoned_habit`.
    case tombstoned
}

/// One displaced row: one line of the recovery log (`{archivedAt, reason, accountId, group |
/// habit | record}`), in DataBackup's v2 item shapes.
struct SyncRecoveryItem: Equatable {
    enum Row: Equatable {
        case group(BackupGroup)
        /// Without its records: they get lines of their own.
        case habit(BackupHabit)
        /// With its habit's id and name, so the line reads on its own.
        case record(BackupRecord, habitID: UUID?, habitName: String?)
    }

    var archivedAt: Date
    var reason: SyncRecoveryReason
    var row: Row

    var ref: SyncRowRef {
        switch row {
        case .group(let g): return SyncRowRef(kind: .group, id: g.id.uuidString)
        case .habit(let h): return SyncRowRef(kind: .habit, id: h.id.uuidString)
        case .record(let r, _, _): return SyncRowRef(kind: .entry, id: r.id.uuidString)
        }
    }
}

/// Where a deletion puts the pending and held rows it takes, BEFORE it deletes them.
///
/// `archive` returns only once the lines are on disk (appended and flushed —
/// `FileHandle.synchronize()`), and throws if they are not. A throw means the deletion does not
/// happen: the reconciler rolls the pull back and writes no cursor, and a push drop leaves the
/// row pending, so the next sync retries either way. The app's sink is the file
/// (`Shared/SyncRecoveryLog.swift`: JSON lines in Application Support, one file per owner, 5 MB
/// cap, export); `SyncMemoryRecoveryLog` is the tests'.
@MainActor
protocol SyncRecoveryLogSink: AnyObject {
    func archive(_ items: [SyncRecoveryItem], accountID: String?) throws
}

/// Keeps the lines in memory — the engine tests' sink, where a line is easier to assert on than
/// a file. Never the app's: its lines are gone when the process exits, and the spec's promise is
/// that the edit survives ("on disk before the delete"). `failure` makes the next appends throw,
/// as a full disk would; StrideTests also drive the real file log into an unwritable directory.
@MainActor
final class SyncMemoryRecoveryLog: SyncRecoveryLogSink {
    struct Line: Equatable {
        var item: SyncRecoveryItem
        var accountID: String?
    }

    private(set) var lines: [Line] = []
    var failure: Error?

    init() {}

    func archive(_ items: [SyncRecoveryItem], accountID: String?) throws {
        if let failure { throw failure }
        lines += items.map { Line(item: $0, accountID: accountID) }
    }
}

// MARK: - Outcome

struct SyncRunOptions: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// Settings → Full resync: every row `needsResend`, a pull on the current cursor, the push,
    /// then the cursor cleared so the next sync full-pulls against the repaired server
    /// ("Forced resend waits until deletions are settled").
    static let fullResync = SyncRunOptions(rawValue: 1 << 0)
}

/// One request the run made — what the rehearsal counts ("each push carried only the changed
/// rows: count rows and bytes").
struct SyncRequestRecord: Equatable {
    var endpoint: SyncEndpoint
    var status: Int?
    var code: String?
    /// Push: the body's bytes. Pull: the response's bytes.
    var bytes: Int
    /// Push: rows sent. Pull: rows received.
    var rows = SyncRowCounts()
    var deletions = 0
    /// Pull only: whether it was a full pull.
    var fullPull = false
}

struct SyncRunSummary: Equatable {
    var requests: [SyncRequestRecord] = []
    var acknowledged = 0
    var held: [SyncPlannedHold] = []
    var dropped = 0
    var archived = 0
    var deletionsDelivered = 0
    var heldTombstoned: [SyncRowRef] = []
    /// Delivered rows a full pull lacked that its pass kept for the push to resend, because the
    /// migrated delivery marks were unverified (review data-safety-1).
    var markedForResend = SyncRowCounts()
    var pullIssues: [SyncPullIssue] = []
    var deletionPassSkipped = false
    /// What a proving full pull decided about the store's migrated delivery marks
    /// (`SyncMarksProof`); nil when no pull in the run was asked to.
    var marks: SyncMarksVerdict?
    /// The last pull's `serverTime`.
    var serverTime: String?

    var pushes: [SyncRequestRecord] { requests.filter { $0.endpoint == .push } }
    var pulls: [SyncRequestRecord] { requests.filter { $0.endpoint == .pull } }
    var pushedRows: SyncRowCounts {
        pushes.reduce(into: SyncRowCounts()) { acc, r in
            acc.groups += r.rows.groups; acc.habits += r.rows.habits; acc.entries += r.rows.entries
        }
    }
}

enum SyncBlockReason: Equatable {
    case alreadyRunning
    case signedOut
    case ownerUnsettled
    /// An automatic run inside the owner's backoff window (`SyncBackoffStore`): the server said
    /// to wait, or the last runs failed. Nothing was sent. A manual run is never blocked by it.
    case backingOff(SyncBackoffState)
}

enum SyncStopReason: Equatable {
    /// The owner, token or generation changed during the run (1.3.0's `SignedOutDuringSync`):
    /// the session this run served is gone, on purpose. Nothing after the change was
    /// acknowledged, deleted, reconciled or written. Not an error to show.
    case bindingChanged
    /// 401: `needsReauth`. No state was reset — re-login to the same account resumes.
    case needsReauth
    /// 426: this build is below the server's floor.
    case upgradeRequired
    /// Rows stay pending, nothing was held for it; the wrapper schedules the retry
    /// (`SyncBackoffPolicy`). `answer` is what the server said, for the report and the footer.
    case backOff(SyncBackoffKind, answer: SyncHTTPAnswer)
    /// The recovery log could not be written: nothing was deleted, no cursor was written.
    case recoveryLogFailed
    /// The store refused a fetch or a save.
    case localFailure(String)
}

enum SyncRunOutcome: Equatable {
    /// Pushed (as much as was pending) and pulled; the cursor was written.
    case synced(SyncRunSummary)
    /// Nothing was sent.
    case blocked(SyncBlockReason)
    /// Stopped part way; what finished before the stop (earlier chunks, an earlier pull) stays
    /// done — each step saved on its own.
    case stopped(SyncStopReason, SyncRunSummary)

    var summary: SyncRunSummary? {
        switch self {
        case .synced(let s), .stopped(_, let s): return s
        case .blocked: return nil
        }
    }
}

// MARK: - Engine

@MainActor
final class SyncEngine {
    /// The server's `CURSOR_RETENTION_DAYS` less its `CURSOR_GRACE_DAYS` (routes/sync.js): a
    /// cursor older than this is cleared locally and the run full-pulls first, the same as a
    /// `409 cursor_expired`. This handler is what makes 1.3.1 the lowest version a 426 floor can
    /// allow once tombstones are swept again.
    static let cursorLifetime: TimeInterval = (365 - 10) * 86_400

    /// A cursor older than this, though still inside `cursorLifetime` by this device's clock, is
    /// pulled on BEFORE the push, so a server that already counts it expired (this clock runs
    /// slow, or the retention constant moved) answers `409 cursor_expired` while nothing has gone
    /// up yet: the spec's order for that answer is "full pull first, then push". Pushed first, the
    /// run sent its pending edits on the expired cursor and learnt of the expiry only on the pull
    /// after — once tombstones are swept, that push re-inserts a delivered row another device
    /// deleted, the resurrection the full-pull-first rule exists to prevent (M2 slice review).
    /// 30 days covers any plausible clock error; cursors this old are rare, so the extra pull
    /// costs nothing in practice.
    static let cursorProbeAge: TimeInterval = cursorLifetime - 30 * 86_400

    /// Rounds of push + pull one run may make. The second exists for a `snapshot_required` that
    /// arrives after the push went up (on the post-push pull, or on a push): the resend must go
    /// up after a pull on a live cursor, in the same run.
    static let maxRounds = 2

    let transport: any SyncTransport
    let gate: any SyncRunGate
    let cursorStore: any SyncCursorStore
    let deletionQueue: SyncDeletionQueue
    let strikes: SyncUnknownHabitStrikes
    /// Whether the store's delivery marks still wait for the first full pull to prove them.
    let marks: SyncMarksProof
    let recoveryLog: any SyncRecoveryLogSink
    /// The per-owner backoff (M2 answer table: `invalid_payload`, 429, 503, other 5xx, no
    /// answer). nil = no backoff at all (most engine tests): every run goes.
    let backoff: SyncBackoffStore?
    /// Sentry, in the app: ids, reason codes and counts only (`SyncDiagnosticReport`).
    let report: (SyncDiagnosticReport) -> Void
    let bounds: SyncPushBounds
    let now: () -> Date

    private(set) var isRunning = false

    init(
        transport: any SyncTransport,
        gate: any SyncRunGate,
        cursorStore: any SyncCursorStore,
        deletionQueue: SyncDeletionQueue,
        strikes: SyncUnknownHabitStrikes,
        marks: SyncMarksProof,
        recoveryLog: any SyncRecoveryLogSink,
        backoff: SyncBackoffStore? = nil,
        report: @escaping (SyncDiagnosticReport) -> Void = { _ in },
        bounds: SyncPushBounds = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.gate = gate
        self.cursorStore = cursorStore
        self.deletionQueue = deletionQueue
        self.strikes = strikes
        self.marks = marks
        self.recoveryLog = recoveryLog
        self.backoff = backoff
        self.report = report
        self.bounds = bounds
        self.now = now
    }

    /// One sync run: (pull first when needed) → push chunk by chunk → pull → cursor.
    ///
    /// - The run captures the gate's binding and re-checks it before every request and after
    ///   every await, before any acknowledgement, deletion-queue change, reconcile or cursor
    ///   write. A mismatch ends it as `.bindingChanged`, acknowledging nothing more.
    /// - While the store's delivery marks are unproven (`SyncMarksProof`), it starts with a FULL
    ///   pull whatever the cursor, and that pull decides them before its deletion pass: nothing
    ///   is pushed, and nothing deleted by absence, before the account is proven. A proving pull
    ///   that cannot decide (its totals do not match) applies nothing, and the run ends there,
    ///   before any push (review data-safety-2). Until a full pull's pass has run after the
    ///   proof, that pass resends what it would have deleted (review data-safety-1).
    /// - It pulls BEFORE pushing when there is no cursor, when the cursor is older than
    ///   `cursorLifetime` (cleared: a full pull) or `cursorProbeAge` (so the server's
    ///   `cursor_expired` comes before the push), or when any row waits on a forced resend: the
    ///   resend goes up only
    ///   after a pull on a live cursor has settled deletions, and without a cursor the full pull
    ///   removes delivered-but-absent rows (archived) before anything is pushed.
    /// - Chunks go in sequence and the run stops at the first one that fails; later chunks do not
    ///   run, and the retry resumes there (the acknowledged ones are no longer pending).
    /// - An `.automatic` run waits out the owner's backoff window (`.blocked(.backingOff)`, no
    ///   request); a `.manual` one goes at once ("Sync Now retries at once"). Either way the
    ///   outcome is written to the backoff under the owner the run was BOUND to: a run that ends
    ///   after a switch to another account must not leave its failure (or its success) on that
    ///   account, which is why this is here and not in the wrapper, which only knows who is
    ///   signed in by the time the run returns.
    func run(in context: ModelContext, options: SyncRunOptions = [],
             trigger: SyncBackoffTrigger = .manual) async -> SyncRunOutcome {
        guard !isRunning else { return .blocked(.alreadyRunning) }
        let binding: SyncRunBinding
        switch gate.current() {
        case .ready(let b): binding = b
        case .signedOut: return .blocked(.signedOut)
        case .ownerUnsettled: return .blocked(.ownerUnsettled)
        }
        if let backoff, case .wait(let state) = backoff.decision(for: trigger, ownerID: binding.ownerID) {
            return .blocked(.backingOff(state))
        }
        isRunning = true
        defer { isRunning = false }

        let run = SyncRun(engine: self, context: context, binding: binding)
        let outcome: SyncRunOutcome
        do {
            try await run.execute(options)
            outcome = .synced(run.summary)
        } catch let stop as SyncRunStop {
            outcome = .stopped(stop.reason, run.summary)
        } catch {
            context.rollback()
            outcome = .stopped(.localFailure(String(describing: error)), run.summary)
        }
        // Success resets; a back-off stop adds a failure; anything else (a reauth, a sign-out
        // mid-run, a local failure) leaves the window as it was (`SyncBackoffStore.record`).
        backoff?.record(outcome, for: binding.ownerID)
        return outcome
    }

    /// Whether `cursor` is too old to trust (or unreadable): the run full-pulls instead.
    func cursorIsExpired(_ cursor: String) -> Bool {
        guard let date = SyncTimestamp.parse(cursor) else { return true }
        return now().timeIntervalSince(date) > Self.cursorLifetime
    }

    /// Whether `cursor` is old enough that the server may count it expired already: the run
    /// pulls on it before pushing (`cursorProbeAge`).
    func cursorNearsExpiry(_ cursor: String) -> Bool {
        guard let date = SyncTimestamp.parse(cursor) else { return true }
        return now().timeIntervalSince(date) > Self.cursorProbeAge
    }

    /// Forced resend: every row `needsResend`, `syncedAt` and holds untouched (a held row is
    /// still not sent). Does not save.
    static func markEveryRowNeedsResend(in context: ModelContext) throws {
        try context.fetch(FetchDescriptor<HabitGroup>()).forEach { $0.markNeedsResend() }
        try context.fetch(FetchDescriptor<Habit>()).forEach { $0.markNeedsResend() }
        try context.fetch(FetchDescriptor<HabitRecord>()).forEach { $0.markNeedsResend() }
    }
}

/// Thrown inside a run to end it with a reason.
private struct SyncRunStop: Error {
    let reason: SyncStopReason
}

/// The state of one run. A class so the async steps share it without inout across awaits.
@MainActor
private final class SyncRun {
    unowned let engine: SyncEngine
    let context: ModelContext
    let binding: SyncRunBinding
    var summary = SyncRunSummary()

    /// `snapshot_required` is one-shot on the server; a second one in the same run is not a
    /// repair request this run can honour.
    private var snapshotHandled = false
    /// Set when a snapshot request marked every row after the current push began: the resend
    /// still has to go up, after the pull that follows.
    private var resendAwaitingPush = false

    // Plain decoders on purpose: APIClient's `.convertFromSnakeCase` is a no-op on this API's
    // camelCase keys, but it would also rewrite the id keys of `skippedReasons` if one ever held
    // an underscore.
    private let decoder = JSONDecoder()

    init(engine: SyncEngine, context: ModelContext, binding: SyncRunBinding) {
        self.engine = engine
        self.context = context
        self.binding = binding
    }

    // MARK: Order

    func execute(_ options: SyncRunOptions) async throws {
        try check()
        if options.contains(.fullResync) {
            try SyncEngine.markEveryRowNeedsResend(in: context)
            try save()
        }

        var cursor = engine.cursorStore.cursor(for: binding.ownerID)
        if let c = cursor, engine.cursorIsExpired(c) {
            // Cleared locally, exactly as a 409 cursor_expired: a full pull first, then push.
            try check()
            engine.cursorStore.setCursor(nil, for: binding.ownerID)
            cursor = nil
        }

        if engine.marks.isAwaited {
            // Not cleared in the store: the proving pull writes the next cursor, and a run that
            // stops before it comes back here. The first run after adoption has no cursor anyway;
            // this also covers an owner that had one (a store adopted, erased empty, re-adopted).
            cursor = nil
        }

        let forcedResend = try SyncPushPlanner.hasForcedResend(in: context)
        let nearsExpiry = cursor.map(engine.cursorNearsExpiry) ?? false
        if cursor == nil || forcedResend || nearsExpiry {
            cursor = try await pull(since: cursor)
        }

        var round = 0
        while true {
            round += 1
            resendAwaitingPush = false
            let pushEnd = try await push()
            if pushEnd == .cursorExpired {
                try check()
                engine.cursorStore.setCursor(nil, for: binding.ownerID)
                cursor = nil
            }
            cursor = try await pull(since: cursor)
            let again = pushEnd != .done || resendAwaitingPush
            if !again || round >= SyncEngine.maxRounds { break }
        }

        if options.contains(.fullResync) {
            try check()
            engine.cursorStore.setCursor(nil, for: binding.ownerID)
        }
    }

    // MARK: Binding

    /// Ends the run unless the gate still answers with the binding it started with.
    private func check() throws {
        guard engine.gate.current() == .ready(binding) else {
            throw SyncRunStop(reason: .bindingChanged)
        }
    }

    private func save() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw SyncRunStop(reason: .localFailure(String(describing: error)))
        }
    }

    private func answer(_ response: SyncTransportResponse) -> SyncHTTPAnswer {
        guard let status = response.status else { return .noAnswer }
        return SyncHTTPAnswer.decode(status: status, body: response.body, retryAfterHeader: response.retryAfter)
    }

    private func stop(_ action: SyncAnswerAction, _ answer: SyncHTTPAnswer) -> SyncRunStop {
        switch action {
        case .reauth: return SyncRunStop(reason: .needsReauth)
        case .upgradeRequired: return SyncRunStop(reason: .upgradeRequired)
        case .backOff(let kind): return SyncRunStop(reason: .backOff(kind, answer: answer))
        default: return SyncRunStop(reason: .backOff(.clientBug, answer: answer))
        }
    }

    /// `snapshot_required`, from a push or a pull: support's repair. Every row `needsResend`
    /// (`syncedAt` and holds untouched); the resend goes up after the next pull.
    private func takeSnapshotRequest(_ answer: SyncHTTPAnswer) throws {
        guard !snapshotHandled else {
            throw SyncRunStop(reason: .backOff(.transient, answer: answer))
        }
        snapshotHandled = true
        try check()
        try SyncEngine.markEveryRowNeedsResend(in: context)
        try save()
        resendAwaitingPush = true
    }

    // MARK: Pull

    /// One pull, applied; returns the new cursor (already stored). On `cursor_expired` it drops
    /// the cursor and full-pulls; on `snapshot_required` it marks every row and pulls again.
    private func pull(since initial: String?) async throws -> String? {
        var since = initial
        while true {
            try check()
            let response = await engine.transport.pull(since: since, token: binding.token)
            try check()
            let answer = answer(response)
            var record = SyncRequestRecord(endpoint: .pull, status: answer.status, code: answer.code,
                                           bytes: response.body.count, fullPull: since == nil)

            let action = SyncAnswers.action(for: answer, endpoint: .pull)
            switch action {
            case .proceed:
                guard let pulled = try? decoder.decode(SyncPullResponse.self, from: response.body) else {
                    summary.requests.append(record)
                    // A 200 we cannot read (a proxy's page, a truncated body): nothing applied.
                    throw SyncRunStop(reason: .backOff(.transient, answer: answer))
                }
                record.rows = SyncRowCounts(groups: pulled.groups?.count ?? 0, habits: pulled.habits.count,
                                            entries: pulled.entries.count)
                record.deletions = (pulled.deletedHabitIds?.count ?? 0) + (pulled.deletedEntryIds?.count ?? 0)
                    + (pulled.deletedGroupIds?.count ?? 0)
                summary.requests.append(record)
                try check()
                let reconciled: SyncReconcileReport
                let proving = since == nil && engine.marks.isAwaited
                let verifying = since == nil && engine.marks.isUnverified
                do {
                    // Read now, not at the run's start: the push before this pull acknowledged
                    // what it delivered, and whatever is still queued must not come back.
                    reconciled = try SyncReconciler.apply(pulled, to: context, isFullPull: since == nil,
                                                          proveMarks: proving, marksUnverified: verifying,
                                                          queuedDeletions: engine.deletionQueue.pending(),
                                                          recoveryLog: engine.recoveryLog,
                                                          accountID: binding.ownerID, now: engine.now())
                } catch SyncReconcileError.recoveryLogFailed {
                    throw SyncRunStop(reason: .recoveryLogFailed)
                } catch {
                    throw SyncRunStop(reason: .localFailure(String(describing: error)))
                }
                if proving, let verdict = reconciled.marks {
                    summary.marks = verdict
                    // Only once the decision is saved (the reconcile saved or threw): a flag
                    // cleared ahead of a rolled-back forget would let the next full pull delete by
                    // marks nobody proved. Settled even if the gate changes next — the store is
                    // what it is. Undecided stays awaited: the next run full-pulls again. Forgotten
                    // leaves no mark to verify either.
                    switch verdict {
                    case .proven: engine.marks.markProven()
                    case .forgotten: engine.marks.settle()
                    case .undecided: break
                    }
                }
                // The pass that resent what the marks could not vouch for has run and is saved:
                // from here a delivered row the account lacks was deleted elsewhere (review
                // data-safety-1). Never before the proof: an undecided pull runs no pass.
                if verifying, reconciled.deletionPassRan { engine.marks.markVerified() }
                summary.archived += reconciled.archived
                summary.heldTombstoned += reconciled.heldTombstoned
                summary.markedForResend += reconciled.markedForResend
                summary.pullIssues += reconciled.issues
                if reconciled.deletionPassSkipped { summary.deletionPassSkipped = true }
                if let diagnostic = reconciled.diagnostic { engine.report(diagnostic) }
                if proving, reconciled.marks == .undecided {
                    // It applied nothing (review data-safety-2), and the run ends before its push:
                    // a row acknowledged into this account would be taken for proof by the next
                    // proving pull as surely as a row this one inserted. No cursor either, as
                    // nothing was applied up to it. Backed off like a 200 whose body cannot be read.
                    throw SyncRunStop(reason: .backOff(.transient, answer: answer))
                }
                summary.serverTime = pulled.serverTime

                try check()
                // As 1.2.3: the server's clock less the overlap; an unreadable serverTime means a
                // full pull next time rather than a cursor from this device's clock.
                let next = SyncCursor.next(afterServerTime: pulled.serverTime)
                engine.cursorStore.setCursor(next, for: binding.ownerID)
                return next

            case .fullPull:
                summary.requests.append(record)
                // cursor_expired (or a `since` the server cannot read): drop it, full pull.
                guard since != nil else { throw stop(.backOff(.clientBug), answer) }
                try check()
                engine.cursorStore.setCursor(nil, for: binding.ownerID)
                since = nil

            case .forcedResend:
                summary.requests.append(record)
                try takeSnapshotRequest(answer)
                // The flag is one-shot on the server: the same cursor now answers 200.

            default:
                summary.requests.append(record)
                if action.reportsToSentry {
                    engine.report(SyncDiagnosticReport(event: "pull_answer", code: answer.code, status: answer.status))
                }
                throw stop(action, answer)
            }
        }
    }

    // MARK: Push

    private enum PushEnd: Equatable {
        case done
        /// `snapshot_required` on a push: every row was marked; pull (live cursor), then resend.
        case snapshotRequested
        /// A push answered `cursor_expired` (the server does not, today): full pull, then push.
        case cursorExpired
    }

    private func push() async throws -> PushEnd {
        try check()
        let plan: SyncPushPlan
        do {
            plan = try SyncPushPlanner.plan(in: context, deletions: engine.deletionQueue.pending(), bounds: engine.bounds)
        } catch {
            throw SyncRunStop(reason: .localFailure(String(describing: error)))
        }
        try applyHolds(plan.holds)

        var chunks = plan.chunks
        var attempts = SyncRunAttempts()
        var bounds = engine.bounds
        var index = 0
        while index < chunks.count {
            let chunk = chunks[index]
            try check()
            let response = await engine.transport.push(body: chunk.body, token: binding.token)
            try check()
            let answer = answer(response)
            summary.requests.append(SyncRequestRecord(
                endpoint: .push, status: answer.status, code: answer.code, bytes: chunk.body.count,
                rows: SyncRowCounts(groups: chunk.payload.groups.count, habits: chunk.payload.habits.count,
                                    entries: chunk.payload.entries.count),
                deletions: chunk.deletionCount))

            let action = SyncAnswers.action(for: answer, endpoint: .push, chunk: chunk.shape, attempts: attempts)
            if action.reportsToSentry { engine.report(chunk.diagnostic(for: answer)) }
            switch action {
            case .proceed:
                guard let pushed = try? decoder.decode(SyncPushResponse.self, from: response.body) else {
                    // The server may have written rows; without the answer none can be
                    // acknowledged. They stay pending and are re-sent (LWW makes that harmless).
                    throw SyncRunStop(reason: .backOff(.transient, answer: answer))
                }
                try check()
                try resolve(chunk, pushed)
                index += 1

            case .holdTooLarge:
                try check()
                let holds = try SyncPushResolver.holdTooLarge(chunk, in: context)
                try save()
                reportHolds(holds)
                summary.held += holds
                index += 1

            case .rechunk(let limits):
                attempts.rechunkedForRows = true
                bounds = bounds.clamped(to: limits)
                chunks = try repack(chunks, from: index, bounds: bounds)

            case .rechunkAtHalfBytes:
                attempts.halvedBytes = true
                bounds = bounds.halvingBytes()
                chunks = try repack(chunks, from: index, bounds: bounds)

            case .forcedResend:
                try takeSnapshotRequest(answer)
                return .snapshotRequested

            case .fullPull:
                return .cursorExpired

            case .reauth, .upgradeRequired, .backOff:
                throw stop(action, answer)
            }
        }
        return .done
    }

    /// Chunks before `index` are answered; the rest are re-planned under `bounds`, in order,
    /// with the stamps they were first planned at.
    private func repack(_ chunks: [SyncPushChunk], from index: Int, bounds: SyncPushBounds) throws -> [SyncPushChunk] {
        let repacked: SyncPushPlan
        do {
            repacked = try SyncPushPlanner.repack(chunks[index...], bounds: bounds)
        } catch {
            throw SyncRunStop(reason: .localFailure(String(describing: error)))
        }
        try applyHolds(repacked.holds)
        return Array(chunks[..<index]) + repacked.chunks
    }

    private func applyHolds(_ holds: [SyncPlannedHold]) throws {
        guard !holds.isEmpty else { return }
        try check()
        do {
            try SyncPushResolver.apply(holds, in: context)
        } catch {
            throw SyncRunStop(reason: .localFailure(String(describing: error)))
        }
        try save()
        reportHolds(holds)
        summary.held += holds
    }

    private func reportHolds(_ holds: [SyncPlannedHold]) {
        let reported = holds.filter(\.reason.reportsToSentry)
        guard !reported.isEmpty else { return }
        engine.report(.held(reported.map { (id: $0.ref.id, reason: $0.reason) }))
    }

    /// A chunk's 200: acknowledgements, holds, strikes, the deletion queue — then the drops,
    /// archived before they are deleted — then one save for the chunk.
    private func resolve(_ chunk: SyncPushChunk, _ response: SyncPushResponse) throws {
        let outcome: SyncChunkOutcome
        do {
            outcome = try SyncPushResolver.resolve(chunk, response: response, in: context,
                                                   deletionQueue: engine.deletionQueue, strikes: engine.strikes)
        } catch {
            context.rollback()
            throw SyncRunStop(reason: .localFailure(String(describing: error)))
        }

        var removal = SyncLocalRemoval(reason: .tombstoned, archivedAt: engine.now())
        if !outcome.drops.isEmpty {
            do {
                try collectDrops(outcome.drops, into: &removal)
            } catch {
                context.rollback()
                throw SyncRunStop(reason: .localFailure(String(describing: error)))
            }
        }

        var archiveFailed = false
        if !removal.archive.isEmpty {
            do {
                try engine.recoveryLog.archive(removal.archive, accountID: binding.ownerID)
            } catch {
                // Delete nothing. The acknowledgements are still true (the server wrote those
                // rows), so they are saved; the dropped rows stay pending, are answered
                // `tombstoned` again next sync, and the archive is retried then.
                archiveFailed = true
            }
        }
        if !archiveFailed {
            removal.commit(in: context)
            summary.dropped += removal.deleted.total
            summary.archived += removal.archive.count
            summary.heldTombstoned += removal.heldTombstoned
        }
        try save()

        summary.acknowledged += outcome.acknowledged.count
        summary.held += outcome.holds
        summary.deletionsDelivered += outcome.deliveredDeletions.count
        reportHolds(outcome.holds)
        if !outcome.unrecognisedReasons.isEmpty {
            var reasons: [String: String] = [:]
            for (ref, reason) in outcome.unrecognisedReasons { reasons[ref.id] = reason.isEmpty ? "none" : reason }
            engine.report(SyncDiagnosticReport(event: "push_unknown_reason", code: nil, status: 200,
                                               counts: ["rows": reasons.count], reasons: reasons))
        }
        if archiveFailed { throw SyncRunStop(reason: .recoveryLogFailed) }
    }

    /// The local rows a chunk's `tombstoned` answers name. A habit's pending and held records go
    /// to the log with it, one by one; a restored row is held instead (`SyncLocalRemoval`).
    private func collectDrops(_ drops: [SyncRowRef], into removal: inout SyncLocalRemoval) throws {
        let wanted = Set(drops)
        let kinds = Set(drops.map(\.kind))
        if kinds.contains(.group) {
            for group in try context.fetch(FetchDescriptor<HabitGroup>())
            where wanted.contains(SyncRowRef(kind: .group, id: group.id.uuidString)) {
                removal.removeGroup(group)
            }
        }
        if kinds.contains(.habit) || kinds.contains(.entry) {
            // Records are reached through their habits: `HabitRecord` has no inverse, and the
            // archived line names the habit. The dropped ones are fetched by id first and then
            // recognised by identifier, so the walk reads no other record's fields — a store whose
            // every row comes back `tombstoned` (the migrated-marks residual) drops in every chunk.
            let entryIDs = drops.filter { $0.kind == .entry }.compactMap { UUID(uuidString: $0.id) }
            let droppedRecords = entryIDs.isEmpty ? Set<PersistentIdentifier>() : Set(try context.fetch(
                FetchDescriptor<HabitRecord>(predicate: #Predicate { entryIDs.contains($0.id) })).map(\.persistentModelID))
            for habit in try context.fetch(FetchDescriptor<Habit>()) {
                if wanted.contains(SyncRowRef(kind: .habit, id: habit.id.uuidString)) {
                    removal.removeHabit(habit)
                    continue
                }
                guard !droppedRecords.isEmpty else { continue }
                for record in habit.records where droppedRecords.contains(record.persistentModelID) {
                    removal.removeRecord(record, of: habit)
                }
            }
        }
    }
}

// MARK: - The owner (account isolation)

// Here rather than in the app's SyncService (where phase B kept it) so that one rule serves the
// app, StrideTests and scripts/sync_rehearsal.sh: the rehearsal drives the account screen's
// choices at the engine level — it has no UI — and must run the code the app runs, not a copy of
// it (DEV-PLAN-1.3.md M2, "Account isolation"; Acceptance (5)). `SyncService` keeps what needs the
// app: the session source, the UI state (`ownerConflict`), and the sync that follows a choice.

/// A server account: `APIUser.id` as a string (the owner key everywhere sync stores per-account
/// state) and its email, for display.
struct SyncAccount: Equatable, Sendable {
    var id: String
    var email: String

    init(id: String, email: String) {
        self.id = id
        self.email = email
    }
}

/// The account whose data this store holds (M2 account isolation). Its id is the key of the
/// per-owner cursor (`SyncDefaultsCursorStore`); the email is for the account screen.
struct SyncOwner: Equatable, Sendable {
    var id: String
    var email: String

    init(_ account: SyncAccount) {
        id = account.id
        email = account.email
    }
}

/// Signed in as `signedIn` on a store that holds something to lose and is not that account's:
/// the account screen's question. No sync runs until it is answered.
struct SyncOwnerConflict: Equatable, Identifiable, Sendable {
    /// The store's owner. nil = **owner unknown**: a device that reached 1.3.1 signed out with
    /// rows (`SyncOwnerStore.ownerUnknown`) — 1.3.0 recorded no account, so they may be a
    /// previous account's or nobody's, and the screen offers "Upload these habits to this
    /// account" as well as "Start from this account's data" (sub-decision (e)).
    var owner: SyncOwner?
    var signedIn: SyncAccount

    var isOwnerUnknown: Bool { owner == nil }
    /// For `.sheet(item:)`: one screen per (owner, account) pair.
    var id: String { "\(owner?.id ?? "-")→\(signedIn.id)" }
}

/// The owner record, in the same defaults as the cursors (`UserDefaults.standard` in the app).
struct SyncOwnerStore {
    static let ownerKey = "stride_sync_owner"
    /// Set once, at the first 1.3.1 launch, when the device was signed out with rows and no
    /// owner: 1.3.0 records no account and clears its cursor on sign-out, so those rows may be a
    /// previous account's or nobody's (M2, "Owner unknown").
    static let ownerUnknownKey = "stride_sync_owner_unknown"
    static let firstLaunchNotedKey = "stride_sync_owner_first_launch_noted"
    /// The first 1.3.1 launch found rows, no owner and a stored session token — which is not yet
    /// evidence of being signed in: a 1.2.3 device keeps a dead token (only 1.3.0 started
    /// deleting them), and a device that auto-updated while dormant still holds the one that
    /// expired meanwhile. Settled by the first answer about that token
    /// (`storedSessionConfirmed(account:)` / `storedSessionEnded`).
    static let ownerUnknownPendingKey = "stride_sync_owner_unknown_pending"

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
        defaults.removeObject(forKey: Self.ownerUnknownPendingKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.ownerUnknownKey)
        defaults.removeObject(forKey: Self.ownerUnknownPendingKey)
    }

    /// Once per install, at the first 1.3.1 launch: a store with rows and no owner is owner-unknown
    /// if the device is signed out (M2, "Owner unknown"). With a session token stored it is
    /// signed in only if that token is still alive, which the launch check has not answered yet,
    /// so the question waits for it (`ownerUnknownPendingKey`). Deciding on "a token is stored"
    /// let a dead token skip the account screen: the check deleted it, the device was signed out
    /// with rows, no owner and no flag, and the next account signed into adopted the rows silently
    /// and received the previous account's never-pushed habits (phase C review, F1).
    func noteFirstLaunch(hasStoredSession: Bool, hasRows: Bool) {
        guard !defaults.bool(forKey: Self.firstLaunchNotedKey) else { return }
        defaults.set(true, forKey: Self.firstLaunchNotedKey)
        guard owner == nil, hasRows else { return }
        defaults.set(true, forKey: hasStoredSession ? Self.ownerUnknownPendingKey : Self.ownerUnknownKey)
    }

    /// The server named the stored token's user: the device was signed in at its first 1.3.1
    /// launch, so that account owns the store from this answer on (M2: "A device signed in at its
    /// first 1.3.1 launch takes that account as owner"). Its marks still wait for the proof — a
    /// live token is not evidence that its account is the one the marks were inferred for — so
    /// `SyncMarksProof` stays awaited, and the owner's first sync full-pulls.
    ///
    /// Recorded now, not left to that account's first sync (review accounts-1): the answer can
    /// come with no sync after it — a login link's recheck of a token whose launch check failed —
    /// and a Log Out in that gap left rows with no owner and no owner-unknown flag, which the next
    /// account signed into adopted without the account screen, uploading the ones this account
    /// never pushed. Does nothing unless the first launch left the question open.
    func storedSessionConfirmed(account: SyncAccount) {
        guard defaults.bool(forKey: Self.ownerUnknownPendingKey) else { return }
        defaults.removeObject(forKey: Self.ownerUnknownPendingKey)
        guard owner == nil else { return }
        set(SyncOwner(account))
    }

    /// The stored token turned out dead (`{user: null}`), or a new sign-in replaced it before the
    /// server ever named its user: the device reached 1.3.1 signed out after all. Rows that are
    /// still ownerless are owner-unknown, and the next sign-in asks (sub-decision (e)). Does
    /// nothing unless the first launch left the question open.
    func storedSessionEnded() {
        guard defaults.bool(forKey: Self.ownerUnknownPendingKey) else { return }
        defaults.removeObject(forKey: Self.ownerUnknownPendingKey)
        guard owner == nil else { return }
        defaults.set(true, forKey: Self.ownerUnknownKey)
    }
}

/// What "Start from this account's data" would take from the device: its rows, the deletions
/// queued for the owner, and the owner's recovery-log lines. The account screen lists it.
struct SyncOwnerHoldings: Equatable, Sendable {
    var habits = 0
    var checkIns = 0
    var groups = 0
    var queuedDeletions = 0
    /// nil when the log could not be read — which counts as something to lose: asking once too
    /// often is cheap, clearing lines nobody saw is not.
    var recoveredEdits: Int? = 0

    var isEmpty: Bool {
        habits == 0 && checkIns == 0 && groups == 0 && queuedDeletions == 0 && recoveredEdits == 0
    }
}

enum SyncOwnershipError: Error, Equatable {
    /// "Upload these habits" asked for a store whose owner is known.
    case uploadNeedsUnknownOwner
}

/// What a sign-in finds, decided before any request (`SyncOwnership.decide`).
enum SyncSignInDecision: Equatable, Sendable {
    /// The owner signed in again: the cursor, the queue and every row's delivery state resume,
    /// and nothing is re-uploaded (M2, "Same account again").
    case resume
    /// No owner, nothing unknown about the rows (a fresh install, an erased store, or an
    /// owner-unknown store emptied since): the account adopts the store (M2, "No owner").
    case adopt
    /// Another account's store with nothing to lose: it changes hands silently.
    case switchSilently(from: SyncOwner)
    /// The account screen: another account's rows (or rows of unknown origin) are here.
    case choose(SyncOwnerConflict)
}

/// The owner rule and the account screen's operations, over the stores a device keeps: the owner
/// record, the per-owner cursors and backoff, the deletion queue, the `unknown_habit` strikes,
/// the marks proof (all in `defaults`) and the recovery-log file.
///
/// Every operation that moves the store to another account clears what was true only for the
/// previous one — an acknowledgement, a cursor, a queued deletion and a server's "wait" are true
/// only for the account that gave them — and none merges one account's rows into another.
@MainActor
struct SyncOwnership {
    let defaults: UserDefaults
    let deletionQueue: SyncDeletionQueue
    let recoveryLog: SyncRecoveryLog

    var owners: SyncOwnerStore { SyncOwnerStore(defaults: defaults) }
    private var cursors: SyncDefaultsCursorStore { SyncDefaultsCursorStore(defaults: defaults) }

    /// What the device holds for `owner` (nil = the unknown owner). A store that cannot be counted
    /// reports a habit, so it is never taken for empty.
    func holdings(owner: SyncOwner?, in context: ModelContext) -> SyncOwnerHoldings {
        var h = SyncOwnerHoldings()
        h.queuedDeletions = deletionQueue.pending().count
        h.recoveredEdits = try? recoveryLog.lineCount(accountID: owner?.id)
        do {
            h.habits = try context.fetchCount(FetchDescriptor<Habit>())
            h.checkIns = try context.fetchCount(FetchDescriptor<HabitRecord>())
            h.groups = try context.fetchCount(FetchDescriptor<HabitGroup>())
        } catch {
            h.habits = max(h.habits, 1)
        }
        return h
    }

    /// The owner rule, for `account` signed in now. Changes nothing (`settle` applies it).
    ///
    /// - The owner signed in → resume.
    /// - No owner → adopt, unless the store is owner-unknown and still holds something: then the
    ///   screen offers Upload and Start (sub-decision (e)). A store adopted without the screen
    ///   keeps its migrated marks only provisionally — the first full pull proves or forgets them
    ///   (`SyncMarksProof`).
    /// - Another owner, nothing to lose → switch silently; something to lose → the screen.
    func decide(for account: SyncAccount, in context: ModelContext) -> SyncSignInDecision {
        guard let owner = owners.owner else {
            if owners.ownerUnknown, !holdings(owner: nil, in: context).isEmpty {
                return .choose(SyncOwnerConflict(owner: nil, signedIn: account))
            }
            return .adopt
        }
        if owner.id == account.id { return .resume }
        if holdings(owner: owner, in: context).isEmpty { return .switchSilently(from: owner) }
        return .choose(SyncOwnerConflict(owner: owner, signedIn: account))
    }

    /// Applies `decide`: returns the conflict when the user must choose (nothing changed), nil
    /// when `account` owns the store now.
    @discardableResult
    func settle(for account: SyncAccount, in context: ModelContext) -> SyncOwnerConflict? {
        switch decide(for: account, in: context) {
        case .resume:
            // The email can change server-side; the screen shows the current one.
            if owners.owner?.email != account.email { owners.set(SyncOwner(account)) }
            return nil
        case .adopt:
            owners.set(SyncOwner(account))
            return nil
        case .switchSilently(let previous):
            // What "Start from this account's data" clears, minus the rows (there are none) and
            // the recovery log (it has no lines, or this would be a conflict).
            handOver(to: SyncOwner(account), from: previous)
            return nil
        case .choose(let conflict):
            return conflict
        }
    }

    /// The store changes hands while it holds nothing of `previous`'s (it is empty, or was just
    /// erased or restored into): what belonged to `previous` goes — its queued deletions, the
    /// `unknown_habit` strikes, its backoff and its cursor — and `next` becomes the owner.
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
    func handOver(to next: SyncOwner?, from previous: SyncOwner?) {
        if let previous, previous.id != next?.id {
            deletionQueue.clearAll()
            SyncUnknownHabitStrikes(defaults: defaults).clearAll()
            SyncBackoffStore(defaults: defaults).clear(for: previous.id)
            cursors.setCursor(nil, for: previous.id)
            if let next { cursors.setCursor(nil, for: next.id) }
        }
        if let next { owners.set(next) } else { owners.clear() }
    }

    /// Whether `conflict` is still the question the device is asking: `signedIn` is who the
    /// caller says is signed in now. A sign-out, another sign-in or a settled owner since the
    /// screen appeared must not erase or upload anything.
    func isCurrent(_ conflict: SyncOwnerConflict, signedIn: SyncAccount?) -> Bool {
        guard signedIn == conflict.signedIn, owners.owner == conflict.owner else { return false }
        return conflict.owner != nil || owners.ownerUnknown
    }

    /// "Start from this account's data" (M2, "Different account, something to lose"; and the
    /// owner-unknown store's second choice). In order: erase the local rows
    /// (`DataBackup.eraseLocalData`, which queues no deletion); clear the deletion queue, the
    /// strikes, and the previous owner's cursor, backoff and recovery log; clear the new owner's
    /// cursor too — an erased store pulled incrementally from an old cursor would come back
    /// without the account's older rows (the 1.2.3 "signed in, no habits" bug); settle the marks
    /// proof (an empty store has no marks); make the signed-in account the owner. The caller then
    /// syncs: with no cursor, that is a full pull.
    ///
    /// The previous owner's log is cleared only once the erase has saved: past it, the lines are
    /// not "something to lose" for the screen — the user exported them or chose not to. A clear
    /// that fails leaves them under the old owner's key, never read for the new one. A failed
    /// erase throws and changes nothing else.
    func startFromAccountsData(_ conflict: SyncOwnerConflict, in context: ModelContext) throws {
        try DataBackup.eraseLocalData(in: context)
        try? recoveryLog.clear(accountID: conflict.owner?.id)
        deletionQueue.clearAll()
        SyncUnknownHabitStrikes(defaults: defaults).clearAll()
        if let previous = conflict.owner { SyncBackoffStore(defaults: defaults).clear(for: previous.id) }
        SyncMarksProof(defaults: defaults).settle()
        handOver(to: SyncOwner(conflict.signedIn), from: conflict.owner)
        cursors.setCursor(nil, for: conflict.signedIn.id)
    }

    /// "Upload these habits to this account" — the owner-unknown store only (sub-decision (e)).
    /// Every delivery mark is forgotten FIRST (`SyncMarksProof.forgetMarks`), even for the marks'
    /// own account: the user said these rows go up, so the adoption's full pull keeps them all
    /// and the push uploads them — rows the server knows as another account's come back
    /// `not_owned` and are held, rows that account deleted come back `tombstoned` and are
    /// archived; none is deleted by absence. The queued deletions stay: they were made on these
    /// rows, and the server applies a deletion only to a row the account owns. A cursor left for
    /// the account is dropped, so the first pull is full. Throws — adopting nothing — when the
    /// marks cannot be saved.
    func uploadLocalHabits(_ conflict: SyncOwnerConflict, in context: ModelContext) throws {
        // Never for a known owner: that would be the keep-and-add 1.3.1 deliberately does not
        // offer (M2, "Why no keep-and-add").
        guard conflict.isOwnerUnknown else { throw SyncOwnershipError.uploadNeedsUnknownOwner }
        try SyncMarksProof(defaults: defaults).forgetMarks(in: context)
        cursors.setCursor(nil, for: conflict.signedIn.id)
        owners.set(SyncOwner(conflict.signedIn))
    }

    /// The account `accountID` was deleted on the server (AuthService.deleteAccount, after its
    /// sign-out). If it owned this store, the store is erased and everything sync kept for it
    /// goes: the owner, every cursor, the queue, the strikes, the backoff and the marks proof —
    /// the next account signed into adopts an empty store. Its recovery log goes either way: its
    /// lines hold that account's names and notes, and nobody can sign into it again. A store
    /// owned by ANOTHER account (the deleted one was signed in while the account screen was
    /// pending) keeps its rows and owner: they were never the deleted account's.
    func accountDeleted(_ accountID: String, in context: ModelContext) throws {
        try? recoveryLog.clear(accountID: accountID)
        SyncBackoffStore(defaults: defaults).clear(for: accountID)
        cursors.setCursor(nil, for: accountID)
        guard owners.owner?.id == accountID else { return }
        try DataBackup.eraseLocalData(in: context)
        defaults.removeObject(forKey: SyncDefaultsCursorStore.key)
        defaults.removeObject(forKey: SyncDefaultsCursorStore.legacyKey)
        owners.clear()
        deletionQueue.clearAll()
        SyncUnknownHabitStrikes(defaults: defaults).clearAll()
        SyncBackoffStore(defaults: defaults).clearAll()
        SyncMarksProof(defaults: defaults).settle()
    }
}
