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
/// path that must not run one, fails here rather than as a hang report.
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
