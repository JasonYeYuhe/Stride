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
    /// day it was for, which stands in for its own delivery date — that would have credited the
    /// 14th (Gemini's finding, "snooze-credits-next-day"). At 00:31, and after a second snooze at
    /// 01:31, it credits the 13th.
    func testASnoozeAcrossMidnightCreditsTheDayItCarries() {
        let snoozeBanner = at(newYork, 2026, 7, 14, 0, 30)
        XCTAssertEqual(resolve(newYork, delivered: snoozeBanner, responded: at(newYork, 2026, 7, 14, 0, 31),
                               day: "2026-07-13"), key(2026, 7, 13))
        XCTAssertEqual(resolve(newYork, delivered: at(newYork, 2026, 7, 14, 1, 30), responded: at(newYork, 2026, 7, 14, 1, 31),
                               day: "2026-07-13"), key(2026, 7, 13), "a snooze of a snooze")
        XCTAssertEqual(resolve(newYork, delivered: at(newYork, 2026, 7, 13, 21), responded: at(newYork, 2026, 7, 13, 21, 5),
                               day: "2026-07-13"), key(2026, 7, 13), "a snooze before midnight, carrying today")
    }

    /// The carried day is the banner's day, not a trump card: past the grace it is as stale as
    /// the reminder it came from. Snoozed at 23:45 on the 13th, left in Notification Center (a
    /// one-shot id nothing re-fires, and nothing withdraws it for a user who never opens the app),
    /// then tapped the next morning or four days later: today, never the 13th (W1 code review).
    /// The first cut credited the 13th at any age, checked it off on every device and left the
    /// day the user was actually in open.
    func testAStaleSnoozeCreditsToday() {
        let snoozeBanner = at(newYork, 2026, 7, 14, 0, 45)
        XCTAssertEqual(resolve(newYork, delivered: snoozeBanner, responded: at(newYork, 2026, 7, 14, 9),
                               day: "2026-07-13"), key(2026, 7, 14), "the next morning, like an original banner")
        XCTAssertEqual(resolve(newYork, delivered: snoozeBanner, responded: at(newYork, 2026, 7, 17, 10),
                               day: "2026-07-13"), key(2026, 7, 17), "four days later")
        XCTAssertEqual(resolve(newYork, delivered: snoozeBanner, responded: at(newYork, 2026, 7, 17, 0, 40),
                               day: "2026-07-13"), key(2026, 7, 17),
                       "inside the grace, but the 13th is not yesterday: today, not the 16th either")
    }

    /// A carried day ahead of the response — only a hand-made payload or a clock or zone change
    /// gets one, the range check alone lets 2099 through — is never credited: no check-in is
    /// written ahead of the clock.
    func testAFutureCarriedDayCreditsToday() {
        let delivered = at(newYork, 2026, 7, 15, 20)
        let responded = delivered.addingTimeInterval(60)
        for future in ["2026-07-16", "2099-12-31"] {
            XCTAssertEqual(resolve(newYork, delivered: delivered, responded: responded, day: future), key(2026, 7, 15), future)
        }
        // A zone change between the tap and the banner: snoozed at 09:00 on Tokyo's 16th, which
        // carries the 16th; an hour later the device is on Los Angeles time, where that instant
        // is 18:00 on the 15th. The 16th has not begun where the user now is.
        let la = at(losAngeles, 2026, 7, 15, 18)
        XCTAssertEqual(la, at(tokyo, 2026, 7, 16, 10), "the same instant")
        XCTAssertEqual(resolve(losAngeles, delivered: la, responded: la.addingTimeInterval(60), day: "2026-07-16"),
                       key(2026, 7, 15))
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

    /// The same banner tapped at 00:40 on Thursday, inside the late-night grace: Thursday. The
    /// grace credits the day that just ended only when the banner was FOR that day; the first cut
    /// credited Wednesday here, a day this Monday-only banner was never for (W1 code review).
    func testThursdayJustAfterMidnightOnMondaysBannerCreditsThursday() {
        let monday = at(newYork, 2026, 7, 13, 20)
        XCTAssertEqual(resolve(newYork, delivered: monday, responded: at(newYork, 2026, 7, 16, 0, 40)), key(2026, 7, 16))
        XCTAssertEqual(resolve(newYork, delivered: monday, responded: at(newYork, 2026, 7, 15, 0, 40)), key(2026, 7, 15),
                       "two days old: Wednesday itself, not Tuesday")
        XCTAssertEqual(resolve(newYork, delivered: monday, responded: at(newYork, 2026, 7, 14, 0, 40)), key(2026, 7, 13),
                       "one day old, inside the grace: Monday, the day it was for")
    }

    /// The invariant both fixes restore: whatever the times and whatever a snooze carries, the
    /// credit is the banner's day or today — never a third day. Swept hour by hour over a week of
    /// responses, for an original banner and for snoozes carrying each day around it, in a
    /// negative and a positive offset.
    func testTheCreditIsAlwaysTheBannersDayOrToday() {
        for zone in [newYork, tokyo] {
            let cal = calendar(zone)
            let delivered = at(zone, 2026, 7, 13, 23, 30)
            let carried: [String?] = [nil, "2026-07-11", "2026-07-12", "2026-07-13", "2026-07-14", "2026-07-20"]
            for day in carried {
                let bannerDay = day.flatMap(DataBackup.dayKey) ?? HabitCalendar.dayKey(forInstant: delivered, calendar: cal)
                for hours in 0..<(7 * 24) {
                    let responded = delivered.addingTimeInterval(TimeInterval(hours) * 3_600)
                    let today = HabitCalendar.dayKey(forInstant: responded, calendar: cal)
                    let credited = resolve(zone, delivered: delivered, responded: responded, day: day)
                    XCTAssertTrue(credited == bannerDay || credited == today,
                                  "\(zone) day=\(day ?? "nil") +\(hours)h credited \(credited)")
                    XCTAssertLessThanOrEqual(credited, today, "never ahead of the clock")
                }
            }
        }
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
