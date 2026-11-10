import XCTest
import SwiftData
import Foundation

/// What the Pro cards may say (`StatsInsights`, `HabitStats.countedRate` and `weekdayTallies`):
/// Insights' strongest and toughest weekday and its momentum, the 8-week Trend's weeks, and
/// Weekly Review's numbers. Each case below is a user doing well whom 1.4.1 (23) told something
/// wrong or discouraging (churn investigation, 2026-10-22):
/// - a user who never misses got "Toughest on Sunday", and a "Strongest" day picked from a
///   Dictionary's per-process order;
/// - on Monday before the check-in, the week so far read 0% and "Down vs last week (100% → 0%)",
///   in Insights and in Weekly Review alike;
/// - a habit created three weeks ago drew five grey bars marked 0 in the Trend, as if missed.
///
/// The review of that fix (bab8acf, 2026-10-22) added three: "3 times a week" on track read as down
/// until its Sunday check-in; Weekly Review's change subtracted means over different habits; and
/// VoiceOver said "Not started" for this week of a habit with months of history.
///
/// Dates are fixed UTC day-keys (2026-06-01 is a Monday), as in StatsMathTests, so none of this
/// depends on the day or the time zone the tests run in.
@MainActor
final class StatsInsightsTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let utc = HabitCalendar.utc

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func day(_ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func days(_ first: Date, through last: Date) -> [Date] {
        var out: [Date] = [], d = first
        while d <= last { out.append(d); d = utc.date(byAdding: .day, value: 1, to: d)! }
        return out
    }

    private func habit(_ schedule: HabitSchedule = .daily, timesPerWeek: Int = 7, activeDays: Int = 127,
                       created: Date) -> Habit {
        let h = Habit(name: "Habit")
        h.schedule = schedule
        h.timesPerWeek = timesPerWeek
        h.activeDaysMask = activeDays
        h.createdAt = created
        context.insert(h)
        return h
    }

    private func checkIn(_ h: Habit, on dates: [Date]) {
        for d in dates { h.records.append(HabitRecord(date: d)) }
    }

    private func stats(_ h: Habit, today: Date) -> HabitStats {
        HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context), calendar: utc, today: today)
    }

    private func extremes(_ s: HabitStats) -> StatsInsights.WeekdayExtremes {
        StatsInsights.weekdayExtremes(s.weekdayTallies, schedule: s.schedule, activeDaysMask: s.activeDaysMask)
    }

    private func tally(_ done: Int, of due: Int) -> StatsInsights.WeekdayTally {
        StatsInsights.WeekdayTally(done: done, due: due)
    }

    /// Daily tallies, Sunday (1) first.
    private func week(_ tallies: [StatsInsights.WeekdayTally]) -> [Int: StatsInsights.WeekdayTally] {
        Dictionary(uniqueKeysWithValues: tallies.enumerated().map { ($0.offset + 1, $0.element) })
    }

    private let none = StatsInsights.WeekdayExtremes()
    private let monWedFriMask = (1 << 1) | (1 << 3) | (1 << 5)   // bit 0 = Sunday

    // MARK: - Strongest and toughest weekday

    /// Every weekday alike — all done, half done, none done — has no strongest and no toughest
    /// day. 1.4.1 (23) said "Toughest on Sunday" (the first of equal minimums, Sunday first) and a
    /// "Strongest" day from a Dictionary's order, which changes between launches.
    func testEveryWeekdayAlikeHasNeitherDay() {
        for t in [tally(10, of: 10), tally(5, of: 10), tally(0, of: 10)] {
            XCTAssertEqual(StatsInsights.weekdayExtremes(week(Array(repeating: t, count: 7)), schedule: .daily,
                                                         activeDaysMask: 127), none, "\(t)")
        }
    }

    /// Monday and Tuesday share the top: no strongest day. Saturday is alone at the bottom.
    func testTwoWeekdaysTiedForTheTopHaveNoStrongestDay() {
        let tallies = week([tally(8, of: 10), tally(10, of: 10), tally(10, of: 10), tally(8, of: 10),
                            tally(8, of: 10), tally(8, of: 10), tally(5, of: 10)])
        XCTAssertEqual(StatsInsights.weekdayExtremes(tallies, schedule: .daily, activeDaysMask: 127),
                       StatsInsights.WeekdayExtremes(strongest: nil, toughest: 7))
    }

    /// The bottom equal to the top — two weekdays at the same rate from different counts (3 of 4,
    /// 6 of 8) — is neither day: the rates are compared exactly, not as rounded fractions.
    func testTheMinimumEqualToTheMaximumIsNeitherDay() {
        let mask = (1 << 1) | (1 << 3)   // Mon, Wed
        XCTAssertEqual(StatsInsights.weekdayExtremes([2: tally(3, of: 4), 4: tally(6, of: 8)], schedule: .specificDays,
                                                     activeDaysMask: mask), none)
    }

    /// One weekday alone at the top and one alone at the bottom: both named.
    func testAWeekdayAloneAtTheTopOrBottomIsNamed() {
        let tallies = week([tally(2, of: 9), tally(9, of: 10), tally(5, of: 10), tally(5, of: 10),
                            tally(5, of: 10), tally(5, of: 10), tally(5, of: 9)])
        XCTAssertEqual(StatsInsights.weekdayExtremes(tallies, schedule: .daily, activeDaysMask: 127),
                       StatsInsights.WeekdayExtremes(strongest: 2, toughest: 1))
    }

    /// Rates, not counts: one more Monday than any other day (the span started on a Monday and
    /// ends on one), all done. Counts would make Monday the strongest day.
    func testMoreOfOneWeekdayDoneIsNotAStrongerDay() {
        var tallies = week(Array(repeating: tally(10, of: 10), count: 7))
        tallies[2] = tally(11, of: 11)
        XCTAssertEqual(StatsInsights.weekdayExtremes(tallies, schedule: .daily, activeDaysMask: 127), none)
    }

    /// Times per week has no weekday schedule — HabitStats.isScheduled calls every day of it due —
    /// so no day of it is strong or tough, whatever was done when; and it is never tallied.
    func testTimesPerWeekHasNoWeekdayInsight() {
        let skewed = week([tally(0, of: 10), tally(10, of: 10), tally(5, of: 10), tally(5, of: 10),
                           tally(5, of: 10), tally(5, of: 10), tally(5, of: 10)])
        XCTAssertEqual(StatsInsights.weekdayExtremes(skewed, schedule: .timesPerWeek, activeDaysMask: 127), none)

        let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(6, 1))
        checkIn(h, on: (0..<4).flatMap { w in [0, 1].map { utc.date(byAdding: .day, value: 7 * w + $0, to: day(6, 1))! } })
        let s = stats(h, today: day(6, 30))
        XCTAssertEqual(s.weekdayTallies, [:])
        XCTAssertEqual(extremes(s), none)
    }

    /// Until every scheduled weekday has come due once, there is nothing to compare: Sunday has
    /// not happened yet, and it is not a weak day.
    func testAWeekdayThatHasNotComeDueSaysNothing() {
        var tallies = week(Array(repeating: tally(1, of: 1), count: 7))
        tallies[3] = tally(0, of: 1)   // Tuesday missed
        tallies[1] = nil                // Sunday not yet due
        XCTAssertEqual(StatsInsights.weekdayExtremes(tallies, schedule: .daily, activeDaysMask: 127), none)
        // One scheduled weekday has nothing to be compared with.
        XCTAssertEqual(StatsInsights.weekdayExtremes([2: tally(4, of: 5)], schedule: .specificDays,
                                                     activeDaysMask: 1 << 1), none)
    }

    /// A user who never misses, on every day of three weeks — today done or not yet: never a
    /// strongest or toughest day. On the Saturdays (after the check-in) and Sundays (before it)
    /// 1.4.1 (23) said "Toughest on Sunday": six of every weekday done, five Sundays.
    func testANeverMissingUserHasNeitherDayOnAnyDay() {
        for today in days(day(6, 1), through: day(6, 21)) {
            for doneToday in [false, true] {
                let h = habit(created: day(6, 1))
                let yesterday = utc.date(byAdding: .day, value: -1, to: today)!
                checkIn(h, on: days(day(6, 1), through: doneToday ? today : yesterday))
                XCTAssertEqual(extremes(stats(h, today: today)), none, "\(today), done today: \(doneToday)")
            }
        }
    }

    /// The tallies count scheduled days from the start through yesterday, and today once it is
    /// done; a check-in on a rest day is not one of them. Mon/Wed/Fri from Mon 06-01: Mon 06-01,
    /// Wed 06-03 and Mon 06-08 done, Fri 06-05 missed, a Tuesday check-in, and today Wed 06-10.
    func testTalliesCountScheduledDaysThroughTheLastCountedDay() {
        let h = habit(.specificDays, activeDays: monWedFriMask, created: day(6, 1))
        checkIn(h, on: [day(6, 1), day(6, 2), day(6, 3), day(6, 8)])
        let before = stats(h, today: day(6, 10))

        XCTAssertEqual(before.weekdayTallies, [2: tally(2, of: 2), 4: tally(1, of: 1), 6: tally(0, of: 1)])
        // Monday and Wednesday share the top; Friday, the one miss, is alone at the bottom.
        XCTAssertEqual(extremes(before), StatsInsights.WeekdayExtremes(strongest: nil, toughest: 6))

        checkIn(h, on: [day(6, 10)])
        XCTAssertEqual(stats(h, today: day(6, 10)).weekdayTallies[4], tally(2, of: 2), "today counts once it is done")
    }

    // MARK: - Momentum and the week so far

    /// Last week all done; Monday, before the check-in. This week has nothing to count yet, so
    /// there is no momentum — 1.4.1 (23) counted today as a miss: "Down vs last week (100% → 0%)".
    func testMondayBeforeTheCheckInHasNoMomentum() {
        let h = habit(created: day(5, 1))
        checkIn(h, on: days(day(5, 1), through: day(5, 31)))
        let s = stats(h, today: day(6, 1))

        XCTAssertEqual(s.completionRate(from: day(6, 1), to: day(6, 1)), 0, "what the old momentum read")
        XCTAssertNil(s.thisWeekRate)
        XCTAssertEqual(s.lastWeekRate, 1)
        XCTAssertNil(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate))
    }

    /// The same Monday after the check-in: level with last week, which reads as up.
    func testMondayAfterTheCheckInIsLevelWithLastWeek() {
        let h = habit(created: day(5, 1))
        checkIn(h, on: days(day(5, 1), through: day(6, 1)))
        let s = stats(h, today: day(6, 1))

        XCTAssertEqual(s.thisWeekRate, 1)
        let momentum = StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate)
        XCTAssertEqual(momentum, StatsInsights.Momentum(was: 100, now: 100))
        XCTAssertEqual(momentum?.isUp, true)
    }

    /// Midweek, today not done yet: the week so far ends yesterday. Monday and Tuesday done is
    /// 100%, not 67%; a missed Tuesday is a real 50%, and down.
    func testAnUnfinishedTodayIsNotAMissMidweek() {
        let h = habit(created: day(5, 1))
        checkIn(h, on: days(day(5, 25), through: day(6, 2)))
        XCTAssertEqual(stats(h, today: day(6, 3)).thisWeekRate, 1)

        let missed = habit(created: day(5, 1))
        checkIn(missed, on: days(day(5, 25), through: day(6, 1)))
        let s = stats(missed, today: day(6, 3))
        XCTAssertEqual(s.thisWeekRate, 0.5)
        XCTAssertEqual(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate),
                       StatsInsights.Momentum(was: 100, now: 50))
    }

    /// "3 times a week", met last week; Monday before the check-in has nothing to count, and the
    /// check-in alone is on track: nothing is owed yet.
    func testATimesPerWeekMondayWaitsForTheCheckIn() {
        let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(5, 1))
        checkIn(h, on: [day(5, 25), day(5, 27), day(5, 29)])
        XCTAssertNil(stats(h, today: day(6, 1)).thisWeekRate)

        checkIn(h, on: [day(6, 1)])
        let s = stats(h, today: day(6, 1))
        XCTAssertEqual(s.thisWeekRate ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate),
                       StatsInsights.Momentum(was: 100, now: 100))
    }

    /// "3 times a week" done Wednesday, Friday and Sunday, last week and this: on every day of this
    /// week, before and after the day's check-in, the week so far is never down. bab8acf spread the
    /// goal over the days counted (`weeklyGoalRate`) and read Tuesday 0%, Thursday 77%, Friday
    /// before the check-in 58% and Sunday before it 77%: "Down vs last week" six days of seven.
    func testATimesPerWeekUserOnTrackIsNeverDown() {
        let checkIns = [day(5, 27), day(5, 29), day(5, 31), day(6, 3), day(6, 5), day(6, 7)]
        for today in days(day(6, 1), through: day(6, 7)) {
            for doneToday in [false, true] where !doneToday || checkIns.contains(today) {
                let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(5, 1))
                checkIn(h, on: checkIns.filter { doneToday ? $0 <= today : $0 < today })
                let s = stats(h, today: today)
                let what = "\(today), done today: \(doneToday)"
                XCTAssertEqual(s.lastWeekRate, 1, what)
                if let rate = s.thisWeekRate { XCTAssertEqual(rate, 1, what) }
                XCTAssertNotEqual(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate)?.isUp,
                                  false, what)
            }
        }
        let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(5, 1))
        checkIn(h, on: Array(checkIns.prefix(3)))
        XCTAssertEqual(stats(h, today: day(6, 2)).completionRate(from: day(6, 1), to: day(6, 1)), 0,
                       "what bab8acf read on Tuesday")
    }

    /// The same goal, nothing done this week: owed is only what can no longer be made up. Friday
    /// morning three days are left for three check-ins, so nothing is owed yet; on Saturday one of
    /// them is missed for good, and a Saturday check-in covers one of the two owed by Sunday.
    func testATimesPerWeekWeekOwesOnlyWhatCanNoLongerBeMadeUp() {
        let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(5, 1))
        checkIn(h, on: [day(5, 27), day(5, 29), day(5, 31)])
        XCTAssertNil(stats(h, today: day(6, 5)).thisWeekRate)

        let saturday = stats(h, today: day(6, 6))
        XCTAssertEqual(saturday.thisWeekRate, 0)
        XCTAssertEqual(StatsInsights.momentum(thisWeek: saturday.thisWeekRate, lastWeek: saturday.lastWeekRate),
                       StatsInsights.Momentum(was: 100, now: 0))

        checkIn(h, on: [day(6, 6)])
        XCTAssertEqual(stats(h, today: day(6, 6)).thisWeekRate ?? 0, 0.5, accuracy: 0.0001)
    }

    /// Counted to its Sunday, this week's rate is the one it keeps as last week (`weeklyGoalRate`):
    /// two of three. A habit created on Thursday owes its share of the goal from then, 3 × 4 ÷ 7,
    /// as `weeklyGoalRate` counts that week: nothing owed on Saturday morning, and one Sunday
    /// check-in is 7/12.
    func testATimesPerWeekWeekCountedToItsSundayKeepsItsRate() {
        let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(5, 1))
        checkIn(h, on: [day(6, 6), day(6, 7)])
        let sunday = stats(h, today: day(6, 7))
        XCTAssertEqual(sunday.thisWeekRate ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(sunday.thisWeekRate, stats(h, today: day(6, 8)).lastWeekRate)

        let new = habit(.timesPerWeek, timesPerWeek: 3, created: day(6, 4))
        XCTAssertNil(stats(new, today: day(6, 6)).thisWeekRate, "Saturday: two days left for its share")
        checkIn(new, on: [day(6, 7)])
        let created = stats(new, today: day(6, 7))
        XCTAssertEqual(created.thisWeekRate ?? 0, 7.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(created.thisWeekRate, stats(new, today: day(6, 8)).lastWeekRate)
    }

    /// A habit created this Wednesday did not exist last week: no momentum. 1.4.1 (23) said "Up vs
    /// last week (0% → 100%)".
    func testAHabitNewThisWeekHasNoMomentum() {
        let h = habit(created: day(6, 3))
        checkIn(h, on: [day(6, 3)])
        let s = stats(h, today: day(6, 4))

        XCTAssertEqual(s.thisWeekRate, 1)
        XCTAssertNil(s.lastWeekRate)
        XCTAssertNil(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate))
        XCTAssertNil(StatsInsights.momentum(thisWeek: 0, lastWeek: 0), "both 0%: nothing to say, as before")
    }

    // MARK: - Weekly Review

    /// Two habits done all last week; Monday before any check-in. Nothing to count yet: no rate,
    /// no change, no Best — 1.4.1 (23) showed 0%, "Down 100% vs last week" and "Best:" a habit at 0%.
    func testWeeklyReviewOnMondayBeforeAnyCheckIn() {
        let run = habit(created: day(5, 1)), read = habit(created: day(5, 1))
        checkIn(run, on: days(day(5, 25), through: day(5, 31)))
        checkIn(read, on: days(day(5, 25), through: day(5, 31)))
        let all = [stats(run, today: day(6, 1)), stats(read, today: day(6, 1))]

        let review = StatsInsights.weeklyReview(thisWeek: all.map(\.thisWeekRate), lastWeek: all.map(\.lastWeekRate))
        XCTAssertEqual(review, StatsInsights.WeeklyReview(rates: [nil, nil], overall: nil, change: nil,
                                                          best: nil, needsWork: nil))
    }

    /// The same Monday after one of them is checked in: that one is 100%, the other has nothing
    /// to count yet. Level with last week (no change), and one rated habit is no Best.
    func testWeeklyReviewOnMondayAfterACheckIn() {
        let run = habit(created: day(5, 1)), read = habit(created: day(5, 1))
        checkIn(run, on: days(day(5, 25), through: day(6, 1)))
        checkIn(read, on: days(day(5, 25), through: day(5, 31)))
        let all = [stats(run, today: day(6, 1)), stats(read, today: day(6, 1))]

        let review = StatsInsights.weeklyReview(thisWeek: all.map(\.thisWeekRate), lastWeek: all.map(\.lastWeekRate))
        XCTAssertEqual(review, StatsInsights.WeeklyReview(rates: [1, nil], overall: 1, change: nil,
                                                          best: nil, needsWork: nil))
    }

    /// Best and Needs work only for a habit alone at the top or the bottom of the percents shown;
    /// the overall rate is the mean over the habits with something to count this week.
    func testWeeklyReviewHighlightsOnlyAHabitAlone() {
        func review(_ rates: [Double?], last: [Double?]? = nil) -> StatsInsights.WeeklyReview {
            StatsInsights.weeklyReview(thisWeek: rates, lastWeek: last ?? rates)
        }
        XCTAssertNil(review([1, 1]).best, "all equal: no Best")
        XCTAssertNil(review([1, 1]).needsWork)
        XCTAssertNil(review([1, 1, 0.5]).best)
        XCTAssertEqual(review([1, 1, 0.5]).needsWork, 2)
        XCTAssertEqual(review([1, 0.5, 0.5]).best, 0)
        XCTAssertNil(review([1, 0.5, 0.5]).needsWork)
        XCTAssertEqual(review([0.2, nil, 1, 0.6]).best, 2)
        XCTAssertEqual(review([0.2, nil, 1, 0.6]).needsWork, 0)
        // Equal as printed (66% and 66%) is equal.
        XCTAssertNil(review([2.0 / 3.0, 0.6667]).best)

        let changed = review([1, nil], last: [0.5, 0.5])
        XCTAssertEqual(changed.overall, 1)
        XCTAssertEqual(changed.change ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertNil(review([0.5], last: [0.505]).change, "within a point: no change shown, as before")
    }

    /// The change compares each habit with itself, over the habits with something to count in
    /// both weeks. bab8acf subtracted last week's mean over every habit rated then from this week's
    /// over the ones rated now: a habit with nothing due yet this week moved the change alone.
    func testWeeklyReviewComparesEachHabitWithItself() {
        XCTAssertNil(StatsInsights.weeklyReview(thisWeek: [0.5, nil], lastWeek: [0.5, 1]).change, "bab8acf: Down 25%")
        XCTAssertNil(StatsInsights.weeklyReview(thisWeek: [1, nil], lastWeek: [1, 0]).change, "bab8acf: Up 50%")
        XCTAssertNil(StatsInsights.weeklyReview(thisWeek: [1, nil], lastWeek: [nil, 1]).change, "nothing pairs")
        let moved = StatsInsights.weeklyReview(thisWeek: [0.5, nil], lastWeek: [4.0 / 7.0, 1])
        XCTAssertEqual(moved.change ?? 0, 0.5 - 4.0 / 7.0, accuracy: 0.0001, "the daily habit against itself")

        // Wednesday 06-03, today not done: a daily habit done every day, level with last week, and
        // a Saturday–Sunday habit missed last weekend with nothing due yet this week.
        let daily = habit(created: day(5, 1))
        checkIn(daily, on: days(day(5, 25), through: day(6, 2)))
        let weekend = habit(.specificDays, activeDays: (1 << 0) | (1 << 6), created: day(5, 1))
        let all = [stats(daily, today: day(6, 3)), stats(weekend, today: day(6, 3))]
        XCTAssertEqual(all.map(\.thisWeekRate), [1, nil])
        XCTAssertEqual(all.map(\.lastWeekRate), [1, 0])

        let review = StatsInsights.weeklyReview(thisWeek: all.map(\.thisWeekRate), lastWeek: all.map(\.lastWeekRate))
        XCTAssertEqual(review.overall, 1)
        XCTAssertNil(review.change)
    }

    // MARK: - 8-week Trend

    /// Created Thursday 07-02, today Wednesday 07-22, the eight weeks from Monday 06-01. The four
    /// weeks before the habit existed have nothing to count — 1.4.1 (23) drew each as a grey bar
    /// marked 0. Its first week counts from its creation day; a week it missed is still 0%, not
    /// "not started"; and this week waits for today.
    func testTheTrendShowsTheWeeksBeforeAHabitAsNotStarted() {
        let h = habit(created: day(7, 2))
        checkIn(h, on: days(day(7, 2), through: day(7, 12)) + days(day(7, 20), through: day(7, 21)))
        let s = stats(h, today: day(7, 22))
        let mondays = (0..<8).map { utc.date(byAdding: .day, value: 7 * $0, to: day(6, 1))! }

        XCTAssertEqual(mondays.map { s.countedRate(ofWeekStarting: $0) }, [nil, nil, nil, nil, 1, 1, 0, 1])
        XCTAssertEqual(mondays.map { s.endsBeforeStart(weekStarting: $0) },
                       [true, true, true, true, false, false, false, false], "only these are \"Not started\"")
        XCTAssertEqual(s.completionRate(from: day(6, 1), to: day(6, 7)), 0, "what the old Trend drew")
    }

    /// Monday 07-20 before the check-in: this week has nothing to count yet, but the habit has run
    /// since 07-02, so the week is not one before its start (bab8acf spoke "Not started" for it).
    func testThisWeekWithNothingCountedIsNotBeforeTheStart() {
        let h = habit(created: day(7, 2))
        checkIn(h, on: days(day(7, 2), through: day(7, 19)))
        let s = stats(h, today: day(7, 20))

        XCTAssertNil(s.countedRate(ofWeekStarting: day(7, 20)))
        XCTAssertFalse(s.endsBeforeStart(weekStarting: day(7, 20)))
        XCTAssertTrue(s.endsBeforeStart(weekStarting: day(6, 22)), "06-22 to 06-28")
        XCTAssertFalse(s.endsBeforeStart(weekStarting: day(6, 29)), "the week it was created in")
    }

    /// Mon/Wed only, created on a Thursday: nothing of that week was due, so it has nothing to
    /// count, though the habit existed in it; the next week counts.
    func testACreationWeekWithNothingDueHasNothingToCount() {
        let h = habit(.specificDays, activeDays: (1 << 1) | (1 << 3), created: day(6, 4))
        checkIn(h, on: [day(6, 8), day(6, 10)])
        let s = stats(h, today: day(6, 12))

        XCTAssertNil(s.countedRate(ofWeekStarting: day(6, 1)))
        XCTAssertFalse(s.endsBeforeStart(weekStarting: day(6, 1)))
        XCTAssertEqual(s.countedRate(ofWeekStarting: day(6, 8)), 1)
    }
}
