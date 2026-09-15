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
}
