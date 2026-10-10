import Foundation
import SwiftData
import UserNotifications
import os.log
#if os(iOS)
import UIKit
#endif

/// Answers a reminder's Mark Done, Add 1 and Snooze 1 Hour (RELEASE-1.4.0.md D4): the
/// `UNUserNotificationCenter` delegate, set in `StrideApp.init` on both platforms.
///
/// - **Set before launch finishes, held strongly.** A button on a lock-screen banner launches a
///   terminated app in the background with no scene, and the response goes to whoever is the
///   delegate by the end of launch; the center holds its delegate weakly (`shared` is what keeps
///   this alive). A `.task` on the window is too late, and never runs without a scene.
/// - **`didReceive` only.** No `willPresent`, so a reminder that fires while Stride is frontmost
///   stays unshown, as before 1.4.0 (acceptance 4).
/// - **A thin shim.** `UNNotificationResponse` has no public initializer, so everything after the
///   route is `perform(route:delivered:responded:)`, over an injected `Environment`: the hosted
///   tests drive it with an in-memory store and recording closures.
///
/// The write never deletes. `NotificationRouter` says only "check in" or "snooze", never what to
/// write; `HabitCheckIn.fromReminder` chooses by the habit's kind NOW (a banner keeps the category
/// it was scheduled with, and a kind can change since), and for a yes/no habit it can only check,
/// never un-check. So no tombstone is ever queued from here.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    /// The one the app installs. The center's `delegate` is weak: this reference is what keeps it.
    @MainActor static let shared = NotificationActionHandler(environment: .live)

    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Notifications")

    /// Everything the handler reaches outside itself, so a hosted test reaches none of the host
    /// app's: its store, widgets, badge, notification store or server.
    struct Environment {
        /// The store to write to — the app's one container (`SharedModelContainer.opened`), never
        /// opened here. nil when the launch could not open it: nothing is written.
        var container: @MainActor () -> ModelContainer?
        /// Widgets, snooze, banners, refresh submit and badge after the write (`CheckInEffects`).
        var effects: CheckInEffects
        /// Pushes the check-in, inside the background task taken before `didReceive` returns.
        var sync: @MainActor (ModelContainer) async -> Void
        /// Snooze 1 Hour, for the day `ReminderDay.resolve` gave.
        var scheduleSnooze: @MainActor (Habit, Date) -> Void
        var now: @MainActor () -> Date
        var calendar: @MainActor () -> Calendar

        static var live: Environment {
            Environment(
                container: { SharedModelContainer.opened },
                effects: .live,
                sync: { container in
                    // The record must be pushed even when a sync was already running when it was
                    // written: that run planned its push before the write and returns false to a
                    // second caller rather than queueing it (SyncService.sync). So wait it out,
                    // then run our own (design review, "action-write-dispatch-and-seams").
                    // `.background`: inside the owner's backoff window it does nothing, and a run
                    // the system cuts short leaves no backoff or error behind (D5).
                    await SyncService.shared.waitUntilIdle()
                    guard !Task.isCancelled else { return }
                    await SyncService.shared.sync(context: container.mainContext, trigger: .background)
                },
                scheduleSnooze: { habit, day in NotificationService.shared.scheduleSnooze(for: habit, day: day) },
                now: { Date() },
                calendar: { .current })
        }
    }

    /// What a response came to. For the tests and the log; the system is told nothing.
    enum Outcome: Equatable {
        /// Not a check-in or a snooze: the default tap, a dismiss, a 1.3.x or global reminder.
        case ignored
        /// The launch could not open the store.
        case storeUnavailable
        /// The habit is gone (deleted, or re-made under new ids) or archived.
        case noHabit
        /// Saved one check-in on this day.
        case checkedIn(day: Date)
        /// Nothing to write: a yes/no habit already done that day. Mark Done twice writes once.
        case alreadyDone(day: Date)
        /// Nothing was saved: the save failed — or, never expected, the write would have deleted a
        /// record. The context was rolled back and nothing else happened.
        case saveFailed
        /// A snooze was handed to the scheduler, carrying this day.
        case snoozed(day: Date)
    }

    let environment: Environment

    init(environment: Environment) {
        self.environment = environment
        super.init()
    }

    /// StrideApp.init, on both platforms: the delegate and the categories, before launch finishes.
    @MainActor
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
        NotificationService.shared.registerCategories()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The async form: the system is told the response is handled when this returns, so
    /// everything that must happen before the process may be suspended — the write, the badge,
    /// taking the background task for the sync — happens before it does.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // Read here, off the main actor: the response is not Sendable, and the route and two dates
        // are all that cross.
        let content = response.notification.request.content
        let route = NotificationRouter.route(actionIdentifier: response.actionIdentifier,
                                             categoryIdentifier: content.categoryIdentifier,
                                             userInfo: content.userInfo)
        guard route != .none else { return }
        let delivered = response.notification.date
        await respond(to: route, delivered: delivered)
    }

    @MainActor
    private func respond(to route: NotificationRoute, delivered: Date) async {
        let outcome = await perform(route: route, delivered: delivered, responded: environment.now())
        Self.logger.notice("reminder action: \(String(describing: outcome), privacy: .public)")
    }

    // MARK: - The action

    /// One routed response. `delivered` is `UNNotification.date`, `responded` now; which day is
    /// credited is `ReminderDay.resolve`'s — the banner's day or today, never a third, and never
    /// through the idempotent `HabitCalendar.dayKey(for:)` (the design review's blocker: a 20:00 EDT
    /// reminder fires at exactly 00:00Z of the next date).
    @MainActor
    @discardableResult
    func perform(route: NotificationRoute, delivered: Date, responded: Date) async -> Outcome {
        let habitID: UUID
        let carriedDay: Date?
        switch route {
        case .none:
            return .ignored
        case .checkIn(let id, let day), .snooze(let id, let day):
            habitID = id
            carriedDay = day
        }
        guard let container = environment.container() else { return .storeUnavailable }
        let day = ReminderDay.resolve(carriedDay: carriedDay, deliveredAt: delivered, respondedAt: responded,
                                      calendar: environment.calendar())

        // A fresh context, as the Siri intent writes, never `mainContext`: its save would also
        // commit whatever a view holds unsaved there (a half-edited habit sheet), and an in-flight
        // sync's rollback on that context could discard this check-in.
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Habit>(predicate: #Predicate<Habit> { $0.id == habitID })
        guard let habit = (try? context.fetch(descriptor))?.first, !habit.isArchived else { return .noHabit }

        if case .snooze = route {
            environment.scheduleSnooze(habit, day)
            return .snoozed(day: day)
        }

        // The write and its save in this one main-actor turn — no await between them, so nothing
        // else on the main actor (a sync's reconcile, its rollback) can run in the middle.
        guard let result = HabitCheckIn.fromReminder(habit, on: day, in: context) else {
            return .alreadyDone(day: day)
        }
        guard result.deletedRecordID == nil else {
            // `fromReminder` cannot delete (it asserts the same); were it ever to, the deletion is
            // not saved and no tombstone is queued — one tap must not un-check a day everywhere.
            assertionFailure("a reminder's check-in deleted a record")
            context.rollback()
            Self.logger.fault("reminder action: the check-in would have deleted a record")
            return .saveFailed
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            Self.logger.error("reminder action: the save failed")
            return .saveFailed
        }

        // Today, the Stats card and anything else observing it redraw — in a scene-less background
        // launch there are none, and the effects below do not depend on them.
        NotificationCenter.default.post(name: .habitDataChanged, object: nil)
        await environment.effects.afterCheckIn(habitID: habitID, container: container)
        syncInBackground(container)
        return .checkedIn(day: day)
    }

    /// The push, in a finite-length background task taken now — before `didReceive` returns, after
    /// which the system may suspend the process (D4 steps 2–5). The Mac takes a ProcessInfo
    /// activity instead, so App Nap does not throttle the run: activation is its only other sync
    /// trigger, and a Mac user acting on a banner may not bring Stride forward for days.
    @MainActor
    private func syncInBackground(_ container: ModelContainer) {
        let sync = environment.sync
        BackgroundRun.start(named: "Stride reminder action") {
            await sync(container)
        }
    }
}

/// One piece of work that must finish while the app is not in front: `beginBackgroundTask` on
/// iOS, a `ProcessInfo` activity on the Mac. Ended once — when the work returns, or on iOS when
/// the time is up, which also cancels the work (a cancelled background sync records no backoff
/// and no error, `SyncService.Trigger.background`).
@MainActor
private final class BackgroundRun {
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #else
    private var activity: NSObjectProtocol?
    #endif
    private var work: Task<Void, Never>?

    static func start(named name: String, _ body: @escaping @MainActor () async -> Void) {
        let run = BackgroundRun()
        #if os(iOS)
        run.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // UIKit calls this on the main thread (the handler is typed main-actor); asserted, so a
            // change in that would trap here rather than race `end()`.
            MainActor.assertIsolated()
            run.work?.cancel()
            run.end()
        }
        #else
        run.activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: name)
        #endif
        run.work = Task { @MainActor in
            await body()
            run.end()
        }
    }

    private func end() {
        #if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #else
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        #endif
    }
}
