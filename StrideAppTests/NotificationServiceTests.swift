import XCTest
import SwiftData
import UserNotifications
@testable import Stride

/// Records what NotificationService asks the system to schedule, with the real center's
/// replace-by-identifier semantics, instead of filling the host app's pending store — and plays
/// the user's answer to the permission prompt instead of raising a real one.
/// Only ever touched from one test at a time (the service is @MainActor and awaits each call,
/// and this center calls its completion handlers synchronously), hence the unchecked Sendable.
private final class RecordingCenter: NotificationScheduling, @unchecked Sendable {
    enum Event: Equatable { case request, add(String) }

    private(set) var pending: [String: UNNotificationRequest] = [:]
    private(set) var removed: [String] = []
    /// Requests and adds in the order they happened — the fresh-install bug was an add while
    /// the status was still `.notDetermined`, with no request before it.
    private(set) var events: [Event] = []

    /// The status before any prompt; a request moves `.notDetermined` to the user's answer,
    /// as the real center does.
    var status: UNAuthorizationStatus = .authorized
    /// What the user taps if the prompt is shown.
    var userAllows = true

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        events.append(.add(request.identifier))
        pending[request.identifier] = request
        completionHandler?(nil)
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        events.append(.request)
        // Like the real center: only a status nobody has decided yet shows a prompt; otherwise
        // the answer is whatever was decided before.
        if status == .notDetermined { status = userAllows ? .authorized : .denied }
        return status == .authorized
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

    // MARK: - Permission on the habit sheet's Save path

    /// The fresh-install bug: a reminder switched on in the New Habit sheet was added while the
    /// status was `.notDetermined` and never delivered. The prompt must come first, then the add.
    func testNotDeterminedAsksBeforeAnyReminderIsAdded() async {
        center.status = .notDetermined
        center.userAllows = true
        let read = habit("Read")

        let permission = await service.enableHabitReminder(for: read)

        XCTAssertEqual(permission, .allowed)
        XCTAssertEqual(center.events, [.request, .add(reminderID(read))])
    }

    /// "Don't Allow" at that prompt: nothing is added, and the caller learns why so the sheet
    /// can show the "Notifications are disabled" footer instead of pretending it worked.
    func testDeclinedPromptSchedulesNothingAndReportsTheDenial() async {
        center.status = .notDetermined
        center.userAllows = false
        let read = habit("Read")

        let permission = await service.enableHabitReminder(for: read)

        XCTAssertEqual(permission, .denied)
        XCTAssertEqual(center.events, [.request])
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// Denied earlier: no request (it would show nothing anyway), no add, the denial surfaced —
    /// and a request left from before the edit is taken out rather than left to fire at its old
    /// time the moment notifications come back on.
    func testDeniedSchedulesNothingAndRemovesAStaleRequest() async {
        center.status = .denied
        let read = habit("Read")
        center.seed(reminderID(read))

        let permission = await service.enableHabitReminder(for: read)

        XCTAssertEqual(permission, .denied)
        XCTAssertEqual(center.events, [])
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// Already allowed — full or provisional — schedules straight away, without asking again.
    func testAuthorizedOrProvisionalSchedulesWithoutAsking() async throws {
        for status in [UNAuthorizationStatus.authorized, .provisional] {
            center.status = status
            let read = habit("Read", hour: 21, minute: 5)

            let permission = await service.enableHabitReminder(for: read)

            XCTAssertEqual(permission, .allowed, "\(status.rawValue)")
            XCTAssertFalse(center.events.contains(.request), "\(status.rawValue)")
            let trigger = try XCTUnwrap(center.trigger(reminderID(read)))
            XCTAssertEqual(trigger.dateComponents, DateComponents(hour: 21, minute: 5))
        }
    }

    /// The sheet settles permission before it saves: the same prompt-once rule, and the answer
    /// sticks — a second call after "Don't Allow" does not ask again.
    func testEnsurePermissionAsksOnlyWhileUndetermined() async {
        center.status = .notDetermined
        center.userAllows = false

        let first = await service.ensureReminderPermission()
        let second = await service.ensureReminderPermission()

        XCTAssertEqual(first, .denied)
        XCTAssertEqual(second, .denied)
        XCTAssertEqual(center.events, [.request])
    }

    /// "Allow" at the habit sheet's prompt schedules every reminder-on habit already in the
    /// store, not only the one being saved. The launch pass ran while the status was undecided;
    /// habits that came by sync or restore, or were saved before the grant, otherwise waited for
    /// the next cold launch.
    func testAllowAtTheSheetSchedulesTheRemindersAlreadyInTheStore() async throws {
        let context = ModelContext(container)
        let synced = habit("Synced", hour: 6, minute: 0)
        let restored = habit("Restored", hour: 22, minute: 15)
        let archived = habit("Archived", archived: true)
        let quiet = habit("Quiet", reminder: false)
        for habit in [synced, restored, archived, quiet] { context.insert(habit) }
        try context.save()
        center.status = .notDetermined
        center.userAllows = true

        let permission = await service.ensureReminderPermission(schedulingExistingIn: container)

        XCTAssertEqual(permission, .allowed)
        XCTAssertEqual(Set(center.pending.keys), [reminderID(synced), reminderID(restored)])
        XCTAssertEqual(center.trigger(reminderID(restored))?.dateComponents, DateComponents(hour: 22, minute: 15))
        XCTAssertEqual(center.events.first, .request, "nothing is added before the answer")
    }

    /// The same through `enableHabitReminder` when nothing settled permission first: the saved
    /// habit's own container is used, and the habit is scheduled along with the rest.
    func testAGrantInsideEnableHabitReminderSchedulesTheWholeStore() async throws {
        let context = ModelContext(container)
        let other = habit("Other", hour: 6, minute: 0)
        let saved = habit("Saved", hour: 7, minute: 30)
        context.insert(other)
        context.insert(saved)
        try context.save()
        center.status = .notDetermined

        let permission = await service.enableHabitReminder(for: saved)

        XCTAssertEqual(permission, .allowed)
        XCTAssertEqual(Set(center.pending.keys), [reminderID(other), reminderID(saved)])
    }

    /// "Don't Allow", or a status decided earlier, schedules nothing from the store: a denied
    /// add is refused anyway, and an authorized device had its launch pass.
    func testNoGrantAtThePromptLeavesTheStoreAlone() async throws {
        let context = ModelContext(container)
        context.insert(habit("Synced"))
        try context.save()

        center.status = .notDetermined
        center.userAllows = false
        let declined = await service.ensureReminderPermission(schedulingExistingIn: container)
        center.status = .authorized
        let already = await service.ensureReminderPermission(schedulingExistingIn: container)

        XCTAssertEqual(declined, .denied)
        XCTAssertEqual(already, .allowed)
        XCTAssertTrue(center.pending.isEmpty)
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
