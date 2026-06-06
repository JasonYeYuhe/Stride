import SwiftData
import Foundation
import os.log

/// Shared model container configuration for App Group data sharing between main app and widgets.
enum SharedModelContainer {
    static let appGroupIdentifier = "group.yyh.stride.habittracker"

    static var storeURL: URL {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        return containerURL.appendingPathComponent("Stride.store")
    }

    static var modelContainer: ModelContainer {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let config = ModelConfiguration(
            "Stride",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            let logger = Logger(subsystem: "yyh.stride.habittracker", category: "ModelContainer")
            logger.error("Failed to create ModelContainer at \(storeURL.path): \(error.localizedDescription). Falling back to default location — user data from App Group will not be visible.")
            do {
                return try ModelContainer(for: schema)
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }

    private static let dayKeyMigrationFlag = "stride_daykey_migration_v2_done"

    /// One-time migration: re-anchor legacy records (stored as *local* midnight)
    /// to UTC-anchored day-keys (see `HabitCalendar`). Idempotent — records that
    /// are already a UTC midnight day-key are skipped, so re-running (or a
    /// UTC-zone user, whose local midnight already equals the key) is safe.
    /// Assumes the device's current time zone matches the record's creation zone,
    /// which holds for any user who hasn't traveled between logging and upgrading.
    static func migrateRecordDayKeysIfNeeded(_ container: ModelContainer) {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard !defaults.bool(forKey: dayKeyMigrationFlag) else { return }

        let context = ModelContext(container)
        do {
            let records = try context.fetch(FetchDescriptor<HabitRecord>())
            var changed = 0
            for record in records where !HabitCalendar.isDayKey(record.date) {
                record.date = HabitCalendar.dayKey(for: record.date)
                changed += 1
            }
            if changed > 0 { try context.save() }
            defaults.set(true, forKey: dayKeyMigrationFlag)
        } catch {
            // Leave the flag unset to retry next launch; the idempotent guard
            // above keeps a partial run safe.
            Logger(subsystem: "yyh.stride.habittracker", category: "Migration")
                .error("Day-key migration failed: \(error.localizedDescription)")
        }
    }
}
