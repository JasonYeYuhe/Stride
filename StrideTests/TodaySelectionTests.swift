import XCTest
import Foundation

/// Which day the Today screen shows once the date has changed under it. It used to stay on the
/// day the view was created: open at 23:50, come back at 07:30, and every check-in went to
/// yesterday.
final class TodaySelectionTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testLookingAtTodayFollowsTheNewDay() {
        let result = TodaySelection.reanchored(selected: at(14, 23, 50), shownOn: at(14, 23, 50), now: at(15, 7, 30), calendar: calendar)
        XCTAssertTrue(calendar.isDate(result, inSameDayAs: at(15, 7, 30)), "was the 14th: check-ins went to yesterday")
    }

    func testSameDayChangesNothing() {
        let picked = at(12, 9)
        XCTAssertEqual(TodaySelection.reanchored(selected: picked, shownOn: at(14, 8), now: at(14, 22), calendar: calendar), picked)
        XCTAssertEqual(TodaySelection.reanchored(selected: at(14, 8), shownOn: at(14, 8), now: at(14, 22), calendar: calendar), at(14, 8))
    }

    func testADayThePersonPickedStaysPicked() {
        let picked = at(12, 9)   // tapped in the week strip on the 14th
        XCTAssertEqual(TodaySelection.reanchored(selected: picked, shownOn: at(14, 23), now: at(15, 7), calendar: calendar), picked)
    }

    func testAPickedDayThatLeftTheWeekStripReturnsToToday() {
        let picked = at(8, 9)    // the oldest day in the strip on the 14th
        let result = TodaySelection.reanchored(selected: picked, shownOn: at(14, 23), now: at(15, 7), calendar: calendar)
        XCTAssertTrue(calendar.isDate(result, inSameDayAs: at(15, 7)), "the 8th is no longer in the strip, so nothing on screen is selected")
    }
}
