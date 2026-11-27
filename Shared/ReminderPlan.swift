import Foundation

/// Which notification requests a habit's reminder becomes, under which identifiers — the one
/// source for both, so that scheduling, removal and the launch prune cannot disagree
/// (RELEASE-1.4.0.md D4). Pure: NotificationService (Stride/Sources) and the widget's check-in
/// (StrideWidget) turn these into `UNNotificationRequest`s.
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
///
/// **1.5.0: quiet when done (RELEASE-1.5.0.md D4, Gemini A0–A5).** A repeating trigger cannot skip
/// one day, so a day that asks nothing more of a habit — done, or its times-per-week goal met —
/// is silenced by an OVERLAY decided per quiet day: that weekday's request becomes a one-shot on
/// the same weekday NEXT week (`.n<w>`), and a daily-shaped habit's bare request becomes weekly
/// requests for its other weekdays (`.<w>`). Today is overlaid only while its reminder time is
/// still ahead; every quiet later day of this Monday week whatever the hour. The Daily Reminder
/// gets the same overlay on a perfect day (`stride.daily.evening.<w>`, `.n<w>`). The plan is
/// computed from scratch every time, from today's day-key, so a later plan has no stale overlay.
enum ReminderPlan {
    /// Every per-habit reminder id starts with this; the legacy daily one is exactly this + uuid.
    static let reminderPrefix = "stride.habit.reminder."
    /// The one-shot Snooze 1 Hour request: this + uuid. Outside `reminderPrefix` on purpose, so no
    /// code that still matches the old prefix can mistake a snooze for a reminder.
    static let snoozePrefix = "stride.habit.snooze."
    /// How far a snooze moves the reminder.
    static let snoozeInterval: TimeInterval = 3_600

    /// The Daily Reminder's base id (NotificationService's `stride.daily.evening`); its overlay ids
    /// are this + `.<w>` and `.n<w>` (`allEveningIdentifiers`).
    static let eveningIdentifier = "stride.daily.evening"

    /// How many snoozes the budget leaves room for. `scheduleSnooze` has no cap of its own, so a
    /// plan made while more are pending takes the extra out of the overlays' budget (`plan`'s
    /// `pendingSnoozes`).
    static let snoozeRoom = 4

    /// How many per-habit reminder requests may be pending: iOS keeps 64 per app, minus the two
    /// global reminders (`stride.daily.evening`, `stride.daily.morning`) and room for four snoozes.
    /// The Daily Reminder's base request is one of the two; its overlay's six more count inside
    /// this budget (D4, Gemini A0).
    static let requestBudget = 64 - 2 - snoozeRoom

    /// One habit's reminder as the planner reads it: a value, so the planner runs without a store.
    struct Settings: Equatable, Sendable {
        var habitID: UUID
        var schedule: HabitSchedule
        var activeDaysMask: Int
        var hour: Int
        var minute: Int
        /// The habit's quiet days this week (D4): day-keys from today through this Monday week's
        /// Sunday whose `DailyProgress` state is `.done` or `.metForWeek` (`quietDays(of:today:)`).
        /// Any other day-key is ignored by the planner; empty plans the base shape.
        var quietDays: Set<Date>

        init(habitID: UUID, schedule: HabitSchedule, activeDaysMask: Int = 127, hour: Int, minute: Int,
             quietDays: Set<Date> = []) {
            self.habitID = habitID
            self.schedule = schedule
            self.activeDaysMask = activeDaysMask
            self.hour = hour
            self.minute = minute
            self.quietDays = quietDays
        }

        /// The habit's reminder, or nil when it has none to plan: reminder off, or archived — the
        /// same rule `scheduleAllHabitReminders` fetches by. A snooze survives the prune only for a
        /// habit that is here (D4: "a snooze is kept only for a habit that still has its reminder
        /// on"). No quiet days: the caller adds them (`quietDays(of:today:)`).
        init?(_ habit: Habit) {
            guard habit.reminderEnabled, !habit.isArchived else { return nil }
            self.init(habitID: habit.id, schedule: habit.schedule, activeDaysMask: habit.activeDaysMask,
                      hour: habit.reminderHour, minute: habit.reminderMinute)
        }
    }

    /// The Daily Reminder as the planner reads it: on (a value) or off (nil).
    struct Evening: Equatable, Sendable {
        var hour: Int
        var minute: Int
        /// `DailyProgress.isPerfect` for today over every unarchived habit: something was due and
        /// all of it is done. A day with nothing due is not perfect, so its reminder stays.
        var isPerfectToday: Bool

        init(hour: Int, minute: Int, isPerfectToday: Bool = false) {
            self.hour = hour
            self.minute = minute
            self.isPerfectToday = isPerfectToday
        }

        /// The keys NotificationService stores the Daily Reminder under, in the App Group.
        enum Key {
            static let enabled = "reminderEnabled"
            static let hour = "reminderHour"
            /// Set once a time was chosen: an unset hour reads as 20:00, a chosen 0 as midnight.
            static let hourSet = "reminderHourSet"
            static let minute = "reminderMinute"
        }

        /// The Daily Reminder as `defaults` holds it, or nil when it is off. An hour never set is
        /// 20:00 (`NotificationService.reminderHour`'s rule).
        static func stored(in defaults: UserDefaults, isPerfectToday: Bool) -> Evening? {
            guard defaults.bool(forKey: Key.enabled) else { return nil }
            let hour = defaults.integer(forKey: Key.hour)
            return Evening(hour: hour == 0 && !defaults.bool(forKey: Key.hourSet) ? 20 : hour,
                           minute: defaults.integer(forKey: Key.minute), isPerfectToday: isPerfectToday)
        }

        /// The widget's read (D5): the Daily Reminder from the App Group's defaults, nil when it is
        /// off or the group cannot be read (then the widget leaves the evening as it is).
        static func storedInAppGroup(isPerfectToday: Bool) -> Evening? {
            SharedModelContainer.appGroupDefaults.flatMap { stored(in: $0, isPerfectToday: isPerfectToday) }
        }
    }

    /// When the plan is made: what decides which quiet days are overlaid and the one-shots' dates.
    struct Today: Sendable {
        /// Today's day-key: `DailyProgress.today(now:calendar:)` (`HabitCalendar.dayKey(forInstant:)`),
        /// never `dayKey(for:)` of a live instant.
        var dayKey: Date
        var now: Date
        /// The user's calendar: its time zone decides whether a reminder time is "still ahead".
        var calendar: Calendar

        init(now: Date, calendar: Calendar) {
            self.init(dayKey: DailyProgress.today(now: now, calendar: calendar), now: now, calendar: calendar)
        }

        init(dayKey: Date, now: Date, calendar: Calendar) {
            self.dayKey = dayKey
            self.now = now
            self.calendar = calendar
        }
    }

    /// One pending request to add.
    struct Request: Equatable, Sendable {
        var identifier: String
        /// The habit, or nil for the Daily Reminder.
        var habitID: UUID?
        /// Repeating: `hour` and `minute`, plus `weekday` for a weekly trigger. `weekday` uses
        /// `DateComponents`' own numbering, 1 = Sunday … 7 = Saturday, whatever day a calendar's
        /// week starts on — so a Monday-first region does not move a Monday reminder to Tuesday.
        /// A one-shot (`repeats == false`, the overlay's `.n<w>`): `year`, `month`, `day`, `hour`
        /// and `minute`, and no time zone — floating, like the repeating ones, so it fires at that
        /// wall-clock time wherever the device is then.
        var dateComponents: DateComponents
        var repeats: Bool

        init(identifier: String, habitID: UUID?, dateComponents: DateComponents, repeats: Bool = true) {
            self.identifier = identifier
            self.habitID = habitID
            self.dateComponents = dateComponents
            self.repeats = repeats
        }

        var weekday: Int? { dateComponents.weekday }

        /// What the trigger is, as a comparable value (`Fire`).
        var fire: Fire { Fire(dateComponents, repeats: repeats) }
    }

    /// A trigger as a comparable value: the calendar fields a trigger of ours can carry, and
    /// whether it repeats. Built from a planned request or from a pending trigger's
    /// `dateComponents`, so "is what is pending what the plan wants?" ignores anything else a
    /// trigger read back from the system may carry (a calendar, a time zone, a zero second).
    struct Fire: Hashable, Sendable {
        var year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?, weekday: Int?
        var repeats: Bool

        init(_ c: DateComponents, repeats: Bool) {
            year = c.year; month = c.month; day = c.day
            hour = c.hour; minute = c.minute; weekday = c.weekday
            self.repeats = repeats
        }
    }

    /// Every request for the habits given, after the budget.
    struct Result: Equatable, Sendable {
        /// The habits' requests, in the order the habits were given.
        var requests: [Request]
        /// The Daily Reminder's: its base request, or its overlay on a perfect day; empty when it
        /// is off.
        var evening: [Request]
        /// The budget was exceeded, so every specificDays habit got its single daily trigger: it
        /// fires on rest days, as in 1.3.x, and nothing is dropped. Then nothing is overlaid (D4).
        /// A code-only diagnostic for the caller to log — no user-facing message, no habit ids.
        var fellBackToDaily: Bool
        /// What the launch prune must not remove: EVERY id each planned habit can have (all
        /// shapes, the overlay's one-shots and the snooze), not only the ones planned now. The keep
        /// set is computed before the center answers, and the widget can write a habit's overlay
        /// in that window; a prune keeping only today's ids would remove it as an orphan and leave
        /// the habit with no request (Gemini A1). Stale shapes of a live habit are its own replace
        /// step's to remove. So the prune removes only orphans of deleted, archived or
        /// reminder-off habits.
        var keep: Set<String>
        /// The habits whose overlay is in the plan (the rest have their base shape).
        var overlaid: Set<UUID>
        /// The Daily Reminder's overlay is in the plan.
        var eveningOverlaid: Bool

        /// One habit's planned requests.
        func requests(for habitID: UUID) -> [Request] {
            requests.filter { $0.habitID == habitID }
        }
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

    /// `stride.habit.reminder.<uuid>.n<w>`: the overlay's one-shot on weekday `w` next week (D4).
    static func oneShotIdentifier(for habitID: UUID, weekday: Int) -> String {
        "\(legacyIdentifier(for: habitID)).n\(weekday)"
    }

    /// `stride.habit.snooze.<uuid>`: one per habit, so snoozing again replaces it.
    static func snoozeIdentifier(for habitID: UUID) -> String {
        snoozePrefix + habitID.uuidString
    }

    /// Every id this habit can have pending or delivered: the legacy daily one, the seven weekday
    /// ones, the overlay's seven one-shots (1.5.0, Gemini A3) and the snooze. Scheduling removes
    /// these first (the snooze aside); removing a habit's reminder (archive, delete, reminder off)
    /// removes all of them, pending and delivered.
    static func allIdentifiers(for habitID: UUID) -> [String] {
        [legacyIdentifier(for: habitID)]
            + (1...7).map { weekdayIdentifier(for: habitID, weekday: $0) }
            + (1...7).map { oneShotIdentifier(for: habitID, weekday: $0) }
            + [snoozeIdentifier(for: habitID)]
    }

    /// Every id the habit's reminder itself can be scheduled under: `allIdentifiers` without the
    /// snooze, which no reschedule ends (launch, a foreground sync, an edit and a language change
    /// all reschedule, and none of them is the user saying the snooze is over).
    static func reminderIdentifiers(for habitID: UUID) -> [String] {
        let snooze = snoozeIdentifier(for: habitID)
        return allIdentifiers(for: habitID).filter { $0 != snooze }
    }

    /// `stride.daily.evening.<w>`.
    static func eveningWeekdayIdentifier(weekday: Int) -> String { "\(eveningIdentifier).\(weekday)" }

    /// `stride.daily.evening.n<w>`.
    static func eveningOneShotIdentifier(weekday: Int) -> String { "\(eveningIdentifier).n\(weekday)" }

    /// Every id the Daily Reminder can have: `stride.daily.evening`, `.1`…`.7` and `.n1`…`.n7`.
    /// Scheduling it, switching it off and every evening transition remove all of them first.
    static let allEveningIdentifiers: [String] = [eveningIdentifier]
        + (1...7).map(eveningWeekdayIdentifier(weekday:))
        + (1...7).map(eveningOneShotIdentifier(weekday:))

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

    /// One habit's base requests. `dailyOnly`: the budget's fallback — one daily trigger whatever
    /// the schedule.
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

    /// Whether a reminder at `hour`:`minute` is still ahead of `now` today, by the wall clock of
    /// `calendar` (the user's): after it, today's request has already fired and there is nothing
    /// left to silence today.
    static func isAhead(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute, .second], from: now)
        let nowSeconds = (c.hour ?? 0) * 3_600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return nowSeconds < hour * 3_600 + minute * 60
    }

    /// The day numbers to overlay for a reminder at `hour`:`minute` whose quiet days are `quiet`:
    /// today while the time is ahead, and every quiet later day of this Monday week. Anything else
    /// in `quiet` (yesterday — the late-night grace's credit quiets yesterday, never today —, last
    /// week, next week) is ignored.
    static func overlayDays(quiet: Set<Date>, hour: Int, minute: Int, today: Today) -> [Int] {
        let todayNumber = HabitStats.dayNumber(ofKey: today.dayKey)
        let sunday = HabitStats.monday(ofWeekContaining: todayNumber) + 6
        // Decided once, when the plan is made, not when its writes reach the center. Accepted
        // (v2 review, finding 6): an un-check at 19:59:59 for a 20:00 reminder plans the base back,
        // but if that write lands after 20:00 the repeating trigger's next fire is tomorrow, so
        // today's reminder is lost. The window is the time a pass takes (milliseconds), the user
        // has just acted on the habit in the app or the widget, and the next day fires as planned.
        let todayAhead = isAhead(hour: hour, minute: minute, now: today.now, calendar: today.calendar)
        return Set(quiet.map(HabitStats.dayNumber(ofKey:)))
            .filter { $0 > todayNumber && $0 <= sunday || ($0 == todayNumber && todayAhead) }
            .sorted()
    }

    /// The one-shot's components for a quiet day: the same weekday next week, at `hour`:`minute`.
    /// The date is the quiet day's key + 7 days in `HabitCalendar.utc` — never `+ 7 × 86 400 s` of
    /// a local instant, which lands on day 6 across a fall-back night — and the components carry
    /// no time zone (D4, Gemini A5).
    static func oneShotComponents(quietDay: Int, hour: Int, minute: Int) -> DateComponents {
        let key = HabitStats.key(ofDay: quietDay)
        let next = HabitCalendar.utc.date(byAdding: .day, value: 7, to: key) ?? key.addingTimeInterval(7 * 86_400)
        let c = HabitCalendar.utc.dateComponents([.year, .month, .day], from: next)
        return DateComponents(year: c.year, month: c.month, day: c.day, hour: hour, minute: minute)
    }

    /// The overlaid shape of a reminder whose base fires on `weekdays` (nil: every day) for the
    /// quiet days `days` (from `overlayDays`): each quiet weekday it fires on becomes a one-shot
    /// next week; a daily-shaped reminder's other weekdays become weekly requests. In weekday
    /// order. nil when no quiet day falls on a weekday it fires on: the base stands.
    static func overlay(weekdays: [Int]?, days: [Int], hour: Int, minute: Int,
                        weekly: (Int) -> String, oneShot: (Int) -> String, habitID: UUID?) -> [Request]? {
        let quietByWeekday = Dictionary(days.map { (HabitStats.weekday(ofDay: $0), $0) },
                                        uniquingKeysWith: { first, _ in first })
        let fires = weekdays ?? Array(1...7)
        guard fires.contains(where: { quietByWeekday[$0] != nil }) else { return nil }
        return fires.map { w in
            if let day = quietByWeekday[w] {
                return Request(identifier: oneShot(w), habitID: habitID,
                               dateComponents: oneShotComponents(quietDay: day, hour: hour, minute: minute),
                               repeats: false)
            }
            return Request(identifier: weekly(w), habitID: habitID,
                           dateComponents: DateComponents(hour: hour, minute: minute, weekday: w))
        }
    }

    /// The Daily Reminder's base request: one repeating daily trigger.
    static func eveningBase(_ evening: Evening) -> Request {
        Request(identifier: eveningIdentifier, habitID: nil,
                dateComponents: DateComponents(hour: evening.hour, minute: evening.minute))
    }

    /// The full plan (D4): every reminder-on habit's requests, and the Daily Reminder's, within
    /// `budget`.
    ///
    /// 1. **The base plan, exactly as before 1.5.0.** Over the budget, every specificDays habit
    ///    falls back to its one daily trigger rather than some reminders being dropped at random:
    ///    iOS keeps 64 pending requests per app and discards the rest without an error (`add`
    ///    reports none), so a reminder would simply stop firing. A specificDays habit that fires
    ///    on its rest days is the 1.3.x behaviour; one that never fires is a silent loss. All of
    ///    them, not just enough to fit: which habit loses its weekday triggers must not depend on
    ///    fetch order. **Then nothing is overlaid: the plan is exactly the base.**
    /// 2. **The overlays**, only with a `today`: each habit's (its `quietDays`) and the Daily
    ///    Reminder's (today, on a perfect day), in order of reminder time (then input order, the
    ///    Daily Reminder after the habits at the same minute), each added while the total stays
    ///    within `budget`. The Daily Reminder's base slot is outside the budget (the "2" in
    ///    `64 - 2 - 4`), its overlay's extra six are inside (Gemini A0). An overlay that does not
    ///    fit is skipped — its reminder keeps its base request and over-fires today — and a later,
    ///    cheaper one may still fit.
    ///
    /// `pendingSnoozes`: the snoozes pending when the plan is made. The budget leaves room for
    /// `snoozeRoom`; each one beyond that is taken out of what the overlays may add (never out of
    /// the base plan, whose fallback is decided against `budget` alone), so a run of snoozes
    /// cannot push the pending total past iOS's 64 through an overlay (v2 review, finding 5).
    static func plan(_ habits: [Settings], evening: Evening? = nil, today: Today? = nil,
                     budget: Int = requestBudget, pendingSnoozes: Int = 0) -> Result {
        var perHabit = habits.map { requests(for: $0) }
        let baseCount = perHabit.reduce(0) { $0 + $1.count }
        let fellBack = baseCount > budget
        if fellBack {
            perHabit = habits.map { requests(for: $0, dailyOnly: true) }
        }
        var eveningRequests = evening.map { [eveningBase($0)] } ?? []
        var overlaid: Set<UUID> = []
        var eveningOverlaid = false

        if !fellBack, let today {
            struct Candidate {
                var index: Int?            // nil: the Daily Reminder
                var minuteOfDay: Int
                var order: Int
                var requests: [Request]
            }
            var candidates: [Candidate] = []
            for (index, settings) in habits.enumerated() {
                let days = overlayDays(quiet: settings.quietDays, hour: settings.hour, minute: settings.minute, today: today)
                guard !days.isEmpty,
                      let shape = overlay(weekdays: weekdays(for: settings), days: days,
                                          hour: settings.hour, minute: settings.minute,
                                          weekly: { weekdayIdentifier(for: settings.habitID, weekday: $0) },
                                          oneShot: { oneShotIdentifier(for: settings.habitID, weekday: $0) },
                                          habitID: settings.habitID)
                else { continue }
                candidates.append(Candidate(index: index, minuteOfDay: settings.hour * 60 + settings.minute,
                                            order: index, requests: shape))
            }
            if let evening, evening.isPerfectToday {
                let todayNumber = HabitStats.dayNumber(ofKey: today.dayKey)
                let days = overlayDays(quiet: [HabitStats.key(ofDay: todayNumber)], hour: evening.hour,
                                       minute: evening.minute, today: today)
                if !days.isEmpty,
                   let shape = overlay(weekdays: nil, days: days, hour: evening.hour, minute: evening.minute,
                                       weekly: eveningWeekdayIdentifier(weekday:),
                                       oneShot: eveningOneShotIdentifier(weekday:), habitID: nil) {
                    candidates.append(Candidate(index: nil, minuteOfDay: evening.hour * 60 + evening.minute,
                                                order: habits.count, requests: shape))
                }
            }
            candidates.sort { ($0.minuteOfDay, $0.order) < ($1.minuteOfDay, $1.order) }

            let overlayBudget = budget - max(0, pendingSnoozes - snoozeRoom)
            var total = baseCount
            for candidate in candidates {
                let current = candidate.index.map { perHabit[$0].count } ?? 1
                let cost = candidate.requests.count - current
                // A free overlay (a specific-days habit's quiet weekday) always fits: it adds nothing,
                // even when snoozes left the overlays less room than the base plan already takes.
                guard cost <= 0 || total + cost <= overlayBudget else { continue }
                total += cost
                if let index = candidate.index {
                    perHabit[index] = candidate.requests
                    overlaid.insert(habits[index].habitID)
                } else {
                    eveningRequests = candidate.requests
                    eveningOverlaid = true
                }
            }
        }

        let keep = Set(habits.flatMap { allIdentifiers(for: $0.habitID) })
        return Result(requests: perHabit.flatMap { $0 }, evening: eveningRequests, fellBackToDaily: fellBack,
                      keep: keep, overlaid: overlaid, eveningOverlaid: eveningOverlaid)
    }

    /// The launch prune: the pending (or delivered) ids to remove — every per-habit reminder or
    /// snooze id that `keep` does not name. Orphans of deleted or archived habits (which sync
    /// cannot reach), a snooze of a habit whose reminder is off. Never the global reminders.
    static func prune(_ identifiers: [String], keep: Set<String>) -> [String] {
        identifiers.filter { isHabitRequest($0) && !keep.contains($0) }
    }

    // MARK: - Reading the store (the planner's inputs)

    /// Whether a `DailyProgress` state asks nothing more of the habit that day (D4): done, or its
    /// times-per-week goal met. `.rest` is quiet already (no request fires on it); `.notStarted`
    /// cannot fall after today.
    static func isQuiet(_ state: DailyProgress.State) -> Bool {
        state == .done || state == .metForWeek
    }

    /// The habit's quiet days this week: the day-keys from `today` through this Monday week's
    /// Sunday whose `DailyProgress` state `isQuiet`. `stats` is built through `today` (later
    /// check-ins do not count; a later day reads `.metForWeek` when the week's goal is met by
    /// today, else `.due`). Yesterday is never asked: a late-night credit for yesterday quiets
    /// yesterday, never today (D4).
    static func quietDays(of stats: HabitStats, today dayKey: Date) -> Set<Date> {
        let todayNumber = HabitStats.dayNumber(ofKey: dayKey)
        let sunday = HabitStats.monday(ofWeekContaining: todayNumber) + 6
        return Set((todayNumber...sunday).map(HabitStats.key(ofDay:))
            .filter { isQuiet(DailyProgress.state(of: stats, on: $0)) })
    }

    /// One habit's planner input, quiet days included; nil when its reminder is off or it is
    /// archived (`Settings.init?(_:)`).
    static func settings(for habit: Habit, stats: HabitStats, today dayKey: Date) -> Settings? {
        guard var settings = Settings(habit) else { return nil }
        settings.quietDays = quietDays(of: stats, today: dayKey)
        return settings
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
        resolve(carriedDay: NotificationRouter.day(from: userInfo), deliveredAt: deliveredAt,
                respondedAt: respondedAt, calendar: calendar)
    }

    /// The same rule from a day the router already read: the `day` of `NotificationRoute.checkIn`
    /// or `.snooze` — `NotificationRouter.day(from:)` of the same `userInfo`, so the two forms
    /// cannot disagree. The action handler (Stride/Sources) holds the route, not the payload.
    static func resolve(carriedDay: Date?, deliveredAt: Date, respondedAt: Date,
                        calendar: Calendar = .current) -> Date {
        let today = HabitCalendar.dayKey(forInstant: respondedAt, calendar: calendar)
        let bannerDay = carriedDay
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

    /// Whether a reminder answered at `now` could still credit `dayKey`, as `resolve` decides:
    /// today, or yesterday within `lateNightGrace` after midnight. Never an older day, nor a later
    /// one.
    ///
    /// A check-in made in the app on such a day completes what the habit's pending snooze and
    /// delivered banners are asking for, so it ends them (`CheckInEffects`). A check-in on any
    /// other day does not. That other day is a backfill from Today's week strip, and it must
    /// leave alone the snooze the user asked for TODAY, and today's banner, while today is still
    /// not done; nothing would restore either (W2 fix review: Thursday 20:30, Wednesday ticked
    /// off in the strip, Thursday's 21:00 snooze gone).
    ///
    /// `dayKey` must be a day-key (`HabitCalendar.dayKey(for:)` of the date the check-in used).
    static func isCreditable(_ dayKey: Date, at now: Date, calendar: Calendar = .current) -> Bool {
        resolve(carriedDay: dayKey, deliveredAt: now, respondedAt: now, calendar: calendar) == dayKey
    }

    /// The `userInfo["day"]` value for a day-key: `yyyy-MM-dd`, what `NotificationRouter.day(from:)`
    /// reads back. A snooze stores the day `resolve` gave at the moment Snooze was tapped, so a
    /// snooze of a snooze carries it forward unchanged.
    static func string(for dayKey: Date) -> String {
        HabitCalendar.dayStringFormatter.string(from: dayKey)
    }
}
