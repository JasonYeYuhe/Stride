import XCTest
import SwiftData
import UserNotifications
@testable import Stride

/// Records what NotificationService asks the system to schedule, with the real center's
/// replace-by-identifier semantics, instead of filling the host app's pending store — and plays
/// the user's answer to the permission prompt instead of raising a real one.
/// Only ever touched from one test at a time (the service is @MainActor and awaits each call,
/// and this center calls its completion handlers synchronously), hence the unchecked Sendable —
/// except the badge, which the service sets from a Task off the main actor, so it has a lock.
final class RecordingCenter: NotificationScheduling, @unchecked Sendable {
    enum Event: Equatable { case request, add(String) }

    private(set) var pending: [String: UNNotificationRequest] = [:]
    private(set) var removed: [String] = []
    /// Requests and adds in the order they happened — the fresh-install bug was an add while
    /// the status was still `.notDetermined`, with no request before it.
    private(set) var events: [Event] = []

    /// Banners in Notification Center, by identifier (a delivery replaces one with the same id,
    /// as the real center's does).
    private(set) var delivered: [String: DeliveredNotification] = [:]
    private(set) var removedDelivered: [String] = []
    /// The last set registered, and how many times.
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var categoryRegistrations = 0

    private let badgeLock = NSLock()
    private var _badgeCounts: [Int] = []
    var badgeCounts: [Int] { badgeLock.withLock { _badgeCounts } }

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

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
        categoryRegistrations += 1
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
        for id in identifiers { delivered.removeValue(forKey: id) }
    }

    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([DeliveredNotification]) -> Void) {
        completionHandler(Array(delivered.values))
    }

    func setBadgeCount(_ newBadgeCount: Int) async throws {
        badgeLock.withLock { _badgeCounts.append(newBadgeCount) }
    }

    /// Something already in the store from an earlier launch.
    func seed(_ identifier: String) {
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 0), repeats: true)
        pending[identifier] = UNNotificationRequest(identifier: identifier, content: UNNotificationContent(), trigger: trigger)
    }

    /// A banner in Notification Center.
    func deliver(_ identifier: String, at date: Date = Date(), category: String = "", habitID: UUID? = nil) {
        delivered[identifier] = DeliveredNotification(identifier: identifier, date: date,
                                                      categoryIdentifier: category, habitID: habitID)
    }

    func trigger(_ identifier: String) -> UNCalendarNotificationTrigger? {
        pending[identifier]?.trigger as? UNCalendarNotificationTrigger
    }

    func category(_ identifier: String) -> UNNotificationCategory? {
        categories.first { $0.identifier == identifier }
    }

    /// The badge is set from a Task (fire and forget, as on the device): wait for the next one.
    func waitForBadge(after count: Int, timeout: Duration = .seconds(2)) async -> Int? {
        let deadline = ContinuousClock.now + timeout
        while badgeCounts.count <= count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return badgeCounts.count > count ? badgeCounts.last : nil
    }
}

@MainActor
final class NotificationServiceTests: XCTestCase {

    private var center: RecordingCenter!
    private var scratch: ScratchDefaults!
    private var service: NotificationService!
    private var container: ModelContainer!
    /// Kept for the test's length: a habit's `modelContext` — through which a single schedule
    /// finds the rest of its store for the budget — is only as alive as its context.
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        center = RecordingCenter()
        scratch = ScratchDefaults("notifications")
        service = NotificationService(center: center, defaults: scratch.defaults)
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    override func tearDown() {
        NotificationService.testOverride = nil
        scratch.remove()
        service = nil
        center = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func habit(_ name: String, reminder: Bool = true, hour: Int = 7, minute: Int = 30,
                       archived: Bool = false, kind: HabitKind = .binary,
                       days: Set<Int>? = nil) -> Habit {
        let habit = Habit(name: name)
        habit.reminderEnabled = reminder
        habit.reminderHour = hour
        habit.reminderMinute = minute
        habit.isArchived = archived
        habit.habitKind = kind
        if kind == .count { habit.targetValue = 8 }
        if let days {
            habit.schedule = .specificDays
            habit.activeDaysMask = days.reduce(0) { $0 | (1 << $1) }   // bit 0 = Sunday, as AddHabitView
        }
        return habit
    }

    /// Monday, Wednesday, Friday — bits 1, 3, 5 — whose reminders are weekdays 2, 4, 6.
    private let monWedFri: Set<Int> = [1, 3, 5]

    private func reminderID(_ habit: Habit) -> String { "stride.habit.reminder." + habit.id.uuidString }
    private func weekdayID(_ habit: Habit, _ weekday: Int) -> String { reminderID(habit) + ".\(weekday)" }
    private func snoozeID(_ habit: Habit) -> String { "stride.habit.snooze." + habit.id.uuidString }
    /// Every id a habit can have: the legacy daily one, seven weekday ones, the snooze.
    private func allIDs(_ habit: Habit) -> Set<String> {
        Set([reminderID(habit)] + (1...7).map { weekdayID(habit, $0) } + [snoozeID(habit)])
    }

    private func insert(_ habits: Habit...) throws {
        for habit in habits { context.insert(habit) }
        try context.save()
    }

    // MARK: - Per-habit reminders

    /// A daily habit: one repeating daily trigger at its hour and minute, under the 1.3.x id (so
    /// an installed 1.3.x request is simply replaced). A trigger with any other component (a
    /// weekday, a day) would fire once a week or month. 1.4.0: the banner carries the category
    /// of the habit's kind, the habit id the action handler acts on, and the habit as its thread.
    func testHabitReminderIsADailyRepeatingTriggerAtItsTime() throws {
        let read = habit("Read", hour: 7, minute: 30)

        service.scheduleHabitReminder(for: read)

        let trigger = try XCTUnwrap(center.trigger(reminderID(read)))
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents, DateComponents(hour: 7, minute: 30))
        let content = try XCTUnwrap(center.pending[reminderID(read)]?.content)
        XCTAssertEqual(content.title, "⭐ Read")
        XCTAssertEqual(content.categoryIdentifier, "stride.habit.binary")
        XCTAssertEqual(content.userInfo["habitId"] as? String, read.id.uuidString)
        XCTAssertEqual(content.threadIdentifier, read.id.uuidString)
        XCTAssertEqual(center.pending.count, 1)
    }

    /// Acceptance (3): a Mon/Wed/Fri habit has exactly three pending triggers, one per day, each
    /// weekly at its time — not 1.3.x's daily one, which nagged on the rest days. A count habit's
    /// carry its own category (Add 1).
    func testMonWedFriHabitGetsExactlyThreeWeekdayTriggers() throws {
        let water = habit("Water", hour: 18, minute: 15, kind: .count, days: monWedFri)

        service.scheduleHabitReminder(for: water)

        XCTAssertEqual(Set(center.pending.keys), [weekdayID(water, 2), weekdayID(water, 4), weekdayID(water, 6)])
        for weekday in [2, 4, 6] {
            let request = try XCTUnwrap(center.pending[weekdayID(water, weekday)])
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertTrue(trigger.repeats)
            XCTAssertEqual(trigger.dateComponents, DateComponents(hour: 18, minute: 15, weekday: weekday))
            XCTAssertEqual(request.content.categoryIdentifier, "stride.habit.count")
            XCTAssertEqual(request.content.userInfo["habitId"] as? String, water.id.uuidString)
            XCTAssertEqual(request.content.threadIdentifier, water.id.uuidString)
        }
    }

    /// Daily → specific days → daily: each schedule removes the other shape first, so the old
    /// daily trigger cannot keep firing on rest days, nor the weekday ones after the switch back.
    func testSwitchingBetweenDailyAndSpecificDaysRemovesTheOtherShape() {
        let gym = habit("Gym")
        service.scheduleHabitReminder(for: gym)
        XCTAssertEqual(Set(center.pending.keys), [reminderID(gym)])

        gym.schedule = .specificDays
        gym.activeDaysMask = monWedFri.reduce(0) { $0 | (1 << $1) }
        service.scheduleHabitReminder(for: gym)
        XCTAssertEqual(Set(center.pending.keys), [weekdayID(gym, 2), weekdayID(gym, 4), weekdayID(gym, 6)])

        gym.schedule = .daily
        service.scheduleHabitReminder(for: gym)
        XCTAssertEqual(Set(center.pending.keys), [reminderID(gym)])
    }

    /// A reschedule is not the user ending a snooze: launch, a foreground sync, an edit and a
    /// language change all schedule, and the snooze must outlive them.
    func testSchedulingKeepsThePendingSnooze() {
        let read = habit("Read")
        center.seed(snoozeID(read))

        service.scheduleHabitReminder(for: read)

        XCTAssertEqual(Set(center.pending.keys), [reminderID(read), snoozeID(read)])
    }

    /// Switching a reminder off, or archiving the habit, has to take the old request out — not
    /// just skip adding a new one. The request repeats in the system store until removed.
    func testDisabledOrArchivedHabitLosesItsExistingReminder() {
        let off = habit("Off", reminder: false)
        let archived = habit("Archived", archived: true)
        center.seed(reminderID(off))
        center.seed(weekdayID(archived, 3))
        center.seed(snoozeID(archived))

        service.scheduleHabitReminder(for: off)
        service.scheduleHabitReminder(for: archived)

        XCTAssertTrue(center.pending.isEmpty)
    }

    /// Reminder off, archive, delete: all eight reminder ids and the snooze, pending AND
    /// delivered — a banner left in Notification Center kept offering Mark Done for a habit that
    /// is gone. Another habit's are untouched.
    func testRemoveHabitReminderRemovesEveryVariantPendingAndDelivered() {
        let deleted = habit("Deleted")
        let kept = habit("Kept")
        for id in allIDs(deleted).union(allIDs(kept)) {
            center.seed(id)
            center.deliver(id)
        }

        service.removeHabitReminder(for: deleted.id)

        XCTAssertEqual(Set(center.pending.keys), allIDs(kept))
        XCTAssertEqual(Set(center.delivered.keys), allIDs(kept))
        XCTAssertEqual(Set(center.removed), allIDs(deleted))
        XCTAssertEqual(Set(center.removedDelivered), allIDs(deleted))
        XCTAssertEqual(allIDs(deleted).count, 9)
    }

    /// The launch-time prune: a habit deleted or archived on another device arrives through
    /// sync, which cannot reach this service, so its reminder would fire every day forever for
    /// a habit with no row left to switch it off. Other reminders — the daily evening one — are
    /// not this prune's to touch.
    func testRescheduleAllPrunesOrphansAndKeepsEverythingElse() throws {
        let active = habit("Active", hour: 6, minute: 45)
        let archivedElsewhere = habit("Archived", archived: true)
        let noReminder = habit("Quiet", reminder: false)
        try insert(active, archivedElsewhere, noReminder)

        let deletedElsewhere = "stride.habit.reminder." + UUID().uuidString
        center.seed(deletedElsewhere)
        center.seed(reminderID(archivedElsewhere))
        center.seed("stride.daily.evening")

        service.rescheduleAllHabitReminders(modelContainer: container)

        XCTAssertEqual(Set(center.pending.keys), [reminderID(active), "stride.daily.evening"])
        XCTAssertEqual(center.trigger(reminderID(active))?.dateComponents, DateComponents(hour: 6, minute: 45))
    }

    /// The first 1.4.0 launch over a 1.3.x store: a Mon/Wed/Fri habit's old daily request becomes
    /// its three weekday ones; a daily habit keeps its bare id; a snooze of a reminder-on habit
    /// survives (the 1.3.x prune kept only `prefix + uuid` and would have taken every weekday id and
    /// every snooze); snoozes of a habit whose reminder is off, and of no habit, go.
    func testUpgradeShapedPruneKeepsWeekdaysTheDailyIdAndLiveSnoozes() throws {
        let gym = habit("Gym", days: monWedFri)
        let read = habit("Read")
        let quiet = habit("Quiet", reminder: false)
        try insert(gym, read, quiet)
        center.seed(reminderID(gym))                                  // 1.3.x: daily, rest days too
        center.seed(reminderID(read))
        center.seed(snoozeID(gym))
        center.seed(snoozeID(quiet))
        center.seed("stride.habit.snooze." + UUID().uuidString)
        center.seed("stride.daily.evening")

        service.rescheduleAllHabitReminders(modelContainer: container)

        XCTAssertEqual(Set(center.pending.keys), [
            weekdayID(gym, 2), weekdayID(gym, 4), weekdayID(gym, 6),
            reminderID(read), snoozeID(gym), "stride.daily.evening",
        ])
    }

    /// The request budget: nine six-day habits are 54 weekday triggers, within 58; the tenth
    /// takes it to 60, and then EVERY specificDays habit falls back to its one daily trigger —
    /// the nine already scheduled too, or they would still crowd iOS's 64 and some reminder would
    /// silently never fire.
    func testTheHabitThatBreaksTheBudgetMovesEverySpecificDaysHabitToDaily() throws {
        let weekdays: Set<Int> = [1, 2, 3, 4, 5, 6]
        let nine = (1...9).map { habit("H\($0)", days: weekdays) }
        for habit in nine { try insert(habit) }
        service.scheduleAllHabitReminders(modelContainer: container)
        XCTAssertEqual(center.pending.count, 54)

        let tenth = habit("H10", days: weekdays)
        try insert(tenth)
        service.scheduleHabitReminder(for: tenth)

        XCTAssertEqual(Set(center.pending.keys), Set((nine + [tenth]).map(reminderID)))
    }

    // MARK: - Categories (RELEASE-1.4.0.md D4)

    /// Mark Done or Add 1 by kind, and Snooze 1 Hour, titled in the in-app language; none of them
    /// opens the app or asks for an unlock — the point is a check-in from the lock screen.
    func testCategoriesCarryTheActionsWithLocalizedTitlesAndNoForegroundOrUnlock() throws {
        service.registerCategories()

        XCTAssertEqual(center.categoryRegistrations, 1)
        XCTAssertEqual(Set(center.categories.map(\.identifier)), ["stride.habit.binary", "stride.habit.count"])
        let binary = try XCTUnwrap(center.category("stride.habit.binary"))
        let count = try XCTUnwrap(center.category("stride.habit.count"))
        XCTAssertEqual(binary.actions.map(\.identifier), ["stride.habit.action.markDone", "stride.habit.action.snooze"])
        XCTAssertEqual(count.actions.map(\.identifier), ["stride.habit.action.addOne", "stride.habit.action.snooze"])
        XCTAssertEqual(binary.actions.map(\.title), [appLocalized("Mark Done"), appLocalized("Snooze 1 Hour")])
        XCTAssertEqual(count.actions.map(\.title), [appLocalized("Add 1"), appLocalized("Snooze 1 Hour")])
        for action in binary.actions + count.actions {
            XCTAssertFalse(action.options.contains(.foreground), action.identifier)
            XCTAssertFalse(action.options.contains(.authenticationRequired), action.identifier)
            XCTAssertFalse(action.options.contains(.destructive), action.identifier)
        }
    }

    /// A language picked in the app re-registers the titles, and re-schedules the reminders whose
    /// text the system holds, through `shared` — this test's service. Japanese, whatever the
    /// machine's language: the titles are the catalog's, not English.
    func testALanguageChangeRegistersTheTitlesAgainInThatLanguage() throws {
        let manager = LanguageManager.shared
        let saved = manager.selectedLanguage
        let hadStored = UserDefaults.standard.object(forKey: "stride_app_language") != nil
        NotificationService.testOverride = service
        addTeardownBlock { @MainActor in
            manager.selectedLanguage = saved
            if !hadStored { UserDefaults.standard.removeObject(forKey: "stride_app_language") }
            NotificationService.testOverride = nil
        }
        if saved == .japanese { manager.selectedLanguage = .english }
        let before = center.categoryRegistrations

        manager.selectedLanguage = .japanese

        XCTAssertEqual(center.categoryRegistrations, before + 1)
        let binary = try XCTUnwrap(center.category("stride.habit.binary"))
        let count = try XCTUnwrap(center.category("stride.habit.count"))
        XCTAssertEqual(binary.actions.map(\.title), ["完了にする", "1時間後に再通知"])
        XCTAssertEqual(count.actions.map(\.title), ["1つ追加", "1時間後に再通知"])

        manager.selectedLanguage = .japanese   // no change, no registration
        XCTAssertEqual(center.categoryRegistrations, before + 1)
    }

    // MARK: - Snooze

    /// Snooze 1 Hour: one shot, an hour out, under the habit's snooze id, with the category, the
    /// habit and the day the reminder was for — what a Mark Done on it credits, even past midnight.
    func testSnoozeIsOneShotInAnHourCarryingTheCategoryHabitAndDay() throws {
        let water = habit("Water", kind: .count)
        let day = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 10, day: 12))!

        service.scheduleSnooze(for: water, day: day)

        let request = try XCTUnwrap(center.pending[snoozeID(water)])
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 3_600)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(request.content.categoryIdentifier, "stride.habit.count")
        XCTAssertEqual(request.content.userInfo["habitId"] as? String, water.id.uuidString)
        XCTAssertEqual(request.content.userInfo["day"] as? String, "2026-10-12")
        XCTAssertEqual(request.content.threadIdentifier, water.id.uuidString)
        XCTAssertEqual(center.pending.count, 1)
        // What the router reads back from it.
        XCTAssertEqual(NotificationRouter.route(actionIdentifier: "stride.habit.action.addOne",
                                                categoryIdentifier: request.content.categoryIdentifier,
                                                userInfo: request.content.userInfo),
                       .checkIn(habitID: water.id, day: day))

        service.cancelSnooze(for: water.id)
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// Only for a habit whose reminder is on: the launch prune would remove any other.
    func testNoSnoozeForAHabitWhoseReminderIsOff() {
        service.scheduleSnooze(for: habit("Quiet", reminder: false), day: HabitCalendar.dayKey(forInstant: Date()))
        XCTAssertTrue(center.pending.isEmpty)
    }

    // MARK: - Delivered banners and the pass after a data change

    /// Banners delivered before today go; today's stay; the evening reminder is not ours to
    /// withdraw (it has no buttons).
    func testPruneDeliveredBeforeTodayTakesOnlyOlderHabitBanners() {
        let read = habit("Read")
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        center.deliver(weekdayID(read, 2), at: yesterday, category: "stride.habit.binary", habitID: read.id)
        center.deliver(snoozeID(read), at: yesterday, category: "stride.habit.binary", habitID: read.id)
        center.deliver(reminderID(read), at: now, category: "stride.habit.binary", habitID: read.id)
        center.deliver("stride.daily.evening", at: yesterday)

        service.pruneDeliveredBeforeToday(now: now)

        XCTAssertEqual(Set(center.delivered.keys), [reminderID(read), "stride.daily.evening"])
    }

    /// The pass after a data change: the badge counts what is left today; a habit done today
    /// (here by the widget, which this process never saw) loses its snooze and its banners; a
    /// banner whose button is another kind's, or whose habit is gone, is withdrawn; the rest stay.
    func testRefreshAfterADataChangeSetsTheBadgeAndClearsWhatIsDone() async throws {
        let done = habit("Done")
        let open = habit("Open")
        let water = habit("Water", kind: .count)
        done.records = [HabitRecord(date: Date())]
        try insert(done, open, water)
        let gone = UUID()
        for habit in [done, open, water] { center.seed(snoozeID(habit)) }
        center.deliver(reminderID(done), category: "stride.habit.binary", habitID: done.id)
        center.deliver(reminderID(open), category: "stride.habit.binary", habitID: open.id)
        center.deliver(reminderID(water), category: "stride.habit.binary", habitID: water.id)   // became count
        center.deliver("stride.habit.reminder." + gone.uuidString, category: "stride.habit.count", habitID: gone)
        center.deliver("stride.daily.evening")

        service.refreshAfterDataChange(modelContainer: container)

        XCTAssertEqual(Set(center.pending.keys), [snoozeID(open), snoozeID(water)])
        XCTAssertEqual(Set(center.delivered.keys), [reminderID(open), "stride.daily.evening"])
        let badge = await center.waitForBadge(after: 0)
        XCTAssertEqual(badge, 2)
    }

    /// The action handler's badge: set before it returns, through the seam (not the host's).
    func testUpdateBadgeAndWaitSetsTheRemainingCount() async throws {
        let done = habit("Done")
        done.records = [HabitRecord(date: Date())]
        try insert(done, habit("Open"), habit("Archived", archived: true))

        await service.updateBadgeAndWait(modelContainer: container)

        XCTAssertEqual(center.badgeCounts, [1])
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
        let synced = habit("Synced", hour: 6, minute: 0)
        let restored = habit("Restored", hour: 22, minute: 15)
        let archived = habit("Archived", archived: true)
        let quiet = habit("Quiet", reminder: false)
        try insert(synced, restored, archived, quiet)
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
        try insert(habit("Synced"))

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
