import XCTest
import SwiftData
import SwiftUI
import UserNotifications
@testable import Stride

/// Today, hosted (RELEASE-1.5.0.md V3): the real TodayView over a store, a `StatsCache`, a
/// NotificationService (over `RecordingCenter`) and the cards' state of this test's own, on a
/// clock of its own (`TodayView(shell:clock:…)`, DEBUG only, D9), read off the accessibility tree.
///
/// - D2: the card is `DailyProgress` for the day shown ("done/due", "Perfect day!" only when
///   perfect, "Rest day" when nothing is due; a habit not started yet is in neither).
/// - D5: one inline card at a time — missed yesterday, the week card, the reminder offer — and
///   what each button does; the permission is asked only on "Turn on" (gate 6).
/// - D7: the rows' at-risk words in their accessibility value, the readable orange, and the
///   at-risk-first order, latched across a check-in and re-sorted on a new day.
/// - D6: `todayFocusHabitID` expands a folded group, scrolls the row into view, moves VoiceOver
///   focus and is consumed.
/// - Data safety 1 and 4: no card tap and no focus writes to the store (row counts and every
///   `updatedAt` unchanged); Pro off, Today reads the same.
///
/// Every day is in June 2026: 06-01 is a Monday. The clock is a local instant in the runner's zone
/// (`TEST_RUNNER_TZ`); records and creation days are day-keys, so the same cases hold in Tokyo and
/// in Los Angeles.
@MainActor
final class TodayRenderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var cache: StatsCache!
    private var window: UIWindow?
    private var automation: Bool?
    private var center: RecordingCenter!
    private var notifications: NotificationService!
    private var notificationDefaults: ScratchDefaults!
    private var cardDefaults: ScratchDefaults!
    private var appStorage: ScratchDefaults!
    /// As WeeklyReviewRenderTests: a hosted view's task can outlive its window, and a context whose
    /// container was released traps.
    private static var retiredContainers: [ModelContainer] = []

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        cache = StatsCache()
        center = RecordingCenter()
        center.status = .authorized
        notificationDefaults = ScratchDefaults("todayRender.notifications")
        notifications = NotificationService(center: center, defaults: notificationDefaults.defaults)
        cardDefaults = ScratchDefaults("todayRender.cards")
        appStorage = ScratchDefaults("todayRender.appStorage")
        TodayView.focusRequests = []
    }

    override func tearDown() async throws {
        closeWindow()
        if let automation { AccessibilityAutomation.restore(automation) }
        automation = nil
        if let container { Self.retiredContainers.append(container) }
        notificationDefaults.remove()
        cardDefaults.remove()
        appStorage.remove()
        cache = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The day-key of 2026-`month`-`day`.
    private static func key(_ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    /// The day-keys `first` … `last`, both in 2026.
    private static func keys(_ first: (Int, Int), _ last: (Int, Int)) -> [Date] {
        var result: [Date] = []
        var day = key(first.0, first.1)
        let end = key(last.0, last.1)
        while day <= end {
            result.append(day)
            day = HabitCalendar.utc.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// A local instant in the runner's zone: what Today's clock reads.
    private static func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private var order = 0.0

    /// A yes/no habit created on the day-key `created`, checked in on each of `checkedIn`, saved;
    /// listed in the order made.
    @discardableResult
    private func habit(_ name: String, created: (Int, Int) = (5, 1), checkedIn: [Date] = [],
                       schedule: HabitSchedule = .daily, timesPerWeek: Int = 7, activeDays: Int = 127,
                       group: HabitGroup? = nil) throws -> Habit {
        let habit = Habit(name: name)
        habit.schedule = schedule
        habit.timesPerWeek = timesPerWeek
        habit.activeDaysMask = activeDays
        habit.createdAt = Self.key(created.0, created.1)
        habit.sortOrder = order
        habit.groupId = group?.id
        order += 1
        context.insert(habit)
        habit.records = checkedIn.map { HabitRecord(date: $0) }
        try context.save()
        return habit
    }

    /// Monday, Wednesday, Friday.
    private let mwf = (1 << 1) | (1 << 3) | (1 << 5)

    /// The day's `DailyProgress` from fresh stats (not the view's cache): what the card must say.
    private func expectedProgress(on day: Date, now: Date) throws -> DailyProgress {
        let habits = try context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { !$0.isArchived }))
        let stats = habits.map {
            HabitStats(habit: $0, live: HabitStats.liveRecords(of: $0), calendar: .current, today: now)
        }
        return DailyProgress(of: stats, on: DailyProgress.today(now: day, calendar: .current))
    }

    /// The app's commit over this test's store and cache: no tombstones, effects or Sentry reach
    /// the host app (as StatsRenderTests).
    private var commitEnvironment: HabitEntryCommit.Environment {
        let cache = self.cache!
        return HabitEntryCommit.Environment(
            save: { try $0.save() }, trackDeletedEntry: { _ in },
            effects: CheckInEffects(reloadWidgets: {}, updateBadge: { _ in }, cancelSnooze: { _ in },
                                    withdrawDelivered: { _ in }, submitRefresh: {}),
            bumpStats: { cache.bump(habitID: $0) }, reportSaveFailure: { _ in },
            now: { Date() }, calendar: { Calendar.current })
    }

    /// The row's check-in on `day`, through the row's own write path (`HabitEntryCommit`).
    private func checkIn(_ habit: Habit, on day: Date) {
        let context = self.context!
        HabitEntryCommit.commit(habitID: habit.id, day: day, in: context, environment: commitEnvironment) { undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: context, undo: undo)
        }
    }

    // MARK: - D2: the card is DailyProgress

    /// Wednesday: one done, two due, a met times-per-week week and a habit not started yet (a
    /// creation stamp from a clock ahead) — "1/3", not "1/5". Its row still shows. Tuesday: the
    /// Mon/Wed/Fri habit rests and the week is met, so "0/2"; the unstarted habit is gone.
    func testTheCardIsDailyProgressForTheDayShown() async throws {
        try habit("Run", checkedIn: [Self.key(6, 3)])
        try habit("Read")
        try habit("Gym", schedule: .specificDays, activeDays: mwf)
        try habit("Swim", checkedIn: [Self.key(6, 1)], schedule: .timesPerWeek, timesPerWeek: 1)
        try habit("Later", created: (6, 4))
        let now = Self.local(6, 3, 9)
        let shell = ShellState(launchArguments: [], now: now)

        let window = try show(now: now, shell: shell)
        let progress = try expectedProgress(on: now, now: now)
        XCTAssertEqual(progress, DailyProgress(done: 1, due: 3))
        try await waitUntil("the card") { self.cardLabel(in: window) == self.cardWords(progress) }
        XCTAssertEqual(card(in: window)?.accessibilityValue, appLocalized("Good start! Keep it up!"))
        XCTAssertNotNil(row("Later", in: window), "a habit not started yet is still on today's list")

        let tuesday = Self.local(6, 2, 12)
        shell.todayDate = tuesday
        let yesterday = try expectedProgress(on: tuesday, now: now)
        XCTAssertEqual(yesterday, DailyProgress(done: 0, due: 2))
        try await waitUntil("Tuesday's card") { self.cardLabel(in: window) == self.cardWords(yesterday) }
        XCTAssertEqual(card(in: window)?.accessibilityValue, appLocalized("Let's get started!"))
        XCTAssertNil(row("Later", in: window), "not started by Tuesday")
    }

    /// Nothing due: "Rest day", no count and no percent, never "Perfect day!". Every due habit done:
    /// "Perfect day!".
    func testRestDayAndPerfectDay() async throws {
        let gym = try habit("Gym", schedule: .specificDays, activeDays: mwf)
        let tuesday = Self.local(6, 2, 9)
        var window = try show(now: tuesday, shell: ShellState(launchArguments: [], now: tuesday))
        XCTAssertTrue(try expectedProgress(on: tuesday, now: tuesday).isRestDay)
        try await waitUntil("Rest day") { self.cardLabel(in: window) == appLocalized("Rest day") }
        XCTAssertNotEqual(card(in: window)?.accessibilityValue, appLocalized("All done! Perfect day!"))
        XCTAssertFalse(labels(in: window).contains { $0.contains("%") }, "no percent on a rest day: \(labels(in: window))")

        gym.records.append(HabitRecord(date: Self.key(6, 3)))
        try context.save()
        let wednesday = Self.local(6, 3, 9)
        window = try show(now: wednesday, shell: ShellState(launchArguments: [], now: wednesday))
        let perfect = try expectedProgress(on: wednesday, now: wednesday)
        XCTAssertTrue(perfect.isPerfect)
        try await waitUntil("a perfect day") { self.cardLabel(in: window) == self.cardWords(perfect) }
        XCTAssertEqual(card(in: window)?.accessibilityValue, appLocalized("All done! Perfect day!"))
    }

    // MARK: - D5: the inline cards

    /// Monday, a habit missed yesterday, the week card due, the offer possible: missed yesterday
    /// shows alone; its "Not now" leaves the week card; the week card's × leaves the offer; the
    /// offer's "Not now" leaves nothing — and the permission was never asked (gate 6).
    func testOneCardAtATimeInPriorityOrder() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (5, 30)))
        center.status = .notDetermined
        let monday = Self.local(6, 1, 9)
        let window = try show(now: monday, shell: ShellState(launchArguments: [], now: monday), isPro: false)

        try await waitUntil("missed yesterday") { self.element("today.missedCard", in: window) != nil }
        XCTAssertTrue(has(appLocalized("\(1) habits not checked yesterday"), in: window), "\(labels(in: window))")
        XCTAssertNil(element("today.weekCard", in: window))
        XCTAssertNil(element("today.reminderCard", in: window))

        try activate("today.missedCard.notNow", in: window)
        try await waitUntil("the week card") { self.element("today.weekCard", in: window) != nil }
        XCTAssertNil(element("today.missedCard", in: window))
        XCTAssertEqual(cardState.missedHiddenDay, HabitStats.dayNumber(ofKey: Self.key(6, 1)), "hidden for today")

        try activate("today.weekCard.dismiss", in: window)
        try await waitUntil("the reminder offer") { self.element("today.reminderCard", in: window) != nil }
        XCTAssertTrue(has(appLocalized("Get a reminder each evening"), in: window))
        XCTAssertNil(element("today.weekCard", in: window))

        try activate("today.reminderCard.notNow", in: window)
        try await waitUntil("no card") { self.element("today.reminderCard", in: window) == nil }
        XCTAssertNil(element("today.missedCard", in: window))
        XCTAssertNil(element("today.weekCard", in: window))
        XCTAssertTrue(cardState.reminderOfferEnded, "never again on this device")
        XCTAssertFalse(center.events.contains(.request), "no prompt without the tap")
        XCTAssertFalse(notifications.isReminderEnabled)
    }

    /// Missed yesterday needs a check-in before today: a first day's user gets none, nor does a day
    /// shown other than today.
    func testNoMissedCardBeforeTheFirstCheckInOrOnAnotherDay() async throws {
        try habit("Run")
        let wednesday = Self.local(6, 3, 9)
        let shell = ShellState(launchArguments: [], now: wednesday)
        let window = try show(now: wednesday, shell: shell)
        try await waitUntil("the card") { self.card(in: window) != nil }
        XCTAssertNil(element("today.missedCard", in: window), "no check-in ever")

        try habit("Read", checkedIn: [Self.key(6, 1)])
        try await waitUntil("missed yesterday") { self.element("today.missedCard", in: window) != nil }
        XCTAssertTrue(has(appLocalized("\(2) habits not checked yesterday"), in: window), "\(labels(in: window))")
        shell.todayDate = Self.local(6, 1, 12)
        try await waitUntil("gone on Monday") { self.element("today.missedCard", in: window) == nil }
    }

    /// "Show yesterday" moves Today to yesterday — the title's anchor stays today — and writes
    /// nothing; the week card's button issues through the shell and writes nothing either.
    func testShowYesterdayAndTheWeekCardWriteNothing() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (5, 30)))
        let monday = Self.local(6, 1, 9)
        let shell = ShellState(launchArguments: [], now: monday)
        let before = try storeSnapshot()
        let window = try show(now: monday, shell: shell, isPro: true)

        try await waitUntil("missed yesterday") { self.element("today.missedCard", in: window) != nil }
        try activate("today.missedCard.action", in: window)
        try await waitUntil("yesterday shown") { Calendar.current.isDate(shell.todayDate, inSameDayAs: Self.local(5, 31, 12)) }
        XCTAssertTrue(Calendar.current.isDate(shell.todayAnchor, inSameDayAs: monday), "the anchor is still today")
        XCTAssertEqual(shell.todayTitle, appLocalized("Yesterday"))
        try await waitUntil("Run, open on Sunday") { self.row("Run", in: window)?.accessibilityLabel == self.rowLabel("Run", done: false) }
        XCTAssertNil(element("today.missedCard", in: window), "only on today")

        try await waitUntil("the week card") { self.element("today.weekCard.open", in: window) != nil }
        try activate("today.weekCard.open", in: window)
        XCTAssertEqual(shell.request, .weeklyReview(week: Self.key(5, 25)))

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(context.hasChanges, "nothing pending")
        XCTAssertEqual(try storeSnapshot(), before, "row counts and every updatedAt unchanged")
    }

    /// "Turn on": the system prompt appears on the tap (and only then), the Daily Reminder is on
    /// at its time, the card is gone for good; the store is untouched. Declined: no reminder, gone
    /// for good too.
    func testTheReminderOfferAsksOnTheTap() async throws {
        try habit("Run", checkedIn: Self.keys((5, 1), (6, 3)))
        let thursday = Self.local(6, 4, 9)
        center.status = .notDetermined
        center.userAllows = true
        let before = try storeSnapshot()
        var window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday))

        try await waitUntil("the offer") { self.element("today.reminderCard", in: window) != nil }
        XCTAssertNil(element("today.missedCard", in: window))
        XCTAssertFalse(center.events.contains(.request), "shown without asking")
        try activate("today.reminderCard.action", in: window)
        try await waitUntil("asked and on") { self.center.events.contains(.request) && self.notifications.isReminderEnabled }
        XCTAssertEqual(notifications.reminderHour, 20, "at its time, 20:00 by default")
        try await waitUntil("the card is gone") { self.element("today.reminderCard", in: window) == nil }
        XCTAssertTrue(cardState.reminderOfferEnded)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try storeSnapshot(), before, "row counts and every updatedAt unchanged")

        // Declined, on a device that never answered.
        cardDefaults.remove()
        notificationDefaults.remove()
        center.status = .notDetermined
        center.userAllows = false
        window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday))
        try await waitUntil("the offer again") { self.element("today.reminderCard", in: window) != nil }
        try activate("today.reminderCard.action", in: window)
        try await waitUntil("declined") { self.center.status == .denied }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(notifications.isReminderEnabled)
        XCTAssertNil(element("today.reminderCard", in: window))
        XCTAssertTrue(cardState.reminderOfferEnded, "declined: never again")
    }

    /// The offer's conditions on screen: not with permission decided, not with a reminder on, not
    /// with check-ins on one day only.
    func testNoOfferWhenItsConditionsFail() async throws {
        let run = try habit("Run", checkedIn: [Self.key(6, 3)])
        let thursday = Self.local(6, 4, 9)
        center.status = .notDetermined
        var window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday))
        try await waitUntil("the card") { self.card(in: window) != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(element("today.reminderCard", in: window), "one day of check-ins")

        run.records.append(HabitRecord(date: Self.key(6, 2)))
        run.reminderEnabled = true
        try context.save()
        window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday))
        try await waitUntil("the card") { self.card(in: window) != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(element("today.reminderCard", in: window), "a habit's reminder is on")

        run.reminderEnabled = false
        try context.save()
        center.status = .denied
        window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday))
        try await waitUntil("the card") { self.card(in: window) != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(element("today.reminderCard", in: window), "denied")
        XCTAssertFalse(center.events.contains(.request))
    }

    // MARK: - D7: the words and the order

    /// Saturday 19:00: each row's words in its accessibility value — "2 more · 2 days left" (at
    /// risk), "2/3 this week · 1 more", "Due today", "2/2 this week", and a first week's share met
    /// reads "2/3 this week", never "0 more". At-risk rows first. No word names a weekday.
    func testTheWordsAndTheOrderOnSaturdayEvening() async throws {
        try habit("Run", checkedIn: [Self.key(6, 6)])
        try habit("Swim", checkedIn: [Self.key(6, 1)], schedule: .timesPerWeek, timesPerWeek: 3)
        try habit("Yoga", checkedIn: [Self.key(6, 1), Self.key(6, 2)], schedule: .timesPerWeek, timesPerWeek: 3)
        try habit("Read")
        try habit("Bike", checkedIn: [Self.key(6, 1), Self.key(6, 2)], schedule: .timesPerWeek, timesPerWeek: 2)
        try habit("Fresh", created: (6, 5), checkedIn: [Self.key(6, 5), Self.key(6, 6)], schedule: .timesPerWeek,
                  timesPerWeek: 3)
        let saturday = Self.local(6, 6, 19)
        let window = try show(now: saturday, shell: ShellState(launchArguments: [], now: saturday))

        try await waitUntil("Swim's words") { self.value("Swim", in: window)?.contains(self.words(.atRiskDaysLeft(owed: 2, daysLeft: 2))) == true }
        XCTAssertEqual(words(.atRiskDaysLeft(owed: 2, daysLeft: 2)), appLocalized("\(2) more · \(2) days left"))
        XCTAssertTrue(try XCTUnwrap(value("Yoga", in: window)).contains(appLocalized("\(2)/\(3) this week · \(1) more")))
        XCTAssertTrue(try XCTUnwrap(value("Read", in: window)).contains(appLocalized("Due today")))
        XCTAssertTrue(try XCTUnwrap(value("Bike", in: window)).contains(appLocalized("\(2)/\(2) this week")))
        let fresh = try XCTUnwrap(value("Fresh", in: window))
        XCTAssertTrue(fresh.contains(appLocalized("\(2)/\(3) this week")), fresh)
        XCTAssertFalse(fresh.contains(appLocalized("\(2)/\(3) this week · \(0) more")), fresh)
        XCTAssertFalse(try XCTUnwrap(value("Run", in: window)).contains(appLocalized("Due today")), "done")
        XCTAssertEqual(rowOrder(["Run", "Swim", "Yoga", "Read", "Bike", "Fresh"], in: window),
                       ["Swim", "Read", "Run", "Yoga", "Bike", "Fresh"], "at risk first, each part in its order")
        expectNoWeekdayNames(in: window)
    }

    /// Sunday: "2 more · today", never "0 days left". Another day shown: no D7 words, the plain
    /// count, the natural order.
    func testTheLastDayAndAnotherDayShown() async throws {
        try habit("Run")
        try habit("Swim", checkedIn: [Self.key(6, 1)], schedule: .timesPerWeek, timesPerWeek: 3)
        let sunday = Self.local(6, 7, 19)
        let shell = ShellState(launchArguments: [], now: sunday)
        let window = try show(now: sunday, shell: shell)
        try await waitUntil("Swim's words") { self.value("Swim", in: window)?.contains(appLocalized("\(2) more · today")) == true }
        let zeroDays = appLocalized("\(2) more · \(0) days left")
        XCTAssertFalse(allText(in: window).contains { $0.contains(zeroDays) }, "never \"0 days left\"")
        XCTAssertEqual(rowOrder(["Run", "Swim"], in: window), ["Run", "Swim"], "both at risk: their own order")

        shell.todayDate = Self.local(6, 5, 12)
        try await waitUntil("Friday's row") { self.value("Swim", in: window)?.contains(appLocalized("\(1)/\(3) this week")) == true }
        let swim = try XCTUnwrap(value("Swim", in: window))
        XCTAssertFalse(swim.contains(appLocalized("\(2) more · today")), swim)
        XCTAssertFalse(try XCTUnwrap(value("Run", in: window)).contains(appLocalized("Due today")))
    }

    /// The at-risk words are drawn in #FF9500 made readable, as the streak words are.
    func testTheAtRiskOrangeIsTheReadableOne() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertEqual(HabitRowView.atRiskColor(in: scheme), Color.readableText(hex: "#FF9500", in: scheme))
        }
        // What that buys: #FF9500 itself is under 2:1 on the light card; the readable shade passes.
        let orange = try! XCTUnwrap(ColorContrast.RGB(hex: "#FF9500"))
        XCTAssertLessThan(ColorContrast.ratio(orange, ColorContrast.lightCard), 2)
        for card in [ColorContrast.lightCard, ColorContrast.darkCard] {
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(ColorContrast.readable(orange, on: card), card),
                                        ColorContrast.textMinimum)
        }
        XCTAssertTrue(TodayAtRisk.Words.dueToday.isAtRisk)
        XCTAssertFalse(TodayAtRisk.Words.weekOwing(done: 1, goal: 3, owed: 2).isAtRisk)
    }

    /// Wednesday 19:00: Bravo and Charlie at risk, first. A check-in on Bravo changes its words but
    /// not its place; a new habit appears and a deleted one goes, in the same pass. The next day
    /// is a new pass: re-sorted.
    func testTheOrderIsLatchedAcrossACheckInAndReSortedOnANewDay() async throws {
        try habit("Alpha", checkedIn: [Self.key(6, 3)])
        let bravo = try habit("Bravo")
        let charlie = try habit("Charlie")
        var clock = Self.local(6, 3, 19)
        let shell = ShellState(launchArguments: [], now: clock)
        let window = try show(clock: { clock }, shell: shell)

        try await waitUntil("at risk first") { self.rowOrder(["Alpha", "Bravo", "Charlie"], in: window) == ["Bravo", "Charlie", "Alpha"] }
        checkIn(bravo, on: clock)
        try await waitUntil("Bravo done") { self.row("Bravo", in: window)?.accessibilityLabel == self.rowLabel("Bravo", done: true) }
        XCTAssertFalse(try XCTUnwrap(value("Bravo", in: window)).contains(appLocalized("Due today")), "its words are live")
        XCTAssertEqual(rowOrder(["Alpha", "Bravo", "Charlie"], in: window), ["Bravo", "Charlie", "Alpha"],
                       "a check-in never moves a row in the same pass")

        try habit("Delta")
        try await waitUntil("Delta appears") { self.row("Delta", in: window) != nil }
        context.delete(charlie)
        try context.save()
        try await waitUntil("Charlie goes") { self.row("Charlie", in: window) == nil }
        XCTAssertEqual(rowOrder(["Alpha", "Bravo", "Delta"], in: window), ["Bravo", "Alpha", "Delta"])

        // Thursday 19:00, as ContentView re-anchors after midnight: all three at risk, their order.
        clock = Self.local(6, 4, 19)
        shell.reanchor(now: clock)
        try await waitUntil("re-sorted") { self.rowOrder(["Alpha", "Bravo", "Delta"], in: window) == ["Alpha", "Bravo", "Delta"] }
    }

    // MARK: - D6: the focus target

    /// The review's at-risk tap lands on a habit at the bottom of a folded group: the group opens,
    /// the row scrolls into view, VoiceOver focus moves to it, the id is consumed — and nothing is
    /// written. A habit that is gone is consumed without a move.
    func testTheFocusTargetIsConsumed() async throws {
        let group = HabitGroup(name: "Morning")
        context.insert(group)
        try context.save()
        var last: Habit!
        for index in 0..<30 {
            last = try habit(String(format: "H%02d", index), group: group)
        }
        appStorage.defaults.set(TodayView.storage(ofCollapsedGroups: [group.id]), forKey: "stride_today_collapsed_groups")
        let now = Self.local(6, 3, 9)
        let shell = ShellState(launchArguments: [], now: now)
        let before = try storeSnapshot()
        let window = try show(now: now, shell: shell)
        try await waitUntil("the folded group") { self.has(appLocalized("\("Morning"), \(30) habits"), in: window) }
        XCTAssertNil(row("H29", in: window), "folded")

        shell.focusOnToday(habitID: last.id, now: now)
        try await waitUntil("consumed") { shell.todayFocusHabitID == nil }
        XCTAssertEqual(TodayView.focusRequests, [last.id], "VoiceOver focus moved to it")
        XCTAssertFalse(TodayView.collapsedGroups(from: appStorage.defaults.string(forKey: "stride_today_collapsed_groups") ?? "")
                        .contains(group.id), "the group opened")
        try await waitUntil("H29 in view") {
            guard let row = self.row("H29", in: window) else { return false }
            return window.bounds.intersects(row.accessibilityFrame)
        }

        shell.todayFocusHabitID = UUID()
        try await waitUntil("a gone habit consumed") { shell.todayFocusHabitID == nil }
        XCTAssertEqual(TodayView.focusRequests, [last.id], "no move for it")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try storeSnapshot(), before, "row counts and every updatedAt unchanged")
    }

    // MARK: - Data safety 4: Pro off

    /// Thursday 19:00 (no week card), at-risk rows and words: every label and value Pro on equals
    /// Pro off.
    func testProOffIsIdentical() async throws {
        try habit("Run", checkedIn: [Self.key(6, 4)])
        try habit("Read")
        try habit("Swim", checkedIn: [Self.key(6, 1)], schedule: .timesPerWeek, timesPerWeek: 3)
        let thursday = Self.local(6, 4, 19)

        var window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday), isPro: true)
        try await waitUntil("Read at risk") { self.value("Read", in: window)?.contains(appLocalized("Due today")) == true }
        try await Task.sleep(for: .milliseconds(200))
        let pro = allText(in: window)
        window = try show(now: thursday, shell: ShellState(launchArguments: [], now: thursday), isPro: false)
        try await waitUntil("Read at risk") { self.value("Read", in: window)?.contains(appLocalized("Due today")) == true }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(allText(in: window), pro)
    }

    // MARK: - Reading Today

    private var cardState: InlinePrompts.DismissalState {
        InlinePromptStore(defaults: cardDefaults.defaults).state
    }

    private func cardWords(_ progress: DailyProgress) -> String {
        appLocalized("\(progress.done) of \(progress.due) habits completed, \(Int(progress.fraction * 100)) percent")
    }

    private func card(in window: UIWindow) -> NSObject? {
        element("today.progressCard", in: window)
    }

    private func cardLabel(in window: UIWindow) -> String? {
        card(in: window)?.accessibilityLabel
    }

    private func rowLabel(_ name: String, done: Bool) -> String {
        done ? appLocalized("\(name), completed") : appLocalized("\(name), not completed")
    }

    /// The row of the habit named `name`, done or not.
    private func row(_ name: String, in window: UIWindow) -> NSObject? {
        let labels = [rowLabel(name, done: true), rowLabel(name, done: false)]
        return elements(in: window) { labels.contains($0.accessibilityLabel ?? "") }.first
    }

    private func value(_ name: String, in window: UIWindow) -> String? {
        row(name, in: window)?.accessibilityValue
    }

    private func words(_ words: TodayAtRisk.Words) -> String {
        HabitRowView.spoken(words)
    }

    /// The rows of `names` that are on screen, top to bottom.
    private func rowOrder(_ names: [String], in window: UIWindow) -> [String] {
        names.compactMap { name in row(name, in: window).map { (name, $0.accessibilityFrame.minY) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Every label and value, in tree order.
    private func allText(in window: UIWindow) -> [String] {
        elements(in: window) { _ in true }.map { "\($0.accessibilityLabel ?? "")|\($0.accessibilityValue ?? "")" }
    }

    private func expectNoWeekdayNames(in window: UIWindow, file: StaticString = #filePath, line: UInt = #line) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = appLocale
        let names = calendar.weekdaySymbols + calendar.standaloneWeekdaySymbols
        let values = elements(in: window) { _ in true }.compactMap(\.accessibilityValue)
        for value in values {
            XCTAssertFalse(names.contains { value.contains($0) }, "a weekday in \(value)", file: file, line: line)
        }
    }

    /// Every row's updatedAt by its identity, and the row counts: what Data safety 1 compares.
    private struct StoreSnapshot: Equatable {
        let counts: [Int]
        let stamps: [PersistentIdentifier: Date?]
    }

    private func storeSnapshot() throws -> StoreSnapshot {
        let habits = try context.fetch(FetchDescriptor<Habit>())
        let records = try context.fetch(FetchDescriptor<HabitRecord>())
        let groups = try context.fetch(FetchDescriptor<HabitGroup>())
        var stamps: [PersistentIdentifier: Date?] = [:]
        for h in habits { stamps[h.persistentModelID] = h.updatedAt }
        for r in records { stamps[r.persistentModelID] = r.updatedAt }
        for g in groups { stamps[g.persistentModelID] = g.updatedAt }
        return StoreSnapshot(counts: [habits.count, records.count, groups.count], stamps: stamps)
    }

    // MARK: - Hosting

    private func show(now: Date, shell: ShellState, isPro: Bool = false) throws -> UIWindow {
        try show(clock: { now }, shell: shell, isPro: isPro)
    }

    /// Today at `clock()`, over this test's store, cache, notification service and card state, in
    /// the picked language's locale, in a window of its own on the host app's scene (replacing any
    /// earlier one), with the accessibility tree built.
    private func show(clock: @escaping () -> Date, shell: ShellState, isPro: Bool = false) throws -> UIWindow {
        closeWindow()
        if automation == nil {
            automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AnyView(
            NavigationStack {
                TodayView(shell: shell, clock: clock, notifications: notifications,
                          cardStore: InlinePromptStore(defaults: cardDefaults.defaults), isPro: isPro)
            }
            .modelContainer(container)
            .environment(\.statsCache, cache)
            .environment(\.habitEntryCommit, commitEnvironment)
            .defaultAppStorage(appStorage.defaults)
            .environment(\.locale, LanguageManager.shared.locale ?? .current)))
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func closeWindow() {
        guard let window else { return }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene?.windows.first { $0 !== window }?.makeKey()
        self.window = nil
    }

    private func activate(_ id: String, in window: UIWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let button = try XCTUnwrap(element(id, in: window), "\(id): \(labels(in: window))", file: file, line: line)
        XCTAssertTrue(button.accessibilityActivate(), id, file: file, line: line)
    }

    private func has(_ label: String, in window: UIWindow) -> Bool {
        !elements(in: window) { $0.accessibilityLabel == label }.isEmpty
    }

    private func labels(in window: UIWindow) -> [String] {
        elements(in: window) { _ in true }.compactMap(\.accessibilityLabel)
    }

    /// The element whose accessibility identifier is `id`.
    private func element(_ id: String, in window: UIWindow) -> NSObject? {
        elements(in: window) { self.identifier(of: $0) == id }.first
    }

    /// An element's accessibility identifier, which SwiftUI's elements answer without adopting
    /// UIAccessibilityIdentification in their type (as PaywallRenderTests).
    private func identifier(of element: NSObject) -> String? {
        if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The distinct accessibility elements under `root` that `matches`, in tree order.
    private func elements(in root: NSObject, where matches: (NSObject) -> Bool) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        collect(in: root, where: matches, seen: &seen, found: &found, depth: 0)
        return found
    }

    private func collect(in root: NSObject, where matches: (NSObject) -> Bool,
                         seen: inout Set<ObjectIdentifier>, found: inout [NSObject], depth: Int) {
        guard depth < 80 else { return }
        if root.isAccessibilityElement, matches(root), seen.insert(ObjectIdentifier(root)).inserted {
            found.append(root)
        }
        if root.accessibilityElementsHidden { return }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView {
            guard !view.isHidden else { return }
            children += view.subviews
        }
        for child in children {
            collect(in: child, where: matches, seen: &seen, found: &found, depth: depth + 1)
        }
    }

    /// Lets SwiftUI and UIKit run until `condition` holds, or fails after five seconds.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting: \(what)")
                throw XCTSkip("timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
