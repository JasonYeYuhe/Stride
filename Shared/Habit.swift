import Foundation
import SwiftData
import SwiftUI

@Model
final class Habit {
    var id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var createdAt: Date
    var isArchived: Bool
    var sortOrder: Double
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var note: String?
    @Relationship(deleteRule: .cascade) var records: [HabitRecord]

    init(name: String, emoji: String = "⭐", colorHex: String = "#34C759") {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.createdAt = Date()
        self.isArchived = false
        self.sortOrder = Date().timeIntervalSince1970
        self.reminderEnabled = false
        self.reminderHour = 20
        self.reminderMinute = 0
        self.note = nil
        self.records = []
    }

    var color: Color {
        Color(hex: colorHex) ?? .green
    }

    var reminderTimeDate: Date {
        get {
            var components = DateComponents()
            components.hour = reminderHour
            components.minute = reminderMinute
            return Calendar.current.date(from: components) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderHour = components.hour ?? 20
            reminderMinute = components.minute ?? 0
        }
    }

    func isCompletedOn(_ date: Date) -> Bool {
        let calendar = Calendar.current
        return records.contains { calendar.isDate($0.date, inSameDayAs: date) }
    }

    func currentStreak(from referenceDate: Date = Date()) -> Int {
        let calendar = Calendar.current
        let sortedDates = Set(records.map { calendar.startOfDay(for: $0.date) })

        guard !sortedDates.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: referenceDate)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }

        guard sortedDates.contains(today) || sortedDates.contains(yesterday) else { return 0 }

        var streak = 0
        var checkDate = sortedDates.contains(today) ? today : yesterday

        while sortedDates.contains(checkDate) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }

        return streak
    }

    func bestStreak() -> Int {
        let calendar = Calendar.current
        let sortedDates = records.map { calendar.startOfDay(for: $0.date) }
            .sorted()

        guard !sortedDates.isEmpty else { return 0 }

        var best = 1
        var current = 1

        for i in 1..<sortedDates.count {
            guard let expected = calendar.date(byAdding: .day, value: 1, to: sortedDates[i - 1]) else { continue }
            if calendar.isDate(sortedDates[i], inSameDayAs: expected) {
                current += 1
                best = max(best, current)
            } else if !calendar.isDate(sortedDates[i], inSameDayAs: sortedDates[i - 1]) {
                current = 1
            }
        }

        return best
    }

    func completionRate(days: Int = 30) -> Double {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return 0 }
        let creationDate = calendar.startOfDay(for: createdAt)
        let effectiveStart = max(startDate, creationDate)

        guard let totalDays = calendar.dateComponents([.day], from: effectiveStart, to: today).day.map({ $0 + 1 }),
              totalDays > 0 else { return 0 }

        let completedDays = records.filter { record in
            let recordDate = calendar.startOfDay(for: record.date)
            return recordDate >= effectiveStart && recordDate <= today
        }.count

        return Double(completedDays) / Double(totalDays)
    }

    func completionsPerWeekday() -> [Int: Int] {
        let calendar = Calendar.current
        var counts: [Int: Int] = [:]
        for record in records {
            let weekday = calendar.component(.weekday, from: record.date)
            counts[weekday, default: 0] += 1
        }
        return counts
    }
}

@Model
final class HabitRecord {
    var id: UUID
    var date: Date
    var note: String?

    init(date: Date = Date(), note: String? = nil) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.note = note
    }
}
