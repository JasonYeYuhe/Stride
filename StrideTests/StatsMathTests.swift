import XCTest
import SwiftData
import Foundation

/// Tests for the streak and completion-rate math behind the Stats tab, the Pro trend chart and
/// Weekly Review. Every case below uses a user who did exactly what the habit asked, and checks
/// the app says so. Before 1.2.3 several of them did not:
/// - a Mon/Wed/Fri habit never missed for six weeks showed "Best Streak 1 day" beside a current
///   streak of 18, because the best streak required literally consecutive calendar days;
/// - a "3 times a week" goal met every single week scored a 30-day rate of 43%, because the
///   rate treated it as due all seven days.
///
/// Since 1.4.1 the math lives in `HabitStats` (RELEASE-1.4.1.md D2) and `Habit`'s aggregates
/// delegate to it; the later sections pin what it adds: the backdating start (D8), which records
/// count (the store decides), the widget's rows, and the best-streak ranges.
///
/// Dates are fixed UTC day-keys (2026-06-01 is a Monday), so none of this depends on the day or
/// the time zone the tests run in.
@MainActor
final class StatsMathTests: XCTestCase {

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

    private func habit(_ schedule: HabitSchedule, timesPerWeek: Int = 7, activeDays: Int = 127) -> Habit {
        let h = Habit(name: "Habit")
        h.schedule = schedule
        h.timesPerWeek = timesPerWeek
        h.activeDaysMask = activeDays
        h.createdAt = day(1, 1)   // well before every range below
        context.insert(h)
        return h
    }

    private func checkIn(_ h: Habit, on dates: [Date]) {
        for d in dates { h.records.append(HabitRecord(date: d)) }
    }

    /// Mon, Wed and Fri of `weeks` consecutive weeks starting Monday 2026-06-01.
    private func monWedFri(weeks: Int) -> [Date] {
        (0..<weeks).flatMap { w in [0, 2, 4].map { utc.date(byAdding: .day, value: 7 * w + $0, to: day(6, 1))! } }
    }

    private let monWedFriMask = (1 << 1) | (1 << 3) | (1 << 5)   // bit 0 = Sunday

    // MARK: - Best streak

    /// "Gym — Mon/Wed/Fri", never missed for six weeks. Rest days must neither count nor break
    /// the run, exactly as they don't for the current streak shown beside it.
    func testBestStreakSkipsRestDaysForSpecificDays() {
        let h = habit(.specificDays, activeDays: monWedFriMask)
        checkIn(h, on: monWedFri(weeks: 6))
        let saturdayAfter = day(7, 11)

        XCTAssertEqual(h.currentStreak(from: saturdayAfter), 18, "precondition: the current streak already handles rest days")
        XCTAssertEqual(h.bestStreak(), 18, "was 1: no two completed days are ever adjacent")
    }

    /// "Yoga — 3 times a week", met six weeks running. Its streak is counted in weeks.
    func testBestStreakCountsWeeksForTimesPerWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: monWedFri(weeks: 6))

        XCTAssertEqual(h.currentStreak(from: day(7, 11)), 6, "precondition: current streak counts weeks")
        XCTAssertEqual(h.bestStreak(), 6, "must be in weeks too, not a count of adjacent days")
    }

    /// A 10-day run, a two-day gap, then 3 days. Best is the old run, current is the new one.
    func testBestStreakKeepsTheLongestRunAfterABreak() {
        let h = habit(.daily)
        checkIn(h, on: (1...10).map { day(6, $0) } + (13...15).map { day(6, $0) })

        XCTAssertEqual(h.currentStreak(from: day(6, 16)), 3)
        XCTAssertEqual(h.bestStreak(), 10)
    }

    // MARK: - Completion rate

    /// "Run — 3 times a week", done Mon/Wed/Fri every week, measured over the 30 days ending the
    /// Saturday after. Hitting the goal every week is 100%; it used to read 43% (13 of 30 days).
    func testThirtyDayRateForAWeeklyGoalMetEveryWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: monWedFri(weeks: 6))
        let end = day(7, 11)
        let start = utc.date(byAdding: .day, value: -29, to: end)!

        XCTAssertEqual(h.completionRate(from: start, to: end), 1.0, accuracy: 0.0001)
    }

    /// One run a week against a goal of three, over four whole weeks: a third.
    func testRateForAWeeklyGoalMissedEveryWeek() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: [day(6, 1), day(6, 8), day(6, 15), day(6, 22)])

        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 28)), 1.0 / 3.0, accuracy: 0.0001)
    }

    /// Mon–Wed done, measured across the whole Mon–Sun week on Wednesday. Thursday to Sunday
    /// haven't happened; they must not be scored as misses. (The 8-week trend's last bar.)
    func testRateDoesNotCountDaysThatHaveNotHappened() {
        let h = habit(.daily)
        checkIn(h, on: [day(6, 1), day(6, 2), day(6, 3)])

        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 7), now: day(6, 3)), 1.0, accuracy: 0.0001)
        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 7), now: day(6, 7)), 3.0 / 7.0, accuracy: 0.0001,
                       "once the week is over, the missing days do count")
    }

    /// A week only partly inside the range still credits a goal met earlier in that week.
    func testWeeklyGoalMetEarlyInAWeekThatStartsBeforeTheRange() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: [day(6, 1), day(6, 2), day(6, 3)])   // Mon–Wed of that week

        // Range starts Saturday of the same week.
        XCTAssertEqual(h.completionRate(from: day(6, 6), to: day(6, 7), now: day(6, 7)), 1.0, accuracy: 0.0001)
    }

    func testCountHabitDaysBelowTargetDoNotCountAsCompleted() {
        let h = habit(.daily)
        h.kind = HabitKind.count.rawValue
        h.targetValue = 8
        h.records.append(HabitRecord(date: day(6, 1), value: 1))
        h.records.append(HabitRecord(date: day(6, 2), value: 8))

        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 2), now: day(6, 2)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(h.bestStreak(), 1)
    }

    // MARK: - Backdating (RELEASE-1.4.1.md D8)

    /// `HabitStats` for `h` as of `today`, in UTC (the day-keys here are UTC midnights), from the
    /// store's live ids — what StatsCache and the widget build.
    private func stats(_ h: Habit, today: Date) -> HabitStats {
        HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context), calendar: utc, today: today)
    }

    /// Created Wed 06-10 at noon UTC; History backfilled 06-01…06-05 and 06-08…06-14. The rate
    /// starts at the earliest record, so the two missed days before creation count against it:
    /// 12 of 14, not 1.4.0's 7 of 7.
    func testBackdatedRecordsStartTheRateAtTheEarliestRecord() {
        let h = habit(.daily)
        h.createdAt = utc.date(byAdding: .hour, value: 12, to: day(6, 10))!
        checkIn(h, on: (1...5).map { day(6, $0) } + (8...14).map { day(6, $0) })
        let s = stats(h, today: day(6, 14))

        XCTAssertEqual(s.startDay, day(6, 1), "min(creation day, earliest live record)")
        XCTAssertEqual(s.completionRate(from: day(5, 1), to: day(6, 30)), 12.0 / 14.0, accuracy: 1e-12)
        XCTAssertEqual(s.completionRate(days: 30), 12.0 / 14.0, accuracy: 1e-12)
        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 14), now: day(6, 14)), 12.0 / 14.0, accuracy: 1e-12,
                       "the wrapper agrees")
        XCTAssertEqual(s.strengthSeries.firstDay, day(6, 1), "the strength walk starts there too (D9)")
    }

    /// Without earlier records the start stays the creation day, in the caller's calendar: the
    /// rate does not count the days before the habit existed.
    func testWithoutBackdatedRecordsTheStartIsTheCreationDay() {
        let h = habit(.daily)
        h.createdAt = utc.date(byAdding: .hour, value: 12, to: day(6, 10))!
        checkIn(h, on: [day(6, 12), day(6, 13)])
        let s = stats(h, today: day(6, 14))

        XCTAssertEqual(s.startDay, day(6, 10))
        XCTAssertEqual(s.completionRate(from: day(6, 1), to: day(6, 14)), 2.0 / 5.0, accuracy: 1e-12)

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        h.createdAt = utc.date(byAdding: .hour, value: 20, to: day(6, 10))!   // 05:00 on 06-11 in Tokyo
        let inTokyo = HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context),
                                 calendar: tokyo, today: day(6, 14))
        XCTAssertEqual(inTokyo.startDay, day(6, 11), "the creation instant is dated in the caller's calendar")
    }

    /// A habit backfilled every day before it was created, then done every day: 100 %, never more,
    /// for every schedule and every range — the clamp may lower the rate, never raise it past 1.
    func testABackdatedRecordNeverYieldsMoreThanOneHundredPercent() {
        for schedule in HabitSchedule.allCases {
            let h = habit(schedule, timesPerWeek: 3, activeDays: monWedFriMask)
            h.createdAt = utc.date(byAdding: .hour, value: 12, to: day(6, 20))!
            checkIn(h, on: (1...30).map { day(6, $0) })
            let s = stats(h, today: day(6, 30))
            for start in [day(5, 1), day(6, 1), day(6, 6), day(6, 20), day(6, 29)] {
                let rate = s.completionRate(from: start, to: day(7, 31))
                XCTAssertLessThanOrEqual(rate, 1, "\(schedule) from \(start)")
                XCTAssertEqual(rate, 1, accuracy: 1e-12, "\(schedule) from \(start): every expected day was done")
            }
            XCTAssertEqual(s.completionRate(days: 90), 1, accuracy: 1e-12, "\(schedule)")
        }
    }

    /// The start is the earliest LIVE record: a deleted backfill no longer moves it.
    func testTheStartIgnoresADeletedBackfill() throws {
        let h = habit(.daily)
        h.createdAt = utc.date(byAdding: .hour, value: 12, to: day(6, 10))!
        checkIn(h, on: [day(6, 2), day(6, 11), day(6, 12)])
        try context.save()
        let early = try XCTUnwrap(h.records.first { $0.date == day(6, 2) })
        context.delete(early)
        try context.save()
        let s = stats(h, today: day(6, 12))
        XCTAssertEqual(s.startDay, day(6, 10))
        XCTAssertEqual(s.completionRate(days: 30), 2.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: - Which records count (D2)

    /// A deletion another context saved and this one has not merged, alongside a record appended
    /// here and not yet saved. The direct lookup still sees the deleted record; the aggregates ask
    /// the store, so they drop it and count the unsaved one.
    func testTheAggregatesAskTheStoreAboutAnotherContextsDeletion() throws {
        let h = habit(.daily)
        checkIn(h, on: (1...5).map { day(6, $0) })
        try context.save()
        for r in h.records { _ = (r.id, r.date, r.value, r.updatedAt) }   // read, as a rendered list has them
        let other = ModelContext(container)
        let target = day(6, 3)
        let gone = try other.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { $0.date == target }))
        XCTAssertEqual(gone.count, 1)
        other.delete(gone[0])
        try other.save()
        h.records.append(HabitRecord(date: day(6, 6)))   // pending, unsaved

        XCTAssertTrue(h.isCompletedOn(day(6, 3)), "precondition: the direct lookup still sees it")
        guard case .persistentIDs(let ids) = HabitStats.liveRecords(of: h) else {
            return XCTFail("expected the store's exact answer")
        }
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(h.completionRate(from: day(6, 1), to: day(6, 6), now: day(6, 6)), 5.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(h.currentStreak(from: day(6, 6)), 3, "06-04 to 06-06")
        let s = stats(h, today: day(6, 6))
        XCTAssertFalse(s.isCompleted(on: day(6, 3)))
        XCTAssertTrue(s.isCompleted(on: day(6, 6)))
        XCTAssertEqual(s.liveRecordCount, 5)
    }

    /// Nothing deleted elsewhere: the store's count matches and no record is read to say so.
    func testWithEveryRecordInTheStoreTheCheckIsACount() throws {
        let h = habit(.daily)
        checkIn(h, on: (1...5).map { day(6, $0) })
        try context.save()
        guard case .attached = HabitStats.liveRecords(of: h) else { return XCTFail("expected .attached") }
        XCTAssertEqual(h.bestStreak(), 5)
    }

    /// A habit in no context has no store to ask: every record counts, for the lookups and the
    /// aggregates alike.
    func testAHabitInNoContextCountsEveryRecord() {
        let h = Habit(name: "Loose")
        h.createdAt = day(1, 1)
        for d in 1...4 { h.records.append(HabitRecord(date: day(6, d))) }
        guard case .all = HabitStats.liveRecords(of: h) else { return XCTFail("expected .all") }
        XCTAssertTrue(h.isCompletedOn(day(6, 2)))
        XCTAssertEqual(h.currentStreak(from: day(6, 4)), 4)
        XCTAssertEqual(h.bestStreak(), 4)
        XCTAssertEqual(WidgetTimelinePlan.RowInput(h).status(day(6, 4)).streak, 4)
    }

    /// demo_check's gate-2 count: completed days in a range, clamped to today; a count habit's
    /// partial days do not count, and a range of any width costs no more than the history.
    func testCompletedDayCountIsClampedToToday() {
        let h = habit(.daily)
        h.kind = HabitKind.count.rawValue
        h.targetValue = 8
        for d in 1...10 { h.records.append(HabitRecord(date: day(6, d), value: d % 2 == 0 ? 8 : 3)) }
        let s = stats(h, today: day(6, 8))
        XCTAssertEqual(s.completedDayCount(from: day(6, 1), to: day(6, 30)), 4, "06-02, 04, 06, 08")
        XCTAssertEqual(s.completedDayCount(from: .distantPast, to: .distantFuture), 4)
        XCTAssertEqual(s.completedDayCount(from: day(6, 3), to: day(6, 4)), 1)
        XCTAssertEqual(s.completedDayCount(from: day(6, 9), to: day(6, 1)), 0)
    }

    // MARK: - Widget rows (one HabitStats per habit, D3)

    /// Noon UTC on 06-10, in UTC: the plan's entries describe 06-10 and 06-11. The rows come from
    /// one HabitStats per habit (through 06-11), which answers both: a check-in dated tomorrow
    /// (the demo top-up's UTC day for a US reviewer) shows only on the midnight entry, and the
    /// day's note rides on the row (D7) for W2's noted-row link.
    func testWidgetRowsAnswerBothDayKeysFromOneHabitStats() throws {
        let noted = habit(.daily)
        checkIn(noted, on: [day(6, 9)])
        noted.records.append(HabitRecord(date: day(6, 10), note: "felt great"))
        noted.records.append(HabitRecord(date: day(6, 11)))
        let plain = habit(.daily)
        checkIn(plain, on: [day(6, 10)])
        try context.save()

        let now = utc.date(byAdding: .hour, value: 12, to: day(6, 10))!
        let plan = WidgetTimelinePlan(now: now, calendar: utc,
                                      rows: WidgetTimelinePlan.rowInputs(for: [noted, plain], in: context, now: now, calendar: utc))
        let (today, midnight) = (plan.entries[0], plan.entries[1])
        XCTAssertEqual(today.dayKey, day(6, 10))
        XCTAssertEqual(today.rows.map(\.isCompleted), [true, true])
        XCTAssertEqual(today.rows.map(\.streak), [2, 1], "tomorrow's check-in does not count today")
        XCTAssertEqual(today.rows.map(\.hasNote), [true, false])
        XCTAssertEqual(midnight.rows.map(\.isCompleted), [true, false])
        XCTAssertEqual(midnight.rows.map(\.streak), [3, 1])
        XCTAssertEqual(midnight.rows.map(\.hasNote), [false, false])
        XCTAssertEqual(WidgetTimelinePlan.lastDayKey(now: now, calendar: utc), day(6, 11))
    }

    // MARK: - Best streak ranges

    private func range(_ s: Date, _ e: Date, _ length: Int, current: Bool = false) -> HabitStats.StreakRange {
        HabitStats.StreakRange(start: s, end: e, length: length, isCurrent: current)
    }

    /// Runs of 3, 5 and 2 days: longest first, each with its exact first and last day.
    func testRangesAreSortedByLengthWithExactDates() {
        let h = habit(.daily)
        checkIn(h, on: (1...3).map { day(6, $0) } + (5...9).map { day(6, $0) } + (12...13).map { day(6, $0) })
        let s = stats(h, today: day(6, 20))

        XCTAssertEqual(s.bestStreakRanges, [range(day(6, 5), day(6, 9), 5),
                                            range(day(6, 1), day(6, 3), 3),
                                            range(day(6, 12), day(6, 13), 2)])
        XCTAssertEqual(s.bestStreak, 5)
        XCTAssertEqual(h.bestStreak(), s.bestStreakRanges.first?.length)
    }

    /// Two runs of 4: the more recent comes first.
    func testTiesGoToTheMostRecentRun() {
        let h = habit(.daily)
        checkIn(h, on: (1...4).map { day(6, $0) } + (10...13).map { day(6, $0) } + (20...21).map { day(6, $0) })
        let s = stats(h, today: day(6, 30))

        XCTAssertEqual(s.bestStreakRanges.map(\.start), [day(6, 10), day(6, 1), day(6, 20)])
        XCTAssertEqual(s.bestStreakRanges.map(\.length), [4, 4, 2])
    }

    /// Seven runs (1 to 4 days, with ties): only the top 5, longest first, ties most recent first.
    func testAtMostFiveRanges() {
        let h = habit(.daily)
        // Runs starting 06-01 (2), 06-04 (4), 06-09 (1), 06-11 (3), 06-15 (4), 06-20 (2), 06-23 (1).
        let runs: [(Int, Int)] = [(1, 2), (4, 4), (9, 1), (11, 3), (15, 4), (20, 2), (23, 1)]
        checkIn(h, on: runs.flatMap { start, length in (0..<length).map { day(6, start + $0) } })
        let s = stats(h, today: day(6, 30))

        XCTAssertEqual(s.bestStreakRanges.count, 5)
        XCTAssertEqual(s.bestStreakRanges.map(\.length), [4, 4, 3, 2, 2])
        XCTAssertEqual(s.bestStreakRanges.map(\.start), [day(6, 15), day(6, 4), day(6, 11), day(6, 20), day(6, 1)])
        XCTAssertEqual(s.bestStreakRanges.map(\.end), [day(6, 18), day(6, 7), day(6, 13), day(6, 21), day(6, 2)])
    }

    /// Mon/Wed/Fri for two weeks: one run of 6 SCHEDULED days from Mon 06-01 to Fri 06-12 — the
    /// rest days inside it neither count nor break it, and check-ins on rest days (Tue 06-09,
    /// Sat 06-13) add nothing and do not move its end. The missed Monday 06-15 ends it; the next
    /// run (Wed 06-17 to Mon 06-22) crosses a weekend too.
    func testSpecificDaysRunsCountScheduledDaysAcrossRestDays() {
        let h = habit(.specificDays, activeDays: monWedFriMask)
        checkIn(h, on: monWedFri(weeks: 2) + [day(6, 9), day(6, 13)] + [day(6, 17), day(6, 19), day(6, 22)])
        let s = stats(h, today: day(6, 30))

        XCTAssertEqual(s.bestStreakRanges, [range(day(6, 1), day(6, 12), 6),
                                            range(day(6, 17), day(6, 22), 3)])
        XCTAssertEqual(s.bestStreak, h.bestStreak())
    }

    /// 3×/week: weeks are Monday-anchored. Fri–Sun of one week and Mon of the next are four
    /// check-ins in four days, but the first week has 3 (met) and the second 1 (not): no run
    /// crosses the Monday. Met weeks run Monday to Sunday.
    func testTimesPerWeekRangesAreMondayAnchoredWeeks() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: [day(6, 5), day(6, 6), day(6, 7), day(6, 8)]          // week of 06-01: 3; of 06-08: 1
                + [day(6, 15), day(6, 17), day(6, 19)]                        // week of 06-15: met
                + [day(6, 22), day(6, 23), day(6, 28)])                       // week of 06-22: met
        let s = stats(h, today: day(7, 15))

        XCTAssertEqual(s.bestStreakRanges, [range(day(6, 15), day(6, 28), 2),
                                            range(day(6, 1), day(6, 7), 1)])
        XCTAssertEqual(s.bestStreak, h.bestStreak())
        XCTAssertEqual(utc.component(.weekday, from: s.bestStreakRanges[0].start), 2, "a Monday")
        XCTAssertEqual(utc.component(.weekday, from: s.bestStreakRanges[0].end), 1, "a Sunday")
    }

    /// The open run under the grace: today not done yet, so the streak still counts the run that
    /// ended yesterday. It is in the ranges, marked current, as long as the current streak.
    func testTheOpenRunUnderTheGraceIsTheCurrentRange() {
        let h = habit(.daily)
        checkIn(h, on: (1...3).map { day(6, $0) } + (10...16).map { day(6, $0) })
        let s = stats(h, today: day(6, 17))

        XCTAssertEqual(s.currentStreak(), 7)
        XCTAssertEqual(s.bestStreakRanges.first, range(day(6, 10), day(6, 16), 7, current: true))
        XCTAssertEqual(s.bestStreakRanges.last, range(day(6, 1), day(6, 3), 3))

        // A day later, with today still not done, the grace is spent: no run is current.
        let dayAfter = stats(h, today: day(6, 18))
        XCTAssertEqual(dayAfter.currentStreak(), 0)
        XCTAssertEqual(dayAfter.bestStreakRanges.filter(\.isCurrent), [])
    }

    /// Times-per-week: last week met and this week under way (one check-in, goal 3): the grace
    /// keeps the run that ended last Sunday open. Once this week is met, the run takes it in and
    /// ends on the last check-in — not on a Sunday that has not happened.
    func testTheOpenWeeklyRunUnderTheGrace() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, on: monWedFri(weeks: 2) + [day(6, 15)])
        let wed = day(6, 17)
        let s = stats(h, today: wed)

        XCTAssertEqual(s.currentStreak(), 2)
        XCTAssertEqual(s.bestStreakRanges, [range(day(6, 1), day(6, 14), 2, current: true)])

        checkIn(h, on: [day(6, 16), day(6, 17)])
        let met = stats(h, today: wed)
        XCTAssertEqual(met.currentStreak(), 3)
        XCTAssertEqual(met.bestStreakRanges, [range(day(6, 1), day(6, 17), 3, current: true)])
    }

    /// A specific-days run is open across rest days: today is a Saturday, Friday was done, so
    /// the Mon/Wed/Fri run is current; a check-in today, a rest day, does not extend it.
    func testASpecificDaysRunStaysOpenOverRestDays() {
        let h = habit(.specificDays, activeDays: monWedFriMask)
        checkIn(h, on: monWedFri(weeks: 1) + [day(6, 6)])
        let s = stats(h, today: day(6, 6))

        XCTAssertEqual(s.currentStreak(), 3)
        XCTAssertEqual(s.bestStreakRanges, [range(day(6, 1), day(6, 5), 3, current: true)])
    }

    /// No check-ins: no ranges, best 0.
    func testNoRecordsNoRanges() {
        let s = stats(habit(.daily), today: day(6, 1))
        XCTAssertEqual(s.bestStreakRanges, [])
        XCTAssertEqual(s.bestStreak, 0)
        XCTAssertEqual(s.currentStreak(), 0)
    }
}
