import Foundation
import SwiftData

/// One habit's statistics, computed once from one snapshot of its records
/// (RELEASE-1.4.1.md D2). **Owner: W1.** Scaffolded by W0: every member below is a stub that
/// returns a neutral value (0, empty, "not completed") and nothing calls it yet.
///
/// TODO(W1): implement D2, then make `Habit`'s aggregates delegate here — `currentStreak(from:)`,
/// `bestStreak()`, `weeklyCompletions`, both `completionRate` overloads and
/// `completionsPerWeekday()`. The per-day lookups (`record(on:)`, `loggedValue(on:)`,
/// `progress(on:)`, `isCompletedOn`) stay direct on `Habit` and never build one of these.
///
/// What D2 fixes, each named in a HabitStatsParityTests case (everything else is frozen by
/// golden values captured first):
/// - ghosts are excluded by the STORE's live ids (`liveRecordIDs`), not by `habit.records`: a
///   deletion saved by another context or process leaves a record that looks live there
///   (HabitCheckIn.swift, `liveRecord`);
/// - `completionsPerWeekday` counts completed days, not every record;
/// - the rate starts at `startDay` = min(creation day, earliest live record) (D8);
/// - records dated after `today` are ignored;
/// - a day with several live records counts as its largest value, for completion and
///   `loggedValue` alike (2026-10-15 decision 7 keeps the record this reads).
///
/// Shape (D2): the initializer builds only the live day-key set and the values by day. Streaks,
/// ranges, the rate and the weekday counts are computed on first access; the strength series
/// only when a strength accessor is read, through `HabitScore` (D9). Any as-of day is answered
/// from the set, never by rescanning records.
///
/// Shared/ rules: a pure value — no `appLocalized`/`appCalendar` (the caller passes a
/// `Calendar`), no UIKit/AppKit, no user-facing text. It also compiles into the widget,
/// scripts/demo_check and scripts/sync_rehearsal, so no top-level name of theirs is used here.
/// The widget builds one per habit per timeline from its own context and keeps none (Data
/// safety 5); the app reads them through `StatsCache` (D3).
final class HabitStats {
    /// One run of consecutive completed scheduled days (or, for times-per-week, met weeks).
    struct StreakRange: Equatable, Hashable {
        /// First day-key of the run (for times-per-week: the Monday of its first week).
        let start: Date
        /// Last day-key of the run (for times-per-week: the Sunday of its last week, or the
        /// last completed day of an open run).
        let end: Date
        /// In the habit's streak unit: days, or weeks for times-per-week.
        let length: Int
    }

    // MARK: Inputs

    let kind: HabitKind
    let targetValue: Double
    let schedule: HabitSchedule
    let timesPerWeek: Int
    let activeDaysMask: Int
    let createdAt: Date
    /// The day-key of "today" the answers are relative to (the caller's `today`, keyed).
    let today: Date
    /// The user's calendar, for keying `today` (Shared/ never reads `appCalendar`).
    let calendar: Calendar

    // MARK: Built in the initializer (D2)

    /// Day-keys whose live records complete the day (count habits: value ≥ target).
    let completedDayKeys: Set<Date>
    /// The largest live value logged on each day-key.
    let valuesByDay: [Date: Double]

    /// - Parameters:
    ///   - records: the habit's records as loaded (may include ghosts).
    ///   - liveRecordIDs: the ids the store says are live (`liveRecordIDs(of:in:)`); only these
    ///     are counted.
    init(records: [HabitRecord], liveRecordIDs: Set<UUID>, kind: HabitKind, targetValue: Double,
         schedule: HabitSchedule, timesPerWeek: Int, activeDaysMask: Int, createdAt: Date,
         calendar: Calendar, today: Date) {
        self.kind = kind
        self.targetValue = targetValue
        self.schedule = schedule
        self.timesPerWeek = timesPerWeek
        self.activeDaysMask = activeDaysMask
        self.createdAt = createdAt
        self.calendar = calendar
        self.today = HabitCalendar.dayKey(for: today, localCalendar: calendar)
        // TODO(W1): build both from the live records, dropping records after `today`.
        self.completedDayKeys = []
        self.valuesByDay = [:]
    }

    /// The habit's own fields, read once.
    convenience init(habit: Habit, liveRecordIDs: Set<UUID>, calendar: Calendar = .current,
                     today: Date = Date()) {
        self.init(records: habit.records, liveRecordIDs: liveRecordIDs, kind: habit.habitKind,
                  targetValue: habit.targetValue, schedule: habit.schedule,
                  timesPerWeek: habit.timesPerWeek, activeDaysMask: habit.activeDaysMask,
                  createdAt: habit.createdAt, calendar: calendar, today: today)
    }

    /// The ids of `habits`' records that the store holds as live, in one fetch (D2, D3):
    /// pending inserts count, pending deletes do not. StatsCache calls it once per rebuild; the
    /// widget calls it in its own context.
    static func liveRecordIDs(of habits: [Habit], in context: ModelContext) -> Set<UUID> {
        // TODO(W1): one FetchDescriptor<HabitRecord> over the habits' record ids, as
        // HabitCheckIn.liveRecord does for one day.
        []
    }

    // MARK: Per-day answers (from the set; never a rescan)

    func isCompleted(on day: Date) -> Bool {
        // TODO(W1)
        false
    }

    /// The day's largest live value; 0 when there is none.
    func loggedValue(on day: Date) -> Double {
        // TODO(W1)
        0
    }

    // MARK: Aggregates (computed on first access)

    /// min(creation day, earliest live record): where the rate (D8), the strength walk (D9),
    /// Today's past-day filter (O11) and History's backdating window (D8) start.
    private(set) lazy var startDay: Date = HabitCalendar.dayKey(for: createdAt, localCalendar: calendar) // TODO(W1)

    /// The streak as of `day` (default: `today`), keeping the grace of `Habit.currentStreak`:
    /// an unfinished today (or, for times-per-week, an unfinished week) does not break it.
    func currentStreak(asOf day: Date? = nil) -> Int {
        // TODO(W1)
        0
    }

    /// The longest run; always `bestStreakRanges.first?.length ?? 0` (a parity rule).
    private(set) lazy var bestStreak: Int = 0 // TODO(W1)

    /// The top 5 runs, dated, longest first, ties broken by the most recent. Times-per-week
    /// runs are Monday-anchored weeks.
    private(set) lazy var bestStreakRanges: [StreakRange] = [] // TODO(W1)

    /// Completed days in the Monday-anchored week starting at `start`.
    func weeklyCompletions(weekStarting start: Date) -> Int {
        // TODO(W1)
        0
    }

    /// Completed days in the Monday-anchored week containing `day`.
    func weeklyCompletions(containing day: Date) -> Int {
        // TODO(W1)
        0
    }

    /// The rate over the last `days` days ending `today`, from `startDay` at the earliest.
    func completionRate(days: Int = 30) -> Double {
        // TODO(W1)
        0
    }

    /// The rate over an inclusive range, clamped to `startDay` and to `today`; never above 1.
    func completionRate(from start: Date, to end: Date) -> Double {
        // TODO(W1)
        0
    }

    /// Completed days per weekday (1 = Sunday … 7 = Saturday).
    private(set) lazy var completionsPerWeekday: [Int: Int] = [:] // TODO(W1)

    // MARK: Strength (D9; only when read)

    /// Today's strength, 0…1 (shown 0–100 via `HabitScore.displayValue`).
    private(set) lazy var strength: Double = 0 // TODO(W1): HabitScore.series(…).current

    /// The change in strength over the last 30 / 90 days, in score units (−1…1).
    private(set) lazy var strengthDelta30: Double = 0 // TODO(W1)
    private(set) lazy var strengthDelta90: Double = 0 // TODO(W1)

    /// Weekly-bucketed strength for StrengthCard's bars (D10), oldest first.
    private(set) lazy var weeklyStrength: [Double] = [] // TODO(W1)
}
