import Foundation

/// Which notification requests a habit's reminder becomes, under which identifiers — the one
/// source for both, so that scheduling, removal and the launch prune cannot disagree
/// (RELEASE-1.4.0.md D4). Pure: NotificationService (Stride/Sources) turns these into
/// `UNNotificationRequest`s.
///
/// Until 1.4.0 every reminder was one daily trigger under `stride.habit.reminder.<uuid>`, so a
/// Mon/Wed/Fri habit was nagged on its rest days too. Now:
/// - daily, timesPerWeek, a mask of every day (127), a malformed mask 0 (read as every day, as
///   AddHabitView's save does with an empty selection) and a mask with only bits above Saturday:
///   one DAILY trigger under that same legacy id, so a 1.3.x request is simply replaced;
/// - any other specificDays habit: one WEEKLY trigger per selected day,
///   `stride.habit.reminder.<uuid>.<w>`, w = 1 Sunday … 7 Saturday.
///
/// Three hazards the M3 code map found, which this type exists to close:
/// - the 1.3.x prune kept only `prefix + uuid` and would have removed every weekday request on
///   the next launch: `keep` comes from here, weekday ids and snoozes included;
/// - a habit moving between daily and specific days left the other shape's requests firing:
///   `allIdentifiers(for:)` is every id a habit can ever have, and scheduling removes all of them
///   first;
/// - weekday triggers multiply requests against iOS's 64 pending, which the system enforces by
///   silently dropping some: the budget below.
enum ReminderPlan {
    /// Every per-habit reminder id starts with this; the legacy daily one is exactly this + uuid.
    static let reminderPrefix = "stride.habit.reminder."
    /// The one-shot Snooze 1 Hour request: this + uuid. Outside `reminderPrefix` on purpose, so no
    /// code that still matches the old prefix can mistake a snooze for a reminder.
    static let snoozePrefix = "stride.habit.snooze."
    /// How far a snooze moves the reminder.
    static let snoozeInterval: TimeInterval = 3_600

    /// How many per-habit reminder requests may be pending: iOS keeps 64 per app, minus the two
    /// global reminders (`stride.daily.evening`, `stride.daily.morning`) and room for four snoozes.
    static let requestBudget = 64 - 2 - 4

    /// One habit's reminder as the planner reads it: a value, so the planner runs without a store.
    struct Settings: Equatable, Sendable {
        var habitID: UUID
        var schedule: HabitSchedule
        var activeDaysMask: Int
        var hour: Int
        var minute: Int

        init(habitID: UUID, schedule: HabitSchedule, activeDaysMask: Int = 127, hour: Int, minute: Int) {
            self.habitID = habitID
            self.schedule = schedule
            self.activeDaysMask = activeDaysMask
            self.hour = hour
            self.minute = minute
        }

        /// The habit's reminder, or nil when it has none to plan: reminder off, or archived — the
        /// same rule `scheduleAllHabitReminders` fetches by. A snooze survives the prune only for a
        /// habit that is here (D4: "a snooze is kept only for a habit that still has its reminder
        /// on").
        init?(_ habit: Habit) {
            guard habit.reminderEnabled, !habit.isArchived else { return nil }
            self.init(habitID: habit.id, schedule: habit.schedule, activeDaysMask: habit.activeDaysMask,
                      hour: habit.reminderHour, minute: habit.reminderMinute)
        }
    }

    /// One pending request to add.
    struct Request: Equatable, Sendable {
        var identifier: String
        var habitID: UUID
        /// `hour` and `minute`, plus `weekday` for a weekly trigger. Repeating. `weekday` uses
        /// `DateComponents`' own numbering, 1 = Sunday … 7 = Saturday, whatever day a calendar's
        /// week starts on — so a Monday-first region does not move a Monday reminder to Tuesday.
        var dateComponents: DateComponents

        var weekday: Int? { dateComponents.weekday }
    }

    /// Every request for the habits given, after the budget.
    struct Result: Equatable, Sendable {
        var requests: [Request]
        /// The budget was exceeded, so every specificDays habit got its single daily trigger: it
        /// fires on rest days, as in 1.3.x, and nothing is dropped. A code-only diagnostic for the
        /// caller to log — no user-facing message, no habit ids.
        var fellBackToDaily: Bool
        /// What the launch prune must not remove: every planned id, and the snooze of every planned
        /// habit (whether or not one is pending).
        var keep: Set<String>
    }

    // MARK: - Identifiers

    /// `stride.habit.reminder.<uuid>` — 1.3.x's only id, still the daily trigger's.
    static func legacyIdentifier(for habitID: UUID) -> String {
        reminderPrefix + habitID.uuidString
    }

    /// `stride.habit.reminder.<uuid>.<w>`, w = 1 Sunday … 7 Saturday.
    static func weekdayIdentifier(for habitID: UUID, weekday: Int) -> String {
        "\(legacyIdentifier(for: habitID)).\(weekday)"
    }

    /// `stride.habit.snooze.<uuid>`: one per habit, so snoozing again replaces it.
    static func snoozeIdentifier(for habitID: UUID) -> String {
        snoozePrefix + habitID.uuidString
    }

    /// Every id this habit can have pending or delivered: the legacy daily one, the seven weekday
    /// ones and the snooze. Scheduling removes these first; removing a habit's reminder (archive,
    /// delete, reminder off) removes all of them, pending and delivered.
    static func allIdentifiers(for habitID: UUID) -> [String] {
        [legacyIdentifier(for: habitID)]
            + (1...7).map { weekdayIdentifier(for: habitID, weekday: $0) }
            + [snoozeIdentifier(for: habitID)]
    }

    /// A per-habit reminder or snooze id — what the prune may remove. The global reminders are not.
    static func isHabitRequest(_ identifier: String) -> Bool {
        identifier.hasPrefix(reminderPrefix) || identifier.hasPrefix(snoozePrefix)
    }

    // MARK: - Planning

    /// The weekdays (1 Sunday … 7 Saturday) a habit's reminder fires on by itself, or nil for one
    /// daily trigger. Only bits 0…6 mean days (Habit.activeDaysMask: bit 0 = Sunday); a synced
    /// mask is not range-checked (SyncReconciler assigns it as the server sent it), so the rest
    /// are ignored, and a mask with no day left — 0, or only higher bits — is every day: a
    /// reminder that the user switched on must never silently never fire.
    static func weekdays(for settings: Settings) -> [Int]? {
        guard settings.schedule == .specificDays else { return nil }
        let days = settings.activeDaysMask & 0b111_1111
        guard days != 0, days != 0b111_1111 else { return nil }
        return (0..<7).filter { days & (1 << $0) != 0 }.map { $0 + 1 }
    }

    /// One habit's requests. `dailyOnly`: the budget's fallback — one daily trigger whatever the
    /// schedule.
    static func requests(for settings: Settings, dailyOnly: Bool = false) -> [Request] {
        guard !dailyOnly, let days = weekdays(for: settings) else {
            return [Request(identifier: legacyIdentifier(for: settings.habitID), habitID: settings.habitID,
                            dateComponents: DateComponents(hour: settings.hour, minute: settings.minute))]
        }
        return days.map { day in
            Request(identifier: weekdayIdentifier(for: settings.habitID, weekday: day), habitID: settings.habitID,
                    dateComponents: DateComponents(hour: settings.hour, minute: settings.minute, weekday: day))
        }
    }

    /// Every reminder-on habit's requests, within `budget`. Over it, every specificDays habit falls
    /// back to its one daily trigger rather than some reminders being dropped at random: iOS keeps
    /// 64 pending requests per app and discards the rest without an error (`add` reports none), so
    /// a reminder would simply stop firing. A specificDays habit that fires on its rest days is the
    /// 1.3.x behaviour; one that never fires is a silent loss. All of them, not just enough to fit:
    /// which habit loses its weekday triggers must not depend on fetch order.
    static func plan(_ habits: [Settings], budget: Int = requestBudget) -> Result {
        var planned = habits.flatMap { requests(for: $0) }
        let fellBack = planned.count > budget
        if fellBack {
            planned = habits.flatMap { requests(for: $0, dailyOnly: true) }
        }
        let keep = Set(planned.map(\.identifier)).union(habits.map { snoozeIdentifier(for: $0.habitID) })
        return Result(requests: planned, fellBackToDaily: fellBack, keep: keep)
    }

    /// The launch prune: the pending (or delivered) ids to remove — every per-habit reminder or
    /// snooze id that `keep` does not name. Orphans of deleted or archived habits (which sync
    /// cannot reach), the old shape of a habit whose schedule changed, a snooze of a habit whose
    /// reminder is off. Never the global reminders.
    static func prune(_ identifiers: [String], keep: Set<String>) -> [String] {
        identifiers.filter { isHabitRequest($0) && !keep.contains($0) }
    }
}

/// Which day a reminder's Mark Done or Add 1 credits (RELEASE-1.4.0.md D4). Pure; the handler
/// passes the delivered notification's `date`, the time of the response and the calendar.
///
/// Two findings of the design review shaped it:
/// - **The blocker.** The first draft passed `response.notification.date` straight to the
///   check-in, which keys it with the idempotent `HabitCalendar.dayKey(for:)`. A calendar trigger
///   fires on a whole minute, and in every negative UTC offset some reminder hour is exactly
///   00:00:00 UTC of the NEXT date — the default 20:00 in US Eastern daylight time, 19:00 EST,
///   16:00 PST. `dayKey(for:)` takes such an instant for a day-key that already exists, so Mark
///   Done wrote TOMORROW's record, synced it everywhere, and left today open. Invisible from
///   UTC+9, where this app is built. Every day here goes through `dayKey(forInstant:)`.
/// - **Stale days.** A delivered banner stays in Notification Center until its id fires again —
///   a week, for a weekday id — and a snooze's one-shot banner until something withdraws it,
///   which for someone who only ever acts from the lock screen is nothing at all. Monday's banner
///   tapped on Thursday must credit Thursday, and a 23:30 reminder snoozed to 00:30 must still
///   credit the day it was for.
///
/// So the answer is only ever one of two days: the day the banner is FOR, or today. Never a
/// third. The first W1 cut followed D4's four steps literally and broke that twice (W1 code
/// review, 2026-10-10): a carried snooze day was taken at any age — a snooze banner from Monday
/// night, tapped on Friday, checked Monday off on every device and left Friday open — and so was
/// any day in the range check, 2099 included; and the late-night grace credited "yesterday"
/// whatever the banner was for, so Monday's weekday banner tapped at 00:40 on Thursday checked
/// off Wednesday, a day it was never for and the habit may not even be scheduled on.
enum ReminderDay {
    /// An action this soon after local midnight, on a banner for the day that just ended, credits
    /// that day: someone ticking off last night's reminder at 00:40 means last night. Elapsed
    /// time, so a DST night does not stretch or shrink it.
    static let lateNightGrace: TimeInterval = 3 * 3_600

    /// The day-key to credit. The banner's day is `userInfo["day"]` when a snooze carries one (its
    /// own delivery can be past midnight), else the day it was delivered. Then:
    /// 1. the banner's day, if that is today;
    /// 2. the banner's day, if that is yesterday and the response came within `lateNightGrace`
    ///    after local midnight;
    /// 3. else today — a stale banner, original or snooze, is a nudge to do it today, the same
    ///    answer as the widget and Siri, which both credit now. A carried day in the future
    ///    lands here too: a check-in is never written ahead of the clock.
    ///
    /// A snooze stores what this returns at the moment Snooze is tapped (`string(for:)`), so a
    /// snooze of a snooze copies its day forward while that day is still creditable, and a snooze
    /// of a stale one starts over from today rather than carrying the stale day on.
    ///
    /// - Parameters:
    ///   - deliveredAt: `UNNotification.date`.
    ///   - respondedAt: now.
    ///   - calendar: the user's calendar (its time zone decides what "today" is).
    static func resolve(userInfo: [AnyHashable: Any], deliveredAt: Date, respondedAt: Date,
                        calendar: Calendar = .current) -> Date {
        let today = HabitCalendar.dayKey(forInstant: respondedAt, calendar: calendar)
        let bannerDay = NotificationRouter.day(from: userInfo)
            ?? HabitCalendar.dayKey(forInstant: deliveredAt, calendar: calendar)
        if bannerDay == today { return today }
        let midnight = calendar.startOfDay(for: respondedAt)
        if respondedAt.timeIntervalSince(midnight) < lateNightGrace,
           let yesterday = HabitCalendar.utc.date(byAdding: .day, value: -1, to: today),
           bannerDay == yesterday {
            return yesterday
        }
        return today
    }

    /// The `userInfo["day"]` value for a day-key: `yyyy-MM-dd`, what `NotificationRouter.day(from:)`
    /// reads back. A snooze stores the day `resolve` gave at the moment Snooze was tapped, so a
    /// snooze of a snooze carries it forward unchanged.
    static func string(for dayKey: Date) -> String {
        HabitCalendar.dayStringFormatter.string(from: dayKey)
    }
}
