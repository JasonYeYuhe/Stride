import Foundation

/// The Weekly Review's and Today's week math (RELEASE-1.4.2.md D8, D9's numbers, D10): which week
/// the review opens on, each habit's counted rate for any week and its change, the highlights,
/// the group section rates, and when a habit is at risk. Every number comes from the habits'
/// `HabitStats` (StatsCache, read once per render, Data safety 4); this decides what may be said
/// about them.
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
    /// (`.weeklyReview(week:)`; any day of it, a day-key or an instant), never later than this
    /// week; otherwise this week from its fourth day (Thursday 00:00 local) on, else last week.
    ///
    /// `now` is an instant, keyed by its local date in `calendar`
    /// (`HabitCalendar.dayKey(forInstant:calendar:)`): Thursday 00:00 in Los Angeles is
    /// 07:00 or 08:00 UTC, and Sunday 16:00 PST is exactly UTC midnight of Monday.
    static func openingWeek(now: Date, calendar: Calendar, requested: Date? = nil) -> OpeningWeek {
        let todayNumber = HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: now, calendar: calendar))
        let thisWeek = WeekRange(containingDay: todayNumber)
        let week: WeekRange
        if let requested {
            week = min(weekRange(containing: requested, in: calendar), thisWeek)
        } else if todayNumber - thisWeek.mondayNumber + 1 >= daysBeforeThisWeekOpens {
            week = thisWeek
        } else {
            week = thisWeek.previous
        }
        let relation: Relation = week == thisWeek ? .thisWeek : week == thisWeek.previous ? .lastWeek : .earlier
        return OpeningWeek(week: week, relation: relation)
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
        /// Whether the week may be compared yet (D8): it is over, or at least
        /// `countedDaysForChange` of its days are counted (`HabitStats.countedDayCount`).
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
        /// when no row has one; 0 reads "Level with the previous week".
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
    ///   week's 60 %.
    /// - A tie for the largest rise or drop goes to the habit first in the caller's order.
    /// - `groupOrder`: the user's groups in their order; empty when the user has none (then one
    ///   section, `groupID` nil, holds every row).
    static func review(of habits: [HabitInput], week: WeekRange, groupOrder: [UUID] = []) -> Review {
        var rows: [Row] = []
        rows.reserveCapacity(habits.count)
        var finished: Bool?
        for (index, habit) in habits.enumerated() where !habit.isArchived {
            let stats = habit.stats
            let todayNumber = HabitStats.dayNumber(ofKey: stats.today)
            let over = week.sundayNumber < todayNumber
            finished = (finished ?? true) && over
            let rate = stats.countedRate(ofWeekStarting: week.monday)
            let previous = stats.countedRate(ofWeekStarting: week.previous.monday)
            let counts = over || stats.countedDayCount(ofWeekStarting: week.monday) >= countedDaysForChange
            var change: Int?
            if counts, let rate, let previous {
                change = StatsInsights.percent(rate) - StatsInsights.percent(previous)
            }
            rows.append(Row(index: index, rate: rate, previousRate: previous,
                            endsBeforeStart: stats.endsBeforeStart(weekStarting: week.monday),
                            countsChange: counts, changePoints: change))
        }

        let changes = rows.compactMap(\.changePoints)
        let changePoints = changes.isEmpty
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
        /// goal − done, never below 0: "N more this week".
        let remaining: Int
        /// The days still open for a check-in: today if it is not done yet, through Sunday.
        let daysLeft: Int
        /// The check-ins still owed cannot fit the days left: remaining > 0 and
        /// remaining ≥ daysLeft. In the week the habit started, if that was after its Monday, the
        /// week owes only its share of the goal (goal × days from the start ÷ 7, rounded up), as
        /// its rate does: a 3-times-a-week habit created on Saturday is not at risk at once.
        let isAtRisk: Bool
    }

    /// `now`'s day number, keyed as an instant.
    private static func todayNumber(_ now: Date, _ calendar: Calendar) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: now, calendar: calendar))
    }

    /// A times-per-week habit's week so far; nil for any other schedule. `stats` must have been
    /// built for `now`'s day (StatsCache's `today`), or later.
    static func weekGoal(of stats: HabitStats, now: Date, calendar: Calendar) -> WeekGoal? {
        guard stats.schedule == .timesPerWeek else { return nil }
        let today = todayNumber(now, calendar)
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
                        isAtRisk: owed > 0 && owed >= daysLeft)
    }

    /// Whether a habit is at risk at `now` (D10). Never an archived habit.
    /// - times-per-week: `weekGoal`'s `isAtRisk`, whatever the hour;
    /// - daily and specific days: scheduled today, not done (a count habit: its target not
    ///   reached), and the local clock at or past `eveningTime`.
    ///
    /// `stats` must have been built for `now`'s day (StatsCache's `today`), or later.
    static func isAtRisk(_ stats: HabitStats, isArchived: Bool, now: Date, calendar: Calendar,
                         eveningTime: TimeOfDay) -> Bool {
        guard !isArchived else { return false }
        if stats.schedule == .timesPerWeek {
            return weekGoal(of: stats, now: now, calendar: calendar)?.isAtRisk ?? false
        }
        let todayKey = HabitStats.key(ofDay: todayNumber(now, calendar))
        guard stats.isScheduled(on: todayKey), !stats.isCompleted(on: todayKey) else { return false }
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

    // MARK: Helpers

    private static func mean(_ rates: [Double?]) -> Double? {
        let known = rates.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }
}
