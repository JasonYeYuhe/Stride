import Foundation

/// Strength: a 0–100 score that rewards consistency and recovers after a miss
/// (RELEASE-1.4.1.md D9; DEV-PLAN-1.3.md M4). **Owner: W1.** Scaffolded by W0: every member is
/// a stub that returns a neutral value and nothing calls it yet.
///
/// TODO(W1): implement D9.
/// - Walk the day-keys from `HabitStats.startDay` (min(created, earliest live record)) to today.
/// - Daily input: yes/no 1 or 0; count `min(1, value / target)`; times-per-week
///   `min(1, trailing-7 completions / timesPerWeek)`, every day. A neutral day (`nil`: a
///   `specificDays` rest day now, an M6 skip later) leaves the score unchanged.
/// - `score = previous · m + input · (1 − m)`, `m = 0.5^(√freq / 13)`, with `freq` = 1 (daily),
///   popcount(activeDaysMask) / 7 (specific days) or timesPerWeek / 7.
/// - Today (O1): today's input is applied only once today is complete; until then the walk ends
///   at yesterday — the same rule for every kind (a count habit's partial today is not applied;
///   a times-per-week habit never gets the streak's in-progress-week grace). Past days are
///   always evaluated, so decay resumes the next day.
/// - Recomputed reference values (HabitScoreTests): 30 perfect days 0.798; 100 days 0.995; one
///   miss after 60 days −4.98 points; the demo seed's Read 0.716 and Journal 0.711 at 30 days,
///   0.890 and 0.883 at 90.
///
/// Derived on read, never persisted; no schema change. Shared/ rules: pure arithmetic, no
/// user-facing text, no `appCalendar` (day-keys are UTC, `HabitCalendar.utc`).
enum HabitScore {
    /// A strength walk's output.
    struct Series: Equatable {
        /// The day-keys walked, oldest first (ends at today only when today is complete).
        var days: [Date] = []
        /// The score after each of `days`, 0…1.
        var scores: [Double] = []

        /// The latest score, 0 for an empty walk.
        var current: Double {
            // TODO(W1)
            0
        }

        /// `current` minus the score `days` days earlier (0 when the walk is shorter).
        func delta(days: Int) -> Double {
            // TODO(W1)
            0
        }

        /// The score at the end of each Monday-anchored week, the last `weeks` weeks, oldest
        /// first (StrengthCard's bars, D10).
        func weekly(weeks: Int) -> [Double] {
            // TODO(W1)
            []
        }
    }

    /// `freq` for the decay: 1 (daily), popcount(activeDaysMask) / 7, or timesPerWeek / 7.
    static func frequency(schedule: HabitSchedule, timesPerWeek: Int, activeDaysMask: Int) -> Double {
        // TODO(W1)
        1
    }

    /// `m = 0.5^(√freq / 13)`.
    static func decay(frequency: Double) -> Double {
        // TODO(W1)
        1
    }

    /// One step: `previous · m + input · (1 − m)`; a nil (neutral) input returns `previous`.
    static func step(previous: Double, input: Double?, decay: Double) -> Double {
        // TODO(W1)
        previous
    }

    /// The walk for one habit, from its completed set and values by day (HabitStats' two
    /// initializer products). `todayIsComplete` decides whether today's input is applied (O1).
    static func series(completedDayKeys: Set<Date>, valuesByDay: [Date: Double], kind: HabitKind,
                       targetValue: Double, schedule: HabitSchedule, timesPerWeek: Int,
                       activeDaysMask: Int, startDay: Date, today: Date,
                       todayIsComplete: Bool) -> Series {
        // TODO(W1)
        Series()
    }

    /// The number shown: 0–100, rounded.
    static func displayValue(_ score: Double) -> Int {
        // TODO(W1)
        0
    }
}
