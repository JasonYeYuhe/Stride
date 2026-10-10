import XCTest
import Foundation

/// Which day a reminder's Mark Done or Add 1 credits (`ReminderDay.resolve`, Shared/ReminderPlan.swift)
/// and the non-idempotent key it is built with (`HabitCalendar.dayKey(forInstant:)`,
/// Shared/DateHelpers.swift). RELEASE-1.4.0.md D4.
///
/// The zones are pinned with explicit calendars, never the machine's: the blocker this guards
/// (a 20:00 reminder in US Eastern daylight time crediting tomorrow) cannot happen at UTC+9, where
/// this app is built and its suite usually runs.
final class ReminderDayTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private let newYork = "America/New_York"
    private let losAngeles = "America/Los_Angeles"
    private let tokyo = "Asia/Tokyo"

    /// A day-key: that date's midnight in UTC.
    private func key(_ year: Int, _ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A wall-clock time in `zone`.
    private func at(_ zone: String, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func utcMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date { key(year, month, day) }

    private func resolve(_ zone: String, delivered: Date, responded: Date,
                         day: String? = nil) -> Date {
        var info: [AnyHashable: Any] = [NotificationRouter.UserInfoKey.habitID: UUID().uuidString]
        if let day { info[NotificationRouter.UserInfoKey.day] = day }
        return ReminderDay.resolve(userInfo: info, deliveredAt: delivered, respondedAt: responded,
                                   calendar: calendar(zone))
    }

    // MARK: - dayKey(forInstant:)

    /// The design review's blocker. 20:00 EDT on 15 July is exactly 2026-07-16T00:00:00Z. Read as
    /// a key it is the 16th — tomorrow; read as an instant it is the 15th, the day it was.
    func testTwentyHundredEasternDaylightIsTheSameDay() {
        let fired = at(newYork, 2026, 7, 15, 20)
        XCTAssertEqual(fired, utcMidnight(2026, 7, 16), "the trap: a whole-minute fire time that is a UTC midnight")
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: fired, calendar: calendar(newYork)), key(2026, 7, 15))
    }

    func testNineteenHundredEasternStandardIsTheSameDay() {
        let fired = at(newYork, 2026, 1, 15, 19)
        XCTAssertEqual(fired, utcMidnight(2026, 1, 16))
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: fired, calendar: calendar(newYork)), key(2026, 1, 15))
    }

    func testSixteenHundredPacificStandardIsTheSameDay() {
        let fired = at(losAngeles, 2026, 1, 15, 16)
        XCTAssertEqual(fired, utcMidnight(2026, 1, 16))
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: fired, calendar: calendar(losAngeles)), key(2026, 1, 15))
    }

    /// A positive offset, the control: 09:00 JST is the same date's key either way, which is why
    /// nothing here could be seen from Japan.
    func testTokyoIsTheSameDayEitherWay() {
        let fired = at(tokyo, 2026, 1, 16, 9)
        XCTAssertEqual(fired, utcMidnight(2026, 1, 16))
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: fired, calendar: calendar(tokyo)), key(2026, 1, 16))
        XCTAssertEqual(HabitCalendar.dayKey(for: fired, localCalendar: calendar(tokyo)), key(2026, 1, 16))
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: at(tokyo, 2026, 1, 16, 23, 59), calendar: calendar(tokyo)),
                       key(2026, 1, 16))
    }

    /// `dayKey(for:)` keeps its idempotence — `isScheduled`, `weekStart` and the streak math hand it
    /// keys — so the UTC-midnight instant still comes back unchanged from it. That is exactly why
    /// a system date must never go through it, and why the new function exists beside it rather
    /// than replacing it.
    func testDayKeyForIsUnchanged() {
        let ny = calendar(newYork)
        XCTAssertEqual(HabitCalendar.dayKey(for: utcMidnight(2026, 7, 16), localCalendar: ny), key(2026, 7, 16),
                       "a key is returned as it is")
        XCTAssertEqual(HabitCalendar.dayKey(for: key(2026, 7, 15), localCalendar: ny), key(2026, 7, 15))
        XCTAssertEqual(HabitCalendar.dayKey(for: at(newYork, 2026, 7, 15, 23, 30), localCalendar: ny), key(2026, 7, 15))
        XCTAssertEqual(HabitCalendar.dayKey(for: at(newYork, 2026, 7, 15, 0, 30), localCalendar: ny), key(2026, 7, 15))
    }

    // MARK: - ReminderDay.resolve

    /// The default 20:00 reminder in New York, acted on at once: the 15th, not the 16th.
    func testAnImmediateActionCreditsTheDayItFired() {
        let delivered = at(newYork, 2026, 7, 15, 20)
        XCTAssertEqual(resolve(newYork, delivered: delivered, responded: delivered.addingTimeInterval(20)), key(2026, 7, 15))
        let winter = at(newYork, 2026, 1, 15, 19)
        XCTAssertEqual(resolve(newYork, delivered: winter, responded: winter.addingTimeInterval(20)), key(2026, 1, 15))
        let pacific = at(losAngeles, 2026, 1, 15, 16)
        XCTAssertEqual(resolve(losAngeles, delivered: pacific, responded: pacific.addingTimeInterval(20)), key(2026, 1, 15))
        let japan = at(tokyo, 2026, 1, 16, 9)
        XCTAssertEqual(resolve(tokyo, delivered: japan, responded: japan.addingTimeInterval(20)), key(2026, 1, 16))
    }

    /// A 23:30 reminder snoozed: the snooze banner arrives at 00:30 the next day and carries the
    /// day it was for, which wins over everything — at 00:31, next morning, or after a second
    /// snooze. Its own delivery date would have credited the 14th (Gemini's finding,
    /// "snooze-credits-next-day").
    func testASnoozeAcrossMidnightCreditsTheDayItCarries() {
        let snoozeBanner = at(newYork, 2026, 7, 14, 0, 30)
        XCTAssertEqual(resolve(newYork, delivered: snoozeBanner, responded: at(newYork, 2026, 7, 14, 0, 31),
                               day: "2026-07-13"), key(2026, 7, 13))
        XCTAssertEqual(resolve(newYork, delivered: snoozeBanner, responded: at(newYork, 2026, 7, 14, 9),
                               day: "2026-07-13"), key(2026, 7, 13), "carried, not the grace rule")
        XCTAssertEqual(resolve(newYork, delivered: at(newYork, 2026, 7, 14, 1, 30), responded: at(newYork, 2026, 7, 14, 1, 31),
                               day: "2026-07-13"), key(2026, 7, 13), "a snooze of a snooze")
    }

    /// A malformed carried day falls back to the delivered day; it is never written as is.
    func testAMalformedCarriedDayFallsBack() {
        let delivered = at(newYork, 2026, 7, 15, 20)
        for bad in ["2026-02-30", "2026-7-15", "yesterday", ""] {
            XCTAssertEqual(resolve(newYork, delivered: delivered, responded: delivered.addingTimeInterval(60), day: bad),
                           key(2026, 7, 15), bad)
        }
    }

    /// Last night's banner ticked off just after midnight means the day that just ended — up to
    /// three hours after midnight, then today.
    func testANextMorningActionWithinThreeHoursCreditsYesterday() {
        let lastNight = at(newYork, 2026, 7, 13, 20)
        XCTAssertEqual(resolve(newYork, delivered: lastNight, responded: at(newYork, 2026, 7, 14, 0, 5)), key(2026, 7, 13))
        XCTAssertEqual(resolve(newYork, delivered: lastNight, responded: at(newYork, 2026, 7, 14, 2, 59)), key(2026, 7, 13))
        XCTAssertEqual(resolve(newYork, delivered: lastNight, responded: at(newYork, 2026, 7, 14, 3)), key(2026, 7, 14),
                       "from 03:00 it is today")
        XCTAssertEqual(resolve(newYork, delivered: lastNight, responded: at(newYork, 2026, 7, 14, 7, 30)), key(2026, 7, 14))
    }

    /// A weekday banner stays delivered for a week. Monday's, acted on on Thursday, credits
    /// Thursday — the day the user is in — not Monday (design review, "action-credits-stale-day").
    func testThursdayOnMondaysBannerCreditsToday() {
        let monday = at(newYork, 2026, 7, 13, 20)
        XCTAssertEqual(calendar(newYork).component(.weekday, from: monday), 2, "the 13th is a Monday")
        XCTAssertEqual(resolve(newYork, delivered: monday, responded: at(newYork, 2026, 7, 16, 10)), key(2026, 7, 16))
        let tokyoMonday = at(tokyo, 2026, 7, 13, 20)
        XCTAssertEqual(resolve(tokyo, delivered: tokyoMonday, responded: at(tokyo, 2026, 7, 16, 10)), key(2026, 7, 16))
    }

    /// The grace is elapsed time: on the night clocks spring forward (New York, 8 March 2026,
    /// 02:00 → 03:00), 03:30 on the wall is only 2.5 h after midnight.
    func testTheGraceIsElapsedTimeAcrossADSTNight() {
        let saturday = at(newYork, 2026, 3, 7, 21)
        let wall0330 = at(newYork, 2026, 3, 8, 3, 30)
        XCTAssertEqual(wall0330.timeIntervalSince(calendar(newYork).startOfDay(for: wall0330)), 2.5 * 3_600)
        XCTAssertEqual(resolve(newYork, delivered: saturday, responded: wall0330), key(2026, 3, 7))
        XCTAssertEqual(resolve(newYork, delivered: saturday, responded: at(newYork, 2026, 3, 8, 4, 1)), key(2026, 3, 8))
    }

    /// Whatever the path, the answer is a day-key: what `HabitCheckIn` keys idempotently.
    func testTheResultIsAlwaysADayKey() {
        let delivered = at(losAngeles, 2026, 1, 15, 16)
        for responded in [delivered, at(losAngeles, 2026, 1, 16, 1), at(losAngeles, 2026, 1, 19, 12)] {
            XCTAssertTrue(HabitCalendar.isDayKey(resolve(losAngeles, delivered: delivered, responded: responded)))
        }
    }
}
