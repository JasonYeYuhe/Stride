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

    /// Regression: `dayKey(for:)` must be a no-op on a value that is already a
    /// day-key. The streak/schedule math re-keys keys (isScheduled, weekStart,
    /// completionRate); before the fix that shifted the day — and therefore the
    /// weekday — back by one in every negative-UTC-offset zone, zeroing the
    /// streak of every "Specific days" habit in the Americas.
    ///
    /// Note the zone list: the original suite only ever exercised Asia/Tokyo and
    /// a *local instant* in Los Angeles, so it could not see this.
    func testDayKeyIsIdempotentInEveryOffsetSign() {
        let friday = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 4))!
        XCTAssertEqual(HabitCalendar.utc.component(.weekday, from: friday), 6, "sanity: 2026-09-04 is a Friday")

        for id in ["UTC", "Asia/Tokyo", "Europe/Berlin", "Pacific/Honolulu",
                   "America/Sao_Paulo", "America/New_York", "America/Los_Angeles"] {
            let cal = calendar(id)
            let reKeyed = HabitCalendar.dayKey(for: friday, localCalendar: cal)
            XCTAssertEqual(reKeyed, friday, "re-keying an existing day-key must not move it (\(id))")
            XCTAssertEqual(HabitCalendar.utc.component(.weekday, from: reKeyed), 6,
                           "weekday must survive the round trip (\(id))")
        }
    }

    /// A Mon/Wed/Fri habit evaluated on real day-keys, the way currentStreak()
    /// walks them. Before the fix each scheduled day reported false and Saturday
    /// reported true, so the streak loop broke immediately and returned 0.
    func testSpecificDaysScheduleIsCorrectOnDayKeys() {
        let h = Habit(name: "Gym")
        h.schedule = .specificDays
        h.activeDaysMask = (1 << 1) | (1 << 3) | (1 << 5) // Mon, Wed, Fri (bit 0 = Sunday)

        let expectations: [(month: Int, day: Int, scheduled: Bool)] = [
            (8, 31, true),  // Monday
            (9,  2, true),  // Wednesday
            (9,  4, true),  // Friday
            (9,  5, false), // Saturday — a rest day
            (9,  3, false), // Thursday — a rest day
        ]
        for e in expectations {
            let key = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: e.month, day: e.day))!
            XCTAssertEqual(h.isScheduled(on: key), e.scheduled,
                           "2026-\(e.month)-\(e.day) scheduled should be \(e.scheduled)")
        }
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
