import Foundation

// Per-owner backoff state (DEV-PLAN-1.3.md M2, "One rule per push answer"; phase B).
//
// The answer table says when to wait: `400 invalid_payload` backs off doubling 1 min → 6 h,
// jittered, and "Sync Now" retries at once; `429 rate_limited` / `503 sync_paused` wait for
// `Retry-After` / `retryAfterSeconds`; other 5xx back off on the same jittered curve. No answer
// at all waits only the curve's first step, about a minute, and never doubles (review critic-2,
// `SyncBackoffState.afterFailure`). `SyncAnswers.action` decides WHICH of those an answer is and
// `SyncBackoffPolicy.delay` gives the number; this file is the state between runs.
//
// The first vertical slice kept that state in memory on `SyncService` (`consecutiveFailures`,
// `nextAutomaticSync`), so a relaunch forgot a server's `Retry-After` and a paused server was
// asked again by every device that was opened — the fleet-wide retry storm the pause switch
// exists to stop. It is persisted here instead, and **stored with the owner** like the cursor
// (M2, account isolation: "The cursor, the backoff state and the recovery log are stored with
// the owner … none of it is ever read for another account"): a sign-in to another account
// starts from nothing, and account A's six-hour wait never delays account B's first sync.
//
// Pure apart from UserDefaults: the clock and the random draw are injected, so StrideTests pin
// every window without waiting and the rehearsal tool can run with a fixed clock.

/// Why automatic syncs are waiting. Stored by raw value, so the strings are part of the format.
enum SyncBackoffReason: String, Equatable, Sendable, CaseIterable {
    /// `invalid_payload`, a second `too_many_rows`, an unknown 4xx: a request this build got
    /// wrong (`SyncBackoffKind.clientBug`). Reported to Sentry by the engine.
    case clientBug = "client_bug"
    /// A 5xx other than the pause, or a 200 that said `ok: false`.
    case serverError = "server_error"
    /// No HTTP answer at all: offline, timeout, DNS, TLS. Split from `serverError` for the phase
    /// C status line ("offline — 3 changes waiting") and for its window: about a minute, never
    /// the doubling curve (review critic-2, `SyncBackoffState.afterFailure`).
    case offline
    /// `429 rate_limited`.
    case rateLimited = "rate_limited"
    /// `503 sync_paused`: support's pause switch.
    case paused = "sync_paused"

    init(_ kind: SyncBackoffKind, answer: SyncHTTPAnswer?) {
        switch kind {
        case .clientBug: self = .clientBug
        case .transient: self = answer?.status == nil ? .offline : .serverError
        case .serverAsked(_, let paused): self = paused ? .paused : .rateLimited
        }
    }

    /// The spec's "sync paused" inline line, never `syncError`: the server asked this device to
    /// wait, which is not something the user can fix or should be alarmed by.
    var showsSyncPaused: Bool { self == .rateLimited || self == .paused }
}

/// One owner's backoff: when the last failure was, how long it said to wait, how many runs in a
/// row have failed, and why.
///
/// The window is stored as `failedAt` + `delay`, not as one absolute "next allowed" date, so a
/// clock set backwards cannot strand automatic syncs: a stored `nextAllowedAt` of tomorrow
/// (today's failure, then the clock stepped back a day) would have blocked every launch and
/// foreground sync for a day. With `failedAt` kept, a `now` before it means the clock moved and
/// the window is over — the same "inequality, not ordering" care the delivery state takes.
struct SyncBackoffState: Equatable, Sendable {
    /// Failed runs since the last successful one, this one included; 1 for the first failure.
    /// A run with no HTTP answer does not add to it (`afterFailure`).
    var consecutiveFailures: Int
    var reason: SyncBackoffReason
    /// When the run that set this window stopped, by this device's clock.
    var failedAt: Date
    /// How long automatic syncs wait after `failedAt`. Never above `SyncBackoffPolicy.maximum`.
    var delay: TimeInterval

    /// When automatic syncs may run again — for the status line ("retrying at 14:05").
    var retryAt: Date { failedAt.addingTimeInterval(delay) }

    /// Whether an automatic sync must still wait at `now`. False once the window is over, and
    /// false when `now` is before `failedAt` (the clock moved back since the failure).
    func isWaiting(at now: Date) -> Bool {
        now >= failedAt && now < retryAt
    }

    /// Seconds left in the window at `now`; 0 once it is over.
    func remaining(at now: Date) -> TimeInterval {
        isWaiting(at: now) ? retryAt.timeIntervalSince(now) : 0
    }

    /// The state after one more failed run. `previous` is this owner's state (nil after a
    /// success, or for an owner that never failed); `unitRandom` is a draw in 0...1.
    ///
    /// The count carries across reasons: a server that was rate-limiting and is now down is
    /// still one failing episode, and the curve keeps doubling instead of restarting at a
    /// minute. A server-given `Retry-After` replaces the curve for that one window
    /// (`SyncBackoffPolicy.delay`) but still counts, so a later answer without one does not
    /// restart it either.
    ///
    /// No HTTP answer is the exception (review critic-2): its window is the curve's first step,
    /// about a minute, and it does not advance the count. No request reached the server, so a
    /// longer wait spares it nothing — and on iOS the only automatic syncs are launch and
    /// foreground, with nothing that re-arms on connectivity, so after a day without signal the
    /// doubled window kept every launch from syncing for up to 6 h after the network was back.
    /// Not counting it keeps the 6 h doubling for real server answers: a 5xx after an offline
    /// stretch starts near the bottom of the curve, not at its cap. A server episode's count is
    /// carried through, so an outage the device also lost its signal in keeps doubling.
    static func afterFailure(
        _ previous: SyncBackoffState?,
        kind: SyncBackoffKind,
        answer: SyncHTTPAnswer?,
        now: Date,
        unitRandom: Double
    ) -> SyncBackoffState {
        let reason = SyncBackoffReason(kind, answer: answer)
        let previousFailures = previous?.consecutiveFailures ?? 0
        let failures = reason == .offline
            ? max(1, previousFailures)
            : min(previousFailures + 1, SyncBackoffState.countCap)
        let delay = SyncBackoffPolicy.delay(for: kind, consecutiveFailures: reason == .offline ? 1 : failures,
                                            unitRandom: unitRandom)
        return SyncBackoffState(
            consecutiveFailures: failures,
            reason: reason,
            failedAt: now,
            delay: min(max(0, delay), SyncBackoffPolicy.maximum))
    }

    /// Past 6 h the count changes nothing (`SyncBackoffPolicy` caps the exponent at 30); keep the
    /// stored number bounded so a device failing for years never overflows it.
    static let countCap = 1_000
}

/// What starts a sync run, as far as the backoff is concerned. The app's `SyncService.Trigger`
/// maps onto it (`.userInitiated` → `.manual`, `.automatic` → `.automatic`, `.background` →
/// `.background`).
///
/// Ask `waitsOutWindow` and `recordsNoAnswer`, never `== .automatic` (RELEASE-1.4.0.md D5). Every
/// check here used to be `trigger == .automatic`, and in SyncService `self == .automatic ?
/// .automatic : .manual`: a third case would have compiled without a warning and been treated as
/// Sync Now — past a paused server's window on every background refresh and every lock-screen
/// action, every failure recorded (design review, "background-trigger-silent-default"). Both
/// properties are exhaustive switches, so the next case cannot slip through either.
enum SyncBackoffTrigger: Equatable, Sendable {
    /// Launch and foreground: waits out the window.
    case automatic
    /// Sync Now, a sign-in, Erase's pre-erase sync, Full resync: "Sync Now retries at once",
    /// whatever the window. A user who asked must never be told "later".
    case manual
    /// 1.4.0's background runs: the BGAppRefreshTask, and the sync after a notification action.
    /// Waits out the window like `.automatic`, but a run that got no answer leaves no trace (see
    /// `recordsNoAnswer`).
    case background

    /// Whether a run must wait while the owner's window is open (`SyncBackoffStore.decision`).
    var waitsOutWindow: Bool {
        switch self {
        case .automatic, .background: return true
        case .manual: return false
        }
    }

    /// Whether a run that got no HTTP answer at all (`SyncBackoffReason.offline`: offline, a
    /// timeout, DNS, TLS — and a cancellation, which APIClient reports the same way) is recorded.
    ///
    /// Not for `.background`. Such a run is cut short by iOS as often as by the network: the
    /// refresh's ~30 s ran out and the task was cancelled, or the action fired on a lock screen in
    /// a tunnel. Recorded, it would open a minute's window that turns away the foreground sync the
    /// user starts by opening the app — the one sync that would deliver the check-in — and
    /// SyncService would show the system's "cancelled" under Settings. A background run that never
    /// reached the server says nothing about the server. A real answer still counts for every trigger: a 429,
    /// a 5xx and the pause switch are recorded and respected (D5).
    var recordsNoAnswer: Bool {
        switch self {
        case .background: return false
        case .automatic, .manual: return true
        }
    }
}

enum SyncBackoffDecision: Equatable, Sendable {
    case go
    /// Skip this automatic run; `state` says why and until when (the status line reads it).
    case wait(SyncBackoffState)

    var mayRun: Bool { self == .go }
}

/// The backoff state of every owner, in the defaults that hold the cursors and the owner
/// (`UserDefaults.standard` in the app): one dictionary, owner id → that owner's state, the
/// shape `SyncDefaultsCursorStore` uses.
///
/// Fail-open by design: an entry this build cannot read (a corrupt value, a future format) reads
/// as "no backoff", and a stored delay above the policy's maximum is clamped to it. The window
/// only spares the server and the battery; a device must never be stuck not syncing because of
/// one bad value, and a manual sync ignores it anyway.
struct SyncBackoffStore {
    static let key = "stride_sync_backoff_by_owner"

    let defaults: UserDefaults
    /// The clock. Tests pass a fixed one.
    let now: () -> Date
    /// A draw in 0...1 for the jitter. Tests pass a fixed one.
    let unitRandom: () -> Double

    init(
        defaults: UserDefaults,
        now: @escaping () -> Date = { Date() },
        unitRandom: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.defaults = defaults
        self.now = now
        self.unitRandom = unitRandom
    }

    // MARK: Reading

    /// This owner's state, or nil when its last run succeeded (or it never failed).
    func state(for ownerID: String) -> SyncBackoffState? {
        guard let entry = defaults.dictionary(forKey: Self.key)?[ownerID] as? [String: Any] else { return nil }
        return Self.decode(entry)
    }

    /// May a run of this kind start now for this owner? Manual always may. Automatic and
    /// background may unless the owner's window is still open (`waitsOutWindow`).
    ///
    /// Asked with the store's OWNER (the only account a run can serve), before the run: a
    /// device signed into an account that is not the owner is blocked by the owner gate
    /// anyway, and an owner that has never failed has no entry.
    func decision(for trigger: SyncBackoffTrigger, ownerID: String) -> SyncBackoffDecision {
        guard trigger.waitsOutWindow, let state = state(for: ownerID), state.isWaiting(at: now()) else {
            return .go
        }
        return .wait(state)
    }

    func mayRun(_ trigger: SyncBackoffTrigger, ownerID: String) -> Bool {
        decision(for: trigger, ownerID: ownerID).mayRun
    }

    // MARK: Writing

    /// One run's outcome for the owner the run was bound to (`SyncRunBinding.ownerID` — never
    /// "whoever is signed in now": a run that ends after a switch to another account must not
    /// write its failure under that account). Returns the state it leaves.
    ///
    /// - `synced` → the state is cleared: "success resets".
    /// - `stopped(.backOff)` → one more failure — except a run with no HTTP answer on a trigger
    ///   that does not record one (`recordsNoAnswer`: `.background`), which leaves the state as it
    ///   was, whatever it was.
    /// - Anything else changes nothing. A reauth, an upgrade-required, a local save failure, a
    ///   run ended by a sign-out, a blocked run: none of these is the server asking for less
    ///   traffic, and none is fixed by waiting — the reauth row, the 426 and the next sync
    ///   handle them. In particular a `bindingChanged` stop says nothing about the server.
    ///
    /// `trigger` has no default on purpose: every caller states what started the run.
    @discardableResult
    func record(_ outcome: SyncRunOutcome, for ownerID: String, trigger: SyncBackoffTrigger) -> SyncBackoffState? {
        switch outcome {
        case .synced:
            recordSuccess(for: ownerID)
            return nil
        case .stopped(.backOff(let kind, let answer), _)
            where !trigger.recordsNoAnswer && SyncBackoffReason(kind, answer: answer) == .offline:
            return state(for: ownerID)
        case .stopped(.backOff(let kind, let answer), _):
            return recordFailure(kind, answer: answer, for: ownerID)
        case .stopped, .blocked:
            return state(for: ownerID)
        }
    }

    /// One more failed run for this owner; returns the new state.
    @discardableResult
    func recordFailure(_ kind: SyncBackoffKind, answer: SyncHTTPAnswer? = nil, for ownerID: String) -> SyncBackoffState {
        let next = SyncBackoffState.afterFailure(
            state(for: ownerID), kind: kind, answer: answer, now: now(), unitRandom: unitRandom())
        write(Self.encode(next), for: ownerID)
        return next
    }

    /// A run for this owner went through: the next failure starts the curve at a minute again.
    func recordSuccess(for ownerID: String) {
        write(nil, for: ownerID)
    }

    /// Forgets one owner's state. "Start from this account's data" clears the previous owner's
    /// backoff with its cursor, queue and recovery log.
    func clear(for ownerID: String) {
        write(nil, for: ownerID)
    }

    /// Forgets every owner's state: Erase Local Data (`SyncService.resetSyncState`), account
    /// deletion.
    func clearAll() {
        defaults.removeObject(forKey: Self.key)
    }

    // MARK: Format

    // A property-list dictionary per owner, like the cursor and the strikes: readable with
    // `defaults read`, which is how a support case inspects a device's sync state. Dates are
    // seconds since 1970 as Double, which round-trips a `Date` exactly.

    private func write(_ entry: [String: Any]?, for ownerID: String) {
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        if let entry { all[ownerID] = entry } else { all.removeValue(forKey: ownerID) }
        if all.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(all, forKey: Self.key) }
    }

    private static func encode(_ state: SyncBackoffState) -> [String: Any] {
        [
            "failures": state.consecutiveFailures,
            "reason": state.reason.rawValue,
            "failedAt": state.failedAt.timeIntervalSince1970,
            "delay": state.delay,
        ]
    }

    private static func decode(_ entry: [String: Any]) -> SyncBackoffState? {
        guard let failures = (entry["failures"] as? NSNumber)?.intValue, failures > 0,
              let reason = (entry["reason"] as? String).flatMap(SyncBackoffReason.init(rawValue:)),
              let failedAt = (entry["failedAt"] as? NSNumber)?.doubleValue, failedAt.isFinite,
              let delay = (entry["delay"] as? NSNumber)?.doubleValue, delay.isFinite
        else { return nil }
        return SyncBackoffState(
            consecutiveFailures: min(failures, SyncBackoffState.countCap),
            reason: reason,
            failedAt: Date(timeIntervalSince1970: failedAt),
            delay: min(max(0, delay), SyncBackoffPolicy.maximum))
    }
}
