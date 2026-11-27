import Foundation
import UserNotifications
import SwiftData
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The part of `UNUserNotificationCenter` that plans reminders: add, remove, list — and, since
/// 1.3.0, the authorization status and the request, because whether a reminder is scheduled at
/// all now depends on them. A seam for StrideAppTests, which records what would be scheduled
/// instead of filling the host app's real pending-notification store (and iOS's 64-request
/// limit) with test reminders, and which plays the user's answer to the system prompt instead
/// of raising a real one.
///
/// 1.4.0 (RELEASE-1.4.0.md D3, D4) adds what the reminder actions need: the categories that put
/// Mark Done / Add 1 / Snooze 1 Hour on a banner, the DELIVERED banners (a schedule or a removal
/// of pending requests never touches one already in Notification Center), and the badge, which
/// went around the seam to `UNUserNotificationCenter.current()` until now — so no test could
/// see it, and every hosted run set the host app's real badge.
protocol NotificationScheduling: AnyObject, Sendable {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void)
    /// Replaces the whole set, as the center does: every category the app has goes in each call.
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    /// `UNNotification` has no public initializer either, so — as with the status below — the seam
    /// hands back the fields the app reads (`DeliveredNotification`), not objects a test could
    /// never build.
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([DeliveredNotification]) -> Void)
    func setBadgeCount(_ newBadgeCount: Int) async throws
    /// `UNNotificationSettings` has no public initializer, so the seam asks for the one field
    /// the app reads rather than the settings object a test could never build.
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

/// `requestAuthorization(options:)`, `setNotificationCategories`, `removeDeliveredNotifications`
/// and `setBadgeCount` are the center's own methods; the status and the delivered list need a
/// wrapper.
extension UNUserNotificationCenter: NotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([DeliveredNotification]) -> Void) {
        // The center's own method, whose block takes `[UNNotification]`: typed explicitly so this
        // call can never resolve to the overload it is in.
        let center: UNUserNotificationCenter = self
        center.getDeliveredNotifications { (notifications: [UNNotification]) in
            completionHandler(notifications.map(DeliveredNotification.init))
        }
    }
}

/// A banner in Notification Center, as the app reads it: what to withdraw, and when it came.
struct DeliveredNotification: Equatable, Sendable {
    var identifier: String
    /// `UNNotification.date`: when it was delivered.
    var date: Date
    var categoryIdentifier: String
    /// `userInfo["habitId"]` in the one form the router accepts (`NotificationRouter.habitID`),
    /// else nil — a global reminder, a 1.3.x banner.
    var habitID: UUID?

    init(identifier: String, date: Date, categoryIdentifier: String, habitID: UUID?) {
        self.identifier = identifier
        self.date = date
        self.categoryIdentifier = categoryIdentifier
        self.habitID = habitID
    }

    init(_ notification: UNNotification) {
        let content = notification.request.content
        self.init(identifier: notification.request.identifier, date: notification.date,
                  categoryIdentifier: content.categoryIdentifier,
                  habitID: NotificationRouter.habitID(from: content.userInfo))
    }
}

/// What the habit sheet needs to know before it schedules a reminder: may it fire?
enum ReminderPermission: Equatable {
    /// Authorized, provisional or ephemeral — the system will deliver it.
    case allowed
    /// The user said no, now or earlier. Only Settings → Stride can change that; asking again
    /// shows nothing.
    case denied
}

/// Manages daily habit reminder notifications.
@MainActor
final class NotificationService {
    #if DEBUG
    /// The app's instance — or, in StrideAppTests only, the test's own over a recording center
    /// while a test drives code that reads `shared`: a language change re-registers the action
    /// titles through it (`languageDidChange`), and that must not reach the host app's real
    /// categories and pending reminders. The `SyncService.shared` pattern.
    static var shared: NotificationService { testOverride ?? live }
    static var testOverride: NotificationService?
    private static let live = NotificationService()
    #else
    static let shared = NotificationService()
    #endif

    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Notifications")

    private let center: NotificationScheduling
    private let reminderIdentifierPrefix = "stride.daily.reminder"
    private let morningIdentifier = "stride.daily.morning"

    // MARK: - UserDefaults Keys (synced via App Group)

    private let defaults: UserDefaults

    var isReminderEnabled: Bool {
        get { defaults.bool(forKey: "reminderEnabled") }
        set {
            defaults.set(newValue, forKey: "reminderEnabled")
            if newValue {
                scheduleReminders()
            } else {
                removeAllReminders()
            }
        }
    }

    var reminderHour: Int {
        get {
            let val = defaults.integer(forKey: "reminderHour")
            return val == 0 && !defaults.bool(forKey: "reminderHourSet") ? 20 : val
        }
        set {
            defaults.set(newValue, forKey: "reminderHour")
            defaults.set(true, forKey: "reminderHourSet")
            if isReminderEnabled { scheduleReminders() }
        }
    }

    var reminderMinute: Int {
        get { defaults.integer(forKey: "reminderMinute") }
        set {
            defaults.set(newValue, forKey: "reminderMinute")
            if isReminderEnabled { scheduleReminders() }
        }
    }

    var reminderTime: Date {
        get {
            var components = DateComponents()
            components.hour = reminderHour
            components.minute = reminderMinute
            return Calendar.current.date(from: components) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderHour = components.hour ?? 20
            reminderMinute = components.minute ?? 0
        }
    }

    var isMorningMotivationEnabled: Bool {
        get { defaults.bool(forKey: "morningMotivationEnabled") }
        set {
            defaults.set(newValue, forKey: "morningMotivationEnabled")
            if newValue && isReminderEnabled {
                scheduleMorningMotivation()
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [morningIdentifier])
            }
        }
    }

    private convenience init() {
        self.init(
            center: UNUserNotificationCenter.current(),
            // The one App Group accessor, which the Mac test variant turns off (STRIDE_MAC_VARIANT).
            defaults: SharedModelContainer.appGroupDefaults ?? .standard
        )
    }

    /// For StrideAppTests: a recording center and a throwaway defaults suite. The app only ever
    /// uses `shared`, built by the private initializer above with the real center and app group.
    init(center: NotificationScheduling, defaults: UserDefaults) {
        self.center = center
        self.defaults = defaults
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func checkPermission() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }

    /// Resolves whether reminders may fire, raising the system prompt only when iOS has never
    /// asked. Callers await this before they schedule and before their sheet goes away, so the
    /// prompt appears over the screen where the user switched the reminder on.
    ///
    /// Until 1.3.0 the only caller of `requestPermission()` was the Settings "Daily Reminder"
    /// toggle. A reminder switched on in the New Habit sheet on a fresh install was queued while
    /// the status was still `.notDetermined` and never delivered — and nothing said so.
    ///
    /// When the prompt is answered "Allow", every reminder-on habit already in `container` is
    /// scheduled at that moment, and the badge is set (`permissionGranted`). The launch pass (`rescheduleAllHabitReminders`) ran while the
    /// status was undecided and scheduled nothing that could fire, so without this the habits
    /// that came by sync or restore, or were saved before the grant, stayed silent until the
    /// next cold launch — on iOS, possibly days — and only the habit being saved worked.
    func ensureReminderPermission(schedulingExistingIn container: ModelContainer? = nil) async -> ReminderPermission {
        switch await checkPermission() {
        case .notDetermined:
            guard await requestPermission() else { return .denied }
            if let container { permissionGranted(schedulingExistingIn: container) }
            return .allowed
        case .denied:
            return .denied
        default:
            // .authorized, .provisional, .ephemeral (and any future case) deliver.
            return .allowed
        }
    }

    /// Right after the user allowed notifications — the habit sheet's prompt
    /// (`ensureReminderPermission`) or Settings' Daily Reminder switch — what was waiting on the
    /// permission:
    /// - every reminder-on habit already in the store, which the launch pass scheduled nothing
    ///   for while the status was undecided;
    /// - the badge (the Dock tile on the Mac). Nothing set it at the grant: it waited for the next
    ///   save, activation or midnight, so on a Mac left in front it could stay blank for hours
    ///   (RELEASE-1.4.0.md's follow-ups, Mac checklist item 12);
    /// - the Daily Reminder, when it is on (v2 review, finding 1). A restore to a new phone brings
    ///   `reminderEnabled` back with nothing pending and the permission undecided, so the launch
    ///   skipped it; allowed later at the habit sheet's prompt, nothing added it until the next
    ///   cold launch. First, so the habits' pass below finds it pending.
    func permissionGranted(schedulingExistingIn container: ModelContainer) {
        if isReminderEnabled { scheduleReminders(modelContainer: container) }
        scheduleAllHabitReminders(modelContainer: container)
        updateBadge(modelContainer: container)
    }

    /// The Save path of the habit sheet: permission first (asking if iOS never has), then the
    /// reminder — or, when notifications are off, no request at all. An add under `.denied` is
    /// refused by the system anyway; not making it keeps the outcome visible to the caller, which
    /// shows the "Notifications are disabled" footer instead of pretending the reminder is set.
    /// The habit keeps `reminderEnabled`, so `rescheduleAllHabitReminders` schedules it at the
    /// first launch after the user allows notifications in Settings → Stride.
    @discardableResult
    func enableHabitReminder(for habit: Habit) async -> ReminderPermission {
        // The habit's own container: a saved habit is in it, so a grant here schedules this
        // habit along with the rest (the habit sheet normally settled permission before saving).
        let permission = await ensureReminderPermission(schedulingExistingIn: habit.modelContext?.container)
        if permission == .allowed {
            scheduleHabitReminder(for: habit)
        } else {
            // A request left over from an earlier time (an edit that moved it) must not linger
            // to fire at the old time the moment notifications are switched back on.
            removeHabitReminder(for: habit.id)
        }
        return permission
    }

    // MARK: - Schedule

    /// The Daily Reminder, replaced whole: what the plan wants now is added with new text, then
    /// every other id it can have (`ReminderPlan.allEveningIdentifiers` — the bare one, and a
    /// perfect day's overlay, D4) goes. Added before removed (v2 review, finding 2): an add under an
    /// id already pending replaces it, and a write cut off in between leaves the reminder
    /// over-firing, never gone. Switching it on, a new time, a language change and the launch. On
    /// a perfect day whose reminder is still ahead that is the overlay, read from `modelContainer`
    /// — or, when none is given (Settings' switch and time picker), from the store of the last full
    /// pass; with neither, the bare request, which the next full pass overlays.
    func scheduleReminders(modelContainer: ModelContainer? = nil) {
        let planned: [ReminderPlan.Request]
        if let container = modelContainer ?? lastPlannedContainer,
           let plan = makePlan(in: container, now: Date(), calendar: .current) {
            planned = plan.result.evening
        } else {
            planned = [ReminderPlan.eveningBase(ReminderPlan.Evening(hour: reminderHour, minute: reminderMinute))]
        }
        let content = eveningContent()
        for request in planned {
            center.add(Self.notificationRequest(request, content: content), withCompletionHandler: nil)
        }
        let plannedIDs = Set(planned.map(\.identifier))
        center.removePendingNotificationRequests(
            withIdentifiers: ReminderPlan.allEveningIdentifiers.filter { !plannedIDs.contains($0) })

        if isMorningMotivationEnabled {
            scheduleMorningMotivation()
        }
    }

    /// The Daily Reminder's banner: one random line, shared by every request of an overlay.
    private func eveningContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = appLocalized("Stride Reminder 🏃")
        content.body = randomEveningMessage()
        content.sound = .default
        return content
    }

    private func scheduleMorningMotivation() {
        center.removePendingNotificationRequests(withIdentifiers: [morningIdentifier])

        let content = UNMutableNotificationContent()
        content.title = appLocalized("Good Morning! ☀️")
        content.body = randomMorningMessage()
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = 8
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: morningIdentifier, content: content, trigger: trigger)

        center.add(request, withCompletionHandler: nil)
    }

    /// The Daily Reminder off: every evening id (the overlay's too) and the morning one.
    func removeAllReminders() {
        center.removePendingNotificationRequests(withIdentifiers: ReminderPlan.allEveningIdentifiers + [morningIdentifier])
    }

    // MARK: - Reminder actions (1.4.0)

    /// The two reminder categories (RELEASE-1.4.0.md D4), one per habit kind because the check-in
    /// button's title differs — Mark Done on a yes/no habit, Add 1 on a count habit — and a
    /// category's buttons are fixed. What the button WRITES is not the category's business: the
    /// handler chooses by the habit's kind at the moment of the tap (`HabitCheckIn.fromReminder`),
    /// because a delivered banner keeps the category it was scheduled with.
    ///
    /// No `.foreground`: the point is a check-in from the lock screen without opening the app. No
    /// `.authenticationRequired`: the write is one check-in, on the habit the banner names, that can
    /// never un-check anything — what the widget on the same lock screen does without an unlock.
    /// Titles in the in-app language (`appLocalized`): the system shows them as given and keeps them
    /// until the next registration, so a language change registers again (`languageDidChange`).
    static func reminderCategories() -> Set<UNNotificationCategory> {
        let snooze = UNNotificationAction(identifier: NotificationRouter.snoozeAction,
                                          title: appLocalized("Snooze 1 Hour"), options: [])
        let markDone = UNNotificationAction(identifier: NotificationRouter.markDoneAction,
                                            title: appLocalized("Mark Done"), options: [])
        let addOne = UNNotificationAction(identifier: NotificationRouter.addOneAction,
                                          title: appLocalized("Add 1"), options: [])
        return [
            UNNotificationCategory(identifier: NotificationRouter.binaryCategory, actions: [markDone, snooze],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationRouter.countCategory, actions: [addOne, snooze],
                                   intentIdentifiers: [], options: []),
        ]
    }

    /// At every launch, from StrideApp.init (`NotificationActionHandler.install`) — before a
    /// background launch made for an action could need them — and after a language change.
    func registerCategories() {
        center.setNotificationCategories(Self.reminderCategories())
    }

    /// The category a habit's reminder is scheduled with: the one for its kind now.
    static func category(for kind: HabitKind) -> String {
        switch kind {
        case .binary: return NotificationRouter.binaryCategory
        case .count: return NotificationRouter.countCategory
        }
    }

    /// The in-app language changed (LanguageManager). Everything the system holds as plain text is
    /// in the old one until it is handed over again: the action titles, and the title and body of
    /// every pending reminder, which `appLocalized` resolved when it was scheduled. Both would
    /// otherwise keep the old language until the next cold launch registers and reschedules them —
    /// on iOS, possibly days. No prune: that is the launch pass's alone (`scheduleAllHabitReminders`
    /// says why).
    func languageDidChange(modelContainer: ModelContainer?) {
        registerCategories()
        if isReminderEnabled { scheduleReminders(modelContainer: modelContainer) }
        if let modelContainer { scheduleAllHabitReminders(modelContainer: modelContainer) }
    }

    // MARK: - Per-Habit Reminders

    /// One habit's reminder: the habit sheet's save, a restore from the archive.
    ///
    /// The request budget (`ReminderPlan.requestBudget`) and the overlays are properties of ALL the
    /// reminders (RELEASE-1.5.0.md D4, Gemini A2), so the habit is planned together with the rest
    /// of its store — the full plan, with this habit as the caller holds it, saved or not — and
    /// every habit whose requests changed is replaced. Should this habit take the total over the
    /// budget, every specificDays habit falls back to its one daily trigger, the others as well,
    /// or their weekday triggers would still crowd iOS's 64 and some reminder would silently never
    /// fire. A habit in no store is planned alone, in its base shape.
    func scheduleHabitReminder(for habit: Habit) {
        guard let settings = ReminderPlan.Settings(habit) else {
            // Off or archived: nothing of it may fire, a snooze included — the launch prune keeps a
            // snooze only for a habit whose reminder is on.
            center.removePendingNotificationRequests(withIdentifiers: ReminderPlan.allIdentifiers(for: habit.id))
            return
        }
        if let container = habit.modelContext?.container,
           let plan = makePlan(in: container, holding: habit, now: Date(), calendar: .current) {
            apply(plan)
            return
        }
        let groups = [group(for: habit, requests: ReminderPlan.plan([settings]).requests)]
        apply(makingGroups: { _ in groups })
    }

    /// A habit's reminder banner (RELEASE-1.4.0.md D4):
    /// - the category of its kind, for the check-in button's title;
    /// - `userInfo["habitId"]`, all the handler acts on. A 1.3.x request has no userInfo and routes
    ///   to nothing; the first 1.4.0 launch's reschedule replaces it;
    /// - `threadIdentifier` = the habit, so one habit's banners stack together.
    private func reminderContent(for habit: Habit) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(habit.emoji) \(habit.name)"
        content.body = appLocalized("Time to work on your habit!")
        content.sound = .default
        content.categoryIdentifier = Self.category(for: habit.habitKind)
        content.userInfo = [NotificationRouter.UserInfoKey.habitID: habit.id.uuidString]
        content.threadIdentifier = habit.id.uuidString
        return content
    }

    /// Reminder off, archive, delete: every reminder shape, the overlay's one-shots and the
    /// snooze, pending AND delivered. A banner already in Notification Center is not a pending
    /// request; left there, it kept offering Mark Done for a habit whose reminder was just
    /// switched off, or that is gone.
    func removeHabitReminder(for habitId: UUID) {
        let identifiers = ReminderPlan.allIdentifiers(for: habitId)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Runs at launch. Re-adds every reminder that should exist AND removes every habit reminder
    /// that shouldn't.
    ///
    /// Reminders are repeating triggers that live in the system's notification store across
    /// relaunches. This used to only add, never prune, so a reminder for a habit that was deleted
    /// or archived fired every day forever — for a habit with no row left to open and switch it
    /// off. Deleting or archiving in Settings now removes it directly, but a habit deleted or
    /// archived on ANOTHER device arrives through sync (Shared/SyncReconciler), which cannot reach
    /// this service; this prune is what cleans those up. Orphans also eat into iOS's 64-request
    /// limit, silently displacing reminders that should fire.
    ///
    /// 1.4.0: what to keep is the planner's (`ReminderPlan.Result.keep`). 1.5.0 (Gemini A1): every
    /// id a reminder-on habit can have, not only today's shape, because the keep set is computed
    /// before the center answers and the widget may write a habit's overlay in between. A live
    /// habit's stale shapes are its own replace step's (`apply`).
    func rescheduleAllHabitReminders(modelContainer: ModelContainer) {
        // Don't prune on a failed fetch: an empty "keep" set would delete every reminder.
        guard let plan = scheduleAllHabitReminders(modelContainer: modelContainer) else { return }
        pruneOrphans(keeping: plan.keep)
    }

    /// `rescheduleAllHabitReminders`, returning once the replace and the prune have run: for a
    /// background run (BackgroundSync — the refresh, and on iOS a reminder action's sync), whose
    /// process can be suspended as soon as its task is completed, taking a prune still waiting on
    /// the center's answer with it.
    ///
    /// `mayPrune` is asked once the center has answered, right before anything is removed, and in
    /// the same main-actor turn as the removal: no habit sheet's save (main actor) can come between
    /// the answer and the remove. BackgroundSync passes "the app is still in the background". The
    /// keep set was computed before the center was asked; since 1.5.0 it names every id a
    /// reminder-on habit can have, so only a habit whose reminder was switched on in that window
    /// could lose its new request — the same race `scheduleAllHabitReminders` documents for the
    /// launch pass (verification, second fix pass: the state was read once, before the wait).
    /// False: nothing is removed; the next launch's pass prunes.
    func rescheduleAllHabitRemindersAndWait(modelContainer: ModelContainer,
                                            mayPrune: @MainActor () -> Bool = { true }) async {
        guard let plan = makePlan(in: modelContainer, now: Date(), calendar: .current) else { return }
        await applyAndWait(plan)
        let center = self.center
        // Identifiers only: the answer crosses from the center's queue back to the main actor.
        let pending: [String] = await withCheckedContinuation { answered in
            center.getPendingNotificationRequests { requests in
                answered.resume(returning: requests.map(\.identifier))
            }
        }
        guard mayPrune() else {
            Self.logger.notice("reminder prune skipped: the app came forward while the center answered")
            return
        }
        let orphans = ReminderPlan.prune(pending, keep: plan.result.keep)
        if !orphans.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: orphans)
        }
    }

    /// Removes every pending habit request the planner did not keep — from the center's callback,
    /// off the main actor. The launch pass's: nothing waits for it.
    private func pruneOrphans(keeping keep: Set<String>) {
        let center = self.center
        center.getPendingNotificationRequests { requests in
            let orphans = ReminderPlan.prune(requests.map(\.identifier), keep: keep)
            if !orphans.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: orphans)
            }
        }
    }

    /// The full plan (RELEASE-1.5.0.md D4) over the store: every reminder-on, unarchived habit and
    /// the Daily Reminder, each habit's quiet days and today's perfect day read through
    /// `DailyProgress`; then every habit whose pending requests differ from the plan is replaced
    /// (`apply`). Returns the plan; nil when the fetch failed. No prune — the launch pass prunes.
    /// That makes it safe while the habit sheet is still saving: a prune computed now would find
    /// the sheet's own reminder, added a moment later, missing from its "keep" set and remove it
    /// (the real center answers `getPendingNotificationRequests` asynchronously).
    ///
    /// 1.4.0: also after a successful foreground sync (StrideApp) and a language change. A kind,
    /// a day mask, a time or a name pulled from another device reaches the triggers and the
    /// content before the next cold launch: the comparison reads them all.
    @discardableResult
    func scheduleAllHabitReminders(modelContainer: ModelContainer, now: Date = Date(),
                                   calendar: Calendar = .current) -> ReminderPlan.Result? {
        guard let plan = makePlan(in: modelContainer, now: now, calendar: calendar) else { return nil }
        apply(plan)
        return plan.result
    }

    /// `scheduleAllHabitReminders`, returning once the center has every add: a reminder action's
    /// check-in (`CheckInEffects.live`), whose process can be suspended as soon as it returns.
    func scheduleAllHabitRemindersAndWait(modelContainer: ModelContainer, now: Date = Date(),
                                          calendar: Calendar = .current) async {
        guard let plan = makePlan(in: modelContainer, now: now, calendar: calendar) else { return }
        await applyAndWait(plan)
    }

    // MARK: - The full plan (1.5.0, D4)

    /// What one pass read from the store: today's state of every unarchived habit (the badge, the
    /// perfect day, what is done) and the plan made from it.
    private struct StorePlan {
        /// Every unarchived habit; `holding` replaced by the caller's.
        let habits: [Habit]
        /// By habit id, built through today.
        let stats: [UUID: HabitStats]
        let today: ReminderPlan.Today
        /// Today over every unarchived habit (`DailyProgress`).
        let progress: DailyProgress
        /// The reminder-on habits, in the order they were planned.
        let reminderHabits: [Habit]
        /// The planner's inputs, so the replace can plan again once it knows the pending snoozes
        /// (`PassInput`, finding 5).
        let settings: [ReminderPlan.Settings]
        let evening: ReminderPlan.Evening?
        /// Planned with no snooze beyond the budget's room.
        let result: ReminderPlan.Result
        /// The archived habits' ids (the caller's held habit aside): the pass removes whatever of
        /// theirs is still pending (finding 5) — an archive synced from another device reaches no
        /// removal here, and their requests eat into iOS's 64 until the next launch's prune.
        let archivedIDs: [UUID]

        /// Habits done today (`DailyProgress.State.done`).
        var doneToday: [Habit] {
            habits.filter { stats[$0.id].map { DailyProgress.state(of: $0, on: today.dayKey) == .done } ?? false }
        }
    }

    /// The store the last full pass read: `scheduleReminders()` without a container plans the
    /// Daily Reminder's perfect-day overlay from it. The app has one container for its life.
    private var lastPlannedContainer: ModelContainer?

    /// Reads the store and plans. In a fresh context: what is saved, never what a view holds
    /// unsaved — except `holding`, the habit sheet's habit as it holds it (planned last, as the
    /// one being added). Habits are planned in their list order (`sortOrder`, then id), so a tie in
    /// the budget's overlay order does not depend on fetch order.
    private func makePlan(in container: ModelContainer, holding held: Habit? = nil,
                          now: Date, calendar: Calendar) -> StorePlan? {
        let context = ModelContext(container)
        guard var habits = unarchivedHabits(in: context) else { return nil }
        lastPlannedContainer = container
        let today = ReminderPlan.Today(now: now, calendar: calendar)
        let live = HabitStats.liveRecordIDs(of: habits, in: context)
        var stats: [UUID: HabitStats] = [:]
        for habit in habits {
            stats[habit.id] = HabitStats(habit: habit, liveRecordIDs: live, calendar: calendar, today: today.dayKey)
        }
        habits.sort { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        if let held {
            habits.removeAll { $0.id == held.id }
            stats[held.id] = nil
            if !held.isArchived {
                habits.append(held)
                stats[held.id] = HabitStats(habit: held, live: HabitStats.liveRecords(of: held),
                                            calendar: calendar, today: today.dayKey)
            }
        }
        let progress = DailyProgress(of: habits.compactMap { stats[$0.id] }, on: today.dayKey)
        let reminderHabits = habits.filter { ReminderPlan.Settings($0) != nil }
        let settings = reminderHabits.compactMap { habit in
            stats[habit.id].flatMap { ReminderPlan.settings(for: habit, stats: $0, today: today.dayKey) }
        }
        // The same read the widget makes of the App Group (`isReminderEnabled`, `reminderHour`,
        // `reminderMinute`), so both processes plan the same evening.
        let evening = ReminderPlan.Evening.stored(in: defaults, isPerfectToday: progress.isPerfect)
        let result = ReminderPlan.plan(settings, evening: evening, today: today)
        if result.fellBackToDaily {
            // Code-only, and no habit ids in a production log line (D4).
            Self.logger.notice("reminders over the request budget: specific-days habits fall back to one daily trigger")
        }
        let archived = (try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate<Habit> { $0.isArchived }))) ?? []
        let archivedIDs = archived.map(\.id).filter { id in !habits.contains { $0.id == id } }
        return StorePlan(habits: habits, stats: stats, today: today, progress: progress,
                         reminderHabits: reminderHabits, settings: settings, evening: evening, result: result,
                         archivedIDs: archivedIDs)
    }

    /// One unit of the replace: a habit's reminder (every id but its snooze), the Daily Reminder,
    /// or a removal-only group (no requests: an archived habit's ids, the evening's while it is
    /// off). Requests are built on the main actor, compared and written on the center's queue.
    private struct ReminderGroup: @unchecked Sendable {
        /// Every id the group can have: what is not planned is removed after the planned ones are
        /// added.
        let identifiers: [String]
        let requests: [UNNotificationRequest]
        /// The Daily Reminder: compared without its body (a random line each time it is built).
        /// Written only when the switch, read again right before the write, still says what the
        /// plan read (finding 4); added back when nothing of it is pending only while notifications
        /// are authorized (finding 1, `restoreEvening`).
        let isEvening: Bool
    }

    private func group(for habit: Habit, requests: [ReminderPlan.Request]) -> ReminderGroup {
        let content = reminderContent(for: habit)
        return ReminderGroup(identifiers: ReminderPlan.reminderIdentifiers(for: habit.id),
                             requests: requests.map { Self.notificationRequest($0, content: content) },
                             isEvening: false)
    }

    /// What one replace builds its groups from, in the center's callback: the plan and its inputs,
    /// so that it can be planned again once the pending snoozes are known, and every banner's
    /// content, built on the main actor (the habits' and the language's).
    ///
    /// Finding 5: `ReminderPlan.requestBudget` leaves room for four snoozes, but `scheduleSnooze`
    /// has no cap. With more pending, the overlays' budget shrinks by the extra
    /// (`ReminderPlan.plan`'s `pendingSnoozes`); the base plan is unchanged.
    private struct PassInput: @unchecked Sendable {
        let settings: [ReminderPlan.Settings]
        let evening: ReminderPlan.Evening?
        let today: ReminderPlan.Today
        let result: ReminderPlan.Result
        let content: [UUID: UNNotificationContent]
        let eveningContent: UNNotificationContent
        let archivedIDs: [UUID]

        func groups(pendingSnoozes: Int) -> [ReminderGroup] {
            let result = pendingSnoozes > ReminderPlan.snoozeRoom
                ? ReminderPlan.plan(settings, evening: evening, today: today, pendingSnoozes: pendingSnoozes)
                : self.result
            var groups: [ReminderGroup] = settings.compactMap { settings in
                guard let content = content[settings.habitID] else { return nil }
                return ReminderGroup(identifiers: ReminderPlan.reminderIdentifiers(for: settings.habitID),
                                     requests: result.requests(for: settings.habitID).map {
                                         NotificationService.notificationRequest($0, content: content)
                                     },
                                     isEvening: false)
            }
            // The Daily Reminder's group, always: on, its plan; off, a removal-only group, so an
            // evening id a widget write added after the switch went off is taken out (finding 4;
            // the prune never touches evening ids).
            groups.append(ReminderGroup(identifiers: ReminderPlan.allEveningIdentifiers,
                                        requests: result.evening.map {
                                            NotificationService.notificationRequest($0, content: eveningContent)
                                        },
                                        isEvening: true))
            groups += archivedIDs.map {
                ReminderGroup(identifiers: ReminderPlan.allIdentifiers(for: $0), requests: [], isEvening: false)
            }
            return groups
        }
    }

    private func passInput(of plan: StorePlan) -> PassInput {
        PassInput(settings: plan.settings, evening: plan.evening, today: plan.today, result: plan.result,
                  content: Dictionary(plan.reminderHabits.map { ($0.id, reminderContent(for: $0) as UNNotificationContent) },
                                      uniquingKeysWith: { first, _ in first }),
                  eveningContent: eveningContent(), archivedIDs: plan.archivedIDs)
    }

    /// A planned request as the system takes it: repeating, or the overlay's one-shot.
    /// Nonisolated: the replace builds them in the center's callback.
    nonisolated static func notificationRequest(_ planned: ReminderPlan.Request,
                                                content: UNNotificationContent) -> UNNotificationRequest {
        let trigger = UNCalendarNotificationTrigger(dateMatching: planned.dateComponents, repeats: planned.repeats)
        return UNNotificationRequest(identifier: planned.identifier, content: content, trigger: trigger)
    }

    private func apply(_ plan: StorePlan) {
        let input = passInput(of: plan)
        apply(makingGroups: { input.groups(pendingSnoozes: $0) })
    }

    private func applyAndWait(_ plan: StorePlan) async {
        let input = passInput(of: plan)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            apply(makingGroups: { input.groups(pendingSnoozes: $0) }) { done.resume() }
        }
    }

    /// `UserDefaults` is thread-safe; the replace re-reads the Daily Reminder's switch in the
    /// center's callback.
    private struct SendableDefaults: @unchecked Sendable {
        let defaults: UserDefaults
        var isEveningOn: Bool { defaults.bool(forKey: ReminderPlan.Evening.Key.enabled) }
    }

    /// The replace (D4, Gemini A1/A2): once the center has listed what is pending — in its
    /// callback, on its queue, so the comparison and the writes see the same store — the groups are
    /// built (`makeGroups`, given how many snoozes are pending), and each group whose pending
    /// requests differ from the planned ones (ids, triggers, and the text, category and habit of
    /// the banner) is replaced. A group that already matches is not touched, so a pass changes only
    /// what changed; the snooze is never in a group. Never a global remove-all: a habit sheet
    /// saving meanwhile keeps its own request.
    ///
    /// **Added before removed** (v2 review, finding 2). The planned requests go first — an add
    /// under an id already pending replaces it — and only then the group's other ids, never a
    /// planned one. A write cut off in between (a suspended process) leaves a habit with its old
    /// requests and its new ones, which over-fires; removing first left it with nothing.
    ///
    /// **The Daily Reminder** (findings 1 and 4). Its switch is read again here, right before the
    /// write: a plan made before the user switched it off does not add it back, nor one made before
    /// it was switched on remove it. On, with nothing of it pending (a restore whose permission
    /// came later, a widget write cut off), it is added back when notifications are authorized
    /// (`restoreEvening`); off, any evening id still pending is removed.
    ///
    /// `completion`, when given, runs once the center has answered every add (or at once when
    /// nothing changed).
    private func apply(makingGroups makeGroups: @escaping @Sendable (Int) -> [ReminderGroup],
                       completion: (@Sendable () -> Void)? = nil) {
        let center = self.center
        let defaults = SendableDefaults(defaults: defaults)
        center.getPendingNotificationRequests { pending in
            let byID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            let snoozes = pending.filter { $0.identifier.hasPrefix(ReminderPlan.snoozePrefix) }.count
            let eveningOn = defaults.isEveningOn
            var writes: [(adds: [UNNotificationRequest], removals: [String])] = []
            var missingEvening: ReminderGroup?
            for group in makeGroups(snoozes) {
                let current = group.identifiers.compactMap { byID[$0] }
                if group.isEvening {
                    let wantsEvening = !group.requests.isEmpty
                    guard wantsEvening == eveningOn else { continue }
                    if wantsEvening, current.isEmpty {
                        missingEvening = group
                        continue
                    }
                }
                guard Self.signature(current, comparesBody: !group.isEvening)
                        != Self.signature(group.requests, comparesBody: !group.isEvening) else { continue }
                let planned = Set(group.requests.map(\.identifier))
                writes.append((group.requests, group.identifiers.filter { !planned.contains($0) }))
            }

            let expected = writes.reduce(0) { $0 + $1.adds.count } + (missingEvening == nil ? 0 : 1)
            let countdown = Countdown(expected)
            let answered: (@Sendable (Error?) -> Void)? = completion.map { completion in
                let tick: @Sendable (Error?) -> Void = { _ in if countdown.tick() { completion() } }
                return tick
            }
            for write in writes {
                for request in write.adds {
                    center.add(request, withCompletionHandler: answered)
                }
                if !write.removals.isEmpty {
                    center.removePendingNotificationRequests(withIdentifiers: write.removals)
                }
            }
            if let missingEvening {
                Self.restoreEvening(missingEvening, center: center, defaults: defaults) { answered?(nil) }
            }
            if expected == 0 { completion?() }
        }
    }

    /// The Daily Reminder is on and nothing of it is pending (finding 1): added back, but only while
    /// notifications are `.authorized` — the launch's rule (StrideApp's `setupNotifications`); an
    /// add under an undecided status is never delivered. The pending list is read again first, so
    /// a `scheduleReminders` that ran meanwhile (the launch, the switch, a new time) is not
    /// overwritten with this pass's older plan, and the switch is read once more.
    private nonisolated static func restoreEvening(_ group: ReminderGroup, center: NotificationScheduling,
                                                   defaults: SendableDefaults, done: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            guard await center.authorizationStatus() == .authorized else { return done() }
            center.getPendingNotificationRequests { pending in
                let ids = Set(group.identifiers)
                guard defaults.isEveningOn, !pending.contains(where: { ids.contains($0.identifier) }),
                      !group.requests.isEmpty
                else { return done() }
                let countdown = Countdown(group.requests.count)
                for request in group.requests {
                    center.add(request) { _ in if countdown.tick() { done() } }
                }
            }
        }
    }

    /// One request as the replace compares it.
    private struct Signature: Hashable {
        let identifier: String
        let fire: ReminderPlan.Fire?
        let title: String
        let body: String
        let category: String
        let thread: String
        let habitID: UUID?
    }

    /// Nonisolated: it runs in the center's callback, off the main actor.
    private nonisolated static func signature(_ requests: [UNNotificationRequest], comparesBody: Bool) -> Set<Signature> {
        Set(requests.map { request in
            let content = request.content
            let fire = (request.trigger as? UNCalendarNotificationTrigger)
                .map { ReminderPlan.Fire($0.dateComponents, repeats: $0.repeats) }
            return Signature(identifier: request.identifier, fire: fire, title: content.title,
                             body: comparesBody ? content.body : "", category: content.categoryIdentifier,
                             thread: content.threadIdentifier,
                             habitID: NotificationRouter.habitID(from: content.userInfo))
        })
    }

    // MARK: - Snooze and delivered banners (1.4.0)

    /// Snooze 1 Hour: the reminder once more, an hour from now, under the habit's one snooze id
    /// (`stride.habit.snooze.<uuid>`, so snoozing again replaces it).
    ///
    /// It carries the category, the habit id and `userInfo["day"]`: the day the reminder was FOR,
    /// as `ReminderDay.resolve` gave it when Snooze was tapped. Its own delivery can fall after
    /// midnight, and a Mark Done on it would otherwise credit the next day (design review,
    /// "snooze-credits-next-day"); a snooze of a snooze carries the day forward the same way.
    ///
    /// Only for a habit whose reminder is on: the launch prune keeps a snooze for no other.
    ///
    /// Returns once the center has called back for the add. The action handler awaits this before
    /// `didReceive` returns, and the system may suspend the process from that moment. A Snooze tapped
    /// on a lock screen relaunches a terminated Stride in the background for this one call, and the
    /// banner is already gone: an add still on its way to the notification server when the
    /// process stopped would leave no reminder at all (W2 fix review). The removal before it goes
    /// to the same center first, in order.
    func scheduleSnooze(for habit: Habit, day: Date) async {
        let identifier = ReminderPlan.snoozeIdentifier(for: habit.id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard ReminderPlan.Settings(habit) != nil else { return }
        let content = reminderContent(for: habit)
        content.userInfo[NotificationRouter.UserInfoKey.day] = ReminderDay.string(for: day)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: ReminderPlan.snoozeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        let center = self.center
        let error: Error? = await withCheckedContinuation { continuation in
            center.add(request) { continuation.resume(returning: $0) }
        }
        if error != nil {
            // Code-only, as the budget notice: no habit id in a production log line (D4).
            Self.logger.error("snooze: the center refused the request")
        }
    }

    /// A check-in of the habit in this process — Today, Siri, the action itself — ends its pending
    /// snooze: it was a nudge to do what is now done (D4).
    func cancelSnooze(for habitID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [ReminderPlan.snoozeIdentifier(for: habitID)])
    }

    /// Takes the habit's banners out of Notification Center: every reminder shape and the snooze.
    /// After a check-in, because they ask for what is done; after a kind change
    /// (`habitKindDidChange`), because their button is the old kind's — a delivered banner keeps
    /// its category (`UNNotificationContent.categoryIdentifier` is read-only), so "Add 1" stayed on
    /// a habit that became yes/no.
    func withdrawDeliveredReminders(for habitID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: ReminderPlan.allIdentifiers(for: habitID))
    }

    /// The habit sheet saved a new kind (D4: "so no wrong button stays visible"). The reschedule
    /// that follows re-categorizes the pending reminders. Nothing re-categorizes two other things,
    /// and both would show the old kind's button:
    /// - delivered banners, which are withdrawn;
    /// - the pending snooze, which is cancelled. The reschedule (`apply`) leaves it alone on purpose, so
    ///   left there it would fire an hour after Snooze with "Add 1" on a habit that is now yes/no
    ///   (W2 fix review).
    ///
    /// Cancelled rather than added again under the new category, because a re-add could not keep
    /// its time. A pending `UNTimeIntervalNotificationTrigger` keeps only `timeInterval` and
    /// `repeats`: its archived form has no other key, and `nextTriggerDate()` is always now + the
    /// interval (measured 2026-10-10 on the macOS 27 SDK). So the re-added snooze would fire up to
    /// an hour later than the one the user asked for. The habit's own reminder still fires on its
    /// schedule. A kind pulled from another device gets the same treatment in
    /// `refreshAfterDataChange`.
    func habitKindDidChange(_ habitID: UUID) {
        withdrawDeliveredReminders(for: habitID)
        cancelSnooze(for: habitID)
    }

    /// Launch, foreground and the day changing: habit banners delivered before today go.
    ///
    /// A delivered banner stays until its id fires again — a week, for a weekday id — and a
    /// snooze's until something withdraws it. A Mark Done on Monday's banner tapped on Thursday
    /// credits Thursday (`ReminderDay.resolve`), but a lock screen of old days' buttons invites taps
    /// meant for those days (design review, "action-credits-stale-day"). Only habit banners: the
    /// evening and morning reminders carry no buttons.
    func pruneDeliveredBeforeToday(now: Date = Date(), calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        let center = self.center
        center.getDeliveredNotifications { delivered in
            let stale = delivered
                .filter { ReminderPlan.isHabitRequest($0.identifier) && $0.date < startOfToday }
                .map(\.identifier)
            guard !stale.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    // MARK: - Badge, and the pass after a data change

    /// One pass after the data may have changed (RELEASE-1.4.0.md D3, D4): the app's saves
    /// (StrideApp's throttled observer), the day changing, a time-zone change, coming to the
    /// foreground, the Mac becoming active.
    /// - The badge, under `updateBadge`'s rule.
    /// - The pending snooze and the banners of every habit already done today. A check-in in this
    ///   process does that at once (`CheckInEffects`); this pass catches the ones it never sees —
    ///   the widget's, in another process, and another device's, arriving by sync.
    /// - Banners whose button is not the habit's kind any more (a kind pulled from another device;
    ///   an edit here withdraws at once, AddHabitView), and banners of a habit gone or archived.
    /// - The same for a pending snooze, which is cancelled (`habitKindDidChange` says why it is not
    ///   re-added). A reschedule never touches the snooze, so after a pulled kind change it would
    ///   still fire with the old kind's button.
    /// - **1.5.0: the full plan** (RELEASE-1.5.0.md D4, Gemini A2). Until 1.5.0 this pass never
    ///   touched a pending reminder. Now a check-in, an un-check, a check-in synced from another
    ///   device or the widget's, and the day or the zone changing all re-plan every reminder-on
    ///   habit and the Daily Reminder from today's state, and replace only the ones whose requests
    ///   changed: a habit done today goes quiet (its overlay), an undo brings its request back, and
    ///   the next day's pass drops yesterday's overlay.
    ///
    /// It writes no data, and never prunes by what is pending: orphans of deleted habits and the
    /// snoozes of reminder-off habits are the launch pass's alone (`rescheduleAllHabitReminders`).
    /// It removes only ids it can name from the store (v2 review, findings 4 and 5): an archived
    /// habit's, and the Daily Reminder's while it is off.
    func refreshAfterDataChange(modelContainer: ModelContainer, now: Date = Date(), calendar: Calendar = .current) {
        guard let plan = makePlan(in: modelContainer, now: now, calendar: calendar) else { return }
        setBadge(plan.progress.remaining)

        let done = plan.doneToday
        if !done.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: done.map { ReminderPlan.snoozeIdentifier(for: $0.id) })
            center.removeDeliveredNotifications(withIdentifiers: done.flatMap { ReminderPlan.allIdentifiers(for: $0.id) })
        }

        apply(plan)

        let categories = Dictionary(plan.habits.map { ($0.id, Self.category(for: $0.habitKind)) },
                                    uniquingKeysWith: { first, _ in first })
        let center = self.center
        center.getDeliveredNotifications { delivered in
            let wrong = delivered.filter { banner in
                Self.showsAnotherKindsButton(category: banner.categoryIdentifier, habitID: banner.habitID,
                                             current: categories)
            }.map(\.identifier)
            guard !wrong.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: wrong)
        }
        center.getPendingNotificationRequests { pending in
            let wrong = pending.filter { request in
                request.identifier.hasPrefix(ReminderPlan.snoozePrefix)
                    && Self.showsAnotherKindsButton(category: request.content.categoryIdentifier,
                                                    habitID: NotificationRouter.habitID(from: request.content.userInfo),
                                                    current: categories)
            }.map(\.identifier)
            guard !wrong.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: wrong)
        }
    }

    /// A reminder action's check-in, and every check-in or un-check made in the app's process
    /// (`CheckInEffects.live`): the full plan, then the badge, both awaited — a lock-screen Mark
    /// Done runs in a background launch with no window, so no save observer re-plans for it, and
    /// the process can be suspended as soon as the action returns.
    func replanAndUpdateBadgeAndWait(modelContainer: ModelContainer, now: Date = Date(),
                                     calendar: Calendar = .current) async {
        await scheduleAllHabitRemindersAndWait(modelContainer: modelContainer, now: now, calendar: calendar)
        await updateBadgeAndWait(modelContainer: modelContainer, now: now, calendar: calendar)
    }

    /// A habit banner, delivered or pending, whose button is not its habit's kind (`current`, by
    /// id), or whose habit is not in `current` (gone or archived). Only our two categories with a
    /// habit id: the evening and morning reminders, and 1.3.x requests, are not this pass's.
    /// Nonisolated: it runs in the center's callbacks, off the main actor.
    private nonisolated static func showsAnotherKindsButton(category: String, habitID: UUID?,
                                                            current: [UUID: String]) -> Bool {
        guard category == NotificationRouter.binaryCategory || category == NotificationRouter.countCategory,
              let habitID
        else { return false }
        return current[habitID] != category
    }

    /// Update the app badge with what is left today: `DailyProgress.remaining` for today's
    /// day-key (RELEASE-1.5.0.md D1, D2) — the habits due today and not done. A rest day, a met
    /// times-per-week week and a habit not started yet are not counted, so a day with nothing due
    /// shows no badge. The same rule as Today's card and the widget; until 1.5.0 the badge
    /// scanned records with `Habit.isCompletedOn` and counted every unarchived habit.
    ///
    /// On both platforms since 1.4.0 (D3), under the same two rules as on iOS — the notification
    /// permission, asked when a reminder is switched on, and the user's own Badges switch. On macOS
    /// `setBadgeCount` alone never reached the Dock, so 1.4.2 also sets the tile's label
    /// (`showOnDock`). Fire and forget: the count is read now and set on the next turn.
    func updateBadge(modelContainer: ModelContainer, now: Date = Date(), calendar: Calendar = .current) {
        guard let count = remainingToday(in: modelContainer, now: now, calendar: calendar) else { return }
        setBadge(count)
    }

    /// `updateBadge`, returning once the system has the count: for the action handler, whose
    /// process can be suspended as soon as it returns, taking a fire-and-forget set with it.
    func updateBadgeAndWait(modelContainer: ModelContainer, now: Date = Date(), calendar: Calendar = .current) async {
        guard let count = remainingToday(in: modelContainer, now: now, calendar: calendar) else { return }
        #if os(macOS)
        let generation = nextDockBadgeGeneration()
        #endif
        try? await center.setBadgeCount(count)
        #if os(macOS)
        await showOnDock(count, generation: generation)
        #endif
    }

    /// `DailyProgress.remaining` today over every unarchived habit; nil when the fetch failed.
    private func remainingToday(in container: ModelContainer, now: Date, calendar: Calendar) -> Int? {
        let context = ModelContext(container)
        guard let habits = unarchivedHabits(in: context) else { return nil }
        let today = DailyProgress.today(now: now, calendar: calendar)
        let live = HabitStats.liveRecordIDs(of: habits, in: context)
        let stats = habits.map { HabitStats(habit: $0, liveRecordIDs: live, calendar: calendar, today: today) }
        return DailyProgress(of: stats, on: today).remaining
    }

    private func setBadge(_ count: Int) {
        let center = self.center
        #if os(macOS)
        // Taken now, in call order, not when `setBadgeCount` answers: replies can come back out of
        // order, and the newest count must win.
        let generation = nextDockBadgeGeneration()
        #endif
        Task {
            try? await center.setBadgeCount(count)
            #if os(macOS)
            await showOnDock(count, generation: generation)
            #endif
        }
    }

    #if os(macOS)
    /// The newest badge request, numbered when it is made (not when its awaits return), so an
    /// older count whose replies come back late cannot overwrite a newer one.
    private var dockBadgeGeneration = 0

    private func nextDockBadgeGeneration() -> Int {
        dockBadgeGeneration += 1
        return dockBadgeGeneration
    }

    /// The Dock tile's label (RELEASE-1.4.2.md Phase 0 item 12, N5). On the Mac `setBadgeCount`
    /// only stores the count: usernoted had it (10→9 on a check-in) while the Dock showed nothing
    /// from 1.4.0 to 1.4.1. The tile's own label shows at once, but it lives only as long as the
    /// process, so it is set wherever the badge is — launch, activation, every save and day change
    /// (StrideApp's `setupNotifications` and `installProcessTriggers` all go through `setBadge`).
    ///
    /// Under the same rules as the system badge: only while Stride's Badges switch is on (which
    /// also needs the notification permission), and no label at 0. Turning Badges off in System
    /// Settings clears it at the next activation, i.e. on coming back to the app.
    ///
    /// Only over the real center: a test's recording center never touches the host's Dock tile.
    private func showOnDock(_ count: Int, generation: Int) async {
        guard let real = center as? UNUserNotificationCenter else { return }
        guard generation == dockBadgeGeneration else { return }
        let enabled = await real.notificationSettings().badgeSetting == .enabled
        guard generation == dockBadgeGeneration else { return }
        NSApp.dockTile.badgeLabel = Self.dockLabel(count: count, badgesEnabled: enabled)
    }
    #endif

    /// The Dock tile's label for a badge count: nil (no badge) at 0, below 0, or with Badges off;
    /// otherwise the count. Pure, and compiled on iOS too, so the hosted suite (an iOS simulator)
    /// pins the rule the Mac's `showOnDock` applies (X4, RELEASE-1.5.0.md).
    static func dockLabel(count: Int, badgesEnabled: Bool) -> String? {
        guard badgesEnabled, count > 0 else { return nil }
        return String(count)
    }

    /// In a fresh context: what is saved, never what a view holds unsaved.
    private func unarchivedHabits(in context: ModelContext) -> [Habit]? {
        let descriptor = FetchDescriptor<Habit>(predicate: #Predicate<Habit> { !$0.isArchived })
        return try? context.fetch(descriptor)
    }

    // MARK: - Message Variety

    private func randomEveningMessage() -> String {
        let messages = [
            appLocalized("Don't break the chain! Check in on your habits before bed."),
            appLocalized("A few minutes now, a better you tomorrow. Open Stride!"),
            appLocalized("Have you completed all your habits today?"),
            appLocalized("Your streak is counting on you! Time to check in."),
            appLocalized("Small steps, big changes. Don't forget your habits!"),
            appLocalized("End the day strong — mark your progress in Stride."),
            appLocalized("Consistency is key. How did you do today?"),
            appLocalized("Your future self will thank you. Check your habits!"),
        ]
        return messages.randomElement() ?? messages[0]
    }

    private func randomMorningMessage() -> String {
        let messages = [
            appLocalized("New day, new opportunities! Your habits are waiting."),
            appLocalized("Rise and shine! Let's make today count."),
            appLocalized("A fresh start — what will you accomplish today?"),
            appLocalized("Good morning! Time to build those healthy habits."),
            appLocalized("Today is full of potential. Start with your habits!"),
        ]
        return messages.randomElement() ?? messages[0]
    }
}

/// Counts down the adds one replace is waiting for; the last answer says so. The center answers
/// on its own queue, so the count is locked.
private final class Countdown: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int

    init(_ count: Int) { left = count }

    /// True for the answer that brings it to zero.
    func tick() -> Bool {
        lock.withLock {
            left -= 1
            return left == 0
        }
    }
}
