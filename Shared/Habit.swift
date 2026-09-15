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

    /// Longest run ever, by the same rules as `currentStreak`: in weeks for a times-per-week
    /// habit; otherwise in days, where a day the habit isn't scheduled neither counts nor breaks
    /// the run. So it can never be smaller than the current streak shown beside it.
    ///
    /// It used to count only literally consecutive completed calendar days, ignoring both the
    /// schedule and the week unit. A Mon/Wed/Fri habit never missed for six weeks read "Best Streak
    /// 1" next to "Current Streak 18 days", and a 3-times-a-week habit had its best counted in days
    /// while its current streak was in weeks.
    func bestStreak() -> Int {
        if schedule == .timesPerWeek { return bestWeeklyStreak() }

        let calendar = HabitCalendar.utc
        let completed = completedDayKeys()
        guard let first = completed.min(), let last = completed.max() else { return 0 }

        var best = 0
        var run = 0
        var day = first
        while day <= last {
            if isScheduled(on: day) {
                if completed.contains(day) {
                    run += 1
                    best = max(best, run)
                } else {
                    run = 0
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return best
    }

    private func bestWeeklyStreak() -> Int {
        let cal = HabitCalendar.utc
        let completed = completedDayKeys()
        guard let first = completed.min(), let last = completed.max() else { return 0 }
        let target = max(1, timesPerWeek)

        var best = 0
        var run = 0
        var week = weekStart(for: first)
        let lastWeek = weekStart(for: last)
        while week <= lastWeek {
            if weeklyCompletions(weekStarting: week) >= target {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
            guard let next = cal.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return best
    }

    func completionRate(days: Int = 30) -> Double {
        let calendar = HabitCalendar.utc
        let today = HabitCalendar.dayKey(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return 0 }
        return completionRate(from: startDate, to: today)
    }

    /// Completion rate over an inclusive date range, clamped to the habit's creation date and to
    /// `now` — a day that hasn't happened yet is never counted as missed.
    ///
    /// - Daily and specific days: completed scheduled days ÷ scheduled days, so rest days don't
    ///   drag it down.
    /// - Times per week: how much of each week's goal was met ÷ the goal. See `weeklyGoalRate`.
    ///
    /// The `now` clamp fixes the Pro 8-week trend, which passes each week's Sunday as the end —
    /// including the current week's, which is in the future — so the days still to come were
    /// scored as misses: a daily habit done every day showed its last bar at 14% on a Monday.
    func completionRate(from start: Date, to end: Date, now: Date = Date()) -> Double {
        let calendar = HabitCalendar.utc
        let endKey = min(HabitCalendar.dayKey(for: end), HabitCalendar.dayKey(for: now))
        let startKey = HabitCalendar.dayKey(for: start)
        let creationDate = HabitCalendar.dayKey(for: createdAt)
        let effectiveStart = max(startKey, creationDate)
        guard effectiveStart <= endKey else { return 0 }

        if schedule == .timesPerWeek {
            return weeklyGoalRate(from: effectiveStart, to: endKey)
        }

        var expectedDays = 0
        var day = effectiveStart
        while day <= endKey {
            if isScheduled(on: day) { expectedDays += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard expectedDays > 0 else { return 0 }

        let completedDays = completedDayKeys().filter { $0 >= effectiveStart && $0 <= endKey && isScheduled(on: $0) }.count
        return Double(completedDays) / Double(expectedDays)
    }

    /// The rate for a times-per-week goal: for each Monday-anchored week the range touches, the
    /// share of the goal that falls inside the range is expected, and the week's completions (up to
    /// the end of the range) are credited against it, capped at that share.
    ///
    /// This habit used to be scored like a daily one — every day "scheduled" — so a goal of N days
    /// a week could never exceed N/7: "Run, 3 times a week", done every single week, read 43%.
    /// Completions are counted across the whole week rather than only the days inside the range
    /// because the goal belongs to the week: three runs on Mon/Wed/Fri meet it even when the range
    /// starts on that week's Saturday.
    private func weeklyGoalRate(from startKey: Date, to endKey: Date) -> Double {
        let cal = HabitCalendar.utc
        let goal = Double(max(1, timesPerWeek))
        let completed = completedDayKeys()

        var earned = 0.0
        var expected = 0.0
        var week = weekStart(for: startKey)
        while week <= endKey {
            guard let weekEnd = cal.date(byAdding: .day, value: 6, to: week) else { break }
            let first = max(week, startKey)
            let last = min(weekEnd, endKey)
            let daysInRange = (cal.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            let share = goal * Double(daysInRange) / 7
            let done = Double(completed.filter { $0 >= week && $0 <= last }.count)
            earned += min(done, share)
            expected += share
            guard let next = cal.date(byAdding: .day, value: 7, to: week) else { break }
            week = next
        }
        return expected > 0 ? earned / expected : 0
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
