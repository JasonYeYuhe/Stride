import AppIntents
import SwiftData
import Foundation
import WidgetKit

// MARK: - The store

/// The store these intents read and write: the one the app's launch opened. They run in the
/// app's own process, after `StrideApp.init`, so they never open the store themselves — that
/// built a container per invocation (see `SharedModelContainer.opened`), and an open here could
/// migrate the store or, after a failed launch open, reach a different one (upgrade race, E2E
/// U123). When the launch could not open it, they say so and touch nothing.
private enum IntentStore {
    static var container: ModelContainer? { SharedModelContainer.opened }

    static var unavailable: String { String(localized: "Stride couldn't open your data") }
}

// MARK: - Habit Name Provider

struct HabitNameProvider: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        guard let container = IntentStore.container else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate { !$0.isArchived }
        )
        let habits = try context.fetch(descriptor)
        return habits.map(\.name).sorted()
    }
}

// MARK: - Complete Habit Intent

struct CompleteHabitIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Habit"
    static var description: IntentDescription = "Mark a habit as completed for today."

    @Parameter(title: "Habit Name", optionsProvider: HabitNameProvider())
    var habitName: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = IntentStore.container else { return .result(value: IntentStore.unavailable) }
        let context = ModelContext(container)
        let searchName = habitName
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate<Habit> { habit in
                habit.name == searchName && !habit.isArchived
            }
        )

        guard let habit = try context.fetch(descriptor).first else {
            return .result(value: String(localized: "Could not find habit \"\(habitName)\"."))
        }

        // Used to append a new record whenever the habit was not yet complete, so a partially
        // logged count habit gained a second record for the same day. markDone adds to the
        // day's existing record and never un-checks anything.
        guard let result = HabitCheckIn.markDone(habit, on: Date(), in: context) else {
            return .result(value: String(localized: "\(habit.emoji) \(habit.name) is already completed today."))
        }
        try context.save()

        NotificationCenter.default.post(name: .habitDataChanged, object: nil)
        WidgetCenter.shared.reloadAllTimelines()

        if habit.habitKind == .count && !result.isCompleted {
            let unit = habit.unit.map { " \($0)" } ?? ""
            return .result(value: String(localized: "Logged \(habit.emoji) \(habit.name): \(Self.amount(result.loggedValue)) of \(Self.amount(habit.targetValue))\(unit)."))
        }
        return .result(value: String(localized: "Completed \(habit.emoji) \(habit.name)!"))
    }

    /// `SafeNumber`, not `String(Int(value))`, which trapped on a synced 1e19 or infinity.
    private static func amount(_ value: Double) -> String { SafeNumber.amount(value) }
}

// MARK: - Check Streak Intent

struct CheckStreakIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Habit Streak"
    static var description: IntentDescription = "Check the current streak for a habit."

    @Parameter(title: "Habit Name", optionsProvider: HabitNameProvider())
    var habitName: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = IntentStore.container else { return .result(value: IntentStore.unavailable) }
        let context = ModelContext(container)
        let searchName = habitName
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate<Habit> { habit in
                habit.name == searchName && !habit.isArchived
            }
        )

        guard let habit = try context.fetch(descriptor).first else {
            return .result(value: String(localized: "Could not find habit \"\(habitName)\"."))
        }

        let streak = habit.currentStreak()
        // A times-per-week habit's streak is in weeks; this always said "days". One key per unit,
        // matching the Today screen, so the unit is translated rather than spliced in as English.
        return .result(value: habit.streakUnit == "week"
            ? String(localized: "\(habit.emoji) \(habit.name): \(streak) week streak")
            : String(localized: "\(habit.emoji) \(habit.name): \(streak) day streak"))
    }
}

// MARK: - List Habits Intent

struct ListHabitsIntent: AppIntent {
    static var title: LocalizedStringResource = "List My Habits"
    static var description: IntentDescription = "List all active habits with today's status."

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = IntentStore.container else { return .result(value: IntentStore.unavailable) }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate { !$0.isArchived }
        )
        let habits = try context.fetch(descriptor)

        if habits.isEmpty {
            return .result(value: String(localized: "No active habits yet."))
        }

        let today = Calendar.current.startOfDay(for: Date())
        let lines = habits.sorted { $0.name < $1.name }.map { habit in
            let status = habit.isCompletedOn(today) ? String(localized: "done") : String(localized: "not done")
            return "\(habit.emoji) \(habit.name) — \(status)"
        }

        return .result(value: lines.joined(separator: "\n"))
    }
}

// MARK: - App Shortcuts Provider

struct StrideShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompleteHabitIntent(),
            phrases: [
                "Complete habit in \(.applicationName)",
                "Log habit in \(.applicationName)",
                "Mark habit done in \(.applicationName)"
            ],
            shortTitle: "Complete Habit",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: CheckStreakIntent(),
            phrases: [
                "Check streak in \(.applicationName)",
                "How's my streak in \(.applicationName)",
                "Habit streak in \(.applicationName)"
            ],
            shortTitle: "Check Streak",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: ListHabitsIntent(),
            phrases: [
                "List habits in \(.applicationName)",
                "Show my habits in \(.applicationName)"
            ],
            shortTitle: "List Habits",
            systemImageName: "list.bullet"
        )
    }
}
