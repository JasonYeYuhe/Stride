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

    /// The same Monday after the check-in: level with last week, and it reads "Level with last
    /// week" (RELEASE-1.4.2.md D7). Changed on purpose in 1.4.2: until then a level week was
    /// `isUp` and read "Up vs last week (100% → 100%)".
    func testMondayAfterTheCheckInIsLevelWithLastWeek() {
        let h = habit(created: day(5, 1))
        checkIn(h, on: days(day(5, 1), through: day(6, 1)))
        let s = stats(h, today: day(6, 1))

        XCTAssertEqual(s.thisWeekRate, 1)
        let momentum = StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate)
        XCTAssertEqual(momentum, StatsInsights.Momentum(was: 100, now: 100))
        XCTAssertEqual(momentum?.direction, .level)
        XCTAssertEqual(momentum?.isUp, false, "level is not up (D7)")
        XCTAssertTrue(StatsInsights.insightLines(for: s).contains(.momentum(StatsInsights.Momentum(was: 100, now: 100))))
    }

    /// Up and down are strict, in the printed percents: 66.9% against 66.1% is level (both 66%).
    func testMomentumDirectionIsStrictInThePrintedPercents() {
        XCTAssertEqual(StatsInsights.momentum(thisWeek: 0.6, lastWeek: 0.5)?.direction, .up)
        XCTAssertEqual(StatsInsights.momentum(thisWeek: 0.5, lastWeek: 0.6)?.direction, .down)
        XCTAssertEqual(StatsInsights.momentum(thisWeek: 0.669, lastWeek: 0.661)?.direction, .level)
        XCTAssertEqual(StatsInsights.Momentum(was: 50, now: 51).isUp, true)
        XCTAssertEqual(StatsInsights.Momentum(was: 51, now: 50).isUp, false)
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
                // Never down; level (100% → 100%) since D7 reads "Level", no longer `isUp`.
                XCTAssertNotEqual(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate)?.direction,
                                  .down, what)
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

    // MARK: - D7: Pro is right in its first week (RELEASE-1.4.2.md)
    //
    // Insights' D7 rules: the weekday line's 12-week window, minimums and gap; the record line;
    // the order and the cap; why the card has nothing to say; Strength's tiles for a young habit;
    // the PRO chip's contrast. Run in Tokyo and Los Angeles (TZ=…): the stats are UTC day-keys,
    // and the one instant-based case keys its instants in the zone the tests run in.

    private typealias Extremes = StatsInsights.WeekdayExtremes
    private typealias Gap = StatsInsights.RecordGap

    /// The weekday line's rule over `tallies` (daily unless given): D7's minimums.
    private func line(_ tallies: [Int: StatsInsights.WeekdayTally], schedule: HabitSchedule = .daily,
                      mask: Int = 127) -> Extremes {
        StatsInsights.weekdayExtremes(tallies, schedule: schedule, activeDaysMask: mask,
                                      minimumDue: StatsInsights.weekdayMinimumDue,
                                      minimumGap: StatsInsights.weekdayMinimumGap)
    }

    /// The named day is at least 15 points from every other scheduled weekday: exactly 15
    /// passes, 14 fails, for the strongest and the toughest, compared exactly (unlike
    /// denominators, and a fraction that is near 15 only once rounded).
    func testTheWeekdayLineNeedsAGapOfFifteenPoints() {
        XCTAssertEqual(StatsInsights.weekdayMinimumGap, 15)
        // Monday 100%, every other day 85%: exactly 15 above the runner-up.
        var t = week(Array(repeating: tally(17, of: 20), count: 7))
        t[2] = tally(20, of: 20)
        XCTAssertEqual(line(t), Extremes(strongest: 2, toughest: nil))
        // 100% against 86%: 14.
        t = week(Array(repeating: tally(43, of: 50), count: 7))
        t[2] = tally(50, of: 50)
        XCTAssertEqual(line(t), none)
        XCTAssertEqual(StatsInsights.weekdayExtremes(t, schedule: .daily, activeDaysMask: 127).strongest, 2,
                       "without the gap it would be named")
        // Friday 70% against 85%: exactly 15 below the next-lowest; 71% is 14.
        t = week(Array(repeating: tally(85, of: 100), count: 7))
        t[6] = tally(70, of: 100)
        XCTAssertEqual(line(t), Extremes(strongest: nil, toughest: 6))
        t[6] = tally(71, of: 100)
        XCTAssertEqual(line(t), none)
        // Unlike denominators, exactly 15: 12 of 12 against 17 of 20.
        t = week(Array(repeating: tally(17, of: 20), count: 7))
        t[2] = tally(12, of: 12)
        XCTAssertEqual(line(t).strongest, 2)
        // 7 of 7 against 6 of 7 is 14.29 points: not 15.
        t = week(Array(repeating: tally(6, of: 7), count: 7))
        t[2] = tally(7, of: 7)
        XCTAssertEqual(line(t), none)
        // Against every other day, not the average: Monday 100%, Tuesday 90%, the rest 50%.
        t = week(Array(repeating: tally(10, of: 20), count: 7))
        t[2] = tally(20, of: 20)
        t[3] = tally(18, of: 20)
        XCTAssertNil(line(t).strongest, "10 points above the runner-up")
    }

    /// Every scheduled weekday due at least 4 times in the window, or no weekday line: 3 fails.
    /// For specific days only the scheduled weekdays count.
    func testTheWeekdayLineNeedsFourDueOfEveryScheduledWeekday() {
        XCTAssertEqual(StatsInsights.weekdayMinimumDue, 4)
        var t = week(Array(repeating: tally(4, of: 4), count: 7))
        t[3] = tally(0, of: 4)
        XCTAssertEqual(line(t), Extremes(strongest: nil, toughest: 3))
        t[1] = tally(3, of: 3)   // Sunday due only 3 times
        XCTAssertEqual(line(t), none)

        let mwf = [2: tally(4, of: 4), 4: tally(4, of: 4), 6: tally(1, of: 4)]
        XCTAssertEqual(line(mwf, schedule: .specificDays, mask: monWedFriMask), Extremes(strongest: nil, toughest: 6))
        var short = mwf
        short[4] = tally(3, of: 3)
        XCTAssertEqual(line(short, schedule: .specificDays, mask: monWedFriMask), none)
        XCTAssertEqual(line(week(Array(repeating: tally(0, of: 12), count: 7)), schedule: .timesPerWeek), none)
    }

    /// The same rule from a habit's own days: daily from Monday 06-01, every Tuesday missed, on
    /// Sunday 06-28. Before the check-in the window holds three Sundays: no weekday line. After
    /// it, four of every weekday: "Toughest on Tuesday". The card then has exactly D7's three
    /// lines in D7's order: 1 day from the record of 6, level with last week, Tuesday.
    func testThreeOrFourDueOccurrencesFromAHabitsDays() {
        let h = habit(created: day(6, 1))
        let tuesdays = [day(6, 2), day(6, 9), day(6, 16), day(6, 23)]
        checkIn(h, on: days(day(6, 1), through: day(6, 27)).filter { !tuesdays.contains($0) })
        let before = stats(h, today: day(6, 28))
        XCTAssertEqual(before.recentWeekdayTallies[1], tally(3, of: 3))
        XCTAssertEqual(StatsInsights.recentWeekdayExtremes(of: before), none)
        XCTAssertEqual(StatsInsights.insightLines(for: before),
                       [.record(Gap(away: 2, record: 6), inWeeks: false), .momentum(StatsInsights.Momentum(was: 85, now: 83))])

        checkIn(h, on: [day(6, 28)])
        let after = stats(h, today: day(6, 28))
        XCTAssertEqual(after.recentWeekdayTallies[1], tally(4, of: 4))
        XCTAssertEqual(StatsInsights.recentWeekdayExtremes(of: after), Extremes(strongest: nil, toughest: 3))
        XCTAssertEqual(StatsInsights.insightLines(for: after),
                       [.record(Gap(away: 1, record: 6), inWeeks: false),
                        .momentum(StatsInsights.Momentum(was: 85, now: 85)), .toughest(3)])
        XCTAssertNil(StatsInsights.emptyState(for: after))
    }

    /// Only the last 12 weeks: daily since Monday 01-05, on Monday 06-15 (counted through Sunday
    /// 06-14, so the window is 03-23 to 06-14). One habit missed every Tuesday until 03-15, the
    /// other did only Fridays until then; both have done every day since 03-16. All time, Tuesday
    /// is the toughest and Friday the strongest, by far more than 15 points; in the window every
    /// weekday is 100%, so neither habit has a weekday line.
    func testTheWeekdayLineIgnoresAPatternOlderThanTwelveWeeks() {
        let recent = days(day(3, 16), through: day(6, 14))
        let old = days(day(1, 5), through: day(3, 15))
        let weekday = { (d: Date) in HabitStats.weekday(ofDay: HabitStats.dayNumber(ofKey: d)) }
        let weak = habit(created: day(1, 5))
        checkIn(weak, on: old.filter { weekday($0) != 3 } + recent)
        let strong = habit(created: day(1, 5))
        checkIn(strong, on: old.filter { weekday($0) == 6 } + recent)

        for (h, allTime) in [(weak, Extremes(strongest: nil, toughest: 3)), (strong, Extremes(strongest: 6, toughest: nil))] {
            let s = stats(h, today: day(6, 15))
            XCTAssertEqual(line(s.weekdayTallies), allTime, "the all-time tally would say so")
            XCTAssertEqual(Set(s.recentWeekdayTallies.values.map { "\($0.done)/\($0.due)" }), ["12/12"])
            XCTAssertEqual(StatsInsights.recentWeekdayExtremes(of: s), none)
            XCTAssertFalse(StatsInsights.insightLines(for: s).contains { line in
                switch line {
                case .strongest, .toughest: return true
                case .record, .momentum: return false
                }
            })
        }
    }

    /// Only while the run is open, is not the record, and is 1…7 away.
    func testTheRecordLinesRule() {
        XCTAssertEqual(StatsInsights.recordLineReach, 7)
        XCTAssertNil(StatsInsights.recordGap(current: 0, best: 5), "no open run")
        XCTAssertNil(StatsInsights.recordGap(current: 5, best: 5), "the run is the record")
        XCTAssertEqual(StatsInsights.recordGap(current: 19, best: 20), Gap(away: 1, record: 20))
        XCTAssertEqual(StatsInsights.recordGap(current: 13, best: 20), Gap(away: 7, record: 20))
        XCTAssertNil(StatsInsights.recordGap(current: 12, best: 20), "8 away")
    }

    private func recordLine(_ s: HabitStats) -> StatsInsights.InsightLine? {
        StatsInsights.insightLines(for: s).first { if case .record = $0 { return true } else { return false } }
    }

    /// Daily from Friday 05-01: a 10-day record (05-01 to 05-10), 05-11 missed, then a new run.
    func testTheRecordLineFromADailyHabit() {
        let seven = habit(created: day(5, 1))
        checkIn(seven, on: days(day(5, 1), through: day(5, 10)) + days(day(5, 12), through: day(5, 14)))
        let open = stats(seven, today: day(5, 15))   // today not done yet: the run of 3 is open
        XCTAssertEqual(open.currentStreak(), 3)
        XCTAssertEqual(open.bestStreak, 10)
        XCTAssertEqual(recordLine(open), .record(Gap(away: 7, record: 10), inWeeks: false))
        XCTAssertEqual(StatsInsights.insightLines(for: open).first, recordLine(open), "the record line comes first")

        let closed = stats(seven, today: day(5, 16))   // 05-15 missed: the run ended
        XCTAssertEqual(closed.currentStreak(), 0)
        XCTAssertNil(recordLine(closed))

        let eight = habit(created: day(5, 1))
        checkIn(eight, on: days(day(5, 1), through: day(5, 10)) + days(day(5, 12), through: day(5, 13)))
        XCTAssertNil(recordLine(stats(eight, today: day(5, 14))), "2 of 10: 8 away")

        let equal = habit(created: day(5, 1))
        checkIn(equal, on: days(day(5, 1), through: day(5, 10)) + days(day(5, 12), through: day(5, 21)))
        let level = stats(equal, today: day(5, 22))
        XCTAssertEqual(level.currentStreak(), level.bestStreak)
        XCTAssertNil(recordLine(level), "a run equal to the record is the record")
    }

    /// Times-per-week counts weeks: 3 a week from Monday 03-02, met five weeks running, the week
    /// of 04-06 missed, met the weeks of 04-13 and 04-20; on Wednesday 04-29 with nothing yet
    /// this week (not a miss yet) the run is 2 weeks, 3 from the record of 5.
    func testTheRecordLineCountsWeeksForTimesPerWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3, created: day(3, 2))
        let mondays = [day(3, 2), day(3, 9), day(3, 16), day(3, 23), day(3, 30), day(4, 13), day(4, 20)]
        checkIn(h, on: mondays.flatMap { m in [0, 2, 4].map { utc.date(byAdding: .day, value: $0, to: m)! } })
        let s = stats(h, today: day(4, 29))
        XCTAssertEqual(s.currentStreak(), 2)
        XCTAssertEqual(s.bestStreak, 5)
        XCTAssertEqual(recordLine(s), .record(Gap(away: 3, record: 5), inWeeks: true))
    }

    /// Record, momentum, then the weekday line (strongest before toughest); never more than 3.
    func testAtMostThreeLinesInOrder() {
        XCTAssertEqual(StatsInsights.maximumInsightLines, 3)
        let gap = Gap(away: 2, record: 9)
        let up = StatsInsights.Momentum(was: 50, now: 80)
        let both = Extremes(strongest: 2, toughest: 6)
        XCTAssertEqual(StatsInsights.insightLines(record: gap, inWeeks: false, momentum: up, weekdays: both),
                       [.record(gap, inWeeks: false), .momentum(up), .strongest(2)], "the toughest day is the fourth")
        XCTAssertEqual(StatsInsights.insightLines(record: nil, inWeeks: false, momentum: up, weekdays: both),
                       [.momentum(up), .strongest(2), .toughest(6)])
        XCTAssertEqual(StatsInsights.insightLines(record: gap, inWeeks: true, momentum: nil, weekdays: both),
                       [.record(gap, inWeeks: true), .strongest(2), .toughest(6)])
        XCTAssertEqual(StatsInsights.insightLines(record: gap, inWeeks: false, momentum: up,
                                                  weekdays: Extremes(strongest: nil, toughest: 6)),
                       [.record(gap, inWeeks: false), .momentum(up), .toughest(6)])
        XCTAssertEqual(StatsInsights.insightLines(record: nil, inWeeks: false, momentum: nil, weekdays: none), [])
    }

    /// The first full Monday-to-Sunday week on or after the start, ended. Started on a Monday,
    /// that is its own first week, read from the next Monday; on a Sunday, the week after; on a
    /// Tuesday, the following Monday's week, 13 days later.
    func testTheFirstFullWeekEdges() {
        let monday = HabitStats.dayNumber(ofKey: day(6, 1))
        XCTAssertFalse(StatsInsights.hasHadFullWeek(startDay: monday, today: monday), "its first day")
        XCTAssertFalse(StatsInsights.hasHadFullWeek(startDay: monday, today: monday + 6), "its Sunday")
        XCTAssertTrue(StatsInsights.hasHadFullWeek(startDay: monday, today: monday + 7), "the next Monday")
        XCTAssertFalse(StatsInsights.hasHadFullWeek(startDay: monday - 1, today: monday + 6), "a Sunday start")
        XCTAssertTrue(StatsInsights.hasHadFullWeek(startDay: monday - 1, today: monday + 7))
        XCTAssertFalse(StatsInsights.hasHadFullWeek(startDay: monday + 1, today: monday + 13), "a Tuesday start")
        XCTAssertTrue(StatsInsights.hasHadFullWeek(startDay: monday + 1, today: monday + 14))
    }

    /// A habit started Wednesday 06-03 with nothing to say reads "after your first full week"
    /// until its first full week (06-08 to 06-14) ends, then "not enough recent check-ins". A
    /// Monday start and a backdated start count from their start day. The empty state never
    /// replaces a real line: the same start with every day done has momentum.
    func testInsightsWaitForTheFirstFullWeek() {
        let h = habit(created: day(6, 3))
        let cases: [(Date, StatsInsights.EmptyState)] = [
            (day(6, 3), .beforeFirstFullWeek), (day(6, 7), .beforeFirstFullWeek), (day(6, 8), .beforeFirstFullWeek),
            (day(6, 14), .beforeFirstFullWeek), (day(6, 15), .notEnoughRecentCheckIns), (day(6, 30), .notEnoughRecentCheckIns),
        ]
        for (today, expected) in cases {
            let s = stats(h, today: today)
            XCTAssertEqual(StatsInsights.insightLines(for: s), [], "\(today)")
            XCTAssertEqual(StatsInsights.emptyState(for: s), expected, "\(today)")
        }

        let monday = habit(created: day(6, 1))
        XCTAssertEqual(StatsInsights.emptyState(for: stats(monday, today: day(6, 7))), .beforeFirstFullWeek)
        XCTAssertEqual(StatsInsights.emptyState(for: stats(monday, today: day(6, 8))), .notEnoughRecentCheckIns)

        // Created 06-10 with a check-in on Monday 06-01: it started on 06-01.
        let backdated = habit(created: day(6, 10))
        checkIn(backdated, on: [day(6, 1)])
        let early = stats(backdated, today: day(6, 8))
        XCTAssertEqual(early.startDay, day(6, 1))
        XCTAssertEqual(StatsInsights.emptyState(for: early), .notEnoughRecentCheckIns)

        let active = habit(created: day(6, 3))
        checkIn(active, on: days(day(6, 3), through: day(6, 9)))
        let s = stats(active, today: day(6, 10))
        XCTAssertEqual(StatsInsights.insightLines(for: s), [.momentum(StatsInsights.Momentum(was: 100, now: 100))])
        XCTAssertNil(StatsInsights.emptyState(for: s))
    }

    /// `today` as an instant, keyed in the zone the tests run in: Sunday 06-07 23:59 local is
    /// still the first week of a Monday 06-01 start; Monday 06-08 00:01 local is past it.
    func testTheFirstFullWeekKeysTodayInTheUsersZone() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let sundayNight = local.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: 23, minute: 59))!
        let mondayMorning = local.date(from: DateComponents(year: 2026, month: 6, day: 8, hour: 0, minute: 1))!
        XCTAssertEqual(StatsInsights.emptyState(startDay: day(6, 1), today: sundayNight, calendar: local), .beforeFirstFullWeek)
        XCTAssertEqual(StatsInsights.emptyState(startDay: day(6, 1), today: mondayMorning, calendar: local),
                       .notEnoughRecentCheckIns)
    }

    /// An old habit gone quiet: daily from Monday 03-02, done every day through Sunday 05-17,
    /// nothing since; on Wednesday 06-03. Last week and this week so far are both 0%, so there is
    /// no momentum; the window's weekdays are 75–83%, under the gap; no open run. It reads "Not
    /// enough recent check-ins to compare", never "after your first full week".
    func testAnOldHabitWithTwoZeroWeeksHasNotEnoughRecentCheckIns() {
        let h = habit(created: day(3, 2))
        checkIn(h, on: days(day(3, 2), through: day(5, 17)))
        let s = stats(h, today: day(6, 3))
        XCTAssertEqual(s.lastWeekRate, 0)
        XCTAssertEqual(s.thisWeekRate, 0)
        XCTAssertEqual(s.countedRate(ofWeekStarting: day(5, 18)), 0)
        XCTAssertNil(StatsInsights.momentum(thisWeek: s.thisWeekRate, lastWeek: s.lastWeekRate))
        XCTAssertEqual(StatsInsights.insightLines(for: s), [])
        XCTAssertEqual(StatsInsights.emptyState(for: s), .notEnoughRecentCheckIns)
    }

    /// One "Since start" under 30 days; 30-Day Change and Since start to 90; then 30 and 90.
    func testAYoungHabitsStrengthTiles() {
        XCTAssertEqual(StatsInsights.strengthChanges(ageInDays: 0), [.sinceStart])
        XCTAssertEqual(StatsInsights.strengthChanges(ageInDays: 30), [.sinceStart])
        XCTAssertEqual(StatsInsights.strengthChanges(ageInDays: 31), [.thirtyDays, .sinceStart])
        XCTAssertEqual(StatsInsights.strengthChanges(ageInDays: 90), [.thirtyDays, .sinceStart])
        XCTAssertEqual(StatsInsights.strengthChanges(ageInDays: 91), [.thirtyDays, .ninetyDays])

        // Daily from 05-01, every day done through 05-30. On 05-31 (30 days old) before the
        // check-in, a 30-day change would reach the day before the start and equal Since start:
        // one tile. From 06-01 (31 days) its window starts at the start day: two different tiles.
        let h = habit(created: day(5, 1))
        checkIn(h, on: days(day(5, 1), through: day(5, 30)))
        let thirty = stats(h, today: day(5, 31))
        XCTAssertEqual(StatsInsights.ageInDays(startDay: thirty.startDay, today: thirty.today, calendar: utc), 30)
        XCTAssertEqual(StatsInsights.strengthChanges(for: thirty), [.sinceStart])
        XCTAssertEqual(StatsInsights.displayedChange(current: thirty.strength, baseline: thirty.strength - thirty.strengthDelta30),
                       StatsInsights.displayedChangeSinceStart(of: thirty), "why it is one tile")

        let older = stats(h, today: day(6, 1))
        XCTAssertEqual(StatsInsights.strengthChanges(for: older), [.thirtyDays, .sinceStart])
        XCTAssertEqual(StatsInsights.strengthAtStart(of: older), 0, "the walk starts from 0")
        let sinceStart = StatsInsights.displayedChangeSinceStart(of: older)
        XCTAssertEqual(sinceStart, HabitScore.displayValue(older.strength))
        XCTAssertLessThan(StatsInsights.displayedChange(current: older.strength, baseline: older.strength - older.strengthDelta30),
                          sinceStart, "the 30-day window starts after the first day's gain")

        // The start is the start day, not the creation day: created 06-10, backdated to 05-01.
        let backdated = habit(created: day(6, 10))
        checkIn(backdated, on: [day(5, 1)])
        XCTAssertEqual(StatsInsights.strengthChanges(for: stats(backdated, today: day(6, 15))), [.thirtyDays, .sinceStart])
        XCTAssertEqual(StatsInsights.strengthChanges(for: stats(habit(created: day(1, 5)), today: day(6, 15))),
                       [.thirtyDays, .ninetyDays])
    }

    /// White on the chip's fill reaches 4.5:1 (WCAG AA body text), with the same colours in light
    /// and dark. The palette's Green itself would not: about 2.2:1 under white.
    func testTheProChipReadsAtFourAndAHalfToOne() {
        XCTAssertEqual(StatsInsights.proChipText, .white)
        XCTAssertGreaterThanOrEqual(ColorContrast.ratio(StatsInsights.proChipText, StatsInsights.proChipFill),
                                    ColorContrast.textMinimum)
        XCTAssertLessThan(ColorContrast.ratio(.white, .fallback), ColorContrast.textMinimum)
    }
}
