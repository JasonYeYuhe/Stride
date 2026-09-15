import Foundation
import SwiftData

/// Applies a `/v1/sync/pull` response to the local store.
///
/// This is the body of `SyncService.pullRemote` minus the network call, moved into Shared/
/// so StrideTests can run the real thing. It used to be tested through a copy pasted into
/// the test file, which is how the two bugs below stayed green.
///
/// 1. Ids were compared as raw strings. Swift's `UUID.uuidString` is UPPERCASE; the server
///    generates ids with Node's `crypto.randomUUID()`, which is lowercase (seed-demo.js,
///    routes/habits.js). Every map lookup and set membership therefore missed server-made
///    ids: pulled entries found no habit and were dropped, and a full pull then deleted
///    every local record because none of the local ids appeared in the server's set. Habits
///    survived only because their upsert happened to parse through `UUID(uuidString:)`,
///    which is case-insensitive — so they showed up with no history. The app itself only
///    ever sends uppercase ids, which means the one account guaranteed to hit this is the
///    App Review demo account, seeded server-side: a reviewer would see six habits with
///    0-day streaks and empty calendars.
/// 2. The habit maps were built with `Dictionary(uniqueKeysWithValues:)`, which traps on a
///    duplicate key. `Habit.id` has no uniqueness constraint, and bug 1 produced duplicates
///    (a lowercase id missed the map and inserted a second habit with the same UUID), so the
///    second sync crashed — inside the launch sync, i.e. on every launch.
///
/// Every id is now compared through `canonicalID`, maps use `uniquingKeysWith:`, and an
/// inserted habit or group is registered in its map so the same id appearing twice in one
/// response updates the row instead of inserting another.
@MainActor
enum SyncReconciler {
    /// The one form ids are compared in: the uppercase `uuidString` of the parsed UUID.
    /// A string that is not a UUID is upper-cased so it still compares consistently.
    static func canonicalID(_ raw: String) -> String {
        UUID(uuidString: raw)?.uuidString ?? raw.uppercased()
    }

    private static let iso8601 = ISO8601DateFormatter()

    // Day-only dates are UTC day-keys, matching the stored representation (HabitCalendar).
    private static let dateOnly: DateFormatter = HabitCalendar.dayStringFormatter

    static func apply(_ response: SyncPullResponse, to context: ModelContext, isFullPull: Bool) throws {
        let existingHabits = try context.fetch(FetchDescriptor<Habit>())
        var habitMap = Dictionary(existingHabits.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

        // Apply remote deletions first to prevent resurrection
        let deletedHabitSet = Set((response.deletedHabitIds ?? []).map(canonicalID))
        let deletedEntrySet = Set((response.deletedEntryIds ?? []).map(canonicalID))

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
            guard let uuid = UUID(uuidString: remoteHabit.id) else { continue }
            let key = uuid.uuidString
            guard !deletedHabitSet.contains(key) else { continue }

            if let local = habitMap[key] {
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
                local.updatedAt = iso8601.date(from: remoteHabit.updatedAt) ?? local.updatedAt
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
                if let created = iso8601.date(from: remoteHabit.createdAt) {
                    habit.createdAt = created
                }
                habit.updatedAt = iso8601.date(from: remoteHabit.updatedAt) ?? habit.createdAt
                context.insert(habit)
                // Register it: the same id appearing again in this response, in either
                // case, must update this row rather than insert a second one.
                habitMap[key] = habit
            }
        }

        // On full pull, remove local habits not present on server
        if isFullPull {
            let remoteHabitIds = Set(response.habits.map { canonicalID($0.id) })
            for local in existingHabits {
                let key = local.id.uuidString
                if !remoteHabitIds.contains(key) && !deletedHabitSet.contains(key) {
                    context.delete(local)
                }
            }
        }

        let updatedHabits = try context.fetch(FetchDescriptor<Habit>())
        let updatedMap = Dictionary(updatedHabits.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

        // Build a set of remote entry IDs for full-pull reconciliation
        let remoteEntryIds = Set(response.entries.map { canonicalID($0.id) })

        for remoteEntry in response.entries {
            guard let entryUUID = UUID(uuidString: remoteEntry.id) else { continue }
            guard !deletedEntrySet.contains(entryUUID.uuidString) else { continue }
            guard let habit = updatedMap[canonicalID(remoteEntry.habitId)] else { continue }
            guard let entryDate = dateOnly.date(from: remoteEntry.date) else { continue }

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

        // On full pull, remove local entries not present on server.
        // Safe because we aligned local IDs to remote IDs above.
        if isFullPull {
            for habit in updatedHabits {
                for record in habit.records where !remoteEntryIds.contains(record.id.uuidString) {
                    context.delete(record)
                }
            }
        }

        // Reconcile habit groups
        let remoteGroups = response.groups ?? []
        let deletedGroupSet = Set((response.deletedGroupIds ?? []).map(canonicalID))
        let existingGroups = try context.fetch(FetchDescriptor<HabitGroup>())
        var groupMap = Dictionary(existingGroups.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

        for deletedId in deletedGroupSet {
            if let local = groupMap[deletedId] { context.delete(local) }
        }
        for remoteGroup in remoteGroups {
            guard let uuid = UUID(uuidString: remoteGroup.id) else { continue }
            let key = uuid.uuidString
            guard !deletedGroupSet.contains(key) else { continue }
            if let local = groupMap[key] {
                local.name = remoteGroup.name
                local.colorHex = remoteGroup.colorHex
                local.sortOrder = remoteGroup.sortOrder
                local.updatedAt = iso8601.date(from: remoteGroup.updatedAt) ?? local.updatedAt
            } else {
                let group = HabitGroup(name: remoteGroup.name, colorHex: remoteGroup.colorHex, sortOrder: remoteGroup.sortOrder)
                group.id = uuid
                if let created = iso8601.date(from: remoteGroup.createdAt) { group.createdAt = created }
                group.updatedAt = iso8601.date(from: remoteGroup.updatedAt) ?? group.createdAt
                context.insert(group)
                groupMap[key] = group
            }
        }
        if isFullPull {
            let remoteGroupIds = Set(remoteGroups.map { canonicalID($0.id) })
            for local in existingGroups where !remoteGroupIds.contains(local.id.uuidString) && !deletedGroupSet.contains(local.id.uuidString) {
                context.delete(local)
            }
        }

        try context.save()
    }
}
