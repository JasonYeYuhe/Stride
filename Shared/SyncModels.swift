import Foundation

// Wire models for /v1/sync/push and /v1/sync/pull.
//
// These live in Shared/ rather than next to APIClient because StrideTests compiles only
// StrideTests/ and Shared/ (it has no TEST_HOST, so nothing under Stride/Sources is
// visible to it). While they sat in APIClient.swift, the reconciliation that consumes them
// could not be tested at all, and SyncReconcileTests tested a hand-copied replica of the
// algorithm instead — a replica that had already drifted from the real code, and that
// stayed green through bugs in the real one.
//
// Field names are camelCase on the wire in BOTH directions; see the encoder note in
// APIClient.swift before adding a key strategy.

struct SyncPushPayload: Encodable {
    let habits: [SyncHabit]
    let entries: [SyncEntry]
    let groups: [SyncGroup]
    let deletedHabitIds: [String]
    let deletedEntryIds: [String]
    let deletedGroupIds: [String]
}

struct SyncHabit: Codable {
    let id: String
    let name: String
    let emoji: String
    let colorHex: String
    let isArchived: Bool
    let sortOrder: Int
    let reminderEnabled: Bool?
    let reminderHour: Int?
    let reminderMinute: Int?
    let note: String?
    // v2 fields (optional on decode so older server responses still parse)
    let kind: String?
    let targetValue: Double?
    let unit: String?
    let scheduleKind: String?
    let timesPerWeek: Int?
    let activeDaysMask: Int?
    let groupId: String?
    let createdAt: String
    let updatedAt: String
}

struct SyncEntry: Codable {
    let id: String
    let habitId: String
    let date: String
    let note: String?
    let value: Double?
    let createdAt: String
    /// When the value or note was last edited, on whichever device edited it. The server keeps
    /// the newer edit rather than whichever device pushed last. Optional: servers before
    /// 2026-09-15 don't send it.
    var updatedAt: String? = nil
}

struct SyncGroup: Codable {
    let id: String
    let name: String
    let colorHex: String
    let sortOrder: Double
    let createdAt: String
    let updatedAt: String
}

struct SyncPullResponse: Decodable {
    let habits: [SyncHabit]
    let entries: [SyncEntry]
    let groups: [SyncGroup]?
    let deletedHabitIds: [String]?
    let deletedEntryIds: [String]?
    let deletedGroupIds: [String]?
    let serverTime: String
    /// The rows the server holds for this account (full-pull scope), on every pull since M0.
    /// Necessary, not sufficient, for the full-pull deletion pass: a truncated body or a
    /// timed-out query must never purge the local store. Optional and last, so older servers'
    /// responses parse and existing memberwise call sites compile unchanged.
    var totals: SyncTotals? = nil
}

struct SyncTotals: Codable, Equatable {
    let habits: Int
    let entries: Int
    let groups: Int
}

/// The `/v1/sync/push` answer (routes/sync.js, "The incremental-push contract"). Before 1.3.1
/// the apps decoded only `ok`; from 1.3.1 it is what acknowledges rows.
///
/// `applied` holds COUNTS per type, not ids. The acknowledged ids are therefore the chunk's
/// submitted ids minus every id in `skipped` — never derived from `applied`.
struct SyncPushResponse: Decodable {
    // The three per-type structs decode a missing key as empty (a synthesised Decodable would
    // ignore the defaults and throw), and keep memberwise inits with defaults for tests.

    struct Applied: Decodable, Equatable {
        var habits = 0
        var entries = 0
        var groups = 0

        init(habits: Int = 0, entries: Int = 0, groups: Int = 0) {
            (self.habits, self.entries, self.groups) = (habits, entries, groups)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: PerType.self)
            habits = try c.decodeIfPresent(Int.self, forKey: .habits) ?? 0
            entries = try c.decodeIfPresent(Int.self, forKey: .entries) ?? 0
            groups = try c.decodeIfPresent(Int.self, forKey: .groups) ?? 0
        }
    }

    struct Skipped: Decodable, Equatable {
        var habits: [String] = []
        var entries: [String] = []
        var groups: [String] = []

        init(habits: [String] = [], entries: [String] = [], groups: [String] = []) {
            (self.habits, self.entries, self.groups) = (habits, entries, groups)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: PerType.self)
            habits = try c.decodeIfPresent([String].self, forKey: .habits) ?? []
            entries = try c.decodeIfPresent([String].self, forKey: .entries) ?? []
            groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        }
    }

    /// id -> reason code, per type (`SyncHoldReason` raw values, plus `tombstoned_habit`,
    /// `not_owned_habit`, `skipped_habit`, `unknown_habit`). Ids are as the server echoes them;
    /// compare through `SyncReconciler.canonicalID`.
    struct SkippedReasons: Decodable, Equatable {
        var habits: [String: String] = [:]
        var entries: [String: String] = [:]
        var groups: [String: String] = [:]

        init(habits: [String: String] = [:], entries: [String: String] = [:], groups: [String: String] = [:]) {
            (self.habits, self.entries, self.groups) = (habits, entries, groups)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: PerType.self)
            habits = try c.decodeIfPresent([String: String].self, forKey: .habits) ?? [:]
            entries = try c.decodeIfPresent([String: String].self, forKey: .entries) ?? [:]
            groups = try c.decodeIfPresent([String: String].self, forKey: .groups) ?? [:]
        }
    }

    private enum PerType: String, CodingKey { case habits, entries, groups }

    let ok: Bool
    /// Optional throughout: a server before M0's contract answers `{ok: true}` alone.
    var applied: Applied? = nil
    var skipped: Skipped? = nil
    var skippedReasons: SkippedReasons? = nil
}

/// The `limits` a `400 too_many_rows` answer carries (routes/sync.js `ROW_LIMITS`), so the
/// planner can re-chunk against what the server actually enforces.
struct SyncRowLimits: Decodable, Equatable {
    let habits: Int
    let entries: Int
    let groups: Int
}
