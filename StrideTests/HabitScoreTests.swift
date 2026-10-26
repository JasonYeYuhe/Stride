import XCTest
import SwiftData
import Foundation

/// `HabitScore` (RELEASE-1.4.1.md D9): the strength walk, its reference values, its today rule
/// (O1) and its inputs per kind and schedule.
///
/// The reference values are the plan's, recomputed independently (2026-10-14): 30 perfect daily
/// days 0.798, 100 days 0.995, one miss after 60 days −4.98 points, and the demo seed's patterns
/// (server/seed-demo.js `completionPatterns`, which ops/demo-topup.js keeps filling): Read 30
/// Minutes 0.716 and Journal 0.711 on seed day (30 days), 0.890 and 0.883 after 90 days of the
/// same patterns. Days are fixed UTC day-keys counted from Monday 2026-01-05, so nothing here
/// depends on the zone or the day the tests run.
@MainActor
final class HabitScoreTests: XCTestCase {

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

    /// Day `n` after Monday 2026-01-05.
    private func d(_ n: Int) -> Date {
        utc.date(byAdding: .day, value: n, to: utc.date(from: DateComponents(year: 2026, month: 1, day: 5))!)!
    }

    private let monWedFriMask = (1 << 1) | (1 << 3) | (1 << 5)   // bit 0 = Sunday

    /// A habit created at noon UTC on day `created`.
    private func habit(_ schedule: HabitSchedule = .daily, kind: HabitKind = .binary, target: Double = 1,
                       timesPerWeek: Int = 7, mask: Int = 127, created: Int = 0) -> Habit {
        let h = Habit(name: "Habit")
        h.schedule = schedule
        h.habitKind = kind
        h.targetValue = target
        h.timesPerWeek = timesPerWeek
        h.activeDaysMask = mask
        h.createdAt = d(created).addingTimeInterval(12 * 3600)
        context.insert(h)
        return h
    }

    private func checkIn(_ h: Habit, days: [Int], value: Double = 1) {
        for n in days { h.records.append(HabitRecord(date: d(n), value: value)) }
    }

    private func stats(_ h: Habit, today: Int) -> HabitStats {
        HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context), calendar: utc, today: d(today))
    }

    /// Mon, Wed and Fri of `weeks` weeks from day 0 (a Monday).
    private func monWedFri(weeks: Int) -> [Int] {
        (0..<weeks).flatMap { w in [0, 2, 4].map { 7 * w + $0 } }
    }

    private let m = pow(0.5, 1.0 / 13)   // the daily decay

    // MARK: - The formula

    func testDecayFollowsTheFrequency() {
        XCTAssertEqual(HabitScore.frequency(schedule: .daily, timesPerWeek: 7, activeDaysMask: 127), 1)
        XCTAssertEqual(HabitScore.frequency(schedule: .specificDays, timesPerWeek: 7, activeDaysMask: monWedFriMask), 3.0 / 7.0)
        XCTAssertEqual(HabitScore.frequency(schedule: .timesPerWeek, timesPerWeek: 3, activeDaysMask: 127), 3.0 / 7.0)
        XCTAssertEqual(HabitScore.decay(frequency: 1), 0.948_077_514, accuracy: 1e-9)
        XCTAssertEqual(HabitScore.decay(frequency: 3.0 / 7.0), pow(0.5, (3.0 / 7.0).squareRoot() / 13), accuracy: 1e-15)
        XCTAssertEqual(HabitScore.step(previous: 0.4, input: nil, decay: 0.9), 0.4, "a neutral day changes nothing")
        XCTAssertEqual(HabitScore.step(previous: 0.4, input: 1, decay: 0.9), 0.46, accuracy: 1e-15)
    }

    func testDisplayValueIsZeroToOneHundredRounded() {
        XCTAssertEqual(HabitScore.displayValue(0.798), 80)
        XCTAssertEqual(HabitScore.displayValue(0.716), 72)
        XCTAssertEqual(HabitScore.displayValue(0.7149), 71)
        XCTAssertEqual(HabitScore.displayValue(0), 0)
        XCTAssertEqual(HabitScore.displayValue(-0.2), 0)
        XCTAssertEqual(HabitScore.displayValue(1.3), 100)
    }

    // MARK: - Reference values (D9)

    func testThirtyPerfectDaysScore0798() {
        let h = habit()
        checkIn(h, days: Array(0...29))
        let s = stats(h, today: 29)
        XCTAssertEqual(s.strength, 0.798, accuracy: 0.0005)
        XCTAssertEqual(s.strength, 1 - pow(m, 30), accuracy: 1e-12)
        XCTAssertEqual(HabitScore.displayValue(s.strength), 80)
    }

    func testOneHundredPerfectDaysScore0995() {
        let h = habit()
        checkIn(h, days: Array(0...99))
        XCTAssertEqual(stats(h, today: 99).strength, 0.995, accuracy: 0.0005)
    }

    /// 60 perfect days, then a miss: −4.98 points (the next day, once the missed day is past).
    func testOneMissAfterSixtyDaysCostsFivePoints() {
        let h = habit()
        checkIn(h, days: Array(0...59))
        let s = stats(h, today: 61)   // day 60 missed; day 61 (today) not done yet
        let before = s.strengthSeries.score(on: d(59)), after = s.strengthSeries.score(on: d(60))
        XCTAssertEqual((before - after) * 100, 4.98, accuracy: 0.005)
        XCTAssertEqual(s.strength, after, "today, unfinished, is not applied")
        XCTAssertLessThan((before - after) * 100, 6, "the spec's bound: one miss dents less than 6 points")
    }

    /// The demo account's two weakest 30-day patterns, as seed-demo.js writes them: created 45
    /// days back, the pattern's last day is today (checked).
    func testTheDemoSeedPatternsAfterThirtyDays() {
        XCTAssertEqual(seedStrength(Self.read, days: 30), 0.716, accuracy: 0.0005)
        XCTAssertEqual(seedStrength(Self.journal, days: 30), 0.711, accuracy: 0.0005)
    }

    /// 90 days of the same patterns (the plan's demo account after D13's top-up): both clear
    /// gate 2's 0.75.
    func testTheDemoSeedPatternsAfterNinetyDays() {
        XCTAssertEqual(seedStrength(Self.read, days: 90), 0.890, accuracy: 0.0005)
        XCTAssertEqual(seedStrength(Self.journal, days: 90), 0.883, accuracy: 0.0005)
    }

    static let read = [1,1,1,1,1,0,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1]
    static let journal = [0,1,0,1,1,1,0,1,1,1,1,0,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1]

    /// `days` days of `pattern`, repeated, ending today with the pattern's last day; the habit was
    /// created before them.
    private func seedStrength(_ pattern: [Int], days: Int) -> Double {
        let today = 120
        let h = habit(created: today - days - 15)
        let first = today - (days - 1)
        checkIn(h, days: (0..<days).filter { pattern[$0 % 30] == 1 }.map { first + $0 })
        return stats(h, today: today).strength
    }

    // MARK: - Properties

    func testNoCheckInsScoreZero() {
        let h = habit()
        let s = stats(h, today: 40)
        XCTAssertEqual(s.strength, 0)
        XCTAssertEqual(s.strengthDelta30, 0)
        XCTAssertEqual(s.weeklyStrength, Array(repeating: 0, count: 8))
        XCTAssertTrue(s.strengthSeries.inputs.allSatisfy { $0 == 0 })

        let new = habit(created: 40)
        let fresh = stats(new, today: 40)
        XCTAssertEqual(fresh.strengthSeries.scores, [], "created today, nothing done: nothing to walk yet")
        XCTAssertEqual(fresh.strength, 0)
    }

    /// Over a long irregular history, for a yes/no and a count habit (with days over the target),
    /// every input and every score stays within 0…1.
    func testScoresStayWithinZeroAndOne() {
        var seed: UInt64 = 0x5EED
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let yesNo = habit()
        let count = habit(kind: .count, target: 8)
        for n in 0..<400 {
            if next() % 3 != 0 { yesNo.records.append(HabitRecord(date: d(n))) }
            let v = Double(next() % 14)
            if v > 0 { count.records.append(HabitRecord(date: d(n), value: v)) }
        }
        for h in [yesNo, count] {
            let series = stats(h, today: 399).strengthSeries
            XCTAssertGreaterThanOrEqual(series.scores.count, 399)
            XCTAssertTrue(series.scores.allSatisfy { (0...1).contains($0) })
            XCTAssertTrue(series.inputs.allSatisfy { ($0 ?? 0) >= 0 && ($0 ?? 0) <= 1 })
        }
    }

    /// After five misses, a month of check-ins brings it back up, every day.
    func testItRecoversAfterMisses() {
        let h = habit()
        checkIn(h, days: Array(0...59) + Array(65...94))
        let series = stats(h, today: 94).strengthSeries
        let peak = series.score(on: d(59)), low = series.score(on: d(64))
        XCTAssertLessThan(low, peak)
        let recovery = (65...94).map { series.score(on: d($0)) }
        XCTAssertTrue(zip(recovery, recovery.dropFirst()).allSatisfy { $1 > $0 }, "rises every day")
        XCTAssertGreaterThan(series.current, 0.94)
    }

    /// Mon/Wed/Fri: a rest day's input is neutral and leaves the score exactly as it was.
    func testRestDaysLeaveTheScoreUnchanged() {
        let h = habit(.specificDays, mask: monWedFriMask)
        checkIn(h, days: monWedFri(weeks: 4).filter { $0 != 9 })   // Wed of week 2 missed
        let series = stats(h, today: 27).strengthSeries
        for n in 1...26 {   // today (27, a Sunday) is not walked: nothing was done on it
            let weekday = utc.component(.weekday, from: d(n))
            guard ![2, 4, 6].contains(weekday) else { continue }
            XCTAssertNil(series.inputs[n], "day \(n) is a rest day")
            XCTAssertEqual(series.score(on: d(n)), series.score(on: d(n - 1)), "day \(n)")
        }
        XCTAssertEqual(series.inputs[9], 0, "a scheduled day missed")
        XCTAssertLessThan(series.score(on: d(9)), series.score(on: d(8)))
    }

    /// The same gap — a week without a check-in after 60 days of check-ins every day — costs a
    /// 3×/week habit far less than a daily one: its trailing week still meets the goal for most
    /// of the gap, and its decay is slower.
    func testThreeTimesAWeekDecaysSlowerThanDailyUnderTheSameMisses() {
        let daily = habit()
        let weekly = habit(.timesPerWeek, timesPerWeek: 3)
        for h in [daily, weekly] { checkIn(h, days: Array(0...59)) }
        let drop = [daily, weekly].map { h -> Double in
            let series = stats(h, today: 67).strengthSeries   // days 60…66 missed, today 67 not done
            return series.score(on: d(59)) - series.current
        }
        XCTAssertGreaterThan(drop[0], drop[1])
        XCTAssertGreaterThan(drop[1], 0, "the 3×/week habit does decay once its week falls short")
        XCTAssertGreaterThan(HabitScore.step(previous: 0.9, input: 0, decay: HabitScore.decay(frequency: 3.0 / 7.0)),
                             HabitScore.step(previous: 0.9, input: 0, decay: HabitScore.decay(frequency: 1)),
                             "one miss from the same score")
    }

    /// "3×/week, done Mon/Wed/Fri": the daily INPUT is 1.0 every day from the first Friday (its
    /// trailing 7 days always hold 3 check-ins) and the score rises every day — but an EMA from 0
    /// never reaches 1.0 (Spec corrections). The streak beside it counts calendar weeks; strength
    /// counts a rolling 7 days.
    func testMonWedFriOnAThreeTimesAWeekHabitHasInputOneAndAMonotonicScore() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, days: monWedFri(weeks: 8) + [56])   // today, Monday of week 9, checked
        let s = stats(h, today: 56)
        let series = s.strengthSeries

        XCTAssertEqual(series.lastDay, d(56), "today is complete, so it is applied")
        let third = 1.0 / 3.0, twoThirds = 2.0 / 3.0
        let firstWeek: [Double?] = [third, third, twoThirds, twoThirds]
        XCTAssertEqual(Array(series.inputs[0...3]), firstWeek, "the first week fills up")
        XCTAssertTrue(series.inputs[4...].allSatisfy { $0 == 1 }, "1.0 every day from the first Friday")
        XCTAssertTrue(zip(series.scores, series.scores.dropFirst()).allSatisfy { $1 > $0 }, "monotonic")
        XCTAssertLessThan(s.strength, 1)
        XCTAssertEqual(s.currentStreak(), 8, "the streak counts calendar weeks: 8 met, the 9th under way (grace)")
    }

    // MARK: - Today (O1)

    /// A count habit at 4 of 8 today holds yesterday's score; 8 of 8 raises it.
    func testACountHabitsPartialTodayHoldsYesterdaysScore() throws {
        let h = habit(kind: .count, target: 8)
        checkIn(h, days: Array(0...19), value: 8)
        checkIn(h, days: [20], value: 4)
        let yesterday = stats(h, today: 19).strength
        let partial = stats(h, today: 20)
        XCTAssertEqual(partial.strength, yesterday, "4/8 is not applied")
        XCTAssertEqual(partial.strengthSeries.lastDay, d(19))

        let today = try XCTUnwrap(h.records.first { $0.date == d(20) })
        today.value = 8
        let done = stats(h, today: 20)
        XCTAssertGreaterThan(done.strength, yesterday, "8/8 is")
        XCTAssertEqual(done.strengthSeries.lastDay, d(20))
    }

    /// A 3×/week habit not checked today holds the score at the end of yesterday — never the
    /// streak's in-progress-week grace — and decays the next day, once the missed Monday is past
    /// and its trailing week holds only two check-ins.
    func testAThreeTimesAWeekHabitUncheckedTodayHoldsYesterdayThenDecays() {
        let h = habit(.timesPerWeek, timesPerWeek: 3)
        checkIn(h, days: monWedFri(weeks: 6))       // through Fri day 39
        let monday = stats(h, today: 42)            // Monday of week 7, not checked
        XCTAssertEqual(monday.strengthSeries.lastDay, d(41))
        XCTAssertEqual(monday.strength, monday.strengthSeries.score(on: d(41)))
        XCTAssertEqual(monday.currentStreak(), 6, "the streak keeps its grace for the week")

        let tuesday = stats(h, today: 43)           // Monday was missed
        XCTAssertEqual(tuesday.strengthSeries.inputs.last ?? nil, 2.0 / 3.0)
        XCTAssertLessThan(tuesday.strength, monday.strength)
    }

    // MARK: - History edits (2026-10-15 decision 8)

    /// The habit's CURRENT target and schedule score its whole history: lowering a count goal
    /// from 8 to 5 turns 40 days of 5 into 40 completed days — strength, streak and rate alike.
    func testEditingTheTargetOrScheduleRescoresTheWholeHistory() {
        let h = habit(kind: .count, target: 8)
        checkIn(h, days: Array(0...39), value: 5)
        let before = stats(h, today: 39)
        XCTAssertEqual(before.strength, 0.625 * (1 - pow(m, 39)), accuracy: 1e-12, "today's 5/8 is not applied")
        XCTAssertEqual(before.currentStreak(), 0)
        XCTAssertEqual(before.completionRate(days: 30), 0)

        h.targetValue = 5
        let after = stats(h, today: 39)
        XCTAssertEqual(after.strength, 1 - pow(m, 40), accuracy: 1e-12)
        XCTAssertEqual(after.currentStreak(), 40)
        XCTAssertEqual(after.completionRate(days: 30), 1)

        h.schedule = .specificDays
        h.activeDaysMask = monWedFriMask
        let mwf = stats(h, today: 39)
        XCTAssertEqual(mwf.strengthSeries.inputs.compactMap { $0 }.count, 18, "only Mon/Wed/Fri are walked")
        XCTAssertEqual(mwf.currentStreak(), 18)
    }

    // MARK: - Deltas and weekly bars

    func testDeltasCompareWithTheScoreThatManyDaysBefore() {
        let h = habit()
        checkIn(h, days: Array(0...99))
        let s = stats(h, today: 99)
        XCTAssertEqual(s.strengthDelta30, pow(m, 70) - pow(m, 100), accuracy: 1e-12)
        XCTAssertEqual(s.strengthDelta90, pow(m, 10) - pow(m, 100), accuracy: 1e-12)

        let young = habit(created: 90)
        checkIn(young, days: Array(90...99))
        let y = stats(young, today: 99)
        XCTAssertEqual(y.strengthDelta30, y.strength, accuracy: 1e-15, "younger than 30 days: all of it is gain from 0")
    }

    func testWeeklyStrengthIsTheScoreAtEachWeeksEndOldestFirst() {
        let h = habit()
        checkIn(h, days: Array(0...100))
        let s = stats(h, today: 100)     // day 100 is the Wednesday of week 15
        let bars = s.weeklyStrength
        XCTAssertEqual(bars.count, 8)
        XCTAssertEqual(bars.last, s.strength, "this week's bar is today's score")
        XCTAssertEqual(bars[6], s.strengthSeries.score(on: d(97)), "last week's bar is its Sunday's")
        XCTAssertTrue(zip(bars, bars.dropFirst()).allSatisfy { $1 > $0 })
        XCTAssertEqual(s.strengthSeries.weekly(weeks: 20).count, 20)
        XCTAssertEqual(s.strengthSeries.weekly(weeks: 20).first, 0, "before the walk started")
    }
}
