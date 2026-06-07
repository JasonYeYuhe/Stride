import XCTest
import Foundation
import SwiftData

/// Tests for flexible/forgiving scheduling: specific-days (rest days skipped)
/// and times-per-week (week-unit streaks).
final class FrequencyTests: XCTestCase {

    private let utc = HabitCalendar.utc

    private func day(_ ref: Date, minus n: Int) -> Date {
        utc.date(byAdding: .day, value: -n, to: HabitCalendar.dayKey(for: ref))!
    }

    /// A reference "today" that is a Wednesday (mid Mon-anchored week) for stable week math.
    private func aWednesday() -> Date {
        var d = utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        while utc.component(.weekday, from: d) != 4 { // 4 = Wednesday
            d = utc.date(byAdding: .day, value: 1, to: d)!
        }
        return d
    }

    func testIsScheduledRespectsActiveDaysMask() {
        let h = Habit(name: "Gym")
        h.schedule = .specificDays
        // Activate only the weekday of our reference date.
        let ref = aWednesday()
        let weekday = utc.component(.weekday, from: ref) // 4
        h.activeDaysMask = 1 << (weekday - 1)
        XCTAssertTrue(h.isScheduled(on: ref))
        XCTAssertFalse(h.isScheduled(on: day(ref, minus: 1))) // Tuesday — not active
    }

    func testRestDayDoesNotBreakStreak() {
        let h = Habit(name: "Run")
        h.schedule = .specificDays
        let ref = aWednesday()
        // Make yesterday (ref-1) a rest day; all other weekdays active.
        let yWeekday = utc.component(.weekday, from: day(ref, minus: 1))
        h.activeDaysMask = 127 & ~(1 << (yWeekday - 1))
        // Completed today and the day before yesterday (both scheduled); ref-1 is rest.
        h.records.append(HabitRecord(date: ref))
        h.records.append(HabitRecord(date: day(ref, minus: 2)))
        XCTAssertEqual(h.currentStreak(from: ref), 2, "rest day between two done days must not break the streak")
    }

    func testMissedScheduledDayBreaksStreak() {
        let h = Habit(name: "Read")
        h.schedule = .specificDays
        h.activeDaysMask = 127 // every day scheduled
        let ref = aWednesday()
        h.records.append(HabitRecord(date: ref))                 // done
        h.records.append(HabitRecord(date: day(ref, minus: 2)))  // done, but ref-1 missed
        XCTAssertEqual(h.currentStreak(from: ref), 1, "a missed scheduled day breaks the streak")
    }

    func testTimesPerWeekCounts() {
        let h = Habit(name: "Yoga")
        h.schedule = .timesPerWeek
        h.timesPerWeek = 2
        let ref = aWednesday()
        h.records.append(HabitRecord(date: ref))                // Wed (this week)
        h.records.append(HabitRecord(date: day(ref, minus: 1))) // Tue (this week)
        XCTAssertEqual(h.weeklyCompletions(containing: ref), 2)
    }

    func testTimesPerWeekStreakCountsWeeks() {
        let h = Habit(name: "Yoga")
        h.schedule = .timesPerWeek
        h.timesPerWeek = 2
        let ref = aWednesday()
        // This week: 2 (meets target)
        h.records.append(HabitRecord(date: ref))
        h.records.append(HabitRecord(date: day(ref, minus: 1)))
        // Previous week: 2 (Wed-7 and Tue-7 = ref-7, ref-8)
        h.records.append(HabitRecord(date: day(ref, minus: 7)))
        h.records.append(HabitRecord(date: day(ref, minus: 8)))
        XCTAssertEqual(h.currentStreak(from: ref), 2, "two consecutive weeks meeting the weekly goal = 2-week streak")
        XCTAssertEqual(h.streakUnit, "week")
    }

    func testCompletionRateOverRange() {
        let h = Habit(name: "Read")
        h.createdAt = day(aWednesday(), minus: 30)
        let ref = aWednesday()
        // 7-day window ending ref; complete 3 of the 7 days.
        for off in [0, 2, 4] {
            h.records.append(HabitRecord(date: day(ref, minus: off)))
        }
        let rate = h.completionRate(from: day(ref, minus: 6), to: ref)
        XCTAssertEqual(rate, 3.0 / 7.0, accuracy: 0.0001)
    }

    func testCompletionRateSpecificDaysDenominatorExcludesRestDays() {
        let h = Habit(name: "Gym")
        h.createdAt = day(aWednesday(), minus: 30)
        h.schedule = .specificDays
        let ref = aWednesday()
        // Only ref's weekday is scheduled → in a 7-day window exactly 1 expected day.
        h.activeDaysMask = 1 << (utc.component(.weekday, from: ref) - 1)
        h.records.append(HabitRecord(date: ref))
        let rate = h.completionRate(from: day(ref, minus: 6), to: ref)
        XCTAssertEqual(rate, 1.0, accuracy: 0.0001, "rest days must not count in the denominator")
    }

    func testTimesPerWeekInProgressWeekDoesNotBreakStreak() {
        let h = Habit(name: "Yoga")
        h.schedule = .timesPerWeek
        h.timesPerWeek = 2
        let ref = aWednesday()
        // This week only 1 (in progress, below target) — grace.
        h.records.append(HabitRecord(date: ref))
        // Previous week: met target.
        h.records.append(HabitRecord(date: day(ref, minus: 7)))
        h.records.append(HabitRecord(date: day(ref, minus: 8)))
        XCTAssertEqual(h.currentStreak(from: ref), 1, "in-progress week below target shouldn't break the prior streak")
    }
}
