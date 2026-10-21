import Foundation

/// What the Pro cards say about a habit's numbers: Insights' strongest and toughest weekday and its
/// momentum, and Weekly Review's overall rate, change and highlights. The numbers come from
/// `HabitStats` (`weekdayTallies`, `thisWeekRate`, `lastWeekRate`); this decides what may be said
/// about them, and is pinned host-less by StatsInsightsTests.
///
/// Found by the churn investigation of 2026-10-22, each a Pro card saying something wrong or
/// discouraging to the users who do best:
/// - "Strongest on" was `max(by:)` over a Dictionary, whose order changes per process: a user who
///   checks in every day got a strongest day that moved between launches, and "Toughest on" was
///   the first of equal minimums, so always Sunday;
/// - momentum and Weekly Review counted an unfinished today as a miss: every Monday before the
///   check-in read 0% and "Down vs last week (100% → 0%)" (`HabitStats.countedRate`).
///
/// Shared/ rules: a pure value, no user-facing text (the views own the keys).
enum StatsInsights {

    // MARK: Strongest and toughest weekday

    /// One weekday's scheduled days so far and how many were completed (`HabitStats.weekdayTallies`).
    struct WeekdayTally: Equatable {
        let done: Int
        let due: Int
    }

    /// Weekdays as `HabitCalendar.utc` numbers them, 1 = Sunday … 7 = Saturday; nil: nothing to say.
    struct WeekdayExtremes: Equatable {
        var strongest: Int?
        var toughest: Int?
    }

    /// The weekday that stands out above every other scheduled weekday, and the one below every
    /// other — only when it is alone there: on a tie there is no strongest or toughest day, and
    /// a user who never misses has neither. Compared as rates (done ÷ due, exactly), not counts:
    /// from Monday to Saturday such a user has done one more of those days than Sundays.
    ///
    /// Nothing for times-per-week, which has no weekday schedule (HabitStats.isScheduled calls
    /// every day of it due), for fewer than two scheduled weekdays, and until every scheduled
    /// weekday has come due at least once: a weekday that has not happened yet is not a weak one.
    static func weekdayExtremes(_ tallies: [Int: WeekdayTally], schedule: HabitSchedule,
                                activeDaysMask: Int) -> WeekdayExtremes {
        let weekdays: [Int]
        switch schedule {
        case .timesPerWeek: return WeekdayExtremes()
        case .daily: weekdays = Array(1...7)
        case .specificDays: weekdays = (1...7).filter { activeDaysMask & (1 << ($0 - 1)) != 0 }
        }
        guard weekdays.count >= 2 else { return WeekdayExtremes() }
        var rated: [WeekdayTally] = []
        for weekday in weekdays {
            guard let tally = tallies[weekday], tally.due > 0 else { return WeekdayExtremes() }
            rated.append(tally)
        }
        // a/b below c/d, without rounding: a·d < c·b (both denominators are positive).
        let below: (WeekdayTally, WeekdayTally) -> Bool = { $0.done * $1.due < $1.done * $0.due }
        let strongest = uniqueTop(rated, below).map { weekdays[$0] }
        let toughest = uniqueTop(rated) { below($1, $0) }.map { weekdays[$0] }
        return WeekdayExtremes(strongest: strongest, toughest: toughest == strongest ? nil : toughest)
    }

    // MARK: Momentum

    /// Last week's and this week's whole percents, as the row prints them.
    struct Momentum: Equatable {
        let was: Int
        let now: Int
        /// "Up" for a week level with the last, as before.
        var isUp: Bool { now >= was }
    }

    /// Insights' "Up/Down vs last week": this week so far against last week, compared in the
    /// percents the row prints, so the arrow agrees with them. Nil when either week has nothing to
    /// count (`HabitStats.countedRate`: on Monday before the check-in, or for a habit that did not
    /// exist last week), and when both are 0%.
    static func momentum(thisWeek: Double?, lastWeek: Double?) -> Momentum? {
        guard let thisWeek, let lastWeek else { return nil }
        let now = percent(thisWeek), was = percent(lastWeek)
        guard was > 0 || now > 0 else { return nil }
        return Momentum(was: was, now: now)
    }

    // MARK: Weekly Review

    struct WeeklyReview: Equatable {
        /// Each habit's week so far, in the caller's order; nil: nothing to count yet.
        let rates: [Double?]
        /// The mean over the habits with something to count this week; nil when none has.
        let overall: Double?
        /// `overall` minus last week's (the mean over the habits with something to count then),
        /// when both exist and they differ by more than a point.
        let change: Double?
        /// The habit alone at the top of this week's percents, and the one alone at the bottom,
        /// among at least two with something to count. The first of equal rates used to be
        /// "Best": on a Monday before any check-in, a habit at 0%.
        let best: Int?
        let needsWork: Int?
    }

    static func weeklyReview(thisWeek: [Double?], lastWeek: [Double?]) -> WeeklyReview {
        let overall = mean(thisWeek), lastOverall = mean(lastWeek)
        var change: Double?
        if let overall, let lastOverall, abs(overall - lastOverall) > 0.01 { change = overall - lastOverall }
        let rated = thisWeek.indices.compactMap { i in thisWeek[i].map { (index: i, percent: percent($0)) } }
        var best: Int?, worst: Int?
        if rated.count >= 2 {
            best = uniqueTop(rated) { $0.percent < $1.percent }.map { rated[$0].index }
            worst = uniqueTop(rated) { $0.percent > $1.percent }.map { rated[$0].index }
        }
        return WeeklyReview(rates: thisWeek, overall: overall, change: change, best: best,
                            needsWork: worst == best ? nil : worst)
    }

    // MARK: Helpers

    /// A rate as the cards print it: whole percent, truncated (`Int(rate * 100)`).
    static func percent(_ rate: Double) -> Int { Int(rate * 100) }

    private static func mean(_ rates: [Double?]) -> Double? {
        let known = rates.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    /// The index of the one item every other is `below`; nil when the top is shared (or there are
    /// no items). With the arguments swapped, the one alone at the bottom.
    private static func uniqueTop<T>(_ items: [T], _ below: (T, T) -> Bool) -> Int? {
        guard var top = items.indices.first else { return nil }
        for i in items.indices.dropFirst() where below(items[top], items[i]) { top = i }
        return items.indices.allSatisfy { $0 == top || below(items[$0], items[top]) } ? top : nil
    }
}
