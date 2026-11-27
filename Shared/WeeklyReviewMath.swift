import Foundation

/// The Weekly Review's and Today's week math (RELEASE-1.4.2.md D8, D9's numbers, D10): which week
/// the review opens on, each habit's counted rate for any week and its change, the highlights,
/// the group section rates, and when a habit is at risk. Every number comes from the habits'
/// `HabitStats` (StatsCache, read once per render, Data safety 4); this decides what may be said
/// about them.
///
/// 1.5.0 (RELEASE-1.5.0.md D1, D6, D7): "due and not done" is `DailyProgress`'s rule (`isAtRisk`,
/// the perfect days); any week's bounds (`weekBounds`); the 7-cell strip (`dayStates`) and its
/// summary; and what a times-per-week row prints (`WeekGoal.owed`, `WeekGoal.isLastDay`).
///
/// Shared/ rules (Design decisions, "Placement rules"): pure values only — no `appLocalized`, no
/// user-facing literals, no UIKit or StoreKit; the `Calendar` is passed in and is used only to
/// key an instant (its Gregorian Y/M/D in its time zone, `HabitCalendar.dayKey`) and to read the
/// clock's hour and minute. Weeks are Monday-anchored on UTC day-keys (Data safety 5): the
/// region's first weekday, the calendar's identifier (the Japanese one included) and the DST
/// changes never move a week.
enum WeeklyReviewMath {

    // MARK: Weeks

    /// One Monday-anchored week, Monday through Sunday, as day-keys (UTC midnight).
    struct WeekRange: Equatable, Hashable, Comparable {
        /// The Monday, as `HabitStats` numbers days (whole days since 1970-01-01).
        let mondayNumber: Int

        /// The week containing day number `day` (whole days since 1970-01-01).
        init(containingDay day: Int) {
            self.mondayNumber = HabitStats.monday(ofWeekContaining: day)
        }

        /// The Monday, a day-key.
        var monday: Date { HabitStats.key(ofDay: mondayNumber) }
        /// The Sunday, a day-key.
        var sunday: Date { HabitStats.key(ofDay: sundayNumber) }
        var sundayNumber: Int { mondayNumber + 6 }
        /// Monday … Sunday, day-keys.
        var days: [Date] { (0..<7).map { HabitStats.key(ofDay: mondayNumber + $0) } }
        var previous: WeekRange { WeekRange(containingDay: mondayNumber - 7) }
        var next: WeekRange { WeekRange(containingDay: mondayNumber + 7) }

        /// Whether a day-key falls in this week.
        func contains(_ dayKey: Date) -> Bool {
            (mondayNumber...sundayNumber).contains(HabitStats.dayNumber(ofKey: dayKey))
        }

        static func < (a: WeekRange, b: WeekRange) -> Bool { a.mondayNumber < b.mondayNumber }
    }

    /// The Monday-anchored week containing `date`: a day-key is kept as it is, any other instant
    /// takes its local date in `calendar` (`HabitCalendar.dayKey(for:localCalendar:)`, the rule
    /// `HabitStats` and StatsCache key "today" by).
    static func weekRange(containing date: Date, in calendar: Calendar) -> WeekRange {
        WeekRange(containingDay: HabitStats.dayNumber(of: date, in: calendar))
    }

    // MARK: The opening week (D8)

    /// Where the opening week stands against today.
    enum Relation: Equatable {
        /// The week containing today: not over, shown "so far".
        case thisWeek
        /// The week before it.
        case lastWeek
        /// Any earlier week.
        case earlier
    }

    struct OpeningWeek: Equatable {
        let week: WeekRange
        let relation: Relation
        /// Whether the week is over (every week but this one).
        var isFinished: Bool { relation != .thisWeek }
    }

    /// This week opens the review once this many of its days have begun: Thursday on (D8: "at
    /// least 4 of its days have passed"). Monday to Wednesday it opens on last week, so a
    /// partial week is never shown as if it were whole.
    static let daysBeforeThisWeekOpens = 4

    /// The week the review opens on (D8): the week of `requested` when one was asked for
    /// (`.weeklyReview(week:)`), never later than this week; otherwise this week from its fourth
    /// day (Thursday 00:00 local) on, else last week.
    ///
    /// `requested` must be a day-key (UTC midnight; every caller passes a `WeekRange.monday`). It
    /// is keyed by `HabitStats.dayNumber(of:in:)`, which keeps an exact UTC midnight as the day it
    /// names, so an instant that happens to fall on one — Sunday 16:00 PST — would be read as
    /// Monday's day-key, a week late (pre-freeze review, A7). Any other instant takes its local
    /// date in `calendar`.
    ///
    /// `now` is an instant, keyed by its local date in `calendar`
    /// (`HabitCalendar.dayKey(forInstant:calendar:)`): Thursday 00:00 in Los Angeles is
    /// 07:00 or 08:00 UTC, and Sunday 16:00 PST is exactly UTC midnight of Monday. Build the
    /// habits' `HabitStats` for `today(now:calendar:)`, so both read the same day.
    ///
    /// `earliestStart`: the earliest `startDay` of the habits the review shows (nil: none, or
    /// unknown). When no week was asked for and it falls after last week — nothing existed last
    /// week, a brand-new user's first Monday to Wednesday — this week opens instead, "so far":
    /// last week would be every row "Not started" and no ring. The change and the highlights still
    /// wait for 4 counted days (`review`).
    static func openingWeek(now: Date, calendar: Calendar, requested: Date? = nil,
                            earliestStart: Date? = nil) -> OpeningWeek {
        let todayNumber = HabitStats.dayNumber(ofKey: today(now: now, calendar: calendar))
        let thisWeek = WeekRange(containingDay: todayNumber)
        let week: WeekRange
        if let requested {
            week = min(weekRange(containing: requested, in: calendar), thisWeek)
        } else if todayNumber - thisWeek.mondayNumber + 1 >= daysBeforeThisWeekOpens {
            week = thisWeek
        } else if let earliestStart, HabitStats.dayNumber(ofKey: earliestStart) > thisWeek.previous.sundayNumber {
            week = thisWeek
        } else {
            week = thisWeek.previous
        }
        let relation: Relation = week == thisWeek ? .thisWeek : week == thisWeek.previous ? .lastWeek : .earlier
        return OpeningWeek(week: week, relation: relation)
    }

    /// The opening week with its review: `openingWeek`, then, when no week was asked for and that
    /// week has nothing to count at all (`overall` nil: no ring, every row a dash or "Not
    /// started"), the other of this week and last week if it has something (pre-freeze review,
    /// A6):
    /// - Monday to Wednesday, this week instead of last: a Mon/Wed/Fri habit created last Saturday
    ///   had nothing due last week, while Monday's check-in already counts this week;
    /// - Thursday to Sunday, last week instead of this: a times-per-week habit owes nothing yet
    ///   on Thursday morning (`HabitStats.countedRate`'s goal so far), while last week has a rate.
    /// The title follows the week shown (`OpeningWeek.relation`). A requested week is always kept.
    /// `earliestStart` is read from the habits not archived, as the view passes it.
    static func openingReview(of habits: [HabitInput], now: Date, calendar: Calendar, requested: Date? = nil,
                              groupOrder: [UUID] = []) -> (opening: OpeningWeek, review: Review) {
        let earliestStart = habits.filter { !$0.isArchived }.map(\.stats.startDay).min()
        let opening = openingWeek(now: now, calendar: calendar, requested: requested, earliestStart: earliestStart)
        let first = review(of: habits, week: opening.week, groupOrder: groupOrder)
        guard requested == nil, first.overall == nil else { return (opening, first) }
        let other: OpeningWeek
        switch opening.relation {
        case .lastWeek: other = OpeningWeek(week: opening.week.next, relation: .thisWeek)
        case .thisWeek: other = OpeningWeek(week: opening.week.previous, relation: .lastWeek)
        case .earlier: return (opening, first)
        }
        let second = review(of: habits, week: other.week, groupOrder: groupOrder)
        return second.overall == nil ? (opening, first) : (other, second)
    }

    /// `now`'s local date as a day-key: the `today` the review's `HabitStats` are built for, the
    /// day `openingWeek` reads. An instant passed as `today` is keyed by `HabitStats.dayNumber(of:)`,
    /// which takes an exact UTC midnight for an already-stored day-key: at Sunday 16:00:00 PST the
    /// header said "so far" while the stats counted Monday.
    static func today(now: Date, calendar: Calendar) -> Date {
        HabitCalendar.dayKey(forInstant: now, calendar: calendar)
    }

    // MARK: The review of one week (D8, D9's numbers)

    /// One habit as the review reads it.
    struct HabitInput {
        let stats: HabitStats
        let isArchived: Bool
        /// The habit's group; nil, or a group that is not in the caller's `groupOrder`: Ungrouped.
        let groupID: UUID?

        init(stats: HabitStats, isArchived: Bool = false, groupID: UUID? = nil) {
            self.stats = stats
            self.isArchived = isArchived
            self.groupID = groupID
        }

        /// The habit's own fields, read once.
        init(habit: Habit, stats: HabitStats) {
            self.init(stats: stats, isArchived: habit.isArchived, groupID: habit.groupId)
        }
    }

    /// One habit's week.
    struct Row: Equatable {
        /// Its position in the caller's input.
        let index: Int
        /// The week's counted rate (`HabitStats.countedRate(ofWeekStarting:)`); nil: nothing to
        /// count — the habit had not started, or nothing has come due yet.
        let rate: Double?
        /// The previous week's counted rate.
        let previousRate: Double?
        /// The week ended before the habit's start: "Not started", never a missed week.
        let endsBeforeStart: Bool
        /// Whether the habit's week may be compared (D8):
        /// - the previous week has at least `countedDaysForChange` counted days (a habit created
        ///   on a Sunday and missed that day read "+85 points, Most improved" the next Monday);
        /// - and the week is over, or — for a daily or specific-days habit — at least
        ///   `countedDaysForChange` of its days are counted (`HabitStats.countedDayCount`). A
        ///   times-per-week habit waits for its week to end, or to meet its goal
        ///   (`metWeeklyGoal`, a final 100 %): what it owes so far can be nothing, so one check-in
        ///   on a Thursday read 100 %.
        let countsChange: Bool
        /// The change against the previous week in whole points, as the two rates print
        /// (`StatsInsights.percent`): only when the week `countsChange` and both rates are known.
        let changePoints: Int?
    }

    /// The members of one group, or the habits in none.
    struct Section: Equatable {
        /// Nil: Ungrouped (always last), or the only section when the user has no groups.
        let groupID: UUID?
        /// The members' positions in the caller's input, in its order.
        let members: [Int]
        /// The members' mean counted rate, over those with one; nil when none has.
        let rate: Double?
    }

    struct Review: Equatable {
        let week: WeekRange
        /// Whether the week is over. When it is not, the view labels the change and the
        /// highlights "so far".
        let isFinished: Bool
        /// Every habit not archived, in the caller's order.
        let rows: [Row]
        /// The mean counted rate over the rows with one; nil when none has.
        let overall: Double?
        /// The mean of the rows' `changePoints`, rounded to whole points; nil (no change line)
        /// when no row has one, or when any row with a rate has none (the line would leave out a
        /// row the ring counts); 0 reads "Level with the previous week".
        let changePoints: Int?
        /// The caller's position of the largest rise of at least `highlightPoints`.
        let mostImproved: Int?
        /// The caller's position of the largest drop of at least `highlightPoints`, never a habit
        /// at `slippedCeilingPercent` or more this week.
        let slipped: Int?
        /// By group in `groupOrder`, Ungrouped last, empty groups left out.
        let sections: [Section]
    }

    /// A week not yet over is compared only once this many of its days are counted (D8).
    static let countedDaysForChange = 4
    /// "Most improved" and "Slipped" need a change of at least this many points (D8).
    static let highlightPoints = 10
    /// A habit at this percent or more this week is never "Slipped" (D8).
    static let slippedCeilingPercent = 80

    /// The review of `week` for `habits` (archived ones are left out).
    ///
    /// - The change and the highlights compare each habit with itself, its week against the
    ///   previous one, in the points the two rates print. A week not over yet is compared only
    ///   once `countedDaysForChange` of its days are counted, as the Pro cards count them (from
    ///   `startDay`, through the last counted day: today once it is done, else yesterday), per
    ///   habit: until then a Tuesday with 1 of 1 done (100 %) would read "+40" against last
    ///   week's 60 %. The previous week needs as many counted days, and a times-per-week habit's
    ///   week must be over or have met its goal (`Row.countsChange`); a habit that fails either has no change, and is
    ///   left out of the mean change and of the highlights.
    /// - A tie for the largest rise or drop goes to the habit first in the caller's order.
    /// - `groupOrder`: the user's groups in their order; empty when the user has none (then one
    ///   section, `groupID` nil, holds every row).
    static func review(of habits: [HabitInput], week: WeekRange, groupOrder: [UUID] = []) -> Review {
        var rows: [Row] = []
        rows.reserveCapacity(habits.count)
        var finished: Bool?
        for (index, habit) in habits.enumerated() where !habit.isArchived {
            let stats = habit.stats
            finished = (finished ?? true) && isOver(week, for: stats)
            let rate = stats.countedRate(ofWeekStarting: week.monday)
            let previous = stats.countedRate(ofWeekStarting: week.previous.monday)
            let counts = countsChange(stats, week: week)
            var change: Int?
            if counts, let rate, let previous {
                change = StatsInsights.percent(rate) - StatsInsights.percent(previous)
            }
            rows.append(Row(index: index, rate: rate, previousRate: previous,
                            endsBeforeStart: stats.endsBeforeStart(weekStarting: week.monday),
                            countsChange: counts, changePoints: change))
        }

        // The change line speaks for the ring: only when every row the ring averages (every row
        // with a rate) has a change. Otherwise a new habit at 0 %, or a times-per-week habit
        // mid-week, lowers the ring under a "+15 points" line that leaves it out (pre-freeze
        // review, A3). The highlights still name single habits.
        let changes = rows.compactMap(\.changePoints)
        let sameCohort = rows.allSatisfy { $0.rate == nil || $0.changePoints != nil }
        let changePoints = changes.isEmpty || !sameCohort
            ? nil : Int((Double(changes.reduce(0, +)) / Double(changes.count)).rounded())

        var improved: Row?, slipped: Row?
        for row in rows {
            guard let change = row.changePoints, let rate = row.rate else { continue }
            if change >= highlightPoints, change > (improved?.changePoints ?? .min) { improved = row }
            if change <= -highlightPoints, StatsInsights.percent(rate) < slippedCeilingPercent,
               change < (slipped?.changePoints ?? .max) { slipped = row }
        }

        return Review(week: week, isFinished: finished ?? false, rows: rows,
                      overall: mean(rows.map(\.rate)), changePoints: changePoints,
                      mostImproved: improved?.index, slipped: slipped?.index,
                      sections: sections(of: rows, habits: habits, groupOrder: groupOrder))
    }

    /// Whether `week` ended before the day `stats` was built for.
    private static func isOver(_ week: WeekRange, for stats: HabitStats) -> Bool {
        week.sundayNumber < HabitStats.dayNumber(ofKey: stats.today)
    }

    /// Whether `stats`' `week` may be compared with the week before it (D8; `Row.countsChange`):
    /// the previous week has at least `countedDaysForChange` counted days, and `week` is over, or,
    /// for a daily or specific-days habit, has that many counted days itself. A times-per-week
    /// habit waits for its week to end, unless the week has already met its goal (`timesPerWeek`
    /// check-ins): its rate is then 100 % and final — no later day can lower it — so comparing it
    /// is true (follow-up to pre-freeze review A4: without it a 3-times-a-week habit never had
    /// momentum). Before that, one check-in on a Thursday reads 100 % of what is owed so far.
    /// Insights' momentum reads the same rule for this week (`StatsInsights.momentum(for:)`), so
    /// the two cards never disagree about what may be compared.
    static func countsChange(_ stats: HabitStats, week: WeekRange) -> Bool {
        let shownCounts = isOver(week, for: stats) || metWeeklyGoal(stats, week: week)
            || (stats.schedule != .timesPerWeek
                && stats.countedDayCount(ofWeekStarting: week.monday) >= countedDaysForChange)
        return shownCounts && stats.countedDayCount(ofWeekStarting: week.previous.monday) >= countedDaysForChange
    }

    /// A times-per-week habit whose `week` already holds `timesPerWeek` check-ins (at least 1).
    /// Its counted rate is then 100 % whatever the remaining days bring; a habit created mid-week
    /// owes only a share of the goal, so the whole goal is more than enough.
    static func metWeeklyGoal(_ stats: HabitStats, week: WeekRange) -> Bool {
        stats.schedule == .timesPerWeek && stats.weeklyCompletions(weekStarting: week.monday) >= max(1, stats.timesPerWeek)
    }

    /// The rows by group (D9: "Sections by group, Ungrouped last"), as Today groups them: a habit
    /// whose group is gone is Ungrouped, and a group with no row has no section.
    private static func sections(of rows: [Row], habits: [HabitInput], groupOrder: [UUID]) -> [Section] {
        func section(_ id: UUID?, _ members: [Row]) -> Section {
            Section(groupID: id, members: members.map(\.index), rate: mean(members.map(\.rate)))
        }
        guard !groupOrder.isEmpty else { return rows.isEmpty ? [] : [section(nil, rows)] }
        let known = Set(groupOrder)
        var byGroup: [UUID: [Row]] = [:], ungrouped: [Row] = []
        for row in rows {
            if let id = habits[row.index].groupID, known.contains(id) {
                byGroup[id, default: []].append(row)
            } else {
                ungrouped.append(row)
            }
        }
        var result: [Section] = []
        var seen = Set<UUID>()
        for id in groupOrder where seen.insert(id).inserted {
            if let members = byGroup[id] { result.append(section(id, members)) }
        }
        if !ungrouped.isEmpty { result.append(section(nil, ungrouped)) }
        return result
    }

    /// The change in strength over `week` (D9's chip), in the whole points the scores print
    /// (`HabitScore.displayValue`): the end-of-week score (the latest, for this week) against the
    /// previous week's. Nil for a week that ended before the habit's start or starts after today.
    /// Reading it walks the habit's strength once (`HabitStats.strengthSeries`, cached).
    static func strengthChangePoints(of stats: HabitStats, week: WeekRange) -> Int? {
        stats.strengthWeekEnds(ofWeekStarting: week.monday).map {
            HabitScore.displayValue($0.end) - HabitScore.displayValue($0.previous)
        }
    }

    // MARK: At risk (D10)

    /// A clock time, local.
    struct TimeOfDay: Equatable, Comparable {
        let hour: Int
        let minute: Int

        init(hour: Int, minute: Int) {
            self.hour = hour
            self.minute = minute
        }

        /// 18:00, when neither the habit's reminder nor the Daily Reminder is on.
        static let defaultEvening = TimeOfDay(hour: 18, minute: 0)

        var minutes: Int { hour * 60 + minute }

        static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutes < b.minutes }
    }

    /// The evening time after which a daily or specific-days habit not done today is at risk
    /// (D10): the habit's own reminder time when its reminder is on, else the Daily Reminder's
    /// when that is on (NotificationService's, passed in: Shared/ never reads it), else 18:00.
    static func eveningTime(habitReminder: TimeOfDay?, dailyReminder: TimeOfDay?) -> TimeOfDay {
        habitReminder ?? dailyReminder ?? .defaultEvening
    }

    /// A times-per-week habit's Monday-anchored week so far (D10).
    struct WeekGoal: Equatable {
        /// Check-ins this week, today's included.
        let done: Int
        /// The weekly goal (`timesPerWeek`, at least 1).
        let goal: Int
        /// goal − done, never below 0. 0: the whole goal is met. `DailyProgress.State.metForWeek`
        /// reads `owed`, which is the same outside the habit's first week.
        let remaining: Int
        /// The days still open for a check-in: today if it is not done yet, through Sunday.
        let daysLeft: Int
        /// Every day left is needed and the goal can still be met: owed > 0 and owed == daysLeft
        /// (`owed` > 0, `isReachable`, and no day to spare). In the week the habit started, if that
        /// was after its Monday, the week owes only its share of the goal (goal × days from the
        /// start ÷ 7, rounded up), as its rate does: a 3-times-a-week habit created on Saturday is
        /// not at risk at once.
        ///
        /// Not once the goal is out of reach (owed > daysLeft: Saturday at 0 of 3, or Sunday at 1
        /// of 3 not done today): no check-in can save that week any more, so nothing calls it
        /// "at risk" and no row asks for a "more" the user cannot do (integrator's call,
        /// 2026-11-27, on RELEASE-1.5.0.md D7; before, owed ≥ daysLeft flagged it). Today's row
        /// then reads the plain count (`TodayAtRisk.Words.weekSoFar`), and the Weekly Review's
        /// "At risk this week" leaves it out.
        let isAtRisk: Bool
        /// What the row prints as "N more" (RELEASE-1.5.0.md D7): the creation week's share less
        /// `done` (never below 0) in the week the habit started after its Monday, else
        /// `remaining`. A 3-times-a-week habit made on Friday reads "1 more", not "3 more · 2 days
        /// left", on Saturday (Spec corrections, D10's at-risk rule): the number is the one
        /// `isAtRisk` weighs. It can be 0 while `remaining` is not (the share met, the whole goal
        /// not): nothing is owed, and `DailyProgress` reads the day as `.metForWeek`.
        let owed: Int
        /// Today is the week's last day (Sunday): the row reads "N more · today", never "0 days
        /// left" (D7). `daysLeft` is then 1, or 0 once today is done.
        let isLastDay: Bool

        /// What the week still owes fits the days left (owed ≤ daysLeft): the goal (or, in the
        /// creation week, its share) can still be met. Met weeks are reachable.
        var isReachable: Bool { owed <= daysLeft }

        init(done: Int, goal: Int, remaining: Int, daysLeft: Int, isAtRisk: Bool, owed: Int, isLastDay: Bool) {
            self.done = done
            self.goal = goal
            self.remaining = remaining
            self.daysLeft = daysLeft
            self.isAtRisk = isAtRisk
            self.owed = owed
            self.isLastDay = isLastDay
        }
    }

    /// `now`'s day number, keyed as an instant.
    private static func todayNumber(_ now: Date, _ calendar: Calendar) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: now, calendar: calendar))
    }

    /// A times-per-week habit's week so far; nil for any other schedule. `stats` must have been
    /// built for `now`'s day (StatsCache's `today`), or later.
    static func weekGoal(of stats: HabitStats, now: Date, calendar: Calendar) -> WeekGoal? {
        weekGoal(of: stats, on: HabitStats.key(ofDay: todayNumber(now, calendar)))
    }

    /// `weekGoal(of:now:calendar:)` as of the day-key `dayKey` (UTC midnight, never re-read as an
    /// instant): its Monday week's check-ins from the Monday through `dayKey`, the days left from
    /// `dayKey` through Sunday. `DailyProgress` reads `.remaining` for any day (a past day of the
    /// review, a widget entry's next day). `stats` must have been built for `dayKey`, or later:
    /// check-ins after the day `stats` was built for are not there.
    static func weekGoal(of stats: HabitStats, on dayKey: Date) -> WeekGoal? {
        guard stats.schedule == .timesPerWeek else { return nil }
        let today = HabitStats.dayNumber(ofKey: dayKey)
        let todayKey = HabitStats.key(ofDay: today)
        let week = WeekRange(containingDay: today)
        let goal = max(1, stats.timesPerWeek)
        let done = stats.completedDayCount(from: week.monday, to: todayKey)
        let doneToday = stats.isCompleted(on: todayKey)
        let daysLeft = week.sundayNumber - today + (doneToday ? 0 : 1)
        let remaining = max(0, goal - done)
        // The week the habit started in owes its share, rounded up.
        let start = HabitStats.dayNumber(ofKey: stats.startDay)
        let owedGoal = start > week.mondayNumber
            ? Int((Double(goal) * Double(week.sundayNumber - start + 1) / 7).rounded(.up))
            : goal
        let owed = max(0, owedGoal - done)
        return WeekGoal(done: done, goal: goal, remaining: remaining, daysLeft: daysLeft,
                        isAtRisk: owed > 0 && owed == daysLeft, owed: owed,
                        isLastDay: today == week.sundayNumber)
    }

    /// Whether a habit is at risk at `now` (D10). Never an archived habit.
    /// - times-per-week: `weekGoal`'s `isAtRisk`, whatever the hour: every day left is needed,
    ///   and the goal is still within reach (not once it is out of reach, RELEASE-1.5.0.md D7);
    /// - daily and specific days: `.due` today by `DailyProgress` (scheduled, not done — a count
    ///   habit: its target not reached — and started), and the local clock at or past
    ///   `eveningTime`. The "due and not done" rule is DailyProgress's (RELEASE-1.5.0.md D1), so
    ///   Today's words, the badge and the review never disagree about it.
    ///
    /// `stats` must have been built for `now`'s day (StatsCache's `today`), or later.
    static func isAtRisk(_ stats: HabitStats, isArchived: Bool, now: Date, calendar: Calendar,
                         eveningTime: TimeOfDay) -> Bool {
        guard !isArchived else { return false }
        if stats.schedule == .timesPerWeek {
            return weekGoal(of: stats, now: now, calendar: calendar)?.isAtRisk ?? false
        }
        let todayKey = HabitStats.key(ofDay: todayNumber(now, calendar))
        guard DailyProgress.state(of: stats, on: todayKey) == .due else { return false }
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        return TimeOfDay(hour: clock.hour ?? 0, minute: clock.minute ?? 0) >= eveningTime
    }

    /// `isAtRisk` with the habit's own fields: its archive flag and, when on, its reminder time.
    /// `dailyReminder`: the Daily Reminder's time when it is on (NotificationService), else nil.
    static func isAtRisk(_ habit: Habit, stats: HabitStats, now: Date, calendar: Calendar,
                         dailyReminder: TimeOfDay?) -> Bool {
        let own = habit.reminderEnabled ? TimeOfDay(hour: habit.reminderHour, minute: habit.reminderMinute) : nil
        return isAtRisk(stats, isArchived: habit.isArchived, now: now, calendar: calendar,
                        eveningTime: eveningTime(habitReminder: own, dailyReminder: dailyReminder))
    }

    // MARK: Any week: navigation bounds (RELEASE-1.5.0.md D6)

    /// The weeks ‹ and › can reach (D6): from the week containing the earliest `startDay` to this
    /// week (`now`'s local date in `calendar`, keyed as an instant). `earliestStart` is a day-key
    /// (a `HabitStats.startDay`); nil (no habit), or a start after this week (a creation stamp
    /// from a device whose clock is ahead), gives this week alone.
    static func weekBounds(earliestStart: Date?, now: Date, calendar: Calendar) -> ClosedRange<WeekRange> {
        let thisWeek = WeekRange(containingDay: todayNumber(now, calendar))
        guard let earliestStart else { return thisWeek...thisWeek }
        let first = WeekRange(containingDay: HabitStats.dayNumber(ofKey: earliestStart))
        return min(first, thisWeek)...thisWeek
    }

    /// `weekBounds(earliestStart:now:calendar:)` over the habits the review shows (archived ones
    /// left out, as `openingReview` reads `earliestStart`).
    static func weekBounds(of habits: [HabitInput], now: Date, calendar: Calendar) -> ClosedRange<WeekRange> {
        weekBounds(earliestStart: habits.filter { !$0.isArchived }.map(\.stats.startDay).min(),
                   now: now, calendar: calendar)
    }

    // MARK: The strip (D6)

    /// One cell of a habit's 7-day strip (D6).
    enum DayState: Equatable, Hashable, CaseIterable {
        /// A check-in (a count habit: its target reached), on any day, a rest day included.
        case done
        /// A past day that was due and was not done: a daily day, a specific-days scheduled day,
        /// or a count habit's partial day (never a times-per-week day).
        case missed
        /// A specific-days off-day without a check-in.
        case rest
        /// Times-per-week, a day without a check-in that is not today: neutral, never `missed` —
        /// the goal belongs to the week, not to a day.
        case neutral
        /// Before the habit's `startDay`: it did not exist yet.
        case beforeStart
        /// After today.
        case future
        /// Today, due and not done yet (a count habit's partial today included): still open,
        /// never a miss.
        case todayOpen
    }

    /// The 7 cells of `week`, Monday through Sunday, for the habit `stats` describes, relative to
    /// the day `stats` was built for (`stats.today`).
    ///
    /// Each day reads `DailyProgress.state`, then: before the start → `.beforeStart`; after today
    /// → `.future`; `.done` → `.done`; `.rest` → `.rest`; times-per-week not done (open, or the
    /// week met) → `.todayOpen` today while open, else `.neutral`; any other open day →
    /// `.todayOpen` today, `.missed` before it.
    ///
    /// It agrees with the row's counted rate (`HabitStats.countedRate(ofWeekStarting:)`), so the
    /// strip never disproves the number beside it: for a daily or specific-days habit the rate is
    /// the `.done` cells on scheduled days over those plus the `.missed` cells (today counts once
    /// it is done, as the rate's last counted day; `.todayOpen` is in neither); for times-per-week
    /// the `.done` cells are the week's check-ins the rate credits (StrideTests,
    /// `testTheStripAgreesWithTheCountedRate`).
    static func dayStates(of stats: HabitStats, week: WeekRange) -> [DayState] {
        let today = HabitStats.dayNumber(ofKey: stats.today)
        return (week.mondayNumber...week.sundayNumber).map { day in
            let key = HabitStats.key(ofDay: day)
            let state = DailyProgress.state(of: stats, on: key)
            if state == .notStarted { return .beforeStart }
            if day > today { return .future }
            switch state {
            case .done: return .done
            case .rest: return .rest
            case .notStarted: return .beforeStart
            case .metForWeek: return .neutral
            case .due:
                if day == today { return .todayOpen }
                return stats.schedule == .timesPerWeek ? .neutral : .missed
            }
        }
    }

    /// What the strip says as one accessibility element ("5 of 7 done, 1 rest day", D6), counted
    /// from its cells and the habit's schedule.
    ///
    /// Integrator's calls (2026-11-27, Gemini review of the 1.5.0 surfaces; the lens: no number on
    /// screen may contradict another):
    /// - `days` leaves today out while it is still open (`.todayOpen`): the row's counted rate
    ///   beside it does not count an unfinished today either, so a week of 3 done days and today
    ///   open reads "3 of 3 done" next to 100 %, never "3 of 4". The cell is still drawn.
    /// - `rest` counts every unscheduled day of a specific-days habit the summary covers, done or
    ///   not: a Mon/Wed/Fri habit checked in only on a Tuesday reads "1 of 7 done, 4 rest days",
    ///   not "… 3 rest days" with the Tuesday neither done-and-due nor rest. The done cell is
    ///   still drawn done.
    struct StripSummary: Equatable {
        /// `.done` cells (a check-in on a rest day included).
        let done: Int
        /// The unscheduled days among `days` (specific days only), done or not.
        let rest: Int
        /// `.missed` cells.
        let missed: Int
        /// The cells the habit existed for and that have begun, today once it is no longer open:
        /// neither `.beforeStart`, `.future` nor `.todayOpen`. 7 for a whole past week the habit
        /// existed in.
        let days: Int

        init(done: Int, rest: Int, missed: Int, days: Int) {
            self.done = done
            self.rest = rest
            self.missed = missed
            self.days = days
        }

        /// The summary of `states` (`dayStates`, Monday first); `isRestDay[i]` says whether day
        /// `i` is unscheduled for the habit. Left out, only the `.rest` cells are rest days.
        init(_ states: [DayState], isRestDay: [Bool]? = nil) {
            var done = 0, rest = 0, missed = 0, days = 0
            for (i, state) in states.enumerated() {
                if state == .beforeStart || state == .future || state == .todayOpen { continue }
                days += 1
                if state == .done { done += 1 }
                if state == .missed { missed += 1 }
                let restDay = isRestDay.map { i < $0.count && $0[i] } ?? (state == .rest)
                if restDay || state == .rest { rest += 1 }
            }
            self.init(done: done, rest: rest, missed: missed, days: days)
        }
    }

    /// `dayStates(of:week:)`'s summary, with the habit's own rest days (done ones included).
    static func stripSummary(of stats: HabitStats, week: WeekRange) -> StripSummary {
        stripSummary(of: stats, week: week, states: dayStates(of: stats, week: week))
    }

    /// The summary of `states`, the cells `dayStates(of: stats, week: week)` already drew.
    static func stripSummary(of stats: HabitStats, week: WeekRange, states: [DayState]) -> StripSummary {
        let isRestDay = (week.mondayNumber...week.sundayNumber).map {
            !stats.isScheduled(on: HabitStats.key(ofDay: $0))
        }
        return StripSummary(states, isRestDay: isRestDay)
    }

    // MARK: Perfect days (D6)

    /// The days of `week`, through today, that were perfect (`DailyProgress.isPerfect`: something
    /// was due and every habit due was done) over `habits` (archived ones left out), oldest first.
    /// Each day is read as of its own end: a times-per-week habit counts in it as due until its
    /// week's goal was met by that day, as Today's card showed it then. A day with nothing due is
    /// never perfect. Today is "today" of the stats (`HabitStats.today`; the earliest, should
    /// they differ).
    static func perfectDays(of habits: [HabitInput], week: WeekRange) -> [Date] {
        let live = habits.filter { !$0.isArchived }.map(\.stats)
        guard let today = live.map({ HabitStats.dayNumber(ofKey: $0.today) }).min() else { return [] }
        let last = min(week.sundayNumber, today)
        guard week.mondayNumber <= last else { return [] }
        return (week.mondayNumber...last).map(HabitStats.key(ofDay:)).filter {
            DailyProgress(of: live, on: $0).isPerfect
        }
    }

    /// "N perfect days" for `week` (D6): `perfectDays(of:week:)`'s count.
    static func perfectDayCount(of habits: [HabitInput], week: WeekRange) -> Int {
        perfectDays(of: habits, week: week).count
    }

    // MARK: Helpers

    private static func mean(_ rates: [Double?]) -> Double? {
        let known = rates.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }
}
