import Foundation
import SwiftData
import SwiftUI

/// Handles bidirectional sync between local SwiftData and the Stride server.
@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private(set) var isSyncing = false
    private(set) var lastSyncTime: String?
    private(set) var syncError: String?

    private let lastSyncKey = "stride_last_sync_time"

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    // Day-only dates are serialized in UTC to match the stored day-key
    // representation (see HabitCalendar) — never the device's current zone,
    // which would shift check-ins across day boundaries after travel.
    private static let dateOnly: DateFormatter = HabitCalendar.dayStringFormatter

    init() {
        lastSyncTime = UserDefaults.standard.string(forKey: lastSyncKey)
    }

    // MARK: - Deletion Tracking

    // Queued in SyncDeletionQueue (Shared/) and sent with the next push. They are removed
    // only after the server accepts that push — see the type's comment for why.

    /// Track a deleted habit ID for next sync push.
    func trackDeletedHabit(_ id: String) { SyncDeletionQueue.live.trackHabit(id) }

    /// Track a deleted entry ID for next sync push.
    func trackDeletedEntry(_ id: String) { SyncDeletionQueue.live.trackEntry(id) }

    /// Track a deleted group ID for next sync push.
    func trackDeletedGroup(_ id: String) { SyncDeletionQueue.live.trackGroup(id) }

    /// Full sync: push local changes then pull remote changes.
    func sync(context: ModelContext) async {
        let api = APIClient.shared
        guard await api.isLoggedIn else { return }
        guard !isSyncing else { return }

        isSyncing = true
        syncError = nil

        do {
            try await pushLocal(context: context, api: api)
            try await pullRemote(context: context, api: api)

            let now = Self.iso8601.string(from: Date())
            lastSyncTime = now
            UserDefaults.standard.set(now, forKey: lastSyncKey)
            AnalyticsService.shared.send("syncPerformed")
        } catch {
            syncError = error.localizedDescription
        }

        isSyncing = false
    }

    private func pushLocal(context: ModelContext, api: APIClient) async throws {
        let habits = try context.fetch(FetchDescriptor<Habit>())
        let queue = SyncDeletionQueue.live
        let deleted = queue.pending()

        let syncHabits = habits.map { habit in
            SyncHabit(
                id: habit.id.uuidString,
                name: habit.name,
                emoji: habit.emoji,
                colorHex: habit.colorHex,
                isArchived: habit.isArchived,
                sortOrder: Int(habit.sortOrder),
                reminderEnabled: habit.reminderEnabled,
                reminderHour: habit.reminderHour,
                reminderMinute: habit.reminderMinute,
                note: habit.note,
                kind: habit.kind,
                targetValue: habit.targetValue,
                unit: habit.unit,
                scheduleKind: habit.scheduleKind,
                timesPerWeek: habit.timesPerWeek,
                activeDaysMask: habit.activeDaysMask,
                groupId: habit.groupId?.uuidString,
                createdAt: Self.iso8601.string(from: habit.createdAt),
                // Truthful per-habit modification time (falls back to createdAt for
                // legacy rows) so the server can resolve multi-device conflicts as
                // last-write-wins instead of last-push-wins.
                updatedAt: Self.iso8601.string(from: habit.updatedAt ?? habit.createdAt)
            )
        }

        let syncEntries = habits.flatMap { habit in
            habit.records.map { record in
                SyncEntry(
                    id: record.id.uuidString,
                    habitId: habit.id.uuidString,
                    date: Self.dateOnly.string(from: record.date),
                    note: record.note,
                    value: record.value,
                    createdAt: Self.iso8601.string(from: record.date)
                )
            }
        }

        let localGroups = try context.fetch(FetchDescriptor<HabitGroup>())
        let syncGroups = localGroups.map { group in
            SyncGroup(
                id: group.id.uuidString,
                name: group.name,
                colorHex: group.colorHex,
                sortOrder: group.sortOrder,
                createdAt: Self.iso8601.string(from: group.createdAt),
                updatedAt: Self.iso8601.string(from: group.updatedAt ?? group.createdAt)
            )
        }

        let payload = SyncPushPayload(
            habits: syncHabits,
            entries: syncEntries,
            groups: syncGroups,
            deletedHabitIds: deleted.habits,
            deletedEntryIds: deleted.entries,
            deletedGroupIds: deleted.groups
        )

        try await api.pushChanges(payload)
        // Only now — the server has them. If pushChanges threw, the ids stay queued.
        queue.acknowledge(deleted)
    }

    private func pullRemote(context: ModelContext, api: APIClient) async throws {
        let response = try await api.pullChanges(since: lastSyncTime)
        // Reconciliation lives in Shared/SyncReconciler.swift so StrideTests exercises the
        // real code rather than a copy of it.
        try SyncReconciler.apply(response, to: context, isFullPull: lastSyncTime == nil)
    }
}
