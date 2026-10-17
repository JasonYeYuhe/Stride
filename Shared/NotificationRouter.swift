import Foundation

/// What a response to a habit reminder asks for (RELEASE-1.4.0.md D4). Never a habit KIND.
///
/// The first draft returned `.checkIn(id, .markDone | .addOne)`, read off the action. The design
/// review (2026-10-10, "stale-category-addone-untoggles-binary") showed why that is unsafe: a
/// banner's category is fixed when it is scheduled, and a delivered one keeps it
/// (`UNNotificationContent.categoryIdentifier` is read-only), while the habit's kind can change
/// afterwards — an edit on this device, or a pull from another. The natural code for that payload
/// was `case .addOne: tap`, and `tap` on a habit that has since become yes/no and is already done
/// DELETES the day's record, and the tombstone takes it off every device. So the route says only
/// "check in" or "snooze"; what a check-in writes is decided from the habit as it is now, by
/// `HabitCheckIn.fromReminder`, which can never delete.
enum NotificationRoute: Equatable, Sendable {
    /// Mark Done (yes/no category) or Add 1 (count category). `day` is the day a snooze carried
    /// (`userInfo["day"]`), nil on an original reminder; `ReminderDay.resolve` turns either into
    /// the day to credit.
    case checkIn(habitID: UUID, day: Date?)
    /// Snooze 1 Hour. `day` as above: a snooze of a snooze copies it forward.
    case snooze(habitID: UUID, day: Date?)
    /// Not one of ours, or not something to write: the default tap (it only opens the app), a
    /// dismiss, the evening and morning reminders, a 1.3.x request with no userInfo, an unknown
    /// category, a missing, malformed or non-canonical habit id.
    case none
}

/// Maps a notification response to a `NotificationRoute`. Pure: the identifiers and the payload
/// in, the route out, so StrideTests pins the whole matrix host-less (D7). The delegate
/// (`NotificationActionHandler`, Stride/Sources) is a thin shim over it.
///
/// It does not import UserNotifications. It needs none of its symbols: anything that is not one
/// of the three action identifiers below routes to `.none`, which is exactly what the default tap
/// (`UNNotificationDefaultActionIdentifier`) and a dismiss (`UNNotificationDismissActionIdentifier`)
/// must do. StrideTests imports the framework and feeds the real constants through, so a change
/// in their values cannot turn them into a check-in.
enum NotificationRouter {
    // MARK: Categories — one per habit kind at scheduling time (the button title differs)

    /// A yes/no habit's reminder: Mark Done, Snooze 1 Hour.
    static let binaryCategory = "stride.habit.binary"
    /// A count habit's reminder: Add 1, Snooze 1 Hour.
    static let countCategory = "stride.habit.count"

    // MARK: Actions

    /// "Mark Done" (binary category).
    static let markDoneAction = "stride.habit.action.markDone"
    /// "Add 1" (count category).
    static let addOneAction = "stride.habit.action.addOne"
    /// "Snooze 1 Hour" (both categories).
    static let snoozeAction = "stride.habit.action.snooze"

    /// The keys of a habit reminder's `userInfo`.
    enum UserInfoKey {
        /// The habit's `id.uuidString` — canonical, upper case, as `UUID.uuidString` writes it.
        static let habitID = "habitId"
        /// On a snooze only: the `yyyy-MM-dd` day the original reminder was for — what
        /// `ReminderDay.resolve` gave when Snooze was tapped (`ReminderDay.string(for:)`), so a
        /// snooze of a snooze copies it forward while it is still creditable. It is the banner's
        /// day, not an override: a stale one credits today, as a stale reminder does.
        static let day = "day"
    }

    static func route(actionIdentifier: String, categoryIdentifier: String,
                      userInfo: [AnyHashable: Any]) -> NotificationRoute {
        // Only our two categories. The evening and morning reminders have none (""); a category
        // a later build adds is not this build's to act on.
        guard categoryIdentifier == binaryCategory || categoryIdentifier == countCategory,
              let habitID = habitID(from: userInfo)
        else { return .none }
        switch actionIdentifier {
        case markDoneAction, addOneAction:
            // Either check-in action, in either category: the category only proves the button was
            // a check-in. Which write it becomes is the habit's CURRENT kind's business
            // (`HabitCheckIn.fromReminder`), never the button's — see `NotificationRoute`.
            return .checkIn(habitID: habitID, day: day(from: userInfo))
        case snoozeAction:
            return .snooze(habitID: habitID, day: day(from: userInfo))
        default:
            return .none
        }
    }

    /// The habit id, only in the canonical form `uuidString` writes: a String, upper case.
    /// `UUID(uuidString:)` alone also takes lower case, which no request of ours ever carries, so a
    /// lower-case id means the payload did not come from this app's scheduler (a hand-made
    /// `simctl push`, a future format) and nothing is written for it.
    static func habitID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let string = userInfo[UserInfoKey.habitID] as? String,
              let id = UUID(uuidString: string), id.uuidString == string
        else { return nil }
        return id
    }

    /// The day a snooze carried, as a day-key, or nil: absent (an original reminder), not a String,
    /// or not a canonical `yyyy-MM-dd` between 1970 and 2100 (`DataBackup.dayKey`, the same
    /// range-checked parser a backup's days go through — "2026-02-30" and "2026-9-5" are refused,
    /// never rolled over). A bad value falls back to the delivered day (`ReminderDay.resolve`), it
    /// never writes a bogus one.
    static func day(from userInfo: [AnyHashable: Any]) -> Date? {
        (userInfo[UserInfoKey.day] as? String).flatMap(DataBackup.dayKey)
    }
}
