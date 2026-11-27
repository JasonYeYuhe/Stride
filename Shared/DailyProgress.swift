import Foundation

/// One rule for every daily surface (RELEASE-1.5.0.md D1): what one habit is on one day, and what
/// a day adds up to — Today's card ("done/due", "Perfect day!", "Rest day"), the badge and the
/// Dock (`remaining`), the widget's entries (each for its own day-key), the Weekly Review's
/// perfect days and `WeeklyReviewMath.isAtRisk`'s "scheduled today and not done". Before 1.5.0
/// they used two code paths (the badge scanned records with `Habit.isCompletedOn`, Today and the
/// widget read `HabitStats`) and none read a schedule, so a rest day counted as remaining on five
/// surfaces (RELEASE-1.5.0.md, Spec corrections, D17).
///
/// **Inputs.** A habit's `HabitStats` and a day-key: UTC midnight, as `HabitStats` numbers days.
/// "Today" is `today(now:calendar:)` (`HabitCalendar.dayKey(forInstant:)`), or a widget entry's
/// own key (`WidgetTimelinePlan.dayKey(of:in:)`) — never `HabitCalendar.dayKey(for:)` on a live
/// instant: 20:00 EDT is exactly 00:00Z of the next date, which that function takes for an
/// already-made key (HabitCalendar's own note). A day-key is read by `HabitStats.dayNumber(ofKey:)`
/// alone, so no calendar is needed after keying and a key is the day it names in every zone.
/// Archived habits are never passed in: the caller filters them, as every surface already does.
///
/// **What "done" is.** `HabitStats.isCompleted(on:)`: a binary habit with a live record that day; a
/// count habit whose largest live value that day reaches its target. A target of 0 is never done
/// (HabitStats builds no completed day for it), so the widget no longer draws a full ring for it.
///
/// Shared/ rules (as `WeeklyReviewMath`, `HabitStats`): pure values, no SwiftUI, no SwiftData
/// fetch, no user-facing text, no `appCalendar`; compiles into the app, the widget extension and
/// the scripts that compile Shared/.
struct DailyProgress: Equatable {

    // MARK: One habit, one day

    /// What one habit is on one day (D1).
    enum State: Equatable, Hashable, CaseIterable {
        /// Done that day: a check-in (a count habit: its target reached). Also on a specific-days
        /// rest day or a times-per-week day after the goal was met — a check-in is always "done",
        /// and it counts in `done` and in `due` alike, so the ratio never passes 1.
        case done
        /// Expected that day and still open: daily, a specific-days scheduled day, or a
        /// times-per-week day while the Monday week's goal is not reached.
        case due
        /// A specific-days off-day without a check-in.
        case rest
        /// Times-per-week: what the Monday week owes was reached by that day
        /// (`WeeklyReviewMath.WeekGoal.owed == 0`: the whole goal, or in the week the habit
        /// started, its share) and the day has no check-in of its own. `owed`, not `remaining`, so
        /// the badge and the row agree: a row that prints nothing more owed is never counted as
        /// remaining (integrator's call on V1's open point 4, 2026-11-27).
        case metForWeek
        /// The day is before the habit's `startDay` (min of its creation day and its earliest live
        /// record): it did not exist yet.
        case notStarted

        /// Whether the day asks something of the habit: `.done` and `.due` count in `due`.
        var counts: Bool { self == .done || self == .due }
    }

    /// The state of the habit `stats` describes on `dayKey` (a day-key, see the type's note).
    ///
    /// In this order: before `startDay` → `.notStarted`; done → `.done`; a specific-days rest day →
    /// `.rest`; times-per-week whose Monday week owes nothing more by `dayKey`
    /// (`WeeklyReviewMath.weekGoal(of:on:)`'s `owed`, check-ins from the Monday through `dayKey`) →
    /// `.metForWeek`; otherwise `.due`.
    ///
    /// A day after the day `stats` was built for has no check-in yet (HabitStats ignores records
    /// dated after its `today`), so it reads `.due` unless it is a rest day, a met week or before
    /// the start: what the widget's next-midnight entry shows. Build `stats` through that day
    /// (`WidgetTimelinePlan.lastDayKey`) when its check-ins should count.
    static func state(of stats: HabitStats, on dayKey: Date) -> State {
        let day = HabitStats.dayNumber(ofKey: dayKey)
        let key = HabitStats.key(ofDay: day)
        if day < HabitStats.dayNumber(ofKey: stats.startDay) { return .notStarted }
        if stats.isCompleted(on: key) { return .done }
        if !stats.isScheduled(on: key) { return .rest }
        if stats.schedule == .timesPerWeek, WeeklyReviewMath.weekGoal(of: stats, on: key)?.owed == 0 {
            return .metForWeek
        }
        return .due
    }

    /// `now`'s local date in `calendar` as a day-key (`HabitCalendar.dayKey(forInstant:)`): the
    /// "today" every daily surface asks about. The same day `WeeklyReviewMath.today(now:calendar:)`
    /// reads; an exact UTC midnight (16:00 PST, 20:00 EDT) is still the local date it falls on.
    static func today(now: Date, calendar: Calendar) -> Date {
        HabitCalendar.dayKey(forInstant: now, calendar: calendar)
    }

    // MARK: One day, every habit

    /// Habits done that day (`.done`), whether or not the day was due: a check-in on a rest day or
    /// after a met week still counts, in `due` too.
    let done: Int
    /// `done` + the habits still open (`.due`). Rest days, met weeks and habits not started are in
    /// neither.
    let due: Int

    /// The habits still open that day: the badge, the Dock, the widget's "N left".
    var remaining: Int { due - done }

    /// Every habit due that day is done, and at least one was due. A day with nothing due is not a
    /// perfect day: Today reads "Rest day", the badge and the Dock show nothing.
    var isPerfect: Bool { due > 0 && remaining == 0 }

    /// Nothing was due that day: every habit rests, has met its week, or had not started.
    var isRestDay: Bool { due == 0 }

    /// done ÷ due, 0…1 (the ring); 0 when nothing is due.
    var fraction: Double { due > 0 ? Double(done) / Double(due) : 0 }

    init(done: Int, due: Int) {
        assert(0 <= done && done <= due, "DailyProgress: done must be within 0…due")
        self.done = done
        self.due = due
    }

    /// The day's totals from each habit's state.
    init<S: Sequence>(states: S) where S.Element == State {
        var done = 0, open = 0
        for state in states {
            switch state {
            case .done: done += 1
            case .due: open += 1
            case .rest, .metForWeek, .notStarted: break
            }
        }
        self.init(done: done, due: done + open)
    }

    /// The day's totals for `habits` (never an archived one) on `dayKey`.
    init(of habits: [HabitStats], on dayKey: Date) {
        self.init(states: habits.lazy.map { Self.state(of: $0, on: dayKey) })
    }
}
