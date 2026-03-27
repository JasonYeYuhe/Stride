import Foundation
import UserNotifications
import SwiftData
#if os(iOS)
import UIKit
#endif

/// Manages daily habit reminder notifications.
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let reminderIdentifierPrefix = "stride.daily.reminder"
    private let morningIdentifier = "stride.daily.morning"
    private let eveningIdentifier = "stride.daily.evening"

    // MARK: - UserDefaults Keys (synced via App Group)

    private let defaults = UserDefaults(suiteName: "group.yyh.stride.habittracker") ?? .standard

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

    private init() {}

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            return granted
        } catch {
            return false
        }
    }

    func checkPermission() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Schedule

    func scheduleReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [eveningIdentifier])

        let content = UNMutableNotificationContent()
        content.title = "Stride Reminder 🏃"
        content.body = randomEveningMessage()
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        var dateComponents = DateComponents()
        dateComponents.hour = reminderHour
        dateComponents.minute = reminderMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: eveningIdentifier, content: content, trigger: trigger)

        center.add(request)

        if isMorningMotivationEnabled {
            scheduleMorningMotivation()
        }
    }

    private func scheduleMorningMotivation() {
        center.removePendingNotificationRequests(withIdentifiers: [morningIdentifier])

        let content = UNMutableNotificationContent()
        content.title = "Good Morning! ☀️"
        content.body = randomMorningMessage()
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = 8
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: morningIdentifier, content: content, trigger: trigger)

        center.add(request)
    }

    func removeAllReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [eveningIdentifier, morningIdentifier])
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
            "Don't break the chain! Check in on your habits before bed.",
            "A few minutes now, a better you tomorrow. Open Stride!",
            "Have you completed all your habits today?",
            "Your streak is counting on you! Time to check in.",
            "Small steps, big changes. Don't forget your habits!",
            "End the day strong — mark your progress in Stride.",
            "Consistency is key. How did you do today?",
            "Your future self will thank you. Check your habits!",
        ]
        return messages.randomElement() ?? messages[0]
    }

    private func randomMorningMessage() -> String {
        let messages = [
            "New day, new opportunities! Your habits are waiting.",
            "Rise and shine! Let's make today count.",
            "A fresh start — what will you accomplish today?",
            "Good morning! Time to build those healthy habits.",
            "Today is full of potential. Start with your habits!",
        ]
        return messages.randomElement() ?? messages[0]
    }
}
