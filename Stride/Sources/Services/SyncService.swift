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
    private let deletedGroupsKey = "stride_deleted_group_ids"

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

    /// Track a deleted group ID for next sync push.
    func trackDeletedGroup(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: deletedGroupsKey) ?? []
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: deletedGroupsKey)
    }

    private static let widgetDeletedEntriesKey = "stride_deleted_entry_ids_widget"

    private func consumeDeletedIds() -> (habits: [String], entries: [String], groups: [String]) {
        let habits = UserDefaults.standard.stringArray(forKey: deletedHabitsKey) ?? []
        var entries = UserDefaults.standard.stringArray(forKey: deletedEntriesKey) ?? []
        let groups = UserDefaults.standard.stringArray(forKey: deletedGroupsKey) ?? []

        // Also consume deletion IDs tracked by the widget extension via shared app group
        if let groupDefaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier) {
            let widgetEntries = groupDefaults.stringArray(forKey: Self.widgetDeletedEntriesKey) ?? []
            entries.append(contentsOf: widgetEntries)
            groupDefaults.removeObject(forKey: Self.widgetDeletedEntriesKey)
        }

        UserDefaults.standard.removeObject(forKey: deletedHabitsKey)
        UserDefaults.standard.removeObject(forKey: deletedEntriesKey)
        UserDefaults.standard.removeObject(forKey: deletedGroupsKey)
        return (habits, entries, groups)
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
    }

    private func pullRemote(context: ModelContext, api: APIClient) async throws {
        let response = try await api.pullChanges(since: lastSyncTime)
        let existingHabits = try context.fetch(FetchDescriptor<Habit>())
        let habitMap = Dictionary(uniqueKeysWithValues: existingHabits.map { ($0.id.uuidString, $0) })

        // Apply remote deletions first to prevent resurrection
        let deletedHabitSet = Set(response.deletedHabitIds ?? [])
        let deletedEntrySet = Set(response.deletedEntryIds ?? [])

        for deletedId in deletedHabitSet {
            if let local = habitMap[deletedId] {
                context.delete(local)
            }
        }

        for habit in existingHabits {
            for record in habit.records where deletedEntrySet.contains(record.id.uuidString) {
                context.delete(record)
            }
        }

        // Upsert habits (skip any that were just deleted remotely)
        for remoteHabit in response.habits {
            guard !deletedHabitSet.contains(remoteHabit.id) else { continue }
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
                local.note = remoteHabit.note
                local.kind = remoteHabit.kind ?? HabitKind.binary.rawValue
                local.targetValue = remoteHabit.targetValue ?? 1
                local.unit = remoteHabit.unit
                local.scheduleKind = remoteHabit.scheduleKind ?? HabitSchedule.daily.rawValue
                local.timesPerWeek = remoteHabit.timesPerWeek ?? 7
                local.activeDaysMask = remoteHabit.activeDaysMask ?? 127
                local.groupId = remoteHabit.groupId.flatMap { UUID(uuidString: $0) }
                // Adopt the server's timestamp so applying remote state doesn't
                // make this habit look locally-modified and re-push as "newer".
                local.updatedAt = Self.iso8601.date(from: remoteHabit.updatedAt) ?? local.updatedAt
            } else {
                let habit = Habit(name: remoteHabit.name, emoji: remoteHabit.emoji, colorHex: remoteHabit.colorHex)
                habit.id = uuid
                habit.isArchived = remoteHabit.isArchived
                habit.sortOrder = Double(remoteHabit.sortOrder)
                habit.reminderEnabled = remoteHabit.reminderEnabled ?? false
                habit.reminderHour = remoteHabit.reminderHour ?? 20
                habit.reminderMinute = remoteHabit.reminderMinute ?? 0
                habit.note = remoteHabit.note
                habit.kind = remoteHabit.kind ?? HabitKind.binary.rawValue
                habit.targetValue = remoteHabit.targetValue ?? 1
                habit.unit = remoteHabit.unit
                habit.scheduleKind = remoteHabit.scheduleKind ?? HabitSchedule.daily.rawValue
                habit.timesPerWeek = remoteHabit.timesPerWeek ?? 7
                habit.activeDaysMask = remoteHabit.activeDaysMask ?? 127
                habit.groupId = remoteHabit.groupId.flatMap { UUID(uuidString: $0) }
                if let created = Self.iso8601.date(from: remoteHabit.createdAt) {
                    habit.createdAt = created
                }
                habit.updatedAt = Self.iso8601.date(from: remoteHabit.updatedAt) ?? habit.createdAt
                context.insert(habit)
            }
        }

        // On full pull (no lastSyncTime), remove local habits not present on server
        if lastSyncTime == nil {
            let remoteHabitIds = Set(response.habits.map { $0.id })
            for local in existingHabits {
                if !remoteHabitIds.contains(local.id.uuidString) && !deletedHabitSet.contains(local.id.uuidString) {
                    context.delete(local)
                }
            }
        }

        let updatedHabits = try context.fetch(FetchDescriptor<Habit>())
        let updatedMap = Dictionary(uniqueKeysWithValues: updatedHabits.map { ($0.id.uuidString, $0) })

        // Build a set of remote entry IDs for full-pull reconciliation
        let remoteEntryIds = Set(response.entries.map { $0.id })

        for remoteEntry in response.entries {
            guard !deletedEntrySet.contains(remoteEntry.id) else { continue }
            guard let habit = updatedMap[remoteEntry.habitId] else { continue }
            guard let entryUUID = UUID(uuidString: remoteEntry.id) else { continue }
            guard let entryDate = Self.dateOnly.date(from: remoteEntry.date) else { continue }

            if let existingRecord = habit.records.first(where: { HabitCalendar.utc.isDate($0.date, inSameDayAs: entryDate) }) {
                // Align local ID to server ID so full-pull reconciliation won't delete it
                existingRecord.id = entryUUID
                existingRecord.note = remoteEntry.note
                existingRecord.value = remoteEntry.value ?? 1
            } else {
                let record = HabitRecord(date: entryDate, note: remoteEntry.note, value: remoteEntry.value ?? 1)
                record.id = entryUUID
                // entryDate is already a UTC day-key parsed from the server's
                // yyyy-MM-dd; store it verbatim rather than re-deriving it from
                // the local calendar (which would shift it in non-UTC zones).
                record.date = HabitCalendar.startOfKey(entryDate)
                habit.records.append(record)
            }
        }

        // On full pull (no lastSyncTime), remove local entries not present on server.
        // Safe because we aligned local IDs to remote IDs above.
        if lastSyncTime == nil {
            for habit in updatedHabits {
                for record in habit.records {
                    if !remoteEntryIds.contains(record.id.uuidString) {
                        context.delete(record)
                    }
                }
            }
        }

        // Reconcile habit groups
        let remoteGroups = response.groups ?? []
        let deletedGroupSet = Set(response.deletedGroupIds ?? [])
        let existingGroups = try context.fetch(FetchDescriptor<HabitGroup>())
        let groupMap = Dictionary(existingGroups.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })

        for deletedId in deletedGroupSet {
            if let local = groupMap[deletedId] { context.delete(local) }
        }
        for remoteGroup in remoteGroups {
            guard !deletedGroupSet.contains(remoteGroup.id) else { continue }
            guard let uuid = UUID(uuidString: remoteGroup.id) else { continue }
            if let local = groupMap[remoteGroup.id] {
                local.name = remoteGroup.name
                local.colorHex = remoteGroup.colorHex
                local.sortOrder = remoteGroup.sortOrder
                local.updatedAt = Self.iso8601.date(from: remoteGroup.updatedAt) ?? local.updatedAt
            } else {
                let group = HabitGroup(name: remoteGroup.name, colorHex: remoteGroup.colorHex, sortOrder: remoteGroup.sortOrder)
                group.id = uuid
                if let created = Self.iso8601.date(from: remoteGroup.createdAt) { group.createdAt = created }
                group.updatedAt = Self.iso8601.date(from: remoteGroup.updatedAt) ?? group.createdAt
                context.insert(group)
            }
        }
        if lastSyncTime == nil {
            let remoteGroupIds = Set(remoteGroups.map { $0.id })
            for local in existingGroups where !remoteGroupIds.contains(local.id.uuidString) && !deletedGroupSet.contains(local.id.uuidString) {
                context.delete(local)
            }
        }

        try context.save()
    }
}
