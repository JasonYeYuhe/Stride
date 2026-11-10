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
/// RELEASE-1.4.2.md D7 ("Pro is right in its first week") added what Insights says and in what
/// order (`insightLines`), why it has nothing to say (`emptyState`), the weekday line's 12-week
/// window and minimums, the record line, a level week, and which Strength changes a young habit
/// shows (`strengthChanges`).
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

    /// Insights' weekday line (D7): every scheduled weekday due at least this often in the
    /// 12-week window (`HabitStats.recentWeekdayTallies`), or no weekday line at all.
    static let weekdayMinimumDue = 4
    /// Insights' weekday line (D7): the named day is at least this many percentage points from
    /// every other scheduled weekday in the 12-week window — the strongest at least 15 above the
    /// runner-up, the toughest at least 15 below the next-lowest — so the line never names a day
    /// that is only marginally ahead. It is a gap in recent rates; agreeing with the free By
    /// Weekday bars, which draw all-time counts, is a separate rule (`agreeingWithAllTimeCounts`).
    static let weekdayMinimumGap = 15

    /// The weekday that stands out above every other scheduled weekday, and the one below every
    /// other — only when it is alone there: on a tie there is no strongest or toughest day, and
    /// a user who never misses has neither. Compared as rates (done ÷ due, exactly), not counts:
    /// from Monday to Saturday such a user has done one more of those days than Sundays.
    ///
    /// Nothing for times-per-week, which has no weekday schedule (HabitStats.isScheduled calls
    /// every day of it due), for fewer than two scheduled weekdays, and until every scheduled
    /// weekday has come due at least `minimumDue` times (at least once): a weekday that has not
    /// happened yet is not a weak one.
    ///
    /// `minimumGap`, in percentage points: the named day's rate must be that far from every other
    /// scheduled weekday's (and strictly beyond it, so 0 is the plain "alone at the top"). Exact,
    /// in integers: a/b at least g points above c/d is 100·(a·d − c·b) ≥ g·b·d, so exactly 15
    /// points passes and anything less does not, with no floating-point rounding at the edge.
    static func weekdayExtremes(_ tallies: [Int: WeekdayTally], schedule: HabitSchedule,
                                activeDaysMask: Int, minimumDue: Int = 1,
                                minimumGap: Int = 0) -> WeekdayExtremes {
        let weekdays = scheduledWeekdays(schedule: schedule, activeDaysMask: activeDaysMask)
        guard weekdays.count >= 2 else { return WeekdayExtremes() }
        var rated: [WeekdayTally] = []
        for weekday in weekdays {
            guard let tally = tallies[weekday], tally.due >= max(1, minimumDue) else { return WeekdayExtremes() }
            rated.append(tally)
        }
        // `high` above `low` by at least the gap, without rounding (both denominators positive).
        let clears: (WeekdayTally, WeekdayTally) -> Bool = { high, low in
            let difference = high.done * low.due - low.done * high.due
            return difference > 0 && 100 * difference >= minimumGap * high.due * low.due
        }
        let strongest = rated.indices.first { top in
            rated.indices.allSatisfy { $0 == top || clears(rated[top], rated[$0]) }
        }.map { weekdays[$0] }
        let toughest = rated.indices.first { bottom in
            rated.indices.allSatisfy { $0 == bottom || clears(rated[$0], rated[bottom]) }
        }.map { weekdays[$0] }
        // Never the same day: with two or more weekdays, each would have to clear the other.
        return WeekdayExtremes(strongest: strongest, toughest: toughest)
    }

    /// The weekdays a schedule has (1 = Sunday … 7 = Saturday); none for times-per-week, which
    /// has no weekday schedule.
    static func scheduledWeekdays(schedule: HabitSchedule, activeDaysMask: Int) -> [Int] {
        switch schedule {
        case .timesPerWeek: return []
        case .daily: return Array(1...7)
        case .specificDays: return (1...7).filter { activeDaysMask & (1 << ($0 - 1)) != 0 }
        }
    }

    /// `extremes` kept only where the free By Weekday bars agree (W5 review): the strongest day
    /// only if its all-time completion count (`HabitStats.completionsPerWeekday`, what By Weekday
    /// draws) is at least tied for the highest among the scheduled weekdays, the toughest only if
    /// it is at least tied for the lowest. Otherwise a habit whose Monday was weak before the
    /// 12-week window and perfect inside it read "Strongest on Monday" over Monday's lowest bar.
    static func agreeingWithAllTimeCounts(_ extremes: WeekdayExtremes, counts: [Int: Int],
                                          weekdays: [Int]) -> WeekdayExtremes {
        let scheduled = weekdays.map { counts[$0] ?? 0 }
        guard let highest = scheduled.max(), let lowest = scheduled.min() else { return WeekdayExtremes() }
        return WeekdayExtremes(
            strongest: extremes.strongest.flatMap { (counts[$0] ?? 0) >= highest ? $0 : nil },
            toughest: extremes.toughest.flatMap { (counts[$0] ?? 0) <= lowest ? $0 : nil })
    }

    /// Insights' weekday line (D7): `weekdayExtremes` over the last 12 weeks
    /// (`HabitStats.recentWeekdayTallies`), with D7's minimums, so a pattern the user has since
    /// changed is not named; and only where By Weekday's all-time bars do not contradict it
    /// (`agreeingWithAllTimeCounts`).
    static func recentWeekdayExtremes(of stats: HabitStats) -> WeekdayExtremes {
        let recent = weekdayExtremes(stats.recentWeekdayTallies, schedule: stats.schedule,
                                     activeDaysMask: stats.activeDaysMask,
                                     minimumDue: weekdayMinimumDue, minimumGap: weekdayMinimumGap)
        return agreeingWithAllTimeCounts(recent, counts: stats.completionsPerWeekday,
                                         weekdays: scheduledWeekdays(schedule: stats.schedule,
                                                                     activeDaysMask: stats.activeDaysMask))
    }

    // MARK: Momentum

    /// Last week's and this week's whole percents, as the row prints them.
    struct Momentum: Equatable {
        enum Direction: Equatable { case up, level, down }

        let was: Int
        let now: Int

        /// Compared in the printed percents. A level week is `.level` ("Level with last week",
        /// D7); until 1.4.2 it read "Up vs last week (100% → 100%)".
        var direction: Direction { now > was ? .up : now < was ? .down : .level }
        /// Strictly up: false for a level week. D7 changed this on purpose; it was `now >= was`.
        var isUp: Bool { direction == .up }
    }

    /// Insights' "Up/Down vs last week" or "Level with last week": this week so far against last
    /// week, compared in the percents the row prints, so the arrow agrees with them. Nil when
    /// either week has nothing to count (`HabitStats.countedRate`: on Monday before the check-in,
    /// or for a habit that did not exist last week), and when both are 0%.
    static func momentum(thisWeek: Double?, lastWeek: Double?) -> Momentum? {
        guard let thisWeek, let lastWeek else { return nil }
        let now = percent(thisWeek), was = percent(lastWeek)
        guard was > 0 || now > 0 else { return nil }
        return Momentum(was: was, now: now)
    }

    // MARK: The record line (D7)

    /// How near the record the current run must be for the record line: 1…7 days (or weeks) away.
    static let recordLineReach = 7

    /// "3 days from your record of 20": the current run and the record it is closing on.
    struct RecordGap: Equatable {
        /// best − current, 1…`recordLineReach`.
        let away: Int
        /// The record, `HabitStats.bestStreak`.
        let record: Int
    }

    /// Only while the current run is open (`current` > 0), is not itself the record
    /// (`current` < `best`; equal means this run is the record), and is within `recordLineReach`
    /// of it. Both counts in the habit's streak unit: days, or Monday-anchored weeks for
    /// times-per-week (`HabitStats.currentStreak()`, `bestStreak`).
    static func recordGap(current: Int, best: Int) -> RecordGap? {
        guard current > 0, current < best, best - current <= recordLineReach else { return nil }
        return RecordGap(away: best - current, record: best)
    }

    // MARK: Insights' lines (D7)

    /// At most this many lines (D7).
    static let maximumInsightLines = 3

    /// One line of Insights, in the order `insightLines` gives them. The view owns the words.
    enum InsightLine: Equatable {
        /// "3 days from your record of 20"; `inWeeks` for times-per-week ("weeks").
        case record(RecordGap, inWeeks: Bool)
        case momentum(Momentum)
        /// A weekday, 1 = Sunday … 7 = Saturday.
        case strongest(Int)
        case toughest(Int)
    }

    /// D7's order and cap: the record line, then momentum, then the weekday line (strongest
    /// before toughest), and nothing past the third.
    static func insightLines(record: RecordGap?, inWeeks: Bool, momentum: Momentum?,
                             weekdays: WeekdayExtremes) -> [InsightLine] {
        var lines: [InsightLine] = []
        if let record { lines.append(.record(record, inWeeks: inWeeks)) }
        if let momentum { lines.append(.momentum(momentum)) }
        if let strongest = weekdays.strongest { lines.append(.strongest(strongest)) }
        if let toughest = weekdays.toughest { lines.append(.toughest(toughest)) }
        return Array(lines.prefix(maximumInsightLines))
    }

    /// Insights' real lines for `stats`. Never an empty-state line (`emptyState(for:)`): Statistics'
    /// locked card counts these ("Stride Pro has N insights", D12).
    static func insightLines(for stats: HabitStats) -> [InsightLine] {
        insightLines(record: recordGap(current: stats.currentStreak(), best: stats.bestStreak),
                     inWeeks: stats.schedule == .timesPerWeek,
                     momentum: momentum(thisWeek: stats.thisWeekRate, lastWeek: stats.lastWeekRate),
                     weekdays: recentWeekdayExtremes(of: stats))
    }

    // MARK: Insights with nothing to say (D7)

    /// Why Insights has no line. The card always draws, with one of these when `insightLines`
    /// is empty.
    enum EmptyState: Equatable {
        /// "Insights appear after your first full week".
        case beforeFirstFullWeek
        /// "Nothing to compare yet this week": past the first full week, but this week has nothing
        /// counted yet (`HabitStats.thisWeekRate` nil), so there is no momentum — a daily habit on
        /// Monday before the check-in, a weekend habit Monday to Saturday, 3 a week early in the
        /// week. A user who never misses has no other line (no record to chase, no weak day), and
        /// was told "Not enough recent check-ins" there (W5 review).
        case nothingToCompareYetThisWeek
        /// "Not enough recent check-ins to compare".
        case notEnoughRecentCheckIns
    }

    /// Whether the habit has had a full Monday-anchored week — Monday to Sunday, every day of it
    /// on or after `startDay` — that has ended: `today` is after its Sunday. Day numbers as
    /// `HabitStats` holds them (whole UTC days). A habit started on a Monday reads its first full
    /// week from the next Monday on; one started on a Tuesday waits for the following Monday's
    /// week to end, 13 days later.
    static func hasHadFullWeek(startDay: Int, today: Int) -> Bool {
        // The first Monday on or after the start: the Monday of the week holding start + 6.
        let firstMonday = HabitStats.monday(ofWeekContaining: startDay + 6)
        return today > firstMonday + 6
    }

    /// The empty state for a habit with no line: before its first full week, "after your first
    /// full week"; after it, "nothing to compare yet this week" while this week has nothing
    /// counted (`thisWeekRate` nil), else "not enough recent check-ins" (momentum is nil when both
    /// weeks are 0%, and the weekday minimums can leave nothing else). `startDay` is a day-key;
    /// `today` any instant, keyed in `calendar` as HabitStats keys it.
    static func emptyState(startDay: Date, today: Date, calendar: Calendar, thisWeekRate: Double?) -> EmptyState {
        guard hasHadFullWeek(startDay: HabitStats.dayNumber(ofKey: startDay),
                             today: HabitStats.dayNumber(of: today, in: calendar))
        else { return .beforeFirstFullWeek }
        return thisWeekRate == nil ? .nothingToCompareYetThisWeek : .notEnoughRecentCheckIns
    }

    /// The empty state for `stats`, whether or not it has lines: InsightsCard draws it only when
    /// `insightLines(for:)` is empty.
    static func emptyStateIgnoringLines(for stats: HabitStats) -> EmptyState {
        emptyState(startDay: stats.startDay, today: stats.today, calendar: stats.calendar,
                   thisWeekRate: stats.thisWeekRate)
    }

    /// What InsightsCard draws instead of lines: nil when it has lines (`insightLines(for:)`).
    static func emptyState(for stats: HabitStats) -> EmptyState? {
        guard insightLines(for: stats).isEmpty else { return nil }
        return emptyStateIgnoringLines(for: stats)
    }

    // MARK: Strength's changes for a young habit (D7)

    /// A change tile on StrengthCard.
    enum StrengthChange: Equatable, Hashable {
        /// "30-Day Change": `HabitStats.strengthDelta30`.
        case thirtyDays
        /// "90-Day Change": `HabitStats.strengthDelta90`.
        case ninetyDays
        /// "Since start": the score now less the score at the start (`strengthAtStart`).
        case sinceStart
    }

    /// Whole days from the start day to today: 0 on the start day. `startDay` a day-key, `today`
    /// any instant keyed in `calendar`.
    static func ageInDays(startDay: Date, today: Date, calendar: Calendar) -> Int {
        HabitStats.dayNumber(of: today, in: calendar) - HabitStats.dayNumber(ofKey: startDay)
    }

    /// The tiles for a habit `ageInDays` old (D7): one "Since start" while it is 30 days old or
    /// younger, "30-Day Change" and "Since start" from 31 to 90, then the 30- and 90-day changes.
    /// `thirtyDayChange` and `sinceStartChange` are the two numbers as drawn.
    ///
    /// The 30-day change is only considered once `ageInDays` > 30: younger, its window (30 days
    /// back from the walk's last day, which is yesterday until today is complete) can reach the
    /// day before the start, where the score is 0, and it would be Since start under another name.
    /// Older, the two can still be the same number: whenever the score was still 0 (as drawn) on
    /// the window's first day — no check-in on the start day, a start on a rest day, a habit left
    /// unused at first. Then the 30-day change is everything gained since the start, and only
    /// "Since start" is shown (W5 review), so the card never shows two equal tiles.
    static func strengthChanges(ageInDays: Int, thirtyDayChange: Int, sinceStartChange: Int) -> [StrengthChange] {
        if ageInDays > 90 { return [.thirtyDays, .ninetyDays] }
        if ageInDays > 30, thirtyDayChange != sinceStartChange { return [.thirtyDays, .sinceStart] }
        return [.sinceStart]
    }

    static func strengthChanges(for stats: HabitStats) -> [StrengthChange] {
        strengthChanges(ageInDays: ageInDays(startDay: stats.startDay, today: stats.today, calendar: stats.calendar),
                        thirtyDayChange: displayedChange(current: stats.strength,
                                                         baseline: stats.strength - stats.strengthDelta30),
                        sinceStartChange: displayedChangeSinceStart(of: stats))
    }

    /// The strength at the start: at the end of the day before `startDay`, where the strength
    /// walk starts from 0 (HabitScore) — so 0. Read through the walk rather than assumed, so that
    /// "Since start" stays "now less then" if the walk ever starts elsewhere.
    static func strengthAtStart(of stats: HabitStats) -> Double {
        stats.strength(on: HabitStats.key(ofDay: HabitStats.dayNumber(ofKey: stats.startDay) - 1))
    }

    /// A change in the points the card draws: the score now less the score then, each rounded as
    /// drawn, so "74" over "+5" always means it read 69 then (StrengthCard.displayedChange).
    static func displayedChange(current: Double, baseline: Double) -> Int {
        HabitScore.displayValue(current) - HabitScore.displayValue(baseline)
    }

    /// "Since start" as drawn: the displayed score now less the displayed score at the start.
    static func displayedChangeSinceStart(of stats: HabitStats) -> Int {
        displayedChange(current: stats.strength, baseline: strengthAtStart(of: stats))
    }

    // MARK: The Pro chip (D7)

    /// The "PRO" chip on the Pro cards' headers: white text on #23863C, the palette's Green
    /// darkened (`ColorContrast.readable`) until white on it reaches 4.6:1, then rounded to 8 bits
    /// per channel as it is drawn: 4.62:1, and still 4.56:1 a step lighter in every channel. The
    /// first fill (readable at exactly 4.5) sat at 4.5000006:1, and one 8-bit step lighter was
    /// 4.44 (W5 review). The same two colours in light and dark, so the contrast is the same in
    /// both.
    static let proChipText = ColorContrast.RGB.white
    static let proChipFill = ColorContrast.RGB(0x23863C)

    // MARK: Weekly Review

    struct WeeklyReview: Equatable {
        /// Each habit's week so far, in the caller's order; nil: nothing to count yet.
        let rates: [Double?]
        /// The mean over the habits with something to count this week; nil when none has.
        let overall: Double?
        /// This week against last, each habit against itself: the mean change over the habits
        /// with something to count in both weeks, when it is more than a point. Two means over
        /// different habits moved with no habit changing: a weekend-only habit, not due yet this
        /// week and missed last weekend, made a level daily habit "Up 50% vs last week" every
        /// weekday (review of bab8acf, 2026-10-22).
        let change: Double?
        /// The habit alone at the top of this week's percents, and the one alone at the bottom,
        /// among at least two with something to count. The first of equal rates used to be
        /// "Best": on a Monday before any check-in, a habit at 0%.
        let best: Int?
        let needsWork: Int?
    }

    static func weeklyReview(thisWeek: [Double?], lastWeek: [Double?]) -> WeeklyReview {
        let overall = mean(thisWeek)
        // Nil for a habit with nothing to count in one of the weeks, which `mean` leaves out.
        let changes: [Double?] = zip(thisWeek, lastWeek).map { now, was in
            guard let now, let was else { return nil }
            return now - was
        }
        var change: Double?
        if let moved = mean(changes), abs(moved) > 0.01 { change = moved }
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
