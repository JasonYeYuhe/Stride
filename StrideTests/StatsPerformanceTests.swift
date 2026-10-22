import XCTest
import SwiftData
import Foundation

/// Statistics timings at scale (RELEASE-1.4.1.md Data safety 4), host-less, in the
/// SyncPerformanceTests pattern: an on-disk store saved, closed and reopened cold, the work
/// timed on the main actor, each test printing `PERF <name>: …`.
///
/// The histories end today (the process's day), so streaks run the full length — the walk a
/// two-year streak really costs — and `Habit`'s wrappers, which read the clock, see the same
/// day as `HabitStats`. Ten habits mix every path: yes/no daily, count (target 8, met on 2 days
/// in 9), 3×/week and Mon/Wed/Fri.
///
/// Each bound is 5× the time first measured (M-series Mac, Debug, 2026-10-15; the first value
/// is in each test's comment), so a return to per-day record scans, or a strength walk on a
/// path that must not run one, fails here rather than as a hang report. The one exception
/// bounds a ratio instead: the wrappers against 1.4.0's own methods, timed side by side.
@MainActor
final class StatsPerformanceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatsPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private static let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])

    // MARK: - 10 habits × 730 days

    /// The full build StatsCache makes for every habit after an invalidate-all: one live-id fetch
    /// for all ten, one `HabitStats` each, then every aggregate the Statistics tab reads,
    /// strength included. First measured 0.191 s, most of it the fetch that loads the cold rows.
    func testFullBuildOnTenHabitsTimesTwoYears() throws {
        let store = try coldStore(habits: 10, days: 730)
        let (stats, seconds) = timed { buildAll(store) }
        XCTAssertEqual(stats.count, 10)
        XCTAssertEqual(stats[0].currentStreak(), 730, "a yes/no habit done every day for two years")
        print(String(format: "PERF stats full build 10x730 (7,300 entries, cold store): %.3f s", seconds))
        XCTAssertLessThan(seconds, 0.96)
    }

    /// 100 reads of a built (cached) set: what 100 renders of the detail card, heatmap and row
    /// streaks cost once StatsCache holds the entries. First measured 0.017 s.
    func testOneHundredCachedReadsOnTenHabitsTimesTwoYears() throws {
        let store = try coldStore(habits: 10, days: 730)
        let stats = buildAll(store)
        let heatmap = (0..<84).map { HabitCalendar.utc.date(byAdding: .day, value: -$0, to: store.today)! }
        let (sum, seconds) = timed { () -> Int in
            var sum = 0
            for _ in 0..<100 {
                for s in stats {
                    sum += s.currentStreak() + s.bestStreak + s.weeklyCompletions(containing: store.today)
                    sum += Int(s.completionRate(days: 30) * 100) + HabitScore.displayValue(s.strength)
                    sum += s.completionsPerWeekday.count + s.bestStreakRanges.count
                    for day in heatmap where s.isCompleted(on: day) { sum += 1 }
                }
            }
            return sum
        }
        XCTAssertGreaterThan(sum, 0)
        print(String(format: "PERF stats 100 cached reads 10x730 (84 heatmap days each): %.3f s", seconds))
        XCTAssertLessThan(seconds, 0.085)
    }

    /// The widget's timeline read: one live-id fetch, one `HabitStats` per habit, both day-keys
    /// answered from it — and no strength walk. Its `HabitStats` are released with the inputs:
    /// the plan keeps only plain rows (Data safety 5). First measured 0.216 s (1.4.0's six
    /// record scans per habit, same store, -Onone: 1.43 s).
    func testWidgetReadOverTwoDayKeys() throws {
        let store = try coldStore(habits: 10, days: 730)
        #if DEBUG
        let walks = HabitScore.walkCount
        #endif
        let now = Date()
        let (plan, seconds) = timed {
            WidgetTimelinePlan(now: now, calendar: .current,
                               rows: WidgetTimelinePlan.rowInputs(for: store.habits, in: store.context, now: now,
                                                                  calendar: .current))
        }
        XCTAssertEqual(plan.entries.map(\.rows.count), [10, 10])
        XCTAssertEqual(plan.entries[0].rows[0].streak, 730)
        #if DEBUG
        XCTAssertEqual(HabitScore.walkCount, walks, "the widget never reads strength")
        #endif
        print(String(format: "PERF stats widget read 10x730 (2 day-keys, cold store): %.3f s", seconds))
        XCTAssertLessThan(seconds, 1.08)

        // Memory: nothing keeps a HabitStats once the plan is made.
        weak var held: HabitStats?
        do {
            let live = HabitStats.liveRecordIDs(of: store.habits, in: store.context)
            let stats = HabitStats(habit: store.habits[0], liveRecordIDs: live, today: now)
            held = stats
            let input = WidgetTimelinePlan.RowInput(store.habits[0], stats: stats)
            _ = WidgetTimelinePlan(now: now, calendar: .current, rows: [input])
        }
        XCTAssertNil(held, "the plan must not retain a HabitStats")
    }

    /// The uncached wrapper path, as a view still on `Habit`'s methods renders it: 84 heatmap
    /// `isCompletedOn` (direct lookups) plus one `currentStreak()` (one HabitStats, one live-id
    /// fetch) per habit. It must run NO strength walk. Timed twice: the first render after a cold
    /// open, where the direct lookups fault every record in one row at a time (SwiftData's cost,
    /// the same before 1.4.1), and a render after that. First measured cold 1.229 s, warm
    /// 0.443 s (1.4.0's methods on the same store, -Onone: cold 1.67 s, warm 0.89 s).
    func testUncachedWrapperPathOnTenHabitsTimesTwoYears() throws {
        let store = try coldStore(habits: 10, days: 730)
        let heatmap = (0..<84).map { HabitCalendar.utc.date(byAdding: .day, value: -$0, to: store.today)! }
        #if DEBUG
        let walks = HabitScore.walkCount
        #endif
        func render() -> Int {
            var sum = 0
            for habit in store.habits {
                for day in heatmap where habit.isCompletedOn(day) { sum += 1 }
                sum += habit.currentStreak()
            }
            return sum
        }
        let (cold, coldSeconds) = timed(render)
        let (warm, warmSeconds) = timed(render)
        let (_, streakSeconds) = timed { store.habits.map { $0.currentStreak() } }
        XCTAssertGreaterThan(cold, 0)
        XCTAssertEqual(warm, cold)
        #if DEBUG
        XCTAssertEqual(HabitScore.walkCount, walks, "a wrapper must never compute strength")
        #endif
        print(String(format: "PERF stats uncached wrappers 10x730 (84 isCompletedOn + currentStreak per habit): cold %.3f s, warm %.3f s (of which the 10 currentStreak: %.3f s)",
                     coldSeconds, warmSeconds, streakSeconds))
        XCTAssertLessThan(coldSeconds, 6.15)
        XCTAssertLessThan(warmSeconds, 2.22)
    }

    /// The wrapper path against 1.4.0's own methods (`Legacy140`, below: copied verbatim from
    /// d780323), timed in one run on the same warm store. A ratio holds in Debug too, where a
    /// bound of 5× a test's own first value could not see the wrappers become 3.5× slower than
    /// 1.4.0 at -O (W1 review, W1-PERF-1).
    ///
    /// What a wrapper call pays that 1.4.0's did not is D2's store count (`liveRecords(of:)`,
    /// about 1 ms per 730 records at -O), the price of seeing a deletion another context or
    /// process saved; its pass over the records reads each one's day and value, where 1.4.0's
    /// `completedDayKeys` read the day. First measured (Debug, M-series Mac), new against 1.4.0:
    /// `completionRate(from:to:)` over a week 2.31×, `currentStreak()` 1.79×; on the same Mac
    /// running a game (every other bound in this suite failing 3–20×), 3.01× and 1.74×. With the
    /// build the wrappers made before the review fix (every record's note and stamp read, the
    /// records filtered twice): 3.18× and 3.06×. So the streak's bound (2.6×) is the one that
    /// catches that build, and the rate's (3.5×) leaves room for a loaded machine. At -O
    /// (`swiftc -O` over Shared/, a warm 730-record yes/no habit): 2.5 ms against 1.0 ms, and
    /// 2.5 ms against 1.7 ms; before the fix 3.6 ms for both.
    func testTheWrapperPathAgainstOneFourZeroOnTenHabitsTimesTwoYears() throws {
        let store = try coldStore(habits: 10, days: 730)
        for habit in store.habits { for r in habit.records { _ = (r.id, r.date, r.value, r.updatedAt, r.note) } }
        let weekStart = HabitCalendar.utc.date(byAdding: .day, value: -6, to: store.today)!
        let now = Date()
        for habit in store.habits {
            let legacy = Legacy140(habit)
            XCTAssertEqual(habit.completionRate(from: weekStart, to: store.today, now: now),
                           legacy.completionRate(from: weekStart, to: store.today, now: now), accuracy: 1e-12,
                           "\(habit.name): the same answer, so the same work is timed")
            XCTAssertEqual(habit.currentStreak(), legacy.currentStreak(), "\(habit.name)")
        }
        func best(_ body: () -> Void) -> Double {
            (0..<5).map { _ in timed { for _ in 0..<10 { body() } }.1 }.min()!
        }
        let rate = best { for h in store.habits { _ = h.completionRate(from: weekStart, to: store.today, now: now) } }
        let rate140 = best { for h in store.habits { _ = Legacy140(h).completionRate(from: weekStart, to: store.today, now: now) } }
        // The streak on the daily yes/no habits only: 1.4.0 rebuilt the day set once per week
        // for a times-per-week streak, which would flatter the ratio.
        let daily = store.habits.filter { $0.schedule == .daily && $0.habitKind == .binary }
        let streak = best { for h in daily { _ = h.currentStreak() } }
        let streak140 = best { for h in daily { _ = Legacy140(h).currentStreak() } }
        let calls = 10.0 * Double(store.habits.count), streakCalls = 10.0 * Double(daily.count)
        print(String(format: "PERF stats wrappers vs 1.4.0 10x730 (warm, per call): completionRate(from:to:) %.2f ms vs %.2f ms (%.2fx), currentStreak() on the %d daily yes/no habits %.2f ms vs %.2f ms (%.2fx)",
                     rate / calls * 1000, rate140 / calls * 1000, rate / rate140, daily.count,
                     streak / streakCalls * 1000, streak140 / streakCalls * 1000, streak / streak140))
        XCTAssertLessThan(rate / rate140, 3.5, "a wrapper call costs more than D2's store count over 1.4.0")
        XCTAssertLessThan(streak / streak140, 2.6, "the wrappers read more than each record's day and value")
    }

    // MARK: - 50 habits × 1,095 days

    /// The full build on the largest account the sync suite models (SyncPerformanceTests.swift,
    /// 54,750 entries): every habit, every aggregate, strength included. First measured 1.494 s.
    func testFullBuildOnFiftyHabitsTimesThreeYears() throws {
        let store = try coldStore(habits: 50, days: 1_095)
        let (stats, seconds) = timed { buildAll(store) }
        XCTAssertEqual(stats.count, 50)
        XCTAssertEqual(stats.map(\.liveRecordCount).reduce(0, +), 54_750)
        print(String(format: "PERF stats full build 50x1095 (54,750 entries, cold store): %.3f s", seconds))
        XCTAssertLessThan(seconds, 7.5)
    }

    // MARK: - Harness

    private struct Store {
        let container: ModelContainer
        let context: ModelContext
        let habits: [Habit]
        let today: Date
    }

    /// Every aggregate of every habit, from one live-id fetch.
    private func buildAll(_ store: Store) -> [HabitStats] {
        let live = HabitStats.liveRecordIDs(of: store.habits, in: store.context)
        return store.habits.map { habit in
            let s = HabitStats(habit: habit, liveRecordIDs: live, today: store.today)
            _ = (s.currentStreak(), s.bestStreakRanges, s.completionRate(days: 30), s.completionsPerWeekday)
            _ = (s.strength, s.strengthDelta30, s.strengthDelta90, s.weeklyStrength)
            return s
        }
    }

    /// 1.4.0's `completionRate(from:to:now:)` and `currentStreak(from:)` with their helpers,
    /// copied verbatim from Shared/Habit.swift at d780323 (only `private` dropped), over the
    /// habit's fields: the comparator for the wrapper path.
    private struct Legacy140 {
        let habit: Habit
        init(_ habit: Habit) { self.habit = habit }
        var records: [HabitRecord] { habit.records }
        var habitKind: HabitKind { habit.habitKind }
        var targetValue: Double { habit.targetValue }
        var schedule: HabitSchedule { habit.schedule }
        var timesPerWeek: Int { habit.timesPerWeek }
        var createdAt: Date { habit.createdAt }
        func isScheduled(on date: Date) -> Bool { habit.isScheduled(on: date) }

        func completedDayKeys() -> Set<Date> {
            switch habitKind {
            case .binary:
                return Set(records.map { HabitCalendar.startOfKey($0.date) })
            case .count:
                return Set(records.filter { $0.value >= targetValue && targetValue > 0 }
                    .map { HabitCalendar.startOfKey($0.date) })
            }
        }

        func currentStreak(from referenceDate: Date = Date()) -> Int {
            if schedule == .timesPerWeek { return currentWeeklyStreak(from: referenceDate) }

            let calendar = HabitCalendar.utc
            let completed = completedDayKeys()
            guard !completed.isEmpty, let earliest = completed.min() else { return 0 }

            let today = HabitCalendar.dayKey(for: referenceDate)
            var day = today
            // Grace: if today isn't done yet, evaluate the streak ending yesterday.
            if !completed.contains(day) {
                guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
                day = y
            }

            var streak = 0
            while day >= earliest {
                if isScheduled(on: day) {
                    if completed.contains(day) {
                        streak += 1
                    } else {
                        break // a scheduled day that's incomplete ends the streak
                    }
                }
                // unscheduled (rest) days are skipped — they neither count nor break
                guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = prev
            }
            return streak
        }

        func weekStart(for date: Date) -> Date {
            let cal = HabitCalendar.utc
            let key = HabitCalendar.dayKey(for: date)
            let weekday = cal.component(.weekday, from: key) // 1=Sun…7=Sat
            let daysFromMonday = (weekday + 5) % 7           // Mon→0, Sun→6
            return cal.date(byAdding: .day, value: -daysFromMonday, to: key) ?? key
        }

        func weeklyCompletions(weekStarting start: Date) -> Int {
            let cal = HabitCalendar.utc
            guard let end = cal.date(byAdding: .day, value: 6, to: start) else { return 0 }
            return completedDayKeys().filter { $0 >= start && $0 <= end }.count
        }

        func currentWeeklyStreak(from referenceDate: Date) -> Int {
            let cal = HabitCalendar.utc
            let completed = completedDayKeys()
            guard !completed.isEmpty, let earliest = completed.min() else { return 0 }
            let target = max(1, timesPerWeek)
            let earliestWeek = weekStart(for: earliest)

            var week = weekStart(for: referenceDate)
            // Grace: the current (in-progress) week not yet meeting target doesn't break the streak.
            if weeklyCompletions(weekStarting: week) < target {
                guard let prev = cal.date(byAdding: .day, value: -7, to: week) else { return 0 }
                week = prev
            }

            var streak = 0
            while week >= earliestWeek {
                if weeklyCompletions(weekStarting: week) >= target {
                    streak += 1
                } else {
                    break
                }
                guard let prev = cal.date(byAdding: .day, value: -7, to: week) else { break }
                week = prev
            }
            return streak
        }

        func completionRate(from start: Date, to end: Date, now: Date = Date()) -> Double {
            let calendar = HabitCalendar.utc
            let endKey = min(HabitCalendar.dayKey(for: end), HabitCalendar.dayKey(for: now))
            let startKey = HabitCalendar.dayKey(for: start)
            let creationDate = HabitCalendar.dayKey(for: createdAt)
            let effectiveStart = max(startKey, creationDate)
            guard effectiveStart <= endKey else { return 0 }

            if schedule == .timesPerWeek {
                return weeklyGoalRate(from: effectiveStart, to: endKey)
            }

            var expectedDays = 0
            var day = effectiveStart
            while day <= endKey {
                if isScheduled(on: day) { expectedDays += 1 }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            guard expectedDays > 0 else { return 0 }

            let completedDays = completedDayKeys().filter { $0 >= effectiveStart && $0 <= endKey && isScheduled(on: $0) }.count
            return Double(completedDays) / Double(expectedDays)
        }

        func weeklyGoalRate(from startKey: Date, to endKey: Date) -> Double {
            let cal = HabitCalendar.utc
            let goal = Double(max(1, timesPerWeek))
            let completed = completedDayKeys()

            var earned = 0.0
            var expected = 0.0
            var week = weekStart(for: startKey)
            while week <= endKey {
                guard let weekEnd = cal.date(byAdding: .day, value: 6, to: week) else { break }
                let first = max(week, startKey)
                let last = min(weekEnd, endKey)
                let daysInRange = (cal.dateComponents([.day], from: first, to: last).day ?? 0) + 1
                let share = goal * Double(daysInRange) / 7
                let done = Double(completed.filter { $0 >= week && $0 <= last }.count)
                earned += min(done, share)
                expected += share
                guard let next = cal.date(byAdding: .day, value: 7, to: week) else { break }
                week = next
            }
            return expected > 0 ? earned / expected : 0
        }
    }

    private func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    /// `habits` habits with a record on each of the `days` days ending today, saved and closed,
    /// then opened again in a new container, as a launch or the widget meets it.
    private func coldStore(habits: Int, days: Int) throws -> Store {
        let url = directory.appendingPathComponent("\(UUID().uuidString).store")
        let today = HabitCalendar.dayKey(for: Date())
        let first = HabitCalendar.utc.date(byAdding: .day, value: -(days - 1), to: today)!
        do {
            let container = try ModelContainer(for: Self.schema, configurations: [ModelConfiguration(url: url)])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for h in 0..<habits {
                let habit = Habit(name: "Habit \(h)")
                habit.sortOrder = Double(h)
                habit.createdAt = first.addingTimeInterval(12 * 3600)
                switch h % 4 {
                case 1: habit.habitKind = .count; habit.targetValue = 8
                case 2: habit.schedule = .timesPerWeek; habit.timesPerWeek = 3
                case 3: habit.schedule = .specificDays; habit.activeDaysMask = (1 << 1) | (1 << 3) | (1 << 5)
                default: break
                }
                context.insert(habit)
                habit.records = (0..<days).map { d in
                    let record = HabitRecord(date: first.addingTimeInterval(Double(d) * 86_400),
                                             value: h % 4 == 1 ? Double(d % 9 + 1) : 1)
                    record.updatedAt = record.date.addingTimeInterval(3_600 + Double(h))
                    return record
                }
                try context.save()
            }
        }
        let container = try ModelContainer(for: Self.schema, configurations: [ModelConfiguration(url: url)])
        let context = container.mainContext
        let fetched = try context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.sortOrder)]))
        XCTAssertEqual(fetched.count, habits)
        return Store(container: container, context: context, habits: fetched, today: today)
    }
}
