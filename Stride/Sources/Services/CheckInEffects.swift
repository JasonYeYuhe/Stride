import Foundation
import SwiftData
import WidgetKit

/// What every check-in made in the app's process does once it is saved (RELEASE-1.4.0.md D3, D4):
/// Today's row and count ring, Siri's "Complete a Habit" (`CompleteHabitIntent`), and a reminder's
/// Mark Done or Add 1 (`NotificationActionHandler`). One helper, so a new check-in path cannot do
/// half of it — before 1.4.0 the intent reloaded the widget but never set the badge.
///
/// - The widget timelines reload.
/// - The habit's pending snooze is cancelled and its delivered banners are withdrawn, when the
///   check-in's day is the one they ask for (`endsReminders`). A check-in made elsewhere (the
///   widget's process, another device) is caught later by `NotificationService.refreshAfterDataChange`.
/// - A background refresh is submitted, so a check-in made just before the app is suspended still
///   reaches the server (D5). A backfilled day too: it has to reach the server as much as today.
/// - The badge, last, awaited: the action handler's process can be suspended as soon as it returns.
///
/// Values, not calls on the singletons, so the hosted tests hand the handler recording closures
/// and never touch the host app's widget, badge or notification store.
struct CheckInEffects {
    var reloadWidgets: @MainActor () -> Void
    var updateBadge: @MainActor (ModelContainer) async -> Void
    var cancelSnooze: @MainActor (UUID) -> Void
    var withdrawDelivered: @MainActor (UUID) -> Void
    var submitRefresh: @MainActor () -> Void

    /// The app's own.
    static var live: CheckInEffects {
        CheckInEffects(
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
            updateBadge: { await NotificationService.shared.updateBadgeAndWait(modelContainer: $0) },
            cancelSnooze: { NotificationService.shared.cancelSnooze(for: $0) },
            withdrawDelivered: { NotificationService.shared.withdrawDeliveredReminders(for: $0) },
            submitRefresh: {
                #if os(iOS)
                // While a session is stored (D5). Through the one entry point, which submits off
                // the main thread and logs `refresh submit check-in: …`. Also the reminder
                // action's submit (D4 step 4): the handler's environment uses these effects.
                BackgroundRefresh.scheduleIfSignedIn(reason: .checkIn)
                #endif
                // The Mac has no background refresh: a reminder's action syncs under its own
                // ProcessInfo activity, and the app syncs on activation.
            })
    }

    /// After `habitID`'s check-in was saved in `container`. Posting `.habitDataChanged` stays with
    /// the caller: Today's save already reaches StrideApp's observer as a `didSave`.
    ///
    /// `endsReminders`: whether the check-in's day is one the habit's snooze and banners can be
    /// asking for (`ReminderDay.isCreditable`). Always true for a reminder's own action, whose day
    /// is the banner's or today by construction, and for Siri, which credits today. Today's row
    /// works out the day it was given: the week strip backfills the past six days, and a backfill
    /// must not cancel the snooze the user asked for today, or withdraw today's banner, while
    /// today is still not done. Nothing would put either back: `refreshAfterDataChange` restores
    /// nothing, and it only cancels for habits done TODAY.
    @MainActor
    func afterCheckIn(habitID: UUID, container: ModelContainer, endsReminders: Bool) async {
        reloadWidgets()
        if endsReminders {
            cancelSnooze(habitID)
            withdrawDelivered(habitID)
        }
        submitRefresh()
        await updateBadge(container)
    }

    /// `endsReminders` for a check-in on `date`, a local date such as Today's week strip hands its
    /// rows. It is keyed as `HabitCheckIn` keys it (`dayKey(for:)`), then asked of the resolver: is it
    /// today, or yesterday within the late-night grace?
    static func endsReminders(checkingIn date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        ReminderDay.isCreditable(HabitCalendar.dayKey(for: date, localCalendar: calendar), at: now, calendar: calendar)
    }

    /// Fire and forget, for a caller that cannot wait — Today's buttons. A Task on the main actor,
    /// so the work runs on the next turn, in order with the check-ins before and after it.
    @MainActor
    static func afterCheckIn(habitID: UUID, container: ModelContainer, endsReminders: Bool) {
        let effects = live
        Task { @MainActor in
            await effects.afterCheckIn(habitID: habitID, container: container, endsReminders: endsReminders)
        }
    }
}
