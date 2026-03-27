import SwiftData
import Foundation

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
            fatalError("Failed to create shared ModelContainer: \(error)")
        }
    }
}
