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
        return NotificationActionHandler(environment: .init(
            container: { container },
            effects: makeEffects(),
            sync: sync ?? { _ in
                recorder.syncs += 1
                recorder.synced?.fulfill()
            },
            scheduleSnooze: { habit, day in recorder.snoozes.append((habit.id, day)) },
            now: { Date() },
            calendar: { calendar }))
    }

    /// Every effect after a check-in, recorded in order.
    private func makeEffects() -> CheckInEffects {
        let recorder = self.recorder!
        return CheckInEffects(
            reloadWidgets: { recorder.events.append("reload") },
            updateBadge: { _ in recorder.events.append("badge") },
            cancelSnooze: { recorder.events.append("cancelSnooze \($0.uuidString)") },
            withdrawDelivered: { recorder.events.append("withdraw \($0.uuidString)") },
            submitRefresh: { recorder.events.append("submitRefresh") })
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

    /// What `didReceive` reads of a response, for sending it the selector UIKit sends. Neither
    /// `UNNotificationResponse` nor `UNNotification` has a public initializer (and their coders'
    /// keys are private); the method reads them only through ObjC messages — `notification`,
    /// `actionIdentifier`, `request`, `date` — and the bridging thunk casts nothing, so these
    /// stand in. The request inside is a real one.
    private final class ResponseStandIn: NSObject {
        @objc let notification: NotificationStandIn
        @objc let actionIdentifier: String
        init(action: String, category: String, userInfo: [AnyHashable: Any]) {
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = category
            content.userInfo = userInfo
            notification = NotificationStandIn(
                request: UNNotificationRequest(identifier: "stride.habit.reminder.test", content: content, trigger: nil),
                date: Date())
            actionIdentifier = action
        }
    }

    private final class NotificationStandIn: NSObject {
        @objc let request: UNNotificationRequest
        @objc let date: Date
        init(request: UNNotificationRequest, date: Date) {
            self.request = request
            self.date = date
        }
    }

    /// The verification's blocker: UIKit's completion for a response delivered to a background
    /// scene asserts the main thread, and the delegate's async method — nonisolated, as a plain
    /// NSObject's is in this Swift 5.9 module — had its bridging thunk call that completion from
    /// the cooperative pool. 8 of 9 E2E responses aborted the app with "Call must be made on main
    /// thread", right after their write. The hosted suite drove `perform` only, which never goes
    /// through the thunk. This sends the ObjC selector itself, as UIKit does — the default tap
    /// (nothing to do) and a Mark Done (the write, the effects and the sync's start, then the
    /// return) — and asserts where the completion runs.
    func testTheSystemsSelectorCompletesOnTheMainThread() async throws {
        let selector = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        let handler = makeHandler(container)
        XCTAssertTrue(handler.responds(to: selector), "the async method is what answers UIKit's selector")
        typealias DidReceive = @convention(c) (NSObject, Selector, UNUserNotificationCenter, NSObject,
                                               @escaping @convention(block) () -> Void) -> Void
        let send = unsafeBitCast(handler.method(for: selector), to: DidReceive.self)
        let read = try habit("Read")
        recorder.synced = expectation(description: "the Mark Done's sync")
        let responses = [
            ("default tap", ResponseStandIn(action: UNNotificationDefaultActionIdentifier,
                                            category: NotificationRouter.binaryCategory,
                                            userInfo: ["habitId": read.id.uuidString])),
            ("Mark Done", ResponseStandIn(action: NotificationRouter.markDoneAction,
                                          category: NotificationRouter.binaryCategory,
                                          userInfo: ["habitId": read.id.uuidString])),
        ]

        for (name, response) in responses {
            final class Completion { var onMainThread: Bool? }
            let completion = Completion()
            let completed = expectation(description: "\(name): the completion")
            send(handler, selector, UNUserNotificationCenter.current(), response) {
                completion.onMainThread = Thread.isMainThread
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(completion.onMainThread, true, "\(name): UIKit's completion asserts the main thread")
        }
        XCTAssertEqual(try records(of: read).count, 1, "the Mark Done was written")
        await fulfillment(of: [recorder.synced!], timeout: 5)
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

    // MARK: - Today's check-ins (CheckInEffects)

    /// Today's week strip backfills the past six days. A backfill still gets the widgets, the
    /// refresh submit (the record has to reach the server) and the badge. It leaves the habit's
    /// snooze and banners alone: they ask for today, which is still not done, and nothing would put
    /// them back (W2 fix review: Thursday 20:30, Wednesday ticked off, Thursday's 21:00 snooze
    /// gone). A reminder's own action always ends them (`effectsAfterCheckIn`).
    func testABackfillLeavesTheSnoozeAndBannersAndDoesTheRest() async throws {
        let read = try habit("Read")

        await makeEffects().afterCheckIn(habitID: read.id, container: container, endsReminders: false)

        XCTAssertEqual(recorder.events, ["reload", "submitRefresh", "badge"])
    }

    /// Which of Today's days end them: the strip's days are local midnights, and Today first opens
    /// on `Date()`; both are keyed as the tap keys them. Thursday 20:30 in New York ends them for
    /// Thursday, not for Wednesday or any older day. At 00:40 on Friday, Thursday still does,
    /// because a reminder answered then would credit Thursday.
    func testTodaysRowEndsRemindersOnlyForTheDayTheyAskFor() {
        let cal = calendar(newYork)
        let evening = at(newYork, 2026, 7, 16, 20, 30)
        let thursday = cal.startOfDay(for: evening)
        let wednesday = cal.date(byAdding: .day, value: -1, to: thursday)!
        let lastSaturday = cal.date(byAdding: .day, value: -5, to: thursday)!

        XCTAssertTrue(CheckInEffects.endsReminders(checkingIn: thursday, now: evening, calendar: cal))
        XCTAssertTrue(CheckInEffects.endsReminders(checkingIn: evening, now: evening, calendar: cal))
        XCTAssertFalse(CheckInEffects.endsReminders(checkingIn: wednesday, now: evening, calendar: cal))
        XCTAssertFalse(CheckInEffects.endsReminders(checkingIn: lastSaturday, now: evening, calendar: cal))
        XCTAssertTrue(CheckInEffects.endsReminders(checkingIn: thursday, now: at(newYork, 2026, 7, 17, 0, 40), calendar: cal))
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

    /// A real SyncService over a stub server, signed in as account A, its store owned with a live
    /// cursor (each run pushes first, then pulls), and installed as `shared` — with a
    /// NotificationService over a recording center installed beside it, so the shipping
    /// environment's after-sync work reaches neither the host app's sync state nor its
    /// notification store. All of it undone at teardown. `center` is that NotificationService's.
    private func installStubbedSync(_ role: String) -> (server: StubServer, sync: SyncService, center: RecordingCenter) {
        let server = StubServer()
        let local = ScratchDefaults("\(role).local")
        let appGroup = ScratchDefaults("\(role).appGroup")
        let notifications = ScratchDefaults("\(role).notifications")
        let recovery = ScratchRecoveryLog()
        let sync = SyncService(api: server.makeClient(tokenStore: InMemoryTokenStore(SyncSession.accountA.token)),
                               defaults: local.defaults,
                               deletionQueue: SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults),
                               sessions: FakeSyncSessions(.accountA), recoveryLog: recovery.log)
        SyncService.testOverride = sync
        let center = RecordingCenter()
        NotificationService.testOverride = NotificationService(center: center, defaults: notifications.defaults)
        addTeardownBlock { @MainActor in
            SyncService.testOverride = nil
            NotificationService.testOverride = nil
            server.stop()
            local.remove()
            appGroup.remove()
            notifications.remove()
            recovery.remove()
        }
        let owner = SyncSession.accountA.account
        SyncOwnerStore(defaults: local.defaults).set(SyncOwner(owner))
        SyncDefaultsCursorStore(defaults: local.defaults)
            .setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400)), for: owner.id)
        return (server, sync, center)
    }

    /// An action saved while a sync is already running is still pushed in seconds: that run planned
    /// its push before the write and turns a second caller away rather than queueing it, so the
    /// shipping environment's sync waits it out and runs one of its own (`.background`). Through
    /// the real SyncService over a stub server, installed as `shared` for the test. On iOS the
    /// shipping sync is the refresh's run (`BackgroundSync.run`, `.live`): its after-sync work goes
    /// to the test's NotificationService, and its widget reload to the host's own timelines.
    ///
    /// That after-sync work is asserted too, on the test's center, and it pins the live wiring
    /// (verification, second fix pass): `testAnActionsSyncReloadsTheWidgetsAfterWhatItPulled`
    /// builds its sync through `sync(through:)` itself, so it passed with `Environment.live` back
    /// on W2's plain closure, whose pull nothing followed. Only `BackgroundSync.Environment.live`
    /// reaches this center here: the handler's own effects are the recording ones.
    func testAnActionDuringASyncIsPushedByARunOfItsOwn() async throws {
        let (server, sync, center) = installStubbedSync("action.sync")
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        // Never in this store: they arrive by the pull.
        let fromTheMac = [Habit(name: "Meditate"), Habit(name: "Stretch")]
        let pull = SyncStubBodies.pull(habits: fromTheMac.map { SyncStubBodies.habit($0) })
        server.on("GET", "/v1/sync/pull") { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return .ok(pull)
        }
        let read = Habit(name: "Read")
        read.reminderEnabled = true
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
        // The device's own zone, as the badge's count reads "today" in it.
        let outcome = await makeHandler(container, zone: TimeZone.current.identifier, sync: { container in
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
        // The run's after-sync work, over the store as the pulls left it: Read's reminder replaced,
        // and the badge counting the two pulled habits as the ones left today (Read is done; before
        // the pull the count was 0). `contains`: the host app's window observer recounts the host's
        // own store on any didSave, this test's included, through the same `shared`.
        XCTAssertNotNil(center.pending["stride.habit.reminder." + read.id.uuidString], "the reminders were rescheduled")
        XCTAssertTrue(center.badgeCounts.contains(2), "the badge was counted after the pull: \(center.badgeCounts)")
    }

    /// The verification's major. A lock-screen Mark Done launches a terminated Stride with no
    /// scene, so no window's didSave observer exists, and the action's sync pulls what other
    /// devices did. W2's sync did nothing after that: the widget kept the timeline it built
    /// before the pull, and its toggle acts on the store — a tap on a habit the Mac had checked
    /// off deleted that check-in on every device. The action's sync is now the refresh's run, so
    /// the widgets reload (with the refresh pass) AFTER the pull has been saved, then the
    /// reminders and badge — besides the reload of the action's own effects, which came before.
    func testAnActionsSyncReloadsTheWidgetsAfterWhatItPulled() async throws {
        let (server, sync, _) = installStubbedSync("action.pull")
        let fromTheMac = Habit(name: "Meditate")   // never in this store: it arrives by the pull
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull(habits: [SyncStubBodies.habit(fromTheMac)])))
        let read = try habit("Read")
        let pulledID = fromTheMac.id
        let recorder = self.recorder!
        let background = BackgroundSync.Environment(
            syncService: { sync },
            refreshAfterSync: { container in
                let pulled = (try? ModelContext(container).fetch(
                    FetchDescriptor<Habit>(predicate: #Predicate<Habit> { $0.id == pulledID }))) ?? []
                recorder.events.append(pulled.isEmpty ? "widgets, nothing pulled yet" : "widgets, after the pull")
            },
            afterSync: { _ in recorder.events.append("reminders and badge") },
            sessionStored: { true },
            submitter: .init { _ in })
        let actionSync = NotificationActionHandler.Environment.sync(through: { background })
        let synced = expectation(description: "the action's sync")

        let outcome = await makeHandler(container, sync: { container in
            await actionSync(container)
            synced.fulfill()
        }).perform(route: .checkIn(habitID: read.id, day: nil), delivered: Date(), responded: Date())
        await fulfillment(of: [synced], timeout: 10)

        guard case .checkedIn = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(recorder.events, effectsAfterCheckIn(of: read) + ["widgets, after the pull", "reminders and badge"])
        XCTAssertEqual(server.paths.filter { $0.hasPrefix("/v1/sync/") }, ["/v1/sync/push", "/v1/sync/pull"])
        let entries = (server.requests.first { $0.path == "/v1/sync/push" }?.json?["entries"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String }
        XCTAssertEqual(entries, try records(of: read).map(\.id.uuidString), "the check-in was pushed")
    }
}
