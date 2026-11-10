import Foundation
import Observation
import SwiftData
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The app's per-habit `HabitStats`, rebuilt only when a habit's records change
/// (RELEASE-1.4.1.md D3). App only: the widget, a separate process with no app `didSave`, gets no
/// cache — it builds one `HabitStats` per habit per timeline (`WidgetTimelinePlan.rowInputs`).
///
/// **Readers (W3, W4)** call `stats(for: habit)` — or `stats(for: habits)` with every habit a view
/// shows, which refills all the stale ones with ONE store fetch — and read everything from the
/// `HabitStats` returned: the detail card's tiles, `HeatmapGrid.dayCell` (the cached
/// `HabitStats` passed into HeatmapView and HeatmapGrid), OverallStatsCard, Today's
/// `completedCount` (`completedCount(of:on:today:)`) and the row streaks. Any as-of day is
/// answered from the one cached set (`currentStreak(asOf:)`, `isCompleted(on:)`), so Today on a
/// past day reads the same entry. Today's row check and count state is NOT a reader: it is
/// derived from the habit (D4). Never hold a returned `HabitStats` across renders; ask again.
///
/// **Observation.** Views depend on `generation`, which every accessor reads, and — through the
/// fingerprint check — on `habit.records` and the habit's own fields. The entries themselves
/// are `@ObservationIgnored`: an accessor fills them during a render, which must never write
/// observed state. Only invalidation bumps `generation`, and only when it dropped an entry, and
/// it runs from the write path, notifications and the main queue — never from a render.
///
/// **An entry** is a `HabitStats` plus the `Fingerprint` it was built at, checked on every read:
/// the habit's fields (stamp, kind, target, schedule, creation), how many records `habit.records`
/// lists, the day-key of `today` and the calendar's zone. Each of those is one read, so a read of
/// a cached habit costs the same whatever its history. The check reads no record: measured
/// 2026-10-15 on 50 × 1,095 records (hosted, Debug simulator), a check that also hashed every
/// record's identifier and took the newest stamp made one warm read of all 50 habits 82 ms
/// (macOS -O: 16 ms for the attached/deleted test, 9 ms for the identifiers, 38 ms for the
/// stamps, against 0.1 ms for the count and the habit's fields). What it would have caught — a
/// record edited in place, or one replaced by another — reaches the cache through the triggers
/// below instead: every such change is a save, and every save is mapped (2), merged (3) or
/// bumped (1).
///
/// A rebuild asks the store once which records are live (one fetch per
/// `HabitStats.liveRecordFetchChunk` of every stale habit's records, by persistent identifier), so
/// a deletion another context saved — a record that still looks live in `habit.records` — is never
/// counted, and never read (W1, "Crash safety"): a record's attributes are read only once the store
/// has vouched for it. The same fetch refreshes, in this context, the records another context
/// saved since this one loaded them.
///
/// **Invalidation.** A `didSave` whose inserted, updated and deleted identifiers map cheaply to
/// cached habits — through the index of the records and habits this cache has built from — drops
/// only those habits; anything it cannot map clears everything. Stats refill lazily, on the next
/// read. The triggers:
/// 1. synchronously, from the write path (`HabitEntryCommit` step 4, `bump(habitID:)`): what "the
///    same render" needs;
/// 2. every `ModelContext.didSave` in the process, unthrottled — one observer for the process,
///    installed by `StrideApp.init` on both platforms, not by a window, so scene-less saves (a
///    reminder's Mark Done in a background launch, Siri) count;
/// 3. for a save by any context other than the one the cached habits live in (mainContext), one
///    main-queue turn later, the merge: the affected habits are fetched again in the cache's own
///    context, which is what makes their `records` drop a record the other context deleted and
///    list one it inserted (measured 2026-10-15: a ModelContext takes in neither on its own, and
///    a fetch of the habit does both), then they are dropped again;
/// 4. `.habitDataChanged` (NotificationActionHandler, StrideShortcuts): every habit, merged;
/// 5. `NSCalendarDayChanged` and `NSSystemTimeZoneDidChange`: everything dropped (the fingerprint
///    also checks the day and the zone it was built for);
/// 6. the app becoming active, for the widget's writes (another process: no `didSave` reaches
///    this one): every habit merged and dropped — but only when the store changed while the app
///    was inactive (`StoreSignature`, taken when it resigns active), so an app switch on a
///    three-year account does not rebuild every visible habit for nothing.
@Observable
@MainActor
final class StatsCache {
    /// The process's one cache, which the app's views read and `HabitEntryCommit` bumps. Hosted
    /// tests make their own and install observers on it (`installObservers(events:)`).
    static let shared = StatsCache()

    /// What an entry was built from; a mismatch at read time rebuilds it.
    struct Fingerprint: Equatable {
        /// `habit.records.count`, ghosts included: one read, whatever the history (an insert
        /// moves it; a merge that drops a ghost moves it).
        var recordCount: Int
        var habitStamp: Date
        var createdAt: Date
        var kind: String
        var targetValue: Double
        var scheduleKind: String
        var timesPerWeek: Int
        var activeDaysMask: Int
        /// The day-key the entry's answers are relative to.
        var todayKey: Date
        var timeZoneID: String
    }

    private struct Entry {
        let stats: HabitStats
        let fingerprint: Fingerprint
    }

    /// Bumped by every invalidation that dropped an entry. Every accessor reads it, so views
    /// depend on it and on nothing else here.
    private(set) var generation = 0

    /// Not observed: written during render, when an entry is rebuilt.
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    /// The index a `didSave` is mapped through: every record and habit an entry was built from.
    /// Only grows (a record never moves to another habit), so a later deletion still maps.
    @ObservationIgnored private var habitOfRecord: [PersistentIdentifier: UUID] = [:]
    @ObservationIgnored private var habitOfModel: [PersistentIdentifier: UUID] = [:]
    /// The stores the cached habits live in: a save to any other (a hosted test's in-memory
    /// container, seen by the host app's cache) is none of this cache's business.
    @ObservationIgnored private var stores: Set<String> = []
    /// The context the cached habits live in (the app's mainContext).
    @ObservationIgnored private weak var context: ModelContext?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Taken when the app resigns active: nil until it has, `.some(nil)` when the store could
    /// not be read then.
    @ObservationIgnored private var signatureAtResign: StoreSignature??

    #if DEBUG
    /// How many entries were (re)built: what the hosted tests count.
    @ObservationIgnored private(set) var rebuildCount = 0
    #endif

    init() {}

    // MARK: - Readers

    /// The habit's stats as of `today`, from the cache when its fingerprint still matches.
    func stats(for habit: Habit, today: Date = Date(), calendar: Calendar = .current) -> HabitStats {
        stats(for: [habit], today: today, calendar: calendar)[0]
    }

    /// Every habit's stats as of `today`, in order: what a list (OverallStatsCard, Today's rows)
    /// asks, so that refilling after a clear-all is ONE store fetch for all of them.
    func stats(for habits: [Habit], today: Date = Date(), calendar: Calendar = .current) -> [HabitStats] {
        _ = generation
        let todayKey = HabitStats.key(ofDay: HabitStats.dayNumber(of: today, in: calendar))
        var result = [HabitStats?](repeating: nil, count: habits.count)
        var stale: [Stale] = []
        for (index, habit) in habits.enumerated() {
            guard let habitContext = habit.modelContext, !habit.isDeleted else {
                // Not in a store (a preview, a habit being deleted): nothing to cache or ask.
                result[index] = HabitStats(habit: habit, live: .all, calendar: calendar, today: today)
                continue
            }
            if habitContext === context, let entry = entries[habit.id],
               Self.isCurrent(entry, habit: habit, todayKey: todayKey, calendar: calendar) {
                result[index] = entry.stats
            } else {
                stale.append(Stale(index: index, habit: habit, records: habit.records, context: habitContext))
            }
        }
        if !stale.isEmpty { rebuild(stale, today: today, calendar: calendar, into: &result) }
        return result.map { $0! }
    }

    /// How many of `habits` are complete on `day` (Today's header and progress card): read from
    /// the cached sets, any day.
    func completedCount(of habits: [Habit], on day: Date, today: Date = Date(),
                        calendar: Calendar = .current) -> Int {
        let key = HabitStats.key(ofDay: HabitStats.dayNumber(of: day, in: calendar))
        return stats(for: habits, today: today, calendar: calendar).filter { $0.isCompleted(on: key) }.count
    }

    // MARK: - Invalidation

    /// Synchronous invalidation from the write path (trigger 1): `habitID`, or everything.
    func bump(habitID: UUID? = nil) {
        if let habitID { invalidate(habitIDs: [habitID]) } else { invalidateAll() }
    }

    /// Drops the entries for `habitIDs`.
    func invalidate(habitIDs: Set<UUID>) {
        var dropped = false
        for id in habitIDs where entries.removeValue(forKey: id) != nil { dropped = true }
        if dropped { generation &+= 1 }
    }

    /// Drops every entry.
    func invalidateAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    // MARK: - Observers

    /// Installs triggers 2–6 for this cache, once: `StrideApp.init`, on both platforms, for the
    /// process. `events` carries everything but `didSave` (always the default center, where
    /// SwiftData posts it): the hosted tests post day, zone and activation changes on a center of
    /// their own instead of the host app's.
    func installObservers(events: NotificationCenter = .default) {
        guard observers.isEmpty else { return }
        // Trigger 2: every save, on whatever thread it was made. Read the notification there; act
        // on the main actor — at once when the save was made on it (mainContext's, HabitEntryCommit
        // included), so the next render already reads the new state.
        observers.append((.default, NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                                           queue: nil) { [weak self] note in
            let saved = SavedIdentifiers(note)
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let deliver: () -> Void = { MainActor.assumeIsolated { self?.didSave(saved, sender: sender) } }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }))
        // The rest act on the main actor: at once when posted there (the activation pair is), else
        // on the next turn (the day and zone changes are posted on no particular thread).
        func onMain(_ name: Notification.Name, _ body: @escaping @MainActor (StatsCache) -> Void) {
            observers.append((events, events.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                let deliver: () -> Void = { MainActor.assumeIsolated { if let self { body(self) } } }
                if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
            }))
        }
        // Trigger 4: Siri's and a reminder's check-ins, saved in their own contexts.
        onMain(.habitDataChanged) { $0.merge(.all) }
        // Trigger 5: the day and the zone every answer is relative to.
        onMain(.NSCalendarDayChanged) { $0.invalidateAll() }
        onMain(.NSSystemTimeZoneDidChange) { $0.invalidateAll() }
        // Trigger 6: the widget writes in another process, while the app is not active.
        #if os(iOS)
        let resign = UIApplication.willResignActiveNotification
        let activate = UIApplication.didBecomeActiveNotification
        #else
        let resign = NSApplication.willResignActiveNotification
        let activate = NSApplication.didBecomeActiveNotification
        #endif
        onMain(resign) { $0.signatureAtResign = .some($0.storeSignature()) }
        onMain(activate) { $0.becameActive() }
    }

    /// Removes this cache's observers (hosted tests' tearDown).
    func removeObservers() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }

    // MARK: - Building

    private struct Stale {
        let index: Int
        let habit: Habit
        let records: [HabitRecord]
        let context: ModelContext
    }

    /// The records a rebuild asks the store about: attached and not deleted (a ghost this context
    /// left has no context). Reading these two never faults.
    private static func isCandidate(_ record: HabitRecord) -> Bool {
        !record.isDeleted && record.modelContext != nil
    }

    /// One read per field, none per record (the type's comment says why).
    private static func isCurrent(_ entry: Entry, habit: Habit, todayKey: Date, calendar: Calendar) -> Bool {
        let f = entry.fingerprint
        return f.todayKey == todayKey && f.timeZoneID == calendar.timeZone.identifier
            && f.habitStamp == habit.stamp && f.createdAt == habit.createdAt && f.kind == habit.kind
            && f.targetValue == habit.targetValue && f.scheduleKind == habit.scheduleKind
            && f.timesPerWeek == habit.timesPerWeek && f.activeDaysMask == habit.activeDaysMask
            && f.recordCount == habit.records.count
    }

    private func rebuild(_ stale: [Stale], today: Date, calendar: Calendar, into result: inout [HabitStats?]) {
        // One context per fetch; in the app there is only mainContext.
        var groups: [ObjectIdentifier: [Stale]] = [:]
        var order: [ObjectIdentifier] = []
        for item in stale {
            let key = ObjectIdentifier(item.context)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        for key in order {
            guard let group = groups[key], let groupContext = group.first?.context else { continue }
            if groupContext !== context {
                // A habit from another context (a second container, a test): the cache follows it.
                entries.removeAll()
                context = groupContext
            }
            var candidates: [PersistentIdentifier] = []
            for item in group {
                for record in item.records where Self.isCandidate(record) { candidates.append(record.persistentModelID) }
            }
            let live = Self.storeHeld(candidates, in: groupContext)
            let todayKey = HabitStats.key(ofDay: HabitStats.dayNumber(of: today, in: calendar))
            for item in group {
                let habit = item.habit
                let stats = HabitStats(records: item.records, live: .persistentIDs(live), kind: habit.habitKind,
                                       targetValue: habit.targetValue, schedule: habit.schedule,
                                       timesPerWeek: habit.timesPerWeek, activeDaysMask: habit.activeDaysMask,
                                       createdAt: habit.createdAt, calendar: calendar, today: today)
                for record in item.records where Self.isCandidate(record) {
                    habitOfRecord[record.persistentModelID] = habit.id
                }
                let habitModel = habit.persistentModelID
                habitOfModel[habitModel] = habit.id
                if let store = habitModel.storeIdentifier { stores.insert(store) }
                let fingerprint = Fingerprint(
                    recordCount: item.records.count, habitStamp: habit.stamp, createdAt: habit.createdAt, kind: habit.kind,
                    targetValue: habit.targetValue, scheduleKind: habit.scheduleKind,
                    timesPerWeek: habit.timesPerWeek, activeDaysMask: habit.activeDaysMask,
                    todayKey: todayKey, timeZoneID: calendar.timeZone.identifier)
                entries[habit.id] = Entry(stats: stats, fingerprint: fingerprint)
                result[item.index] = stats
                #if DEBUG
                rebuildCount += 1
                #endif
            }
        }
    }

    /// Which of `candidates` the store holds, fetched — the rows loaded in one query per chunk, so
    /// `HabitStats`' reads of them are cheap, and any this context held stale (another context
    /// saved them since) are refreshed. A chunk the store cannot be asked about counts as held:
    /// the best local answer (`HabitStats.liveRecordIDs` does the same).
    private static func storeHeld(_ candidates: [PersistentIdentifier], in context: ModelContext) -> Set<PersistentIdentifier> {
        var held = Set<PersistentIdentifier>(minimumCapacity: candidates.count)
        let size = HabitStats.liveRecordFetchChunk
        for start in stride(from: 0, to: candidates.count, by: size) {
            let chunk = Array(candidates[start..<min(start + size, candidates.count)])
            let descriptor = FetchDescriptor<HabitRecord>(predicate: #Predicate { chunk.contains($0.persistentModelID) })
            guard let stored = try? context.fetch(descriptor) else {
                held.formUnion(chunk)
                continue
            }
            for record in stored { held.insert(record.persistentModelID) }
        }
        return held
    }

    // MARK: - Saves

    /// A `didSave`'s identifiers, read on the thread that posted it.
    struct SavedIdentifiers: @unchecked Sendable {
        var inserted: [PersistentIdentifier] = []
        var updated: [PersistentIdentifier] = []
        var deleted: [PersistentIdentifier] = []
        /// The save named no identifiers it changed (or said everything was invalidated): only
        /// a clear-all is safe.
        var unspecified = false

        init(_ note: Notification) {
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier]? {
                note.userInfo?[key.rawValue] as? [PersistentIdentifier]
            }
            let inserted = ids(.insertedIdentifiers), updated = ids(.updatedIdentifiers)
            let deleted = ids(.deletedIdentifiers)
            if note.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] != nil
                || (inserted == nil && updated == nil && deleted == nil) {
                unspecified = true
            }
            self.inserted = inserted ?? []
            self.updated = updated ?? []
            self.deleted = deleted ?? []
        }

        init(inserted: [PersistentIdentifier] = [], updated: [PersistentIdentifier] = [],
             deleted: [PersistentIdentifier] = []) {
            self.inserted = inserted
            self.updated = updated
            self.deleted = deleted
        }
    }

    /// What a save changed, as far as this cache can tell.
    enum Affected: Equatable {
        case nothing
        case habits(Set<UUID>)
        case all
    }

    /// A persistent identifier's `entityName`: the model's class name (Shared/Habit.swift names no
    /// entity otherwise; `Schema.entityName(for:)` would say the same, from iOS 18).
    private static let habitEntity = String(describing: Habit.self)
    private static let recordEntity = String(describing: HabitRecord.self)
    private static let groupEntity = String(describing: HabitGroup.self)

    /// The habits a save changed, through the index: a record's habit by the record, a habit by
    /// itself. A record this cache has never seen is mapped only when it was inserted — an insert
    /// changes its habit's `records`, so the habit is in the save as updated (no inverse
    /// relationship: a record cannot be asked for its habit) — and an insert with no habit beside
    /// it, or any other record or entity it cannot place, clears everything. Groups never matter.
    func affected(by saved: SavedIdentifiers) -> Affected {
        guard !stores.isEmpty else { return .nothing }
        func ours(_ id: PersistentIdentifier) -> Bool { id.storeIdentifier.map(stores.contains) ?? false }
        if saved.unspecified { return .all }
        var habits = Set<UUID>()
        var habitInSave = false, unplacedInsert = false
        func place(_ id: PersistentIdentifier, inserted: Bool) -> Bool {
            switch id.entityName {
            case Self.groupEntity:
                return true
            case Self.habitEntity:
                habitInSave = true
                if let habit = habitOfModel[id] { habits.insert(habit) }
                return true
            case Self.recordEntity:
                if let habit = habitOfRecord[id] { habits.insert(habit); return true }
                if inserted { unplacedInsert = true; return true }
                return false
            default:
                return false
            }
        }
        for id in saved.inserted where ours(id) { guard place(id, inserted: true) else { return .all } }
        for id in saved.updated where ours(id) { guard place(id, inserted: false) else { return .all } }
        for id in saved.deleted where ours(id) { guard place(id, inserted: false) else { return .all } }
        if unplacedInsert, !habitInSave { return .all }
        return habits.isEmpty ? .nothing : .habits(habits)
    }

    private func didSave(_ saved: SavedIdentifiers, sender: ObjectIdentifier?) {
        let affected = affected(by: saved)
        apply(affected)
        guard affected != .nothing else { return }
        let fromCachedContext = sender != nil && context.map(ObjectIdentifier.init) == sender
        guard !fromCachedContext else { return }
        // Trigger 3: another context's save, once this turn — and whatever merge of it is already
        // queued — has run: the habits fetched again, so their `records` are what the store holds.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.merge(affected) }
            }
        }
    }

    private func apply(_ affected: Affected) {
        switch affected {
        case .nothing: break
        case .habits(let ids): invalidate(habitIDs: ids)
        case .all: invalidateAll()
        }
    }

    /// The merge another context's save needs here: the affected cached habits (or every one
    /// this cache knows) fetched again in the cache's context — a fetch of a habit refreshes its
    /// `records` from the store — then dropped. Never during a render: from the main queue or a
    /// notification.
    func merge(_ affected: Affected) {
        guard affected != .nothing else { return }
        if let context {
            let models: [PersistentIdentifier]
            switch affected {
            case .nothing: models = []
            case .all: models = Array(habitOfModel.keys)
            case .habits(let ids): models = habitOfModel.filter { ids.contains($0.value) }.map(\.key)
            }
            let size = HabitStats.liveRecordFetchChunk
            for start in stride(from: 0, to: models.count, by: size) {
                let chunk = Array(models[start..<min(start + size, models.count)])
                _ = try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))
            }
        }
        apply(affected)
    }

    // MARK: - Activation (the widget's writes)

    /// What the store holds, in four numbers: enough to tell that another process wrote while
    /// the app was inactive. The widget's toggle inserts or deletes a record, and its count tap
    /// moves a record's stamp to now; every record written here is stamped `SyncTimestamp.now()`.
    struct StoreSignature: Equatable {
        var records: Int
        var newestRecord: Date?
        var habits: Int
        var newestHabit: Date?
    }

    func storeSignature() -> StoreSignature? {
        guard let context else { return nil }
        var record = FetchDescriptor<HabitRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        record.fetchLimit = 1
        var habit = FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        habit.fetchLimit = 1
        guard let records = try? context.fetchCount(FetchDescriptor<HabitRecord>()),
              let habits = try? context.fetchCount(FetchDescriptor<Habit>()),
              let newestRecords = try? context.fetch(record),
              let newestHabits = try? context.fetch(habit)
        else { return nil }
        return StoreSignature(records: records, newestRecord: newestRecords.first?.updatedAt,
                              habits: habits, newestHabit: newestHabits.first?.updatedAt)
    }

    private func becameActive() {
        // Not inactive since this cache was built (the launch's own activation), or nothing ever
        // built: nothing can have been written elsewhere that it holds.
        guard !habitOfModel.isEmpty, let before = signatureAtResign else { return }
        signatureAtResign = nil
        // Unchanged: nothing to do. Unreadable, then or now: assume it changed.
        if let before, let now = storeSignature(), before == now { return }
        merge(.all)
    }
}
