import XCTest
import SwiftData
import Foundation

/// Large-account timings of the real engine (`SyncEngine` → planner, resolver, reconciler) on an
/// on-disk store reopened cold, as the launch sync meets it. The network is a canned transport
/// that answers instantly, so what is timed is the device's own work on the main actor: decode,
/// plan, resolve, reconcile, save.
///
/// Why these exist: the M2 slice's rehearsal (S12, a 20,000-entry account, -O build) measured
/// 3.4 s on every sync with no edits — the planner walked every record of every habit through
/// its relationship — and 51 s for a second device joining, the reconciler's
/// `habit.records.first(where: isDate(inSameDayAs:))` per pulled entry with one-at-a-time
/// appends. Both would reach users as hang reports. The unit suites only ever held a few rows.
///
/// Measured here first, then fixed (M1 Pro, Debug, 2026-09-28; before → after):
///
///     quiet sync 10 × 730                         1.22 s → 0.008 s
///     overlap pull re-applying 10 × 730           9.62 s → 0.37 s
///     first join 50 × 1,095 (54,750 entries)    175.6 s  → 7.0 s   (~75 % is SwiftData's one save)
///     full pull onto a synced 50 × 1,095         92.2 s  → 2.5 s
///     first upload 50 × 1,095 (28 chunks)        53.0 s  → 23.2 s  (mostly each chunk's save)
///
/// The bounds asserted are loose on purpose (a Debug build on a slower CI Mac must pass): they
/// catch a return to quadratic work, not a few percent. Each test prints its timing as
/// `PERF <name>: …`.
@MainActor
final class SyncPerformanceTests: XCTestCase {

    private var directory: URL!
    private var suiteNames: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        suiteNames.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        try super.tearDownWithError()
    }

    private static let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
    private let day0 = HabitCalendar.utc.date(from: DateComponents(year: 2023, month: 1, day: 1))!

    // MARK: - Quiet sync

    /// 10 habits × 730 days, everything delivered, a live cursor, and a pull with nothing new:
    /// the sync every launch and every foreground makes. Nothing is pending, so the engine's
    /// whole cost is finding that out.
    func testQuietSyncOnTenHabitsTimesTwoYears() async throws {
        let store = try makeStore(habits: 10, days: 730, delivered: true)
        let device = try Device(store: store, suite: suite())
        device.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")
        device.transport.pullBody = { _ in Self.pullBody(habits: [], entries: []) }

        let (outcome, seconds) = await timed { await device.engine.run(in: device.context) }
        let summary = try expectSynced(outcome)
        XCTAssertTrue(summary.pushes.isEmpty)
        XCTAssertEqual(device.transport.pushes, 0)
        print(String(format: "PERF quiet sync 10x730 (7,300 entries, cold store): %.3f s", seconds))
        XCTAssertLessThan(seconds, 0.5, "a sync with no edits must not read every record")
    }

    /// One check-in edited since the last sync on the same store: the push carries that entry
    /// alone, and finding it must not cost a read of every record.
    func testOneEditOnTenHabitsTimesTwoYears() async throws {
        let store = try makeStore(habits: 10, days: 730, delivered: true)
        let device = try Device(store: store, suite: suite())
        device.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")
        device.transport.pullBody = { _ in Self.pullBody(habits: [], entries: []) }
        let first = day0
        let edited = try XCTUnwrap(device.context.fetch(FetchDescriptor<HabitRecord>(
            predicate: #Predicate { $0.date == first })).first)
        edited.value = 2
        edited.touch()
        try device.context.save()

        let (outcome, seconds) = await timed { await device.engine.run(in: device.context) }
        let summary = try expectSynced(outcome)
        XCTAssertEqual(summary.pushedRows, SyncRowCounts(groups: 0, habits: 0, entries: 1))
        XCTAssertFalse(edited.isPending)
        print(String(format: "PERF one edit on 10x730: %.3f s", seconds))
        XCTAssertLessThan(seconds, 1.0)
    }

    /// The same store, but the incremental pull echoes every row back (the cursor's 60 s overlap
    /// right after a big upload or a full pull re-feeds what was just written): the reconciler
    /// re-applies 7,300 entries onto records it already has.
    func testOverlapPullReapplyingEveryRowOnTenHabitsTimesTwoYears() async throws {
        let store = try makeStore(habits: 10, days: 730, delivered: true)
        let device = try Device(store: store, suite: suite())
        device.cursors.setCursor(SyncTimestamp.millisecondString(from: Date()), for: "1")
        let body = Self.pullBody(habits: store.habits, entries: store.entries)
        device.transport.pullBody = { _ in body }

        let (outcome, seconds) = await timed { await device.engine.run(in: device.context) }
        let summary = try expectSynced(outcome)
        XCTAssertTrue(summary.pushes.isEmpty, "an echo of delivered rows leaves nothing pending")
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<HabitRecord>()), 7_300)
        print(String(format: "PERF overlap pull re-applying 10x730: %.3f s", seconds))
        XCTAssertLessThan(seconds, 3.0)
    }

    // MARK: - Joining a large account

    /// A second device joins a 50-habit, three-year account (54,750 entries): one full pull into
    /// an empty store, then a push with nothing to send and an incremental pull.
    func testFirstJoinOfFiftyHabitsTimesThreeYears() async throws {
        let store = try makeStore(habits: 50, days: 1_095, delivered: true, persist: false)
        let device = try Device(store: try emptyStore(), suite: suite())
        let full = Self.pullBody(habits: store.habits, entries: store.entries, totals: true)
        let empty = Self.pullBody(habits: [], entries: [])
        device.transport.pullBody = { since in since == nil ? full : empty }

        let (outcome, seconds) = await timed { await device.engine.run(in: device.context) }
        let summary = try expectSynced(outcome)
        XCTAssertTrue(summary.pushes.isEmpty, "every pulled row is delivered")
        XCTAssertFalse(summary.deletionPassSkipped)
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<HabitRecord>()), 54_750)
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<Habit>()), 50)
        print(String(format: "PERF first join 50x1095 (54,750 entries): %.3f s", seconds))
        XCTAssertLessThan(seconds, 45.0)
    }

    /// A full pull of the same 54,750 entries onto a store that already holds them all — Full
    /// resync, a `cursor_expired`, the proving pull of migrated marks: every entry is matched to
    /// its local record by habit and day.
    func testFullPullOntoASyncedStoreOfFiftyHabitsTimesThreeYears() async throws {
        let store = try makeStore(habits: 50, days: 1_095, delivered: true)
        let device = try Device(store: store, suite: suite())
        let full = Self.pullBody(habits: store.habits, entries: store.entries, totals: true)
        let empty = Self.pullBody(habits: [], entries: [])
        device.transport.pullBody = { since in since == nil ? full : empty }

        let (outcome, seconds) = await timed { await device.engine.run(in: device.context) }
        let summary = try expectSynced(outcome)
        XCTAssertTrue(summary.pushes.isEmpty)
        XCTAssertFalse(summary.deletionPassSkipped)
        XCTAssertEqual(try device.context.fetchCount(FetchDescriptor<HabitRecord>()), 54_750)
        print(String(format: "PERF full pull onto a synced 50x1095 store: %.3f s", seconds))
        XCTAssertLessThan(seconds, 30.0)
    }

    // MARK: - First upload

    /// 20 × 1,095 never delivered, an empty account: 11 chunks of up to 2,000 entries, each
    /// answered with nothing skipped. (Smaller than the others: most of an upload's time is
    /// SwiftData saving each chunk's acknowledgements, which is linear and not the engine's, and
    /// this suite runs on every CI push. 50 × 1,095 measured 53.0 s before the M2 work, 23.2 s
    /// after.)
    func testFirstUploadOfTwentyHabitsTimesThreeYears() async throws {
        let store = try makeStore(habits: 20, days: 1_095, delivered: false)
        let device = try Device(store: store, suite: suite())
        let empty = Self.pullBody(habits: [], entries: [], totals: true)
        device.transport.pullBody = { _ in empty }

        let (outcome, seconds) = await timed { await device.engine.run(in: device.context) }
        let summary = try expectSynced(outcome)
        XCTAssertEqual(summary.pushedRows, SyncRowCounts(groups: 0, habits: 20, entries: 21_900))
        XCTAssertEqual(summary.acknowledged, 21_920)
        XCTAssertEqual(summary.pushes.count, 11)
        print(String(format: "PERF first upload 20x1095 (%d pushes): %.3f s", summary.pushes.count, seconds))
        XCTAssertLessThan(seconds, 45.0)
    }

    // MARK: - Harness

    private func suite() -> String {
        let name = "SyncPerformanceTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return name
    }

    private func timed<T>(_ body: () async -> T) async -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = await body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

    private func expectSynced(_ outcome: SyncRunOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> SyncRunSummary {
        guard case .synced(let summary) = outcome else {
            XCTFail("expected .synced, got \(outcome)", file: file, line: line)
            throw NotSynced()
        }
        return summary
    }

    private struct NotSynced: Error {}

    /// A store on disk and the wire rows it holds (what the account's server would send).
    struct Store {
        var url: URL
        var habits: [SyncHabit]
        var entries: [SyncEntry]
    }

    private func emptyStore() throws -> Store {
        Store(url: directory.appendingPathComponent("\(UUID().uuidString).store"), habits: [], entries: [])
    }

    /// `habits` habits with a check-in every day for `days` days. `delivered` marks every row
    /// delivered at its stamp, as a device that has synced them holds them. Saved and closed, so
    /// the device under test opens it cold. `persist: false` builds the wire rows only.
    private func makeStore(habits: Int, days: Int, delivered: Bool, persist: Bool = true) throws -> Store {
        var store = try emptyStore()
        let container = try ModelContainer(for: Self.schema, configurations: [ModelConfiguration(url: store.url)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // Every row its own stamp, as a real history has: a check-in is edited on its own day.
        // (One shared stamp would let anything that caches by string look free.)
        let base = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-86_400 * 4))
        for h in 0..<habits {
            let habit = Habit(name: "Habit \(h)")
            let stamp = base.addingTimeInterval(Double(h))
            habit.createdAt = stamp
            habit.updatedAt = stamp
            habit.sortOrder = Double(h)
            let records = (0..<days).map { d -> HabitRecord in
                let record = HabitRecord(date: day0.addingTimeInterval(Double(d) * 86_400))
                record.updatedAt = SyncTimestamp.floorToMillisecond(
                    record.date.addingTimeInterval(Double(h) * 60 + 3_600 + Double(d % 1_000) / 1_000))
                if delivered { record.adoptRemoteState() }
                return record
            }
            if delivered { habit.adoptRemoteState() }
            store.habits.append(SyncPushPlanner.wireHabit(habit, stamp: stamp))
            store.entries += records.map { SyncPushPlanner.wireEntry($0, habitID: habit.id.uuidString, stamp: $0.stamp) }
            if persist {
                context.insert(habit)
                habit.records = records
                try context.save()
            }
        }
        return store
    }

    private struct PullBody: Encodable {
        var habits: [SyncHabit]
        var entries: [SyncEntry]
        var groups: [SyncGroup] = []
        var deletedHabitIds: [String] = []
        var deletedEntryIds: [String] = []
        var deletedGroupIds: [String] = []
        var serverTime: String
        var totals: SyncTotals?
    }

    static func pullBody(habits: [SyncHabit], entries: [SyncEntry], totals: Bool = false) -> Data {
        try! JSONEncoder().encode(PullBody(
            habits: habits, entries: entries, serverTime: SyncTimestamp.millisecondString(from: Date()),
            totals: totals ? SyncTotals(habits: habits.count, entries: entries.count, groups: 0) : nil))
    }

    /// Answers every pull with `pullBody(since)` and every push with "all written".
    @MainActor
    final class CannedTransport: SyncTransport {
        var pullBody: (String?) -> Data = { _ in Data() }
        private(set) var pushes = 0

        func push(body: Data, token: String) async -> SyncTransportResponse {
            pushes += 1
            return SyncTransportResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }

        func pull(since: String?, deletionsSince: String?, token: String) async -> SyncTransportResponse {
            SyncTransportResponse(status: 200, body: pullBody(since))
        }
    }

    /// One device on a store file, opened cold.
    @MainActor
    final class Device {
        let container: ModelContainer
        let context: ModelContext
        let defaults: UserDefaults
        let cursors: SyncDefaultsCursorStore
        let transport = CannedTransport()
        let engine: SyncEngine

        init(store: Store, suite: String) throws {
            container = try ModelContainer(for: SyncPerformanceTests.schema,
                                           configurations: [ModelConfiguration(url: store.url)])
            context = container.mainContext
            defaults = UserDefaults(suiteName: suite)!
            cursors = SyncDefaultsCursorStore(defaults: defaults)
            engine = SyncEngine(
                transport: transport,
                gate: TestDevice.Gate(.ready(SyncRunBinding(ownerID: "1", token: "t", generation: 0))),
                cursorStore: cursors, deletionQueue: SyncDeletionQueue(local: defaults, shared: nil),
                strikes: SyncUnknownHabitStrikes(defaults: defaults), marks: SyncMarksProof(defaults: defaults),
                recoveryLog: SyncMemoryRecoveryLog())
        }
    }
}
