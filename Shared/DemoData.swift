import SwiftData
import Foundation

enum DemoData {
    @MainActor
    static func populate(container: ModelContainer) {
        let context = container.mainContext

        // Clear existing data
        try? context.delete(model: HabitRecord.self)
        try? context.delete(model: Habit.self)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let habits: [(String, String, String)] = [
            ("Morning Run", "\u{1F3C3}", "#34C759"),
            ("Read 30 min", "\u{1F4DA}", "#007AFF"),
            ("Drink Water", "\u{1F4A7}", "#FF9500"),
            ("Meditate", "\u{1F9D8}", "#AF52DE"),
            ("Journal", "\u{270D}\u{FE0F}", "#FF3B30"),
        ]

        let patterns: [[Bool]] = [
            [true, true, true, true, true],
            [true, true, true, false, true],
            [true, false, true, true, true],
            [true, true, true, true, false],
            [false, true, true, true, true],
            [true, true, true, true, true],
            [true, true, false, true, true],
            [true, true, true, true, true],
            [true, false, true, true, false],
            [true, true, true, false, true],
            [false, true, true, true, true],
            [true, true, true, true, true],
            [true, true, false, true, true],
            [true, false, true, true, false],
            [true, true, true, true, true],
        ]

        for (i, info) in habits.enumerated() {
            let habit = Habit(name: info.0, emoji: info.1, colorHex: info.2)
            habit.createdAt = calendar.date(byAdding: .second, value: i, to: calendar.date(byAdding: .day, value: -30, to: today)!)!
            context.insert(habit)

            for (dayOffset, pattern) in patterns.enumerated() {
                if pattern[i] {
                    let date = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
                    let record = HabitRecord(date: date)
                    habit.records.append(record)
                }
            }
        }

        try? context.save()
    }
}
