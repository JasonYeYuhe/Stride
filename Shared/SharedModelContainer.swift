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
        let schema = Schema([Habit.self, HabitRecord.self])
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
}
