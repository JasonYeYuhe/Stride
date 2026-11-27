import Foundation

/// When Today shows its inline card, and which (RELEASE-1.4.2.md D12). Pure: the `Calendar`, the
/// clock, the entitlement, last week's rate and the dismissal state are passed in, so every rule is
/// pinned host-less in both zones (InlinePromptsTests).
///
/// The "Your week" card, the only inline card in 1.4.2:
/// - **When:** Monday 00:00 to Tuesday 23:59 local time — the first two days of the
///   Monday-anchored week (`WeeklyReviewMath.WeekRange`, on the local date of `now`, so the
///   region's first weekday, the calendar's identifier and a DST change never move it) — once
///   last week has an overall counted rate (`WeeklyReviewMath.Review.overall`, the number the
///   review's own ring shows for that week).
/// - **Pro:** "Last week: 82%" and "See your Weekly Review", every week; × hides it for that week.
/// - **Free:** "Your Weekly Review is ready" (no number) and a crowned "See your Weekly Review",
///   in at most `freeWeekCap` weeks ever; × ends it for good.
/// - **At most one inline card on Today** (`card(...)` returns one or none).
///
/// Its dismissal state is `DismissalState`, which the app keeps in `UserDefaults.standard` only
/// (TodayCards' `InlinePromptStore`): never synced, never in the backup, never read by the widget
/// (Data safety 9). A per-device preference on purpose: a card dismissed on the iPhone can still
/// show on the iPad or the Mac, and a reinstall resets it. `-inlineCard none|week` overrides it in
/// DEBUG (D14), in the app, never here.
///
/// 1.5.0 (RELEASE-1.5.0.md D5) adds two cards, and Today shows at most one of the three, in this
/// priority:
/// 1. **Missed yesterday** (`MissedYesterdayCard`): today is selected, yesterday left at least one
///    habit `.due` (`DailyProgress`: not a rest day, not a met week, not before its start), and
///    today is after the user's first check-in ever. "Show yesterday" re-anchors Today to yesterday
///    (the shell's day, never the store); "Not now" hides it for the rest of the day.
/// 2. **The week card**, unchanged.
/// 3. **The reminder offer**: the system permission is not determined, no reminder is on (no
///    habit's, and not the Daily Reminder), and the user has checked in on at least two different
///    days. "Turn on" asks for permission on the tap; whatever happens then, and on "Not now", it
///    never shows again on this device.
///
/// Shared/ rules: values only, no user-facing text (TodayCards words the card).
enum InlinePrompts {

    // MARK: The cards

    /// What Today shows inline. One at most, in this priority (D5): missed yesterday, the week
    /// card, the reminder offer.
    enum Card: Equatable {
        case missedYesterday(MissedYesterdayCard)
        case week(WeekCard)
        case reminderOffer
    }

    /// "%lld habits not checked yesterday" (D5).
    struct MissedYesterdayCard: Equatable {
        /// Today, as a day number: what "Not now" hides the card for.
        let today: Int
        /// The habits yesterday left open (`DailyProgress.State.due`), at least 1.
        let openCount: Int
        /// Yesterday, a day number.
        var yesterday: Int { today - 1 }
    }

    /// What the two 1.5.0 cards are decided from: the habits' part from their `HabitStats`
    /// (`facts(of:today:)`), the rest from the shell and the notification settings (the app's).
    struct TodayFacts: Equatable {
        /// The day Today shows is today (`shell.todayDate`).
        var isTodaySelected: Bool
        /// The habits `.due` yesterday and not done (`DailyProgress`).
        var openYesterday: Int
        /// The user's first check-in ever (any live record of a habit Today shows) was before
        /// today: today is "a day after the first check-in" (D5).
        var checkedInBeforeToday: Bool
        /// How many different days carry a check-in, counted up to 2 (all the offer asks).
        var checkInDays: Int
        /// The system's notification permission is `.notDetermined`. A status not read yet is not.
        var permissionUndecided: Bool
        /// A habit's reminder or the Daily Reminder is on.
        var anyReminderOn: Bool

        init(isTodaySelected: Bool = false, openYesterday: Int = 0, checkedInBeforeToday: Bool = false,
             checkInDays: Int = 0, permissionUndecided: Bool = false, anyReminderOn: Bool = false) {
            self.isTodaySelected = isTodaySelected
            self.openYesterday = openYesterday
            self.checkedInBeforeToday = checkedInBeforeToday
            self.checkInDays = checkInDays
            self.permissionUndecided = permissionUndecided
            self.anyReminderOn = anyReminderOn
        }

        /// Nothing that shows either 1.5.0 card: `card(...)` answers as in 1.4.2.
        static let none = TodayFacts()
    }

    /// The "Your week" card.
    struct WeekCard: Equatable {
        /// The week the card shows in (the current one), by its Monday's day number: what × hides
        /// (Pro) and what the free cap counts.
        let shownWeek: WeeklyReviewMath.WeekRange
        /// The week the card is about and opens: the one before `shownWeek`.
        var lastWeek: WeeklyReviewMath.WeekRange { shownWeek.previous }
        let copy: Copy

        enum Copy: Equatable {
            /// "Last week: \(percent)%" — the review ring's own number for last week
            /// (`StatsInsights.percent` of the overall rate).
            case pro(percent: Int)
            /// "Your Weekly Review is ready": no number, by design (D12).
            case free
        }

        var isPro: Bool {
            if case .pro = copy { return true }
            return false
        }

        /// Who issues the tap (D8, `MenuCommandRules.destination`): last week's review for Pro,
        /// the paywall with `.today` resuming it for everyone else, decided at the tap.
        var issuer: MenuCommandRules.ProIssuer { .todayWeekCard(lastWeek: lastWeek.monday) }
    }

    // MARK: Dismissal state

    /// What the user did with the card on this device. `UserDefaults.standard` only.
    struct DismissalState: Equatable {
        /// Pro's ×: the Monday (day number) of the week it was hidden in.
        var proHiddenWeek: Int?
        /// The Mondays (day numbers) of the weeks the free card was shown in, oldest first, at most
        /// `freeWeekCap` of them.
        var freeWeeksShown: [Int]
        /// Free's ×: the card never shows again for a free user.
        var freeEnded: Bool
        /// Missed yesterday's "Not now": the day number of the day it was pressed on (D5).
        var missedHiddenDay: Int?
        /// The reminder offer was answered ("Turn on", whatever the system said after it, or "Not
        /// now"): it never shows again on this device (D5).
        var reminderOfferEnded: Bool

        init(proHiddenWeek: Int? = nil, freeWeeksShown: [Int] = [], freeEnded: Bool = false,
             missedHiddenDay: Int? = nil, reminderOfferEnded: Bool = false) {
            self.proHiddenWeek = proHiddenWeek
            self.freeWeeksShown = freeWeeksShown
            self.freeEnded = freeEnded
            self.missedHiddenDay = missedHiddenDay
            self.reminderOfferEnded = reminderOfferEnded
        }

        static let empty = DismissalState()
    }

    /// A free user sees the card in at most this many weeks, ever (D12).
    static let freeWeekCap = 3

    /// The card shows on the first this-many days of the week: Monday and Tuesday.
    static let windowDays = 2

    // MARK: When

    /// The Monday-anchored week containing `now`'s local date.
    static func currentWeek(now: Date, calendar: Calendar) -> WeeklyReviewMath.WeekRange {
        WeeklyReviewMath.WeekRange(containingDay: todayNumber(now, calendar))
    }

    /// Whether `now` is Monday 00:00 … Tuesday 23:59:59 local time.
    static func isInWindow(now: Date, calendar: Calendar) -> Bool {
        let today = todayNumber(now, calendar)
        let offset = today - WeeklyReviewMath.WeekRange(containingDay: today).mondayNumber
        return (0..<windowDays).contains(offset)
    }

    /// Last week, as Today's card means it: the week before `now`'s.
    static func lastWeek(now: Date, calendar: Calendar) -> WeeklyReviewMath.WeekRange {
        currentWeek(now: now, calendar: calendar).previous
    }

    /// The week card at `now`, or nil.
    /// - Parameters:
    ///   - lastWeekRate: last week's overall counted rate (`WeeklyReviewMath.review(of:week:)` of
    ///     `lastWeek(now:calendar:)`, `.overall`); nil — the first week, no habit counted — shows
    ///     no card.
    ///   - ignoresWindow: DEBUG's `-inlineCard week` (the sweep's capture): any day, and whatever
    ///     the dismissal state says. Last week still needs a rate.
    static func weekCard(now: Date, calendar: Calendar, isPro: Bool, lastWeekRate: Double?,
                         state: DismissalState, ignoresWindow: Bool = false) -> WeekCard? {
        guard let lastWeekRate else { return nil }
        guard ignoresWindow || isInWindow(now: now, calendar: calendar) else { return nil }
        let week = currentWeek(now: now, calendar: calendar)
        if isPro {
            if !ignoresWindow, state.proHiddenWeek == week.mondayNumber { return nil }
            return WeekCard(shownWeek: week, copy: .pro(percent: StatsInsights.percent(lastWeekRate)))
        }
        if !ignoresWindow {
            guard !state.freeEnded else { return nil }
            let shownThisWeek = state.freeWeeksShown.contains(week.mondayNumber)
            guard shownThisWeek || state.freeWeeksShown.count < freeWeekCap else { return nil }
        }
        return WeekCard(shownWeek: week, copy: .free)
    }

    /// Missed yesterday (D5) at `now`, or nil: today is selected, yesterday left a habit open,
    /// today is after the first check-in ever, and "Not now" was not pressed today.
    static func missedYesterdayCard(now: Date, calendar: Calendar, facts: TodayFacts,
                                    state: DismissalState) -> MissedYesterdayCard? {
        let today = todayNumber(now, calendar)
        guard facts.isTodaySelected, facts.openYesterday > 0, facts.checkedInBeforeToday,
              state.missedHiddenDay != today else { return nil }
        return MissedYesterdayCard(today: today, openCount: facts.openYesterday)
    }

    /// Whether the reminder offer shows (D5): permission not determined, no reminder on, check-ins
    /// on at least two different days, and never answered on this device.
    static func offersReminder(facts: TodayFacts, state: DismissalState) -> Bool {
        facts.permissionUndecided && !facts.anyReminderOn && facts.checkInDays >= 2 && !state.reminderOfferEnded
    }

    /// Today's one inline card, or none (D5: at most one at any time): missed yesterday, else the
    /// week card, else the reminder offer. `ignoresWindow` (DEBUG's `-inlineCard week`) is the
    /// week card alone, as in 1.4.2. With `facts` left out (`.none`) this is 1.4.2's answer.
    static func card(now: Date, calendar: Calendar, isPro: Bool, lastWeekRate: Double?,
                     state: DismissalState, facts: TodayFacts = .none, ignoresWindow: Bool = false) -> Card? {
        let week = weekCard(now: now, calendar: calendar, isPro: isPro, lastWeekRate: lastWeekRate, state: state,
                            ignoresWindow: ignoresWindow)
        if ignoresWindow { return week.map(Card.week) }
        if let missed = missedYesterdayCard(now: now, calendar: calendar, facts: facts, state: state) {
            return .missedYesterday(missed)
        }
        if let week { return .week(week) }
        return offersReminder(facts: facts, state: state) ? .reminderOffer : nil
    }

    /// The habits' part of `TodayFacts` (D5), from each habit's `HabitStats` built for today or later
    /// (StatsCache's): yesterday's open habits by `DailyProgress`, whether any check-in is older
    /// than today, and the different check-in days counted up to 2. `today` is a day-key. The app
    /// fills in the rest (the selected day, the permission, the reminders).
    ///
    /// A check-in day is a day with a live record (a count habit's partial day too), as
    /// `HabitStats.valuesByDay` holds them; the walk stops as soon as both answers are known, so
    /// a long history costs a few lookups, not a scan per render.
    static func facts(of stats: [HabitStats], today: Date) -> TodayFacts {
        let todayNumber = HabitStats.dayNumber(ofKey: today)
        let yesterday = HabitStats.key(ofDay: todayNumber - 1)
        var open = 0
        var before = false
        var days = Set<Int>()
        for habit in stats {
            if DailyProgress.state(of: habit, on: yesterday) == .due { open += 1 }
            guard !before || days.count < 2 else { continue }
            for key in habit.valuesByDay.keys {
                let day = HabitStats.dayNumber(ofKey: key)
                if day < todayNumber { before = true }
                if days.count < 2 { days.insert(day) }
                if before && days.count >= 2 { break }
            }
        }
        return TodayFacts(openYesterday: open, checkedInBeforeToday: before, checkInDays: days.count)
    }

    // MARK: What the user did

    /// The state once `card` was on screen: a free card counts its week toward the cap (once per
    /// week). A Pro card changes nothing.
    static func shown(_ card: WeekCard, in state: DismissalState) -> DismissalState {
        guard !card.isPro else { return state }
        let week = card.shownWeek.mondayNumber
        guard !state.freeWeeksShown.contains(week), state.freeWeeksShown.count < freeWeekCap else { return state }
        var next = state
        next.freeWeeksShown.append(week)
        return next
    }

    /// The state after ×: Pro hides it for the week it shows in; free ends it for good.
    static func dismissed(_ card: WeekCard, in state: DismissalState) -> DismissalState {
        var next = shown(card, in: state)
        if card.isPro {
            next.proHiddenWeek = card.shownWeek.mondayNumber
        } else {
            next.freeEnded = true
        }
        return next
    }

    /// Missed yesterday's "Not now": hidden for the rest of the day it was pressed on.
    static func dismissed(_ card: MissedYesterdayCard, in state: DismissalState) -> DismissalState {
        var next = state
        next.missedHiddenDay = card.today
        return next
    }

    /// The reminder offer answered — "Turn on", whatever the system said after it, or "Not now":
    /// never again on this device.
    static func reminderOfferAnswered(in state: DismissalState) -> DismissalState {
        var next = state
        next.reminderOfferEnded = true
        return next
    }

    // MARK: Helpers

    /// `now`'s local date as a day number (`WeeklyReviewMath.today`, the review's own clock).
    private static func todayNumber(_ now: Date, _ calendar: Calendar) -> Int {
        HabitStats.dayNumber(ofKey: WeeklyReviewMath.today(now: now, calendar: calendar))
    }
}

// MARK: - Today's at-risk words and order (RELEASE-1.5.0.md D7)

/// What a Today row says about its week or its day beyond "done", and where it sorts (D7). Pure,
/// beside the cards because it is Today's too (TodayView words and draws it), and pinned host-less
/// in both zones (InlinePromptsTests). Free: Pro changes nothing here.
///
/// Only for today: the caller asks only when the day Today shows is today. "More" is always the
/// creation week's `owed` (`WeeklyReviewMath.WeekGoal`), the number `isAtRisk` weighs, so a
/// 3-times-a-week habit made on Friday never reads "3 more · 2 days left". No case names a weekday.
enum TodayAtRisk {

    /// The row's words.
    enum Words: Equatable {
        /// "%lld/%lld this week": times-per-week, the goal met — or, in the week the habit started,
        /// its share met (`owed == 0`), so no "0 more" is ever printed.
        case weekSoFar(done: Int, goal: Int)
        /// "%1$lld/%2$lld this week · %3$#@more@": times-per-week, owing `owed`, not at risk.
        case weekOwing(done: Int, goal: Int, owed: Int)
        /// "%1$#@more@ · %2$#@days@": times-per-week at risk, `daysLeft` ≥ 1 (never "0 days left").
        case atRiskDaysLeft(owed: Int, daysLeft: Int)
        /// "%#@more@ · today": times-per-week at risk on the week's last day.
        case atRiskToday(owed: Int)
        /// "Due today": a daily or specific-days habit at risk (due, not done, past its evening).
        case dueToday

        /// Drawn in the readable orange, and sorted first.
        var isAtRisk: Bool {
            switch self {
            case .weekSoFar, .weekOwing: return false
            case .atRiskDaysLeft, .atRiskToday, .dueToday: return true
            }
        }
    }

    /// The words for the habit `stats` describes at `now` (its stats built for `now`'s day, as
    /// StatsCache's are), or nil: a daily or specific-days habit that is not at risk says nothing
    /// new. `eveningTime`: `WeeklyReviewMath.eveningTime` for this habit. Archived habits are never
    /// passed in (Today does not show them).
    static func words(for stats: HabitStats, now: Date, calendar: Calendar,
                      eveningTime: WeeklyReviewMath.TimeOfDay) -> Words? {
        if let goal = WeeklyReviewMath.weekGoal(of: stats, now: now, calendar: calendar) {
            if goal.isAtRisk {
                return goal.isLastDay ? .atRiskToday(owed: goal.owed)
                    : .atRiskDaysLeft(owed: goal.owed, daysLeft: max(1, goal.daysLeft))
            }
            return goal.owed > 0 ? .weekOwing(done: goal.done, goal: goal.goal, owed: goal.owed)
                : .weekSoFar(done: goal.done, goal: goal.goal)
        }
        let atRisk = WeeklyReviewMath.isAtRisk(stats, isArchived: false, now: now, calendar: calendar,
                                               eveningTime: eveningTime)
        return atRisk ? .dueToday : nil
    }

    /// `items` with the at-risk ones first, each part in its own order (stable): one section's
    /// rows. Today passes the set it latched (D7), never one read after a check-in in the same pass.
    static func atRiskFirst<T>(_ items: [T], isAtRisk: (T) -> Bool) -> [T] {
        items.filter(isAtRisk) + items.filter { !isAtRisk($0) }
    }
}
