import Foundation
import UserNotifications
import SwiftData
#if os(iOS)
import UIKit
#endif

/// The part of `UNUserNotificationCenter` that plans reminders: add, remove, list — and, since
/// 1.3.0, the authorization status and the request, because whether a reminder is scheduled at
/// all now depends on them. A seam for StrideAppTests, which records what would be scheduled
/// instead of filling the host app's real pending-notification store (and iOS's 64-request
/// limit) with test reminders, and which plays the user's answer to the system prompt instead
/// of raising a real one.
protocol NotificationScheduling: AnyObject, Sendable {
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void)
    /// `UNNotificationSettings` has no public initializer, so the seam asks for the one field
    /// the app reads rather than the settings object a test could never build.
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

/// `requestAuthorization(options:)` is the center's own async method; only the status needs a
/// wrapper. Both are exactly what `requestPermission` / `checkPermission` called before the seam.
extension UNUserNotificationCenter: NotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
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
    static let shared = NotificationService()

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
            defaults: UserDefaults(suiteName: "group.yyh.stride.habittracker") ?? .standard
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

    // MARK: - Per-Habit Reminders

    private let habitReminderPrefix = "stride.habit.reminder."

    func scheduleHabitReminder(for habit: Habit) {
        let identifier = habitReminderPrefix + habit.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard habit.reminderEnabled && !habit.isArchived else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(habit.emoji) \(habit.name)"
        content.body = appLocalized("Time to work on your habit!")
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = habit.reminderHour
        dateComponents.minute = habit.reminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.add(request, withCompletionHandler: nil)
    }

    func removeHabitReminder(for habitId: UUID) {
        let identifier = habitReminderPrefix + habitId.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
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
    func rescheduleAllHabitReminders(modelContainer: ModelContainer) {
        // Don't prune on a failed fetch: an empty "wanted" set would delete every reminder.
        guard let habits = scheduleAllHabitReminders(modelContainer: modelContainer) else { return }

        let prefix = habitReminderPrefix
        let wanted = Set(habits.map { prefix + $0.id.uuidString })
        let center = self.center
        center.getPendingNotificationRequests { requests in
            let orphans = requests.map(\.identifier).filter { $0.hasPrefix(prefix) && !wanted.contains($0) }
            guard !orphans.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: orphans)
        }
    }

    /// Adds (replaces) the reminder of every reminder-on, unarchived habit in the store and
    /// returns those habits; nil when the fetch failed. No prune — the launch pass prunes. That
    /// makes it safe while the habit sheet is still saving: a prune computed now would find the
    /// sheet's own reminder, added a moment later, missing from its "wanted" set and remove it
    /// (the real center answers `getPendingNotificationRequests` asynchronously).
    @discardableResult
    func scheduleAllHabitReminders(modelContainer: ModelContainer) -> [Habit]? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate<Habit> { $0.reminderEnabled && !$0.isArchived }
        )
        guard let habits = try? context.fetch(descriptor) else { return nil }
        for habit in habits {
            scheduleHabitReminder(for: habit)
        }
        return habits
    }

    // MARK: - Smart Badge Update

    /// Update app badge with the number of incomplete habits for today.
    func updateBadge(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let today = Calendar.current.startOfDay(for: .now)

        do {
            let descriptor = FetchDescriptor<Habit>(
                predicate: #Predicate<Habit> { !$0.isArchived }
            )
            let habits = try context.fetch(descriptor)
            let incompleteCount = habits.filter { !$0.isCompletedOn(today) }.count

            #if os(iOS)
            UNUserNotificationCenter.current().setBadgeCount(incompleteCount)
            #endif
        } catch {
            // silently fail
        }
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
