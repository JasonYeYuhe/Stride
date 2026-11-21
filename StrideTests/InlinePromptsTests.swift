import XCTest
import SwiftData
import Foundation

/// Today's "Your week" card (`InlinePrompts`, RELEASE-1.4.2.md D12, W7): when it shows, its copy,
/// the free cap and what × does.
///
/// The window is the local Monday 00:00 … Tuesday 23:59, so every boundary is built in an explicit
/// zone (Asia/Tokyo, America/Los_Angeles) and in the process's own zone — Tokyo by default, Los
/// Angeles under `TEST_RUNNER_TZ=America/Los_Angeles` — so both runs cover both zones. 2026-06-01
/// is a Monday. The DST weekends are Los Angeles' 2026-11-01 (fall back) and 2026-03-08 (spring
/// forward), and Berlin's 2026-03-29.
@MainActor
final class InlinePromptsTests: XCTestCase {

    typealias Prompts = InlinePrompts

    private static func gregorian(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private let tokyo = gregorian(TimeZone(identifier: "Asia/Tokyo")!)
    private let la = gregorian(TimeZone(identifier: "America/Los_Angeles")!)
    private let berlin = gregorian(TimeZone(identifier: "Europe/Berlin")!)
    /// The process's zone.
    private let local = gregorian(.current)
    private var zones: [Calendar] { [tokyo, la, local] }

    /// A local wall-clock instant in `calendar`'s zone.
    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                    _ second: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute,
                                           second: second))!
    }

    private func dayNumber(_ month: Int, _ day: Int) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.utc.date(from: DateComponents(year: 2026, month: month, day: day))!)
    }

    private func card(_ now: Date, _ calendar: Calendar, isPro: Bool, rate: Double? = 0.82,
                      state: Prompts.DismissalState = .empty) -> Prompts.WeekCard? {
        Prompts.weekCard(now: now, calendar: calendar, isPro: isPro, lastWeekRate: rate, state: state)
    }

    // MARK: - The window

    func testMondayMidnightOpensTheWindow() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            XCTAssertTrue(Prompts.isInWindow(now: at(6, 1, 0, 0, in: calendar), calendar: calendar), zone)
            XCTAssertFalse(Prompts.isInWindow(now: at(5, 31, 23, 59, 59, in: calendar), calendar: calendar),
                           "Sunday 23:59:59, \(zone)")
            XCTAssertNotNil(card(at(6, 1, 0, 0, in: calendar), calendar, isPro: true), zone)
            XCTAssertNil(card(at(5, 31, 23, 59, in: calendar), calendar, isPro: true), zone)
        }
    }

    func testTuesday2359IsInAndWednesdayMidnightIsOut() {
        for calendar in zones {
            let zone = calendar.timeZone.identifier
            XCTAssertTrue(Prompts.isInWindow(now: at(6, 2, 23, 59, 59, in: calendar), calendar: calendar), zone)
            XCTAssertFalse(Prompts.isInWindow(now: at(6, 3, 0, 0, in: calendar), calendar: calendar), zone)
            XCTAssertNotNil(card(at(6, 2, 23, 59, in: calendar), calendar, isPro: false), zone)
            XCTAssertNil(card(at(6, 3, 0, 0, in: calendar), calendar, isPro: false), zone)
            XCTAssertNil(card(at(6, 3, 0, 0, in: calendar), calendar, isPro: true), zone)
        }
    }

    /// Thursday to Sunday are out, every hour.
    func testTheRestOfTheWeekIsOut() {
        for calendar in zones {
            for day in 3...7 {
                for hour in [0, 9, 23] {
                    XCTAssertFalse(Prompts.isInWindow(now: at(6, day, hour, 0, in: calendar), calendar: calendar),
                                   "06-0\(day) \(hour):00 \(calendar.timeZone.identifier)")
                }
            }
        }
    }

    /// The same instant is a Monday in Tokyo and still Sunday in Los Angeles: the local date rules.
    func testTheWindowIsLocalNotUTC() {
        let mondayMorningTokyo = at(6, 1, 8, 0, in: tokyo)       // Sunday 16:00 in Los Angeles
        XCTAssertTrue(Prompts.isInWindow(now: mondayMorningTokyo, calendar: tokyo))
        XCTAssertFalse(Prompts.isInWindow(now: mondayMorningTokyo, calendar: la))
        // Exactly UTC midnight of Monday: Sunday 17:00 PDT, not Monday.
        let utcMidnight = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        XCTAssertFalse(Prompts.isInWindow(now: utcMidnight, calendar: la))
        XCTAssertTrue(Prompts.isInWindow(now: utcMidnight, calendar: tokyo))
    }

    /// The DST weekends: the change is on the Sunday, and Monday 00:00 still opens the window, Tuesday
    /// 23:59 still closes it, and the week is the Monday-anchored one.
    func testDSTWeekends() {
        for (calendar, month, monday) in [(la, 11, 2), (la, 3, 9), (berlin, 3, 30)] {
            let zone = calendar.timeZone.identifier
            XCTAssertFalse(Prompts.isInWindow(now: at(month, monday - 1, 23, 59, in: calendar), calendar: calendar), zone)
            XCTAssertTrue(Prompts.isInWindow(now: at(month, monday, 0, 0, in: calendar), calendar: calendar), zone)
            XCTAssertTrue(Prompts.isInWindow(now: at(month, monday + 1, 23, 59, in: calendar), calendar: calendar), zone)
            XCTAssertFalse(Prompts.isInWindow(now: at(month, monday + 2, 0, 0, in: calendar), calendar: calendar), zone)
            let week = Prompts.currentWeek(now: at(month, monday, 0, 0, in: calendar), calendar: calendar)
            XCTAssertEqual(week.mondayNumber, dayNumber(month, monday), zone)
            XCTAssertEqual(Prompts.lastWeek(now: at(month, monday, 0, 30, in: calendar), calendar: calendar).mondayNumber,
                           dayNumber(month, monday) - 7, zone)
        }
    }

    /// The Japanese calendar and a Sunday-first region move nothing: the week is Monday-anchored on
    /// the Gregorian date.
    func testTheCalendarsIdentifierAndFirstWeekdayMoveNothing() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = tokyo.timeZone
        var sundayFirst = tokyo
        sundayFirst.firstWeekday = 1
        let monday = at(6, 1, 0, 0, in: tokyo)
        for calendar in [japanese, sundayFirst] {
            XCTAssertTrue(Prompts.isInWindow(now: monday, calendar: calendar))
            XCTAssertFalse(Prompts.isInWindow(now: at(6, 3, 0, 0, in: tokyo), calendar: calendar))
            XCTAssertEqual(Prompts.currentWeek(now: monday, calendar: calendar).mondayNumber, dayNumber(6, 1))
        }
    }

    // MARK: - The copy

    func testProShowsLastWeeksPercentAsTheReviewPrintsIt() {
        let monday = at(6, 1, 9, 0, in: local)
        let pro = card(monday, local, isPro: true, rate: 0.829)
        XCTAssertEqual(pro?.copy, .pro(percent: 82), "StatsInsights.percent: the review's ring truncates")
        XCTAssertEqual(pro?.lastWeek.mondayNumber, dayNumber(5, 25))
        XCTAssertEqual(pro?.shownWeek.mondayNumber, dayNumber(6, 1))
        XCTAssertEqual(card(monday, local, isPro: true, rate: 0)?.copy, .pro(percent: 0))
    }

    /// The free card carries no number at all: its copy has no field for one.
    func testTheFreeLineHasNoNumber() {
        let free = card(at(6, 1, 9, 0, in: local), local, isPro: false, rate: 0.82)
        XCTAssertEqual(free?.copy, .free)
        XCTAssertFalse(free?.isPro ?? true)
        XCTAssertFalse(String(describing: free?.copy as Any).contains("82"))
    }

    /// The tap issues Today's card request on last week's Monday (W4's rule decides review or
    /// paywall at the tap).
    func testTheTapIssuesLastWeek() {
        let lastMonday = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 5, day: 25))!
        for isPro in [true, false] {
            let c = card(at(6, 2, 20, 0, in: local), local, isPro: isPro)
            XCTAssertEqual(c?.issuer, .todayWeekCard(lastWeek: lastMonday))
        }
        XCTAssertEqual(MenuCommandRules.destination(for: .todayWeekCard(lastWeek: lastMonday), isPro: true),
                       .review(week: lastMonday))
        XCTAssertEqual(MenuCommandRules.destination(for: .todayWeekCard(lastWeek: lastMonday), isPro: false),
                       .paywall(trigger: .today, resume: .review(week: lastMonday)))
    }

    /// One card at most: `card(...)` is the week card or nothing.
    func testAtMostOneCard() {
        let monday = at(6, 1, 9, 0, in: local)
        XCTAssertEqual(Prompts.card(now: monday, calendar: local, isPro: true, lastWeekRate: 0.5, state: .empty),
                       .week(card(monday, local, isPro: true, rate: 0.5)!))
        XCTAssertNil(Prompts.card(now: at(6, 4, 9, 0, in: local), calendar: local, isPro: true, lastWeekRate: 0.5, state: .empty))
    }

    // MARK: - The first week

    /// No counted rate last week (a new user, or a habit that started this week): no card, Pro or
    /// free, and nothing counts toward the free cap.
    func testNoCountedRateLastWeekShowsNoCard() {
        let monday = at(6, 1, 9, 0, in: local)
        XCTAssertNil(card(monday, local, isPro: true, rate: nil))
        XCTAssertNil(card(monday, local, isPro: false, rate: nil))
    }

    /// The same edge through the review's own numbers: a habit created on Monday 06-01 has no rate
    /// for last week; one created the Monday before has.
    func testTheFirstWeekEdgeFromTheReviewsNumbers() throws {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let utc = HabitCalendar.utc
        func key(_ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: m, day: d))! }
        func rate(createdOn created: Date, checkedIn: [Date]) -> Double? {
            let h = Habit(name: "Run")
            h.createdAt = created
            context.insert(h)
            for d in checkedIn { h.records.append(HabitRecord(date: d)) }
            let now = at(6, 1, 9, 0, in: local)
            let stats = HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: context),
                                   calendar: local, today: WeeklyReviewMath.today(now: now, calendar: local))
            let review = WeeklyReviewMath.review(of: [.init(stats: stats)], week: Prompts.lastWeek(now: now, calendar: local))
            return review.overall
        }
        let newRate = rate(createdOn: key(6, 1), checkedIn: [key(6, 1)])
        XCTAssertNil(newRate, "created this week: nothing counted last week")
        XCTAssertNil(card(at(6, 1, 9, 0, in: local), local, isPro: true, rate: newRate))
        let olderRate = rate(createdOn: key(5, 25), checkedIn: [key(5, 25), key(5, 26)])
        XCTAssertNotNil(olderRate)
        XCTAssertEqual(card(at(6, 1, 9, 0, in: local), local, isPro: true, rate: olderRate)?.copy,
                       .pro(percent: StatsInsights.percent(olderRate!)))
        withExtendedLifetime(container) {}
    }

    // MARK: - The free cap

    /// A free user sees the card in at most 3 weeks ever: shown on Monday, it still shows on that
    /// Tuesday; the fourth week has none.
    func testTheFreeCapOfThreeWeeks() {
        var state = Prompts.DismissalState.empty
        let mondays = [(6, 1), (6, 8), (6, 15), (6, 22)]
        for (index, (month, day)) in mondays.enumerated() {
            let monday = at(month, day, 9, 0, in: local)
            let shown = card(monday, local, isPro: false, state: state)
            if index < Prompts.freeWeekCap {
                let c = try! XCTUnwrap(shown, "week \(index + 1)")
                state = Prompts.shown(c, in: state)
                state = Prompts.shown(c, in: state)   // shown again the same week: counted once
                XCTAssertEqual(state.freeWeeksShown.count, index + 1)
                XCTAssertNotNil(card(at(month, day + 1, 22, 0, in: local), local, isPro: false, state: state),
                                "the same week's Tuesday")
            } else {
                XCTAssertNil(shown, "the fourth week")
            }
        }
        XCTAssertEqual(state.freeWeeksShown, [dayNumber(6, 1), dayNumber(6, 8), dayNumber(6, 15)])
        // The cap is the free card's: Pro still shows every week.
        XCTAssertNotNil(card(at(6, 22, 9, 0, in: local), local, isPro: true, state: state))
    }

    /// A week the free card was not seen in does not count, and nothing past the cap is recorded.
    func testOnlyShownWeeksCount() {
        var state = Prompts.DismissalState(freeWeeksShown: [dayNumber(6, 1)])
        XCTAssertNotNil(card(at(6, 22, 9, 0, in: local), local, isPro: false, state: state))
        state = Prompts.DismissalState(freeWeeksShown: [dayNumber(6, 1), dayNumber(6, 8), dayNumber(6, 15)])
        let full = Prompts.WeekCard(shownWeek: .init(containingDay: dayNumber(6, 22)), copy: .free)
        XCTAssertEqual(Prompts.shown(full, in: state), state)
        // A Pro card counts nothing.
        let pro = Prompts.WeekCard(shownWeek: .init(containingDay: dayNumber(6, 22)), copy: .pro(percent: 50))
        XCTAssertEqual(Prompts.shown(pro, in: .empty), .empty)
    }

    // MARK: - ×

    /// Pro's × hides the card for the week it shows in, and only that week.
    func testProDismissHidesForThatWeek() throws {
        let monday = at(6, 1, 9, 0, in: local)
        let c = try XCTUnwrap(card(monday, local, isPro: true))
        let state = Prompts.dismissed(c, in: .empty)
        XCTAssertEqual(state.proHiddenWeek, dayNumber(6, 1))
        XCTAssertFalse(state.freeEnded)
        XCTAssertNil(card(monday, local, isPro: true, state: state))
        XCTAssertNil(card(at(6, 2, 23, 0, in: local), local, isPro: true, state: state), "the same week's Tuesday")
        XCTAssertNotNil(card(at(6, 8, 0, 0, in: local), local, isPro: true, state: state), "next week's Monday")
    }

    /// Free's × ends the card for good: every later week, whatever the cap says.
    func testFreeDismissEndsItForGood() throws {
        let c = try XCTUnwrap(card(at(6, 1, 9, 0, in: local), local, isPro: false))
        let state = Prompts.dismissed(c, in: .empty)
        XCTAssertTrue(state.freeEnded)
        XCTAssertEqual(state.freeWeeksShown, [dayNumber(6, 1)])
        for (month, day) in [(6, 1), (6, 8), (7, 6), (12, 28)] {
            XCTAssertNil(card(at(month, day, 9, 0, in: local), local, isPro: false, state: state), "\(month)-\(day)")
        }
        // The free ×'s end is not Pro's: a user who buys Pro sees Pro's card.
        XCTAssertNotNil(card(at(6, 8, 9, 0, in: local), local, isPro: true, state: state))
    }

    /// DEBUG's `-inlineCard week` forces the card any day and past any dismissal, but still needs a
    /// rate; it never changes the state.
    func testForcedCardIgnoresTheWindowAndTheState() {
        let thursday = at(6, 4, 9, 0, in: local)
        let ended = Prompts.DismissalState(proHiddenWeek: dayNumber(6, 1), freeWeeksShown: [1, 2, 3], freeEnded: true)
        XCTAssertNotNil(Prompts.weekCard(now: thursday, calendar: local, isPro: true, lastWeekRate: 0.5, state: ended,
                                         ignoresWindow: true))
        XCTAssertEqual(Prompts.weekCard(now: thursday, calendar: local, isPro: false, lastWeekRate: 0.5, state: ended,
                                        ignoresWindow: true)?.copy, .free)
        XCTAssertNil(Prompts.weekCard(now: thursday, calendar: local, isPro: true, lastWeekRate: nil, state: .empty,
                                      ignoresWindow: true))
    }
}
