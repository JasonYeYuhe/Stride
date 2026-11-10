import XCTest
import Foundation

/// X2 (docs/X2-non-gregorian-day-keys.md, RELEASE-1.4.1.md W10): a day-key's year, month and day
/// are Gregorian whatever calendar the device uses (`HabitCalendar.dayCalendar`), at every place a
/// key is built — `dayKey(for:localCalendar:)`, `dayKey(forInstant:calendar:)`,
/// `WidgetTimelinePlan.dayKey(of:in:)`, `HistoryLink.target` — and the weekday and week math that
/// runs on keys is then the real one.
///
/// Every calendar a device can be set to (the 14 `calendars`) in six zones: Tokyo,
/// Los Angeles, UTC, London in winter (UTC+0, where a local midnight IS a UTC midnight), UTC+14
/// (Kiritimati) and UTC−11 (Pago Pago). Gregorian keys must come out byte for byte as before.
final class DayKeyCalendarTests: XCTestCase {
    static let zones = ["Asia/Tokyo", "America/Los_Angeles", "UTC", "Europe/London", "Pacific/Kiritimati",
                        "Pacific/Pago_Pago"]

    /// Every system calendar besides Gregorian and ISO 8601 (the report's 14; `DayKeyDecoder`
    /// tries the same list).
    static let calendars: [Calendar.Identifier] = [
        .japanese, .buddhist, .republicOfChina,
        .islamicUmmAlQura, .islamicCivil, .islamic, .islamicTabular,
        .hebrew, .persian, .indian, .coptic, .ethiopicAmeteMihret, .ethiopicAmeteAlem, .chinese,
    ]

    private func calendar(_ identifier: Calendar.Identifier, _ zone: String) -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func key(_ y: Int, _ m: Int, _ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// 1.4.0's `dayKey(forInstant:calendar:)`, line for line: the device calendar's Y/M/D.
    private func formulaBeforeX2(_ instant: Date, _ calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        return HabitCalendar.utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))
            ?? HabitCalendar.utc.startOfDay(for: instant)
    }

    /// Local dates and times worth keying: London's winter (UTC+0), both DST changes in the US and
    /// Europe, today in the report's experiments, a month end, a year end, a leap day, and Hebrew's
    /// Elul/Tishri collision days of 2025 and 2026.
    private let localTimes: [(y: Int, m: Int, d: Int, h: Int, min: Int)] = [
        (2026, 1, 10, 0, 0), (2026, 1, 10, 0, 30), (2026, 1, 10, 12, 0), (2026, 1, 10, 23, 59),
        (2026, 3, 8, 1, 30), (2026, 3, 8, 3, 30), (2026, 3, 29, 1, 30), (2026, 3, 29, 3, 0),
        (2026, 10, 15, 0, 1), (2026, 10, 15, 12, 0), (2026, 10, 15, 23, 59),
        (2026, 10, 25, 1, 30), (2026, 11, 1, 1, 30), (2026, 11, 30, 23, 0),
        (2026, 12, 31, 23, 59), (2027, 1, 1, 0, 0), (2028, 2, 29, 9, 0), (2028, 3, 1, 9, 0),
        (2025, 9, 22, 18, 0), (2025, 9, 23, 6, 0), (2026, 9, 11, 18, 0), (2026, 9, 12, 6, 0),
    ]

    // MARK: - Every calendar keys the real day

    /// The four build sites agree with each other and with the Gregorian date of the local day, in
    /// every calendar and zone: 0008-10-15, 2569-10-15, 5787-02-04 and the rest are never written.
    func testEveryCalendarKeysTheRealDayInEveryZone() throws {
        var checked = 0
        for zone in Self.zones {
            let gregorian = calendar(.gregorian, zone)
            for t in localTimes {
                guard let instant = gregorian.date(from: DateComponents(year: t.y, month: t.m, day: t.d, hour: t.h, minute: t.min))
                else { continue }
                // The local date of the instant (a DST gap moves 02:30 on, never to another day).
                let local = gregorian.dateComponents([.year, .month, .day], from: instant)
                let expected = key(local.year!, local.month!, local.day!)
                for identifier in Self.calendars + [.gregorian, .iso8601] {
                    let device = calendar(identifier, zone)
                    let what = "\(identifier) \(zone) \(t)"
                    XCTAssertEqual(HabitCalendar.dayKey(forInstant: instant, calendar: device), expected, what)
                    XCTAssertEqual(WidgetTimelinePlan.dayKey(of: instant, in: device), expected, what)
                    // The idempotent one returns an instant that is exactly a UTC midnight unchanged
                    // (its documented shortcut: in UTC−11, 13:00 is 00:00Z of the NEXT date). Apart
                    // from that it keys the same day, and in UTC+0 a local midnight is the key itself.
                    if !HabitCalendar.isDayKey(instant) || zone == "UTC" || zone == "Europe/London" {
                        XCTAssertEqual(HabitCalendar.dayKey(for: instant, localCalendar: device), expected, what)
                        XCTAssertEqual(HabitStats.dayNumber(of: instant, in: device), HabitStats.dayNumber(ofKey: expected), what)
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 2_000)
    }

    /// The day calendar: the device's own when it is Gregorian (so a Gregorian device's every key is
    /// computed exactly as before), else a Gregorian one in its zone.
    func testTheDayCalendarIsGregorianInTheDevicesZone() {
        var gregorian = calendar(.gregorian, "Asia/Tokyo")
        gregorian.firstWeekday = 2
        gregorian.locale = Locale(identifier: "ja_JP")
        XCTAssertEqual(HabitCalendar.dayCalendar(gregorian), gregorian, "a Gregorian calendar is used as it is")
        for identifier in Self.calendars + [.iso8601] {
            for zone in Self.zones {
                let device = calendar(identifier, zone)
                let day = HabitCalendar.dayCalendar(device)
                XCTAssertEqual(day.identifier, .gregorian, "\(identifier)")
                XCTAssertEqual(day.timeZone, device.timeZone, "\(identifier) \(zone)")
            }
        }
        XCTAssertTrue(HabitCalendar.wroteGregorianKeys(calendar(.gregorian, "UTC")))
        XCTAssertTrue(HabitCalendar.wroteGregorianKeys(calendar(.iso8601, "UTC")))
        for identifier in Self.calendars {
            XCTAssertFalse(HabitCalendar.wroteGregorianKeys(calendar(identifier, "UTC")), "\(identifier)")
        }
    }

    // MARK: - Gregorian keys are byte-identical

    /// Every hour of 2025 and 2026 in every zone: a Gregorian (or ISO 8601) device keys exactly
    /// what 1.4.0 keyed, as the same `yyyy-MM-dd` on the wire. (W1's parity goldens, which run in
    /// two zones, are unchanged too.)
    func testGregorianKeysAreByteIdenticalToBefore() throws {
        let start = key(2025, 1, 1).addingTimeInterval(-14 * 3_600)
        let hours = 2 * 366 * 24
        for zone in Self.zones {
            for identifier in [Calendar.Identifier.gregorian, .iso8601] {
                let device = calendar(identifier, zone)
                for h in 0..<hours {
                    let instant = start.addingTimeInterval(Double(h) * 3_600 + 1_234.5)
                    let before = formulaBeforeX2(instant, device)
                    let now = HabitCalendar.dayKey(forInstant: instant, calendar: device)
                    guard now == before,
                          WidgetTimelinePlan.dayKey(of: instant, in: device) == before,
                          HabitCalendar.dayKey(for: instant, localCalendar: device) == before,
                          HabitCalendar.dayStringFormatter.string(from: now) == HabitCalendar.dayStringFormatter.string(from: before)
                    else { return XCTFail("\(identifier) \(zone) \(instant): \(now) vs \(before)") }
                }
            }
        }
    }

    // MARK: - Weekdays and weeks are the real ones

    /// A Mon/Wed/Fri habit checked on every scheduled day for three weeks, keyed in each calendar
    /// and zone as the app keys a check-in: its key weekdays are the real Monday, Wednesday and
    /// Friday, the streak is all nine, the weekday chart counts three of each, each Monday week
    /// holds three, and the rest days are rest days. Before X2 a Japanese key's weekday was off by
    /// three or four, a Buddhist one's by two or three: the streak read 0 or 1.
    func testSpecificDaysAndMondayWeeksAreTheRealOnesInEveryCalendar() throws {
        for zone in Self.zones {
            let gregorian = calendar(.gregorian, zone)
            // Monday 2026-09-28 to Sunday 2026-10-18, at 20:00 local.
            let mondays = [(2026, 9, 28), (2026, 10, 5), (2026, 10, 12)]
            for identifier in Self.calendars + [.gregorian] {
                let device = calendar(identifier, zone)
                let what = "\(identifier) \(zone)"
                var records: [HabitRecord] = []
                var restDays: [Date] = []
                for (y, m, d) in mondays {
                    let monday = try XCTUnwrap(gregorian.date(from: DateComponents(year: y, month: m, day: d, hour: 20)))
                    for offset in 0..<7 {
                        let instant = try XCTUnwrap(gregorian.date(byAdding: .day, value: offset, to: monday))
                        if [0, 2, 4].contains(offset) {
                            let k = HabitCalendar.dayKey(forInstant: instant, calendar: device)
                            XCTAssertEqual(HabitStats.weekday(ofDay: HabitStats.dayNumber(ofKey: k)), [2, 4, 6][offset / 2], what)
                            XCTAssertEqual(HabitStats.monday(ofWeekContaining: HabitStats.dayNumber(ofKey: k)),
                                           HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: monday, calendar: device)), what)
                            records.append(HabitRecord(date: k))
                        } else {
                            restDays.append(instant)
                        }
                    }
                }
                let lastFriday = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 21)))
                let stats = HabitStats(records: records, live: .all, kind: .binary, targetValue: 1,
                                       schedule: .specificDays, timesPerWeek: 7, activeDaysMask: 0b0101010,
                                       createdAt: try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8))),
                                       calendar: device, today: lastFriday)
                XCTAssertEqual(stats.currentStreak(), 9, what)
                XCTAssertEqual(stats.bestStreak, 9, what)
                XCTAssertEqual(stats.completionsPerWeekday, [2: 3, 4: 3, 6: 3], what)
                XCTAssertEqual(stats.weeklyCompletions(containing: lastFriday), 3, what)
                XCTAssertEqual(stats.completionRate(from: records.first!.date, to: lastFriday), 1, accuracy: 1e-9, what)
                for rest in restDays where rest < lastFriday {
                    XCTAssertFalse(stats.isScheduled(on: rest), "\(what): \(rest) is a rest day")
                }
                XCTAssertTrue(stats.isScheduled(on: lastFriday), what)
            }
        }
    }

    // MARK: - The widget's plan

    /// A widget on a Japanese- or Buddhist-calendar phone describes today and tomorrow by their
    /// Gregorian keys, which are the keys the app writes.
    func testTheWidgetsPlanKeysTheRealDaysOnANonGregorianDevice() throws {
        for identifier in [Calendar.Identifier.japanese, .buddhist, .hebrew] {
            let device = calendar(identifier, "Asia/Tokyo")
            let now = try XCTUnwrap(calendar(.gregorian, "Asia/Tokyo").date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 21)))
            let plan = WidgetTimelinePlan(now: now, calendar: device, rows: [])
            XCTAssertEqual(plan.entries.map(\.dayKey), [key(2026, 10, 15), key(2026, 10, 16)], "\(identifier)")
            XCTAssertEqual(WidgetTimelinePlan.lastDayKey(now: now, calendar: device), key(2026, 10, 16), "\(identifier)")
        }
    }
}
