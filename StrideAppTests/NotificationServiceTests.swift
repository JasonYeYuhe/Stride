import XCTest
import SwiftData
import UserNotifications
@testable import Stride

/// Records what NotificationService asks the system to schedule, with the real center's
/// replace-by-identifier semantics, instead of filling the host app's pending store.
/// Only ever touched from the main actor (the service is @MainActor, and this center calls its
/// completion handlers synchronously), hence the unchecked Sendable.
private final class RecordingCenter: NotificationScheduling, @unchecked Sendable {
    private(set) var pending: [String: UNNotificationRequest] = [:]
    private(set) var removed: [String] = []

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        pending[request.identifier] = request
        completionHandler?(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removed.append(contentsOf: identifiers)
        for id in identifiers { pending.removeValue(forKey: id) }
    }

    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
        completionHandler(Array(pending.values))
    }

    /// Something already in the store from an earlier launch.
    func seed(_ identifier: String) {
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 0), repeats: true)
        pending[identifier] = UNNotificationRequest(identifier: identifier, content: UNNotificationContent(), trigger: trigger)
    }

    func trigger(_ identifier: String) -> UNCalendarNotificationTrigger? {
        pending[identifier]?.trigger as? UNCalendarNotificationTrigger
    }
}

@MainActor
final class NotificationServiceTests: XCTestCase {

    private var center: RecordingCenter!
    private var scratch: ScratchDefaults!
    private var service: NotificationService!
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        center = RecordingCenter()
        scratch = ScratchDefaults("notifications")
        service = NotificationService(center: center, defaults: scratch.defaults)
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    override func tearDown() {
        scratch.remove()
        service = nil
        center = nil
        container = nil
        super.tearDown()
    }

    private func habit(_ name: String, reminder: Bool = true, hour: Int = 7, minute: Int = 30,
                       archived: Bool = false) -> Habit {
        let habit = Habit(name: name)
        habit.reminderEnabled = reminder
        habit.reminderHour = hour
        habit.reminderMinute = minute
        habit.isArchived = archived
        return habit
    }

    private func reminderID(_ habit: Habit) -> String { "stride.habit.reminder." + habit.id.uuidString }

    // MARK: - Per-habit reminders

    /// One repeating daily trigger at the habit's hour and minute, under an identifier derived
    /// from the habit id — the prune below and `removeHabitReminder` find it by that prefix.
    /// A trigger with any other component (a weekday, a day) would fire once a week or month.
    func testHabitReminderIsADailyRepeatingTriggerAtItsTime() throws {
        let read = habit("Read", hour: 7, minute: 30)

        service.scheduleHabitReminder(for: read)

        let trigger = try XCTUnwrap(center.trigger(reminderID(read)))
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents, DateComponents(hour: 7, minute: 30))
        XCTAssertEqual(center.pending[reminderID(read)]?.content.title, "⭐ Read")
        XCTAssertEqual(center.pending.count, 1)
    }

    /// Switching a reminder off, or archiving the habit, has to take the old request out — not
    /// just skip adding a new one. The request repeats in the system store until removed.
    func testDisabledOrArchivedHabitLosesItsExistingReminder() {
        let off = habit("Off", reminder: false)
        let archived = habit("Archived", archived: true)
        center.seed(reminderID(off))
        center.seed(reminderID(archived))

        service.scheduleHabitReminder(for: off)
        service.scheduleHabitReminder(for: archived)

        XCTAssertTrue(center.pending.isEmpty)
    }

    func testRemoveHabitReminderRemovesOnlyThatHabitsRequest() {
        let deleted = habit("Deleted")
        let kept = habit("Kept")
        service.scheduleHabitReminder(for: deleted)
        service.scheduleHabitReminder(for: kept)

        service.removeHabitReminder(for: deleted.id)

        XCTAssertEqual(Set(center.pending.keys), [reminderID(kept)])
    }

    /// The launch-time prune: a habit deleted or archived on another device arrives through
    /// sync, which cannot reach this service, so its reminder would fire every day forever for
    /// a habit with no row left to switch it off. Other reminders — the daily evening one — are
    /// not this prune's to touch.
    func testRescheduleAllPrunesOrphansAndKeepsEverythingElse() throws {
        let context = ModelContext(container)
        let active = habit("Active", hour: 6, minute: 45)
        let archivedElsewhere = habit("Archived", archived: true)
        let noReminder = habit("Quiet", reminder: false)
        for habit in [active, archivedElsewhere, noReminder] { context.insert(habit) }
        try context.save()

        let deletedElsewhere = "stride.habit.reminder." + UUID().uuidString
        center.seed(deletedElsewhere)
        center.seed(reminderID(archivedElsewhere))
        center.seed("stride.daily.evening")

        service.rescheduleAllHabitReminders(modelContainer: container)

        XCTAssertEqual(Set(center.pending.keys), [reminderID(active), "stride.daily.evening"])
        XCTAssertEqual(center.trigger(reminderID(active))?.dateComponents, DateComponents(hour: 6, minute: 45))
    }

    // MARK: - Daily reminder

    /// Never set means 20:00. Explicitly set to midnight means 00:00: the stored integer is 0 in
    /// both cases, and only the `reminderHourSet` flag tells them apart.
    func testDailyReminderDefaultsTo8pmButHonoursAnExplicitMidnight() throws {
        service.isReminderEnabled = true
        var trigger = try XCTUnwrap(center.trigger("stride.daily.evening"))
        XCTAssertEqual(trigger.dateComponents, DateComponents(hour: 20, minute: 0))
        XCTAssertTrue(trigger.repeats)

        service.reminderHour = 0
        trigger = try XCTUnwrap(center.trigger("stride.daily.evening"))
        XCTAssertEqual(trigger.dateComponents, DateComponents(hour: 0, minute: 0))

        service.isReminderEnabled = false
        XCTAssertNil(center.pending["stride.daily.evening"])
    }
}
