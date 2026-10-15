import XCTest
import SwiftData
import Observation
@testable import Stride

/// `StatsCache` (RELEASE-1.4.1.md D3), hosted, with Statistics alive: a cache of its own over an
/// in-memory store whose mainContext holds the habits, as the app's views do, its observers
/// installed (`installObservers(events:)`) with the day, zone and activation notifications on a
/// center of the test's own — never the host app's. Every "after" compares the cached answer with
/// a fresh recompute: a `HabitStats` built from the habit fetched in a brand-new context, which
/// is what the store holds.
///
/// The write paths are the ones that do not go through `HabitEntryCommit`, and so reach the cache
/// only through its observers: Siri's "Complete a Habit" and a reminder's Mark Done, each saving
/// in a context of its own. `CompleteHabitIntent.perform` writes to `SharedModelContainer.opened`
/// — the host app's real store — and cannot be pointed at another, so its write is made here
/// exactly as `perform` makes it (a fresh context, `markDone` on today, save, `.habitDataChanged`);
/// `NotificationActionHandler.perform` is the real one, over its injected environment.
@MainActor
final class StatsCacheTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var cache: StatsCache!
    private var events: NotificationCenter!

    private let calendar = Calendar.current
    private var todayKey: Date { HabitCalendar.dayKey(forInstant: Date(), calendar: calendar) }

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        events = NotificationCenter()
        cache = StatsCache()
        cache.installObservers(events: events)
    }

    override func tearDown() {
        cache.removeObservers()
        cache = nil
        events = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// The day-key `offset` days from today.
    private func day(_ offset: Int) -> Date {
        HabitCalendar.utc.date(byAdding: .day, value: offset, to: todayKey)!
    }

    /// A habit with a record on each of `days` (offsets from today), saved in mainContext.
    @discardableResult
    private func habit(_ name: String, kind: HabitKind = .binary, target: Double = 1, value: Double = 1,
                       days: [Int]) throws -> Habit {
        let habit = Habit(name: name)
        habit.habitKind = kind
        habit.targetValue = target
        habit.createdAt = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-86_400 * 400))
        context.insert(habit)
        habit.records = days.map { HabitRecord(date: day($0), value: value) }
        try context.save()
        return habit
    }

    /// What the store holds for `habit`, through a context of its own.
    private func fresh(_ habit: Habit) throws -> HabitStats {
        let id = habit.id
        let other = ModelContext(container)
        let stored = try XCTUnwrap(other.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        return HabitStats(habit: stored, live: HabitStats.liveRecords(of: stored), calendar: calendar, today: Date())
    }

    private func cached(_ habit: Habit) -> HabitStats { cache.stats(for: habit, today: Date(), calendar: calendar) }

    /// The cached answer equals the fresh recompute in everything a reader asks.
    private func assertMatchesTheStore(_ habit: Habit, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = cached(habit), b = try fresh(habit)
        XCTAssertEqual(a.completedDayKeys, b.completedDayKeys, "completed days", file: file, line: line)
        XCTAssertEqual(a.valuesByDay, b.valuesByDay, "values", file: file, line: line)
        XCTAssertEqual(a.liveRecordCount, b.liveRecordCount, "live records", file: file, line: line)
        XCTAssertEqual(a.latestLiveRecordStamp, b.latestLiveRecordStamp, "newest stamp", file: file, line: line)
        XCTAssertEqual(a.currentStreak(), b.currentStreak(), "streak", file: file, line: line)
        XCTAssertEqual(a.bestStreak, b.bestStreak, "best streak", file: file, line: line)
        XCTAssertEqual(a.completionRate(days: 30), b.completionRate(days: 30), "rate", file: file, line: line)
        XCTAssertEqual(a.strength, b.strength, "strength", file: file, line: line)
        XCTAssertEqual(a.startDay, b.startDay, "start", file: file, line: line)
    }

    /// Past the cache's own merge of another context's save (two main-queue hops after it) and
    /// anything queued alongside it.
    private func afterTheMerge() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { DispatchQueue.main.async { DispatchQueue.main.async { done.resume() } } }
        }
    }

    /// Effects that touch nothing outside the test.
    private var noEffects: CheckInEffects {
        CheckInEffects(reloadWidgets: {}, updateBadge: { _ in }, cancelSnooze: { _ in },
                       withdrawDelivered: { _ in }, submitRefresh: {})
    }

    /// `HabitEntryCommit` over this cache, with no tombstones, effects or Sentry reaching the host.
    private func commitEnvironment(bumping cache: StatsCache) -> HabitEntryCommit.Environment {
        HabitEntryCommit.Environment(save: { try $0.save() }, trackDeletedEntry: { _ in }, effects: noEffects,
                                     bumpStats: { cache.bump(habitID: $0) }, reportSaveFailure: { _ in },
                                     now: { Date() }, calendar: { Calendar.current })
    }

    #if DEBUG
    private var rebuilds: Int { cache.rebuildCount }
    #endif

    // MARK: - The writes that save in their own contexts

    /// Siri's "Complete a Habit", with Statistics alive: once the merge has run, the cache
    /// equals a fresh recompute — the day checked, the streak one longer — for a yes/no habit (a
    /// new record) and a count habit (the kept record's value raised, in place).
    func testACompleteHabitIntentWriteMatchesAFreshRecomputeAfterTheMerge() async throws {
        let read = try habit("Read", days: Array(-10...(-1)))
        let water = try habit("Water", kind: .count, target: 8, value: 8, days: Array(-5...(-1)))
        water.records.append(HabitRecord(date: day(0), value: 3))
        try context.save()
        XCTAssertFalse(cached(read).isCompleted(on: day(0)))
        XCTAssertEqual(cached(read).currentStreak(), 10)
        XCTAssertEqual(cached(water).loggedValue(on: day(0)), 3)

        for name in ["Read", "Water"] {
            // CompleteHabitIntent.perform, over this store (see the type's comment).
            let siri = ModelContext(container)
            let habit = try XCTUnwrap(siri.fetch(FetchDescriptor<Habit>(
                predicate: #Predicate<Habit> { $0.name == name && !$0.isArchived })).first)
            XCTAssertNotNil(HabitCheckIn.markDone(habit, on: Date(), in: siri))
            try siri.save()
            events.post(name: .habitDataChanged, object: nil)
        }
        await afterTheMerge()

        try assertMatchesTheStore(read)
        try assertMatchesTheStore(water)
        XCTAssertTrue(cached(read).isCompleted(on: day(0)))
        XCTAssertEqual(cached(read).currentStreak(), 11)
        XCTAssertEqual(cached(water).loggedValue(on: day(0)), 4, "Add 1 on the kept record, refreshed here")
        XCTAssertEqual(read.records.count, 11, "the merge: mainContext's habit lists the record Siri inserted")
    }

    /// A reminder's Mark Done, through the real handler (its own context, then
    /// `.habitDataChanged` on the default center, which this cache does not listen to: only its
    /// `didSave` observer and the merge after it see the write).
    func testANotificationActionHandlerWriteMatchesAFreshRecomputeAfterTheMerge() async throws {
        let walk = try habit("Walk", days: Array(-3...(-1)))
        XCTAssertEqual(cached(walk).currentStreak(), 3)
        let generation = cache.generation

        let calendar = self.calendar
        let handler = NotificationActionHandler(environment: .init(
            container: { [container] in container }, effects: noEffects, sync: { _ in },
            scheduleSnooze: { _, _ in }, now: { Date() }, calendar: { calendar }))
        let now = Date()
        let outcome = await handler.perform(route: .checkIn(habitID: walk.id, day: nil), delivered: now, responded: now)
        XCTAssertEqual(outcome, .checkedIn(day: todayKey))
        XCTAssertGreaterThan(cache.generation, generation, "the save dropped Walk's entry at once")
        await afterTheMerge()

        try assertMatchesTheStore(walk)
        XCTAssertTrue(cached(walk).isCompleted(on: day(0)))
        XCTAssertEqual(cached(walk).currentStreak(), 4)
    }

    // MARK: - The write path

    /// "The same render" (D3 trigger 1): a commit changes the cached answer before the next read,
    /// with no turn of the run loop in between — a check-in and then its un-check — and bumps
    /// `generation`, so every view reading the cache redraws. Also for a cache with no observers
    /// at all: the commit's own bump is enough, even for the un-check, which leaves the record
    /// count where it was.
    func testACommitChangesTheCachedValueBeforeTheNextRead() throws {
        let read = try habit("Read", days: Array(-5...(-1)))
        let bare = StatsCache()
        for cache in [self.cache!, bare] {
            XCTAssertFalse(cache.stats(for: read).isCompleted(on: day(0)))
            XCTAssertEqual(cache.stats(for: read).currentStreak(), 5)
        }
        let before = (cache.generation, bare.generation)

        for cache in [self.cache!, bare] {
            let checked = HabitEntryCommit.commit(habitID: read.id, day: day(0), in: context,
                                                  environment: commitEnvironment(bumping: cache)) { undo in
                HabitCheckIn.setChecked(true, on: self.day(0), of: read, in: self.context, undo: undo)
            }
            guard case .committed = checked else { return XCTFail("\(checked)") }
            XCTAssertTrue(cache.stats(for: read).isCompleted(on: day(0)))
            XCTAssertEqual(cache.stats(for: read).currentStreak(), 6)
            // The un-check leaves the deleted record listed in `read.records` (a ghost): the
            // count does not move, so only the bump (or the save's observer) can drop the entry.
            let unchecked = HabitEntryCommit.commit(habitID: read.id, day: day(0), in: context,
                                                    environment: commitEnvironment(bumping: cache)) { undo in
                HabitCheckIn.setChecked(false, on: self.day(0), of: read, in: self.context, undo: undo)
            }
            guard case .committed = unchecked else { return XCTFail("\(unchecked)") }
            XCTAssertFalse(cache.stats(for: read).isCompleted(on: day(0)))
            XCTAssertEqual(cache.stats(for: read).currentStreak(), 5)
        }
        XCTAssertGreaterThan(cache.generation, before.0)
        XCTAssertGreaterThan(bare.generation, before.1)
        try assertMatchesTheStore(read)
    }

    #if DEBUG
    /// A save that names one habit drops only that habit: the other cached habits are not rebuilt
    /// (per-habit invalidation, through the index of records the cache built from).
    func testASaveRebuildsOnlyTheHabitItChanged() throws {
        let read = try habit("Read", days: Array(-5...(-1)))
        let walk = try habit("Walk", days: Array(-5...(-1)))
        _ = cache.stats(for: [read, walk])
        let before = rebuilds

        // A check-in on Read (an insert: its habit is in the save as updated) ...
        HabitEntryCommit.commit(habitID: read.id, day: day(0), in: context,
                                environment: commitEnvironment(bumping: cache)) { undo in
            HabitCheckIn.setChecked(true, on: self.day(0), of: read, in: self.context, undo: undo)
        }
        _ = cache.stats(for: [read, walk])
        XCTAssertEqual(rebuilds - before, 1, "Read only")

        // ... and an edit of one of Walk's records (an update the index places).
        let edited = try XCTUnwrap(walk.records.first)
        edited.note = "after the rain"
        edited.touch()
        try context.save()
        _ = cache.stats(for: [read, walk])
        XCTAssertEqual(rebuilds - before, 2, "then Walk only")

        // A save to another store entirely (the host app's, another test's) drops nothing.
        let elsewhere = try ModelContainer(for: Schema([Habit.self, HabitRecord.self, HabitGroup.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let stranger = Habit(name: "Elsewhere")
        elsewhere.mainContext.insert(stranger)
        stranger.records = [HabitRecord(date: day(0))]
        try elsewhere.mainContext.save()
        _ = cache.stats(for: [read, walk])
        XCTAssertEqual(rebuilds - before, 2)
        try assertMatchesTheStore(read)
        try assertMatchesTheStore(walk)
    }
    #endif

    // MARK: - Another context's deletion

    /// A deletion saved by a second context — the widget's pattern in-process: this context still
    /// lists the record, which looks live here and is gone from the store. The save's deleted id
    /// maps to the habit, so the next read rebuilds without it, at once; the merge then drops it
    /// from the habit's `records`. Nothing reads the gone record's fields, so nothing faults.
    func testADeletionSavedByASecondContextInvalidates() async throws {
        let read = try habit("Read", days: Array(-3...0))
        XCTAssertTrue(cached(read).isCompleted(on: day(0)))
        XCTAssertEqual(cached(read).currentStreak(), 4)

        let id = read.id, today = day(0)
        let widget = ModelContext(container)
        let theirs = try XCTUnwrap(widget.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        for record in theirs.records where record.date == today { widget.delete(record) }
        try widget.save()

        XCTAssertEqual(read.records.count, 4, "before the merge this context still lists it")
        XCTAssertFalse(cached(read).isCompleted(on: day(0)), "dropped by the save, rebuilt from the store")
        XCTAssertEqual(cached(read).currentStreak(), 3)
        await afterTheMerge()
        XCTAssertEqual(read.records.count, 3, "the merge: the record left this context's habit")
        try assertMatchesTheStore(read)
    }

    // MARK: - The day and the zone

    #if DEBUG
    /// Midnight and a zone change drop every entry (and bump `generation`); a read for another day
    /// or in another zone rebuilds even without them (the fingerprint holds both).
    func testADayChangeAndATimeZoneChangeInvalidate() throws {
        let read = try habit("Read", days: Array(-3...(-1)))
        _ = cached(read)
        var count = rebuilds, generation = cache.generation

        events.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertGreaterThan(cache.generation, generation)
        _ = cached(read)
        XCTAssertEqual(rebuilds, count + 1, "the day change dropped it")
        _ = cached(read)
        XCTAssertEqual(rebuilds, count + 1, "then it is cached again")

        count = rebuilds; generation = cache.generation
        events.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertGreaterThan(cache.generation, generation)
        _ = cached(read)
        XCTAssertEqual(rebuilds, count + 1, "the zone change dropped it")

        count = rebuilds
        let tomorrow = Date().addingTimeInterval(86_400)
        XCTAssertEqual(cache.stats(for: read, today: tomorrow, calendar: calendar).today, day(1))
        XCTAssertEqual(rebuilds, count + 1, "another day is another entry")
        var elsewhere = Calendar(identifier: .gregorian)
        elsewhere.timeZone = TimeZone(identifier: calendar.timeZone.identifier == "Pacific/Kiritimati"
                                      ? "Pacific/Pago_Pago" : "Pacific/Kiritimati")!
        _ = cache.stats(for: read, today: Date(), calendar: elsewhere)
        XCTAssertEqual(rebuilds, count + 2, "another zone is another entry")
    }

    /// The app becoming active merges and rebuilds only when the store changed while it was not:
    /// an app switch with nothing written elsewhere rebuilds nothing.
    func testAnActivationRebuildsOnlyWhenTheStoreChangedWhileInactive() throws {
        let read = try habit("Read", days: Array(-3...(-1)))
        _ = cached(read)
        let count = rebuilds
        #if os(iOS)
        let resign = UIApplication.willResignActiveNotification, active = UIApplication.didBecomeActiveNotification
        #else
        let resign = NSApplication.willResignActiveNotification, active = NSApplication.didBecomeActiveNotification
        #endif

        events.post(name: resign, object: nil)
        events.post(name: active, object: nil)
        _ = cached(read)
        XCTAssertEqual(rebuilds, count, "nothing changed while inactive")

        events.post(name: resign, object: nil)
        let other = ModelContext(container)   // stands in for the widget's process
        let id = read.id
        let theirs = try XCTUnwrap(other.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(HabitCheckIn.tap(theirs, on: day(0), in: other), .init(isCompleted: true, loggedValue: 1))
        try other.save()
        events.post(name: active, object: nil)
        XCTAssertEqual(read.records.count, 4, "activation merged what was written meanwhile")
        XCTAssertTrue(cached(read).isCompleted(on: day(0)))
        try assertMatchesTheStore(read)
    }
    #endif

    // MARK: - Performance (Data safety 4, the hosted cache case)

    #if DEBUG
    /// A multi-chunk sync of a 50 × 1,095 account (54,750 entries) with Statistics alive: a reader
    /// re-reads every habit's stats once per main-queue turn whenever `generation` moves, as the
    /// tab's cards would, while the real engine pushes 6,000 local edits in 3 chunks (each
    /// acknowledged with its own save) and then pulls one other device's edit per habit. Counts
    /// the rebuilds the run caused: each save drops only the habits whose records it wrote, so a
    /// habit is rebuilt at most once per save that touched it and the reader saw — never 50 per
    /// save. Then the cache equals the store for every habit, and a warm read of all 50 costs what
    /// one render of the tab would. First measured 2026-10-15 (iPhone 17 simulator, Debug): the
    /// run 4.053 s with 50 rebuilds over its 4 saves (the engine does not yield between them, so
    /// the reader saw the end state), and a warm read 0.3 ms — 82.4 ms while the fingerprint still
    /// read every record (StatsCache's comment). Each time is bounded at 5× its first value.
    func testAMultiChunkSyncOfFiftyHabitsTimesThreeYearsRebuildsBoundedPerPull() async throws {
        let habitCount = 50, days = 1_095, edited = 120
        var habits: [Habit] = []
        let base = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-86_400 * 3))
        for h in 0..<habitCount {
            let habit = Habit(name: "Habit \(h)")
            habit.habitKind = .count
            habit.targetValue = 2
            habit.createdAt = base
            habit.updatedAt = base
            habit.sortOrder = Double(h)
            habit.adoptRemoteState()
            context.insert(habit)
            habit.records = (1...days).map { d in
                let record = HabitRecord(date: day(-d), value: 2)
                record.updatedAt = base.addingTimeInterval(Double(d) / 1_000)
                record.adoptRemoteState()
                return record
            }
            try context.save()
            habits.append(habit)
        }
        // This device's own edits of the last 120 days: 6,000 pending entries, 3 chunks of 2,000.
        for habit in habits {
            for record in habit.records where record.date >= day(-edited) {
                record.note = "edited here"
                record.touch()
            }
        }
        try context.save()

        // Another device's edit of one older day per habit, newer than anything here: below target.
        let theirDay = day(-200)
        let theirStamp = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(1))
        let pulled = habits.map { habit -> SyncEntry in
            let record = habit.records.first { $0.date == theirDay }!
            return SyncEntry(id: record.id.uuidString, habitId: habit.id.uuidString,
                             date: HabitCalendar.dayStringFormatter.string(from: theirDay), note: nil, value: 1,
                             createdAt: SyncWireStamp.string(from: theirDay), updatedAt: SyncWireStamp.string(from: theirStamp))
        }
        let transport = CannedTransport(pull: try PullBody(entries: pulled).encoded())
        let scratch = ScratchDefaults("statsCache.perf")
        defer { scratch.remove() }
        let binding = SyncRunBinding(ownerID: "1", token: "t", generation: 0)
        let cursors = SyncDefaultsCursorStore(defaults: scratch.defaults)
        cursors.setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400)), for: "1")
        let engine = SyncEngine(transport: transport, gate: ReadyGate(.ready(binding)), cursorStore: cursors,
                                deletionQueue: SyncDeletionQueue(local: scratch.defaults, shared: nil),
                                strikes: SyncUnknownHabitStrikes(defaults: scratch.defaults),
                                marks: SyncMarksProof(defaults: scratch.defaults),
                                recoveryLog: SyncMemoryRecoveryLog())

        // Statistics, alive: every card read once, then again on every turn `generation` moved.
        let reader = Reader(cache: cache, habits: habits)
        reader.read()
        let rebuiltBefore = rebuilds
        let saves = Counter()
        let counting = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context,
                                                              queue: nil) { _ in saves.value += 1 }
        let start = DispatchTime.now().uptimeNanoseconds
        let outcome = await engine.run(in: context)
        await afterTheMerge()
        reader.read()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        NotificationCenter.default.removeObserver(counting)
        reader.stop()

        guard case .synced(let summary) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(summary.pushes.count, 3, "6,000 entries at 2,000 a chunk")
        let rebuilt = rebuilds - rebuiltBefore
        print(String(format: "PERF stats cache alive through a 3-chunk sync + pull of 50x1095: %.3f s, %d rebuilds over %d saves (%.1f per habit), %d reads",
                     seconds, rebuilt, saves.value, Double(rebuilt) / Double(habitCount), reader.reads))
        XCTAssertGreaterThanOrEqual(rebuilt, habitCount, "the pull changed every habit")
        XCTAssertLessThanOrEqual(rebuilt, habitCount * 3, "each save drops only the habits it wrote")
        XCTAssertLessThan(seconds, 20.3, "5x the first measurement, 4.053 s (iPhone 17 simulator, Debug, 2026-10-15)")
        for habit in habits {
            XCTAssertFalse(cached(habit).isCompleted(on: theirDay), habit.name)
        }
        try assertMatchesTheStore(habits[0])
        try assertMatchesTheStore(habits[habitCount - 1])

        // A warm read of every habit: what one render of the Statistics tab costs once the cache
        // holds them, fingerprint checks included.
        let reads = 100
        let warm = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<reads { _ = cache.stats(for: habits) }
        let perRead = Double(DispatchTime.now().uptimeNanoseconds - warm) / 1e6 / Double(reads)
        print(String(format: "PERF stats cache warm read of 50x1095 (fingerprints checked): %.1f ms per read of all 50", perRead))
        XCTAssertEqual(rebuilds - rebuiltBefore, rebuilt, "warm reads rebuild nothing")
        XCTAssertLessThan(perRead, 1.5, "5x the first measurement, 0.3 ms")
    }
    #endif

    // MARK: - Perf harness

    private final class Counter: @unchecked Sendable { var value = 0 }

    /// Re-reads every habit's stats on the main-queue turn after `generation` moves, once per
    /// turn — what SwiftUI does for the views that read the cache.
    private final class Reader {
        let cache: StatsCache
        let habits: [Habit]
        private(set) var reads = 0
        private var scheduled = false
        private var stopped = false

        init(cache: StatsCache, habits: [Habit]) {
            self.cache = cache
            self.habits = habits
        }

        @MainActor func read() {
            guard !stopped else { return }
            scheduled = false
            reads += 1
            withObservationTracking {
                for stats in cache.stats(for: habits) { _ = stats.currentStreak() }
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.scheduled else { return }
                        self.scheduled = true
                        self.read()
                    }
                }
            }
        }

        func stop() { stopped = true }
    }

    private struct PullBody: Encodable {
        var habits: [SyncHabit] = []
        var entries: [SyncEntry]
        var groups: [SyncGroup] = []
        var deletedHabitIds: [String] = []
        var deletedEntryIds: [String] = []
        var deletedGroupIds: [String] = []
        var serverTime = SyncTimestamp.millisecondString(from: Date())

        func encoded() throws -> Data { try JSONEncoder().encode(self) }
    }

    /// Every push "all written", every pull the same body.
    @MainActor
    private final class CannedTransport: SyncTransport {
        let pull: Data
        init(pull: Data) { self.pull = pull }

        func push(body: Data, token: String) async -> SyncTransportResponse {
            SyncTransportResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }

        func pull(since: String?, deletionsSince: String?, token: String) async -> SyncTransportResponse {
            SyncTransportResponse(status: 200, body: pull)
        }
    }

    @MainActor
    private final class ReadyGate: SyncRunGate {
        let state: SyncGateState
        init(_ state: SyncGateState) { self.state = state }
        func current() -> SyncGateState { state }
    }
}
