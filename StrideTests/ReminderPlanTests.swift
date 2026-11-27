import XCTest
import SwiftData
import Foundation

/// The reminder planner (`ReminderPlan`, Shared/ReminderPlan.swift; RELEASE-1.4.0.md D4): which
/// requests a habit's reminder becomes, the identifiers scheduling, removal and the launch prune
/// all derive from it, and the 58-request budget.
final class ReminderPlanTests: XCTestCase {

    private func habit(_ schedule: HabitSchedule, mask: Int = 127, hour: Int = 20, minute: Int = 0,
                       id: UUID = UUID()) -> ReminderPlan.Settings {
        ReminderPlan.Settings(habitID: id, schedule: schedule, activeDaysMask: mask, hour: hour, minute: minute)
    }

    private func legacy(_ settings: ReminderPlan.Settings) -> String {
        ReminderPlan.legacyIdentifier(for: settings.habitID)
    }

    // MARK: - Shapes

    /// Acceptance (3): a Mon/Wed/Fri habit (bits 1, 3, 5 = 42) gets exactly three weekly triggers,
    /// weekday 2, 4 and 6, under `.2`/`.4`/`.6` — and no daily one, which would fire on rest days.
    func testMondayWednesdayFridayIsExactlyThreeWeekdayTriggers() {
        let mwf = habit(.specificDays, mask: 0b010_1010, hour: 7, minute: 30)
        let requests = ReminderPlan.requests(for: mwf)

        XCTAssertEqual(requests.map(\.identifier), [2, 4, 6].map { "\(legacy(mwf)).\($0)" })
        XCTAssertEqual(requests.map(\.weekday), [2, 4, 6])
        for request in requests {
            XCTAssertEqual(request.habitID, mwf.habitID)
            XCTAssertEqual(request.dateComponents, DateComponents(hour: 7, minute: 30, weekday: request.weekday))
        }
        XCTAssertFalse(requests.map(\.identifier).contains(legacy(mwf)))
    }

    /// Every day (127) is one daily trigger under the 1.3.x id — so the request a 1.3.x build left
    /// pending is replaced, not doubled — with exactly hour and minute (a weekday or a day in the
    /// components would make it weekly or monthly).
    func testEveryDayIsTheLegacyDailyTrigger() {
        let everyDay = habit(.specificDays, mask: 127, hour: 7, minute: 30)
        XCTAssertEqual(ReminderPlan.requests(for: everyDay),
                       [ReminderPlan.Request(identifier: legacy(everyDay), habitID: everyDay.habitID,
                                             dateComponents: DateComponents(hour: 7, minute: 30))])
        XCTAssertEqual(legacy(everyDay), "stride.habit.reminder.\(everyDay.habitID.uuidString)")
    }

    /// A mask of 0 — the server allows it and a pull assigns it unchecked — means every day, as
    /// AddHabitView's save reads an empty selection: a reminder switched on must not silently never
    /// fire. So does a mask with only bits above Saturday (128), and the stray bits beside real days
    /// are ignored.
    func testMalformedMasksFallBackToDaily() {
        for mask in [0, 128, 256, 0b1000_0000_0000, -128] {
            let odd = habit(.specificDays, mask: mask)
            XCTAssertNil(ReminderPlan.weekdays(for: odd), "mask \(mask)")
            XCTAssertEqual(ReminderPlan.requests(for: odd).map(\.identifier), [legacy(odd)], "mask \(mask)")
        }
        XCTAssertEqual(ReminderPlan.weekdays(for: habit(.specificDays, mask: 128 | 0b010_1010)), [2, 4, 6])
        XCTAssertNil(ReminderPlan.weekdays(for: habit(.specificDays, mask: 255)), "every day plus a stray bit")
        XCTAssertNil(ReminderPlan.weekdays(for: habit(.specificDays, mask: -1)))
    }

    /// Daily and times-per-week habits fire every day whatever mask they still carry from an
    /// earlier specific-days setting.
    func testDailyAndTimesPerWeekIgnoreTheMask() {
        for schedule in [HabitSchedule.daily, .timesPerWeek] {
            let h = habit(schedule, mask: 0b010_1010)
            XCTAssertEqual(ReminderPlan.requests(for: h).map(\.identifier), [legacy(h)], "\(schedule)")
            XCTAssertNil(ReminderPlan.requests(for: h)[0].weekday)
        }
    }

    /// One bit per weekday, Sunday = bit 0 = weekday 1 … Saturday = bit 6 = weekday 7, the numbering
    /// `Habit.isScheduled(on:)` reads the mask with.
    func testEachBitIsItsWeekday() {
        for bit in 0..<7 {
            let one = habit(.specificDays, mask: 1 << bit)
            XCTAssertEqual(ReminderPlan.requests(for: one).map(\.weekday), [bit + 1])
            XCTAssertEqual(ReminderPlan.requests(for: one).map(\.identifier), ["\(legacy(one)).\(bit + 1)"])
        }
    }

    /// A Monday-first region (firstWeekday 2) does not move anything: the trigger's weekday is
    /// DateComponents' absolute numbering, so weekday 2 fires on Mondays wherever the week starts.
    func testAMondayFirstCalendarDoesNotShiftTheWeekdays() throws {
        let mwf = habit(.specificDays, mask: 0b010_1010, hour: 7, minute: 30)
        var mondayFirst = Calendar(identifier: .gregorian)
        mondayFirst.timeZone = TimeZone(identifier: "Europe/London")!
        mondayFirst.locale = Locale(identifier: "en_GB")
        mondayFirst.firstWeekday = 2
        let names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        names.timeZone = mondayFirst.timeZone
        names.dateFormat = "EEEE"

        let sunday = try XCTUnwrap(mondayFirst.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 12)))
        XCTAssertEqual(names.string(from: sunday), "Sunday")
        let fires = try ReminderPlan.requests(for: mwf).map { request in
            try XCTUnwrap(mondayFirst.nextDate(after: sunday, matching: request.dateComponents, matchingPolicy: .nextTime))
        }
        XCTAssertEqual(fires.map(names.string(from:)), ["Monday", "Wednesday", "Friday"])
        XCTAssertEqual(fires.map { mondayFirst.component(.hour, from: $0) }, [7, 7, 7])
    }

    // MARK: - Identifiers: one source

    /// Everything a habit can ever have pending or delivered: the legacy id, seven weekday ids, the
    /// overlay's seven one-shots (1.5.0, Gemini A3) and the snooze. Whatever shape it is planned
    /// in, every planned id is among them, so "remove all variants, then add" never leaves the
    /// other shape's requests firing.
    func testAllIdentifiersCoverEveryShape() {
        let id = UUID()
        let all = ReminderPlan.allIdentifiers(for: id)
        XCTAssertEqual(all.count, 16)
        XCTAssertEqual(Set(all).count, 16)
        XCTAssertEqual(all.first, "stride.habit.reminder.\(id.uuidString)")
        XCTAssertEqual(all.last, "stride.habit.snooze.\(id.uuidString)")
        XCTAssertEqual(Array(all[8...14]), (1...7).map { "stride.habit.reminder.\(id.uuidString).n\($0)" })
        XCTAssertEqual(ReminderPlan.reminderIdentifiers(for: id), Array(all.dropLast()), "every id but the snooze")
        XCTAssertEqual(ReminderPlan.allEveningIdentifiers,
                       ["stride.daily.evening"] + (1...7).map { "stride.daily.evening.\($0)" }
                       + (1...7).map { "stride.daily.evening.n\($0)" })
        XCTAssertFalse(ReminderPlan.allEveningIdentifiers.contains(where: ReminderPlan.isHabitRequest),
                       "the prune never touches the Daily Reminder")
        XCTAssertEqual(ReminderPlan.snoozeIdentifier(for: id), "stride.habit.snooze.\(id.uuidString)")
        for mask in [0, 1, 0b010_1010, 126, 127] {
            for schedule in HabitSchedule.allCases {
                let planned = ReminderPlan.requests(for: habit(schedule, mask: mask, id: id)).map(\.identifier)
                XCTAssertTrue(Set(planned).isSubset(of: all), "\(schedule) \(mask)")
            }
        }
        XCTAssertTrue(all.allSatisfy(ReminderPlan.isHabitRequest))
        XCTAssertFalse(ReminderPlan.isHabitRequest("stride.daily.evening"))
        XCTAssertFalse(ReminderPlan.isHabitRequest("stride.daily.morning"))
    }

    // MARK: - The budget

    /// 58 planned requests fit (64 − 2 globals − 4 snoozes); 59 do not, and then EVERY
    /// specific-days habit gets its one daily trigger — none dropped, none chosen by fetch order.
    func testTheBudgetBoundaryIsFiftyEight() {
        XCTAssertEqual(ReminderPlan.requestBudget, 58)
        let sixDays = (0..<9).map { _ in habit(.specificDays, mask: 0b111_1110) }   // Mon–Sat: 6 each
        let daily = (0..<4).map { _ in habit(.daily) }

        let fits = ReminderPlan.plan(sixDays + daily)
        XCTAssertEqual(fits.requests.count, 58)
        XCTAssertFalse(fits.fellBackToDaily)
        XCTAssertEqual(fits.requests.filter { $0.weekday != nil }.count, 54)

        let all = sixDays + daily + [habit(.timesPerWeek)]
        let over = ReminderPlan.plan(all)
        XCTAssertTrue(over.fellBackToDaily)
        XCTAssertEqual(over.requests.count, 14, "one daily trigger per habit")
        XCTAssertTrue(over.requests.allSatisfy { $0.weekday == nil })
        XCTAssertEqual(over.requests.map(\.identifier), all.map(legacy), "nothing dropped, in order")
    }

    /// A smaller budget, to pin the comparison itself: exactly at it plans weekdays, one over falls
    /// back.
    func testTheBudgetIsAnUpperBoundInclusive() {
        let mwf = habit(.specificDays, mask: 0b010_1010)
        let daily = habit(.daily)
        XCTAssertFalse(ReminderPlan.plan([mwf, daily], budget: 4).fellBackToDaily)
        XCTAssertEqual(ReminderPlan.plan([mwf, daily], budget: 4).requests.count, 4)
        let tight = ReminderPlan.plan([mwf, daily], budget: 3)
        XCTAssertTrue(tight.fellBackToDaily)
        XCTAssertEqual(tight.requests.map(\.identifier), [legacy(mwf), legacy(daily)])
        XCTAssertFalse(ReminderPlan.plan([], budget: 0).fellBackToDaily)
    }

    // MARK: - The prune

    /// The launch prune removes every per-habit request of a habit that is not planned, and
    /// nothing else (1.5.0, Gemini A1): `keep` names EVERY id a reminder-on habit can have, so
    /// - a planned habit's ids of any shape stay, its stale ones included (the 1.3.x daily id of a
    ///   Mon/Wed/Fri habit, a stray `.1`): its own replace step removes those, diffing against
    ///   what is pending (NotificationService's `apply`);
    /// - a planned habit's snooze stays; the snooze of a habit whose reminder is now off goes;
    /// - an orphan of a habit deleted on another device goes, one-shots included;
    /// - the global reminders (the evening's overlay too) and anything not ours are never touched.
    /// 1.3.x kept only `prefix + uuid` and would have removed every weekday request on each launch.
    func testThePruneRemovesOnlyOrphans() {
        let mwf = habit(.specificDays, mask: 0b010_1010)
        let daily = habit(.daily)
        let off = UUID()
        let deleted = UUID()
        let result = ReminderPlan.plan([mwf, daily])

        XCTAssertEqual(result.keep, Set(ReminderPlan.allIdentifiers(for: mwf.habitID)
                                        + ReminderPlan.allIdentifiers(for: daily.habitID)))
        XCTAssertTrue(Set(result.requests.map(\.identifier)).isSubset(of: result.keep))

        let pending = [
            "stride.daily.evening", "stride.daily.evening.3", "stride.daily.evening.n4",
            "stride.daily.morning", "com.example.other",
            legacy(mwf), "\(legacy(mwf)).2", "\(legacy(mwf)).4", "\(legacy(mwf)).6", "\(legacy(mwf)).1",
            "\(legacy(mwf)).n4",
            legacy(daily), ReminderPlan.snoozeIdentifier(for: daily.habitID),
            ReminderPlan.snoozeIdentifier(for: off), ReminderPlan.legacyIdentifier(for: deleted),
            "\(ReminderPlan.legacyIdentifier(for: deleted)).3", "\(ReminderPlan.legacyIdentifier(for: deleted)).n5",
        ]
        XCTAssertEqual(ReminderPlan.prune(pending, keep: result.keep), [
            ReminderPlan.snoozeIdentifier(for: off), ReminderPlan.legacyIdentifier(for: deleted),
            "\(ReminderPlan.legacyIdentifier(for: deleted)).3", "\(ReminderPlan.legacyIdentifier(for: deleted)).n5",
        ])
    }

    /// The A1 race (RELEASE-1.5.0.md D4, Gemini A1): the launch prune's keep set is computed
    /// before the center answers. The widget checks a habit off in that window and writes its
    /// overlay — ids the plan did not contain when `keep` was made. The prune must leave them:
    /// removing them as orphans left the habit with NO request at all.
    func testTheKeepSetSurvivesAnOverlayWrittenAfterItWasComputed() {
        let read = habit(.daily, hour: 20)
        let mwf = habit(.specificDays, mask: 0b010_1010, hour: 7)
        let keep = ReminderPlan.plan([read, mwf]).keep               // computed now: base shapes

        // Meanwhile, the widget's overlay: Wednesday quiet for both.
        let widgetWrote = (1...7).filter { $0 != 4 }.map { "\(legacy(read)).\($0)" }
            + ["\(legacy(read)).n4", "\(legacy(mwf)).2", "\(legacy(mwf)).n4", "\(legacy(mwf)).6"]
        XCTAssertEqual(ReminderPlan.prune(widgetWrote, keep: keep), [], "nothing of a live habit is an orphan")
    }

    /// After the budget's fallback the plan has the daily ids; the old weekday ids are still
    /// kept from the prune (they are the habit's) and its replace step swaps them.
    func testThePruneKeepsEveryShapeAfterTheFallback() {
        let mwf = habit(.specificDays, mask: 0b010_1010)
        let result = ReminderPlan.plan([mwf], budget: 2)
        XCTAssertTrue(result.fellBackToDaily)
        XCTAssertEqual(result.requests.map(\.identifier), [legacy(mwf)])
        let weekdayIDs = [2, 4, 6].map { "\(legacy(mwf)).\($0)" }
        XCTAssertEqual(ReminderPlan.prune(weekdayIDs + [legacy(mwf)], keep: result.keep), [])
    }

    // MARK: - Reading a habit

    /// Only a habit with its reminder on and not archived is planned — the rule the scheduler
    /// fetches by, and the one that decides whether its snooze survives the prune.
    @MainActor
    func testSettingsComeFromAReminderOnUnarchivedHabit() throws {
        let container = try ModelContainer(for: Schema([Habit.self, HabitRecord.self, HabitGroup.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let h = Habit(name: "Run")
        container.mainContext.insert(h)
        h.schedule = .specificDays
        h.activeDaysMask = 0b010_1010
        h.reminderHour = 6
        h.reminderMinute = 45

        XCTAssertNil(ReminderPlan.Settings(h), "reminder off")
        h.reminderEnabled = true
        XCTAssertEqual(ReminderPlan.Settings(h), habit(.specificDays, mask: 0b010_1010, hour: 6, minute: 45, id: h.id))
        h.isArchived = true
        XCTAssertNil(ReminderPlan.Settings(h), "archived")
    }
}

/// The 1.5.0 overlay (RELEASE-1.5.0.md D4; Gemini A0, A4, A5): quiet when done, per quiet day, the
/// one-shots' dates and zones, the budget with the Daily Reminder inside it, and the property the
/// whole design rests on: it never under-fires.
///
/// Day-keys are fixed: 2026-06-01, 2026-03-02 and 2026-10-26 are Mondays. Every instant is a wall
/// clock in an explicit zone, so the suite means the same in Tokyo and under
/// `TEST_RUNNER_TZ=America/Los_Angeles`.
final class ReminderPlanOverlayTests: XCTestCase {

    private static func gregorian(_ id: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: id)!
        return c
    }

    private let tokyo = gregorian("Asia/Tokyo")
    private let losAngeles = gregorian("America/Los_Angeles")
    private let newYork = gregorian("America/New_York")
    private let apia = gregorian("Pacific/Apia")

    private func key(_ y: Int, _ m: Int, _ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func at(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Today on a local date at a local time.
    private func today(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> ReminderPlan.Today {
        let now = at(cal, y, m, d, h, min)
        let today = ReminderPlan.Today(now: now, calendar: cal)
        XCTAssertEqual(today.dayKey, key(y, m, d), "precondition: today's key is the local date")
        return today
    }

    private func habit(_ schedule: HabitSchedule = .daily, mask: Int = 127, hour: Int = 20, minute: Int = 0,
                       quiet: [Date] = []) -> ReminderPlan.Settings {
        ReminderPlan.Settings(habitID: UUID(), schedule: schedule, activeDaysMask: mask, hour: hour, minute: minute,
                              quietDays: Set(quiet))
    }

    private func id(_ s: ReminderPlan.Settings) -> String { ReminderPlan.legacyIdentifier(for: s.habitID) }

    private func weekly(_ s: ReminderPlan.Settings, _ w: Int) -> ReminderPlan.Request {
        ReminderPlan.Request(identifier: "\(id(s)).\(w)", habitID: s.habitID,
                             dateComponents: DateComponents(hour: s.hour, minute: s.minute, weekday: w))
    }

    private func oneShot(_ s: ReminderPlan.Settings, _ w: Int, _ y: Int, _ m: Int, _ d: Int) -> ReminderPlan.Request {
        ReminderPlan.Request(identifier: "\(id(s)).n\(w)", habitID: s.habitID,
                             dateComponents: DateComponents(year: y, month: m, day: d, hour: s.hour, minute: s.minute),
                             repeats: false)
    }

    private let mwf = 0b010_1010

    // MARK: - The overlay, per state

    /// Done on Wednesday before its 20:00 reminder: the bare daily request becomes six weekly ones
    /// and a one-shot next Wednesday — today stays quiet, every other day still fires.
    func testADailyHabitDoneBeforeItsTimeIsOverlaid() {
        for cal in [tokyo, losAngeles] {
            let read = habit(quiet: [key(2026, 6, 3)])
            let plan = ReminderPlan.plan([read], today: today(cal, 2026, 6, 3, 10))
            XCTAssertEqual(plan.requests, [1, 2, 3].map { weekly(read, $0) } + [oneShot(read, 4, 2026, 6, 10)]
                           + [5, 6, 7].map { weekly(read, $0) }, cal.timeZone.identifier)
            XCTAssertEqual(plan.overlaid, [read.habitID])
            XCTAssertFalse(plan.requests.contains { $0.identifier == id(read) }, "no bare id on a quiet day")
        }
    }

    /// Done after its time (or at it): today's reminder already fired, nothing is left to silence,
    /// so the plan is the base — exactly the 1.4.2 ids.
    func testADailyHabitDoneAfterItsTimeKeepsItsBase() {
        let read = habit(quiet: [key(2026, 6, 3)])
        for (h, min) in [(20, 0), (20, 30), (23, 59)] {
            let plan = ReminderPlan.plan([read], today: today(tokyo, 2026, 6, 3, h, min))
            XCTAssertEqual(plan.requests, ReminderPlan.requests(for: read), "\(h):\(min)")
            XCTAssertTrue(plan.overlaid.isEmpty)
        }
        XCTAssertTrue(ReminderPlan.isAhead(hour: 20, minute: 0, now: at(tokyo, 2026, 6, 3, 19, 59), calendar: tokyo))
        XCTAssertFalse(ReminderPlan.isAhead(hour: 20, minute: 0, now: at(tokyo, 2026, 6, 3, 20, 0), calendar: tokyo))
    }

    /// A specific-days habit: only the quiet weekday's request changes, into its one-shot. A
    /// check-in on a rest day (state `.done`, but no request that weekday) changes nothing.
    func testASpecificDaysHabitsQuietWeekdayBecomesItsOneShot() {
        let gym = habit(.specificDays, mask: mwf, hour: 7, quiet: [key(2026, 6, 3)])
        let plan = ReminderPlan.plan([gym], today: today(losAngeles, 2026, 6, 3, 6, 30))
        XCTAssertEqual(plan.requests, [weekly(gym, 2), oneShot(gym, 4, 2026, 6, 10), weekly(gym, 6)])

        let restDay = habit(.specificDays, mask: mwf, hour: 7, quiet: [key(2026, 6, 2)])
        let tuesday = ReminderPlan.plan([restDay], today: today(losAngeles, 2026, 6, 2, 6, 30))
        XCTAssertEqual(tuesday.requests, ReminderPlan.requests(for: restDay))
        XCTAssertTrue(tuesday.overlaid.isEmpty)
    }

    /// A times-per-week goal met on Wednesday: Wednesday (while its time is ahead) and every
    /// later day of the Monday week are quiet. Each becomes its one-shot next week; Monday and
    /// Tuesday stay weekly. Met AFTER Wednesday's time (Gemini A4): Wednesday stays weekly, the
    /// rest of the week is still overlaid — gating the whole overlay on today's time would have
    /// left Thursday to Sunday firing.
    func testATimesPerWeekGoalMetQuietsTheRestOfTheWeek() {
        let quiet = (3...7).map { key(2026, 6, $0) }
        let run = habit(.timesPerWeek, quiet: quiet)
        let morning = ReminderPlan.plan([run], today: today(tokyo, 2026, 6, 3, 10))
        XCTAssertEqual(morning.requests, [oneShot(run, 1, 2026, 6, 14), weekly(run, 2), weekly(run, 3),
                                          oneShot(run, 4, 2026, 6, 10), oneShot(run, 5, 2026, 6, 11),
                                          oneShot(run, 6, 2026, 6, 12), oneShot(run, 7, 2026, 6, 13)])

        let night = ReminderPlan.plan([run], today: today(tokyo, 2026, 6, 3, 21))
        XCTAssertEqual(night.requests, [oneShot(run, 1, 2026, 6, 14), weekly(run, 2), weekly(run, 3),
                                        weekly(run, 4), oneShot(run, 5, 2026, 6, 11),
                                        oneShot(run, 6, 2026, 6, 12), oneShot(run, 7, 2026, 6, 13)])
    }

    /// Only today (while ahead) and this week's later days are overlaid: yesterday — the
    /// late-night grace's credit quiets yesterday, never today — last week and next week are
    /// ignored.
    func testOnlyTodayAndTheRestOfThisWeekAreOverlaid() {
        let read = habit(quiet: [key(2026, 6, 2), key(2026, 5, 27), key(2026, 6, 8), key(2026, 6, 10)])
        let plan = ReminderPlan.plan([read], today: today(tokyo, 2026, 6, 3, 0, 40))
        XCTAssertEqual(plan.requests, ReminderPlan.requests(for: read))
        XCTAssertEqual(ReminderPlan.plan([read]).requests, ReminderPlan.requests(for: read), "no today: the base")
    }

    /// The late-night grace (D4): at 00:40 a reminder answered for yesterday credits yesterday. The
    /// record is yesterday's, so today's state is still due and today's reminder still fires.
    func testTheLateNightGraceQuietsYesterdayNeverToday() {
        let wednesday = key(2026, 6, 3)
        let stats = Self.stats(.daily, checkIns: [key(2026, 6, 2)], today: wednesday, calendar: newYork,
                               created: key(2026, 5, 1))
        XCTAssertEqual(ReminderPlan.quietDays(of: stats, today: wednesday), [])
        var read = habit(hour: 0, minute: 30)
        read.quietDays = ReminderPlan.quietDays(of: stats, today: wednesday)
        let plan = ReminderPlan.plan([read], today: today(newYork, 2026, 6, 3, 0, 10))
        XCTAssertEqual(plan.requests.map(\.identifier), [id(read)])
    }

    /// `quietDays` reads `DailyProgress`: done today; a met times-per-week week from the day it is
    /// met through Sunday; a Sunday's week ends that day.
    func testQuietDaysComeFromDailyProgress() {
        let created = key(2026, 5, 1)
        let wednesday = key(2026, 6, 3)
        XCTAssertEqual(ReminderPlan.quietDays(of: Self.stats(.daily, checkIns: [wednesday], today: wednesday,
                                                             calendar: tokyo, created: created), today: wednesday),
                       [wednesday])
        let met = Self.stats(.timesPerWeek, timesPerWeek: 2, checkIns: [key(2026, 6, 1), key(2026, 6, 2)],
                             today: wednesday, calendar: tokyo, created: created)
        XCTAssertEqual(ReminderPlan.quietDays(of: met, today: wednesday), Set((3...7).map { key(2026, 6, $0) }))
        let notMet = Self.stats(.timesPerWeek, timesPerWeek: 3, checkIns: [key(2026, 6, 1)],
                                today: wednesday, calendar: tokyo, created: created)
        XCTAssertEqual(ReminderPlan.quietDays(of: notMet, today: wednesday), [])
        let sunday = key(2026, 6, 7)
        XCTAssertEqual(ReminderPlan.quietDays(of: Self.stats(.daily, checkIns: [sunday], today: sunday,
                                                             calendar: tokyo, created: created), today: sunday),
                       [sunday])
    }

    // MARK: - The Daily Reminder

    /// A perfect day before the Daily Reminder's time: its bare request becomes six weekly ones and
    /// a one-shot next week, under the evening's own ids. Not perfect, or after its time: the bare
    /// request. The morning reminder is not the planner's.
    func testTheDailyReminderIsOverlaidOnAPerfectDay() {
        let wednesday = today(tokyo, 2026, 6, 3, 10)
        let perfect = ReminderPlan.plan([], evening: .init(hour: 20, minute: 0, isPerfectToday: true), today: wednesday)
        XCTAssertTrue(perfect.eveningOverlaid)
        XCTAssertEqual(perfect.evening.map(\.identifier),
                       ["stride.daily.evening.1", "stride.daily.evening.2", "stride.daily.evening.3",
                        "stride.daily.evening.n4", "stride.daily.evening.5", "stride.daily.evening.6",
                        "stride.daily.evening.7"])
        XCTAssertEqual(perfect.evening[3].dateComponents, DateComponents(year: 2026, month: 6, day: 10, hour: 20, minute: 0))
        XCTAssertFalse(perfect.evening[3].repeats)
        XCTAssertTrue(perfect.evening.allSatisfy { $0.habitID == nil })

        let bare = [ReminderPlan.Request(identifier: "stride.daily.evening", habitID: nil,
                                         dateComponents: DateComponents(hour: 20, minute: 0))]
        XCTAssertEqual(ReminderPlan.plan([], evening: .init(hour: 20, minute: 0, isPerfectToday: false),
                                         today: wednesday).evening, bare)
        XCTAssertEqual(ReminderPlan.plan([], evening: .init(hour: 20, minute: 0, isPerfectToday: true),
                                         today: today(tokyo, 2026, 6, 3, 20, 5)).evening, bare)
        XCTAssertEqual(ReminderPlan.plan([], evening: nil, today: wednesday).evening, [], "off: nothing")
    }

    /// The Daily Reminder as the app stores it (and the widget reads it from the App Group): off
    /// is nil; an hour never set is 20:00; a chosen midnight is 00:00.
    func testTheDailyReminderIsReadAsNotificationServiceStoresIt() throws {
        let name = "ReminderPlanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(ReminderPlan.Evening.stored(in: defaults, isPerfectToday: true))
        defaults.set(true, forKey: "reminderEnabled")
        XCTAssertEqual(ReminderPlan.Evening.stored(in: defaults, isPerfectToday: true),
                       .init(hour: 20, minute: 0, isPerfectToday: true))
        defaults.set(0, forKey: "reminderHour")
        defaults.set(true, forKey: "reminderHourSet")
        defaults.set(15, forKey: "reminderMinute")
        XCTAssertEqual(ReminderPlan.Evening.stored(in: defaults, isPerfectToday: false),
                       .init(hour: 0, minute: 15, isPerfectToday: false))
    }

    // MARK: - Dates and zones (Gemini A5)

    /// The one-shot's date is the quiet day's key + 7 days in UTC, with no time zone in the
    /// components. Across New York's fall-back night (Sunday 2026-11-01) a local instant + 7 × 86 400 s
    /// lands on day 6 for a reminder just after midnight; the key does not.
    func testTheOneShotIsTheSameWeekdayNextWeekAcrossAFallBackNight() throws {
        let saturday = today(newYork, 2026, 10, 31, 0, 10)
        let late = habit(hour: 0, minute: 30, quiet: [key(2026, 10, 31)])
        let plan = ReminderPlan.plan([late], today: saturday)
        let shot = try XCTUnwrap(plan.requests.first { $0.identifier == "\(id(late)).n7" })
        XCTAssertEqual(shot.dateComponents, DateComponents(year: 2026, month: 11, day: 7, hour: 0, minute: 30))
        XCTAssertNil(shot.dateComponents.timeZone)
        XCTAssertNil(shot.dateComponents.calendar)
        XCTAssertFalse(shot.repeats)

        let fires = try XCTUnwrap(newYork.nextDate(after: saturday.now, matching: shot.dateComponents, matchingPolicy: .nextTime))
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: fires, calendar: newYork), key(2026, 11, 7))
        XCTAssertEqual(newYork.component(.hour, from: fires), 0)

        let naive = at(newYork, 2026, 10, 31, 0, 30).addingTimeInterval(7 * 86_400)
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: naive, calendar: newYork), key(2026, 11, 6),
                       "why the date is never seconds added to a local instant")
    }

    /// Apia (UTC+13) and Los Angeles (UTC−7) on the same local Wednesday: the same one-shot date,
    /// though the two instants are almost a day apart in UTC.
    func testTheOneShotDateIsTheLocalDateInEveryZone() {
        for cal in [apia, losAngeles, tokyo, newYork] {
            let read = habit(hour: 23, minute: 30, quiet: [key(2026, 6, 3)])
            let plan = ReminderPlan.plan([read], today: today(cal, 2026, 6, 3, 23, 0))
            XCTAssertEqual(plan.requests.first { $0.repeats == false }, oneShot(read, 4, 2026, 6, 10),
                           cal.timeZone.identifier)
        }
    }

    // MARK: - The budget (Gemini A0)

    /// Overlays are added in order of reminder time while the total stays within 58; one that does
    /// not fit is skipped (its habit keeps the base and over-fires today), and a later, cheaper one
    /// can still fit. Input order does not decide it: the 21:00 habit comes first in the input.
    func testOverlaysFitTheBudgetInReminderTimeOrder() {
        let wednesday = key(2026, 6, 3)
        let sixDays = (0..<7).map { _ in habit(.specificDays, mask: 0b111_1110) }   // 42
        let evening = habit(hour: 21, quiet: [wednesday])                          // +6
        let morning = habit(hour: 7, quiet: [wednesday])                           // +6
        let gym = habit(.specificDays, mask: mwf, hour: 22, quiet: [wednesday])    // 3, +0
        let plain = (0..<2).map { _ in habit() }
        let now = today(tokyo, 2026, 6, 3, 6)

        // 42 + 1 + 1 + 3 + 2 = 49 base; +6 +6 = 61 > 58: the 07:00 overlay first, the 21:00 one
        // does not fit, the free one still does.
        let plan = ReminderPlan.plan(sixDays + [evening, morning, gym] + plain, today: now)
        XCTAssertFalse(plan.fellBackToDaily)
        XCTAssertEqual(plan.overlaid, [morning.habitID, gym.habitID])
        XCTAssertEqual(plan.requests.filter { $0.habitID == evening.habitID }.map(\.identifier), [id(evening)])
        XCTAssertEqual(plan.requests.count, 55)

        // One plain habit fewer and no gym: 42 + 2 + 1 = 45, + 12 = 57: both fit.
        let both = ReminderPlan.plan(sixDays + [evening, morning, plain[0]], today: now)
        XCTAssertEqual(both.overlaid, [morning.habitID, evening.habitID])
        XCTAssertEqual(both.requests.count, 57)
    }

    /// The Daily Reminder's overlay is inside the 58: its base slot is reserved outside, its six
    /// extra requests are not.
    func testTheDailyRemindersOverlayCountsInsideTheBudget() {
        let now = today(tokyo, 2026, 6, 3, 10)
        let perfect = ReminderPlan.Evening(hour: 20, minute: 0, isPerfectToday: true)
        let fiftyTwo = (0..<52).map { _ in habit() }
        let fits = ReminderPlan.plan(fiftyTwo, evening: perfect, today: now)
        XCTAssertTrue(fits.eveningOverlaid)
        XCTAssertEqual(fits.requests.count + fits.evening.count - 1, 58)

        let fiftyThree = (0..<53).map { _ in habit() }
        let over = ReminderPlan.plan(fiftyThree, evening: perfect, today: now)
        XCTAssertFalse(over.eveningOverlaid)
        XCTAssertEqual(over.evening.map(\.identifier), ["stride.daily.evening"])
    }

    /// When the base plan alone is over the budget, nothing is overlaid: the plan is exactly the one
    /// made without any quiet day — 1.4.2's, every specific-days habit on its daily trigger.
    func testOverTheBudgetThePlanIsExactlyTodays() {
        let wednesday = key(2026, 6, 3)
        let sixDays = (0..<9).map { _ in habit(.specificDays, mask: 0b111_1110, quiet: [wednesday]) }  // 54
        let daily = (0..<5).map { _ in habit(quiet: [wednesday]) }                                     // 59
        let quietPlan = ReminderPlan.plan(sixDays + daily, evening: .init(hour: 20, minute: 0, isPerfectToday: true),
                                          today: today(tokyo, 2026, 6, 3, 6))
        let unquiet = (sixDays + daily).map { s -> ReminderPlan.Settings in var s = s; s.quietDays = []; return s }
        let base = ReminderPlan.plan(unquiet, evening: .init(hour: 20, minute: 0))
        XCTAssertTrue(quietPlan.fellBackToDaily)
        XCTAssertEqual(quietPlan.requests, base.requests)
        XCTAssertEqual(quietPlan.evening, base.evening)
        XCTAssertTrue(quietPlan.overlaid.isEmpty)
        XCTAssertFalse(quietPlan.eveningOverlaid)
        XCTAssertTrue(quietPlan.requests.allSatisfy { $0.weekday == nil && $0.repeats })
    }

    // MARK: - Never under-fires

    /// The property D4 is built on: for every reminder habit and every due day from tomorrow to
    /// today + 7, some planned request fires that day — and on a quiet today whose time is ahead,
    /// none fires today. Fires are what the calendar itself finds (`nextDate`, as a calendar
    /// trigger does), in Asia/Tokyo, Los Angeles and New York (a spring-forward week and the
    /// fall-back week) and Pacific/Apia (UTC+13), for every day of the week, three times of day and
    /// reminders around midnight and in the DST gap. Due days are `DailyProgress`'s.
    func testThePlanNeverUnderFires() {
        let weeks = [key(2026, 3, 2), key(2026, 10, 26)]
        let times = [(0, 30), (2, 30), (7, 0), (23, 30)]
        let nows = [(0, 10), (12, 0), (23, 50)]
        var checked = 0
        for cal in [tokyo, losAngeles, newYork, apia] {
            for monday in weeks {
                for offset in 0..<7 {
                    let t = HabitCalendar.utc.date(byAdding: .day, value: offset, to: monday)!
                    let ymd = HabitCalendar.utc.dateComponents([.year, .month, .day], from: t)
                    let day = { (n: Int) in HabitCalendar.utc.date(byAdding: .day, value: n, to: t)! }
                    let scenarios: [(String, HabitSchedule, Int, Int, [Date])] = [
                        ("daily done", .daily, 127, 1, [t]),
                        ("daily open", .daily, 127, 1, []),
                        ("mwf done", .specificDays, mwf, 1, [t]),
                        ("mwf open", .specificDays, mwf, 1, []),
                        ("3x met by today", .timesPerWeek, 127, 3, Array(Set([monday, day(0), day(offset > 0 ? -1 : 0)]))),
                        ("1x met Monday", .timesPerWeek, 127, 1, [monday]),
                        ("2x done today only", .timesPerWeek, 127, 2, [t]),
                    ]
                    for (name, schedule, mask, perWeek, checkIns) in scenarios {
                        let stats = Self.stats(schedule, mask: mask, timesPerWeek: perWeek, checkIns: checkIns,
                                               today: t, calendar: cal,
                                               created: HabitCalendar.utc.date(byAdding: .day, value: -21, to: monday)!)
                        let quiet = ReminderPlan.quietDays(of: stats, today: t)
                        for (h, m) in times {
                            for (nh, nm) in nows {
                                let now = at(cal, ymd.year!, ymd.month!, ymd.day!, nh, nm)
                                let planToday = ReminderPlan.Today(dayKey: t, now: now, calendar: cal)
                                let settings = ReminderPlan.Settings(habitID: UUID(), schedule: schedule,
                                                                     activeDaysMask: mask, hour: h, minute: m,
                                                                     quietDays: quiet)
                                let plan = ReminderPlan.plan([settings], today: planToday)
                                let fires = Self.fireDays(plan.requests, after: now, calendar: cal)
                                let label = "\(cal.timeZone.identifier) \(ymd.month!)-\(ymd.day!) \(nh):\(nm) \(name) at \(h):\(m)"
                                for k in 1...7 {
                                    let d = day(k)
                                    guard DailyProgress.state(of: stats, on: d) == .due else { continue }
                                    XCTAssertTrue(fires.contains(d), "\(label): nothing fires on +\(k)")
                                    checked += 1
                                }
                                if quiet.contains(t), ReminderPlan.isAhead(hour: h, minute: m, now: now, calendar: cal),
                                   ReminderPlan.weekdays(for: settings)?.contains(HabitStats.weekday(ofDay: HabitStats.dayNumber(ofKey: t))) ?? true {
                                    XCTAssertFalse(fires.contains(t), "\(label): fires on its quiet today")
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000, "the property ran")
    }

    /// The same for the Daily Reminder on a perfect day: silent tonight, firing every day after.
    func testThePerfectDayEveningNeverUnderFires() {
        for cal in [tokyo, losAngeles, newYork, apia] {
            for offset in 0..<7 {
                let t = HabitCalendar.utc.date(byAdding: .day, value: offset, to: key(2026, 10, 26))!
                let ymd = HabitCalendar.utc.dateComponents([.year, .month, .day], from: t)
                let now = at(cal, ymd.year!, ymd.month!, ymd.day!, 9)
                let plan = ReminderPlan.plan([], evening: .init(hour: 20, minute: 0, isPerfectToday: true),
                                             today: .init(dayKey: t, now: now, calendar: cal))
                let fires = Self.fireDays(plan.evening, after: now, calendar: cal)
                XCTAssertFalse(fires.contains(t), "\(cal.timeZone.identifier) \(offset)")
                for k in 1...7 {
                    XCTAssertTrue(fires.contains(HabitCalendar.utc.date(byAdding: .day, value: k, to: t)!),
                                  "\(cal.timeZone.identifier) \(offset) +\(k)")
                }
            }
        }
    }

    // MARK: - Helpers (static: no main actor needed)

    /// A habit's stats as the app builds them, from day-key check-ins, through `today`.
    static func stats(_ schedule: HabitSchedule, mask: Int = 127, timesPerWeek: Int = 1, checkIns: [Date],
                      today: Date, calendar: Calendar, created: Date) -> HabitStats {
        HabitStats(records: checkIns.map { HabitRecord(date: $0) }, live: .all, kind: .binary, targetValue: 1,
                   schedule: schedule, timesPerWeek: timesPerWeek, activeDaysMask: mask, createdAt: created,
                   calendar: calendar, today: today)
    }

    /// The local days (as day-keys) the requests fire on in the nine days after `now`, as the
    /// calendar finds them: repeating ones every match, a one-shot once.
    static func fireDays(_ requests: [ReminderPlan.Request], after now: Date, calendar: Calendar) -> Set<Date> {
        let end = now.addingTimeInterval(9 * 86_400)
        var days: Set<Date> = []
        for request in requests {
            var cursor = now
            while let next = calendar.nextDate(after: cursor, matching: request.dateComponents, matchingPolicy: .nextTime),
                  next < end {
                days.insert(HabitCalendar.dayKey(forInstant: next, calendar: calendar))
                guard request.repeats else { break }
                cursor = next
            }
        }
        return days
    }
}
