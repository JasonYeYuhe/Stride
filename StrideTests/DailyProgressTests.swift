import XCTest
import SwiftData
import Foundation

/// `DailyProgress` (RELEASE-1.5.0.md D1): one habit's state on one day, and a day's totals, the
/// rule Today's card, the badge, the Dock, the widget, the review's perfect days and
/// `WeeklyReviewMath.isAtRisk` share.
///
/// Every state for a binary and a count habit (a target of 0 included); a times-per-week goal met
/// on Friday, Saturday, Sunday and Monday; a habit created today is not started yesterday; a key
/// at an exact UTC midnight; a rest day with nothing due. Stats are built in Asia/Tokyo,
/// America/Los_Angeles, UTC and the process's own zone, so a run under
/// `TEST_RUNNER_TZ=America/Los_Angeles` and one in the default zone both cover the Americas.
/// Check-in dates are fixed day-keys: 2026-06-01 is a Monday.
@MainActor
final class DailyProgressTests: XCTestCase {

    typealias State = DailyProgress.State

    var container: ModelContainer!
    var context: ModelContext!
    let utc = HabitCalendar.utc

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        print("DAILYPROGRESS zone: TimeZone.current=\(TimeZone.current.identifier)")
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

    /// The day-key of a date in 2026.
    private func key(_ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    /// The instant of a local wall-clock time in 2026 in `calendar`'s zone.
    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in calendar: Calendar) -> Date {
        Self.gregorian(calendar.timeZone)
            .date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Monday, Wednesday, Friday (bits 1, 3, 5).
    private let mwf = (1 << 1) | (1 << 3) | (1 << 5)

    private func habit(_ schedule: HabitSchedule = .daily, timesPerWeek: Int = 7, activeDays: Int = 127,
                       kind: HabitKind = .binary, target: Double = 1, created: Date) -> Habit {
        let h = Habit(name: "Habit")
        h.schedule = schedule
        h.timesPerWeek = timesPerWeek
        h.activeDaysMask = activeDays
        h.habitKind = kind
        h.targetValue = target
        h.createdAt = created
        context.insert(h)
        return h
    }

    private func checkIn(_ h: Habit, on dates: [Date], value: Double = 1) {
        for d in dates { h.records.append(HabitRecord(date: d, value: value)) }
    }

    /// Stats as StatsCache builds them, for the day-key `today`, keying instants in `calendar`.
    private func stats(_ h: Habit, today: Date, calendar: Calendar? = nil) -> HabitStats {
        HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context),
                   calendar: calendar ?? utc, today: today)
    }

    private func state(_ h: Habit, on day: Date, today: Date? = nil, calendar: Calendar? = nil) -> State {
        DailyProgress.state(of: stats(h, today: today ?? day, calendar: calendar), on: day)
    }

    // MARK: - Every state, binary

    func testEveryStateOfABinaryHabit() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            // Daily: done, due.
            let daily = habit(created: key(5, 1))
            checkIn(daily, on: [key(6, 2)])
            XCTAssertEqual(state(daily, on: key(6, 2), calendar: calendar), .done, zone)
            XCTAssertEqual(state(daily, on: key(6, 3), calendar: calendar), .due, zone)
            // Mon/Wed/Fri: Tuesday rests; a check-in on it is done; Wednesday is due.
            let days = habit(.specificDays, activeDays: mwf, created: key(5, 1))
            XCTAssertEqual(state(days, on: key(6, 2), calendar: calendar), .rest, "\(zone): Tuesday")
            XCTAssertEqual(state(days, on: key(6, 3), calendar: calendar), .due, "\(zone): Wednesday")
            checkIn(days, on: [key(6, 2)])
            XCTAssertEqual(state(days, on: key(6, 2), calendar: calendar), .done, "\(zone): a done rest day is done")
            // Times-per-week: due until the goal is met, then met on the days without a check-in.
            let tpw = habit(.timesPerWeek, timesPerWeek: 2, created: key(5, 1))
            checkIn(tpw, on: [key(6, 1), key(6, 2)])
            XCTAssertEqual(state(tpw, on: key(6, 2), calendar: calendar), .done, zone)
            XCTAssertEqual(state(tpw, on: key(6, 3), calendar: calendar), .metForWeek, zone)
            let open = habit(.timesPerWeek, timesPerWeek: 3, created: key(5, 1))
            checkIn(open, on: [key(6, 1)])
            XCTAssertEqual(state(open, on: key(6, 3), calendar: calendar), .due, "\(zone): 1 of 3")
            // Not started: the day before its creation.
            let late = habit(created: key(6, 5))
            XCTAssertEqual(state(late, on: key(6, 4), today: key(6, 5), calendar: calendar), .notStarted, zone)
            XCTAssertEqual(state(late, on: key(6, 5), calendar: calendar), .due, zone)
        }
        // Every case is reached above; `counts` is true only for the two that count in `due`.
        XCTAssertEqual(State.allCases.filter(\.counts), [.done, .due])
    }

    // MARK: - Every state, count (a target of 0 included)

    func testEveryStateOfACountHabit() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            let glasses = habit(kind: .count, target: 3, created: key(5, 1))
            checkIn(glasses, on: [key(6, 1)], value: 3)
            checkIn(glasses, on: [key(6, 2)], value: 2)
            XCTAssertEqual(state(glasses, on: key(6, 1), calendar: calendar), .done, "\(zone): the target reached")
            XCTAssertEqual(state(glasses, on: key(6, 2), calendar: calendar), .due, "\(zone): 2 of 3 is still due")
            XCTAssertEqual(state(glasses, on: key(6, 3), calendar: calendar), .due, "\(zone): nothing logged")
            // Above the target is done; the day's largest value counts.
            checkIn(glasses, on: [key(6, 2)], value: 5)
            XCTAssertEqual(state(glasses, on: key(6, 2), calendar: calendar), .done, zone)

            // A target of 0 is never done: logged or not, a due day stays due.
            let zero = habit(kind: .count, target: 0, created: key(5, 1))
            checkIn(zero, on: [key(6, 1)], value: 4)
            XCTAssertEqual(state(zero, on: key(6, 1), calendar: calendar), .due, "\(zone): target 0, logged")
            XCTAssertEqual(state(zero, on: key(6, 2), calendar: calendar), .due, "\(zone): target 0, nothing")
            let zeroDays = habit(.specificDays, activeDays: mwf, kind: .count, target: 0, created: key(5, 1))
            XCTAssertEqual(state(zeroDays, on: key(6, 2), calendar: calendar), .rest, "\(zone): target 0 still rests")

            // Count on specific days and times-per-week.
            let days = habit(.specificDays, activeDays: mwf, kind: .count, target: 2, created: key(5, 1))
            XCTAssertEqual(state(days, on: key(6, 2), calendar: calendar), .rest, zone)
            checkIn(days, on: [key(6, 2)], value: 1)
            XCTAssertEqual(state(days, on: key(6, 2), calendar: calendar), .rest, "\(zone): partial on a rest day is not done")
            checkIn(days, on: [key(6, 4)], value: 2)
            XCTAssertEqual(state(days, on: key(6, 4), calendar: calendar), .done, "\(zone): done on a rest day (Thursday)")
            let tpw = habit(.timesPerWeek, timesPerWeek: 1, kind: .count, target: 2, created: key(5, 1))
            checkIn(tpw, on: [key(6, 1)], value: 1)
            XCTAssertEqual(state(tpw, on: key(6, 2), calendar: calendar), .due, "\(zone): a partial day does not meet the week")
            checkIn(tpw, on: [key(6, 2)], value: 2)
            XCTAssertEqual(state(tpw, on: key(6, 3), calendar: calendar), .metForWeek, zone)

            let late = habit(kind: .count, target: 3, created: key(6, 5))
            XCTAssertEqual(state(late, on: key(6, 4), today: key(6, 5), calendar: calendar), .notStarted, zone)
        }
    }

    // MARK: - Times-per-week met Friday to Monday

    func testATimesPerWeekGoalMetOnFridaySaturdayAndSundayThenMonday() {
        // 2 a week, Monday done; the second check-in on Friday, Saturday or Sunday.
        for calendar in zones {
            for metOn in [5, 6, 7] {
                let label = "\(calendar.timeZone.identifier), met on June \(metOn)"
                let h = habit(.timesPerWeek, timesPerWeek: 2, created: key(5, 1))
                checkIn(h, on: [key(6, 1), key(6, metOn)])
                let s = stats(h, today: key(6, 8), calendar: calendar)
                for day in 2..<metOn {
                    XCTAssertEqual(DailyProgress.state(of: s, on: key(6, day)), .due, "\(label): June \(day)")
                }
                XCTAssertEqual(DailyProgress.state(of: s, on: key(6, metOn)), .done, label)
                for day in (metOn + 1)..<8 {
                    XCTAssertEqual(DailyProgress.state(of: s, on: key(6, day)), .metForWeek, "\(label): June \(day)")
                }
                // Monday: a new week owes the whole goal again.
                XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 8)), .due, "\(label): Monday resets")
            }
            // Met on a Monday (1 a week): Tuesday to Sunday are met, the next Monday is due.
            let once = habit(.timesPerWeek, timesPerWeek: 1, created: key(5, 1))
            checkIn(once, on: [key(6, 8)])
            let s = stats(once, today: key(6, 15), calendar: calendar)
            XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 8)), .done)
            for day in 9...14 { XCTAssertEqual(DailyProgress.state(of: s, on: key(6, day)), .metForWeek, "June \(day)") }
            XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 15)), .due)
        }
    }

    func testTheCreationWeeksShareMetIsMetForTheWeek() {
        // 3 a week, created Friday 5 June: Friday to Sunday owe ⌈3 × 3/7⌉ = 2. Done Friday and
        // Saturday, Sunday owes nothing (the row prints no "more"), so it is met, not remaining,
        // although the whole goal (3) is not reached. Monday owes the whole goal again.
        for calendar in zones {
            let h = habit(.timesPerWeek, timesPerWeek: 3, created: key(6, 5))
            checkIn(h, on: [key(6, 5), key(6, 6)])
            let s = stats(h, today: key(6, 8), calendar: calendar)
            let goal = WeeklyReviewMath.weekGoal(of: s, on: key(6, 7))
            XCTAssertEqual(goal?.owed, 0, calendar.timeZone.identifier)
            XCTAssertEqual(goal?.remaining, 1, calendar.timeZone.identifier)
            XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 7)), .metForWeek, calendar.timeZone.identifier)
            XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 8)), .due, calendar.timeZone.identifier)
        }
    }

    func testAWidgetEntryForTomorrowReadsItsOwnDay() {
        // Stats built for Sunday 7 June (a met week); the midnight entry asks about Monday 8 June.
        let tpw = habit(.timesPerWeek, timesPerWeek: 1, created: key(5, 1))
        checkIn(tpw, on: [key(6, 3)])
        let days = habit(.specificDays, activeDays: mwf, created: key(5, 1))
        checkIn(days, on: [key(6, 5)])
        let sunday = [stats(tpw, today: key(6, 7)), stats(days, today: key(6, 7))]
        XCTAssertEqual(sunday.map { DailyProgress.state(of: $0, on: key(6, 7)) }, [.metForWeek, .rest])
        XCTAssertEqual(DailyProgress(of: sunday, on: key(6, 7)), DailyProgress(done: 0, due: 0))
        XCTAssertEqual(sunday.map { DailyProgress.state(of: $0, on: key(6, 8)) }, [.due, .due], "Monday resets the week")
        XCTAssertEqual(DailyProgress(of: sunday, on: key(6, 8)).remaining, 2)
        XCTAssertEqual(DailyProgress.state(of: sunday[1], on: key(6, 9)), .rest, "Tuesday rests")
    }

    // MARK: - Created today

    func testAHabitCreatedTodayIsNotStartedYesterday() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            // Created at 00:30 and at 23:30 local on 9 June: 8 June 15:30Z in Tokyo, 10 June 06:30Z
            // in Los Angeles. Both are 9 June where they were made.
            for (hour, minute) in [(0, 30), (23, 30)] {
                let h = habit(created: at(6, 9, hour, minute, in: calendar))
                let s = stats(h, today: key(6, 9), calendar: calendar)
                XCTAssertEqual(s.startDay, key(6, 9), zone)
                XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 9)), .due, "\(zone) \(hour):\(minute): today")
                XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 8)), .notStarted, "\(zone) \(hour):\(minute): yesterday")
                XCTAssertEqual(DailyProgress(of: [s], on: key(6, 8)), DailyProgress(done: 0, due: 0))
                XCTAssertFalse(DailyProgress(of: [s], on: key(6, 8)).isPerfect)
            }
            // A specific-days habit created today on one of its rest days: rest today, not started
            // yesterday.
            let days = habit(.specificDays, activeDays: mwf, created: at(6, 9, 10, 0, in: calendar))
            XCTAssertEqual(state(days, on: key(6, 9), calendar: calendar), .rest, zone)
            XCTAssertEqual(state(days, on: key(6, 8), today: key(6, 9), calendar: calendar), .notStarted, zone)
        }
        // A check-in backdated before the creation day moves the start to it (HabitStats.startDay).
        let backdated = habit(created: key(6, 9))
        checkIn(backdated, on: [key(6, 7)])
        XCTAssertEqual(state(backdated, on: key(6, 7), today: key(6, 9)), .done)
        XCTAssertEqual(state(backdated, on: key(6, 8), today: key(6, 9)), .due)
        XCTAssertEqual(state(backdated, on: key(6, 6), today: key(6, 9)), .notStarted)
    }

    // MARK: - An exact UTC midnight

    func testAKeyAtAnExactUTCMidnight() {
        // Monday 8 June 17:00 PDT is exactly 2026-06-09 00:00:00Z.
        let now = at(6, 8, 17, 0, in: la)
        XCTAssertEqual(now.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400), 0)
        XCTAssertEqual(DailyProgress.today(now: now, calendar: la), key(6, 8), "keyed as an instant: still Monday")
        XCTAssertEqual(DailyProgress.today(now: now, calendar: la), WeeklyReviewMath.today(now: now, calendar: la))
        XCTAssertEqual(HabitCalendar.dayKey(for: now, localCalendar: la), key(6, 9),
                       "the trap D1 names: dayKey(for:) takes it for Tuesday's key")

        // A Mon/Wed/Fri habit: Monday is due, Tuesday rests. Asked with the key of Tuesday, in Los
        // Angeles stats, it is Tuesday (never re-read as Monday 17:00 local).
        let days = habit(.specificDays, activeDays: mwf, created: key(5, 1))
        let s = stats(days, today: key(6, 9), calendar: la)
        XCTAssertEqual(DailyProgress.state(of: s, on: DailyProgress.today(now: now, calendar: la)), .due)
        XCTAssertEqual(DailyProgress.state(of: s, on: key(6, 9)), .rest)
        // Done on Monday: the badge at 17:00 PDT reads nothing left.
        checkIn(days, on: [key(6, 8)])
        let monday = stats(days, today: DailyProgress.today(now: now, calendar: la), calendar: la)
        XCTAssertEqual(DailyProgress(of: [monday], on: DailyProgress.today(now: now, calendar: la)), DailyProgress(done: 1, due: 1))
        // In every zone a key names the same day.
        for calendar in zones {
            XCTAssertEqual(DailyProgress.state(of: stats(days, today: key(6, 9), calendar: calendar), on: key(6, 9)), .rest,
                           calendar.timeZone.identifier)
        }
    }

    // MARK: - The day's totals

    func testARestDayWithNothingDueIsNotPerfect() {
        let days = habit(.specificDays, activeDays: mwf, created: key(5, 1))
        let tuesday = DailyProgress(of: [stats(days, today: key(6, 2))], on: key(6, 2))
        XCTAssertEqual(tuesday.due, 0)
        XCTAssertEqual(tuesday.done, 0)
        XCTAssertEqual(tuesday.remaining, 0)
        XCTAssertFalse(tuesday.isPerfect, "nothing due is a rest day, not a perfect day")
        XCTAssertTrue(tuesday.isRestDay)
        XCTAssertEqual(tuesday.fraction, 0)
        // No habit at all: the same.
        XCTAssertEqual(DailyProgress(of: [], on: key(6, 2)), DailyProgress(done: 0, due: 0))
        XCTAssertFalse(DailyProgress(of: [], on: key(6, 2)).isPerfect)
        // A check-in on the rest day counts in done and due (D1): 1 of 1, never past 1.
        checkIn(days, on: [key(6, 2)])
        let done = DailyProgress(of: [stats(days, today: key(6, 2))], on: key(6, 2))
        XCTAssertEqual(done, DailyProgress(done: 1, due: 1))
        XCTAssertTrue(done.isPerfect)
        XCTAssertEqual(done.fraction, 1)
    }

    func testTheDaysTotalsOverTheParityFixture() {
        // D2's fixture on Thursday 4 June: a daily, a Mon/Wed/Fri (rests), a 3×/week met on
        // Wednesday, a count habit at target 0, a habit created today.
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            let daily = habit(created: key(5, 1))
            let days = habit(.specificDays, activeDays: mwf, created: key(5, 1))
            let tpw = habit(.timesPerWeek, timesPerWeek: 3, created: key(5, 1))
            checkIn(tpw, on: [key(6, 1), key(6, 2), key(6, 3)])
            let zero = habit(kind: .count, target: 0, created: key(5, 1))
            checkIn(zero, on: [key(6, 4)], value: 3)
            let new = habit(created: at(6, 4, 9, 0, in: calendar))
            func totals(_ day: Date) -> DailyProgress {
                DailyProgress(of: [daily, days, tpw, zero, new].map { stats($0, today: key(6, 4), calendar: calendar) }, on: day)
            }
            XCTAssertEqual([daily, days, tpw, zero, new].map { state($0, on: key(6, 4), calendar: calendar) },
                           [.due, .rest, .metForWeek, .due, .due], zone)
            XCTAssertEqual(totals(key(6, 4)), DailyProgress(done: 0, due: 3), zone)
            checkIn(daily, on: [key(6, 4)])
            checkIn(new, on: [key(6, 4)])
            let thursday = totals(key(6, 4))
            XCTAssertEqual(thursday, DailyProgress(done: 2, due: 3), zone)
            XCTAssertEqual(thursday.remaining, 1, "\(zone): the target-0 habit is still open")
            XCTAssertFalse(thursday.isPerfect, zone)
            XCTAssertEqual(thursday.fraction, 2.0 / 3.0, accuracy: 1e-9)
            // Wednesday: the new habit had not started, the Mon/Wed/Fri was due, the 3×/week done.
            XCTAssertEqual(totals(key(6, 3)), DailyProgress(done: 1, due: 4), zone)
        }
    }

    func testAPerfectDay() {
        let daily = habit(created: key(5, 1))
        let days = habit(.specificDays, activeDays: mwf, created: key(5, 1))
        checkIn(daily, on: [key(6, 1), key(6, 2)])
        checkIn(days, on: [key(6, 1)])
        let s = [stats(daily, today: key(6, 2)), stats(days, today: key(6, 2))]
        XCTAssertTrue(DailyProgress(of: s, on: key(6, 1)).isPerfect, "both due, both done")
        XCTAssertTrue(DailyProgress(of: s, on: key(6, 2)).isPerfect, "the rest day does not count against it")
        XCTAssertEqual(DailyProgress(of: s, on: key(6, 2)), DailyProgress(done: 1, due: 1))
        XCTAssertEqual(DailyProgress(states: [State.done, .due, .rest, .metForWeek, .notStarted]),
                       DailyProgress(done: 1, due: 2))
    }
}
