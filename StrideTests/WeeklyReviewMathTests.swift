import XCTest
import SwiftData
import Foundation

/// Weekly Review's and Today's week math (`WeeklyReviewMath`, RELEASE-1.4.2.md W1: D8, D9's
/// numbers, D10) and the two HabitStats additions beside it: the 12-week weekday tally (D7) and
/// strength on a given day.
///
/// Weeks are Monday-anchored on UTC day-keys (Data safety 5). The local-clock cases build their
/// instants in an explicit zone (Asia/Tokyo, America/Los_Angeles) and in the process's own zone,
/// so a run under `TEST_RUNNER_TZ=America/Los_Angeles` and one in the default zone both cover
/// it; the DST cases use 2026-11-01 and 2027-03-14 in Los Angeles; one case uses
/// `ja_JP@calendar=japanese`. Check-in dates are fixed day-keys: 2026-06-01 is a Monday.
@MainActor
final class WeeklyReviewMathTests: XCTestCase {

    typealias Math = WeeklyReviewMath

    var container: ModelContainer!
    var context: ModelContext!
    let utc = HabitCalendar.utc

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        print("WEEKLYREVIEW zone: TimeZone.current=\(TimeZone.current.identifier)")
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static func gregorian(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private let tokyo = gregorian(TimeZone(identifier: "Asia/Tokyo")!)
    private let la = gregorian(TimeZone(identifier: "America/Los_Angeles")!)
    /// The process's zone: Asia/Tokyo by default, Los Angeles under TEST_RUNNER_TZ.
    private let local = gregorian(.current)

    private var zones: [Calendar] { [tokyo, la, local, utc] }

    /// The day-key of a Gregorian date.
    private func key(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The day-key of a date in 2026.
    private func key(_ month: Int, _ day: Int) -> Date { key(2026, month, day) }

    private func keys(_ first: Date, through last: Date) -> [Date] {
        var out: [Date] = [], d = first
        while d <= last { out.append(d); d = utc.date(byAdding: .day, value: 1, to: d)! }
        return out
    }

    /// The instant of a local wall-clock time in `calendar`'s zone (always Gregorian Y/M/D).
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                    in calendar: Calendar) -> Date {
        let c = Self.gregorian(calendar.timeZone)
        return c.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// `at` in 2026.
    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in calendar: Calendar) -> Date {
        at(2026, month, day, hour, minute, in: calendar)
    }

    private func habit(_ schedule: HabitSchedule = .daily, timesPerWeek: Int = 7, activeDays: Int = 127,
                       created: Date, archived: Bool = false, group: UUID? = nil) -> Habit {
        let h = Habit(name: "Habit")
        h.schedule = schedule
        h.timesPerWeek = timesPerWeek
        h.activeDaysMask = activeDays
        h.createdAt = created
        h.isArchived = archived
        h.groupId = group
        context.insert(h)
        return h
    }

    private func checkIn(_ h: Habit, on dates: [Date]) {
        for d in dates { h.records.append(HabitRecord(date: d)) }
    }

    /// Stats as StatsCache builds them, for the day `today` (a day-key, so no instant is ever
    /// re-read as a key).
    private func stats(_ h: Habit, today: Date, calendar: Calendar? = nil) -> HabitStats {
        HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context),
                   calendar: calendar ?? utc, today: today)
    }

    private func review(_ habits: [Habit], today: Date, week: Math.WeekRange,
                        groups: [UUID] = []) -> Math.Review {
        Math.review(of: habits.map { Math.HabitInput(habit: $0, stats: stats($0, today: today)) },
                    week: week, groupOrder: groups)
    }

    private func week(of dayKey: Date) -> Math.WeekRange {
        Math.weekRange(containing: dayKey, in: utc)
    }

    /// Monday to Friday (bits 1…5).
    private let weekdays = 0b011_1110

    // MARK: - Weeks

    func testSundayLastMinuteAndMondayMidnight() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            let sunday = Math.weekRange(containing: at(6, 7, 23, 59, in: calendar), in: calendar)
            XCTAssertEqual(sunday.monday, key(6, 1), "\(zone): Sunday 23:59 is in the week of Monday 1 June")
            XCTAssertEqual(sunday.sunday, key(6, 7), zone)
            XCTAssertEqual(sunday.days, keys(key(6, 1), through: key(6, 7)), zone)
            let monday = Math.weekRange(containing: at(6, 8, 0, 0, in: calendar), in: calendar)
            XCTAssertEqual(monday.monday, key(6, 8), "\(zone): Monday 00:00 starts the next week")
            XCTAssertEqual(monday, sunday.next, zone)
            XCTAssertEqual(monday.previous, sunday, zone)
            XCTAssertTrue(monday.contains(key(6, 14)), zone)
            XCTAssertFalse(monday.contains(key(6, 7)), zone)
        }
        // A day-key is kept as it is, in every zone: never re-read as a local instant.
        for calendar in zones {
            XCTAssertEqual(Math.weekRange(containing: key(6, 7), in: calendar).monday, key(6, 1))
            XCTAssertEqual(Math.weekRange(containing: key(6, 8), in: calendar).monday, key(6, 8))
        }
    }

    func testTheDSTWeeks() {
        // 2026-11-01: Los Angeles falls back at 02:00 (a 25-hour Sunday).
        XCTAssertEqual(Math.weekRange(containing: at(11, 1, 1, 30, in: la), in: la).monday, key(10, 26))
        XCTAssertEqual(Math.weekRange(containing: at(11, 1, 23, 59, in: la), in: la).monday, key(10, 26))
        XCTAssertEqual(Math.weekRange(containing: at(11, 2, 0, 0, in: la), in: la).monday, key(11, 2))
        XCTAssertEqual(Math.weekRange(containing: at(11, 1, 23, 59, in: la), in: la).sunday, key(11, 1))
        // 2027-03-14: it springs forward at 02:00 (a 23-hour Sunday).
        XCTAssertEqual(Math.weekRange(containing: at(2027, 3, 14, 3, 30, in: la), in: la).monday, key(2027, 3, 8))
        XCTAssertEqual(Math.weekRange(containing: at(2027, 3, 14, 23, 59, in: la), in: la).monday, key(2027, 3, 8))
        XCTAssertEqual(Math.weekRange(containing: at(2027, 3, 15, 0, 0, in: la), in: la).monday, key(2027, 3, 15))
        // The opening week across them.
        XCTAssertEqual(Math.openingWeek(now: at(10, 28, 23, 59, in: la), calendar: la).week.monday, key(10, 19))
        XCTAssertEqual(Math.openingWeek(now: at(10, 29, 0, 0, in: la), calendar: la).week.monday, key(10, 26))
        XCTAssertEqual(Math.openingWeek(now: at(11, 2, 0, 0, in: la), calendar: la).week.monday, key(10, 26))
        XCTAssertEqual(Math.openingWeek(now: at(2027, 3, 10, 23, 59, in: la), calendar: la).week.monday, key(2027, 3, 1))
        XCTAssertEqual(Math.openingWeek(now: at(2027, 3, 11, 0, 0, in: la), calendar: la).week.monday, key(2027, 3, 8))
        // And in the process's own zone (Tokyo has no DST; Los Angeles under TEST_RUNNER_TZ).
        XCTAssertEqual(Math.weekRange(containing: at(11, 1, 23, 59, in: local), in: local).monday, key(10, 26))
        XCTAssertEqual(Math.weekRange(containing: at(2027, 3, 15, 0, 0, in: local), in: local).monday, key(2027, 3, 15))
    }

    func testTheJapaneseCalendar() {
        var japanese = Calendar(identifier: .japanese)
        japanese.locale = Locale(identifier: "ja_JP@calendar=japanese")
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // Reiwa 8 is 2026: the weeks are Gregorian day-keys, never year 8.
        let sunday = Math.weekRange(containing: at(6, 7, 23, 59, in: japanese), in: japanese)
        XCTAssertEqual(sunday.monday, key(6, 1))
        XCTAssertEqual(Math.weekRange(containing: at(6, 8, 0, 0, in: japanese), in: japanese).monday, key(6, 8))
        XCTAssertEqual(Math.openingWeek(now: at(6, 10, 23, 59, in: japanese), calendar: japanese),
                       Math.OpeningWeek(week: sunday, relation: .lastWeek))
        XCTAssertEqual(Math.openingWeek(now: at(6, 11, 0, 0, in: japanese), calendar: japanese).relation, .thisWeek)

        // The same review from stats keyed with the Japanese calendar.
        let h = habit(created: key(5, 1))
        checkIn(h, on: keys(key(5, 25), through: key(6, 7)))
        let a = HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context),
                           calendar: japanese, today: at(6, 9, 12, 0, in: japanese))
        XCTAssertEqual(a.today, key(6, 9))
        let r = Math.review(of: [Math.HabitInput(stats: a)], week: sunday)
        XCTAssertEqual(r.rows.map(\.rate), [1])
        XCTAssertEqual(r.changePoints, 0)
        // A specific-days habit's weekday is the real one under it (Monday/Wednesday/Friday).
        let mwf = habit(.specificDays, activeDays: (1 << 1) | (1 << 3) | (1 << 5), created: key(5, 1))
        checkIn(mwf, on: [key(6, 1), key(6, 3), key(6, 5)])
        let b = HabitStats(habit: mwf, liveRecordIDs: HabitStats.liveRecordIDs(of: [mwf], in: context),
                           calendar: japanese, today: at(6, 9, 12, 0, in: japanese))
        XCTAssertEqual(b.countedRate(ofWeekStarting: sunday.monday), 1)
    }

    // MARK: - The opening week (D8)

    func testWednesdayLastMinuteAndThursdayMidnight() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            let lastWeek = Math.WeekRange(containingDay: HabitStats.dayNumber(ofKey: key(6, 1)))
            let monday = Math.openingWeek(now: at(6, 8, 0, 0, in: calendar), calendar: calendar)
            XCTAssertEqual(monday, Math.OpeningWeek(week: lastWeek, relation: .lastWeek), "\(zone): Monday opens on last week")
            XCTAssertTrue(monday.isFinished, zone)
            let wednesday = Math.openingWeek(now: at(6, 10, 23, 59, in: calendar), calendar: calendar)
            XCTAssertEqual(wednesday.week, lastWeek, "\(zone): Wednesday 23:59 still opens on last week")
            XCTAssertEqual(wednesday.relation, .lastWeek, zone)
            let thursday = Math.openingWeek(now: at(6, 11, 0, 0, in: calendar), calendar: calendar)
            XCTAssertEqual(thursday.week, lastWeek.next, "\(zone): Thursday 00:00 opens on this week so far")
            XCTAssertEqual(thursday.relation, .thisWeek, zone)
            XCTAssertFalse(thursday.isFinished, zone)
            let sunday = Math.openingWeek(now: at(6, 14, 23, 59, in: calendar), calendar: calendar)
            XCTAssertEqual(sunday.week, lastWeek.next, zone)
            XCTAssertEqual(Math.openingWeek(now: at(6, 15, 0, 0, in: calendar), calendar: calendar).week,
                           lastWeek.next, "\(zone): the next Monday opens on the week just over")
        }
        XCTAssertEqual(Math.daysBeforeThisWeekOpens, 4)
    }

    func testARequestedWeekOpensOnThatWeek() {
        let now = at(6, 9, 10, 0, in: local)   // Tuesday 9 June
        let thisWeek = Math.weekRange(containing: key(6, 8), in: utc)
        XCTAssertEqual(Math.openingWeek(now: now, calendar: local, requested: key(6, 3)),
                       Math.OpeningWeek(week: thisWeek.previous, relation: .lastWeek))
        XCTAssertEqual(Math.openingWeek(now: now, calendar: local, requested: key(5, 20)),
                       Math.OpeningWeek(week: Math.weekRange(containing: key(5, 18), in: utc), relation: .earlier))
        // This week asked for on a Tuesday opens on it (not over).
        XCTAssertEqual(Math.openingWeek(now: now, calendar: local, requested: key(6, 8)),
                       Math.OpeningWeek(week: thisWeek, relation: .thisWeek))
        // A week after this one is never opened.
        XCTAssertEqual(Math.openingWeek(now: now, calendar: local, requested: key(7, 1)).week, thisWeek)
    }

    // MARK: - Change and highlights (D8)

    func testATuesdayOneOfOneAgainstSixtyPercentGivesNoHighlight() {
        // Monday to Friday: last week 3 of 5 (60 %); this week Monday done, Tuesday not yet.
        let h = habit(.specificDays, activeDays: weekdays, created: key(5, 1))
        checkIn(h, on: [key(6, 1), key(6, 3), key(6, 5), key(6, 8)])
        let thisWeek = week(of: key(6, 8))
        let tuesday = review([h], today: key(6, 9), week: thisWeek)
        XCTAssertEqual(tuesday.rows.first?.rate, 1, "1 of 1 counted: 100 %")
        XCTAssertEqual(tuesday.rows.first?.previousRate, 0.6)
        XCTAssertEqual(tuesday.rows.first?.countsChange, false)
        XCTAssertNil(tuesday.rows.first?.changePoints)
        XCTAssertNil(tuesday.changePoints, "no change line: it would read +40")
        XCTAssertNil(tuesday.mostImproved)
        XCTAssertFalse(tuesday.isFinished)

        // Wednesday after its check-in: 3 counted days, still nothing.
        checkIn(h, on: [key(6, 9), key(6, 10)])
        XCTAssertNil(review([h], today: key(6, 10), week: thisWeek).changePoints)
        // Thursday before its check-in: Monday to Wednesday counted, 3 days: nothing yet.
        XCTAssertNil(review([h], today: key(6, 11), week: thisWeek).changePoints)
        // Thursday after it: 4 counted days, 4 of 4 against 3 of 5.
        checkIn(h, on: [key(6, 11)])
        let thursday = review([h], today: key(6, 11), week: thisWeek)
        XCTAssertEqual(thursday.changePoints, 40)
        XCTAssertEqual(thursday.mostImproved, 0)
        XCTAssertFalse(thursday.isFinished, "labelled so far")
        // The finished week always counts.
        let after = review([h], today: key(6, 15), week: thisWeek)
        XCTAssertTrue(after.isFinished)
        XCTAssertEqual(after.rows.first?.countsChange, true)
    }

    func testAHabitAtEightyPercentOrMoreIsNeverSlipped() {
        // A 90 % week cannot be made from one week of one habit (at most 7 days are due), so the
        // two nearest: 6 of 7 (85 %) after 7 of 7, and 4 of 5 (80 %, the ceiling) after 5 of 5.
        let daily = habit(created: key(5, 1))
        checkIn(daily, on: keys(key(6, 1), through: key(6, 7)) + keys(key(6, 8), through: key(6, 13)))
        let five = habit(.specificDays, activeDays: weekdays, created: key(5, 1))
        checkIn(five, on: keys(key(6, 1), through: key(6, 5)) + keys(key(6, 8), through: key(6, 11)))
        let r = review([daily, five], today: key(6, 15), week: week(of: key(6, 8)))
        XCTAssertEqual(r.rows.map(\.changePoints), [-15, -20])
        XCTAssertNil(r.slipped, "85 % and 80 % this week: never Slipped")
        XCTAssertEqual(r.changePoints, -18, "the change line still says it (−17.5 rounded)")

        // Below the ceiling, the larger drop is Slipped.
        let low = habit(created: key(5, 1))
        checkIn(low, on: keys(key(6, 1), through: key(6, 7)) + keys(key(6, 8), through: key(6, 12)))
        let withLow = review([daily, five, low], today: key(6, 15), week: week(of: key(6, 8)))
        XCTAssertEqual(withLow.rows[2].changePoints, -29, "5 of 7 (71 %) after 7 of 7")
        XCTAssertEqual(withLow.slipped, 2)
        XCTAssertNil(withLow.mostImproved)
    }

    func testHighlightsNeedTenPointsAndTheLargestWins() {
        // Created on Wednesday of the week before: 4 of 5 (80 %), then 6 of 7 (85 %): +5.
        let small = habit(created: key(6, 3))
        checkIn(small, on: keys(key(6, 3), through: key(6, 6)) + keys(key(6, 8), through: key(6, 13)))
        // Monday to Friday: 3 of 5, then 4 of 5 (+20); and 1 of 5, then 4 of 5 (+60).
        let twenty = habit(.specificDays, activeDays: weekdays, created: key(5, 1))
        checkIn(twenty, on: [key(6, 1), key(6, 2), key(6, 3)] + keys(key(6, 8), through: key(6, 11)))
        let sixty = habit(.specificDays, activeDays: weekdays, created: key(5, 1))
        checkIn(sixty, on: [key(6, 1)] + keys(key(6, 8), through: key(6, 11)))
        let thisWeek = week(of: key(6, 8))

        let onlySmall = review([small], today: key(6, 15), week: thisWeek)
        XCTAssertEqual(onlySmall.changePoints, 5, "a change line")
        XCTAssertNil(onlySmall.mostImproved, "under 10 points: no highlight")

        let all = review([small, twenty, sixty], today: key(6, 15), week: thisWeek)
        XCTAssertEqual(all.rows.map(\.changePoints), [5, 20, 60])
        XCTAssertEqual(all.mostImproved, 2, "the largest rise")
        XCTAssertEqual(all.changePoints, 28, "(5 + 20 + 60) ÷ 3, rounded")
        XCTAssertNil(all.slipped)
        // A tie goes to the habit first in the caller's order.
        let tie = habit(.specificDays, activeDays: weekdays, created: key(5, 1))
        checkIn(tie, on: [key(6, 1), key(6, 2), key(6, 3)] + keys(key(6, 8), through: key(6, 11)))
        XCTAssertEqual(review([small, tie, twenty], today: key(6, 15), week: thisWeek).mostImproved, 1)
    }

    func testALevelWeekAndTheOverallRate() {
        let a = habit(created: key(5, 1)), b = habit(created: key(5, 1))
        checkIn(a, on: keys(key(6, 1), through: key(6, 7)) + keys(key(6, 8), through: key(6, 14)))
        checkIn(b, on: keys(key(6, 1), through: key(6, 4)) + keys(key(6, 8), through: key(6, 11)))
        let r = review([a, b], today: key(6, 15), week: week(of: key(6, 8)))
        XCTAssertEqual(r.changePoints, 0, "Level with the previous week")
        XCTAssertEqual(r.overall!, (1 + 4.0 / 7) / 2, accuracy: 1e-12)
        XCTAssertNil(r.mostImproved)
        XCTAssertNil(r.slipped)
    }

    func testAHabitCreatedMidWeek() {
        // Created on Wednesday 3 June, done Wednesday to Friday; Saturday before its check-in.
        let h = habit(created: key(6, 3).addingTimeInterval(9 * 3600))
        checkIn(h, on: [key(6, 3), key(6, 4), key(6, 5)])
        let thisWeek = week(of: key(6, 1))
        let saturday = review([h], today: key(6, 6), week: thisWeek)
        let row = try! XCTUnwrap(saturday.rows.first)
        XCTAssertEqual(row.rate, 1)
        XCTAssertNil(row.previousRate, "it did not exist last week")
        XCTAssertFalse(row.endsBeforeStart)
        XCTAssertFalse(row.countsChange, "Wednesday to Friday: 3 counted days")
        XCTAssertNil(saturday.changePoints)
        // The week before it ended before its start: "Not started", never a missed week.
        let before = review([h], today: key(6, 6), week: thisWeek.previous).rows[0]
        XCTAssertTrue(before.endsBeforeStart)
        XCTAssertNil(before.rate)
        XCTAssertEqual(stats(h, today: key(6, 6)).countedDayCount(ofWeekStarting: thisWeek.monday), 3)
        // Its second week compares with its first (3 of 5 days of it, as its rate counts them).
        checkIn(h, on: keys(key(6, 8), through: key(6, 14)))
        let next = review([h], today: key(6, 15), week: thisWeek.next)
        XCTAssertEqual(next.rows[0].previousRate, 0.6, "Wednesday to Sunday, 3 of 5")
        XCTAssertEqual(next.changePoints, 40)
    }

    func testArchivedHabitsAreLeftOut() {
        let kept = habit(created: key(5, 1))
        checkIn(kept, on: keys(key(6, 1), through: key(6, 14)))
        let archived = habit(created: key(5, 1), archived: true)
        checkIn(archived, on: keys(key(6, 1), through: key(6, 7)))
        let r = review([archived, kept], today: key(6, 15), week: week(of: key(6, 8)))
        XCTAssertEqual(r.rows.map(\.index), [1], "only the habit not archived, by its input position")
        XCTAssertNil(r.slipped, "the archived habit's 100 → 0 is not a slip")
        XCTAssertEqual(r.overall, 1)
        XCTAssertEqual(r.sections.map(\.members), [[1]])
        // Never at risk either.
        let s = stats(archived, today: key(6, 15))
        XCTAssertFalse(Math.isAtRisk(s, isArchived: true, now: at(6, 15, 23, 0, in: local), calendar: local,
                                     eveningTime: .defaultEvening))
        XCTAssertFalse(Math.isAtRisk(archived, stats: s, now: at(6, 15, 23, 0, in: local), calendar: local,
                                     dailyReminder: nil))
    }

    func testAnEmptyReview() {
        let r = Math.review(of: [], week: week(of: key(6, 8)))
        XCTAssertEqual(r.rows, [])
        XCTAssertNil(r.overall)
        XCTAssertNil(r.changePoints)
        XCTAssertEqual(r.sections, [])
    }

    // MARK: - Group sections

    func testGroupSectionRates() {
        let morning = UUID(), evening = UUID(), empty = UUID(), gone = UUID()
        let a = habit(created: key(5, 1), group: evening)
        let b = habit(created: key(5, 1), group: morning)
        let c = habit(created: key(5, 1), group: evening)
        let d = habit(created: key(5, 1))
        let e = habit(created: key(5, 1), group: gone)
        let late = habit(created: key(6, 20), group: morning)   // nothing to count that week
        checkIn(a, on: keys(key(6, 8), through: key(6, 14)))                     // 100 %
        checkIn(b, on: keys(key(6, 8), through: key(6, 10)))                     // 3 of 7
        checkIn(c, on: keys(key(6, 8), through: key(6, 11)))                     // 4 of 7
        checkIn(d, on: [key(6, 8)])                                              // 1 of 7
        let r = review([a, b, c, d, e, late], today: key(6, 22), week: week(of: key(6, 8)),
                       groups: [morning, evening, empty])
        XCTAssertEqual(r.sections.map(\.groupID), [morning, evening, nil], "group order, empty left out, Ungrouped last")
        XCTAssertEqual(r.sections.map(\.members), [[1, 5], [0, 2], [3, 4]], "a missing group is Ungrouped")
        XCTAssertEqual(r.sections[0].rate!, 3.0 / 7, accuracy: 1e-12, "a member with nothing to count is left out")
        XCTAssertEqual(r.sections[1].rate!, (1 + 4.0 / 7) / 2, accuracy: 1e-12)
        XCTAssertEqual(r.sections[2].rate!, (1.0 / 7) / 2, accuracy: 1e-12)

        // No groups: one section of every row.
        let flat = review([a, b], today: key(6, 22), week: week(of: key(6, 8)))
        XCTAssertEqual(flat.sections, [Math.Section(groupID: nil, members: [0, 1], rate: flat.overall)])
    }

    // MARK: - Strength (D9's numbers)

    func testStrengthOnADayAndItsWeeklyChange() {
        let h = habit(created: key(5, 4))
        checkIn(h, on: keys(key(5, 4), through: key(6, 14)))
        let s = stats(h, today: key(6, 15))
        let lastWeek = week(of: key(6, 8))
        let end = s.strength(on: key(6, 14)), before = s.strength(on: key(6, 7))
        XCTAssertGreaterThan(end, before)
        XCTAssertEqual(s.strengthChange(ofWeekStarting: lastWeek.monday)!, end - before, accuracy: 1e-15)
        XCTAssertEqual(Math.strengthChangePoints(of: s, week: lastWeek),
                       HabitScore.displayValue(end) - HabitScore.displayValue(before))
        XCTAssertEqual(s.strength(on: key(6, 14)), s.strengthSeries.score(on: key(6, 14)))
        // Today not done yet: the latest score holds, and this week reads it.
        XCTAssertEqual(s.strength(on: key(6, 15)), s.strength)
        XCTAssertEqual(s.strengthChange(ofWeekStarting: key(6, 15))!, s.strength - end, accuracy: 1e-15)
        // Before the start: 0, and no change for a week that ended before it.
        XCTAssertEqual(s.strength(on: key(5, 1)), 0)
        XCTAssertNil(s.strengthChange(ofWeekStarting: key(4, 27)))
        XCTAssertNil(Math.strengthChangePoints(of: s, week: week(of: key(4, 27))))
        // Its first week gains everything it has.
        XCTAssertEqual(s.strengthChange(ofWeekStarting: key(5, 4))!, s.strength(on: key(5, 10)), accuracy: 1e-15)
        // A week after today has none.
        XCTAssertNil(s.strengthChange(ofWeekStarting: key(6, 22)))
    }

    // MARK: - The 12-week weekday tally (D7)

    func testTheTwelveWeekTallyBesideTheAllTimeOne() {
        // Daily since 2026-01-05 (a Monday), every Sunday missed until 22 March, every day since.
        let h = habit(created: key(1, 5))
        let all = keys(key(1, 5), through: key(6, 14))
        checkIn(h, on: all.filter { $0 >= key(3, 23) || HabitStats.weekday(ofDay: HabitStats.dayNumber(ofKey: $0)) != 1 })
        let s = stats(h, today: key(6, 15))   // Monday, not done: counted through Sunday 14 June
        XCTAssertEqual(HabitStats.recentWeekdayWeeks, 12)
        let recent = s.recentWeekdayTallies
        XCTAssertEqual(Set(recent.keys), Set(1...7))
        for weekday in 1...7 {
            XCTAssertEqual(recent[weekday], StatsInsights.WeekdayTally(done: 12, due: 12), "weekday \(weekday)")
        }
        XCTAssertEqual(s.weekdayTallies[1], StatsInsights.WeekdayTally(done: 12, due: 23), "all time keeps the misses")
        XCTAssertEqual(s.weekdayTallies(lastWeeks: 12), recent)
        XCTAssertEqual(s.weekdayTallies(lastWeeks: 20)[1], StatsInsights.WeekdayTally(done: 12, due: 20))
        // A habit younger than the window: the window is its whole life, as the all-time tally.
        let young = habit(created: key(5, 25))
        checkIn(young, on: keys(key(5, 25), through: key(6, 14)))
        let y = stats(young, today: key(6, 15))
        XCTAssertEqual(y.recentWeekdayTallies, y.weekdayTallies)
        XCTAssertEqual(y.recentWeekdayTallies[2], StatsInsights.WeekdayTally(done: 3, due: 3))
        // Times-per-week has no weekday schedule.
        let tpw = habit(.timesPerWeek, timesPerWeek: 3, created: key(1, 5))
        checkIn(tpw, on: [key(6, 1)])
        XCTAssertEqual(stats(tpw, today: key(6, 15)).recentWeekdayTallies, [:])
    }

    // MARK: - At risk (D10)

    func testTimesPerWeekAtRiskOnFridaySaturdaySundayAndMonday() {
        for calendar in [tokyo, la, local] {
            let zone = calendar.timeZone.identifier
            // 3 times a week, nothing done this week (1–7 June).
            let h = habit(.timesPerWeek, timesPerWeek: 3, created: key(5, 1))
            func goal(_ today: Date, _ hour: Int = 9) -> Math.WeekGoal? {
                let comps = utc.dateComponents([.month, .day], from: today)
                return Math.weekGoal(of: stats(h, today: today), now: at(6, comps.day!, hour, 0, in: calendar),
                                     calendar: calendar)
            }
            XCTAssertEqual(goal(key(6, 4)), Math.WeekGoal(done: 0, goal: 3, remaining: 3, daysLeft: 4, isAtRisk: false), "\(zone) Thursday")
            XCTAssertEqual(goal(key(6, 5)), Math.WeekGoal(done: 0, goal: 3, remaining: 3, daysLeft: 3, isAtRisk: true), "\(zone) Friday")
            XCTAssertEqual(goal(key(6, 5), 0)?.isAtRisk, true, "\(zone): from Friday 00:00, whatever the hour")
            // Saturday with one done (Friday's): 2 more, 2 days left.
            checkIn(h, on: [key(6, 5)])
            XCTAssertEqual(goal(key(6, 6)), Math.WeekGoal(done: 1, goal: 3, remaining: 2, daysLeft: 2, isAtRisk: true), "\(zone) Saturday")
            // Sunday: done today, 1 more still owed and no day left.
            checkIn(h, on: [key(6, 7)])
            XCTAssertEqual(goal(key(6, 7)), Math.WeekGoal(done: 2, goal: 3, remaining: 1, daysLeft: 0, isAtRisk: true), "\(zone) Sunday")
            // Monday: a new week, 3 more and 7 days.
            XCTAssertEqual(goal(key(6, 8)), Math.WeekGoal(done: 0, goal: 3, remaining: 3, daysLeft: 7, isAtRisk: false), "\(zone) Monday")
            // Met: nothing remains, never at risk.
            checkIn(h, on: [key(6, 6)])
            XCTAssertEqual(goal(key(6, 7)), Math.WeekGoal(done: 3, goal: 3, remaining: 0, daysLeft: 0, isAtRisk: false), "\(zone) met")

            // 7 times a week is at risk from Monday: every day is owed.
            let every = habit(.timesPerWeek, timesPerWeek: 7, created: key(5, 1))
            let monday = Math.weekGoal(of: stats(every, today: key(6, 8)), now: at(6, 8, 0, 0, in: calendar), calendar: calendar)
            XCTAssertEqual(monday, Math.WeekGoal(done: 0, goal: 7, remaining: 7, daysLeft: 7, isAtRisk: true), "\(zone) 7× Monday")
            XCTAssertTrue(Math.isAtRisk(stats(every, today: key(6, 8)), isArchived: false, now: at(6, 8, 0, 0, in: calendar),
                                        calendar: calendar, eveningTime: .defaultEvening))
            // Only for times-per-week.
            XCTAssertNil(Math.weekGoal(of: stats(habit(created: key(5, 1)), today: key(6, 8)),
                                       now: at(6, 8, 9, 0, in: calendar), calendar: calendar))
        }
    }

    func testATimesPerWeekHabitCreatedMidWeekOwesItsShare() {
        let saturday = habit(.timesPerWeek, timesPerWeek: 3, created: key(6, 6).addingTimeInterval(10 * 3600))
        let s = stats(saturday, today: key(6, 6))
        let goal = Math.weekGoal(of: s, now: at(6, 6, 20, 0, in: local), calendar: local)
        XCTAssertEqual(goal, Math.WeekGoal(done: 0, goal: 3, remaining: 3, daysLeft: 2, isAtRisk: false),
                       "2 of 7 days: owes 1 (3 × 2 ÷ 7, rounded up), with 2 days left")
        // Created on Thursday: owes 2 (3 × 4 ÷ 7 rounded up); on Saturday with none done, at risk.
        let thursday = habit(.timesPerWeek, timesPerWeek: 3, created: key(6, 4).addingTimeInterval(10 * 3600))
        XCTAssertEqual(Math.weekGoal(of: stats(thursday, today: key(6, 6)), now: at(6, 6, 9, 0, in: local),
                                     calendar: local)?.isAtRisk, true)
        XCTAssertEqual(Math.weekGoal(of: stats(thursday, today: key(6, 5)), now: at(6, 5, 9, 0, in: local),
                                     calendar: local)?.isAtRisk, false, "Friday: 2 owed, 3 days left")
        // A daily habit created today is at risk after the evening like any other.
        let daily = habit(created: key(6, 6).addingTimeInterval(10 * 3600))
        XCTAssertTrue(Math.isAtRisk(stats(daily, today: key(6, 6)), isArchived: false, now: at(6, 6, 18, 0, in: local),
                                    calendar: local, eveningTime: .defaultEvening))
    }

    func testDailyAtRiskBeforeAndAfterTheEveningTime() {
        for calendar in [tokyo, la, local] {
            let zone = calendar.timeZone.identifier
            let h = habit(created: key(5, 1))
            let s = stats(h, today: key(6, 9))
            func risk(_ hour: Int, _ minute: Int, _ evening: Math.TimeOfDay = .defaultEvening) -> Bool {
                Math.isAtRisk(s, isArchived: false, now: at(6, 9, hour, minute, in: calendar), calendar: calendar,
                              eveningTime: evening)
            }
            XCTAssertFalse(risk(17, 59), "\(zone): before 18:00")
            XCTAssertTrue(risk(18, 0), "\(zone): from 18:00")
            XCTAssertTrue(risk(23, 59), zone)
            XCTAssertFalse(risk(0, 0), zone)
            // Done today: never.
            checkIn(h, on: [key(6, 9)])
            XCTAssertFalse(Math.isAtRisk(stats(h, today: key(6, 9)), isArchived: false, now: at(6, 9, 22, 0, in: calendar),
                                         calendar: calendar, eveningTime: .defaultEvening), zone)
            // A specific-days habit on a rest day: never.
            let mwf = habit(.specificDays, activeDays: (1 << 1) | (1 << 3) | (1 << 5), created: key(5, 1))
            XCTAssertFalse(Math.isAtRisk(stats(mwf, today: key(6, 9)), isArchived: false, now: at(6, 9, 22, 0, in: calendar),
                                         calendar: calendar, eveningTime: .defaultEvening), "\(zone): Tuesday is a rest day")
            XCTAssertTrue(Math.isAtRisk(stats(mwf, today: key(6, 10)), isArchived: false, now: at(6, 10, 22, 0, in: calendar),
                                        calendar: calendar, eveningTime: .defaultEvening), "\(zone): Wednesday is due")
        }
    }

    func testTheEveningTimeIsTheHabitsReminderThenTheDailyReminderThen18() {
        let nine = Math.TimeOfDay(hour: 21, minute: 0), eight = Math.TimeOfDay(hour: 20, minute: 30)
        XCTAssertEqual(Math.eveningTime(habitReminder: nine, dailyReminder: eight), nine)
        XCTAssertEqual(Math.eveningTime(habitReminder: nil, dailyReminder: eight), eight)
        XCTAssertEqual(Math.eveningTime(habitReminder: nil, dailyReminder: nil), Math.TimeOfDay(hour: 18, minute: 0))

        for calendar in [tokyo, la, local] {
            let zone = calendar.timeZone.identifier
            let h = habit(created: key(5, 1))
            let s = stats(h, today: key(6, 9))
            func risk(_ hour: Int, _ minute: Int, daily: Math.TimeOfDay?) -> Bool {
                Math.isAtRisk(h, stats: s, now: at(6, 9, hour, minute, in: calendar), calendar: calendar, dailyReminder: daily)
            }
            // Its own reminder at 21:00: not at 20:59 though past 18:00 and the Daily Reminder's 20:30.
            h.reminderEnabled = true; h.reminderHour = 21; h.reminderMinute = 0
            XCTAssertFalse(risk(20, 59, daily: eight), "\(zone): before its own reminder")
            XCTAssertTrue(risk(21, 0, daily: eight), "\(zone): after its own reminder")
            // Its own reminder at 07:15 (a morning one) is still its time.
            h.reminderHour = 7; h.reminderMinute = 15
            XCTAssertFalse(risk(7, 14, daily: nil), zone)
            XCTAssertTrue(risk(7, 15, daily: nil), zone)
            // Its reminder off: the Daily Reminder's time, not its stored one.
            h.reminderEnabled = false
            XCTAssertFalse(risk(20, 29, daily: eight), "\(zone): before the Daily Reminder")
            XCTAssertTrue(risk(20, 30, daily: eight), "\(zone): after the Daily Reminder")
            // Neither on: 18:00.
            XCTAssertFalse(risk(17, 59, daily: nil), zone)
            XCTAssertTrue(risk(18, 0, daily: nil), zone)
        }
    }

    func testAtRiskOnTheDSTSundays() {
        // 18:00 on the 25-hour and the 23-hour Sunday, Los Angeles.
        let h = habit(created: key(10, 1))
        let fall = stats(h, today: key(11, 1))
        XCTAssertFalse(Math.isAtRisk(fall, isArchived: false, now: at(11, 1, 17, 59, in: la), calendar: la, eveningTime: .defaultEvening))
        XCTAssertTrue(Math.isAtRisk(fall, isArchived: false, now: at(11, 1, 18, 0, in: la), calendar: la, eveningTime: .defaultEvening))
        let spring = stats(h, today: key(2027, 3, 14))
        XCTAssertFalse(Math.isAtRisk(spring, isArchived: false, now: at(2027, 3, 14, 17, 59, in: la), calendar: la, eveningTime: .defaultEvening))
        XCTAssertTrue(Math.isAtRisk(spring, isArchived: false, now: at(2027, 3, 14, 18, 0, in: la), calendar: la, eveningTime: .defaultEvening))
        // Sunday 16:00 PST is exactly UTC midnight of Monday: still Sunday, keyed as an instant.
        let tpw = habit(.timesPerWeek, timesPerWeek: 2, created: key(10, 1))
        checkIn(tpw, on: [key(11, 2)])
        let sundayAfternoon = Math.weekGoal(of: stats(tpw, today: key(11, 8)), now: at(11, 8, 16, 0, in: la), calendar: la)
        XCTAssertEqual(sundayAfternoon, Math.WeekGoal(done: 1, goal: 2, remaining: 1, daysLeft: 1, isAtRisk: true))
    }
}
