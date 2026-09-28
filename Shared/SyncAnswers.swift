import Foundation

// One rule per push answer (DEV-PLAN-1.3.md M2, "One rule per push answer" — revised
// 2026-09-28, replacing the 400-bisection poison-pill guard).
//
// Pure mappings, from what the server said to what the app does. Nothing here touches a store,
// a network or a clock: the engine executes the actions, `SyncPushResolver` applies the row-level
// ones to a store, and StrideTests drives this table directly. In Shared/ so the host-less tests
// and scripts/sync_rehearsal.sh run the one implementation the app runs.
//
// Why a table and not bisection: the server answers a bad ROW with 200 and a `skippedReasons`
// entry (SQLite errors are caught per row as `row_error`), and its only push 400s are envelope
// errors — `invalid_payload` (a field that is not an array) and `too_many_rows` (over the row
// caps), routes/sync.js "The incremental-push contract". Bisecting a 400 chunk therefore never
// isolates a bad row: it splits a malformed envelope down to single rows and then quarantines
// good data.

// MARK: - Row level (a 200's `skippedReasons`)

/// The reasons `/v1/sync/push` gives per skipped id (routes/sync.js, "The incremental-push
/// contract"). `SyncHoldReason` is what the app stores; this is what the server says.
enum SyncSkipReason: String, CaseIterable {
    /// The row itself was deleted, earlier or in this very push.
    case tombstoned
    /// An entry whose habit was deleted.
    case tombstonedHabit = "tombstoned_habit"
    /// No name / habitId / date — never applies as sent.
    case missingField = "missing_field"
    /// SQLite refused the row (constraint, unbindable value).
    case rowError = "row_error"
    /// A number no app can produce (routes/sync.js PUSH_BOUNDS).
    case invalidValue = "invalid_value"
    /// An entry whose habit the server does not have at all — usually the habit's own chunk has
    /// not landed yet.
    case unknownHabit = "unknown_habit"
    /// An entry whose habit was in this push and was itself skipped.
    case skippedHabit = "skipped_habit"
    /// A habit or group id that belongs to another account.
    case notOwned = "not_owned"
    /// An entry whose habit id belongs to another account.
    case notOwnedHabit = "not_owned_habit"
}

/// What happens to one submitted row after a 200.
enum SyncRowAction: Equatable {
    /// Sent and not in `skipped`: `syncedAt` = the stamp that was SENT (`SyncDeliverable.acknowledge`).
    case acknowledge
    /// Delete wins: the engine archives the row to the recovery log (a row that was just sent is
    /// pending by definition), then deletes it locally.
    case drop
    /// Quarantine at the sent stamp: kept, never acknowledged, never re-sent until edited, never
    /// deleted by a full pull.
    case hold(SyncHoldReason)
    /// Neither acknowledged nor held: sent again next sync.
    case keepPending
}

/// What the row-level rule needs to know about the local row, beyond the server's reason.
struct SyncRowFacts: Equatable {
    /// `restoredAt != nil`: restored with its backup's ids. A tombstone answer holds it for the
    /// restore-as-copies choice instead of dropping it — a restore undoes another device's
    /// deletion only when the user says so.
    var isRestored = false
    /// For an entry: its habit has been delivered (`syncedAt != nil`). The `unknown_habit`
    /// strikes count only from then on — before, the habit's own chunk may simply not have landed.
    var habitAcknowledged = false
    /// `unknown_habit` answers this entry already had, in earlier syncs, after its habit was
    /// acknowledged (`SyncUnknownHabitStrikes`).
    var priorUnknownHabitStrikes = 0
}

enum SyncAnswers {
    /// "An entry still `unknown_habit` three syncs after its habit was acknowledged is held and
    /// reported" — the habit is on the server by then, so the entry's `habitId` is what is wrong.
    static let unknownHabitStrikeLimit = 3

    /// The row-level rule for one submitted id.
    ///
    /// - Parameters:
    ///   - skipped: the id (canonicalised) is in the response's `skipped` or `skippedReasons`.
    ///   - reason: its `skippedReasons` code, if the server gave one.
    ///
    /// A reason this build does not know keeps the row pending rather than holding it: it may be
    /// a new server code for "try again", and a hold would quarantine good data behind a code the
    /// app cannot explain. It is never acknowledged — the server said it did not write it.
    static func rowAction(skipped: Bool, reason: String?, facts: SyncRowFacts = SyncRowFacts()) -> SyncRowAction {
        guard skipped else { return .acknowledge }
        guard let known = reason.flatMap(SyncSkipReason.init(rawValue:)) else { return .keepPending }
        switch known {
        case .tombstoned, .tombstonedHabit:
            return facts.isRestored ? .hold(.tombstoned) : .drop
        case .missingField:
            return .hold(.missingField)
        case .rowError:
            return .hold(.rowError)
        case .invalidValue:
            return .hold(.invalidValue)
        case .unknownHabit:
            guard facts.habitAcknowledged,
                  facts.priorUnknownHabitStrikes + 1 >= unknownHabitStrikeLimit
            else { return .keepPending }
            return .hold(.unknownHabit)
        case .skippedHabit:
            // The habit's own answer decides it; once the habit lands, so does the entry.
            return .keepPending
        case .notOwned, .notOwnedHabit:
            // Never acknowledge (the full-pull rule would then delete it), never drop (it is the
            // user's data). "Restore as new copies" gives it new ids.
            return .hold(.notOwned)
        }
    }

    /// Whether this answer's `unknown_habit` counts as a strike toward the hold. Only after the
    /// habit was acknowledged: before that, `unknown_habit` is the expected answer for an entry
    /// whose habit's chunk failed.
    static func countsUnknownHabitStrike(reason: String?, facts: SyncRowFacts) -> Bool {
        reason == SyncSkipReason.unknownHabit.rawValue && facts.habitAcknowledged
    }
}

// MARK: - Request level (status and code)

enum SyncEndpoint: Equatable {
    case push
    case pull
}

/// What one sync request came back with, reduced to what the rule table reads. The transport
/// builds it; `status == nil` means no HTTP answer at all (offline, timeout, DNS, TLS).
struct SyncHTTPAnswer: Equatable {
    var status: Int?
    /// The body's machine-readable code (`code`, or `error` when that is a code).
    var code: String? = nil
    /// A 200's `ok`. nil when the body had none (or was not read).
    var ok: Bool? = nil
    /// The body's `retryAfterSeconds`, else the `Retry-After` header.
    var retryAfterSeconds: Double? = nil
    /// A `400 too_many_rows` answer's `limits`.
    var limits: SyncRowLimits? = nil

    static let noAnswer = SyncHTTPAnswer(status: nil)

    /// Decodes the parts the table reads from a response. Tolerates any body: a proxy's HTML
    /// 502, an empty 413 from nginx, a JSON body from a server older than the codes.
    ///
    /// `errorBody` (server/lib/clientVersion.js) puts the code in both `error` and `code` for a
    /// client that sends `X-Stride-Client`, and a human sentence in `error` for one that does
    /// not; `code` is therefore read first, and `error` only when it looks like a code.
    static func decode(status: Int, body: Data?, retryAfterHeader: String? = nil) -> SyncHTTPAnswer {
        var answer = SyncHTTPAnswer(status: status)
        if let body, !body.isEmpty, let parsed = try? JSONDecoder().decode(Body.self, from: body) {
            answer.ok = parsed.ok
            answer.code = parsed.code ?? parsed.error.flatMap { looksLikeCode($0) ? $0 : nil }
            answer.retryAfterSeconds = parsed.retryAfterSeconds
            answer.limits = parsed.limits
        }
        if answer.retryAfterSeconds == nil,
           let header = retryAfterHeader?.trimmingCharacters(in: .whitespaces),
           let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            answer.retryAfterSeconds = seconds
        }
        return answer
    }

    private struct Body: Decodable {
        var ok: Bool?
        var code: String?
        var error: String?
        var retryAfterSeconds: Double?
        var limits: SyncRowLimits?
    }

    private static func looksLikeCode(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLowercase || $0 == "_" || $0.isNumber }
    }
}

/// The shape of the chunk a push answer is about. "Single row" is what separates the two 413
/// rules: a one-row chunk cannot be split, so the row is what is too big.
struct SyncChunkShape: Equatable {
    /// Rows and deletion ids together.
    var items: Int
    /// Groups, habits and entries (deletion ids are not rows: they cannot be held).
    var rows: Int

    var isSingleRow: Bool { items == 1 && rows == 1 }
}

/// Retries already spent within ONE sync run. Each re-chunking rule fires once per run; a second
/// identical answer is a bug the app cannot fix by splitting again.
struct SyncRunAttempts: Equatable {
    var rechunkedForRows = false
    var halvedBytes = false
}

enum SyncBackoffKind: Equatable {
    /// The app built a request the server could not read (`invalid_payload`, a second
    /// `too_many_rows`, an unknown 4xx). Doubling 1 min → 6 h, jittered; reported to Sentry.
    case clientBug
    /// Other 5xx, no answer, a 200 that said `ok: false`. Doubling 1 min → 6 h, jittered.
    case transient
    /// 429 `rate_limited` / 503 `sync_paused`: the server said when. Shown as "sync paused"
    /// inline when `paused`; never `syncError`.
    case serverAsked(seconds: Double?, paused: Bool)
}

/// What the engine does with one answer. Rows stay pending in every case except `proceed` (then
/// row by row) and `holdTooLarge`.
enum SyncAnswerAction: Equatable {
    /// 2xx: push — resolve the chunk row by row (`SyncAnswers.rowAction`); pull — apply it.
    case proceed
    /// 400 `too_many_rows`, first in this run: a planner bug. Re-chunk what is left against the
    /// returned `limits` and resend in the same sync.
    case rechunk(SyncRowLimits?)
    /// 413 on a multi-item chunk, first in this run: re-chunk what is left at half the byte
    /// bound and resend in the same sync.
    case rechunkAtHalfBytes
    /// 413 on a one-row chunk: hold that row `too_large` (at the stamp that was sent) and carry
    /// on with the next chunk.
    case holdTooLarge
    /// 401: `needsReauth`; stop. No state is reset — re-login to the same account resumes.
    case reauth
    /// 409 `snapshot_required` (push or pull): every row `needsResend` (`syncedAt` and holds
    /// untouched), then pull on a live cursor BEFORE the resend goes up ("Forced resend").
    case forcedResend
    /// 409 `cursor_expired`: clear the cursor; full pull first, then push.
    case fullPull
    /// 426: this build is below the server's floor. Stop; no backoff loop can fix it.
    case upgradeRequired
    /// Stop this sync; rows stay pending, nothing is held.
    case backOff(SyncBackoffKind)

    /// Worth a Sentry report (ids, codes and counts only — `SyncDiagnosticReport`).
    var reportsToSentry: Bool {
        if case .backOff(.clientBug) = self { return true }
        return false
    }

    /// Whether the Settings footer's `syncError` is set. A rate limit, a pause, a lost network,
    /// a reauth (its own row) and the in-run re-chunks are not errors to show.
    var setsSyncError: Bool {
        switch self {
        case .backOff(.clientBug), .upgradeRequired: return true
        case .backOff(.transient): return true
        default: return false
        }
    }
}

extension SyncAnswers {
    /// The request-level rule — the table in DEV-PLAN-1.3.md M2, "One rule per push answer".
    ///
    /// - Parameters:
    ///   - chunk: the push chunk's shape; nil for a pull.
    ///   - attempts: re-chunks already spent in this run.
    static func action(
        for answer: SyncHTTPAnswer,
        endpoint: SyncEndpoint,
        chunk: SyncChunkShape? = nil,
        attempts: SyncRunAttempts = SyncRunAttempts()
    ) -> SyncAnswerAction {
        guard let status = answer.status else { return .backOff(.transient) }
        switch status {
        case 200..<300:
            // A 200 that says it failed wrote nothing we can prove: acknowledge nothing.
            return answer.ok == false ? .backOff(.transient) : .proceed
        case 401:
            return .reauth
        case 409:
            switch answer.code {
            case "snapshot_required": return .forcedResend
            // Only a pull answers it; were a push ever to, a full pull is still the recovery.
            case "cursor_expired": return .fullPull
            default: return .backOff(.transient)
            }
        case 400:
            if endpoint == .push, answer.code == "too_many_rows", !attempts.rechunkedForRows {
                return .rechunk(answer.limits)
            }
            if endpoint == .pull, answer.code == "invalid_payload" {
                // The pull's only 400 is a `since` the server cannot read. Backing off would
                // leave the device retrying the same cursor forever; dropping it (a full pull)
                // is the one repair, and a full pull sends no `since` to be wrong.
                return .fullPull
            }
            return .backOff(.clientBug)
        case 413:
            guard endpoint == .push, let chunk else { return .backOff(.clientBug) }
            if chunk.isSingleRow { return .holdTooLarge }
            if chunk.items > 1, !attempts.halvedBytes { return .rechunkAtHalfBytes }
            // Already halved once, or a lone deletion id: splitting again is not the fix.
            return .backOff(.clientBug)
        case 426:
            return .upgradeRequired
        case 429:
            return .backOff(.serverAsked(seconds: answer.retryAfterSeconds, paused: false))
        case 503 where answer.code == "sync_paused":
            return .backOff(.serverAsked(seconds: answer.retryAfterSeconds, paused: true))
        case 500..<600:
            return .backOff(.transient)
        default:
            // Any other 4xx (or a 3xx the session did not follow) is a request this build got
            // wrong; the rows are not what is wrong, so nothing is held.
            return .backOff(.clientBug)
        }
    }
}

// MARK: - Backoff

/// "Doubling 1 min → 6 h, jittered; Sync Now retries at once." Today `APIClient` / `SyncService`
/// have no retry at all, so a device that fails keeps failing at the rate the user foregrounds
/// the app. Pure: the caller supplies the failure count and the random draw, so a test can pin
/// the curve and the rehearsal can run without waiting.
enum SyncBackoffPolicy {
    static let initial: TimeInterval = 60
    static let maximum: TimeInterval = 6 * 60 * 60
    /// ±20 %: enough to spread a fleet that failed on the same server restart.
    static let jitter = 0.2

    /// The delay before the next automatic attempt.
    /// - Parameters:
    ///   - consecutiveFailures: 1 for the first failure.
    ///   - unitRandom: a draw in 0...1 (0.5 = no jitter).
    static func delay(for kind: SyncBackoffKind, consecutiveFailures: Int, unitRandom: Double) -> TimeInterval {
        if case let .serverAsked(seconds?, _) = kind, seconds.isFinite, seconds > 0 {
            // The server said when; earlier is refused again, later wastes the window.
            return min(seconds, maximum)
        }
        let exponent = max(0, min(consecutiveFailures - 1, 30))
        let base = min(maximum, initial * pow(2, Double(exponent)))
        let draw = min(1, max(0, unitRandom.isFinite ? unitRandom : 0.5))
        let jittered = base * (1 - jitter + 2 * jitter * draw)
        return min(maximum, jittered)
    }
}

// MARK: - Diagnostics

/// What a Sentry report about sync may carry: ids, reason codes, counts and (added by the
/// reporter) the build — never names, notes or values. Built only from those, so there is no
/// field a row's content could reach.
struct SyncDiagnosticReport: Equatable {
    /// "push_answer" (a request-level answer worth reporting), "row_held".
    var event: String
    var code: String?
    var status: Int?
    var counts: [String: Int] = [:]
    /// id -> reason code.
    var reasons: [String: String] = [:]

    /// A request-level answer (e.g. `invalid_payload`), with the chunk's counts only.
    static func answer(_ answer: SyncHTTPAnswer, groups: Int, habits: Int, entries: Int, deletions: Int) -> SyncDiagnosticReport {
        SyncDiagnosticReport(
            event: "push_answer",
            code: answer.code,
            status: answer.status,
            counts: ["groups": groups, "habits": habits, "entries": entries, "deletions": deletions]
        )
    }

    /// Rows just held, by id and reason.
    static func held(_ holds: [(id: String, reason: SyncHoldReason)]) -> SyncDiagnosticReport {
        var reasons: [String: String] = [:]
        var counts: [String: Int] = [:]
        for hold in holds {
            reasons[hold.id] = hold.reason.rawValue
            counts[hold.reason.rawValue, default: 0] += 1
        }
        return SyncDiagnosticReport(event: "row_held", code: nil, status: nil, counts: counts, reasons: reasons)
    }
}

extension SyncHoldReason {
    /// Held rows that mean something is wrong with the data or this build, reported to Sentry
    /// once. `not_owned` and `tombstoned` are user-resolvable states ("Restore as new copies"),
    /// shown in Settings and counted, not reported.
    var reportsToSentry: Bool {
        switch self {
        case .missingField, .rowError, .invalidValue, .unknownHabit, .tooLarge: return true
        case .notOwned, .tombstoned: return false
        }
    }
}

// MARK: - unknown_habit strikes

/// How many syncs in a row each entry came back `unknown_habit` after its habit was
/// acknowledged. Local state, beside the deletion queue; cleared with it when the device starts
/// from another account's data (`clearAll`).
///
/// A count, not a model field: it matters for a handful of entries at most, for three syncs, and
/// is not worth a schema change. Losing it (a reinstall) only restarts the count.
struct SyncUnknownHabitStrikes {
    static let key = "stride_unknown_habit_strikes"

    let defaults: UserDefaults

    /// Strikes for a canonical entry id.
    func strikes(for id: String) -> Int {
        (defaults.dictionary(forKey: Self.key)?[id] as? Int) ?? 0
    }

    /// Records one more strike; returns the new count.
    @discardableResult
    func record(_ id: String) -> Int {
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        let next = ((all[id] as? Int) ?? 0) + 1
        all[id] = next
        defaults.set(all, forKey: Self.key)
        return next
    }

    /// Forgets these ids: they were acknowledged, held or dropped.
    func clear(_ ids: some Sequence<String>) {
        guard var all = defaults.dictionary(forKey: Self.key) else { return }
        var changed = false
        for id in ids where all.removeValue(forKey: id) != nil { changed = true }
        guard changed else { return }
        if all.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(all, forKey: Self.key) }
    }

    func clearAll() { defaults.removeObject(forKey: Self.key) }
}
