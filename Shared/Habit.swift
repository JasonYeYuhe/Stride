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
    /// Last time this habit's own fields were modified. Optional so existing
    /// (pre-v2) stores migrate with no default; treated as `createdAt` when nil.
    /// Drives correct multi-device last-write-wins on sync.
    var updatedAt: Date?

    // MARK: - v2 fields (all defaulted for lightweight SwiftData migration)

    /// "binary" (done/not-done) or "count" (quantitative, e.g. 8 glasses).
    var kind: String = HabitKind.binary.rawValue
    /// Daily target for count habits (e.g. 8). Ignored for binary.
    var targetValue: Double = 1
    /// Unit label for count habits, e.g. "glasses", "min", "km".
    var unit: String?
    /// "daily", "timesPerWeek", or "specificDays".
    var scheduleKind: String = HabitSchedule.daily.rawValue
    /// Weekly target count when scheduleKind == "timesPerWeek".
    var timesPerWeek: Int = 7
    /// Bitmask of active weekdays (bit 0 = Sunday … bit 6 = Saturday) when
    /// scheduleKind == "specificDays". 127 = every day.
    var activeDaysMask: Int = 127
    /// Optional grouping. Stored as the group's UUID; nil = ungrouped.
    var groupId: UUID?

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
        self.updatedAt = Date()
        self.kind = HabitKind.binary.rawValue
        self.targetValue = 1
        self.unit = nil
        self.scheduleKind = HabitSchedule.daily.rawValue
        self.timesPerWeek = 7
        self.activeDaysMask = 127
        self.groupId = nil
        self.records = []
    }

    // MARK: - v2 typed accessors

    var habitKind: HabitKind {
        get { HabitKind(rawValue: kind) ?? .binary }
        set { kind = newValue.rawValue }
    }

    var schedule: HabitSchedule {
        get { HabitSchedule(rawValue: scheduleKind) ?? .daily }
        set { scheduleKind = newValue.rawValue }
    }

    /// Stamp `updatedAt = now` after modifying this habit's own fields, so sync
    /// can resolve conflicts in favor of the most recent real edit.
    func touch() {
        updatedAt = Date()
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

    /// The record for a given day, if any.
    func record(on date: Date) -> HabitRecord? {
        records.first { HabitCalendar.record($0.date, isOnSameDayAs: date) }
    }

    /// Amount logged on a day (0 if none). For binary habits a check-in is 1.
    func loggedValue(on date: Date) -> Double {
        record(on: date)?.value ?? 0
    }

    /// Progress toward the day's goal, clamped to 0...1.
    func progress(on date: Date) -> Double {
        switch habitKind {
        case .binary:
            return isCompletedOn(date) ? 1 : 0
        case .count:
            guard targetValue > 0 else { return loggedValue(on: date) > 0 ? 1 : 0 }
            return min(1, loggedValue(on: date) / targetValue)
        }
    }

    func isCompletedOn(_ date: Date) -> Bool {
        switch habitKind {
        case .binary:
            return record(on: date) != nil
        case .count:
            return loggedValue(on: date) >= targetValue && targetValue > 0
        }
    }

    /// Day-keys that count as "completed" for streak/rate purposes — for count
    /// habits only days that met the target qualify.
    private func completedDayKeys() -> Set<Date> {
        switch habitKind {
        case .binary:
            return Set(records.map { HabitCalendar.startOfKey($0.date) })
        case .count:
            return Set(records.filter { $0.value >= targetValue && targetValue > 0 }
                .map { HabitCalendar.startOfKey($0.date) })
        }
    }

    /// Whether the habit is expected on a given day (rest days for `specificDays`
    /// don't count toward — or break — the streak).
    func isScheduled(on date: Date) -> Bool {
        switch schedule {
        case .daily, .timesPerWeek:
            return true
        case .specificDays:
            let weekday = HabitCalendar.utc.component(.weekday, from: HabitCalendar.dayKey(for: date)) // 1=Sun…7=Sat
            return (activeDaysMask & (1 << (weekday - 1))) != 0
        }
    }

    /// Unit label for the current streak ("day" for daily/specificDays, "week" for timesPerWeek).
    var streakUnit: String { schedule == .timesPerWeek ? "week" : "day" }

    func currentStreak(from referenceDate: Date = Date()) -> Int {
        if schedule == .timesPerWeek { return currentWeeklyStreak(from: referenceDate) }

        let calendar = HabitCalendar.utc
        let completed = completedDayKeys()
        guard !completed.isEmpty, let earliest = completed.min() else { return 0 }

        let today = HabitCalendar.dayKey(for: referenceDate)
        var day = today
        // Grace: if today isn't done yet, evaluate the streak ending yesterday.
        if !completed.contains(day) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }

        var streak = 0
        while day >= earliest {
            if isScheduled(on: day) {
                if completed.contains(day) {
                    streak += 1
                } else {
                    break // a scheduled day that's incomplete ends the streak
                }
            }
            // unscheduled (rest) days are skipped — they neither count nor break
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    // MARK: - Weekly (timesPerWeek) helpers

    /// Monday-anchored start (as a day-key) of the week containing `date`.
    private func weekStart(for date: Date) -> Date {
        let cal = HabitCalendar.utc
        let key = HabitCalendar.dayKey(for: date)
        let weekday = cal.component(.weekday, from: key) // 1=Sun…7=Sat
        let daysFromMonday = (weekday + 5) % 7           // Mon→0, Sun→6
        return cal.date(byAdding: .day, value: -daysFromMonday, to: key) ?? key
    }

    /// Count of completed days in the week starting at `start`.
    func weeklyCompletions(weekStarting start: Date) -> Int {
        let cal = HabitCalendar.utc
        guard let end = cal.date(byAdding: .day, value: 6, to: start) else { return 0 }
        return completedDayKeys().filter { $0 >= start && $0 <= end }.count
    }

    /// Completions in the week containing `date` (for "3/5 this week" display).
    func weeklyCompletions(containing date: Date = Date()) -> Int {
        weeklyCompletions(weekStarting: weekStart(for: date))
    }

    private func currentWeeklyStreak(from referenceDate: Date) -> Int {
        let cal = HabitCalendar.utc
        let completed = completedDayKeys()
        guard !completed.isEmpty, let earliest = completed.min() else { return 0 }
        let target = max(1, timesPerWeek)
        let earliestWeek = weekStart(for: earliest)

        var week = weekStart(for: referenceDate)
        // Grace: the current (in-progress) week not yet meeting target doesn't break the streak.
        if weeklyCompletions(weekStarting: week) < target {
            guard let prev = cal.date(byAdding: .day, value: -7, to: week) else { return 0 }
            week = prev
        }

        var streak = 0
        while week >= earliestWeek {
            if weeklyCompletions(weekStarting: week) >= target {
                streak += 1
            } else {
                break
            }
            guard let prev = cal.date(byAdding: .day, value: -7, to: week) else { break }
            week = prev
        }
        return streak
    }

    func bestStreak() -> Int {
        let calendar = HabitCalendar.utc
        let sortedDates = completedDayKeys().sorted()

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
        let calendar = HabitCalendar.utc
        let today = HabitCalendar.dayKey(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return 0 }
        let creationDate = HabitCalendar.dayKey(for: createdAt)
        let effectiveStart = max(startDate, creationDate)

        // Denominator = scheduled (expected) days in the window, so rest days
        // for specificDays habits don't drag the rate down.
        var expectedDays = 0
        var day = effectiveStart
        while day <= today {
            if isScheduled(on: day) { expectedDays += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard expectedDays > 0 else { return 0 }

        let completedDays = completedDayKeys().filter { $0 >= effectiveStart && $0 <= today && isScheduled(on: $0) }.count

        return Double(completedDays) / Double(expectedDays)
    }

    func completionsPerWeekday() -> [Int: Int] {
        let calendar = HabitCalendar.utc
        var counts: [Int: Int] = [:]
        for record in records {
            let weekday = calendar.component(.weekday, from: HabitCalendar.startOfKey(record.date))
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
    /// Last modification time (e.g. note edited). Optional for migration safety.
    var updatedAt: Date?
    /// Amount logged for the day. For binary habits this is always 1 (a check-in);
    /// for count habits it accumulates toward the habit's `targetValue`.
    var value: Double = 1

    init(date: Date = Date(), note: String? = nil, value: Double = 1) {
        self.id = UUID()
        self.date = HabitCalendar.dayKey(for: date)
        self.note = note
        self.updatedAt = Date()
        self.value = value
    }

    func touch() {
        updatedAt = Date()
    }
}

/// A user-defined grouping for habits (e.g. "Health", "Work").
@Model
final class HabitGroup {
    var id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Double
    var createdAt: Date
    var updatedAt: Date?

    init(name: String, colorHex: String = "#34C759", sortOrder: Double = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var color: Color {
        Color(hex: colorHex) ?? .green
    }

    func touch() {
        updatedAt = Date()
    }
}

// MARK: - v2 enums

enum HabitKind: String, CaseIterable {
    case binary
    case count
}

enum HabitSchedule: String, CaseIterable {
    case daily
    case timesPerWeek
    case specificDays
}
