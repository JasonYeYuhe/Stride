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
    /// A full pull that asked (`?deletionsSince=`, a 1.3.1 server): the account's deletions since
    /// that time (review data-safety-1). Absent from every other answer, and from a server before
    /// 1.3.1's, which ignores the parameter.
    var deletionsSince: SyncDeletionsSince? = nil
}

struct SyncTotals: Codable, Equatable {
    let habits: Int
    let entries: Int
    let groups: Int
}

/// `deletionsSince` in a full pull's answer (routes/sync.js, above `listableDeletionsSince`): every
/// habit, entry and group id the account deleted after the time the pull named, read in the same
/// transaction as the snapshot — or `complete: false` and no lists, when that time is past the
/// server's cursor horizon (a sweep may have removed a tombstone after it) or unreadable.
///
/// Decoded leniently: a malformed field must not fail the decode of the whole pull, which the
/// engine would take for an unreadable 200 and back off on. Anything but a complete answer with all
/// three lists reads as "not listed" (`lists` nil), which the pass treats like a server that sent
/// nothing: it deletes by absence and archives every row it deletes.
struct SyncDeletionsSince: Decodable, Equatable {
    var complete = false
    var habitIds: [String]? = nil
    var entryIds: [String]? = nil
    var groupIds: [String]? = nil

    init(complete: Bool, habitIds: [String]? = nil, entryIds: [String]? = nil, groupIds: [String]? = nil) {
        (self.complete, self.habitIds, self.entryIds, self.groupIds) = (complete, habitIds, entryIds, groupIds)
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        complete = (try? c.decodeIfPresent(Bool.self, forKey: .complete)) ?? false
        habitIds = try? c.decodeIfPresent([String].self, forKey: .habitIds)
        entryIds = try? c.decodeIfPresent([String].self, forKey: .entryIds)
        groupIds = try? c.decodeIfPresent([String].self, forKey: .groupIds)
    }

    private enum Keys: String, CodingKey { case complete, habitIds, entryIds, groupIds }

    /// The three lists, canonical (`SyncReconciler.canonicalID`), when the answer is complete.
    @MainActor var lists: SyncDeletedIDs? {
        guard complete, let habitIds, let entryIds, let groupIds else { return nil }
        return SyncDeletedIDs(habits: Set(habitIds.map(SyncReconciler.canonicalID)),
                              entries: Set(entryIds.map(SyncReconciler.canonicalID)),
                              groups: Set(groupIds.map(SyncReconciler.canonicalID)))
    }
}

/// Ids the account deleted, per kind, canonical: what `SyncDeletionsSince.lists` gives the pass.
struct SyncDeletedIDs: Equatable {
    var habits: Set<String> = []
    var entries: Set<String> = []
    var groups: Set<String> = []
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

    /// Applied entries that landed on a row the server already held for their habit and day, under
    /// another id: sent id -> the id that row keeps, as the server spells both; compare through
    /// `SyncReconciler.canonicalID` (routes/sync.js "aliases", review data-safety-4). Only entries:
    /// habits and groups conflict on their own id. Absent from a push that had none, and from
    /// every server before 1.3.1's.
    struct Aliases: Decodable, Equatable {
        var entries: [String: String] = [:]

        init(entries: [String: String] = [:]) { self.entries = entries }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: PerType.self)
            entries = try c.decodeIfPresent([String: String].self, forKey: .entries) ?? [:]
        }
    }

    private enum PerType: String, CodingKey { case habits, entries, groups }

    let ok: Bool
    /// Optional throughout: a server before M0's contract answers `{ok: true}` alone.
    var applied: Applied? = nil
    var skipped: Skipped? = nil
    var skippedReasons: SkippedReasons? = nil
    var aliases: Aliases? = nil
}

/// The `limits` a `400 too_many_rows` answer carries (routes/sync.js `ROW_LIMITS`), so the
/// planner can re-chunk against what the server actually enforces.
struct SyncRowLimits: Decodable, Equatable {
    let habits: Int
    let entries: Int
    let groups: Int
}
