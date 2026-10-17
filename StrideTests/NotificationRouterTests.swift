import XCTest
import Foundation
import UserNotifications

/// `NotificationRouter.route` (Shared/NotificationRouter.swift; RELEASE-1.4.0.md D4): which
/// responses to a reminder write anything, and never with a kind. The router itself does not
/// import UserNotifications (Shared/ also compiles into scripts/sync_rehearsal's bare CLI); this
/// file does, so the system's own default-tap and dismiss identifiers go through the matrix.
final class NotificationRouterTests: XCTestCase {

    private let habitID = UUID()
    private var info: [AnyHashable: Any] { [NotificationRouter.UserInfoKey.habitID: habitID.uuidString] }

    private let binary = NotificationRouter.binaryCategory
    private let count = NotificationRouter.countCategory
    private let markDone = NotificationRouter.markDoneAction
    private let addOne = NotificationRouter.addOneAction
    private let snooze = NotificationRouter.snoozeAction

    private func route(_ action: String, _ category: String, _ userInfo: [AnyHashable: Any]? = nil) -> NotificationRoute {
        NotificationRouter.route(actionIdentifier: action, categoryIdentifier: category, userInfo: userInfo ?? info)
    }

    private func key(_ year: Int, _ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - The identifiers are a format

    /// Delivered banners and pending requests carry these strings across app updates, and the
    /// E2E kit's `simctl push` payloads spell them out: changing one strands every banner that has it.
    func testIdentifiersArePinned() {
        XCTAssertEqual(binary, "stride.habit.binary")
        XCTAssertEqual(count, "stride.habit.count")
        XCTAssertEqual(markDone, "stride.habit.action.markDone")
        XCTAssertEqual(addOne, "stride.habit.action.addOne")
        XCTAssertEqual(snooze, "stride.habit.action.snooze")
        XCTAssertEqual(NotificationRouter.UserInfoKey.habitID, "habitId")
        XCTAssertEqual(NotificationRouter.UserInfoKey.day, "day")
    }

    /// The system's own identifiers, pinned here because the router never names them: it sends
    /// everything that is not one of our actions to `.none`. If a future SDK ever reused one of
    /// our strings, this would say so.
    func testTheSystemActionIdentifiersAreNotOurs() {
        XCTAssertEqual(UNNotificationDefaultActionIdentifier, "com.apple.UNNotificationDefaultActionIdentifier")
        XCTAssertEqual(UNNotificationDismissActionIdentifier, "com.apple.UNNotificationDismissActionIdentifier")
        for system in [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier] {
            XCTAssertFalse([markDone, addOne, snooze].contains(system))
        }
    }

    // MARK: - The matrix

    /// Every action in every category. Only our two categories ever write, a check-in action in
    /// either one is a check-in (the write then follows the habit's current kind, not the
    /// button), Snooze is a snooze, and everything else — the default tap that only opens the
    /// app, a dismiss, an unknown action — is `.none`.
    func testEveryActionInEveryCategory() {
        let actions = [markDone, addOne, snooze, UNNotificationDefaultActionIdentifier,
                       UNNotificationDismissActionIdentifier, "", "stride.habit.action.unknown"]
        let categories = [binary, count, "", "stride.habit.unknown", "STRIDE.HABIT.BINARY", "stride.habit"]
        for category in categories {
            for action in actions {
                let expected: NotificationRoute
                switch (category == binary || category == count, action) {
                case (true, markDone), (true, addOne): expected = .checkIn(habitID: habitID, day: nil)
                case (true, snooze): expected = .snooze(habitID: habitID, day: nil)
                default: expected = .none
                }
                XCTAssertEqual(route(action, category), expected, "\(action) in \"\(category)\"")
            }
        }
    }

    /// The route never carries a kind: Add 1 in the yes/no category and Mark Done in the count
    /// category are the same check-in as the matching pair (design review,
    /// "stale-category-addone-untoggles-binary").
    func testTheRouteCarriesNoKind() {
        let checkIn = NotificationRoute.checkIn(habitID: habitID, day: nil)
        XCTAssertEqual(route(markDone, binary), checkIn)
        XCTAssertEqual(route(addOne, count), checkIn)
        XCTAssertEqual(route(addOne, binary), checkIn)
        XCTAssertEqual(route(markDone, count), checkIn)
    }

    /// The evening and morning reminders (`stride.daily.evening`, `stride.daily.morning`) have no
    /// category and no userInfo; neither has a 1.3.x habit reminder still pending after the update.
    /// The default tap on any of them only opens the app.
    func testGlobalAndLegacyRemindersRouteToNone() {
        for action in [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier, markDone] {
            XCTAssertEqual(route(action, "", [:]), .none, "a global reminder: \(action)")
            XCTAssertEqual(route(action, "", info), .none, "no category, even with a habit id: \(action)")
        }
        XCTAssertEqual(route(markDone, binary, [:]), .none, "our category with no userInfo")
    }

    // MARK: - The habit id

    /// Only the canonical form `uuidString` writes. Lower case parses as a UUID but never comes
    /// from our scheduler, so it writes nothing; neither does anything that is not a String.
    func testMissingMalformedOrNonCanonicalHabitIDsRouteToNone() {
        let bad: [Any] = [
            habitID.uuidString.lowercased(),
            "{\(habitID.uuidString)}",
            " \(habitID.uuidString)",
            habitID.uuidString + "\n",
            String(habitID.uuidString.dropLast()),
            "not-a-uuid",
            "",
            habitID,                       // a UUID object, not its string
            NSNumber(value: 42),
            [habitID.uuidString],
        ]
        for value in bad {
            XCTAssertEqual(route(markDone, binary, [NotificationRouter.UserInfoKey.habitID: value]), .none, "\(value)")
            XCTAssertEqual(route(snooze, count, [NotificationRouter.UserInfoKey.habitID: value]), .none, "\(value)")
        }
        XCTAssertEqual(route(markDone, binary, ["habitID": habitID.uuidString]), .none, "the key is case-sensitive")
        XCTAssertEqual(NotificationRouter.habitID(from: info), habitID)
    }

    // MARK: - The day a snooze carries

    /// A canonical `yyyy-MM-dd` in range becomes that day's key, on a check-in and on a snooze
    /// (which copies it forward). Anything else is nil — the route still stands, and the day
    /// falls back to the delivered one (`ReminderDay.resolve`); a bogus day is never written.
    func testTheDayIsParsedCanonicallyOrNotAtAll() {
        var withDay = info
        withDay[NotificationRouter.UserInfoKey.day] = "2026-07-13"
        XCTAssertEqual(route(markDone, binary, withDay), .checkIn(habitID: habitID, day: key(2026, 7, 13)))
        XCTAssertEqual(route(addOne, count, withDay), .checkIn(habitID: habitID, day: key(2026, 7, 13)))
        XCTAssertEqual(route(snooze, binary, withDay), .snooze(habitID: habitID, day: key(2026, 7, 13)))

        let refused: [Any] = ["2026-02-30", "2026-7-13", "2026-07-13T00:00:00Z", "13/07/2026", "1969-12-31",
                              "2101-01-01", "", " 2026-07-13", NSNumber(value: 20_260_713), key(2026, 7, 13)]
        for value in refused {
            var bad = info
            bad[NotificationRouter.UserInfoKey.day] = value
            XCTAssertEqual(route(markDone, binary, bad), .checkIn(habitID: habitID, day: nil), "\(value)")
            XCTAssertEqual(route(snooze, count, bad), .snooze(habitID: habitID, day: nil), "\(value)")
        }
    }

    /// What a snooze stores is what the router reads back.
    func testTheStoredDayRoundTrips() {
        for day in [key(2026, 7, 13), key(2026, 1, 1), key(2026, 12, 31), key(2028, 2, 29)] {
            var withDay = info
            withDay[NotificationRouter.UserInfoKey.day] = ReminderDay.string(for: day)
            XCTAssertEqual(NotificationRouter.day(from: withDay), day)
        }
        XCTAssertEqual(ReminderDay.string(for: key(2026, 7, 13)), "2026-07-13")
    }
}
