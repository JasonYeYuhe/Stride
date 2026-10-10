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

    /// Everything a habit can ever have pending or delivered: the legacy id, seven weekday ids and
    /// the snooze. Whatever shape it is planned in, every planned id is among them, so "remove all
    /// variants, then add" never leaves the other shape's requests firing.
    func testAllIdentifiersCoverEveryShape() {
        let id = UUID()
        let all = ReminderPlan.allIdentifiers(for: id)
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(Set(all).count, 9)
        XCTAssertEqual(all.first, "stride.habit.reminder.\(id.uuidString)")
        XCTAssertEqual(all.last, "stride.habit.snooze.\(id.uuidString)")
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

    /// The launch prune removes every per-habit request the plan does not keep, and nothing else:
    /// - a Mon/Wed/Fri habit's 1.3.x daily id (it fired on rest days) goes; its weekday ids stay;
    /// - a planned habit's snooze stays; the snooze of a habit whose reminder is now off goes;
    /// - an orphan of a habit deleted on another device goes;
    /// - the global reminders and anything not ours are never touched.
    /// 1.3.x kept only `prefix + uuid` and would have removed every weekday request on each launch.
    func testThePruneKeepsThePlanAndItsSnoozes() {
        let mwf = habit(.specificDays, mask: 0b010_1010)
        let daily = habit(.daily)
        let off = UUID()
        let deleted = UUID()
        let result = ReminderPlan.plan([mwf, daily])

        XCTAssertEqual(result.keep, Set(result.requests.map(\.identifier)).union([
            ReminderPlan.snoozeIdentifier(for: mwf.habitID), ReminderPlan.snoozeIdentifier(for: daily.habitID),
        ]))

        let pending = [
            "stride.daily.evening", "stride.daily.morning", "com.example.other",
            legacy(mwf), "\(legacy(mwf)).2", "\(legacy(mwf)).4", "\(legacy(mwf)).6", "\(legacy(mwf)).1",
            legacy(daily), ReminderPlan.snoozeIdentifier(for: daily.habitID),
            ReminderPlan.snoozeIdentifier(for: off), ReminderPlan.legacyIdentifier(for: deleted),
            "\(ReminderPlan.legacyIdentifier(for: deleted)).3",
        ]
        XCTAssertEqual(ReminderPlan.prune(pending, keep: result.keep), [
            legacy(mwf), "\(legacy(mwf)).1",
            ReminderPlan.snoozeIdentifier(for: off), ReminderPlan.legacyIdentifier(for: deleted),
            "\(ReminderPlan.legacyIdentifier(for: deleted)).3",
        ])
    }

    /// After the budget's fallback the plan keeps the daily ids, so the prune takes the weekday
    /// ones out — no habit is left with both shapes.
    func testThePruneFollowsTheFallback() {
        let mwf = habit(.specificDays, mask: 0b010_1010)
        let result = ReminderPlan.plan([mwf], budget: 2)
        XCTAssertTrue(result.fellBackToDaily)
        let weekdayIDs = [2, 4, 6].map { "\(legacy(mwf)).\($0)" }
        XCTAssertEqual(ReminderPlan.prune(weekdayIDs + [legacy(mwf)], keep: result.keep), weekdayIDs)
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
