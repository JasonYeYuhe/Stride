import Foundation

/// What the widget shows and when: one entry for now, one for the coming local midnight.
///
/// Until 1.3.0 the timeline held a single entry computed "now" with a `.after(tomorrow)`
/// policy, so the flip to a new day depended entirely on WidgetKit choosing to reload at or
/// after midnight. It is a request, not a schedule: the system budgets reloads, and a widget
/// could sit on yesterday's ticks well into the morning — every habit drawn as done, so
/// nothing invited the day's first check-in, and a tap on a row that said "done" checked it
/// rather than clearing it. Now the midnight state is already in the timeline when it is
/// handed over, and WidgetKit only has to switch entries, which it does on time. The reload
/// an hour after midnight is the safety net, not the mechanism.
///
/// Pure: it takes the instant, the calendar and plain row inputs, and reads no clock, no
/// `Calendar.current` and no store — so tests can pin it to any zone. The day arithmetic
/// itself stays in `Habit` (reached through `RowInput.status`); this file only decides which
/// habit-day each entry describes.
struct WidgetTimelinePlan {
    /// One habit as a widget row. Plain values: the view never touches a model object.
    struct Row: Identifiable, Equatable {
        // The habit's id, not a fresh UUID: a new identity per reload made an in-widget toggle
        // drop VoiceOver focus back to the top of the widget.
        var id: String { habitId }
        let habitId: String
        let name: String
        let emoji: String
        let colorHex: String
        /// Count habits add one per tap (HabitCheckIn), so they are Buttons, never Toggles.
        let isCount: Bool
        let isCompleted: Bool
        /// 0...1 toward the day's goal. A count habit at 6 of 8 must not draw as an empty
        /// circle — that is what invited the tap that used to delete its day.
        let progress: Double
        let streak: Int
        /// A times-per-week habit counts its streak in weeks ("12w", "12 week streak").
        let streakInWeeks: Bool
    }

    /// A habit's state on one habit-day.
    struct Status: Equatable {
        let isCompleted: Bool
        let progress: Double
        let streak: Int
    }

    /// Everything the plan needs about one habit. `status` is asked with a DAY-KEY (UTC
    /// midnight, see `HabitCalendar`), never a local instant: `Habit`'s methods re-key their
    /// argument with `Calendar.current`, which is idempotent on a key and zone-dependent on
    /// anything else — so passing keys is what keeps the answer independent of the machine.
    struct RowInput {
        let habitId: String
        let name: String
        let emoji: String
        let colorHex: String
        let isCount: Bool
        let streakInWeeks: Bool
        let status: (_ dayKey: Date) -> Status
    }

    struct Entry: Equatable {
        /// When WidgetKit starts showing this entry.
        let date: Date
        /// The habit-day its rows describe.
        let dayKey: Date
        let rows: [Row]

        var completedCount: Int { rows.filter(\.isCompleted).count }
        var totalCount: Int { rows.count }
    }

    /// `[entry(now), entry(next local midnight)]`.
    let entries: [Entry]
    /// The next local midnight — when the second entry takes over.
    let midnight: Date
    /// Timeline policy `.after(refreshAfter)`: midnight + 1 h, the safety net.
    let refreshAfter: Date

    static let safetyNetDelay: TimeInterval = 3600

    init(now: Date, calendar: Calendar, rows: [RowInput]) {
        let midnight = Self.nextLocalMidnight(after: now, calendar: calendar)
        let todayKey = Self.dayKey(of: now, in: calendar)
        let tomorrowKey = Self.dayKey(of: midnight, in: calendar)

        func entry(at date: Date, dayKey: Date) -> Entry {
            Entry(date: date, dayKey: dayKey, rows: rows.map { input in
                let status = input.status(dayKey)
                return Row(habitId: input.habitId, name: input.name, emoji: input.emoji,
                           colorHex: input.colorHex, isCount: input.isCount,
                           isCompleted: status.isCompleted,
                           progress: min(1, max(0, status.progress)),
                           streak: status.streak, streakInWeeks: input.streakInWeeks)
            })
        }

        self.entries = [entry(at: now, dayKey: todayKey), entry(at: midnight, dayKey: tomorrowKey)]
        self.midnight = midnight
        self.refreshAfter = midnight.addingTimeInterval(Self.safetyNetDelay)
    }

    /// The first instant of the local day after the one containing `now`.
    ///
    /// Not `now + 24 h` (a DST day is 23 or 25 hours: America/New_York 2026-11-01 is 25) and not
    /// `date(byAdding: .day)` then `startOfDay` (where local midnight does not exist — Brazil's
    /// DST started AT midnight until 2019, Cuba's still does — the result depends on the
    /// calendar's matching policy for a nonexistent time). Every civil day lasts between 23 and
    /// 25 hours, so 36 hours after the start of today always lands inside tomorrow, and
    /// `startOfDay` of that is tomorrow's first instant — 01:00 on a day with no 00:00.
    static func nextLocalMidnight(after now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.startOfDay(for: now).addingTimeInterval(36 * 3600))
    }

    /// The local Y/M/D of `instant` in `calendar`, anchored to UTC midnight — the same key
    /// `HabitCalendar.dayKey` produces for an ordinary instant.
    ///
    /// Not `HabitCalendar.dayKey(for:localCalendar:)` itself: its idempotency shortcut returns
    /// any instant that happens to BE a UTC midnight unchanged. For a real instant in a
    /// negative-offset zone that is the next day — 20:00:00 in New York in summer is
    /// 00:00:00Z tomorrow — so an entry computed at that exact second would describe tomorrow.
    static func dayKey(of instant: Date, in calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        return HabitCalendar.utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))
            ?? HabitCalendar.utc.startOfDay(for: instant)
    }

    /// How many rows a list with room for `capacity` lines shows, and how many it summarises
    /// as "+N more".
    ///
    /// The large widget used to be planned without the medium's "+N more", on the idea that
    /// eight rows is enough. It is not the common case that matters but the ninth habit: a list
    /// that silently stops at eight looks complete, so the ninth reads as lost. The count says
    /// where the rest went, and a tap on it opens the app.
    ///
    /// The overflow line replaces the last row rather than being added under it, so the list
    /// never grows past `capacity` lines — the widget's height is fixed, and a line past it is
    /// clipped off the bottom, which at larger text sizes would be the "+N more" itself.
    static func visibleRows(total: Int, capacity: Int) -> (shown: Int, more: Int) {
        guard capacity > 0 else { return (0, total) }
        guard total > capacity else { return (total, 0) }
        let shown = capacity - 1
        return (shown, total - shown)
    }
}

extension WidgetTimelinePlan.RowInput {
    /// A habit read through its own day arithmetic. The closure captures the model object, so
    /// build the plan while the context that fetched it is alive (the provider does, in one call).
    init(_ habit: Habit) {
        self.init(habitId: habit.id.uuidString,
                  name: habit.name,
                  emoji: habit.emoji,
                  colorHex: habit.colorHex,
                  isCount: habit.habitKind == .count,
                  streakInWeeks: habit.schedule == .timesPerWeek,
                  status: { dayKey in
                      WidgetTimelinePlan.Status(isCompleted: habit.isCompletedOn(dayKey),
                                                progress: habit.progress(on: dayKey),
                                                streak: habit.currentStreak(from: dayKey))
                  })
    }
}
