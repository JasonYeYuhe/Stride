import Foundation

/// When Stride asks the system for a rating (RELEASE-1.4.2.md N3, the owner's narrow amendment of
/// DEV-PLAN-1.3.md rule 4). Pure, so every condition is pinned host-less (ReviewPromptRuleTests);
/// the app's `ReviewPrompter` (Stride/Sources/Views/TodayCards.swift) reads the state, builds the
/// inputs and makes the one call.
///
/// The call is StoreKit's own prompt only — SwiftUI's `requestReview` action, i.e.
/// `requestReview(in:)` — which the system itself limits to 3 a year and may not show at all.
/// Stride asks only when **every** condition holds:
/// 1. **Right after a check-in that is a milestone** (`isMilestone`), made on Today's row for
///    today:
///    - a daily or specific-days habit (streaks in days): the check-in completes the day and takes
///      the current streak to a positive multiple of 7 (7, 14, 21 …), up from the streak before
///      it. The streak is the one Today's row shows (`HabitStats.currentStreak(asOf:)`): for
///      specific days it counts scheduled days, so "7" is seven scheduled days in a row;
///    - a times-per-week habit (streaks in weeks): the check-in meets the week — this week's
///      check-ins reach the weekly goal (`timesPerWeek`), up from below it.
/// 2. **At most once per app version** (`CFBundleShortVersionString`): the version last asked
///    for is kept in `UserDefaults.standard`, never synced, never in the app's backup.
/// 3. **Never in the first `minimumDaysSinceInstall` days after install.** The install date is the
///    first time this install of 1.4.2 or later recorded one (`ReviewPrompter`: Today's first
///    appearance, or the first check-in on Today, whichever comes first), in
///    `UserDefaults.standard`. A user who upgrades from 1.4.1 starts the clock at the upgrade —
///    never earlier, so the rule can only ask later than a true install date would. No date yet:
///    no ask. A clock set back before it: no ask.
/// 4. **Never during onboarding** (`stride_onboarding_completed` is not yet set).
/// 5. **Never with a sheet showing**: the shell's sheet, or anything the window presents (an
///    alert, the onboarding cover, a view's own sheet) — `ShellState.sheetOnScreen` and
///    `WindowPresentation.isPresenting`.
/// 6. **Never in an automated run** (`isAutomatedRun`): any launch argument (`-demo`, `-demoPro`,
///    `-paywall`, `-tab`, the sweep's and the E2E kit's `-stride_onboarding_completed`, Xcode's and
///    XCUITest's own), or an XCTest environment. A store build is launched with no arguments, so
///    this costs a real user nothing. The rule has no `#if DEBUG`: the Release build answers it the
///    same way, and a Release binary started with `open --args` (the Mac) still never asks.
///
/// The Settings → About "Rate Stride" row (D13) stays: it opens `writeReviewURL`.
enum ReviewPromptRule {

    /// Apple's write-a-review page for Stride (D13), Settings → About → Rate Stride.
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6761262334?action=write-review")!

    /// Condition 3.
    static let minimumDaysSinceInstall = 3

    /// A daily streak is a milestone at each multiple of this many days.
    static let streakMilestoneDays = 7

    // MARK: The check-in

    /// What a habit's streak counts (`Habit.streakUnit`).
    enum StreakUnit: Equatable {
        /// Daily and specific days.
        case day
        /// Times per week.
        case week
    }

    /// One habit's numbers just before and just after one write on Today's row.
    struct CheckIn: Equatable {
        let unit: StreakUnit
        /// The write moved the day toward done and the day ends completed
        /// (`HabitCheckIn.Written.isCheckIn && .isCompleted`): an un-check, a note, a count still
        /// below its target, are not.
        let completesDay: Bool
        /// The row's day is today (the week strip can show an earlier one; a backfill is not the
        /// moment to ask).
        let isToday: Bool
        /// `currentStreak(asOf: day)` before and after the write.
        let streakBefore: Int
        let streakAfter: Int
        /// This week's check-ins (`weeklyCompletions(containing: day)`) before and after.
        let weekDoneBefore: Int
        let weekDoneAfter: Int
        /// `timesPerWeek`, at least 1.
        let weeklyGoal: Int

        init(unit: StreakUnit, completesDay: Bool, isToday: Bool, streakBefore: Int, streakAfter: Int,
             weekDoneBefore: Int = 0, weekDoneAfter: Int = 0, weeklyGoal: Int = 1) {
            self.unit = unit
            self.completesDay = completesDay
            self.isToday = isToday
            self.streakBefore = streakBefore
            self.streakAfter = streakAfter
            self.weekDoneBefore = weekDoneBefore
            self.weekDoneAfter = weekDoneAfter
            self.weeklyGoal = max(1, weeklyGoal)
        }
    }

    /// Condition 1: the check-in completes a 7-day streak (or 14, 21 …), or meets a week.
    static func isMilestone(_ checkIn: CheckIn) -> Bool {
        guard checkIn.completesDay, checkIn.isToday else { return false }
        switch checkIn.unit {
        case .day:
            return checkIn.streakAfter > checkIn.streakBefore
                && checkIn.streakAfter >= streakMilestoneDays
                && checkIn.streakAfter % streakMilestoneDays == 0
        case .week:
            return checkIn.weekDoneBefore < checkIn.weeklyGoal && checkIn.weekDoneAfter >= checkIn.weeklyGoal
        }
    }

    // MARK: Everything else

    /// The app's state at the moment of the check-in.
    struct Context: Equatable {
        /// `CFBundleShortVersionString`.
        let appVersion: String
        /// The version Stride last asked in; nil: never.
        let lastPromptedVersion: String?
        /// Condition 3's install date; nil: none recorded yet.
        let installDate: Date?
        let now: Date
        /// `stride_onboarding_completed`.
        let onboardingCompleted: Bool
        /// Condition 5.
        let sheetShowing: Bool
        /// Condition 6 (`isAutomatedRun`).
        let automatedRun: Bool
    }

    /// Why Stride does not ask, the first condition that fails, in the order above.
    enum Skip: Equatable {
        case notAMilestone
        case alreadyAskedThisVersion
        case tooSoonAfterInstall
        case onboarding
        case sheetShowing
        case automatedRun
    }

    enum Decision: Equatable {
        /// Make the call, and record `appVersion` as asked.
        case ask
        case skip(Skip)
    }

    static func decide(_ checkIn: CheckIn, in context: Context) -> Decision {
        // The automated-run check first: a test or a sweep never even reads further.
        if context.automatedRun { return .skip(.automatedRun) }
        guard isMilestone(checkIn) else { return .skip(.notAMilestone) }
        guard !context.appVersion.isEmpty, context.lastPromptedVersion != context.appVersion else {
            return .skip(.alreadyAskedThisVersion)
        }
        guard let installDate = context.installDate,
              context.now.timeIntervalSince(installDate) >= TimeInterval(minimumDaysSinceInstall * 86_400)
        else { return .skip(.tooSoonAfterInstall) }
        guard context.onboardingCompleted else { return .skip(.onboarding) }
        guard !context.sheetShowing else { return .skip(.sheetShowing) }
        return .ask
    }

    /// Condition 6: a launch with any argument after the executable's path, or an XCTest
    /// environment (a hosted test's host app, an XCUITest run).
    static func isAutomatedRun(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.dropFirst().contains(where: { $0.hasPrefix("-") }) { return true }
        return xcTestEnvironmentKeys.contains { environment[$0] != nil }
    }

    /// Set by XCTest in the process it tests.
    static let xcTestEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
}
