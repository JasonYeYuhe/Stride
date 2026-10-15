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

    // MARK: - Delivery state (1.3.1; local only, never on the wire)
    // See `SyncDeliverable` in SyncDelivery.swift for what each field means and why there are
    // three of them. All optional or defaulted: a 1.3.0 store opens under this schema by
    // lightweight migration, every row "never delivered" until the migrated-rows rule runs.
    var syncedAt: Date?
    var syncHoldReason: String?
    var syncHoldStamp: Date?
    var needsResend: Bool = false
    var restoredAt: Date?

    @Relationship(deleteRule: .cascade) var records: [HabitRecord]

    init(name: String, emoji: String = "⭐", colorHex: String = "#34C759") {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        // Millisecond-floored, like touch(): createdAt is the stamp of a row never edited
        // (`stamp = updatedAt ?? createdAt`) and goes on the wire as it is stored.
        let now = SyncTimestamp.now()
        self.createdAt = now
        self.isArchived = false
        self.sortOrder = Date().timeIntervalSince1970
        self.reminderEnabled = false
        self.reminderHour = 20
        self.reminderMinute = 0
        self.note = nil
        self.updatedAt = now
        self.kind = HabitKind.binary.rawValue
        self.targetValue = 1
        self.unit = nil
        self.scheduleKind = HabitSchedule.daily.rawValue
        self.timesPerWeek = 7
        self.activeDaysMask = 127
        self.groupId = nil
        self.syncedAt = nil
        self.syncHoldReason = nil
        self.syncHoldStamp = nil
        self.needsResend = false
        self.restoredAt = nil
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
    ///
    /// Floored to the whole millisecond (1.3.1): the push sends exactly this number, so the
    /// server's acknowledgement and this device's own echo compare equal to it. The new stamp
    /// is also what makes the row pending again and lifts a sync hold — no mutation site has to
    /// know about delivery state (`SyncDeliverable`) — so it always differs from the previous
    /// one, even for two edits inside one millisecond (`SyncTimestamp.nextStamp`).
    func touch() {
        updatedAt = SyncTimestamp.nextStamp(after: stamp)
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

    // MARK: - Per-day lookups (direct: they never build a HabitStats)

    /// Whether `record` counts for this habit's per-day lookups: not deleted, and not a ghost —
    /// the record a deletion saved in this context leaves behind in `records`, with no context
    /// (HabitCheckIn.liveRecord; the same filter as SyncCopies.live). A habit that is not in a
    /// context has no store to have deleted anything from, so all its records count.
    ///
    /// A deletion saved by ANOTHER context or process still looks live here; only the store can
    /// tell (`HabitStats.liveRecords(of:)`), so the aggregates ask it and these lookups do not.
    private func countsForLookups(_ record: HabitRecord, habitHasContext: Bool) -> Bool {
        !record.isDeleted && (record.modelContext != nil || !habitHasContext)
    }

    /// The record for a given day, if any: of several on one day, the one D2 reads — the
    /// largest value, then the newest stamp (`HabitRecord.outranks`).
    func record(on date: Date) -> HabitRecord? {
        // `HabitCalendar.dayKey(for: date)` and `startOfKey(record.date)`, as whole days (exact
        // for day-keys, and no Calendar call per record).
        let day = HabitStats.dayNumber(of: date, in: .current)
        let hasContext = modelContext != nil
        var best: HabitRecord?
        for record in records
        where HabitStats.dayNumber(ofKey: record.date) == day && countsForLookups(record, habitHasContext: hasContext) {
            if let current = best, !record.outranks(current) { continue }
            best = record
        }
        return best
    }

    /// Amount logged on a day (0 if none): the day's largest value. For binary habits a check-in
    /// is 1.
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
            // Any live record checks a yes/no day, so the first one found answers: no need to
            // look on for the one `record(on:)` would pick.
            let day = HabitStats.dayNumber(of: date, in: .current)
            let hasContext = modelContext != nil
            return records.contains {
                HabitStats.dayNumber(ofKey: $0.date) == day && countsForLookups($0, habitHasContext: hasContext)
            }
        case .count:
            return loggedValue(on: date) >= targetValue && targetValue > 0
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

    // MARK: - Aggregates (each call builds one HabitStats, D2)

    /// A fresh `HabitStats` for this habit, from the live record ids its own context's store
    /// holds. `HabitStats` says what it computes and which 1.4.0 answers it fixes.
    ///
    /// **Cost, per call:** one store count over this habit's records (`HabitStats.liveRecords`;
    /// the exact set only after another context's unmerged deletion), one pass over `records`,
    /// then the aggregate asked for — measured 2026-10-15 (-Onone, a warm 730-record habit) at
    /// about 4 ms a call, against 1.4.0's 1.3 ms for `completionRate(from:to:)` and 27 ms for
    /// `currentStreak` (its Calendar walk). Views that read aggregates per render, or one per
    /// row, read the app's `StatsCache` instead (D3); code asking several questions at once
    /// builds one with this and asks it. A habit that is in no context counts every record
    /// (there is no store to ask).
    func makeStats(today: Date = Date(), calendar: Calendar = .current) -> HabitStats {
        HabitStats(habit: self, live: HabitStats.liveRecords(of: self), calendar: calendar, today: today)
    }

    /// The streak as of `referenceDate`, with the grace for an unfinished day (or week). Records
    /// dated after the real today are ignored.
    func currentStreak(from referenceDate: Date = Date()) -> Int {
        makeStats().currentStreak(asOf: referenceDate)
    }

    /// Count of completed days in the 7 days from `start` (a Monday).
    func weeklyCompletions(weekStarting start: Date) -> Int {
        makeStats().weeklyCompletions(weekStarting: start)
    }

    /// Completions in the week containing `date` (for "3/5 this week" display).
    func weeklyCompletions(containing date: Date = Date()) -> Int {
        makeStats().weeklyCompletions(containing: date)
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
        makeStats().bestStreak
    }

    /// The rate over the last `days` days ending today.
    func completionRate(days: Int = 30) -> Double {
        makeStats().completionRate(days: days)
    }

    /// Completion rate over an inclusive date range, clamped to the habit's start —
    /// min(creation day, earliest live record) (D8) — and to `now`: a day that hasn't happened
    /// yet is never counted as missed, and the rate never passes 100 %.
    ///
    /// - Daily and specific days: completed scheduled days ÷ scheduled days, so rest days don't
    ///   drag it down.
    /// - Times per week: how much of each week's goal was met ÷ the goal.
    ///
    /// The `now` clamp fixes the Pro 8-week trend, which passes each week's Sunday as the end —
    /// including the current week's, which is in the future — so the days still to come were
    /// scored as misses: a daily habit done every day showed its last bar at 14% on a Monday.
    ///
    /// The times-per-week habit used to be scored like a daily one — every day "scheduled" — so
    /// a goal of N days a week could never exceed N/7: "Run, 3 times a week", done every single
    /// week, read 43%. Completions are counted across the whole week rather than only the days
    /// inside the range because the goal belongs to the week: three runs on Mon/Wed/Fri meet it
    /// even when the range starts on that week's Saturday.
    func completionRate(from start: Date, to end: Date, now: Date = Date()) -> Double {
        makeStats(today: now).completionRate(from: start, to: end)
    }

    /// Completed days per weekday (1 = Sunday … 7 = Saturday).
    func completionsPerWeekday() -> [Int: Int] {
        makeStats().completionsPerWeekday
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

    // MARK: - Delivery state (1.3.1; local only, never on the wire)
    // See `SyncDeliverable` in SyncDelivery.swift for what each field means and why there are
    // three of them. All optional or defaulted: a 1.3.0 store opens under this schema by
    // lightweight migration, every row "never delivered" until the migrated-rows rule runs.
    var syncedAt: Date?
    var syncHoldReason: String?
    var syncHoldStamp: Date?
    var needsResend: Bool = false
    var restoredAt: Date?

    init(date: Date = Date(), note: String? = nil, value: Double = 1) {
        self.id = UUID()
        self.date = HabitCalendar.dayKey(for: date)
        self.note = note
        self.updatedAt = SyncTimestamp.now()
        self.value = value
        self.syncedAt = nil
        self.syncHoldReason = nil
        self.syncHoldStamp = nil
        self.needsResend = false
        self.restoredAt = nil
    }

    /// Millisecond-floored; see `Habit.touch()`.
    func touch() {
        updatedAt = SyncTimestamp.nextStamp(after: stamp)
    }

    /// Of two live records on one day, whether this is the one D2 reads (and 2026-10-15
    /// decision 7 keeps when it merges the day): the larger value, then the newer stamp, then —
    /// only so that every device picks the same one — the larger id.
    func outranks(_ other: HabitRecord) -> Bool {
        if value != other.value { return value > other.value }
        if stamp != other.stamp { return stamp > other.stamp }
        return id.uuidString > other.id.uuidString
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

    // MARK: - Delivery state (1.3.1; local only, never on the wire)
    // See `SyncDeliverable` in SyncDelivery.swift for what each field means and why there are
    // three of them. All optional or defaulted: a 1.3.0 store opens under this schema by
    // lightweight migration, every row "never delivered" until the migrated-rows rule runs.
    var syncedAt: Date?
    var syncHoldReason: String?
    var syncHoldStamp: Date?
    var needsResend: Bool = false
    var restoredAt: Date?

    init(name: String, colorHex: String = "#34C759", sortOrder: Double = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        let now = SyncTimestamp.now()
        self.createdAt = now
        self.updatedAt = now
        self.syncedAt = nil
        self.syncHoldReason = nil
        self.syncHoldStamp = nil
        self.needsResend = false
        self.restoredAt = nil
    }

    var color: Color {
        Color(hex: colorHex) ?? .green
    }

    /// Millisecond-floored; see `Habit.touch()`.
    func touch() {
        updatedAt = SyncTimestamp.nextStamp(after: stamp)
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
