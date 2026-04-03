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
    private let deletedHabitsKey = "stride_deleted_habit_ids"
    private let deletedEntriesKey = "stride_deleted_entry_ids"

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    init() {
        lastSyncTime = UserDefaults.standard.string(forKey: lastSyncKey)
    }

    // MARK: - Deletion Tracking

    /// Track a deleted habit ID for next sync push.
    func trackDeletedHabit(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: deletedHabitsKey) ?? []
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: deletedHabitsKey)
    }

    /// Track a deleted entry ID for next sync push.
    func trackDeletedEntry(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: deletedEntriesKey) ?? []
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: deletedEntriesKey)
    }

    private func consumeDeletedIds() -> (habits: [String], entries: [String]) {
        let habits = UserDefaults.standard.stringArray(forKey: deletedHabitsKey) ?? []
        let entries = UserDefaults.standard.stringArray(forKey: deletedEntriesKey) ?? []
        UserDefaults.standard.removeObject(forKey: deletedHabitsKey)
        UserDefaults.standard.removeObject(forKey: deletedEntriesKey)
        return (habits, entries)
    }

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
        let deleted = consumeDeletedIds()

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
                createdAt: Self.iso8601.string(from: habit.createdAt),
                updatedAt: Self.iso8601.string(from: Date())
            )
        }

        let syncEntries = habits.flatMap { habit in
            habit.records.map { record in
                SyncEntry(
                    id: record.id.uuidString,
                    habitId: habit.id.uuidString,
                    date: Self.dateOnly.string(from: record.date),
                    note: record.note,
                    createdAt: Self.iso8601.string(from: record.date)
                )
            }
        }

        let payload = SyncPushPayload(
            habits: syncHabits,
            entries: syncEntries,
            deletedHabitIds: deleted.habits,
            deletedEntryIds: deleted.entries
        )

        try await api.pushChanges(payload)
    }

    private func pullRemote(context: ModelContext, api: APIClient) async throws {
        let response = try await api.pullChanges(since: lastSyncTime)
        let existingHabits = try context.fetch(FetchDescriptor<Habit>())
        let habitMap = Dictionary(uniqueKeysWithValues: existingHabits.map { ($0.id.uuidString, $0) })

        for remoteHabit in response.habits {
            guard let uuid = UUID(uuidString: remoteHabit.id) else { continue }

            if let local = habitMap[remoteHabit.id] {
                local.name = remoteHabit.name
                local.emoji = remoteHabit.emoji
                local.colorHex = remoteHabit.colorHex
                local.isArchived = remoteHabit.isArchived
                local.sortOrder = Double(remoteHabit.sortOrder)
                if let re = remoteHabit.reminderEnabled { local.reminderEnabled = re }
                if let rh = remoteHabit.reminderHour { local.reminderHour = rh }
                if let rm = remoteHabit.reminderMinute { local.reminderMinute = rm }
            } else {
                let habit = Habit(name: remoteHabit.name, emoji: remoteHabit.emoji, colorHex: remoteHabit.colorHex)
                habit.id = uuid
                habit.isArchived = remoteHabit.isArchived
                habit.sortOrder = Double(remoteHabit.sortOrder)
                habit.reminderEnabled = remoteHabit.reminderEnabled ?? false
                habit.reminderHour = remoteHabit.reminderHour ?? 20
                habit.reminderMinute = remoteHabit.reminderMinute ?? 0
                if let created = Self.iso8601.date(from: remoteHabit.createdAt) {
                    habit.createdAt = created
                }
                context.insert(habit)
            }
        }

        let updatedHabits = try context.fetch(FetchDescriptor<Habit>())
        let updatedMap = Dictionary(uniqueKeysWithValues: updatedHabits.map { ($0.id.uuidString, $0) })

        for remoteEntry in response.entries {
            guard let habit = updatedMap[remoteEntry.habitId] else { continue }
            guard let entryUUID = UUID(uuidString: remoteEntry.id) else { continue }
            guard let entryDate = Self.dateOnly.date(from: remoteEntry.date) else { continue }

            let alreadyExists = habit.records.contains { record in
                Calendar.current.isDate(record.date, inSameDayAs: entryDate)
            }

            if !alreadyExists {
                let record = HabitRecord(date: entryDate)
                record.id = entryUUID
                habit.records.append(record)
            }
        }

        try context.save()
    }
}
