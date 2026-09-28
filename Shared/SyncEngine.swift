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
// What plugs in later (not in the first vertical slice): the owner gate UI decides what
// `SyncRunGate.current()` returns; the recovery-log file implements `SyncRecoveryLogSink`; the
// backoff scheduler and the sync-status line read `SyncRunOutcome`; Settings → Full resync is
// `SyncRunOptions.fullResync`.

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
/// row pending, so the next sync retries either way. The file implementation
/// (`Shared/SyncRecoveryLog.swift`: JSON lines in Application Support, 5 MB cap, export) is not
/// part of the first vertical slice; the in-memory one stands in for it.
@MainActor
protocol SyncRecoveryLogSink: AnyObject {
    func archive(_ items: [SyncRecoveryItem], accountID: String?) throws
}

/// Keeps the lines in memory — the tests' and the rehearsal's sink, and the app's until the file
/// log lands. `failure` makes the next appends throw, as a full disk would.
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
    ///   is pushed, and nothing deleted by absence, before the account is proven.
    /// - It pulls BEFORE pushing when there is no cursor, when the cursor is older than
    ///   `cursorLifetime` (cleared: a full pull) or `cursorProbeAge` (so the server's
    ///   `cursor_expired` comes before the push), or when any row waits on a forced resend: the
    ///   resend goes up only
    ///   after a pull on a live cursor has settled deletions, and without a cursor the full pull
    ///   removes delivered-but-absent rows (archived) before anything is pushed.
    /// - Chunks go in sequence and the run stops at the first one that fails; later chunks do not
    ///   run, and the retry resumes there (the acknowledged ones are no longer pending).
    func run(in context: ModelContext, options: SyncRunOptions = []) async -> SyncRunOutcome {
        guard !isRunning else { return .blocked(.alreadyRunning) }
        let binding: SyncRunBinding
        switch gate.current() {
        case .ready(let b): binding = b
        case .signedOut: return .blocked(.signedOut)
        case .ownerUnsettled: return .blocked(.ownerUnsettled)
        }
        isRunning = true
        defer { isRunning = false }

        let run = SyncRun(engine: self, context: context, binding: binding)
        do {
            try await run.execute(options)
            return .synced(run.summary)
        } catch let stop as SyncRunStop {
            return .stopped(stop.reason, run.summary)
        } catch {
            context.rollback()
            return .stopped(.localFailure(String(describing: error)), run.summary)
        }
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
                do {
                    // Read now, not at the run's start: the push before this pull acknowledged
                    // what it delivered, and whatever is still queued must not come back.
                    reconciled = try SyncReconciler.apply(pulled, to: context, isFullPull: since == nil,
                                                          proveMarks: proving,
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
                    // what it is. Undecided stays awaited: the next run full-pulls again.
                    if verdict != .undecided { engine.marks.settle() }
                }
                summary.archived += reconciled.archived
                summary.heldTombstoned += reconciled.heldTombstoned
                summary.pullIssues += reconciled.issues
                if reconciled.deletionPassSkipped { summary.deletionPassSkipped = true }
                if let diagnostic = reconciled.diagnostic { engine.report(diagnostic) }
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
