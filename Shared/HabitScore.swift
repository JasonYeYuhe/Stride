import Foundation

/// Strength: a 0–100 score that rewards consistency and recovers after a miss
/// (RELEASE-1.4.1.md D9; DEV-PLAN-1.3.md M4, :1180-1188). Re-derived from Loop's published
/// formula, not copied.
///
/// - The walk covers every day from `HabitStats.startDay` (min(created, earliest live record))
///   to today, starting from 0.
/// - Daily input: yes/no 1 or 0; count `min(1, value / target)`; times-per-week
///   `min(1, trailing-7 completions / timesPerWeek)`, every day. A neutral day (`nil`: a
///   `specificDays` rest day now, an M6 skip later) leaves the score unchanged.
/// - `score = previous · m + input · (1 − m)`, `m = 0.5^(√freq / 13)`, with `freq` = 1 (daily),
///   popcount(activeDaysMask) / 7 (specific days) or timesPerWeek / 7: a habit due less often
///   decays more slowly per day, so one miss costs a 3×/week habit no more than a daily one.
/// - Today (O1): today's input is applied only once today is complete; until then the walk ends
///   at yesterday — the same rule for every kind (a count habit's partial today is not applied;
///   a times-per-week habit holds only today, never the streak's in-progress-week grace). Past
///   days are always evaluated, so decay resumes the next day.
/// - The habit's CURRENT target and schedule score its whole history (2026-10-15 decision 8).
///
/// Reference values (HabitScoreTests, recomputed 2026-10-14): 30 perfect days 0.798; 100 days
/// 0.995; one miss after 60 days −4.98 points; the demo seed's Read 30 Minutes 0.716 and Journal
/// 0.711 after its 30 days, 0.890 and 0.883 after 90 days of the same patterns.
///
/// Derived on read, never persisted; no schema change. Shared/ rules: pure arithmetic, no
/// user-facing text, no `appCalendar` (days are whole UTC days, as `HabitStats` holds them).
enum HabitScore {
    /// A strength walk's output: one input and one score per walked day, oldest first.
    struct Series: Equatable {
        /// The first day walked, as `HabitStats` numbers days (days since 1970-01-01).
        let firstDayNumber: Int
        /// The habit-day the walk was made on (its last day only when today is complete).
        let todayNumber: Int
        /// Each walked day's input, 0…1; nil for a neutral day (score unchanged).
        let inputs: [Double?]
        /// The score after each walked day, 0…1.
        let scores: [Double]

        /// The first day walked, a day-key.
        var firstDay: Date { HabitStats.key(ofDay: firstDayNumber) }
        /// The last day walked (today once complete, else yesterday); nil for an empty walk.
        var lastDay: Date? { scores.isEmpty ? nil : HabitStats.key(ofDay: lastDayNumber) }
        /// The day-keys walked, oldest first.
        var days: [Date] { scores.indices.map { HabitStats.key(ofDay: firstDayNumber + $0) } }

        private var lastDayNumber: Int { firstDayNumber + scores.count - 1 }

        /// The latest score, 0 for an empty walk.
        var current: Double { scores.last ?? 0 }

        /// The score at the end of `day`: 0 before the walk (where it starts), the latest score
        /// after its last day (today's unfinished input is not applied).
        func score(on day: Date) -> Double {
            score(onDay: HabitStats.dayNumber(ofKey: day))
        }

        func score(onDay day: Int) -> Double {
            guard !scores.isEmpty, day >= firstDayNumber else { return 0 }
            return day > lastDayNumber ? current : scores[day - firstDayNumber]
        }

        /// `current` minus the score `days` days before the last day walked. Before the walk
        /// the score was 0, so a habit younger than `days` reports everything it has gained.
        func delta(days: Int) -> Double {
            guard !scores.isEmpty else { return 0 }
            return current - score(onDay: lastDayNumber - days)
        }

        /// The score at the end of each Monday-anchored week, the last `weeks` weeks up to and
        /// including the one containing today (the current week holds its latest score), oldest
        /// first (StrengthCard's bars, D10).
        func weekly(weeks: Int) -> [Double] {
            guard weeks > 0 else { return [] }
            let thisMonday = HabitStats.monday(ofWeekContaining: todayNumber)
            return (0..<weeks).reversed().map { back in
                score(onDay: min(thisMonday - 7 * back + 6, todayNumber))
            }
        }
    }

    #if DEBUG
    /// How many walks `series` has run in this process: StatsPerformanceTests proves the
    /// uncached wrapper path runs none.
    nonisolated(unsafe) static var walkCount = 0
    #endif

    /// `freq` for the decay: 1 (daily), popcount(activeDaysMask) / 7, or timesPerWeek / 7, kept
    /// within (0, 1].
    static func frequency(schedule: HabitSchedule, timesPerWeek: Int, activeDaysMask: Int) -> Double {
        let perWeek: Int
        switch schedule {
        case .daily: return 1
        case .specificDays: perWeek = (activeDaysMask & 0b111_1111).nonzeroBitCount
        case .timesPerWeek: perWeek = timesPerWeek
        }
        return Double(min(7, max(1, perWeek))) / 7
    }

    /// `m = 0.5^(√freq / 13)`.
    static func decay(frequency: Double) -> Double {
        pow(0.5, frequency.squareRoot() / 13)
    }

    /// One step: `previous · m + input · (1 − m)`; a nil (neutral) input returns `previous`.
    static func step(previous: Double, input: Double?, decay: Double) -> Double {
        guard let input else { return previous }
        return previous * decay + input * (1 - decay)
    }

    /// The input `day` contributes; nil when it is neutral.
    static func input(onDay day: Int, completedDays: Set<Int>, valuesByDay: [Int: Double],
                      kind: HabitKind, targetValue: Double, schedule: HabitSchedule,
                      timesPerWeek: Int, activeDaysMask: Int, trailingCompletions: Int) -> Double? {
        switch schedule {
        case .timesPerWeek:
            return min(1, Double(trailingCompletions) / Double(max(1, timesPerWeek)))
        case .specificDays where !HabitStats.isScheduled(day: day, schedule: schedule, activeDaysMask: activeDaysMask):
            return nil
        case .daily, .specificDays:
            switch kind {
            case .binary:
                return completedDays.contains(day) ? 1 : 0
            case .count:
                let value = valuesByDay[day] ?? 0
                guard targetValue > 0 else { return value > 0 ? 1 : 0 }
                return min(1, max(0, value / targetValue))
            }
        }
    }

    /// The walk for one habit, from its completed days and values by day (HabitStats' two
    /// initializer products, by day number). `todayIsComplete` decides whether today's input is
    /// applied (O1).
    static func series(completedDays: Set<Int>, valuesByDay: [Int: Double], kind: HabitKind,
                       targetValue: Double, schedule: HabitSchedule, timesPerWeek: Int,
                       activeDaysMask: Int, startDay: Int, today: Int,
                       todayIsComplete: Bool) -> Series {
        #if DEBUG
        walkCount += 1
        #endif
        // Never before 2025-01-01 (X2): a start there could only come from a key a non-Gregorian
        // device wrote (year 8 is ~737,000 days of arrays). `HabitStats.startDay` already skips
        // such keys; this holds for a caller that passes its own start.
        let startDay = max(startDay, HabitCalendar.firstRealDayNumber)
        let last = todayIsComplete ? today : today - 1
        guard startDay <= last else {
            return Series(firstDayNumber: startDay, todayNumber: today, inputs: [], scores: [])
        }
        let m = decay(frequency: frequency(schedule: schedule, timesPerWeek: timesPerWeek,
                                           activeDaysMask: activeDaysMask))
        let count = last - startDay + 1
        var inputs: [Double?] = []
        var scores: [Double] = []
        inputs.reserveCapacity(count)
        scores.reserveCapacity(count)
        var score = 0.0
        // Completions in the 7 days ending `day`, slid one day at a time.
        var trailing = (startDay - 6...startDay - 1).reduce(0) { $0 + (completedDays.contains($1) ? 1 : 0) }
        for day in startDay...last {
            if completedDays.contains(day) { trailing += 1 }
            if completedDays.contains(day - 7) { trailing -= 1 }
            let x = input(onDay: day, completedDays: completedDays, valuesByDay: valuesByDay, kind: kind,
                          targetValue: targetValue, schedule: schedule, timesPerWeek: timesPerWeek,
                          activeDaysMask: activeDaysMask, trailingCompletions: trailing)
            score = step(previous: score, input: x, decay: m)
            inputs.append(x)
            scores.append(score)
        }
        return Series(firstDayNumber: startDay, todayNumber: today, inputs: inputs, scores: scores)
    }

    /// The same walk from day-keys (tests, and callers without a `HabitStats`).
    static func series(completedDayKeys: Set<Date>, valuesByDay: [Date: Double], kind: HabitKind,
                       targetValue: Double, schedule: HabitSchedule, timesPerWeek: Int,
                       activeDaysMask: Int, startDay: Date, today: Date,
                       todayIsComplete: Bool) -> Series {
        series(completedDays: Set(completedDayKeys.map(HabitStats.dayNumber(ofKey:))),
               valuesByDay: Dictionary(valuesByDay.map { (HabitStats.dayNumber(ofKey: $0.key), $0.value) },
                                       uniquingKeysWith: max),
               kind: kind, targetValue: targetValue, schedule: schedule, timesPerWeek: timesPerWeek,
               activeDaysMask: activeDaysMask, startDay: HabitStats.dayNumber(ofKey: startDay),
               today: HabitStats.dayNumber(ofKey: today), todayIsComplete: todayIsComplete)
    }

    /// The number shown: 0–100, rounded.
    static func displayValue(_ score: Double) -> Int {
        Int((min(1, max(0, score)) * 100).rounded())
    }
}
