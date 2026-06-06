import XCTest
import Foundation
import SwiftData

/// Regression tests for the UTC-anchored "day-key" model that prevents
/// check-ins from shifting to an adjacent day across time-zone / DST changes.
final class TimezoneTests: XCTestCase {

    private func calendar(_ id: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: id)!
        return c
    }

    func testDayKeyAnchorsToUTCMidnight() {
        let tokyo = calendar("Asia/Tokyo") // +09:00
        // Local midnight 2026-06-06 in Tokyo == 2026-06-05T15:00:00Z (not a UTC key).
        let localMidnight = tokyo.date(from: DateComponents(year: 2026, month: 6, day: 6))!
        let key = HabitCalendar.dayKey(for: localMidnight, localCalendar: tokyo)
        let expected = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 6, day: 6))!

        XCTAssertEqual(key, expected, "day-key must be UTC midnight of the local Y/M/D")
        XCTAssertTrue(HabitCalendar.isDayKey(key))
        XCTAssertFalse(HabitCalendar.isDayKey(localMidnight), "a non-UTC local midnight is not a day-key")
    }

    func testLateNightCheckInKeepsLocalDay() {
        let la = calendar("America/Los_Angeles") // -07:00 in June
        // 11:30pm on June 6 local — close to the boundary, easy to slip to June 7 in UTC.
        let lateNight = la.date(from: DateComponents(year: 2026, month: 6, day: 6, hour: 23, minute: 30))!
        let key = HabitCalendar.dayKey(for: lateNight, localCalendar: la)
        let expected = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 6, day: 6))!
        XCTAssertEqual(key, expected, "late-night local check-in must stay on the local calendar day")
    }

    func testHabitRecordIsAlwaysStoredAsDayKey() {
        // Whatever instant we pass, the stored date is a UTC-midnight day-key.
        for offset in [0, -1, -7, -30] {
            let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
            let record = HabitRecord(date: d)
            XCTAssertTrue(HabitCalendar.isDayKey(record.date),
                          "HabitRecord must normalize its date to a day-key (offset \(offset))")
        }
    }

    func testIsCompletedOnDistinguishesTodayFromYesterday() {
        let habit = Habit(name: "Test")
        habit.records.append(HabitRecord(date: Date()))
        XCTAssertTrue(habit.isCompletedOn(Date()))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        XCTAssertFalse(habit.isCompletedOn(yesterday))
    }

    func testMigrationConversionIsIdempotent() {
        let tokyo = calendar("Asia/Tokyo")
        // Simulate a legacy record: local midnight stored verbatim (15:00Z prior day).
        let legacy = tokyo.date(from: DateComponents(year: 2026, month: 6, day: 6))!
        XCTAssertFalse(HabitCalendar.isDayKey(legacy))

        let once = HabitCalendar.dayKey(for: legacy, localCalendar: tokyo)
        XCTAssertTrue(HabitCalendar.isDayKey(once), "after migration the date is a day-key")
        XCTAssertEqual(once, HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 6, day: 6))!)

        // A second migration pass must skip it (idempotent), leaving it unchanged.
        XCTAssertTrue(HabitCalendar.isDayKey(once))
        XCTAssertEqual(HabitCalendar.startOfKey(once), once)
    }

    func testStreakUsesStableDayKeys() {
        let habit = Habit(name: "Streak")
        let cal = Calendar.current
        for offset in 0...4 {
            let d = cal.date(byAdding: .day, value: -offset, to: Date())!
            habit.records.append(HabitRecord(date: d))
        }
        XCTAssertEqual(habit.currentStreak(), 5, "five consecutive days = streak of 5")
    }
}
