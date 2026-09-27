import Foundation
import SwiftData
import SwiftUI

/// Handles bidirectional sync between local SwiftData and the Stride server.
@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private(set) var isSyncing = false
    /// When this device last synced, by its own clock — shown in Settings, and nothing else.
    private(set) var lastSyncTime: String?
    private(set) var syncError: String?

    private let lastSyncKey = "stride_last_sync_time"
    /// The `?since` for the next pull (see `SyncCursor`). Deliberately a new key: until 1.2.3 the
    /// cursor was `lastSyncTime`, a device-clock value that could have skipped rows, so the
    /// first sync after updating finds no cursor and does one full pull, which brings back
    /// anything the old cursor missed.
    private let cursorKey = "stride_sync_cursor"

    // Day-only dates are serialized in UTC to match the stored day-key
    // representation (see HabitCalendar) — never the device's current zone,
    // which would shift check-ins across day boundaries after travel.
    private static let dateOnly: DateFormatter = HabitCalendar.dayStringFormatter

    private let api: APIClient
    private let defaults: UserDefaults
    private let deletionQueue: SyncDeletionQueue

    /// The defaults are exactly what `shared` used before they were parameters. StrideAppTests
    /// passes an APIClient over a stubbed URLSession, a throwaway defaults suite and a queue on
    /// it, so a test neither talks to a server nor touches the host app's cursor and queues.
    init(
        api: APIClient = .shared,
        defaults: UserDefaults = .standard,
        deletionQueue: SyncDeletionQueue = .live
    ) {
        self.api = api
        self.defaults = defaults
        self.deletionQueue = deletionQueue
        lastSyncTime = defaults.string(forKey: lastSyncKey)
    }

    // MARK: - Deletion Tracking

    // Queued in SyncDeletionQueue (Shared/) and sent with the next push. They are removed
    // only after the server accepts that push — see the type's comment for why.

    /// Track a deleted habit ID for next sync push.
    func trackDeletedHabit(_ id: String) { deletionQueue.trackHabit(id) }

    /// Track a deleted entry ID for next sync push.
    func trackDeletedEntry(_ id: String) { deletionQueue.trackEntry(id) }

    /// Track a deleted group ID for next sync push.
    func trackDeletedGroup(_ id: String) { deletionQueue.trackGroup(id) }

    /// Full sync: push local changes then pull remote changes.
    func sync(context: ModelContext) async {
        guard await api.isLoggedIn else { return }
        guard !isSyncing else { return }

        isSyncing = true
        syncError = nil

        do {
            try await pushLocal(context: context)
            let serverTime = try await pullRemote(context: context)

            if let cursor = SyncCursor.next(afterServerTime: serverTime) {
                defaults.set(cursor, forKey: cursorKey)
            } else {
                defaults.removeObject(forKey: cursorKey)   // full pull next time
            }
            let now = SyncTimestamp.string(from: Date())
            lastSyncTime = now
            defaults.set(now, forKey: lastSyncKey)
            AnalyticsService.shared.send("syncPerformed")
        } catch {
            syncError = error.localizedDescription
        }

        isSyncing = false
    }

    private func pushLocal(context: ModelContext) async throws {
        let habits = try context.fetch(FetchDescriptor<Habit>())
        let queue = deletionQueue
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
                createdAt: SyncTimestamp.string(from: habit.createdAt),
                // Truthful per-habit modification time (falls back to createdAt for
                // legacy rows) so the server can resolve multi-device conflicts as
                // last-write-wins instead of last-push-wins.
                updatedAt: SyncTimestamp.string(from: habit.updatedAt ?? habit.createdAt)
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
                    createdAt: SyncTimestamp.string(from: record.date),
                    updatedAt: SyncTimestamp.string(from: record.updatedAt ?? record.date)
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
                createdAt: SyncTimestamp.string(from: group.createdAt),
                updatedAt: SyncTimestamp.string(from: group.updatedAt ?? group.createdAt)
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

    /// Forget the cursor and last-sync time, so the next account signed in on this device starts
    /// with a full pull instead of an incremental one against the previous account's cursor.
    func resetSyncState() {
        defaults.removeObject(forKey: cursorKey)
        defaults.removeObject(forKey: lastSyncKey)
        lastSyncTime = nil
    }

    /// Returns the response's `serverTime`, from which the next cursor is taken.
    private func pullRemote(context: ModelContext) async throws -> String {
        let cursor = defaults.string(forKey: cursorKey)
        let response = try await api.pullChanges(since: cursor)
        // Reconciliation lives in Shared/SyncReconciler.swift so StrideTests exercises the
        // real code rather than a copy of it.
        try SyncReconciler.apply(response, to: context, isFullPull: cursor == nil)
        return response.serverTime
    }
}
