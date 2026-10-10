import XCTest
import SwiftData
import UserNotifications
@testable import Stride

/// A reminder's Mark Done, Add 1 and Snooze 1 Hour (RELEASE-1.4.0.md D4), through the handler's
/// injected environment: an in-memory store (or one on disk, for the two-process case), recording
/// closures for the widgets, badge, snooze and banners, a pinned clock and calendar. Nothing here
/// reaches the host app's store, notification store or server — the `SharedModelContainer.opened`
/// the shipping environment reads is the host's real store (StoreLaunchTests).
///
/// `UNNotificationResponse` cannot be constructed, so the tests start at the route, which the
/// router's own suite (StrideTests/NotificationRouterTests) pins from the identifiers; a few go
/// through `NotificationRouter.route` here to show the two together.
@MainActor
final class NotificationActionHandlerTests: XCTestCase {

    /// What the handler did outside the store, in order.
    private final class Recorder {
        var events: [String] = []
        var snoozes: [(habitID: UUID, day: Date)] = []
        var syncs = 0
        var synced: XCTestExpectation?
    }

    private var container: ModelContainer!
    private var context: ModelContext!
    private var recorder: Recorder!

    private let losAngeles = "America/Los_Angeles"
    private let newYork = "America/New_York"

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        recorder = Recorder()
    }

    override func tearDown() {
        recorder = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// A wall-clock time in `zone`.
    private func at(_ zone: String, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A day-key: that date's midnight in UTC.
    private func key(_ year: Int, _ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The handler over `container` (nil: the launch could not open the store), with every
    /// effect recorded and the calendar pinned to `zone`.
    private func makeHandler(_ container: ModelContainer?, zone: String = "America/Los_Angeles",
                             sync: (@MainActor (ModelContainer) async -> Void)? = nil) -> NotificationActionHandler {
        let recorder = self.recorder!
        let calendar = self.calendar(zone)
        let effects = CheckInEffects(
            reloadWidgets: { recorder.events.append("reload") },
            updateBadge: { _ in recorder.events.append("badge") },
            cancelSnooze: { recorder.events.append("cancelSnooze \($0.uuidString)") },
            withdrawDelivered: { recorder.events.append("withdraw \($0.uuidString)") },
            submitRefresh: { recorder.events.append("submitRefresh") })
        return NotificationActionHandler(environment: .init(
            container: { container },
            effects: effects,
            sync: sync ?? { _ in
                recorder.syncs += 1
                recorder.synced?.fulfill()
            },
            scheduleSnooze: { habit, day in recorder.snoozes.append((habit.id, day)) },
            now: { Date() },
            calendar: { calendar }))
    }

    private func habit(_ name: String, kind: HabitKind = .binary, archived: Bool = false) throws -> Habit {
        let habit = Habit(name: name)
        habit.habitKind = kind
        if kind == .count { habit.targetValue = 8 }
        habit.reminderEnabled = true
        habit.isArchived = archived
        context.insert(habit)
        try context.save()
        return habit
    }

    /// The habit's records as the store has them now, through a context of their own.
    private func records(of habit: Habit, in container: ModelContainer? = nil) throws -> [HabitRecord] {
        let id = habit.id
        let fresh = ModelContext(container ?? self.container)
        let found = try fresh.fetch(FetchDescriptor<Habit>(predicate: #Predicate<Habit> { $0.id == id }))
        return try XCTUnwrap(found.first).records
    }

    /// What every saved check-in does after the save, in this order (D4, "After the write").
    private func effectsAfterCheckIn(of habit: Habit) -> [String] {
        ["reload", "cancelSnooze \(habit.id.uuidString)", "withdraw \(habit.id.uuidString)", "submitRefresh", "badge"]
    }

    // MARK: - Host wiring

    /// Set in StrideApp.init and held strongly: the center keeps its delegate weakly, so a
    /// handler nothing else held would already be gone here, and a lock-screen Mark Done would
    /// have no one to go to. The categories were registered at the same launch (read-only here).
    func testTheHostsDelegateIsTheHandlerAndItsCategoriesAreRegistered() async {
        XCTAssertIdentical(UNUserNotificationCenter.current().delegate, NotificationActionHandler.shared)
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        XCTAssertTrue(Set(categories.map(\.identifier)).isSuperset(of: ["stride.habit.binary", "stride.habit.count"]))
    }

    // MARK: - The write never deletes

    /// The design review's "stale-category-addone-untoggles-binary": a count habit's "Add 1"
    /// banner, tapped after the habit became yes/no and was done. `tap` would have deleted the
    /// day's record and its tombstone would have taken it off every device. Nothing changes, no
    /// tombstone is queued, nothing is synced.
    func testAStaleAddOneOnADoneYesNoHabitChangesNothing() async throws {
        let meditate = try habit("Meditate")
        let today = HabitCalendar.dayKey(forInstant: Date(), calendar: calendar(losAngeles))
        let record = HabitRecord(date: today)
        meditate.records.append(record)
        try context.save()
        let route = NotificationRouter.route(actionIdentifier: NotificationRouter.addOneAction,
                                             categoryIdentifier: NotificationRouter.countCategory,
                                             userInfo: ["habitId": meditate.id.uuidString])

        let outcome = await makeHandler(container).perform(route: route, delivered: Date(), responded: Date())

        XCTAssertEqual(outcome, .alreadyDone(day: today))
        let after = try records(of: meditate)
        XCTAssertEqual(after.map(\.id), [record.id], "the day's record is still there")
        XCTAssertEqual(after.first?.value, 1)
        XCTAssertFalse(SyncDeletionQueue.live.pending().entries.contains(record.id.uuidString), "no tombstone")
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.syncs, 0)
    }

    /// A count habit gains one unit per action, past the target too ("Add 1") — and a "Mark Done"
    /// banner left from when it was yes/no adds one as well: the kind now decides, not the button.
    /// After the save: `.habitDataChanged`, the effects in order, then the action's own sync.
    func testACountHabitGainsOneUnitWhicheverButtonWasTapped() async throws {
        let water = try habit("Water", kind: .count)
        let today = HabitCalendar.dayKey(forInstant: Date(), calendar: calendar(losAngeles))
        water.records.append(HabitRecord(date: today, value: 3))
        try context.save()
        let posted = expectation(forNotification: .habitDataChanged, object: nil)
        posted.assertForOverFulfill = false   // the second action below posts it again
        recorder.synced = expectation(description: "the action's sync")

        let outcome = await makeHandler(container).perform(
            route: NotificationRouter.route(actionIdentifier: NotificationRouter.markDoneAction,
                                            categoryIdentifier: NotificationRouter.binaryCategory,
                                            userInfo: ["habitId": water.id.uuidString]),
            delivered: Date(), responded: Date())

        XCTAssertEqual(outcome, .checkedIn(day: today))
        XCTAssertEqual(try records(of: water).map(\.value), [4])
        XCTAssertEqual(recorder.events, effectsAfterCheckIn(of: water))
        await fulfillment(of: [posted, recorder.synced!], timeout: 5)
        XCTAssertEqual(recorder.syncs, 1)

        recorder.synced = expectation(description: "the second action's sync")
        let second = await makeHandler(container).perform(route: .checkIn(habitID: water.id, day: nil),
                                                          delivered: Date(), responded: Date())
        XCTAssertEqual(second, .checkedIn(day: today))
        XCTAssertEqual(try records(of: water).map(\.value), [5], "one more, past nothing: no ceiling at the target")
        await fulfillment(of: [recorder.synced!], timeout: 5)
    }

    /// Mark Done tapped twice (two devices' banners, or a double tap) writes one check-in: the
    /// second finds the day done and does nothing at all.
    func testMarkDoneTwiceWritesOnce() async throws {
        let read = try habit("Read")
        let handler = makeHandler(container)
        recorder.synced = expectation(description: "one sync")

        let first = await handler.perform(route: .checkIn(habitID: read.id, day: nil), delivered: Date(), responded: Date())
        let second = await handler.perform(route: .checkIn(habitID: read.id, day: nil), delivered: Date(), responded: Date())

        let today = HabitCalendar.dayKey(forInstant: Date(), calendar: calendar(losAngeles))
        XCTAssertEqual(first, .checkedIn(day: today))
        XCTAssertEqual(second, .alreadyDone(day: today))
        XCTAssertEqual(try records(of: read).count, 1)
        XCTAssertEqual(recorder.events, effectsAfterCheckIn(of: read))
        await fulfillment(of: [recorder.synced!], timeout: 5)
        XCTAssertEqual(recorder.syncs, 1)
    }

    /// Archived, deleted (or re-made under new ids by "Restore as new copies"), and a launch that
    /// could not open the store: nothing written, nothing else done.
    func testArchivedDeletedAndNoStoreAreNoOps() async throws {
        let archived = try habit("Old", archived: true)
        let handler = makeHandler(container)

        let onArchived = await handler.perform(route: .checkIn(habitID: archived.id, day: nil), delivered: Date(), responded: Date())
        let onDeleted = await handler.perform(route: .checkIn(habitID: UUID(), day: nil), delivered: Date(), responded: Date())
        let snoozeOnArchived = await handler.perform(route: .snooze(habitID: archived.id, day: nil), delivered: Date(), responded: Date())
        let noStore = await makeHandler(nil).perform(route: .checkIn(habitID: archived.id, day: nil), delivered: Date(), responded: Date())
        let ignored = await handler.perform(route: .none, delivered: Date(), responded: Date())

        XCTAssertEqual(onArchived, .noHabit)
        XCTAssertEqual(onDeleted, .noHabit)
        XCTAssertEqual(snoozeOnArchived, .noHabit)
        XCTAssertEqual(noStore, .storeUnavailable)
        XCTAssertEqual(ignored, .ignored)
        XCTAssertTrue(try records(of: archived).isEmpty)
        XCTAssertEqual(recorder.events, [])
        XCTAssertTrue(recorder.snoozes.isEmpty)
        XCTAssertEqual(recorder.syncs, 0)
    }

    // MARK: - Which day

    /// The design review's blocker, end to end: the default 20:00 reminder in US Eastern daylight
    /// time fires at exactly 00:00:00Z of the NEXT date, which the idempotent `dayKey(for:)` took
    /// for tomorrow's key. Mark Done at 20:01 checks off the 15th, not the 16th.
    func testATwentyHundredEasternReminderCreditsItsOwnDay() async throws {
        let read = try habit("Read")
        let delivered = at(newYork, 2026, 7, 15, 20)
        XCTAssertEqual(delivered, key(2026, 7, 16), "the trap: a fire time that is a UTC midnight")

        let outcome = await makeHandler(container, zone: newYork).perform(
            route: .checkIn(habitID: read.id, day: nil), delivered: delivered, responded: at(newYork, 2026, 7, 15, 20, 1))

        XCTAssertEqual(outcome, .checkedIn(day: key(2026, 7, 15)))
        XCTAssertEqual(try records(of: read).map(\.date), [key(2026, 7, 15)])
    }

    /// A snooze banner delivered after midnight carries the day its reminder was for, and Mark Done
    /// on it credits that day — not the day the snooze happened to arrive on.
    func testMarkDoneOnASnoozeAcrossMidnightCreditsTheDayItCarries() async throws {
        let read = try habit("Read")
        let delivered = at(losAngeles, 2026, 10, 13, 0, 30)   // Monday 23:30's reminder, snoozed

        let outcome = await makeHandler(container).perform(
            route: .checkIn(habitID: read.id, day: key(2026, 10, 12)), delivered: delivered,
            responded: at(losAngeles, 2026, 10, 13, 0, 31))

        XCTAssertEqual(outcome, .checkedIn(day: key(2026, 10, 12)))
        XCTAssertEqual(try records(of: read).map(\.date), [key(2026, 10, 12)])
    }

    /// Snooze hands the scheduler the day the banner was for: the delivered day for an original
    /// reminder, the carried one for a snooze of a snooze (still creditable shortly after
    /// midnight), and today for a stale one — what `ReminderDay.resolve` gives, so the snooze's
    /// Mark Done credits what the original's would have. Nothing is written.
    func testSnoozeCarriesTheResolvedDay() async throws {
        let read = try habit("Read")
        let handler = makeHandler(container)

        let original = await handler.perform(route: .snooze(habitID: read.id, day: nil),
                                             delivered: at(losAngeles, 2026, 10, 12, 23, 30),
                                             responded: at(losAngeles, 2026, 10, 12, 23, 31))
        let again = await handler.perform(route: .snooze(habitID: read.id, day: key(2026, 10, 12)),
                                          delivered: at(losAngeles, 2026, 10, 13, 0, 31),
                                          responded: at(losAngeles, 2026, 10, 13, 0, 35))
        let stale = await handler.perform(route: .snooze(habitID: read.id, day: key(2026, 10, 12)),
                                          delivered: at(losAngeles, 2026, 10, 13, 0, 31),
                                          responded: at(losAngeles, 2026, 10, 15, 9))

        XCTAssertEqual(original, .snoozed(day: key(2026, 10, 12)))
        XCTAssertEqual(again, .snoozed(day: key(2026, 10, 12)))
        XCTAssertEqual(stale, .snoozed(day: key(2026, 10, 15)))
        XCTAssertEqual(recorder.snoozes.map(\.habitID), [read.id, read.id, read.id])
        XCTAssertEqual(recorder.snoozes.map(\.day), [key(2026, 10, 12), key(2026, 10, 12), key(2026, 10, 15)])
        XCTAssertTrue(try records(of: read).isEmpty)
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.syncs, 0)
    }

    // MARK: - Another process

    /// The widget checks in from its own process, through its own container over the same file;
    /// the app's container has already loaded the record at the old value. The action reads the
    /// store through a fresh context, so it adds to the widget's unit instead of overwriting it
    /// with the app's stale one: 1 → 2 (widget) → 3 (action), seen the same from both sides.
    func testAnActionAddsToACountTheWidgetSavedFromAnotherContainer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Stride.store")
        let app = try SharedModelContainer.makeContainer(at: url)
        let widget = try SharedModelContainer.makeContainer(at: url)
        let today = HabitCalendar.dayKey(forInstant: Date(), calendar: calendar(losAngeles))

        let water = Habit(name: "Water")
        water.habitKind = .count
        water.targetValue = 8
        water.records = [HabitRecord(date: today, value: 1)]
        app.mainContext.insert(water)
        try app.mainContext.save()
        XCTAssertEqual(water.records.first?.value, 1, "the app holds the record at 1")

        let id = water.id
        let widgetContext = ModelContext(widget)
        let inWidget = try XCTUnwrap(widgetContext.fetch(FetchDescriptor<Habit>(predicate: #Predicate<Habit> { $0.id == id })).first)
        HabitCheckIn.tap(inWidget, on: today, in: widgetContext)
        try widgetContext.save()

        recorder.synced = expectation(description: "the action's sync")
        let outcome = await makeHandler(app).perform(route: .checkIn(habitID: id, day: nil), delivered: Date(), responded: Date())

        XCTAssertEqual(outcome, .checkedIn(day: today))
        XCTAssertEqual(try records(of: water, in: widget).map(\.value), [3])
        XCTAssertEqual(try records(of: water, in: app).map(\.value), [3])
        await fulfillment(of: [recorder.synced!], timeout: 5)
    }

    // MARK: - The sync

    /// An action saved while a sync is already running is still pushed in seconds: that run planned
    /// its push before the write and turns a second caller away rather than queueing it, so the
    /// shipping environment's sync waits it out and runs one of its own (`.background`). Through
    /// the real SyncService over a stub server, installed as `shared` for the test.
    func testAnActionDuringASyncIsPushedByARunOfItsOwn() async throws {
        let server = StubServer()
        let local = ScratchDefaults("action.sync.local")
        let appGroup = ScratchDefaults("action.sync.appGroup")
        let recovery = ScratchRecoveryLog()
        let sync = SyncService(api: server.makeClient(tokenStore: InMemoryTokenStore(SyncSession.accountA.token)),
                               defaults: local.defaults,
                               deletionQueue: SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults),
                               sessions: FakeSyncSessions(.accountA), recoveryLog: recovery.log)
        SyncService.testOverride = sync
        addTeardownBlock { @MainActor in
            SyncService.testOverride = nil
            server.stop()
            local.remove()
            appGroup.remove()
            recovery.remove()
        }
        // An owned store with a live cursor: each run pushes first, then pulls.
        let owner = SyncSession.accountA.account
        SyncOwnerStore(defaults: local.defaults).set(SyncOwner(owner))
        SyncDefaultsCursorStore(defaults: local.defaults)
            .setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400)), for: owner.id)
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        let pull = SyncStubBodies.pull()
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .ok(pull)
        }
        let read = Habit(name: "Read")
        container.mainContext.insert(read)
        try container.mainContext.save()

        let inFlight = Task { await sync.sync(context: container.mainContext) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.paths.contains("/v1/sync/pull") {
            guard ContinuousClock.now < deadline else { return XCTFail("the first sync never pulled") }
            try await Task.sleep(for: .milliseconds(10))
        }

        let shipping = NotificationActionHandler.Environment.live.sync
        let synced = expectation(description: "the action's own sync")
        let outcome = await makeHandler(container, sync: { container in
            await shipping(container)
            synced.fulfill()
        }).perform(route: .checkIn(habitID: read.id, day: nil), delivered: Date(), responded: Date())

        XCTAssertTrue(sync.isSyncing, "the first run was still in flight when the action saved")
        await fulfillment(of: [synced], timeout: 10)
        let firstRan = await inFlight.value
        XCTAssertTrue(firstRan)
        guard case .checkedIn = outcome else { return XCTFail("\(outcome)") }
        let record = try XCTUnwrap(records(of: read).first)
        let pushes = server.requests.filter { $0.path == "/v1/sync/push" }
        XCTAssertEqual(pushes.count, 2, "the in-flight run's push, then the action's own")
        let entries = (pushes.last?.json?["entries"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(entries, [record.id.uuidString])
    }
}
