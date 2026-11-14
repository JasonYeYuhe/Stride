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
/// Shared/ rules: values only, no user-facing text (TodayCards words the card).
enum InlinePrompts {

    // MARK: The cards

    /// What Today shows inline. One at most.
    enum Card: Equatable {
        case week(WeekCard)
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

        init(proHiddenWeek: Int? = nil, freeWeeksShown: [Int] = [], freeEnded: Bool = false) {
            self.proHiddenWeek = proHiddenWeek
            self.freeWeeksShown = freeWeeksShown
            self.freeEnded = freeEnded
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

    /// Today's one inline card, or none (D12: at most one at any time; the week card is the only
    /// kind in 1.4.2, so this is it when it shows).
    static func card(now: Date, calendar: Calendar, isPro: Bool, lastWeekRate: Double?,
                     state: DismissalState, ignoresWindow: Bool = false) -> Card? {
        weekCard(now: now, calendar: calendar, isPro: isPro, lastWeekRate: lastWeekRate, state: state,
                 ignoresWindow: ignoresWindow).map(Card.week)
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

    // MARK: Helpers

    /// `now`'s local date as a day number (`WeeklyReviewMath.today`, the review's own clock).
    private static func todayNumber(_ now: Date, _ calendar: Calendar) -> Int {
        HabitStats.dayNumber(ofKey: WeeklyReviewMath.today(now: now, calendar: calendar))
    }
}
