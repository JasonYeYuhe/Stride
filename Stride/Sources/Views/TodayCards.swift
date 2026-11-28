import SwiftUI
import SwiftData

/// Today's inline cards (RELEASE-1.4.2.md D12; RELEASE-1.5.0.md D5: missed yesterday, the week
/// card, the reminder offer) and the one system review prompt after a check-in (N3). When a card
/// shows is `InlinePrompts`' (Shared/), when Stride asks for a rating is `ReviewPromptRule`'s; this
/// file draws them and keeps the state of both, in `UserDefaults.standard` only — never synced,
/// never in the backup, never read by the widget. Neither writes anything to the store (Data
/// safety 3 of 1.4.2, 1 of 1.5.0).
enum TodayCards {

    /// Today's one inline card at `now`, or nil (RELEASE-1.5.0.md D5: missed yesterday, the week
    /// card, the reminder offer — one at a time, in that order).
    /// - Parameters:
    ///   - habits: Today's habits (not archived), in order.
    ///   - cache: their stats, read for `WeeklyReviewMath.today(now:calendar:)` — the day the
    ///     review is built for — so the week card's number is the number the review's ring shows
    ///     for last week, and yesterday's open habits are `DailyProgress`'s.
    ///   - live: the app's part of `InlinePrompts.TodayFacts` (the selected day, the permission,
    ///     the reminders); `.none` leaves the two 1.5.0 cards out, as 1.4.2 did.
    ///   - override: DEBUG's `-inlineCard` (`nil` everywhere else).
    @MainActor
    static func card(habits: [Habit], cache: StatsCache, now: Date, calendar: Calendar, isPro: Bool,
                     state: InlinePrompts.DismissalState, live: InlinePrompts.TodayFacts = .none,
                     override: InlineOverride? = nil) -> InlinePrompts.Card? {
        if override == .hidden { return nil }
        if override == .reminder { return .reminderOffer }
        if override == .missed {
            // Yesterday's real count, whatever the day, the permission and "Not now" (V5's sweep).
            let today = WeeklyReviewMath.today(now: now, calendar: calendar)
            let open = InlinePrompts.facts(of: cache.stats(for: habits, today: today, calendar: calendar),
                                           today: today).openYesterday
            guard open > 0 else { return nil }
            return .missedYesterday(InlinePrompts.MissedYesterdayCard(
                today: HabitStats.dayNumber(ofKey: today), openCount: open))
        }
        let forced = override == .forced
        let inWindow = forced || InlinePrompts.isInWindow(now: now, calendar: calendar)
        // The 1.5.0 cards need the stats only when one of them could show at all.
        let wantsFacts = live.isTodaySelected || (live.permissionUndecided && !live.anyReminderOn)
        guard inWindow || wantsFacts else { return nil }
        let today = WeeklyReviewMath.today(now: now, calendar: calendar)
        let stats = cache.stats(for: habits, today: today, calendar: calendar)
        var rate: Double?
        if inWindow {
            let lastWeek = InlinePrompts.lastWeek(now: now, calendar: calendar)
            let inputs = zip(habits, stats).map { WeeklyReviewMath.HabitInput(habit: $0, stats: $1) }
            rate = WeeklyReviewMath.review(of: inputs, week: lastWeek).overall
        }
        var facts = live
        if !forced {
            let fromHabits = InlinePrompts.facts(of: stats, today: today)
            facts.openYesterday = fromHabits.openYesterday
            facts.checkedInBeforeToday = fromHabits.checkedInBeforeToday
            facts.checkInDays = fromHabits.checkInDays
        }
        return InlinePrompts.card(now: now, calendar: calendar, isPro: isPro, lastWeekRate: rate,
                                  state: state, facts: facts, ignoresWindow: forced)
    }

    /// Whether any reminder is on (D5's offer): a shown habit's own, or the Daily Reminder.
    @MainActor
    static func anyReminderOn(habits: [Habit], dailyReminderOn: Bool) -> Bool {
        dailyReminderOn || habits.contains { $0.reminderEnabled }
    }

    /// This process is an automated run (`ReviewPromptRule.isAutomatedRun`): any launch argument,
    /// or an XCTest host. Then Today writes nothing to `UserDefaults.standard` — neither the card's
    /// state nor the install date — the same predicate that keeps the review prompt away.
    static var isAutomatedRun: Bool {
        ReviewPromptRule.isAutomatedRun(arguments: ProcessInfo.processInfo.arguments,
                                        environment: ProcessInfo.processInfo.environment)
    }

    /// `-inlineCard none|week|missed|reminder` (D14; RELEASE-1.5.0.md V5), as Today reads it.
    enum InlineOverride: Equatable {
        /// `none`: no inline card, whatever the day.
        case hidden
        /// `week`: the week card, whatever the day and whatever was dismissed.
        case forced
        /// `missed`: the missed-yesterday card with yesterday's real count (none when it is 0).
        case missed
        /// `reminder`: the reminder offer, whatever the permission and the reminders say.
        case reminder
    }

    /// This process's `-inlineCard` (DEBUG only; nil in Release).
    static var launchOverride: InlineOverride? {
        #if DEBUG
        switch StrideDebugLaunchFlags.current.inlineCard {
        case .off?: return .hidden
        case .week?: return .forced
        case .missed?: return .missed
        case .reminder?: return .reminder
        case nil: return nil
        }
        #else
        return nil
        #endif
    }
}

// MARK: - The "Your week" card

/// D12's card, under Today's progress card, Monday and Tuesday.
/// - Pro: "Last week: 82%" over "See your Weekly Review".
/// - Free: "Your Weekly Review is ready" — no number — over a crowned "See your Weekly Review".
///
/// The button issues through the shell (`onOpen`: `ShellState.issue(card.issuer, isPro:)`, D8): the
/// review on last week for Pro, the paywall with `.today` resuming it for a free user. × is
/// "Hide until next week" for Pro and "Don't show again" for a free user. Buttons only, so VoiceOver
/// and Full Keyboard Access reach both.
struct TodayWeekCard: View {
    let card: InlinePrompts.WeekCard
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The palette's Green as readable text on the card: the system green is about 2.2:1 on the
    /// light card.
    private static let linkHex = "#34C759"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                icon
            }
            VStack(alignment: .leading, spacing: 6) {
                title
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text("See your Weekly Review")
                            .fixedSize(horizontal: false, vertical: true)
                        if !card.isPro {
                            // Decoration, as on Statistics' Weekly Review button: the paywall
                            // says what it sells.
                            Image(systemName: "crown.fill")
                                .imageScale(.small)
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.readableText(hex: Self.linkHex, in: colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.weekCard.open")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -12)
            .padding(.trailing, -12)
            .accessibilityLabel(card.isPro ? "Hide until next week" : "Don't show again")
            .accessibilityIdentifier("today.weekCard.dismiss")
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.weekCard")
    }

    private var icon: some View {
        Image(systemName: "calendar.badge.clock")
            .font(.title2)
            .foregroundStyle(.green)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var title: some View {
        switch card.copy {
        case .pro(let percent):
            Text("Last week: \(percent)%")
        case .free:
            Text("Your Weekly Review is ready")
        }
    }
}

// MARK: - Missed yesterday and the reminder offer (RELEASE-1.5.0.md D5)

/// One of D5's two cards: a title over its two buttons, the first the action, the second "Not now".
/// Buttons only, so VoiceOver and Full Keyboard Access reach both. Neither writes to the store
/// (Data safety 1): `onAction` re-anchors Today or asks for notifications, `onNotNow` writes the
/// card's own state in `UserDefaults.standard` (`InlinePromptStore`).
struct TodayPromptCard: View {
    enum Kind: Equatable {
        /// "%lld habits not checked yesterday" / "Show yesterday".
        case missedYesterday(openCount: Int)
        /// "Get a reminder each evening" / "Turn on".
        case reminderOffer
    }

    let kind: Kind
    let onAction: () -> Void
    let onNotNow: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The palette's Green as readable text, as the week card's link.
    private static let linkHex = "#34C759"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                // Side by side while they fit; one over the other at accessibility sizes.
                let buttons = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 20))
                buttons {
                    Button(action: onAction) {
                        actionTitle
                            .fixedSize(horizontal: false, vertical: true)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.readableText(hex: Self.linkHex, in: colorScheme))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier).action")
                    Button(action: onNotNow) {
                        Text("Not now")
                            .fixedSize(horizontal: false, vertical: true)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier).notNow")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch kind {
        case .missedYesterday: return "today.missedCard"
        case .reminderOffer: return "today.reminderCard"
        }
    }

    private var icon: String {
        switch kind {
        case .missedYesterday: return "arrow.uturn.backward.circle"
        case .reminderOffer: return "bell.badge"
        }
    }

    @ViewBuilder
    private var title: some View {
        switch kind {
        case .missedYesterday(let count):
            Text("\(count) habits not checked yesterday")
        case .reminderOffer:
            Text("Get a reminder each evening")
        }
    }

    @ViewBuilder
    private var actionTitle: some View {
        switch kind {
        case .missedYesterday:
            Text("Show yesterday")
        case .reminderOffer:
            Text("Turn on")
        }
    }
}

// MARK: - The card's state

/// `InlinePrompts.DismissalState` in `UserDefaults.standard` (D12). Per device on purpose; never
/// synced, never in the backup, never read by the widget (the widget has no code that reads these
/// keys). The hosted tests pass a scratch suite.
///
/// `live` is read-only in an automated run (`ReviewPromptRule.isAutomatedRun`: any launch argument,
/// an XCTest host): a sweep or a hosted test that draws Today on a Monday or Tuesday reads the
/// state and never writes it, so no run leaves a free week, a × or a cap in the app's defaults for
/// the next one.
struct InlinePromptStore {
    let defaults: UserDefaults
    /// `save` writes nothing.
    let readOnly: Bool

    init(defaults: UserDefaults, readOnly: Bool = false) {
        self.defaults = defaults
        self.readOnly = readOnly
    }

    static let proHiddenWeekKey = "stride_week_card_pro_hidden_week"
    static let freeWeeksShownKey = "stride_week_card_free_weeks_shown"
    static let freeEndedKey = "stride_week_card_free_ended"
    /// Missed yesterday's "Not now" (RELEASE-1.5.0.md D5): the day number it was pressed on.
    static let missedHiddenDayKey = "stride_missed_card_hidden_day"
    /// The reminder offer answered (D5): never again on this device.
    static let reminderOfferEndedKey = "stride_reminder_offer_ended"

    /// Every key this store writes.
    static let keys = [proHiddenWeekKey, freeWeeksShownKey, freeEndedKey, missedHiddenDayKey, reminderOfferEndedKey]

    static var live: InlinePromptStore {
        InlinePromptStore(defaults: .standard, readOnly: TodayCards.isAutomatedRun)
    }

    var state: InlinePrompts.DismissalState {
        InlinePrompts.DismissalState(
            proHiddenWeek: defaults.object(forKey: Self.proHiddenWeekKey) as? Int,
            freeWeeksShown: (defaults.array(forKey: Self.freeWeeksShownKey) as? [Int]) ?? [],
            freeEnded: defaults.bool(forKey: Self.freeEndedKey),
            missedHiddenDay: defaults.object(forKey: Self.missedHiddenDayKey) as? Int,
            reminderOfferEnded: defaults.bool(forKey: Self.reminderOfferEndedKey))
    }

    func save(_ state: InlinePrompts.DismissalState) {
        guard !readOnly else { return }
        if let week = state.proHiddenWeek {
            defaults.set(week, forKey: Self.proHiddenWeekKey)
        } else {
            defaults.removeObject(forKey: Self.proHiddenWeekKey)
        }
        defaults.set(state.freeWeeksShown, forKey: Self.freeWeeksShownKey)
        defaults.set(state.freeEnded, forKey: Self.freeEndedKey)
        if let day = state.missedHiddenDay {
            defaults.set(day, forKey: Self.missedHiddenDayKey)
        } else {
            defaults.removeObject(forKey: Self.missedHiddenDayKey)
        }
        defaults.set(state.reminderOfferEnded, forKey: Self.reminderOfferEndedKey)
    }
}

// MARK: - The review prompt (N3)

/// The app's side of `ReviewPromptRule`: it reads the state, decides, makes the call and records
/// it. The rule's own conditions live in Shared/ReviewPromptRule.swift; there is no `#if DEBUG`
/// here either, so a Release build answers exactly as the hosted tests see it.
///
/// State, in `defaults` (`UserDefaults.standard` in the app), never synced, never in the backup:
/// - `installDateKey`: the install date (`ReviewPromptRule` condition 3), recorded once, the first
///   time Today appears or a check-in reaches this prompter on this install of 1.4.2 or later;
/// - `promptedVersionKey`: the version Stride last asked in (condition 2).
struct ReviewPrompter {
    let defaults: UserDefaults
    let arguments: [String]
    let environment: [String: String]
    let appVersion: String
    let now: () -> Date

    static let installDateKey = "stride_install_date"
    static let promptedVersionKey = "stride_review_prompt_version"
    /// OnboardingView's flag (the sweep and the E2E kit set it in the argument domain).
    static let onboardingCompletedKey = "stride_onboarding_completed"

    /// This process: `UserDefaults.standard`, its own arguments and environment, its version.
    static var live: ReviewPrompter {
        ReviewPrompter(defaults: .standard, arguments: ProcessInfo.processInfo.arguments,
                       environment: ProcessInfo.processInfo.environment,
                       appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                       now: { Date() })
    }

    var installDate: Date? { defaults.object(forKey: Self.installDateKey) as? Date }

    /// Sets the install date unless one is set. Never in an automated run (its own arguments and
    /// environment): a hosted test or a sweep must not start the 3-day clock of the app it runs in.
    func recordInstallDateIfNeeded() {
        guard installDate == nil,
              !ReviewPromptRule.isAutomatedRun(arguments: arguments, environment: environment) else { return }
        defaults.set(now(), forKey: Self.installDateKey)
    }

    func context(sheetShowing: Bool) -> ReviewPromptRule.Context {
        ReviewPromptRule.Context(
            appVersion: appVersion,
            lastPromptedVersion: defaults.string(forKey: Self.promptedVersionKey),
            installDate: installDate,
            now: now(),
            onboardingCompleted: defaults.bool(forKey: Self.onboardingCompletedKey),
            sheetShowing: sheetShowing,
            automatedRun: ReviewPromptRule.isAutomatedRun(arguments: arguments, environment: environment))
    }

    /// After a write on Today's row: asks (`request`, the system's prompt) when the rule says so,
    /// and records the version first, so a second milestone in the same version never asks again
    /// even if the system showed nothing.
    @discardableResult
    func afterCheckIn(_ checkIn: ReviewPromptRule.CheckIn, sheetShowing: Bool,
                      request: () -> Void) -> ReviewPromptRule.Decision {
        recordInstallDateIfNeeded()
        let decision = ReviewPromptRule.decide(checkIn, in: context(sheetShowing: sheetShowing))
        if decision == .ask {
            defaults.set(appVersion, forKey: Self.promptedVersionKey)
            request()
        }
        return decision
    }
}

/// What Today's rows call after a write (N3): TodayView hands its rows the hook, which knows
/// whether anything is presented and holds the system's `requestReview` action. Nil outside Today.
struct ReviewPromptHook {
    let afterCheckIn: @MainActor (ReviewPromptRule.CheckIn) -> Void
}

extension EnvironmentValues {
    var reviewPromptHook: ReviewPromptHook? {
        get { self[ReviewPromptHookKey.self] }
        set { self[ReviewPromptHookKey.self] = newValue }
    }
}

private struct ReviewPromptHookKey: EnvironmentKey {
    static let defaultValue: ReviewPromptHook? = nil
}

extension ReviewPromptRule.CheckIn {
    /// A row's write, from the habit's stats before and after it (`StatsCache`, re-read after the
    /// commit's bump).
    init(habit: Habit, day: Date, before: HabitStats, after: HabitStats, written: HabitCheckIn.Written,
         calendar: Calendar = .current, now: Date = Date()) {
        self.init(unit: habit.schedule == .timesPerWeek ? .week : .day,
                  completesDay: written.isCheckIn && written.isCompleted,
                  isToday: calendar.isDate(day, inSameDayAs: now),
                  streakBefore: before.currentStreak(asOf: day), streakAfter: after.currentStreak(asOf: day),
                  weekDoneBefore: before.weeklyCompletions(containing: day),
                  weekDoneAfter: after.weeklyCompletions(containing: day),
                  weeklyGoal: habit.timesPerWeek)
    }
}
