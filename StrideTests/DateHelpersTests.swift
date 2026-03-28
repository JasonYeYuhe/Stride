import XCTest
import Foundation

final class DateHelpersTests: XCTestCase {

    // MARK: - startOfDay

    func testStartOfDayStripsTime() {
        let now = Date()
        let start = now.startOfDay
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: start)

        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testStartOfDayPreservesDate() {
        let now = Date()
        let calendar = Calendar.current
        let start = now.startOfDay

        XCTAssertEqual(calendar.component(.year, from: start), calendar.component(.year, from: now))
        XCTAssertEqual(calendar.component(.month, from: start), calendar.component(.month, from: now))
        XCTAssertEqual(calendar.component(.day, from: start), calendar.component(.day, from: now))
    }

    // MARK: - isToday

    func testIsTodayForNow() {
        XCTAssertTrue(Date().isToday)
    }

    func testIsTodayForYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        XCTAssertFalse(yesterday.isToday)
    }

    func testIsTodayForTomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertFalse(tomorrow.isToday)
    }

    // MARK: - daysInRange

    func testDaysInRangeSameDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let result = Date.daysInRange(from: today, to: today)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, today)
    }

    func testDaysInRangeMultipleDays() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        let result = Date.daysInRange(from: threeDaysAgo, to: today)

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.first, threeDaysAgo)
        XCTAssertEqual(result.last, today)
    }

    func testDaysInRangeReversedReturnsEmpty() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let result = Date.daysInRange(from: tomorrow, to: today)
        XCTAssertTrue(result.isEmpty)
    }

    func testDaysInRangeContiguousDates() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let fiveDaysAgo = calendar.date(byAdding: .day, value: -5, to: today)!

        let result = Date.daysInRange(from: fiveDaysAgo, to: today)

        // Verify each date is exactly 1 day after the previous
        for i in 1..<result.count {
            let diff = calendar.dateComponents([.day], from: result[i - 1], to: result[i]).day
            XCTAssertEqual(diff, 1)
        }
    }

    // MARK: - lastNDays

    func testLastNDaysCount() {
        let result = Date.lastNDays(7)
        XCTAssertEqual(result.count, 7)
    }

    func testLastNDaysEndsToday() {
        let result = Date.lastNDays(7)
        let today = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(result.last, today)
    }

    func testLastNDaysStartsCorrectly() {
        let result = Date.lastNDays(7)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expected = calendar.date(byAdding: .day, value: -6, to: today)!
        XCTAssertEqual(result.first, expected)
    }

    func testLastOneDayIsJustToday() {
        let result = Date.lastNDays(1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, Calendar.current.startOfDay(for: Date()))
    }
}
