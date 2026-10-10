import Foundation
import SwiftData
import WidgetKit

/// What every check-in made in the app's process does once it is saved (RELEASE-1.4.0.md D3, D4):
/// Today's row and count ring, Siri's "Complete a Habit" (`CompleteHabitIntent`), and a reminder's
/// Mark Done or Add 1 (`NotificationActionHandler`). One helper, so a new check-in path cannot do
/// half of it — before 1.4.0 the intent reloaded the widget but never set the badge.
///
/// - The widget timelines reload.
/// - The habit's pending snooze is cancelled and its delivered banners are withdrawn: both ask for
///   what has just been done. A check-in made elsewhere (the widget's process, another device) is
///   caught later by `NotificationService.refreshAfterDataChange`.
/// - A background refresh is submitted, so a check-in made just before the app is suspended still
///   reaches the server (D5).
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
            // A no-op until the background-sync workstream (W3) lands
            // `BackgroundRefresh.schedule(reason:)` with its check-in reason (D5).
            submitRefresh: {})
    }

    /// After `habitID`'s check-in was saved in `container`. Posting `.habitDataChanged` stays with
    /// the caller: Today's save already reaches StrideApp's observer as a `didSave`.
    @MainActor
    func afterCheckIn(habitID: UUID, container: ModelContainer) async {
        reloadWidgets()
        cancelSnooze(habitID)
        withdrawDelivered(habitID)
        submitRefresh()
        await updateBadge(container)
    }

    /// Fire and forget, for a caller that cannot wait — Today's buttons. A Task on the main actor,
    /// so the work runs on the next turn, in order with the check-ins before and after it.
    @MainActor
    static func afterCheckIn(habitID: UUID, container: ModelContainer) {
        let effects = live
        Task { @MainActor in
            await effects.afterCheckIn(habitID: habitID, container: container)
        }
    }
}
