import Foundation
import UserNotifications
import SwiftData
import os.log
#if os(iOS)
import UIKit
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
    private let eveningIdentifier = "stride.daily.evening"

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
    /// scheduled at that moment. The launch pass (`rescheduleAllHabitReminders`) ran while the
    /// status was undecided and scheduled nothing that could fire, so without this the habits
    /// that came by sync or restore, or were saved before the grant, stayed silent until the
    /// next cold launch — on iOS, possibly days — and only the habit being saved worked.
    func ensureReminderPermission(schedulingExistingIn container: ModelContainer? = nil) async -> ReminderPermission {
        switch await checkPermission() {
        case .notDetermined:
            guard await requestPermission() else { return .denied }
            if let container { scheduleAllHabitReminders(modelContainer: container) }
            return .allowed
        case .denied:
            return .denied
        default:
            // .authorized, .provisional, .ephemeral (and any future case) deliver.
            return .allowed
        }
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

    func scheduleReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [eveningIdentifier])

        let content = UNMutableNotificationContent()
        content.title = appLocalized("Stride Reminder 🏃")
        content.body = randomEveningMessage()
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        var dateComponents = DateComponents()
        dateComponents.hour = reminderHour
        dateComponents.minute = reminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: eveningIdentifier, content: content, trigger: trigger)

        center.add(request, withCompletionHandler: nil)

        if isMorningMotivationEnabled {
            scheduleMorningMotivation()
        }
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

    func removeAllReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [eveningIdentifier, morningIdentifier])
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
        if isReminderEnabled { scheduleReminders() }
        if let modelContainer { scheduleAllHabitReminders(modelContainer: modelContainer) }
    }

    // MARK: - Per-Habit Reminders

    /// Every id a habit's reminder can be scheduled under — the legacy daily one and the seven
    /// weekday ones (`ReminderPlan`) — which a schedule removes before it adds: a habit moving
    /// between every day and specific days must leave nothing of the other shape firing. Not the
    /// snooze: launch, a foreground sync, an edit and a language change all reschedule, and none of
    /// them is the user saying the snooze is over.
    private static func reminderIdentifiers(for habitID: UUID) -> [String] {
        let snooze = ReminderPlan.snoozeIdentifier(for: habitID)
        return ReminderPlan.allIdentifiers(for: habitID).filter { $0 != snooze }
    }

    /// One habit's reminder: the habit sheet's save, a restore from the archive.
    ///
    /// The request budget (`ReminderPlan.requestBudget`) is a property of ALL the reminders, so the
    /// habit is planned together with the others in its store. Should it take the total over,
    /// every specificDays habit falls back to its one daily trigger — the others as well, or their
    /// weekday triggers would still crowd iOS's 64 and some reminder would silently never fire.
    func scheduleHabitReminder(for habit: Habit) {
        guard let settings = ReminderPlan.Settings(habit) else {
            // Off or archived: nothing of it may fire, a snooze included — the launch prune keeps a
            // snooze only for a habit whose reminder is on.
            center.removePendingNotificationRequests(withIdentifiers: ReminderPlan.allIdentifiers(for: habit.id))
            return
        }
        if let container = habit.modelContext?.container,
           let others = reminderHabits(in: ModelContext(container))?.filter({ $0.id != habit.id }) {
            let plan = ReminderPlan.plan(others.compactMap { ReminderPlan.Settings($0) } + [settings])
            if plan.fellBackToDaily {
                scheduleAllHabitReminders(modelContainer: container)
                // This habit as the caller holds it, saved or not.
                replaceReminder(of: habit, with: ReminderPlan.requests(for: settings, dailyOnly: true))
                return
            }
        }
        replaceReminder(of: habit, with: ReminderPlan.requests(for: settings))
    }

    /// Removes the pending requests of every reminder shape, then adds `requests`.
    private func replaceReminder(of habit: Habit, with requests: [ReminderPlan.Request]) {
        center.removePendingNotificationRequests(withIdentifiers: Self.reminderIdentifiers(for: habit.id))
        for planned in requests {
            let trigger = UNCalendarNotificationTrigger(dateMatching: planned.dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: planned.identifier, content: reminderContent(for: habit),
                                                trigger: trigger)
            center.add(request, withCompletionHandler: nil)
        }
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

    /// Reminder off, archive, delete: every reminder shape and the snooze, pending AND delivered. A
    /// banner already in Notification Center is not a pending request; left there, it kept offering
    /// Mark Done for a habit whose reminder was just switched off, or that is gone.
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
    /// 1.4.0: what to keep is the planner's (`ReminderPlan.Result.keep`) — weekday ids, and the
    /// snooze of every habit whose reminder is on. 1.3.x kept exactly `prefix + uuid`, which would
    /// have removed every weekday reminder and every snooze at the next launch.
    func rescheduleAllHabitReminders(modelContainer: ModelContainer) {
        // Don't prune on a failed fetch: an empty "keep" set would delete every reminder.
        guard let plan = scheduleAllHabitReminders(modelContainer: modelContainer) else { return }

        let keep = plan.keep
        let center = self.center
        center.getPendingNotificationRequests { requests in
            let orphans = ReminderPlan.prune(requests.map(\.identifier), keep: keep)
            guard !orphans.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: orphans)
        }
    }

    /// Adds (replaces) the reminder of every reminder-on, unarchived habit in the store and
    /// returns the plan; nil when the fetch failed. No prune — the launch pass prunes. That
    /// makes it safe while the habit sheet is still saving: a prune computed now would find the
    /// sheet's own reminder, added a moment later, missing from its "keep" set and remove it
    /// (the real center answers `getPendingNotificationRequests` asynchronously).
    ///
    /// 1.4.0: also after a successful foreground sync (StrideApp) and a language change. Each
    /// habit's requests are replaced whole, so a kind, a day mask or a time pulled from another
    /// device reaches the triggers and the category before the next cold launch.
    @discardableResult
    func scheduleAllHabitReminders(modelContainer: ModelContainer) -> ReminderPlan.Result? {
        guard let habits = reminderHabits(in: ModelContext(modelContainer)) else { return nil }
        let plan = ReminderPlan.plan(habits.compactMap { ReminderPlan.Settings($0) })
        if plan.fellBackToDaily {
            // Code-only, and no habit ids in a production log line (D4).
            Self.logger.notice("reminders over the request budget: specific-days habits fall back to one daily trigger")
        }
        let requests = Dictionary(grouping: plan.requests, by: \.habitID)
        for habit in habits {
            replaceReminder(of: habit, with: requests[habit.id] ?? [])
        }
        return plan
    }

    /// Every reminder-on, unarchived habit; nil when the fetch failed.
    private func reminderHabits(in context: ModelContext) -> [Habit]? {
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate<Habit> { $0.reminderEnabled && !$0.isArchived }
        )
        return try? context.fetch(descriptor)
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
    func scheduleSnooze(for habit: Habit, day: Date) {
        let identifier = ReminderPlan.snoozeIdentifier(for: habit.id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard ReminderPlan.Settings(habit) != nil else { return }
        let content = reminderContent(for: habit)
        content.userInfo[NotificationRouter.UserInfoKey.day] = ReminderDay.string(for: day)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: ReminderPlan.snoozeInterval, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger),
                   withCompletionHandler: nil)
    }

    /// A check-in of the habit in this process — Today, Siri, the action itself — ends its pending
    /// snooze: it was a nudge to do what is now done (D4).
    func cancelSnooze(for habitID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [ReminderPlan.snoozeIdentifier(for: habitID)])
    }

    /// Takes the habit's banners out of Notification Center: every reminder shape and the snooze.
    /// After a check-in, because they ask for what is done; after a kind change, because their
    /// button is the old kind's — a delivered banner keeps its category
    /// (`UNNotificationContent.categoryIdentifier` is read-only), so "Add 1" stayed on a habit that
    /// became yes/no.
    func withdrawDeliveredReminders(for habitID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: ReminderPlan.allIdentifiers(for: habitID))
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
    /// (StrideApp's throttled observer), the day changing, coming to the foreground, the Mac
    /// becoming active.
    /// - The badge, under `updateBadge`'s rule.
    /// - The pending snooze and the banners of every habit already done today. A check-in in this
    ///   process does that at once (`CheckInEffects`); this pass catches the ones it never sees —
    ///   the widget's, in another process, and another device's, arriving by sync.
    /// - Banners whose button is not the habit's kind any more (a kind pulled from another device;
    ///   an edit here withdraws at once, AddHabitView), and banners of a habit gone or archived.
    ///
    /// It writes no data and never removes a pending REMINDER: those are the schedule's and the
    /// launch prune's.
    func refreshAfterDataChange(modelContainer: ModelContainer, now: Date = Date()) {
        guard let habits = unarchivedHabits(in: modelContainer) else { return }
        let today = Calendar.current.startOfDay(for: now)
        let done = habits.filter { $0.isCompletedOn(today) }
        setBadge(habits.count - done.count)

        if !done.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: done.map { ReminderPlan.snoozeIdentifier(for: $0.id) })
            center.removeDeliveredNotifications(withIdentifiers: done.flatMap { ReminderPlan.allIdentifiers(for: $0.id) })
        }

        let categories = Dictionary(habits.map { ($0.id, Self.category(for: $0.habitKind)) },
                                    uniquingKeysWith: { first, _ in first })
        let center = self.center
        center.getDeliveredNotifications { delivered in
            let wrong = delivered.filter { banner in
                guard banner.categoryIdentifier == NotificationRouter.binaryCategory
                        || banner.categoryIdentifier == NotificationRouter.countCategory,
                      let habitID = banner.habitID
                else { return false }
                return categories[habitID] != banner.categoryIdentifier
            }.map(\.identifier)
            guard !wrong.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: wrong)
        }
    }

    /// Update app badge with the number of incomplete habits for today — unarchived and not done,
    /// the rule the widget and Today's card share (a schedule-aware count would have to change all
    /// of them at once; D3 leaves it to the backlog).
    ///
    /// On both platforms since 1.4.0 (D3): `setBadgeCount` is macOS 13+ too, where it badges the
    /// Dock tile under the same two rules as on iOS — the notification permission, asked when a
    /// reminder is switched on, and the user's own Badges switch. Fire and forget: the count is
    /// read now and set on the next turn.
    func updateBadge(modelContainer: ModelContainer) {
        guard let habits = unarchivedHabits(in: modelContainer) else { return }
        setBadge(Self.remaining(of: habits, now: Date()))
    }

    /// `updateBadge`, returning once the system has the count: for the action handler, whose
    /// process can be suspended as soon as it returns, taking a fire-and-forget set with it.
    func updateBadgeAndWait(modelContainer: ModelContainer) async {
        guard let habits = unarchivedHabits(in: modelContainer) else { return }
        try? await center.setBadgeCount(Self.remaining(of: habits, now: Date()))
    }

    private static func remaining(of habits: [Habit], now: Date) -> Int {
        let today = Calendar.current.startOfDay(for: now)
        return habits.filter { !$0.isCompletedOn(today) }.count
    }

    private func setBadge(_ count: Int) {
        let center = self.center
        Task { try? await center.setBadgeCount(count) }
    }

    /// In a fresh context: what is saved, never what a view holds unsaved.
    private func unarchivedHabits(in modelContainer: ModelContainer) -> [Habit]? {
        let context = ModelContext(modelContainer)
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
