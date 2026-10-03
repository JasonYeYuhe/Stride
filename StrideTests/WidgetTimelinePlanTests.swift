import XCTest
import SwiftData
import Foundation

/// The widget's rollover: `[entry(now), entry(next local midnight)]`, policy `.after(midnight + 1 h)`.
///
/// Every instant here is built from an explicit zone and every expectation is a literal UTC
/// time, so the suite means the same thing on the developer's Mac (UTC+9), on CI (UTC) and
/// anywhere else. The zones are chosen for the ones those two machines cannot see: date bugs in
/// this app have shipped only in NEGATIVE offsets (HabitCalendar.dayKey's comment has the
/// history), where a local evening is already tomorrow in UTC.
@MainActor
final class WidgetTimelinePlanTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

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

    private func calendar(_ id: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: id)!
        return c
    }

    /// A wall-clock time in `cal`'s zone.
    private func local(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func key(_ y: Int, _ m: Int, _ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func plan(_ now: Date, _ cal: Calendar, _ rows: [WidgetTimelinePlan.RowInput] = []) -> WidgetTimelinePlan {
        WidgetTimelinePlan(now: now, calendar: cal, rows: rows)
    }

    private func assertShape(_ p: WidgetTimelinePlan, now: Date, midnight: String, today: Date, tomorrow: Date,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.entries.map(\.date), [now, utc(midnight)], "entry dates", file: file, line: line)
        XCTAssertEqual(p.entries.map(\.dayKey), [today, tomorrow], "habit-days", file: file, line: line)
        XCTAssertEqual(p.midnight, utc(midnight), file: file, line: line)
        XCTAssertEqual(p.refreshAfter, utc(midnight).addingTimeInterval(3600), "policy .after(midnight + 1 h)", file: file, line: line)
    }

    // MARK: - America/New_York, 2026-11-01: DST ends, a 25-hour day

    func testNewYorkEveningBeforeFallBackRollsOverAtEDTMidnight() {
        let ny = calendar("America/New_York")
        let now = local(ny, 2026, 10, 31, 23, 30)                  // 03:30Z on Nov 1, still EDT
        assertShape(plan(now, ny), now: now, midnight: "2026-11-01T04:00:00Z",
                    today: key(2026, 10, 31), tomorrow: key(2026, 11, 1))
    }

    /// Noon on the 25-hour day. Its midnight is 25 h after its start, so "start of today + 24 h"
    /// would roll over at 23:00 EST on Nov 1 — an hour early, drawing tomorrow's empty rows
    /// over the last hour of today.
    func testNewYorkOnTheTwentyFiveHourDayRollsOverAtESTMidnight() {
        let ny = calendar("America/New_York")
        let now = local(ny, 2026, 11, 1, 12)                       // 17:00Z, EST
        let p = plan(now, ny)
        assertShape(p, now: now, midnight: "2026-11-02T05:00:00Z",
                    today: key(2026, 11, 1), tomorrow: key(2026, 11, 2))
        XCTAssertNotEqual(p.midnight, ny.startOfDay(for: now).addingTimeInterval(24 * 3600))
        XCTAssertEqual(p.midnight.timeIntervalSince(ny.startOfDay(for: now)), 25 * 3600)
    }

    /// 01:30 happens twice on Nov 1. Both are the same habit-day with the same midnight.
    func testNewYorkRepeatedHourBothPassesShareOneMidnight() {
        let ny = calendar("America/New_York")
        let firstPass = utc("2026-11-01T05:30:00Z")               // 01:30 EDT
        let secondPass = utc("2026-11-01T06:30:00Z")              // 01:30 EST
        XCTAssertEqual(ny.component(.hour, from: firstPass), 1)
        XCTAssertEqual(ny.component(.hour, from: secondPass), 1)
        for now in [firstPass, secondPass] {
            assertShape(plan(now, ny), now: now, midnight: "2026-11-02T05:00:00Z",
                        today: key(2026, 11, 1), tomorrow: key(2026, 11, 2))
        }
    }

    /// The 23-hour day in March, for symmetry.
    func testNewYorkSpringForwardDay() {
        let ny = calendar("America/New_York")
        let now = local(ny, 2026, 3, 8, 12)
        assertShape(plan(now, ny), now: now, midnight: "2026-03-09T04:00:00Z",
                    today: key(2026, 3, 8), tomorrow: key(2026, 3, 9))
    }

    // MARK: - Negative offsets beyond DST

    /// 22:30 in São Paulo (UTC-3) is already 01:30 TOMORROW in UTC. Any UTC reading of "now"
    /// puts the first entry on the wrong day; this is the whole class of bug this app has shipped.
    func testSaoPauloLateEveningStaysOnTheLocalDay() {
        let sp = calendar("America/Sao_Paulo")
        let now = local(sp, 2026, 9, 27, 22, 30)
        XCTAssertEqual(HabitCalendar.utc.component(.day, from: now), 28, "precondition: UTC is already the 28th")
        assertShape(plan(now, sp), now: now, midnight: "2026-09-28T03:00:00Z",
                    today: key(2026, 9, 27), tomorrow: key(2026, 9, 28))
    }

    /// Brazil's DST began AT midnight until 2019: on 2018-11-04 local time jumped from 23:59:59
    /// to 01:00, so that day had no 00:00. Its first instant is 01:00 -02 = 03:00Z.
    func testSaoPauloDayWithNoMidnightRollsOverAtOneAM() {
        let sp = calendar("America/Sao_Paulo")
        let now = local(sp, 2018, 11, 3, 23)
        let p = plan(now, sp)
        assertShape(p, now: now, midnight: "2018-11-04T03:00:00Z",
                    today: key(2018, 11, 3), tomorrow: key(2018, 11, 4))
        XCTAssertEqual(sp.component(.hour, from: p.midnight), 1)
    }

    /// 20:00:00 in New York in summer IS 00:00:00Z the next day, so `HabitCalendar.dayKey`'s
    /// idempotency shortcut reads it as an existing key — tomorrow's. The plan must not.
    func testInstantOnAUTCMidnightIsKeyedByItsLocalDay() {
        let ny = calendar("America/New_York")
        let now = local(ny, 2026, 7, 1, 20)
        XCTAssertEqual(now, utc("2026-07-02T00:00:00Z"))
        XCTAssertEqual(HabitCalendar.dayKey(for: now, localCalendar: ny), key(2026, 7, 2),
                       "documents why the plan keys days itself")
        assertShape(plan(now, ny), now: now, midnight: "2026-07-02T04:00:00Z",
                    today: key(2026, 7, 1), tomorrow: key(2026, 7, 2))
    }

    // MARK: - Positive offsets

    /// 08:30 in Tokyo is still YESTERDAY in UTC — the mirror image of São Paulo.
    func testTokyoMorningStaysOnTheLocalDay() {
        let tokyo = calendar("Asia/Tokyo")
        let now = local(tokyo, 2026, 9, 27, 8, 30)
        XCTAssertEqual(HabitCalendar.utc.component(.day, from: now), 26, "precondition: UTC is still the 26th")
        assertShape(plan(now, tokyo), now: now, midnight: "2026-09-27T15:00:00Z",
                    today: key(2026, 9, 27), tomorrow: key(2026, 9, 28))
    }

    /// Samoa skipped 2011-12-30 entirely. The next midnight after the 29th is the 31st's.
    func testApiaSkippedDayRollsStraightToTheThirtyFirst() {
        let apia = calendar("Pacific/Apia")
        let now = local(apia, 2011, 12, 29, 12)
        assertShape(plan(now, apia), now: now, midnight: "2011-12-30T10:00:00Z",
                    today: key(2011, 12, 29), tomorrow: key(2011, 12, 31))
    }

    // MARK: - Invariants across DST weeks

    /// Every 20 minutes through the DST weeks of 2026 in a spread of zones: the midnight entry is
    /// later than now, at most one (possibly 25-hour) day away, the first instant of its day, and
    /// on the next habit-day.
    func testMidnightInvariantsAcrossDSTWeeks() {
        let zones = ["America/New_York", "America/Sao_Paulo", "America/Havana", "America/Santiago",
                     "Europe/London", "Asia/Tokyo", "Australia/Lord_Howe", "Pacific/Chatham", "UTC"]
        let windows: [(String, String)] = [("2026-03-06T00:00:00Z", "2026-03-10T00:00:00Z"),
                                           ("2026-03-27T00:00:00Z", "2026-04-07T00:00:00Z"),
                                           ("2026-09-03T00:00:00Z", "2026-09-08T00:00:00Z"),
                                           ("2026-09-25T00:00:00Z", "2026-09-29T00:00:00Z"),
                                           ("2026-10-23T00:00:00Z", "2026-11-03T00:00:00Z")]
        for id in zones {
            let cal = calendar(id)
            for (from, to) in windows {
                var now = utc(from)
                let end = utc(to)
                while now < end {
                    let p = plan(now, cal)
                    let gap = p.midnight.timeIntervalSince(now)
                    XCTAssertGreaterThan(gap, 0, "\(id) \(now)")
                    XCTAssertLessThanOrEqual(gap, 25 * 3600, "\(id) \(now)")
                    XCTAssertEqual(cal.startOfDay(for: p.midnight), p.midnight, "\(id) \(now)")
                    XCTAssertEqual(p.entries[1].dayKey,
                                   HabitCalendar.utc.date(byAdding: .day, value: 1, to: p.entries[0].dayKey),
                                   "\(id) \(now)")
                    XCTAssertTrue(HabitCalendar.isDayKey(p.entries[0].dayKey) && HabitCalendar.isDayKey(p.entries[1].dayKey))
                    now = now.addingTimeInterval(20 * 60)
                }
            }
        }
    }

    // MARK: - Rows: completion and streak as of each entry's day

    private func binaryHabit(_ name: String, doneOn keys: [Date]) throws -> Habit {
        let habit = Habit(name: name)
        context.insert(habit)
        for k in keys { habit.records.append(HabitRecord(date: k)) }
        try context.save()
        return habit
    }

    /// Late evening in São Paulo, when UTC is already on the next day. Today's entry shows today;
    /// the midnight entry shows tomorrow: nothing done yet, a streak that survives only if
    /// today was done.
    func testMidnightEntryUsesTomorrowsCompletionAndStreak() throws {
        let sp = calendar("America/Sao_Paulo")
        let now = local(sp, 2026, 9, 27, 22, 30)
        let today = key(2026, 9, 27), yesterday = key(2026, 9, 26)

        let kept = try binaryHabit("Meditate", doneOn: [yesterday, today])
        let lapsing = try binaryHabit("Read", doneOn: [key(2026, 9, 25), yesterday])

        let water = Habit(name: "Drink Water")
        water.kind = HabitKind.count.rawValue
        water.targetValue = 8
        context.insert(water)
        water.records.append(HabitRecord(date: today, value: 6))

        let run = try binaryHabit("Run", doneOn: [])
        run.scheduleKind = HabitSchedule.timesPerWeek.rawValue
        run.timesPerWeek = 1
        run.records.append(HabitRecord(date: key(2026, 9, 16)))   // last week (Mon 9/14 – Sun 9/20)
        run.records.append(HabitRecord(date: key(2026, 9, 24)))   // this week (Mon 9/21 – Sun 9/27)
        try context.save()

        let p = plan(now, sp, [kept, lapsing, water, run].map(WidgetTimelinePlan.RowInput.init))
        let (atNow, atMidnight) = (p.entries[0], p.entries[1])

        XCTAssertEqual(atNow.rows.map(\.isCompleted), [true, false, false, false])
        XCTAssertEqual(atNow.rows.map(\.streak), [2, 2, 0, 2])
        XCTAssertEqual(atNow.rows.map(\.progress), [1, 0, 0.75, 0])
        XCTAssertEqual(atNow.completedCount, 1)
        XCTAssertEqual(atNow.totalCount, 4)

        // Monday 9/28: nothing logged yet. "Meditate" keeps its 2 (today was done — the streak's
        // grace day); "Read" missed the 27th and drops to 0; the count habit starts over at 0/8;
        // "Run" is in a new week, so this week's not-yet-met goal does not break its 2 weeks.
        XCTAssertEqual(atMidnight.rows.map(\.isCompleted), [false, false, false, false])
        XCTAssertEqual(atMidnight.rows.map(\.streak), [2, 0, 0, 2])
        XCTAssertEqual(atMidnight.rows.map(\.progress), [0, 0, 0, 0])
        XCTAssertEqual(atMidnight.completedCount, 0)

        XCTAssertEqual(atNow.rows.map(\.isCount), [false, false, true, false])
        XCTAssertEqual(atNow.rows.map(\.streakInWeeks), [false, false, false, true])
        XCTAssertEqual(atNow.rows.map(\.habitId), [kept, lapsing, water, run].map(\.id.uuidString),
                       "row identity is the habit's id in both entries (VoiceOver focus survives reloads)")
        XCTAssertEqual(atMidnight.rows.map(\.id), atNow.rows.map(\.id))
    }

    /// The status function is always asked with a day-key — the property that makes `Habit`'s
    /// answers independent of the machine's zone.
    func testStatusIsAskedWithDayKeysOnly() {
        var asked: [Date] = []
        let input = WidgetTimelinePlan.RowInput(habitId: "h", name: "n", emoji: "e", colorHex: "#000000",
                                                isCount: false, streakInWeeks: false,
                                                status: { day in
                                                    asked.append(day)
                                                    return .init(isCompleted: false, progress: 3, streak: 0)
                                                })
        let ny = calendar("America/New_York")
        let p = plan(local(ny, 2026, 11, 1, 1, 30), ny, [input])
        XCTAssertEqual(asked, [key(2026, 11, 1), key(2026, 11, 2)])
        XCTAssertEqual(p.entries[0].rows[0].progress, 1, "progress is clamped to 0...1")
    }

    /// Same store, same instant, same zone — different machine zone. The answers must not move.
    func testResultDoesNotDependOnTheMachineTimeZone() throws {
        let sp = calendar("America/Sao_Paulo")
        let now = local(sp, 2026, 9, 27, 22, 30)
        let habit = try binaryHabit("Meditate", doneOn: [key(2026, 9, 26), key(2026, 9, 27)])
        // Weekends only (Sun = bit 0, Sat = bit 6): the weekday path is where re-keying in the
        // machine's zone used to shift every day back by one in the Americas.
        habit.scheduleKind = HabitSchedule.specificDays.rawValue
        habit.activeDaysMask = 0b1000001
        try context.save()

        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }

        var results: [[WidgetTimelinePlan.Entry]] = []
        for machineZone in ["Asia/Tokyo", "Europe/London", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            NSTimeZone.default = TimeZone(identifier: machineZone)!
            XCTAssertEqual(Calendar.current.timeZone.identifier, machineZone, "precondition: the machine zone moved")
            results.append(plan(now, sp, [.init(habit)]).entries)
        }
        for r in results.dropFirst() { XCTAssertEqual(r, results[0]) }
        XCTAssertEqual(results[0].map { $0.rows[0].isCompleted }, [true, false])
        XCTAssertEqual(results[0].map { $0.rows[0].streak }, [2, 2])
    }

    // MARK: - "+N more"

    private func visible(_ total: Int, _ capacity: Int) -> [Int] {
        let v = WidgetTimelinePlan.visibleRows(total: total, capacity: capacity)
        return [v.shown, v.more]
    }

    func testOverflowLineReplacesTheLastRow() {
        XCTAssertEqual(visible(0, 8), [0, 0])
        XCTAssertEqual(visible(5, 8), [5, 0])
        XCTAssertEqual(visible(8, 8), [8, 0], "eight fit: no summary line")
        XCTAssertEqual(visible(9, 8), [7, 2], "never nine lines in eight slots")
        XCTAssertEqual(visible(17, 16), [15, 2])
        XCTAssertEqual(visible(3, 0), [0, 3])
    }
}
