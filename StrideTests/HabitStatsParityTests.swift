import XCTest
import SwiftData
import Foundation

/// Golden values of the 1.4.0 `Habit` statistics on the fixtures of RELEASE-1.4.1.md Data
/// safety 3, committed before W1 switched `Habit`'s aggregates to `HabitStats` (D2). Commit 1
/// was green on the 1.4.0 methods; commit 2 changed only the values marked `.named`.
///
/// **How the goldens were made.** Each fixture ran once through the current methods in
/// Asia/Tokyo, America/Los_Angeles and UTC, and the answers are pasted below as literals: nothing
/// here computes an expected value with the code under test. A throwaway model of the same rules,
/// written independently, reproduced every captured value with D2's fixes off. Turning one fix on
/// at a time named the fix behind every value that changes, and the `becomes:` literals are that
/// model's answers with all five fixes on.
///
/// **The switch.** `asserted(_:)` returned `today` in commit 1. Commit 2 changed it to
/// `commit2 ?? today`, which flips exactly the `.named` values (each has a `NAMED FIX` comment)
/// and nothing else. Commit 2 also checks `HabitStats` itself on these fixtures:
/// - its per-day answer equals `Habit.isCompletedOn` / `loggedValue` on every day, except on rows
///   that carry `stats:`. Those are a deletion saved by another context, which only the store's
///   ids can see, and days after today, which `HabitStats` ignores while the direct per-day
///   lookups (which do not know `today`) still read the record;
/// - `bestStreakRanges.first?.length == bestStreak()`.
///
/// **Zones.** Fixtures build day-keys with explicit calendars, so almost every answer is the same
/// in every zone. Two inputs legitimately depend on the zone the tests run in, because today's
/// code dates them with `Calendar.current`:
/// - an instant passed as the day itself (`instants:`);
/// - `createdAt`, which starts the rate (`.byCreationDayOffset`).
/// Those carry one golden per answer a zone can give. The golden is picked by how the run's zone
/// dates that instant against its UTC date: −1 or 0, which covers UTC−12 to UTC+14 for the
/// instants used here. The suite runs in the default zone and under TZ=America/Los_Angeles
/// (xcodebuild forwards TEST_RUNNER_TZ), and `setUp` prints the zone it sees.
///
/// **`completionRate(days:)` reads the clock.** So it is checked on a copy of the fixture moved
/// to end on the run's today. A schedule bound to weekdays then depends on the run's weekday
/// (`.byWeekday`). The captures for the other weekdays came from `completionRate(from:to:now:)`
/// over the same 30 days, which is the whole of `completionRate(days:)` (Habit.swift:320-325);
/// the capture checked that both agree on the run's own day.
///
/// **SwiftData behaviour these fixtures depend on** (measured 2026-10-15, macOS, in-memory store):
/// - A relationship's order is not kept across a save (SyncCopiesTests says so too). Today's
///   per-day lookups read the FIRST record of a day, so the same-day duplicate fixtures stay
///   unsaved: only the append order makes today's answer stable at all.
/// - A record deleted in its own context and saved stays in `habit.records`, with no context.
///   The habit's next `append` re-attaches it as a pending insert (a fetch then returns it), and
///   the save after that drops it. So the ghost fixture appends nothing after its deletes.
/// - A record deleted and saved by ANOTHER context still looks live here (context set, not
///   deleted). Reading any of its attributes is a fatal error unless this context read the record
///   since its last save; its `persistentModelID`, `modelContext` and `isDeleted` are always
///   safe. So the second-context fixture reads its records first, as the app's list has.
@MainActor
final class HabitStatsParityTests: XCTestCase {

    private static var printedZone = false

    override func setUp() {
        super.setUp()
        guard !Self.printedZone else { return }
        Self.printedZone = true
        print("PARITY zone: TimeZone.current=\(TimeZone.current.identifier), Calendar.current=\(Calendar.current.timeZone.identifier), TZ=\(ProcessInfo.processInfo.environment["TZ"] ?? "unset")")
    }

    // MARK: - D2's named fixes, and the one switch commit 2 flips

    /// RELEASE-1.4.1.md D2, "Deliberate fixes": the only reasons a value below may change.
    enum NamedFix: String {
        /// Aggregates count only the records the store holds (`HabitStats.liveRecordIDs`); the
        /// per-day lookups skip a same-context ghost (`modelContext != nil && !isDeleted`).
        case ghosts
        /// `completionsPerWeekday` counts completed days, not every record (Habit.swift:394-401).
        case perWeekdayCountsDays
        /// The rate starts at min(creation day, earliest live record) (D8), not at creation.
        case rateStart
        /// Records dated after today are ignored by the aggregates.
        case afterToday
        /// A day with several live records counts as its largest value, then its newest stamp
        /// (2026-10-15 decision 7), for completion, `loggedValue` and `record(on:)` alike.
        case dayMax
    }

    /// A value captured from today's code and, only where a named fix changes it, the value
    /// commit 2 must produce instead.
    struct Golden<Value: Equatable> {
        let today: Value
        let commit2: Value?
        let fixes: [NamedFix]

        static func same(_ value: Value) -> Golden { Golden(today: value, commit2: nil, fixes: []) }
        static func named(_ fixes: NamedFix..., today: Value, becomes: Value) -> Golden {
            Golden(today: today, commit2: becomes, fixes: fixes)
        }
    }

    /// THE switch. Commit 1 asserted today's values. Commit 2 changed this body to
    /// `golden.commit2 ?? golden.today`, and nothing else in the goldens.
    private func asserted<Value>(_ golden: Golden<Value>) -> Value { golden.commit2 ?? golden.today }

    // MARK: - Golden shapes

    /// One day's answers from `Habit`, for one fixture day.
    struct Day: Equatable {
        let done: Bool        // isCompletedOn(day)
        let value: Double     // loggedValue(on: day)
        let progress: Double  // progress(on: day)
        let record: Int?      // record(on: day), as the fixture's record number; nil for none
        let streak: Int       // currentStreak(from: day)
        let week: Int         // weeklyCompletions(containing: day)
        init(_ done: Bool, _ value: Double, _ progress: Double, _ record: Int?, _ streak: Int, _ week: Int) {
            self.done = done; self.value = value; self.progress = progress
            self.record = record; self.streak = streak; self.week = week
        }
    }

    /// `HabitStats.isCompleted(on:)` and `loggedValue(on:)` for commit 2, kept only where they must
    /// differ from `Habit`'s direct per-day lookups. Unused in commit 1.
    struct StatsDay: Equatable {
        let done: Bool
        let value: Double
        init(_ done: Bool, _ value: Double) { self.done = done; self.value = value }
    }

    /// `isCompletedOn`, `loggedValue(on:)` and `currentStreak(from:)` given an instant.
    struct Answer: Equatable {
        let done: Bool
        let value: Double
        let streak: Int
        init(_ done: Bool, _ value: Double, _ streak: Int) { self.done = done; self.value = value; self.streak = streak }
    }

    struct DayRow {
        let day: Date
        let golden: Golden<Day>
        let stats: StatsDay?
        static func on(_ y: Int, _ m: Int, _ d: Int, _ golden: Golden<Day>, stats: StatsDay? = nil) -> DayRow {
            DayRow(day: HabitStatsParityTests.key(y, m, d), golden: golden, stats: stats)
        }
    }

    struct WeekRow {
        let monday: Date
        let golden: Golden<Int>
        static func monday(_ y: Int, _ m: Int, _ d: Int, _ golden: Golden<Int>) -> WeekRow {
            WeekRow(monday: HabitStatsParityTests.key(y, m, d), golden: golden)
        }
    }

    /// A golden that is the same for every run, or one per weekday of the run's today, or one per
    /// way the run's zone can date the habit's `createdAt`.
    enum ByRun<Value: Equatable> {
        case always(Golden<Value>)
        case byWeekday([Int: Golden<Value>])           // 1 = Sunday … 7 = Saturday
        case byCreationDayOffset([Int: Golden<Value>]) // Self.processDayOffset(createdAt)
    }

    struct RateRow {
        let from: Date
        let to: Date
        let golden: ByRun<Double>
        static func range(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ golden: ByRun<Double>) -> RateRow {
            RateRow(from: HabitStatsParityTests.key(a.0, a.1, a.2), to: HabitStatsParityTests.key(b.0, b.1, b.2), golden: golden)
        }
    }

    struct InstantRow {
        let label: String
        let byOffset: [Int: Golden<Answer>]  // Self.processDayOffset(instant)
        static func instant(_ label: String, _ byOffset: [Int: Golden<Answer>]) -> InstantRow {
            InstantRow(label: label, byOffset: byOffset)
        }
    }

    struct Expect {
        var days: [DayRow]
        var weeks: [WeekRow]
        var best: Golden<Int>
        var rates: [RateRow]
        var perWeekday: Golden<[Int: Int]>
        var thirtyDay: ByRun<Double>
        var instants: [InstantRow]
    }

    // MARK: - The fixtures (builders below, under "Building fixtures")

    /// Daily yes/no: 06-01…06-10, a two-day gap, 06-13…06-17 (today, a Wednesday). No named fix
    /// applies.
    func testDaily() throws {
        try check(daily(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 7))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(true, 1, 1, 2, 2, 7))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 3, 3, 7))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(true, 1, 1, 4, 4, 7))),  // Thu 06-04
                .on(2026, 6, 5, .same(Day(true, 1, 1, 5, 5, 7))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(true, 1, 1, 6, 6, 7))),  // Sat 06-06
                .on(2026, 6, 7, .same(Day(true, 1, 1, 7, 7, 7))),  // Sun 06-07
                .on(2026, 6, 8, .same(Day(true, 1, 1, 8, 8, 5))),  // Mon 06-08
                .on(2026, 6, 9, .same(Day(true, 1, 1, 9, 9, 5))),  // Tue 06-09
                .on(2026, 6, 10, .same(Day(true, 1, 1, 10, 10, 5))),  // Wed 06-10
                .on(2026, 6, 11, .same(Day(false, 0, 0, nil, 10, 5))),  // Thu 06-11
                .on(2026, 6, 12, .same(Day(false, 0, 0, nil, 0, 5))),  // Fri 06-12
                .on(2026, 6, 13, .same(Day(true, 1, 1, 11, 1, 5))),  // Sat 06-13
                .on(2026, 6, 14, .same(Day(true, 1, 1, 12, 2, 5))),  // Sun 06-14
                .on(2026, 6, 15, .same(Day(true, 1, 1, 13, 3, 3))),  // Mon 06-15
                .on(2026, 6, 16, .same(Day(true, 1, 1, 14, 4, 3))),  // Tue 06-16
                .on(2026, 6, 17, .same(Day(true, 1, 1, 15, 5, 3))),  // Wed 06-17
                .on(2026, 6, 18, .same(Day(false, 0, 0, nil, 5, 3))),  // Thu 06-18
            ],
            weeks: [
                .monday(2026, 6, 1, .same(7)),  // weeklyCompletions(weekStarting: Mon 06-01)
                .monday(2026, 6, 8, .same(5)),  // weeklyCompletions(weekStarting: Mon 06-08)
                .monday(2026, 6, 15, .same(3)),  // weeklyCompletions(weekStarting: Mon 06-15)
            ],
            best: .same(10),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Wed 06-17, now: today)
                .range((2026, 6, 1), (2026, 6, 17), .always(.same(15.0 / 17.0))),
                // completionRate(from: Mon 05-25, to: Tue 06-30, now: today)
                .range((2026, 5, 25), (2026, 6, 30), .always(.same(15.0 / 17.0))),
                // completionRate(from: Thu 06-11, to: Fri 06-12, now: today)
                .range((2026, 6, 11), (2026, 6, 12), .always(.same(0))),
                // completionRate(from: Sat 06-13, to: Wed 06-17, now: today)
                .range((2026, 6, 13), (2026, 6, 17), .always(.same(1))),
            ],
            // completionsPerWeekday(): Sun 2, Mon 3, Tue 3, Wed 3, Thu 1, Fri 1, Sat 2
            perWeekday: .same([1: 2, 2: 3, 3: 3, 4: 3, 5: 1, 6: 1, 7: 2]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            thirtyDay: .always(.same(15.0 / 17.0)),
            instants: []))
    }

    /// Mon/Wed/Fri. A check-in on a rest day (Tue 06-09), Wed 06-17 missed, today Tue 06-23 (a rest
    /// day). Rest days neither count nor break a run; the rest-day check-in still counts per
    /// weekday. No named fix applies.
    func testSpecificDays() throws {
        try check(specificDays(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 3))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(false, 0, 0, nil, 1, 3))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 2, 2, 3))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(false, 0, 0, nil, 2, 3))),  // Thu 06-04
                .on(2026, 6, 5, .same(Day(true, 1, 1, 3, 3, 3))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(false, 0, 0, nil, 3, 3))),  // Sat 06-06
                .on(2026, 6, 7, .same(Day(false, 0, 0, nil, 3, 3))),  // Sun 06-07
                .on(2026, 6, 8, .same(Day(true, 1, 1, 4, 4, 4))),  // Mon 06-08
                .on(2026, 6, 9, .same(Day(true, 1, 1, 5, 4, 4))),  // Tue 06-09
                .on(2026, 6, 10, .same(Day(true, 1, 1, 6, 5, 4))),  // Wed 06-10
                .on(2026, 6, 11, .same(Day(false, 0, 0, nil, 5, 4))),  // Thu 06-11
                .on(2026, 6, 12, .same(Day(true, 1, 1, 7, 6, 4))),  // Fri 06-12
                .on(2026, 6, 13, .same(Day(false, 0, 0, nil, 6, 4))),  // Sat 06-13
                .on(2026, 6, 14, .same(Day(false, 0, 0, nil, 6, 4))),  // Sun 06-14
                .on(2026, 6, 15, .same(Day(true, 1, 1, 8, 7, 2))),  // Mon 06-15
                .on(2026, 6, 16, .same(Day(false, 0, 0, nil, 7, 2))),  // Tue 06-16
                .on(2026, 6, 17, .same(Day(false, 0, 0, nil, 7, 2))),  // Wed 06-17
                .on(2026, 6, 18, .same(Day(false, 0, 0, nil, 0, 2))),  // Thu 06-18
                .on(2026, 6, 19, .same(Day(true, 1, 1, 9, 1, 2))),  // Fri 06-19
                .on(2026, 6, 20, .same(Day(false, 0, 0, nil, 1, 2))),  // Sat 06-20
                .on(2026, 6, 21, .same(Day(false, 0, 0, nil, 1, 2))),  // Sun 06-21
                .on(2026, 6, 22, .same(Day(true, 1, 1, 10, 2, 1))),  // Mon 06-22
                .on(2026, 6, 23, .same(Day(false, 0, 0, nil, 2, 1))),  // Tue 06-23
                .on(2026, 6, 24, .same(Day(false, 0, 0, nil, 2, 1))),  // Wed 06-24
            ],
            weeks: [
                .monday(2026, 6, 1, .same(3)),  // weeklyCompletions(weekStarting: Mon 06-01)
                .monday(2026, 6, 8, .same(4)),  // weeklyCompletions(weekStarting: Mon 06-08)
                .monday(2026, 6, 15, .same(2)),  // weeklyCompletions(weekStarting: Mon 06-15)
                .monday(2026, 6, 22, .same(1)),  // weeklyCompletions(weekStarting: Mon 06-22)
            ],
            best: .same(7),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Tue 06-23, now: today)
                .range((2026, 6, 1), (2026, 6, 23), .always(.same(9.0 / 10.0))),
                // completionRate(from: Sat 06-06, to: Sun 06-07, now: today)
                .range((2026, 6, 6), (2026, 6, 7), .always(.same(0))),
                // completionRate(from: Mon 06-15, to: Sun 06-21, now: today)
                .range((2026, 6, 15), (2026, 6, 21), .always(.same(2.0 / 3.0))),
                // completionRate(from: Mon 06-08, to: Sun 06-14, now: today)
                .range((2026, 6, 8), (2026, 6, 14), .always(.same(1))),
            ],
            // completionsPerWeekday(): Mon 4, Tue 1, Wed 2, Fri 3
            perWeekday: .same([2: 4, 3: 1, 4: 2, 6: 3]),
            // completionRate(days: 30), the fixture moved to end on the run's today, by the weekday of the run's today: the schedule is bound to weekdays
            thirtyDay: .byWeekday([
                1: .same(5.0 / 9.0),  // Sun
                2: .same(1.0 / 10.0),  // Mon
                3: .same(9.0 / 10.0),  // Tue
                4: .same(1.0 / 10.0),  // Wed
                5: .same(3.0 / 5.0),  // Thu
                6: .same(2.0 / 5.0),  // Fri
                7: .same(2.0 / 5.0),  // Sat
            ]),
            instants: []))
    }

    /// Three times a week. The weeks of 06-01, 06-08, 06-15, 06-22 and 06-29 have 3, 4, 1, 3 and 1
    /// check-ins; today is Wed 07-01, inside the unfinished week. Monday-anchored weeks and the
    /// in-progress week's grace. No named fix applies.
    func testThreeTimesAWeek() throws {
        try check(timesPerWeek(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 3))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(false, 0, 0, nil, 1, 3))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 2, 1, 3))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(false, 0, 0, nil, 1, 3))),  // Thu 06-04
                .on(2026, 6, 5, .same(Day(true, 1, 1, 3, 1, 3))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(false, 0, 0, nil, 1, 3))),  // Sat 06-06
                .on(2026, 6, 7, .same(Day(false, 0, 0, nil, 1, 3))),  // Sun 06-07
                .on(2026, 6, 8, .same(Day(false, 0, 0, nil, 2, 4))),  // Mon 06-08
                .on(2026, 6, 9, .same(Day(true, 1, 1, 4, 2, 4))),  // Tue 06-09
                .on(2026, 6, 10, .same(Day(false, 0, 0, nil, 2, 4))),  // Wed 06-10
                .on(2026, 6, 11, .same(Day(true, 1, 1, 5, 2, 4))),  // Thu 06-11
                .on(2026, 6, 12, .same(Day(false, 0, 0, nil, 2, 4))),  // Fri 06-12
                .on(2026, 6, 13, .same(Day(true, 1, 1, 6, 2, 4))),  // Sat 06-13
                .on(2026, 6, 14, .same(Day(true, 1, 1, 7, 2, 4))),  // Sun 06-14
                .on(2026, 6, 15, .same(Day(true, 1, 1, 8, 2, 1))),  // Mon 06-15
                .on(2026, 6, 16, .same(Day(false, 0, 0, nil, 2, 1))),  // Tue 06-16
                .on(2026, 6, 17, .same(Day(false, 0, 0, nil, 2, 1))),  // Wed 06-17
                .on(2026, 6, 18, .same(Day(false, 0, 0, nil, 2, 1))),  // Thu 06-18
                .on(2026, 6, 19, .same(Day(false, 0, 0, nil, 2, 1))),  // Fri 06-19
                .on(2026, 6, 20, .same(Day(false, 0, 0, nil, 2, 1))),  // Sat 06-20
                .on(2026, 6, 21, .same(Day(false, 0, 0, nil, 2, 1))),  // Sun 06-21
                .on(2026, 6, 22, .same(Day(true, 1, 1, 9, 1, 3))),  // Mon 06-22
                .on(2026, 6, 23, .same(Day(true, 1, 1, 10, 1, 3))),  // Tue 06-23
                .on(2026, 6, 24, .same(Day(true, 1, 1, 11, 1, 3))),  // Wed 06-24
                .on(2026, 6, 25, .same(Day(false, 0, 0, nil, 1, 3))),  // Thu 06-25
                .on(2026, 6, 26, .same(Day(false, 0, 0, nil, 1, 3))),  // Fri 06-26
                .on(2026, 6, 27, .same(Day(false, 0, 0, nil, 1, 3))),  // Sat 06-27
                .on(2026, 6, 28, .same(Day(false, 0, 0, nil, 1, 3))),  // Sun 06-28
                .on(2026, 6, 29, .same(Day(false, 0, 0, nil, 1, 1))),  // Mon 06-29
                .on(2026, 6, 30, .same(Day(true, 1, 1, 12, 1, 1))),  // Tue 06-30
                .on(2026, 7, 1, .same(Day(false, 0, 0, nil, 1, 1))),  // Wed 07-01
                .on(2026, 7, 2, .same(Day(false, 0, 0, nil, 1, 1))),  // Thu 07-02
            ],
            weeks: [
                .monday(2026, 6, 1, .same(3)),  // weeklyCompletions(weekStarting: Mon 06-01)
                .monday(2026, 6, 8, .same(4)),  // weeklyCompletions(weekStarting: Mon 06-08)
                .monday(2026, 6, 15, .same(1)),  // weeklyCompletions(weekStarting: Mon 06-15)
                .monday(2026, 6, 22, .same(3)),  // weeklyCompletions(weekStarting: Mon 06-22)
                .monday(2026, 6, 29, .same(1)),  // weeklyCompletions(weekStarting: Mon 06-29)
            ],
            best: .same(2),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Wed 07-01, now: today)
                .range((2026, 6, 1), (2026, 7, 1), .always(.same(0.8279569892473118))),
                // completionRate(from: Sat 06-06, to: Tue 06-30, now: today)
                .range((2026, 6, 6), (2026, 6, 30), .always(.same(61.0 / 75.0))),
                // completionRate(from: Mon 06-15, to: Sun 06-21, now: today)
                .range((2026, 6, 15), (2026, 6, 21), .always(.same(1.0 / 3.0))),
                // completionRate(from: Mon 06-29, to: Sun 07-05, now: today)
                .range((2026, 6, 29), (2026, 7, 5), .always(.same(0.7777777777777777))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 3, Tue 3, Wed 2, Thu 1, Fri 1, Sat 1
            perWeekday: .same([1: 1, 2: 3, 3: 3, 4: 2, 5: 1, 6: 1, 7: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today, by the weekday of the run's today: the schedule is bound to weekdays
            thirtyDay: .byWeekday([
                1: .same(23.0 / 30.0),  // Sun
                2: .same(73.0 / 90.0),  // Mon
                3: .same(31.0 / 45.0),  // Tue
                4: .same(37.0 / 45.0),  // Wed
                5: .same(13.0 / 15.0),  // Thu
                6: .same(5.0 / 6.0),  // Fri
                7: .same(79.0 / 90.0),  // Sat
            ]),
            instants: []))
    }

    /// Count, target 8: 8, 3, 10, 7, 8, none, 8, 1 on 06-01…06-08 (today). Named:
    /// completionsPerWeekday counts completed days.
    func testCountPartials() throws {
        try check(countPartials(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 8, 1, 1, 1, 4))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(false, 3, 0.375, 2, 1, 4))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 10, 1, 3, 1, 4))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(false, 7, 0.875, 4, 1, 4))),  // Thu 06-04
                .on(2026, 6, 5, .same(Day(true, 8, 1, 5, 1, 4))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(false, 0, 0, nil, 1, 4))),  // Sat 06-06
                .on(2026, 6, 7, .same(Day(true, 8, 1, 6, 1, 4))),  // Sun 06-07
                .on(2026, 6, 8, .same(Day(false, 1, 0.125, 7, 1, 0))),  // Mon 06-08
                .on(2026, 6, 9, .same(Day(false, 0, 0, nil, 0, 0))),  // Tue 06-09
            ],
            weeks: [
                .monday(2026, 6, 1, .same(4)),  // weeklyCompletions(weekStarting: Mon 06-01)
                .monday(2026, 6, 8, .same(0)),  // weeklyCompletions(weekStarting: Mon 06-08)
            ],
            best: .same(1),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Mon 06-08, now: today)
                .range((2026, 6, 1), (2026, 6, 8), .always(.same(1.0 / 2.0))),
                // completionRate(from: Tue 06-02, to: Thu 06-04, now: today)
                .range((2026, 6, 2), (2026, 6, 4), .always(.same(1.0 / 3.0))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 2, Tue 1, Wed 1, Thu 1, Fri 1
            // NAMED FIX (D2: completionsPerWeekday counts completed days): becomes [1: 1, 2: 1, 4: 1, 6: 1] in commit 2
            perWeekday: .named(.perWeekdayCountsDays, today: [1: 1, 2: 2, 3: 1, 4: 1, 5: 1, 6: 1], becomes: [1: 1, 2: 1, 4: 1, 6: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            thirtyDay: .always(.same(1.0 / 2.0)),
            instants: []))
    }

    /// Created Wed 06-10, with check-ins on 06-01…06-05 (before creation) and 06-08…06-14 (today).
    /// Named: the rate's start (D8).
    func testBackdated() throws {
        try check(backdated(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 5, 31, .same(Day(false, 0, 0, nil, 0, 0))),  // Sun 05-31
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 5))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(true, 1, 1, 2, 2, 5))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 3, 3, 5))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(true, 1, 1, 4, 4, 5))),  // Thu 06-04
                .on(2026, 6, 5, .same(Day(true, 1, 1, 5, 5, 5))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(false, 0, 0, nil, 5, 5))),  // Sat 06-06
                .on(2026, 6, 7, .same(Day(false, 0, 0, nil, 0, 5))),  // Sun 06-07
                .on(2026, 6, 8, .same(Day(true, 1, 1, 6, 1, 7))),  // Mon 06-08
                .on(2026, 6, 9, .same(Day(true, 1, 1, 7, 2, 7))),  // Tue 06-09
                .on(2026, 6, 10, .same(Day(true, 1, 1, 8, 3, 7))),  // Wed 06-10
                .on(2026, 6, 11, .same(Day(true, 1, 1, 9, 4, 7))),  // Thu 06-11
                .on(2026, 6, 12, .same(Day(true, 1, 1, 10, 5, 7))),  // Fri 06-12
                .on(2026, 6, 13, .same(Day(true, 1, 1, 11, 6, 7))),  // Sat 06-13
                .on(2026, 6, 14, .same(Day(true, 1, 1, 12, 7, 7))),  // Sun 06-14
                .on(2026, 6, 15, .same(Day(false, 0, 0, nil, 7, 0))),  // Mon 06-15
            ],
            weeks: [
                .monday(2026, 5, 25, .same(0)),  // weeklyCompletions(weekStarting: Mon 05-25)
                .monday(2026, 6, 1, .same(5)),  // weeklyCompletions(weekStarting: Mon 06-01)
                .monday(2026, 6, 8, .same(7)),  // weeklyCompletions(weekStarting: Mon 06-08)
            ],
            best: .same(7),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Sun 06-14, now: today)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 6.0 / 7.0 in commit 2
                .range((2026, 6, 1), (2026, 6, 14), .always(.named(.rateStart, today: 1, becomes: 6.0 / 7.0))),
                // completionRate(from: Mon 06-08, to: Sun 06-14, now: today)
                .range((2026, 6, 8), (2026, 6, 14), .always(.same(1))),
                // completionRate(from: Fri 05-01, to: Tue 06-30, now: today)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 6.0 / 7.0 in commit 2
                .range((2026, 5, 1), (2026, 6, 30), .always(.named(.rateStart, today: 1, becomes: 6.0 / 7.0))),
                // completionRate(from: Mon 06-01, to: Tue 06-09, now: today)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 7.0 / 9.0 in commit 2
                .range((2026, 6, 1), (2026, 6, 9), .always(.named(.rateStart, today: 0, becomes: 7.0 / 9.0))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 2, Tue 2, Wed 2, Thu 2, Fri 2, Sat 1
            perWeekday: .same([1: 1, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2, 7: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 6.0 / 7.0 in commit 2
            thirtyDay: .always(.named(.rateStart, today: 1, becomes: 6.0 / 7.0)),
            instants: []))
    }

    /// Daily, 05-31 (the day before creation) to 06-05 (today). The records of 05-31, 06-03 and
    /// 06-05 were deleted in the habit's own context and saved, so they stay in `habit.records`
    /// as ghosts. Named: ghosts excluded, by every aggregate and by the per-day lookups.
    func testGhosts() throws {
        try check(ghost(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                // NAMED FIX (D2: ghosts excluded): becomes Day(false, 0, 0, nil, 0, 0) in commit 2
                .on(2026, 5, 30, .named(.ghosts, today: Day(false, 0, 0, nil, 0, 1), becomes: Day(false, 0, 0, nil, 0, 0))),  // Sat 05-30
                // NAMED FIX (D2: ghosts excluded): becomes Day(false, 0, 0, nil, 0, 0) in commit 2
                .on(2026, 5, 31, .named(.ghosts, today: Day(true, 1, 1, 1, 1, 1), becomes: Day(false, 0, 0, nil, 0, 0))),  // Sun 05-31
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 2, 1, 3) in commit 2
                .on(2026, 6, 1, .named(.ghosts, today: Day(true, 1, 1, 2, 2, 5), becomes: Day(true, 1, 1, 2, 1, 3))),  // Mon 06-01
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 3, 2, 3) in commit 2
                .on(2026, 6, 2, .named(.ghosts, today: Day(true, 1, 1, 3, 3, 5), becomes: Day(true, 1, 1, 3, 2, 3))),  // Tue 06-02
                // NAMED FIX (D2: ghosts excluded): becomes Day(false, 0, 0, nil, 2, 3) in commit 2
                .on(2026, 6, 3, .named(.ghosts, today: Day(true, 1, 1, 4, 4, 5), becomes: Day(false, 0, 0, nil, 2, 3))),  // Wed 06-03
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 5, 1, 3) in commit 2
                .on(2026, 6, 4, .named(.ghosts, today: Day(true, 1, 1, 5, 5, 5), becomes: Day(true, 1, 1, 5, 1, 3))),  // Thu 06-04
                // NAMED FIX (D2: ghosts excluded): becomes Day(false, 0, 0, nil, 1, 3) in commit 2
                .on(2026, 6, 5, .named(.ghosts, today: Day(true, 1, 1, 6, 6, 5), becomes: Day(false, 0, 0, nil, 1, 3))),  // Fri 06-05
                // NAMED FIX (D2: ghosts excluded): becomes Day(false, 0, 0, nil, 0, 3) in commit 2
                .on(2026, 6, 6, .named(.ghosts, today: Day(false, 0, 0, nil, 6, 5), becomes: Day(false, 0, 0, nil, 0, 3))),  // Sat 06-06
            ],
            weeks: [
                // NAMED FIX (D2: ghosts excluded): becomes 0 in commit 2
                .monday(2026, 5, 25, .named(.ghosts, today: 1, becomes: 0)),  // weeklyCompletions(weekStarting: Mon 05-25)
                // NAMED FIX (D2: ghosts excluded): becomes 3 in commit 2
                .monday(2026, 6, 1, .named(.ghosts, today: 5, becomes: 3)),  // weeklyCompletions(weekStarting: Mon 06-01)
            ],
            // NAMED FIX (D2: ghosts excluded): becomes 2 in commit 2
            best: .named(.ghosts, today: 6, becomes: 2),  // bestStreak()
            rates: [
                // completionRate(from: Mon 05-25, to: Fri 06-05, now: today)
                // NAMED FIX (D2: ghosts excluded): becomes 3.0 / 5.0 in commit 2
                .range((2026, 5, 25), (2026, 6, 5), .always(.named(.ghosts, today: 1, becomes: 3.0 / 5.0))),
                // completionRate(from: Wed 06-03, to: Wed 06-03, now: today)
                // NAMED FIX (D2: ghosts excluded): becomes 0 in commit 2
                .range((2026, 6, 3), (2026, 6, 3), .always(.named(.ghosts, today: 1, becomes: 0))),
                // completionRate(from: Mon 06-01, to: Fri 06-05, now: today)
                // NAMED FIX (D2: ghosts excluded): becomes 3.0 / 5.0 in commit 2
                .range((2026, 6, 1), (2026, 6, 5), .always(.named(.ghosts, today: 1, becomes: 3.0 / 5.0))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 1, Tue 1, Wed 1, Thu 1, Fri 1
            // NAMED FIX (D2: ghosts excluded): becomes [2: 1, 3: 1, 5: 1] in commit 2
            perWeekday: .named(.ghosts, today: [1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1], becomes: [2: 1, 3: 1, 5: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            // NAMED FIX (D2: ghosts excluded): becomes 3.0 / 5.0 in commit 2
            thirtyDay: .always(.named(.ghosts, today: 1, becomes: 3.0 / 5.0)),
            instants: []))
    }

    /// Check-ins dated by an America/Los_Angeles calendar from instants near midnight, across the
    /// spring-forward of Sunday 2026-03-08: 03-04…03-11, then 03-13 and 03-14 (today). Two Los
    /// Angeles instants are also passed as the day itself. No named fix applies.
    func testDSTSpringForward() throws {
        try check(dst(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 3, 3, .same(Day(false, 0, 0, nil, 0, 5))),  // Tue 03-03
                .on(2026, 3, 4, .same(Day(true, 1, 1, 1, 1, 5))),  // Wed 03-04
                .on(2026, 3, 5, .same(Day(true, 1, 1, 2, 2, 5))),  // Thu 03-05
                .on(2026, 3, 6, .same(Day(true, 1, 1, 3, 3, 5))),  // Fri 03-06
                .on(2026, 3, 7, .same(Day(true, 1, 1, 4, 4, 5))),  // Sat 03-07
                .on(2026, 3, 8, .same(Day(true, 1, 1, 5, 5, 5))),  // Sun 03-08
                .on(2026, 3, 9, .same(Day(true, 1, 1, 6, 6, 5))),  // Mon 03-09
                .on(2026, 3, 10, .same(Day(true, 1, 1, 7, 7, 5))),  // Tue 03-10
                .on(2026, 3, 11, .same(Day(true, 1, 1, 8, 8, 5))),  // Wed 03-11
                .on(2026, 3, 12, .same(Day(false, 0, 0, nil, 8, 5))),  // Thu 03-12
                .on(2026, 3, 13, .same(Day(true, 1, 1, 9, 1, 5))),  // Fri 03-13
                .on(2026, 3, 14, .same(Day(true, 1, 1, 10, 2, 5))),  // Sat 03-14
                .on(2026, 3, 15, .same(Day(false, 0, 0, nil, 2, 5))),  // Sun 03-15
            ],
            weeks: [
                .monday(2026, 3, 2, .same(5)),  // weeklyCompletions(weekStarting: Mon 03-02)
                .monday(2026, 3, 9, .same(5)),  // weeklyCompletions(weekStarting: Mon 03-09)
            ],
            best: .same(8),  // bestStreak()
            rates: [
                // completionRate(from: Sun 03-01, to: Sat 03-14, now: today)
                .range((2026, 3, 1), (2026, 3, 14), .always(.same(5.0 / 7.0))),
                // completionRate(from: Sat 03-07, to: Mon 03-09, now: today)
                .range((2026, 3, 7), (2026, 3, 9), .always(.same(1))),
                // completionRate(from: Sun 03-08, to: Sun 03-08, now: today)
                .range((2026, 3, 8), (2026, 3, 8), .always(.same(1))),
                // completionRate(from: Thu 03-12, to: Tue 03-31, now: today)
                .range((2026, 3, 12), (2026, 3, 31), .always(.same(2.0 / 3.0))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 1, Tue 1, Wed 2, Thu 1, Fri 2, Sat 2
            perWeekday: .same([1: 1, 2: 1, 3: 1, 4: 2, 5: 1, 6: 2, 7: 2]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            thirtyDay: .always(.same(5.0 / 7.0)),
            instants: [
                // isCompletedOn, loggedValue, currentStreak(from:) given the instant itself, which today's
                // code dates with the run's zone
                .instant("2026-03-07 22:30 PST", [
                    -1: .same(Answer(true, 1, 4)),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    0: .same(Answer(true, 1, 5)),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ]),
                .instant("2026-03-12 23:30 PDT", [
                    -1: .same(Answer(false, 0, 8)),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    0: .same(Answer(true, 1, 1)),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ]),
            ]))
    }

    /// Check-ins at 21:30 in a fixed UTC−9 zone (06:30 the next day in UTC), dated by that zone's
    /// calendar: 06-01…06-04, 06-06, 06-07 (today). createdAt is 21:00 on 06-01 there, which Los
    /// Angeles dates 06-01 and UTC or Tokyo 06-02. Named: the rate's start, where the run's zone
    /// dates createdAt after the first check-in.
    func testUTCMinus9() throws {
        try check(utcMinus9(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 5, 31, .same(Day(false, 0, 0, nil, 0, 0))),  // Sun 05-31
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 6))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(true, 1, 1, 2, 2, 6))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 3, 3, 6))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(true, 1, 1, 4, 4, 6))),  // Thu 06-04
                .on(2026, 6, 5, .same(Day(false, 0, 0, nil, 4, 6))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(true, 1, 1, 5, 1, 6))),  // Sat 06-06
                .on(2026, 6, 7, .same(Day(true, 1, 1, 6, 2, 6))),  // Sun 06-07
                .on(2026, 6, 8, .same(Day(false, 0, 0, nil, 2, 0))),  // Mon 06-08
            ],
            weeks: [
                .monday(2026, 5, 25, .same(0)),  // weeklyCompletions(weekStarting: Mon 05-25)
                .monday(2026, 6, 1, .same(6)),  // weeklyCompletions(weekStarting: Mon 06-01)
            ],
            best: .same(4),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Sun 06-07, now: today): depends on the day the run's zone gives createdAt
                .range((2026, 6, 1), (2026, 6, 7), .byCreationDayOffset([
                    -1: .same(6.0 / 7.0),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 6.0 / 7.0 in commit 2
                    0: .named(.rateStart, today: 5.0 / 6.0, becomes: 6.0 / 7.0),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ])),
                // completionRate(from: Mon 05-25, to: Sun 06-07, now: today): depends on the day the run's zone gives createdAt
                .range((2026, 5, 25), (2026, 6, 7), .byCreationDayOffset([
                    -1: .same(6.0 / 7.0),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 6.0 / 7.0 in commit 2
                    0: .named(.rateStart, today: 5.0 / 6.0, becomes: 6.0 / 7.0),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ])),
                // completionRate(from: Tue 06-02, to: Sun 06-07, now: today)
                .range((2026, 6, 2), (2026, 6, 7), .always(.same(5.0 / 6.0))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 1, Tue 1, Wed 1, Thu 1, Sat 1
            perWeekday: .same([1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 7: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today: depends on the day the run's zone gives createdAt (every weekday alike)
            thirtyDay: .byCreationDayOffset([
                -1: .same(6.0 / 7.0),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 6.0 / 7.0 in commit 2
                0: .named(.rateStart, today: 5.0 / 6.0, becomes: 6.0 / 7.0),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
            ]),
            instants: [
                // isCompletedOn, loggedValue, currentStreak(from:) given the instant itself, which today's
                // code dates with the run's zone
                .instant("2026-06-05 21:30 UTC−9", [
                    -1: .same(Answer(false, 0, 4)),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    0: .same(Answer(true, 1, 1)),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ]),
                .instant("2026-06-07 21:30 UTC−9", [
                    -1: .same(Answer(true, 1, 2)),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    0: .same(Answer(false, 0, 2)),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ]),
            ]))
    }

    /// Count, target 5, same-day duplicates (unsaved, so in append order): 06-02 has 3 then 8;
    /// 06-03 has 8 then 3; 06-04 has 6 and a newer 6; 06-05 has 2 then 4. Today 06-05. Named: a
    /// day counts as its largest value, then its newest stamp; completionsPerWeekday counts days.
    func testDuplicateCounts() throws {
        try check(duplicateCounts(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 5, 1, 1, 1, 4))),  // Mon 06-01
                // NAMED FIX (D2: a day's several live records count as its max value): becomes Day(true, 8, 1, 3, 2, 4) in commit 2
                .on(2026, 6, 2, .named(.dayMax, today: Day(false, 3, 0.6, 2, 2, 4), becomes: Day(true, 8, 1, 3, 2, 4))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 8, 1, 4, 3, 4))),  // Wed 06-03
                // NAMED FIX (D2: a day's several live records count as its max value): becomes Day(true, 6, 1, 7, 4, 4) in commit 2
                .on(2026, 6, 4, .named(.dayMax, today: Day(true, 6, 1, 6, 4, 4), becomes: Day(true, 6, 1, 7, 4, 4))),  // Thu 06-04
                // NAMED FIX (D2: a day's several live records count as its max value): becomes Day(false, 4, 0.8, 9, 4, 4) in commit 2
                .on(2026, 6, 5, .named(.dayMax, today: Day(false, 2, 0.4, 8, 4, 4), becomes: Day(false, 4, 0.8, 9, 4, 4))),  // Fri 06-05
                .on(2026, 6, 6, .same(Day(false, 0, 0, nil, 0, 4))),  // Sat 06-06
            ],
            weeks: [
                .monday(2026, 6, 1, .same(4)),  // weeklyCompletions(weekStarting: Mon 06-01)
            ],
            best: .same(4),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Fri 06-05, now: today)
                .range((2026, 6, 1), (2026, 6, 5), .always(.same(4.0 / 5.0))),
            ],
            // completionsPerWeekday(): Mon 1, Tue 2, Wed 2, Thu 2, Fri 2
            // NAMED FIX (D2: completionsPerWeekday counts completed days): becomes [2: 1, 3: 1, 4: 1, 5: 1] in commit 2
            perWeekday: .named(.perWeekdayCountsDays, today: [2: 1, 3: 2, 4: 2, 5: 2, 6: 2], becomes: [2: 1, 3: 1, 4: 1, 5: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            thirtyDay: .always(.same(4.0 / 5.0)),
            instants: []))
    }

    /// Yes/no with two records on 06-02, the second newer (unsaved). Today 06-03. Named: the
    /// newest record of the day; completionsPerWeekday counts days.
    func testDuplicateCheckIns() throws {
        try check(duplicateCheckIns(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 3))),  // Mon 06-01
                // NAMED FIX (D2: a day's several live records count as its max value): becomes Day(true, 1, 1, 3, 2, 3) in commit 2
                .on(2026, 6, 2, .named(.dayMax, today: Day(true, 1, 1, 2, 2, 3), becomes: Day(true, 1, 1, 3, 2, 3))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 4, 3, 3))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(false, 0, 0, nil, 3, 3))),  // Thu 06-04
            ],
            weeks: [
                .monday(2026, 6, 1, .same(3)),  // weeklyCompletions(weekStarting: Mon 06-01)
            ],
            best: .same(3),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Wed 06-03, now: today)
                .range((2026, 6, 1), (2026, 6, 3), .always(.same(1))),
            ],
            // completionsPerWeekday(): Mon 1, Tue 2, Wed 1
            // NAMED FIX (D2: completionsPerWeekday counts completed days): becomes [2: 1, 3: 1, 4: 1] in commit 2
            perWeekday: .named(.perWeekdayCountsDays, today: [2: 1, 3: 2, 4: 1], becomes: [2: 1, 3: 1, 4: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            thirtyDay: .always(.same(1)),
            instants: []))
    }

    /// 06-01…06-03 (today), plus Mon–Fri 2099-01-05…09, after any run's today. Named: records
    /// after today ignored by the best streak, the week counts and the weekday counts. The direct
    /// per-day lookups keep reading them; `HabitStats` does not (`stats:`).
    func testRecordsAfterToday() throws {
        try check(afterToday(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 6, 1, .same(Day(true, 1, 1, 1, 1, 3))),  // Mon 06-01
                .on(2026, 6, 2, .same(Day(true, 1, 1, 2, 2, 3))),  // Tue 06-02
                .on(2026, 6, 3, .same(Day(true, 1, 1, 3, 3, 3))),  // Wed 06-03
                .on(2026, 6, 4, .same(Day(false, 0, 0, nil, 3, 3))),  // Thu 06-04
                .on(2099, 1, 4, .same(Day(false, 0, 0, nil, 0, 0))),  // Sun 2099-01-04
                // NAMED FIX (D2: records after today ignored): becomes Day(true, 1, 1, 4, 0, 0) in commit 2
                // HabitStats' own answer for this day in commit 2: StatsDay(false, 0)
                .on(2099, 1, 5, .named(.afterToday, today: Day(true, 1, 1, 4, 1, 5), becomes: Day(true, 1, 1, 4, 0, 0)), stats: StatsDay(false, 0)),  // Mon 2099-01-05
                // NAMED FIX (D2: records after today ignored): becomes Day(true, 1, 1, 5, 0, 0) in commit 2
                // HabitStats' own answer for this day in commit 2: StatsDay(false, 0)
                .on(2099, 1, 6, .named(.afterToday, today: Day(true, 1, 1, 5, 2, 5), becomes: Day(true, 1, 1, 5, 0, 0)), stats: StatsDay(false, 0)),  // Tue 2099-01-06
                // NAMED FIX (D2: records after today ignored): becomes Day(true, 1, 1, 6, 0, 0) in commit 2
                // HabitStats' own answer for this day in commit 2: StatsDay(false, 0)
                .on(2099, 1, 7, .named(.afterToday, today: Day(true, 1, 1, 6, 3, 5), becomes: Day(true, 1, 1, 6, 0, 0)), stats: StatsDay(false, 0)),  // Wed 2099-01-07
                // NAMED FIX (D2: records after today ignored): becomes Day(true, 1, 1, 7, 0, 0) in commit 2
                // HabitStats' own answer for this day in commit 2: StatsDay(false, 0)
                .on(2099, 1, 8, .named(.afterToday, today: Day(true, 1, 1, 7, 4, 5), becomes: Day(true, 1, 1, 7, 0, 0)), stats: StatsDay(false, 0)),  // Thu 2099-01-08
                // NAMED FIX (D2: records after today ignored): becomes Day(true, 1, 1, 8, 0, 0) in commit 2
                // HabitStats' own answer for this day in commit 2: StatsDay(false, 0)
                .on(2099, 1, 9, .named(.afterToday, today: Day(true, 1, 1, 8, 5, 5), becomes: Day(true, 1, 1, 8, 0, 0)), stats: StatsDay(false, 0)),  // Fri 2099-01-09
                // NAMED FIX (D2: records after today ignored): becomes Day(false, 0, 0, nil, 0, 0) in commit 2
                .on(2099, 1, 10, .named(.afterToday, today: Day(false, 0, 0, nil, 5, 5), becomes: Day(false, 0, 0, nil, 0, 0))),  // Sat 2099-01-10
            ],
            weeks: [
                .monday(2026, 6, 1, .same(3)),  // weeklyCompletions(weekStarting: Mon 06-01)
                // NAMED FIX (D2: records after today ignored): becomes 0 in commit 2
                .monday(2099, 1, 5, .named(.afterToday, today: 5, becomes: 0)),  // weeklyCompletions(weekStarting: Mon 2099-01-05)
            ],
            // NAMED FIX (D2: records after today ignored): becomes 3 in commit 2
            best: .named(.afterToday, today: 5, becomes: 3),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Wed 06-03, now: today)
                .range((2026, 6, 1), (2026, 6, 3), .always(.same(1))),
                // completionRate(from: Mon 06-01, to: Thu 2099-12-31, now: today)
                .range((2026, 6, 1), (2099, 12, 31), .always(.same(1))),
            ],
            // completionsPerWeekday(): Mon 2, Tue 2, Wed 2, Thu 1, Fri 1
            // NAMED FIX (D2: records after today ignored): becomes [2: 1, 3: 1, 4: 1] in commit 2
            perWeekday: .named(.afterToday, today: [2: 2, 3: 2, 4: 2, 5: 1, 6: 1], becomes: [2: 1, 3: 1, 4: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            thirtyDay: .always(.same(1)),
            instants: []))
    }

    /// Created Mon 2025-11-03 (PST). Check-ins dated by a Los Angeles calendar on 10-30 and 10-31
    /// (PDT, before creation), 11-02 at 01:30 (the repeated hour of the fall-back), and
    /// 11-03…11-06 (today); 11-01 missed. Named: the rate's start (D8).
    func testBackdatedAcrossDSTFallBack() throws {
        try check(backdatedAcrossDST(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2025, 10, 29, .same(Day(false, 0, 0, nil, 0, 3))),  // Wed 10-29
                .on(2025, 10, 30, .same(Day(true, 1, 1, 1, 1, 3))),  // Thu 10-30
                .on(2025, 10, 31, .same(Day(true, 1, 1, 2, 2, 3))),  // Fri 10-31
                .on(2025, 11, 1, .same(Day(false, 0, 0, nil, 2, 3))),  // Sat 11-01
                .on(2025, 11, 2, .same(Day(true, 1, 1, 3, 1, 3))),  // Sun 11-02
                .on(2025, 11, 3, .same(Day(true, 1, 1, 4, 2, 4))),  // Mon 11-03
                .on(2025, 11, 4, .same(Day(true, 1, 1, 5, 3, 4))),  // Tue 11-04
                .on(2025, 11, 5, .same(Day(true, 1, 1, 6, 4, 4))),  // Wed 11-05
                .on(2025, 11, 6, .same(Day(true, 1, 1, 7, 5, 4))),  // Thu 11-06
                .on(2025, 11, 7, .same(Day(false, 0, 0, nil, 5, 4))),  // Fri 11-07
            ],
            weeks: [
                .monday(2025, 10, 27, .same(3)),  // weeklyCompletions(weekStarting: Mon 10-27)
                .monday(2025, 11, 3, .same(4)),  // weeklyCompletions(weekStarting: Mon 11-03)
            ],
            best: .same(5),  // bestStreak()
            rates: [
                // completionRate(from: Mon 10-27, to: Thu 11-06, now: today)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 7.0 / 8.0 in commit 2
                .range((2025, 10, 27), (2025, 11, 6), .always(.named(.rateStart, today: 1, becomes: 7.0 / 8.0))),
                // completionRate(from: Sat 11-01, to: Thu 11-06, now: today)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 5.0 / 6.0 in commit 2
                .range((2025, 11, 1), (2025, 11, 6), .always(.named(.rateStart, today: 1, becomes: 5.0 / 6.0))),
                // completionRate(from: Mon 11-03, to: Thu 11-06, now: today)
                .range((2025, 11, 3), (2025, 11, 6), .always(.same(1))),
                // completionRate(from: Thu 10-30, to: Fri 10-31, now: today)
                // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 1 in commit 2
                .range((2025, 10, 30), (2025, 10, 31), .always(.named(.rateStart, today: 0, becomes: 1))),
            ],
            // completionsPerWeekday(): Sun 1, Mon 1, Tue 1, Wed 1, Thu 2, Fri 1
            perWeekday: .same([1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            // NAMED FIX (D2: the rate starts at min(created, earliest live record)): becomes 7.0 / 8.0 in commit 2
            thirtyDay: .always(.named(.rateStart, today: 1, becomes: 7.0 / 8.0)),
            instants: [
                // isCompletedOn, loggedValue, currentStreak(from:) given the instant itself, which today's
                // code dates with the run's zone
                .instant("2025-11-05 23:30 PST", [
                    -1: .same(Answer(true, 1, 4)),  // the run's zone dates it the day before its UTC date (e.g. Los Angeles)
                    0: .same(Answer(true, 1, 5)),  // the run's zone dates it on its UTC date (e.g. UTC, Tokyo)
                ]),
            ]))
    }

    /// 06-01…06-05 (today) saved; a second ModelContext on the same container deletes 06-04 and
    /// saves. Here that record still looks live, so `Habit`'s per-day lookups keep it in commit 2
    /// too; only the store's ids can tell (`stats:`). Named: the aggregates drop it.
    func testDeletionSavedBySecondContext() throws {
        try check(secondContext(shift:), Expect(
            days: [
                //   isCompletedOn, loggedValue, progress, record(on:) as the fixture's number,
                //   currentStreak(from:), weeklyCompletions(containing:)
                .on(2026, 5, 31, .same(Day(false, 0, 0, nil, 0, 0))),  // Sun 05-31
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 1, 1, 4) in commit 2
                .on(2026, 6, 1, .named(.ghosts, today: Day(true, 1, 1, 1, 1, 5), becomes: Day(true, 1, 1, 1, 1, 4))),  // Mon 06-01
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 2, 2, 4) in commit 2
                .on(2026, 6, 2, .named(.ghosts, today: Day(true, 1, 1, 2, 2, 5), becomes: Day(true, 1, 1, 2, 2, 4))),  // Tue 06-02
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 3, 3, 4) in commit 2
                .on(2026, 6, 3, .named(.ghosts, today: Day(true, 1, 1, 3, 3, 5), becomes: Day(true, 1, 1, 3, 3, 4))),  // Wed 06-03
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 4, 3, 4) in commit 2
                // HabitStats' own answer for this day in commit 2: StatsDay(false, 0)
                .on(2026, 6, 4, .named(.ghosts, today: Day(true, 1, 1, 4, 4, 5), becomes: Day(true, 1, 1, 4, 3, 4)), stats: StatsDay(false, 0)),  // Thu 06-04
                // NAMED FIX (D2: ghosts excluded): becomes Day(true, 1, 1, 5, 1, 4) in commit 2
                .on(2026, 6, 5, .named(.ghosts, today: Day(true, 1, 1, 5, 5, 5), becomes: Day(true, 1, 1, 5, 1, 4))),  // Fri 06-05
                // NAMED FIX (D2: ghosts excluded): becomes Day(false, 0, 0, nil, 1, 4) in commit 2
                .on(2026, 6, 6, .named(.ghosts, today: Day(false, 0, 0, nil, 5, 5), becomes: Day(false, 0, 0, nil, 1, 4))),  // Sat 06-06
            ],
            weeks: [
                // NAMED FIX (D2: ghosts excluded): becomes 4 in commit 2
                .monday(2026, 6, 1, .named(.ghosts, today: 5, becomes: 4)),  // weeklyCompletions(weekStarting: Mon 06-01)
            ],
            // NAMED FIX (D2: ghosts excluded): becomes 3 in commit 2
            best: .named(.ghosts, today: 5, becomes: 3),  // bestStreak()
            rates: [
                // completionRate(from: Mon 06-01, to: Fri 06-05, now: today)
                // NAMED FIX (D2: ghosts excluded): becomes 4.0 / 5.0 in commit 2
                .range((2026, 6, 1), (2026, 6, 5), .always(.named(.ghosts, today: 1, becomes: 4.0 / 5.0))),
                // completionRate(from: Thu 06-04, to: Thu 06-04, now: today)
                // NAMED FIX (D2: ghosts excluded): becomes 0 in commit 2
                .range((2026, 6, 4), (2026, 6, 4), .always(.named(.ghosts, today: 1, becomes: 0))),
            ],
            // completionsPerWeekday(): Mon 1, Tue 1, Wed 1, Thu 1, Fri 1
            // NAMED FIX (D2: ghosts excluded): becomes [2: 1, 3: 1, 4: 1, 6: 1] in commit 2
            perWeekday: .named(.ghosts, today: [2: 1, 3: 1, 4: 1, 5: 1, 6: 1], becomes: [2: 1, 3: 1, 4: 1, 6: 1]),
            // completionRate(days: 30), the fixture moved to end on the run's today; the same on every weekday and in every zone
            // NAMED FIX (D2: ghosts excluded): becomes 4.0 / 5.0 in commit 2
            thirtyDay: .always(.named(.ghosts, today: 1, becomes: 4.0 / 5.0)),
            instants: []))
    }

    /// The realistic "after today" case: the demo top-up dates by UTC, which is tomorrow for a US
    /// reviewer (D13 item 5). Yes/no check-ins on the run's today −2…+1, so the weekday-bound
    /// answer is summed rather than keyed.
    func testARecordForTheRunsTomorrow() throws {
        for _ in 0..<2 {
            let today = Self.processToday()
            let f = try build("tomorrow", created: Self.add(-2, today).addingTimeInterval(11 * 3600), today: today, shift: 0)
            for k in -2...1 { add(f, k + 3, Self.add(k, today)) }
            try f.context.save()
            let h = f.habit
            let best = h.bestStreak()
            let streak = h.currentStreak(from: today)
            let rate = h.completionRate(days: 30)
            let perWeekday = h.completionsPerWeekday().values.reduce(0, +)
            let tomorrow = h.isCompletedOn(Self.add(1, today))
            let stats = HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: f.context),
                                   calendar: .current, today: today)
            let statsTomorrow = StatsDay(stats.isCompleted(on: Self.add(1, today)), stats.loggedValue(on: Self.add(1, today)))
            let ranges = stats.bestStreakRanges
            guard Self.processToday() == today else { continue }   // midnight passed: run it again
            // NAMED FIX (D2: records after today ignored): becomes 3 in commit 2
            XCTAssertEqual(best, asserted(Golden<Int>.named(.afterToday, today: 4, becomes: 3)), "bestStreak()")
            XCTAssertEqual(streak, asserted(Golden<Int>.same(3)), "currentStreak(from: today)")
            XCTAssertEqual(rate, asserted(Golden<Double>.same(1)), accuracy: 1e-9, "completionRate(days: 30)")
            // NAMED FIX (D2: records after today ignored): becomes 3 in commit 2
            XCTAssertEqual(perWeekday, asserted(Golden<Int>.named(.afterToday, today: 4, becomes: 3)),
                           "completionsPerWeekday(), summed over the weekdays")
            // HabitStats' own answer for tomorrow in commit 2: StatsDay(false, 0)
            XCTAssertEqual(tomorrow, asserted(Golden<Bool>.same(true)), "isCompletedOn(tomorrow), a direct lookup")
            XCTAssertEqual(statsTomorrow, StatsDay(false, 0), "HabitStats' answer for tomorrow: ignored")
            XCTAssertEqual(ranges.first?.length ?? 0, best, "bestStreakRanges.first?.length == bestStreak()")
            print("PARITY tomorrow: 7 golden values checked (zone \(TimeZone.current.identifier))")
            return
        }
        XCTFail("the day changed twice during the test")
    }

    // MARK: - Checking

    private static let dayFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private func ymd(_ d: Date) -> String { Self.dayFormatter.string(from: d) }

    /// Builds the fixture, checks every golden of `e` on it, then `completionRate(days: 30)` on a
    /// copy moved to end on the run's today.
    private func check(_ make: (Int) throws -> Built, _ e: Expect,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try make(0)
        let h = f.habit
        var checked = 0
        // `HabitStats` itself, from the store's live ids, as of the fixture's today.
        let stats = HabitStats(habit: h, liveRecordIDs: HabitStats.liveRecordIDs(of: [h], in: f.context),
                               calendar: .current, today: f.today)

        XCTAssertEqual(e.days.map(\.day), f.rangeDays, "\(f.name): one row per fixture day", file: file, line: line)
        for row in e.days {
            let want = asserted(row.golden), d = row.day, at = "\(f.name) \(ymd(d))"
            XCTAssertEqual(h.isCompletedOn(d), want.done, "\(at) isCompletedOn", file: file, line: line)
            XCTAssertEqual(h.loggedValue(on: d), want.value, accuracy: 1e-9, "\(at) loggedValue", file: file, line: line)
            XCTAssertEqual(h.progress(on: d), want.progress, accuracy: 1e-9, "\(at) progress", file: file, line: line)
            XCTAssertEqual(f.number(h.record(on: d)), want.record, "\(at) record(on:)", file: file, line: line)
            XCTAssertEqual(h.currentStreak(from: d), want.streak, "\(at) currentStreak(from:)", file: file, line: line)
            XCTAssertEqual(h.weeklyCompletions(containing: d), want.week, "\(at) weeklyCompletions(containing:)",
                           file: file, line: line)
            checked += 6
            // HabitStats' per-day answer equals Habit's direct lookups, except where a row says
            // what only HabitStats gets right (`stats:`).
            let statsWant = row.stats ?? StatsDay(want.done, want.value)
            XCTAssertEqual(stats.isCompleted(on: d), statsWant.done, "\(at) HabitStats.isCompleted(on:)", file: file, line: line)
            XCTAssertEqual(stats.loggedValue(on: d), statsWant.value, accuracy: 1e-9, "\(at) HabitStats.loggedValue(on:)",
                           file: file, line: line)
            XCTAssertEqual(stats.currentStreak(asOf: d), want.streak, "\(at) HabitStats.currentStreak(asOf:)",
                           file: file, line: line)
            XCTAssertEqual(stats.weeklyCompletions(containing: d), want.week, "\(at) HabitStats.weeklyCompletions(containing:)",
                           file: file, line: line)
            checked += 4
            if row.stats == nil {
                XCTAssertEqual(stats.progress(on: d), want.progress, accuracy: 1e-9, "\(at) HabitStats.progress(on:)",
                               file: file, line: line)
                checked += 1
            }
        }

        XCTAssertEqual(e.weeks.map(\.monday), f.mondays, "\(f.name): one row per fixture week", file: file, line: line)
        for w in e.weeks {
            XCTAssertEqual(h.weeklyCompletions(weekStarting: w.monday), asserted(w.golden),
                           "\(f.name) weeklyCompletions(weekStarting: \(ymd(w.monday)))", file: file, line: line)
            checked += 1
        }

        XCTAssertEqual(h.bestStreak(), asserted(e.best), "\(f.name) bestStreak()", file: file, line: line)
        XCTAssertEqual(stats.bestStreakRanges.first?.length ?? 0, h.bestStreak(),
                       "\(f.name) bestStreakRanges.first?.length == bestStreak()", file: file, line: line)
        checked += 2

        XCTAssertEqual(e.rates.map { [$0.from, $0.to] }, f.rateRanges.map { [$0.0, $0.1] },
                       "\(f.name): one row per fixture range", file: file, line: line)
        for r in e.rates {
            let what = "\(f.name) completionRate(from: \(ymd(r.from)), to: \(ymd(r.to)), now: today)"
            guard let g = select(r.golden, f, what, file: file, line: line) else { continue }
            XCTAssertEqual(h.completionRate(from: r.from, to: r.to, now: f.today), asserted(g), accuracy: 1e-9, what,
                           file: file, line: line)
            checked += 1
        }

        XCTAssertEqual(h.completionsPerWeekday(), asserted(e.perWeekday), "\(f.name) completionsPerWeekday()",
                       file: file, line: line)
        checked += 1

        XCTAssertEqual(e.instants.map(\.label), f.instants.map { $0.0 }, "\(f.name): one row per fixture instant",
                       file: file, line: line)
        for i in e.instants {
            guard let instant = f.instants.first(where: { $0.0 == i.label })?.1 else { continue }
            let offset = Self.processDayOffset(instant), at = "\(f.name) \(i.label)"
            guard let g = i.byOffset[offset] else {
                XCTFail("\(at): no golden for a zone that dates it \(offset) day(s) from its UTC date (\(TimeZone.current.identifier))",
                        file: file, line: line)
                continue
            }
            let want = asserted(g)
            XCTAssertEqual(h.isCompletedOn(instant), want.done, "\(at) isCompletedOn", file: file, line: line)
            XCTAssertEqual(h.loggedValue(on: instant), want.value, accuracy: 1e-9, "\(at) loggedValue", file: file, line: line)
            XCTAssertEqual(h.currentStreak(from: instant), want.streak, "\(at) currentStreak(from:)", file: file, line: line)
            XCTAssertEqual(stats.isCompleted(on: instant), want.done, "\(at) HabitStats.isCompleted(on:)", file: file, line: line)
            XCTAssertEqual(stats.currentStreak(asOf: instant), want.streak, "\(at) HabitStats.currentStreak(asOf:)",
                           file: file, line: line)
            checked += 5
        }

        checked += try checkThirtyDayRate(make, f, e.thirtyDay, file: file, line: line)
        print("PARITY \(f.name): \(checked) golden values checked (zone \(TimeZone.current.identifier))")
    }

    /// `completionRate(days: 30)` reads the clock: check it on the fixture moved so that its today
    /// is the run's today. Returns how many goldens it checked.
    private func checkThirtyDayRate(_ make: (Int) throws -> Built, _ f: Built, _ golden: ByRun<Double>,
                                    file: StaticString, line: UInt) throws -> Int {
        for _ in 0..<2 {
            let runToday = Self.processToday()
            let moved = try make(Self.daysBetween(f.today, runToday))
            let got = moved.habit.completionRate(days: 30)
            guard Self.processToday() == runToday else { continue }   // midnight passed during the call
            let what = "\(f.name) completionRate(days: 30), moved to end on \(ymd(runToday))"
            guard let g = select(golden, moved, what, file: file, line: line) else { return 0 }
            XCTAssertEqual(got, asserted(g), accuracy: 1e-9, what, file: file, line: line)
            return 1
        }
        XCTFail("\(f.name): the day changed twice during completionRate(days: 30)", file: file, line: line)
        return 0
    }

    private func select<Value>(_ run: ByRun<Value>, _ f: Built, _ what: String,
                               file: StaticString, line: UInt) -> Golden<Value>? {
        let golden: Golden<Value>?
        switch run {
        case .always(let g): golden = g
        case .byWeekday(let table): golden = table[Self.weekday(f.today)]
        case .byCreationDayOffset(let table): golden = table[Self.processDayOffset(f.habit.createdAt)]
        }
        if golden == nil {
            XCTFail("\(what): no golden for this run (zone \(TimeZone.current.identifier), today \(ymd(f.today)))",
                    file: file, line: line)
        }
        return golden
    }

    // MARK: - Dates (Foundation only: nothing here calls the code under test)

    nonisolated static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    nonisolated static let la: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()
    nonisolated static let minus9: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: -9 * 3600)!; return c }()

    /// A day-key: UTC midnight of that date.
    nonisolated static func key(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }
    nonisolated static func add(_ days: Int, _ key: Date) -> Date { utc.date(byAdding: .day, value: days, to: key)! }
    nonisolated static func days(_ from: Date, _ to: Date) -> [Date] {
        var out: [Date] = [], d = from
        while d <= to { out.append(d); d = add(1, d) }
        return out
    }
    nonisolated static func daysBetween(_ a: Date, _ b: Date) -> Int { utc.dateComponents([.day], from: a, to: b).day! }
    /// A wall-clock instant in `cal`'s zone.
    nonisolated static func at(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    /// The day-key of the date `cal` gives `instant`: how a device in that zone keys a check-in.
    nonisolated static func localKey(_ instant: Date, _ cal: Calendar) -> Date {
        let c = cal.dateComponents([.year, .month, .day], from: instant)
        return key(c.year!, c.month!, c.day!)
    }
    /// 11:00 UTC on that date, which every zone from UTC−11 to UTC+12 dates the same: a creation
    /// instant whose day does not depend on the zone the tests run in.
    nonisolated static func noonish(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d, hour: 11))! }
    /// The run's zone, as today's code sees it (`Calendar.current`).
    nonisolated static var processCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = Calendar.current.timeZone; return c }
    nonisolated static func processToday() -> Date { localKey(Date(), processCalendar) }
    /// −1, 0 or +1: the date the run's zone gives `instant`, against its UTC date.
    nonisolated static func processDayOffset(_ instant: Date) -> Int { daysBetween(localKey(instant, utc), localKey(instant, processCalendar)) }
    nonisolated static func weekday(_ key: Date) -> Int { utc.component(.weekday, from: key) }

    // MARK: - Building fixtures

    /// One fixture: a habit in its own in-memory container (so a moved copy never shares record ids
    /// with the original), its today, and what the goldens cover.
    @MainActor final class Built {
        let name: String
        let container: ModelContainer
        let context: ModelContext
        let habit: Habit
        let today: Date
        let shift: Int
        /// Record id → the fixture's number for it (the `record` column).
        var numbers: [UUID: Int] = [:]
        var rangeDays: [Date] = []
        var mondays: [Date] = []
        var rateRanges: [(Date, Date)] = []
        var instants: [(String, Date)] = []
        init(name: String, container: ModelContainer, habit: Habit, today: Date, shift: Int) {
            self.name = name; self.container = container; self.context = container.mainContext
            self.habit = habit; self.today = today; self.shift = shift
        }
        func s(_ key: Date) -> Date { HabitStatsParityTests.add(shift, key) }
        func si(_ instant: Date) -> Date { instant.addingTimeInterval(Double(shift) * 86_400) }
        func record(_ n: Int) -> HabitRecord { habit.records.first { numbers[$0.id] == n }! }
        func number(_ r: HabitRecord?) -> Int? { r.flatMap { numbers[$0.id] } }
    }

    struct FixtureError: Error, CustomStringConvertible { let description: String }

    static func recordID(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    /// A habit created at `created` (an instant), every date moved by `shift` days. Records come
    /// from `add`; each fixture decides whether to save.
    private func build(_ name: String, kind: HabitKind = .binary, target: Double = 1,
                       schedule: HabitSchedule = .daily, timesPerWeek: Int = 7, mask: Int = 127,
                       created: Date, today: Date, shift: Int) throws -> Built {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let habit = Habit(name: name)
        habit.kind = kind.rawValue
        habit.targetValue = target
        habit.scheduleKind = schedule.rawValue
        habit.timesPerWeek = timesPerWeek
        habit.activeDaysMask = mask
        habit.createdAt = created.addingTimeInterval(Double(shift) * 86_400)
        container.mainContext.insert(habit)
        return Built(name: name, container: container, habit: habit, today: Self.add(shift, today), shift: shift)
    }

    /// Record `n` on `day` (a day-key, moved by the fixture's shift), with a fixed id and a stamp
    /// that grows with `n`.
    private func add(_ f: Built, _ n: Int, _ day: Date, _ value: Double = 1) {
        let r = HabitRecord(date: f.s(day), value: value)
        r.id = Self.recordID(n)
        r.updatedAt = Date(timeIntervalSince1970: 1_780_000_000 + Double(n))
        f.numbers[r.id] = n
        f.habit.records.append(r)
    }

    /// What the goldens cover: the days, the Mondays, the rate ranges and the instants.
    private func plan(_ f: Built, range: (Date, Date), mondays: [Date], rates: [(Date, Date)], instants: [(String, Date)] = []) {
        f.rangeDays = Self.days(range.0, range.1)
        f.mondays = mondays
        f.rateRanges = rates
        f.instants = instants.map { ($0.0, f.si($0.1)) }
    }

    /// Deletes record `n` in the habit's own context and saves: a ghost, still in `habit.records`.
    private func deleteHere(_ f: Built, _ n: Int) throws {
        let r = f.record(n)
        f.context.delete(r)
        try f.context.save()
        guard f.habit.records.contains(where: { f.numbers[$0.id] == n }), r.modelContext == nil else {
            throw FixtureError(description: "\(f.name): record \(n) did not stay behind as a ghost")
        }
    }

    /// Deletes record `n` in a second context on the same container and saves. The records are read
    /// first, as the app's rendered list has them (see the header).
    private func deleteElsewhere(_ f: Built, _ n: Int) throws {
        for r in f.habit.records { _ = (r.id, r.date, r.value, r.updatedAt) }
        let other = ModelContext(f.container)
        let id = Self.recordID(n)
        let found = try other.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { $0.id == id }))
        guard found.count == 1 else { throw FixtureError(description: "\(f.name): record \(n) not in the store") }
        other.delete(found[0])
        try other.save()
        let r = f.record(n)
        guard r.modelContext != nil, !r.isDeleted else {
            throw FixtureError(description: "\(f.name): record \(n) no longer looks live in the first context")
        }
    }

    func daily(shift: Int = 0) throws -> Built {
        let f = try build("daily", created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 17), shift: shift)
        var n = 0
        for d in Self.days(Self.key(2026, 6, 1), Self.key(2026, 6, 10)) + Self.days(Self.key(2026, 6, 13), Self.key(2026, 6, 17)) {
            n += 1; add(f, n, d)
        }
        try f.context.save()
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 6, 18)),
             mondays: [Self.key(2026, 6, 1), Self.key(2026, 6, 8), Self.key(2026, 6, 15)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 17)), (Self.key(2026, 5, 25), Self.key(2026, 6, 30)),
                     (Self.key(2026, 6, 11), Self.key(2026, 6, 12)), (Self.key(2026, 6, 13), Self.key(2026, 6, 17))])
        return f
    }

    static let monWedFri = (1 << 1) | (1 << 3) | (1 << 5)
    func specificDays(shift: Int = 0) throws -> Built {
        let f = try build("specificDays", schedule: .specificDays, mask: Self.monWedFri,
                          created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 23), shift: shift)
        for (n, d) in [1, 3, 5, 8, 9, 10, 12, 15, 19, 22].enumerated() { add(f, n + 1, Self.key(2026, 6, d)) }
        try f.context.save()
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 6, 24)),
             mondays: [Self.key(2026, 6, 1), Self.key(2026, 6, 8), Self.key(2026, 6, 15), Self.key(2026, 6, 22)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 23)), (Self.key(2026, 6, 6), Self.key(2026, 6, 7)),
                     (Self.key(2026, 6, 15), Self.key(2026, 6, 21)), (Self.key(2026, 6, 8), Self.key(2026, 6, 14))])
        return f
    }

    func timesPerWeek(shift: Int = 0) throws -> Built {
        let f = try build("timesPerWeek", schedule: .timesPerWeek, timesPerWeek: 3,
                          created: Self.noonish(2026, 6, 1), today: Self.key(2026, 7, 1), shift: shift)
        let dates = [(6, 1), (6, 3), (6, 5), (6, 9), (6, 11), (6, 13), (6, 14), (6, 15), (6, 22), (6, 23), (6, 24), (6, 30)]
        for (n, d) in dates.enumerated() { add(f, n + 1, Self.key(2026, d.0, d.1)) }
        try f.context.save()
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 7, 2)),
             mondays: [Self.key(2026, 6, 1), Self.key(2026, 6, 8), Self.key(2026, 6, 15), Self.key(2026, 6, 22), Self.key(2026, 6, 29)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 7, 1)), (Self.key(2026, 6, 6), Self.key(2026, 6, 30)),
                     (Self.key(2026, 6, 15), Self.key(2026, 6, 21)), (Self.key(2026, 6, 29), Self.key(2026, 7, 5))])
        return f
    }

    func countPartials(shift: Int = 0) throws -> Built {
        let f = try build("countPartials", kind: .count, target: 8,
                          created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 8), shift: shift)
        for (n, e) in [(1, 8.0), (2, 3), (3, 10), (4, 7), (5, 8), (7, 8), (8, 1)].enumerated() { add(f, n + 1, Self.key(2026, 6, e.0), e.1) }
        try f.context.save()
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 6, 9)),
             mondays: [Self.key(2026, 6, 1), Self.key(2026, 6, 8)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 8)), (Self.key(2026, 6, 2), Self.key(2026, 6, 4))])
        return f
    }

    func backdated(shift: Int = 0) throws -> Built {
        let f = try build("backdated", created: Self.noonish(2026, 6, 10), today: Self.key(2026, 6, 14), shift: shift)
        var n = 0
        for d in Self.days(Self.key(2026, 6, 1), Self.key(2026, 6, 5)) + Self.days(Self.key(2026, 6, 8), Self.key(2026, 6, 14)) {
            n += 1; add(f, n, d)
        }
        try f.context.save()
        plan(f, range: (Self.key(2026, 5, 31), Self.key(2026, 6, 15)),
             mondays: [Self.key(2026, 5, 25), Self.key(2026, 6, 1), Self.key(2026, 6, 8)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 14)), (Self.key(2026, 6, 8), Self.key(2026, 6, 14)),
                     (Self.key(2026, 5, 1), Self.key(2026, 6, 30)), (Self.key(2026, 6, 1), Self.key(2026, 6, 9))])
        return f
    }

    func ghost(shift: Int = 0) throws -> Built {
        let f = try build("ghost", created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 5), shift: shift)
        add(f, 1, Self.key(2026, 5, 31))
        for d in 1...5 { add(f, d + 1, Self.key(2026, 6, d)) }
        try f.context.save()
        try deleteHere(f, 1)
        try deleteHere(f, 4)
        try deleteHere(f, 6)
        plan(f, range: (Self.key(2026, 5, 30), Self.key(2026, 6, 6)),
             mondays: [Self.key(2026, 5, 25), Self.key(2026, 6, 1)],
             rates: [(Self.key(2026, 5, 25), Self.key(2026, 6, 5)), (Self.key(2026, 6, 3), Self.key(2026, 6, 3)),
                     (Self.key(2026, 6, 1), Self.key(2026, 6, 5))])
        return f
    }

    func dst(shift: Int = 0) throws -> Built {
        let la = Self.la
        let f = try build("dst", created: Self.noonish(2026, 3, 1), today: Self.key(2026, 3, 14), shift: shift)
        let checkIns = [Self.at(la, 2026, 3, 4, 23, 30), Self.at(la, 2026, 3, 5, 0, 10), Self.at(la, 2026, 3, 6, 23, 59),
                        Self.at(la, 2026, 3, 7, 22, 0), Self.at(la, 2026, 3, 8, 0, 30), Self.at(la, 2026, 3, 9, 3, 30),
                        Self.at(la, 2026, 3, 10, 23, 30), Self.at(la, 2026, 3, 11, 0, 5), Self.at(la, 2026, 3, 13, 12, 0),
                        Self.at(la, 2026, 3, 14, 23, 30)]
        for (n, i) in checkIns.enumerated() { add(f, n + 1, Self.localKey(i, la)) }
        try f.context.save()
        plan(f, range: (Self.key(2026, 3, 3), Self.key(2026, 3, 15)),
             mondays: [Self.key(2026, 3, 2), Self.key(2026, 3, 9)],
             rates: [(Self.key(2026, 3, 1), Self.key(2026, 3, 14)), (Self.key(2026, 3, 7), Self.key(2026, 3, 9)),
                     (Self.key(2026, 3, 8), Self.key(2026, 3, 8)), (Self.key(2026, 3, 12), Self.key(2026, 3, 31))],
             instants: [("2026-03-07 22:30 PST", Self.at(la, 2026, 3, 7, 22, 30)),
                        ("2026-03-12 23:30 PDT", Self.at(la, 2026, 3, 12, 23, 30))])
        return f
    }

    func utcMinus9(shift: Int = 0) throws -> Built {
        let m9 = Self.minus9
        let f = try build("utcMinus9", created: Self.at(m9, 2026, 6, 1, 21, 0), today: Self.key(2026, 6, 7), shift: shift)
        for (n, d) in [1, 2, 3, 4, 6, 7].enumerated() { add(f, n + 1, Self.localKey(Self.at(m9, 2026, 6, d, 21, 30), m9)) }
        try f.context.save()
        plan(f, range: (Self.key(2026, 5, 31), Self.key(2026, 6, 8)),
             mondays: [Self.key(2026, 5, 25), Self.key(2026, 6, 1)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 7)), (Self.key(2026, 5, 25), Self.key(2026, 6, 7)),
                     (Self.key(2026, 6, 2), Self.key(2026, 6, 7))],
             instants: [("2026-06-05 21:30 UTC−9", Self.at(m9, 2026, 6, 5, 21, 30)),
                        ("2026-06-07 21:30 UTC−9", Self.at(m9, 2026, 6, 7, 21, 30))])
        return f
    }

    // Unsaved on purpose: see the header (a save does not keep the order of `records`).
    func duplicateCounts(shift: Int = 0) throws -> Built {
        let f = try build("duplicateCounts", kind: .count, target: 5,
                          created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 5), shift: shift)
        for (n, e) in [(1, 5.0), (2, 3), (2, 8), (3, 8), (3, 3), (4, 6), (4, 6), (5, 2), (5, 4)].enumerated() {
            add(f, n + 1, Self.key(2026, 6, e.0), e.1)
        }
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 6, 6)),
             mondays: [Self.key(2026, 6, 1)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 5))])
        return f
    }

    // Unsaved on purpose, as above.
    func duplicateCheckIns(shift: Int = 0) throws -> Built {
        let f = try build("duplicateCheckIns", created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 3), shift: shift)
        for (n, d) in [1, 2, 2, 3].enumerated() { add(f, n + 1, Self.key(2026, 6, d)) }
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 6, 4)),
             mondays: [Self.key(2026, 6, 1)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 3))])
        return f
    }

    func afterToday(shift: Int = 0) throws -> Built {
        let f = try build("afterToday", created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 3), shift: shift)
        for d in 1...3 { add(f, d, Self.key(2026, 6, d)) }
        for d in 5...9 { add(f, d - 1, Self.key(2099, 1, d)) }
        try f.context.save()
        plan(f, range: (Self.key(2026, 6, 1), Self.key(2026, 6, 4)),
             mondays: [Self.key(2026, 6, 1), Self.key(2099, 1, 5)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 3)), (Self.key(2026, 6, 1), Self.key(2099, 12, 31))])
        f.rangeDays += Self.days(Self.key(2099, 1, 4), Self.key(2099, 1, 10))
        return f
    }

    func backdatedAcrossDST(shift: Int = 0) throws -> Built {
        let la = Self.la
        let f = try build("backdatedAcrossDST", created: Self.noonish(2025, 11, 3), today: Self.key(2025, 11, 6), shift: shift)
        let checkIns = [Self.at(la, 2025, 10, 30, 23, 30), Self.at(la, 2025, 10, 31, 22, 0), Self.at(la, 2025, 11, 2, 1, 30),
                        Self.at(la, 2025, 11, 3, 23, 30), Self.at(la, 2025, 11, 4, 7, 0), Self.at(la, 2025, 11, 5, 23, 59),
                        Self.at(la, 2025, 11, 6, 0, 1)]
        for (n, i) in checkIns.enumerated() { add(f, n + 1, Self.localKey(i, la)) }
        try f.context.save()
        plan(f, range: (Self.key(2025, 10, 29), Self.key(2025, 11, 7)),
             mondays: [Self.key(2025, 10, 27), Self.key(2025, 11, 3)],
             rates: [(Self.key(2025, 10, 27), Self.key(2025, 11, 6)), (Self.key(2025, 11, 1), Self.key(2025, 11, 6)),
                     (Self.key(2025, 11, 3), Self.key(2025, 11, 6)), (Self.key(2025, 10, 30), Self.key(2025, 10, 31))],
             instants: [("2025-11-05 23:30 PST", Self.at(la, 2025, 11, 5, 23, 30))])
        return f
    }

    func secondContext(shift: Int = 0) throws -> Built {
        let f = try build("secondContext", created: Self.noonish(2026, 6, 1), today: Self.key(2026, 6, 5), shift: shift)
        for d in 1...5 { add(f, d, Self.key(2026, 6, d)) }
        try f.context.save()
        try deleteElsewhere(f, 4)
        plan(f, range: (Self.key(2026, 5, 31), Self.key(2026, 6, 6)),
             mondays: [Self.key(2026, 6, 1)],
             rates: [(Self.key(2026, 6, 1), Self.key(2026, 6, 5)), (Self.key(2026, 6, 4), Self.key(2026, 6, 4))])
        return f
    }
}
