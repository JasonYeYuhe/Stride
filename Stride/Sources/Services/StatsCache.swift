import Foundation
import Observation
import SwiftData

/// The app's per-habit `HabitStats`, rebuilt only when a habit's records change
/// (RELEASE-1.4.1.md D3). App only: the widget, a separate process with no app `didSave`, gets
/// no cache (it builds one `HabitStats` per habit per timeline). **Owner: W2.** Scaffolded by
/// W0: `stats(for:)` builds a fresh, neutral `HabitStats` every time, caches nothing, and
/// nothing calls it yet.
///
/// TODO(W2): implement D3.
/// - Each entry holds a `HabitStats` and the `Fingerprint` it was built at; the accessor checks
///   the fingerprint, and reading it keeps the Observation dependency on `habit.records`, so a
///   merge both redraws and invalidates.
/// - A rebuild makes one store fetch of live record ids (`HabitStats.liveRecordIDs`, D2).
/// - Invalidation: a `didSave` whose inserted/updated/deleted ids map cheaply to habits
///   invalidates only those; otherwise everything. Stats refill lazily. Triggers:
///   1. synchronously in the write path (`HabitEntryCommit`, step 4: `bump()`);
///   2. an unthrottled, process-level `ModelContext.didSave` observer installed in
///      `StrideApp.init` on both platforms (not on a window: scene-less saves count);
///   3. one main-queue turn after a `didSave` whose object is not mainContext, after the merge;
///   4. `.habitDataChanged` (NotificationActionHandler, StrideShortcuts);
///   5. `NSCalendarDayChanged` and `NSSystemTimeZoneDidChange`;
///   6. scene activation, which covers widget writes.
/// - Readers: the detail card, `HeatmapGrid.dayCell` (the cached `HabitStats` passed into
///   HeatmapView/HeatmapGrid), OverallStatsCard, `TodayView.completedCount` and the row streaks.
///   Today's row check and count state is NOT a reader: it is derived from the habit (D4).
@Observable
@MainActor
final class StatsCache {
    // TODO(W2): or injected through the environment; one per process either way (trigger 2).
    static let shared = StatsCache()

    /// What an entry was built from; a mismatch at read time rebuilds it.
    struct Fingerprint: Equatable {
        var liveRecordCount: Int
        var maxRecordStamp: Date?
        var habitStamp: Date
        var kind: String
        var targetValue: Double
        var scheduleKind: String
        var timesPerWeek: Int
        var activeDaysMask: Int
    }

    private struct Entry {
        let stats: HabitStats
        let fingerprint: Fingerprint
    }

    /// Bumped by every invalidation. Every accessor reads it, so views depend on it and on
    /// nothing else here.
    private(set) var generation = 0

    /// Not observed: it is written during render, when an entry is rebuilt.
    @ObservationIgnored private var entries: [UUID: Entry] = [:]

    init() {}

    /// The habit's stats as of `today`, from the cache when its fingerprint still matches.
    func stats(for habit: Habit, today: Date = Date()) -> HabitStats {
        _ = generation
        // TODO(W2): fingerprint check, one live-id fetch per rebuild, store the entry.
        return HabitStats(habit: habit, liveRecordIDs: [], today: today)
    }

    /// Synchronous invalidation from the write path (D3 trigger 1).
    func bump(habitID: UUID? = nil) {
        // TODO(W2): invalidate `habitID` (or everything), then `generation += 1`.
    }

    /// Drops the entries for `habitIDs`.
    func invalidate(habitIDs: Set<UUID>) {
        // TODO(W2)
    }

    /// Drops every entry.
    func invalidateAll() {
        // TODO(W2)
    }

    /// Installs triggers 2–5 for the process, once (`StrideApp.init`, both platforms).
    func installObservers() {
        // TODO(W2)
    }
}
