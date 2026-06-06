import XCTest
import Foundation
import SwiftData

/// Tests for quantitative ("count") habit completion, progress, and streaks.
final class CountHabitTests: XCTestCase {

    private func makeCountHabit(target: Double = 8) -> Habit {
        let h = Habit(name: "Water")
        h.habitKind = .count
        h.targetValue = target
        h.unit = "glasses"
        return h
    }

    func testBinaryDefaults() {
        let h = Habit(name: "Read")
        XCTAssertEqual(h.habitKind, .binary)
        XCTAssertEqual(h.schedule, .daily)
        XCTAssertEqual(h.targetValue, 1)
        XCTAssertEqual(h.activeDaysMask, 127)
        XCTAssertNil(h.groupId)
    }

    func testCountNotCompleteBelowTarget() {
        let h = makeCountHabit(target: 8)
        h.records.append(HabitRecord(date: Date(), value: 5))
        XCTAssertFalse(h.isCompletedOn(Date()))
        XCTAssertEqual(h.loggedValue(on: Date()), 5)
        XCTAssertEqual(h.progress(on: Date()), 5.0 / 8.0, accuracy: 0.0001)
    }

    func testCountCompleteAtOrAboveTarget() {
        let h = makeCountHabit(target: 8)
        h.records.append(HabitRecord(date: Date(), value: 8))
        XCTAssertTrue(h.isCompletedOn(Date()))
        XCTAssertEqual(h.progress(on: Date()), 1.0, accuracy: 0.0001)
    }

    func testCountProgressClampedAboveTarget() {
        let h = makeCountHabit(target: 8)
        h.records.append(HabitRecord(date: Date(), value: 12))
        XCTAssertTrue(h.isCompletedOn(Date()))
        XCTAssertEqual(h.progress(on: Date()), 1.0, accuracy: 0.0001)
    }

    func testCountStreakCountsOnlyTargetMetDays() {
        let h = makeCountHabit(target: 3)
        let cal = Calendar.current
        // today: met (3), yesterday: not met (1), 2 days ago: met (3)
        h.records.append(HabitRecord(date: Date(), value: 3))
        h.records.append(HabitRecord(date: cal.date(byAdding: .day, value: -1, to: Date())!, value: 1))
        h.records.append(HabitRecord(date: cal.date(byAdding: .day, value: -2, to: Date())!, value: 3))
        // Only today qualifies consecutively (yesterday missed target → breaks streak)
        XCTAssertEqual(h.currentStreak(), 1)
    }

    func testBinaryStreakUnaffectedByValue() {
        let h = Habit(name: "Meditate") // binary
        let cal = Calendar.current
        for offset in 0...2 {
            h.records.append(HabitRecord(date: cal.date(byAdding: .day, value: -offset, to: Date())!))
        }
        XCTAssertEqual(h.currentStreak(), 3)
    }
}
