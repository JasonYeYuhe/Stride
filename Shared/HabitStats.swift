import Foundation
import SwiftData

/// One habit's statistics, computed once from one snapshot of its records (RELEASE-1.4.1.md D2).
///
/// **Who builds one.** `Habit`'s aggregates (`currentStreak(from:)`, `bestStreak()`,
/// `weeklyCompletions`, both `completionRate` overloads, `completionsPerWeekday()`) build a fresh
/// one per call; the app's views read a cached one through `StatsCache` (D3); the widget builds
/// one per habit per timeline and answers both of its day-keys from it
/// (`WidgetTimelinePlan.rowInputs`); demo_check builds one per demo habit. `Habit`'s per-day
/// lookups (`record(on:)`, `loggedValue(on:)`, `progress(on:)`, `isCompletedOn`) never build one.
///
/// **What it fixes,** each named in a HabitStatsParityTests case (everything else is frozen by
/// golden values captured from the 1.4.0 methods first):
/// - ghosts are excluded by what the STORE holds (`liveRecordIDs(of:in:)`, or for one habit
///   `liveRecords(of:)`), not by `habit.records`: a deletion saved by another context or process
///   leaves a record that looks live there (HabitCheckIn.swift, `liveRecord`);
/// - `completionsPerWeekday` counts completed days, not every record;
/// - the rate starts at `startDay` = min(creation day, earliest live record) (D8);
/// - records dated after `today` are ignored;
/// - a day with several live records counts as its largest value, for completion and
///   `loggedValue` alike (2026-10-15 decision 7 keeps the record this reads).
///
/// **Shape.** The initializer makes one pass over the records and builds only the live
/// completed-day set and the values by day (plus, unless `readsNotesAndStamps` is off as in
/// `Habit.makeStats`, the noted days and the newest record stamp, in the same pass). Streaks,
/// ranges, the rate and the weekday counts are computed on first access; the strength series
/// only when a strength accessor is read, through `HabitScore` (D9). Every per-day question
/// reads the set — any as-of day is answered from it, never by rescanning records. Days are
/// held as whole days since 1970-01-01 (a day-key is UTC midnight, so the arithmetic is exact
/// and needs no `Calendar`).
///
/// Shared/ rules: a pure value — no `appLocalized`/`appCalendar` (the caller passes a
/// `Calendar`), no UIKit/AppKit, no user-facing text. It also compiles into the widget,
/// scripts/demo_check and scripts/sync_rehearsal, so no top-level name of theirs is used here.
/// It holds no model object after `init`, so it outlives the context that fetched the records;
/// the widget keeps none past its plan (Data safety 5).
final class HabitStats {
    /// One run of consecutive completed scheduled days (or, for times-per-week, met weeks).
    struct StreakRange: Equatable, Hashable {
        /// First day-key of the run: its first completed scheduled day, or for times-per-week
        /// the Monday of its first week.
        let start: Date
        /// Last day-key of the run: its last completed scheduled day, or for times-per-week the
        /// Sunday of its last week — the last completed day instead when that week is the
        /// current one (its Sunday has not happened).
        let end: Date
        /// In the habit's streak unit: scheduled days (rest days inside the run neither count
        /// nor break it), or weeks for times-per-week.
        let length: Int
        /// The run the current streak counts, including one kept open by the grace (today, or
        /// this week, not done yet).
        let isCurrent: Bool
    }

    // MARK: Inputs

    let kind: HabitKind
    let targetValue: Double
    let schedule: HabitSchedule
    let timesPerWeek: Int
    let activeDaysMask: Int
    let createdAt: Date
    /// The day-key of "today" the answers are relative to (the caller's `today`, keyed).
    let today: Date
    /// The user's calendar, for keying instants (Shared/ never reads `appCalendar`).
    let calendar: Calendar

    // MARK: Built in the initializer (D2)

    /// Day numbers whose live records complete the day (count habits: the day's largest value
    /// reaches the target). Nothing after `today`.
    private let completed: Set<Int>
    /// The largest live value logged on each day number. Nothing after `today`.
    private let values: [Int: Double]
    /// Days whose live records include a non-empty note (the widget's noted row, D7; the
    /// heatmap's note dot, D5). Nothing after `today`. Empty unless `readsNotesAndStamps`.
    private let noted: Set<Int>
    private let todayNumber: Int

    /// Whether the initializer read each live record's note and stamp: `hasNote(on:)` and
    /// `latestLiveRecordStamp` answer only then. `Habit`'s aggregate wrappers (`Habit.makeStats`)
    /// ask neither and skip both reads, which were about a quarter of every wrapper call.
    let readsNotesAndStamps: Bool

    /// Every live record counted, including any dated after `today` — StatsCache's fingerprint
    /// input (D3).
    let liveRecordCount: Int
    /// The newest `stamp` among the live records, including any dated after `today` — the other
    /// fingerprint input from the records (D3). Only when `readsNotesAndStamps`.
    var latestLiveRecordStamp: Date? {
        assert(readsNotesAndStamps, "built without stamps (Habit.makeStats): use a full HabitStats")
        return latestStamp
    }
    private let latestStamp: Date?

    /// Which of a habit's records count. Only the store decides what is live (D2): a deletion
    /// saved by another context or process leaves a record that looks live in `habit.records`.
    enum LiveRecords {
        /// The ids the store holds (`liveRecordIDs(of:in:)`, the widget's and StatsCache's).
        case ids(Set<UUID>)
        /// The store's answer by persistent identifier (`liveRecords(of:)`'s exact path).
        case persistentIDs(Set<PersistentIdentifier>)
        /// Every record that is neither deleted nor a ghost the context itself left (one with no
        /// context): the store was asked and holds them all (`liveRecords(of:)`'s usual answer).
        case attached
        /// Every record not deleted: the habit is in no context, so there is no store to ask.
        case all
    }

    /// - Parameters:
    ///   - records: the habit's records as loaded (may include ghosts).
    ///   - live: which of them count (`LiveRecords`).
    ///   - today: any instant of the day the answers are relative to; keyed with `calendar`.
    ///   - readsNotesAndStamps: also read each live record's note and stamp, for `hasNote(on:)`
    ///     and `latestLiveRecordStamp` (StatsCache's fingerprint and note dot, the widget's
    ///     noted row). Only `Habit.makeStats` turns it off.
    convenience init(records: [HabitRecord], live: LiveRecords, kind: HabitKind, targetValue: Double,
                     schedule: HabitSchedule, timesPerWeek: Int, activeDaysMask: Int, createdAt: Date,
                     calendar: Calendar, today: Date, readsNotesAndStamps: Bool = true) {
        let counts: (HabitRecord) -> Bool
        switch live {
        case .ids(let ids): counts = { !$0.isDeleted && ids.contains($0.id) }
        case .persistentIDs(let ids): counts = { !$0.isDeleted && ids.contains($0.persistentModelID) }
        case .attached: counts = { !$0.isDeleted && $0.modelContext != nil }
        case .all: counts = { !$0.isDeleted }
        }
        self.init(counting: records, where: counts, kind: kind, targetValue: targetValue, schedule: schedule,
                  timesPerWeek: timesPerWeek, activeDaysMask: activeDaysMask, createdAt: createdAt,
                  calendar: calendar, today: today, readsNotesAndStamps: readsNotesAndStamps)
    }

    /// The one pass. `counts` nil: every record passed is live (the caller has filtered them).
    private init(counting records: [HabitRecord], where counts: ((HabitRecord) -> Bool)?, kind: HabitKind,
                 targetValue: Double, schedule: HabitSchedule, timesPerWeek: Int, activeDaysMask: Int,
                 createdAt: Date, calendar: Calendar, today: Date, readsNotesAndStamps: Bool) {
        self.kind = kind
        self.targetValue = targetValue
        self.schedule = schedule
        self.timesPerWeek = timesPerWeek
        self.activeDaysMask = activeDaysMask
        self.createdAt = createdAt
        self.calendar = calendar
        self.readsNotesAndStamps = readsNotesAndStamps
        let todayNumber = Self.dayNumber(of: today, in: calendar)
        self.todayNumber = todayNumber
        self.today = Self.key(ofDay: todayNumber)

        var values: [Int: Double] = [:]
        values.reserveCapacity(records.count)
        var noted = Set<Int>()
        var count = 0
        var latest: Date?
        for record in records where counts?(record) ?? true {
            count += 1
            if readsNotesAndStamps {
                let stamp = record.stamp
                if latest.map({ stamp > $0 }) ?? true { latest = stamp }
            }
            let day = Self.dayNumber(ofKey: record.date)
            guard day <= todayNumber else { continue }
            let value = record.value
            if let existing = values[day] {
                if value > existing { values[day] = value }
            } else {
                values[day] = value
            }
            if readsNotesAndStamps, let note = record.note, !note.isEmpty { noted.insert(day) }
        }
        let completed: Set<Int>
        switch kind {
        case .binary:
            completed = Set(values.keys)
        case .count:
            let target = targetValue
            completed = target > 0 ? Set(values.lazy.filter { $0.value >= target }.map(\.key)) : []
        }
        self.values = values
        self.completed = completed
        self.noted = noted
        self.liveRecordCount = count
        self.latestStamp = latest
    }

    /// - Parameters:
    ///   - liveRecordIDs: the ids the store says are live (`liveRecordIDs(of:in:)`); only these
    ///     are counted.
    convenience init(records: [HabitRecord], liveRecordIDs: Set<UUID>, kind: HabitKind, targetValue: Double,
                     schedule: HabitSchedule, timesPerWeek: Int, activeDaysMask: Int, createdAt: Date,
                     calendar: Calendar, today: Date) {
        self.init(records: records, live: .ids(liveRecordIDs), kind: kind, targetValue: targetValue,
                  schedule: schedule, timesPerWeek: timesPerWeek, activeDaysMask: activeDaysMask,
                  createdAt: createdAt, calendar: calendar, today: today)
    }

    /// The habit's own fields, read once.
    convenience init(habit: Habit, live: LiveRecords, calendar: Calendar = .current, today: Date = Date(),
                     readsNotesAndStamps: Bool = true) {
        self.init(records: habit.records, live: live, kind: habit.habitKind,
                  targetValue: habit.targetValue, schedule: habit.schedule,
                  timesPerWeek: habit.timesPerWeek, activeDaysMask: habit.activeDaysMask,
                  createdAt: habit.createdAt, calendar: calendar, today: today,
                  readsNotesAndStamps: readsNotesAndStamps)
    }

    /// `Habit.makeStats`'s build, for the aggregates: the store asked once about this habit's
    /// records (`liveRecords(of:)`), the records it was asked about counted without being read
    /// again when it holds them all, and no note or stamp read (`readsNotesAndStamps` off).
    static func forAggregates(of habit: Habit, calendar: Calendar, today: Date) -> HabitStats {
        let (candidates, live) = liveAnswer(of: habit)
        let records: [HabitRecord], counts: ((HabitRecord) -> Bool)?
        switch live {
        case .attached:
            // The store holds every candidate, and a candidate is neither deleted nor a
            // same-context ghost: they are exactly the live records.
            records = candidates; counts = nil
        case .persistentIDs(let ids):
            records = candidates; counts = { ids.contains($0.persistentModelID) }
        case .all, .ids:
            return HabitStats(habit: habit, live: live, calendar: calendar, today: today, readsNotesAndStamps: false)
        }
        return HabitStats(counting: records, where: counts, kind: habit.habitKind, targetValue: habit.targetValue,
                          schedule: habit.schedule, timesPerWeek: habit.timesPerWeek,
                          activeDaysMask: habit.activeDaysMask, createdAt: habit.createdAt,
                          calendar: calendar, today: today, readsNotesAndStamps: false)
    }

    /// The habit's own fields, read once, counting `liveRecordIDs`.
    convenience init(habit: Habit, liveRecordIDs: Set<UUID>, calendar: Calendar = .current,
                     today: Date = Date()) {
        self.init(habit: habit, live: .ids(liveRecordIDs), calendar: calendar, today: today)
    }

    /// How many records one fetch asks for. SQLite caps a statement's bound variables (32,766 on
    /// current systems, 999 on old ones); a 50-habit, three-year store holds 54,750 records.
    /// Measured 2026-10-15 (macOS, Debug, 54,750 cold records): 900, 5,000, 20,000 and one
    /// 60,000-id query all took 0.83–1.0 s, so the small, safe size costs nothing.
    static let liveRecordFetchChunk = 900

    /// The candidates the store is asked about: not deleted, and not a ghost the context itself
    /// left behind (`modelContext == nil`), which is never live. By `persistentModelID`, which
    /// reading never faults.
    private static func candidates(of habits: [Habit]) -> [PersistentIdentifier] {
        var candidates: [PersistentIdentifier] = []
        for habit in habits {
            for record in habit.records where !record.isDeleted && record.modelContext != nil {
                candidates.append(record.persistentModelID)
            }
        }
        return candidates
    }

    private static func chunks(_ ids: [PersistentIdentifier]) -> [[PersistentIdentifier]] {
        stride(from: 0, to: ids.count, by: liveRecordFetchChunk).map {
            Array(ids[$0..<min($0 + liveRecordFetchChunk, ids.count)])
        }
    }

    /// The store's live records among `chunk`, fetched (rows loaded); nil when it cannot be asked.
    /// Pending changes are included (the default): a record appended but not yet saved counts,
    /// one deleted but not yet saved does not.
    private static func stored(_ chunk: [PersistentIdentifier], in context: ModelContext) -> [HabitRecord]? {
        try? context.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))
    }

    /// The ids of `habits`' records that the store holds as live (D2, D3): pending inserts
    /// count, pending deletes do not, and neither does a record another context or process
    /// deleted and saved — which still looks live in `habit.records` (HabitCheckIn.liveRecord).
    /// For many habits at once, or a store opened cold: StatsCache's invalidate-all rebuild, the
    /// widget's timeline (its own context), demo_check. One warm habit: `liveRecords(of:)`.
    ///
    /// It asks by `persistentModelID`, so no candidate's attributes are read before the store
    /// has answered, and the fetch loads the live records' rows in one query per
    /// `liveRecordFetchChunk`, which makes `HabitStats.init`'s reads of them cheap. Asking by
    /// `id` instead read every record one fault at a time first (measured 2026-10-15 on a cold
    /// 10 × 730 store: 0.68 s of single-row faults, against 0.01 s for a 730-record fetch).
    static func liveRecordIDs(of habits: [Habit], in context: ModelContext) -> Set<UUID> {
        let candidates = candidates(of: habits)
        var live = Set<UUID>(minimumCapacity: candidates.count)
        for chunk in chunks(candidates) {
            guard let stored = stored(chunk, in: context) else {
                // Cannot ask the store: the best local answer, which still skips a same-context
                // ghost (they never became candidates).
                let asked = Set(chunk)
                for habit in habits {
                    for record in habit.records where asked.contains(record.persistentModelID) {
                        live.insert(record.id)
                    }
                }
                continue
            }
            for record in stored { live.insert(record.id) }
        }
        return live
    }

    /// Which of ONE habit's records the store holds as live, as cheaply as the store can say:
    /// a count first — almost always every candidate is there, and `.attached` says so without
    /// reading any record — and only when the store holds fewer (a deletion saved by another
    /// context, not merged here), the exact set. `Habit`'s aggregate wrappers ask it once per
    /// call, through `forAggregates` (measured 2026-10-15, Debug, a warm 730-record habit: the
    /// count 0.9 ms, against 10 ms for `liveRecordIDs(of:in:)`'s fetch; about 1 ms at -O).
    static func liveRecords(of habit: Habit) -> LiveRecords {
        liveAnswer(of: habit).live
    }

    /// `liveRecords(of:)`'s answer, and the candidates it asked the store about (empty for `.all`).
    private static func liveAnswer(of habit: Habit) -> (candidates: [HabitRecord], live: LiveRecords) {
        guard let context = habit.modelContext else { return ([], .all) }
        let records = habit.records.filter { !$0.isDeleted && $0.modelContext != nil }
        let candidates = records.map(\.persistentModelID)
        let pieces = chunks(candidates)
        var held = 0
        for chunk in pieces {
            let descriptor = FetchDescriptor<HabitRecord>(predicate: #Predicate { chunk.contains($0.persistentModelID) })
            guard let n = try? context.fetchCount(descriptor) else { return (records, .attached) }   // the best local answer
            held += n
        }
        guard held < candidates.count else { return (records, .attached) }
        var live = Set<PersistentIdentifier>()
        for chunk in pieces {
            guard let stored = stored(chunk, in: context) else { live.formUnion(chunk); continue }
            for record in stored { live.insert(record.persistentModelID) }
        }
        return (records, .persistentIDs(live))
    }

    // MARK: Day numbers

    /// Whole days since 1970-01-01 of a stored record date: `HabitCalendar.startOfKey`'s day.
    static func dayNumber(ofKey key: Date) -> Int {
        Int((key.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// The day-key (UTC midnight) of a day number.
    static func key(ofDay day: Int) -> Date {
        Date(timeIntervalSince1970: Double(day) * 86_400)
    }

    /// The day number of `date` as `HabitCalendar.dayKey(for:localCalendar:)` keys it: a value
    /// that is already a day-key is kept, any other instant takes its local date in `calendar`.
    static func dayNumber(of date: Date, in calendar: Calendar) -> Int {
        let t = date.timeIntervalSince1970
        if t.truncatingRemainder(dividingBy: 86_400) == 0 { return Int(t / 86_400) }
        return dayNumber(ofKey: HabitCalendar.dayKey(for: date, localCalendar: calendar))
    }

    /// 1 = Sunday … 7 = Saturday, as `HabitCalendar.utc` numbers a day-key (1970-01-01 was a
    /// Thursday).
    static func weekday(ofDay day: Int) -> Int {
        ((day + 4) % 7 + 7) % 7 + 1
    }

    /// The Monday of the Monday-anchored week containing `day`.
    static func monday(ofWeekContaining day: Int) -> Int {
        day - (weekday(ofDay: day) + 5) % 7
    }

    /// Whether `day` is expected for a schedule: rest days of `specificDays` are not.
    static func isScheduled(day: Int, schedule: HabitSchedule, activeDaysMask: Int) -> Bool {
        switch schedule {
        case .daily, .timesPerWeek:
            return true
        case .specificDays:
            return (activeDaysMask & (1 << (weekday(ofDay: day) - 1))) != 0
        }
    }

    private func dayNumber(of date: Date) -> Int { Self.dayNumber(of: date, in: calendar) }

    private func isScheduled(_ day: Int) -> Bool {
        Self.isScheduled(day: day, schedule: schedule, activeDaysMask: activeDaysMask)
    }

    // MARK: Per-day answers (from the set; never a rescan)

    func isCompleted(on day: Date) -> Bool {
        completed.contains(dayNumber(of: day))
    }

    /// The day's largest live value; 0 when there is none (or the day is after `today`).
    func loggedValue(on day: Date) -> Double {
        values[dayNumber(of: day)] ?? 0
    }

    /// Progress toward the day's goal, 0…1, by `Habit.progress(on:)`'s rule.
    func progress(on day: Date) -> Double {
        let n = dayNumber(of: day)
        switch kind {
        case .binary:
            return completed.contains(n) ? 1 : 0
        case .count:
            let value = values[n] ?? 0
            guard targetValue > 0 else { return value > 0 ? 1 : 0 }
            return min(1, value / targetValue)
        }
    }

    /// Whether one of the day's live records carries a non-empty note. Only when
    /// `readsNotesAndStamps` (never from `Habit.makeStats`).
    func hasNote(on day: Date) -> Bool {
        assert(readsNotesAndStamps, "built without notes (Habit.makeStats): use a full HabitStats")
        return noted.contains(dayNumber(of: day))
    }

    /// Whether the habit is expected on `day` (`Habit.isScheduled(on:)`'s rule).
    func isScheduled(on day: Date) -> Bool {
        isScheduled(dayNumber(of: day))
    }

    /// The completed days as day-keys.
    private(set) lazy var completedDayKeys: Set<Date> = Set(completed.map(Self.key(ofDay:)))

    /// The largest live value of each day, by day-key.
    private(set) lazy var valuesByDay: [Date: Double] = Dictionary(
        uniqueKeysWithValues: values.map { (Self.key(ofDay: $0.key), $0.value) })

    /// Completed days in the inclusive range, clamped to `today`.
    func completedDayCount(from start: Date, to end: Date) -> Int {
        let first = dayNumber(of: start), last = min(dayNumber(of: end), todayNumber)
        guard first <= last else { return 0 }
        let range = first...last
        // Whichever is shorter: the range's days, or the completed days.
        guard range.count <= completed.count else { return completed.reduce(0) { $0 + (range.contains($1) ? 1 : 0) } }
        return range.reduce(0) { $0 + (completed.contains($1) ? 1 : 0) }
    }

    // MARK: Aggregates (computed on first access)

    private lazy var sortedCompleted: [Int] = completed.sorted()
    /// The earliest live record on a real day: from `HabitCalendar.firstRealDayNumber` (2025-01-01)
    /// on (X2). A key before it is one a build before 1.4.1 wrote on a non-Gregorian device — a
    /// Japanese-calendar phone's year 8 — not yet repaired (`DayKeyRepair`, at the next launch).
    /// Taken for the start, it made the strength walk start in year 8: about 737,000 days, some
    /// 18 MB of arrays per habit. Days after `today` are not in `values` at all.
    private lazy var earliestLiveDay: Int? = {
        let floor = HabitCalendar.firstRealDayNumber
        return values.keys.lazy.filter { $0 >= floor }.min()
    }()

    /// min(creation day, earliest live record on a real day), as a day number.
    private lazy var startDayNumber: Int = {
        let created = Self.dayNumber(of: createdAt, in: calendar)
        return earliestLiveDay.map { min(created, $0) } ?? created
    }()

    /// min(creation day, earliest live record on or after 2025-01-01): where the rate (D8), the
    /// strength walk (D9), Today's past-day filter (O11) and History's backdating window (D8)
    /// start.
    private(set) lazy var startDay: Date = Self.key(ofDay: startDayNumber)

    private var streakMemo: [Int: Int] = [:]

    /// The streak as of `day` (default: `today`), keeping the grace of 1.4.0's
    /// `Habit.currentStreak`: an unfinished day (or, for times-per-week, an unfinished week)
    /// does not break it. Days after `today` hold nothing, so a later `day` reads as unfinished.
    func currentStreak(asOf day: Date? = nil) -> Int {
        let n = day.map(dayNumber(of:)) ?? todayNumber
        if let known = streakMemo[n] { return known }
        let streak = schedule == .timesPerWeek ? weeklyStreak(asOf: n) : dailyStreak(asOf: n)
        streakMemo[n] = streak
        return streak
    }

    private func dailyStreak(asOf reference: Int) -> Int {
        guard let earliest = sortedCompleted.first else { return 0 }
        var day = reference
        // Grace: if the day isn't done yet, evaluate the streak ending the day before.
        if !completed.contains(day) { day -= 1 }
        var streak = 0
        while day >= earliest {
            if isScheduled(day) {
                guard completed.contains(day) else { break }  // a scheduled day missed ends it
                streak += 1
            }
            // rest days are skipped: they neither count nor break
            day -= 1
        }
        return streak
    }

    /// The streak a `HabitStats` built with `today: day` shows: `currentStreak(asOf: day)` with
    /// every record dated after `day` left out.
    ///
    /// The two differ only for times-per-week, and only when `day` is before `today`:
    /// `currentStreak(asOf:)` counts `day`'s whole week through `today`, as 1.4.0 counted a past
    /// as-of day's week through the real today (frozen by the parity goldens), so a check-in
    /// later in that week counts. The widget's "now" entry asks this of stats built through
    /// tomorrow (`WidgetTimelinePlan.lastDayKey`): a check-in dated tomorrow must not count today,
    /// just as the app's `Habit.currentStreak()` leaves it out.
    func currentStreak(asIfToday day: Date) -> Int {
        let n = dayNumber(of: day)
        guard schedule == .timesPerWeek, n < todayNumber else { return currentStreak(asOf: day) }
        return weeklyStreak(asOf: n, through: n)
    }

    /// - Parameter horizon: the last day whose completions count (the default: through `today`).
    private func weeklyStreak(asOf reference: Int, through horizon: Int = .max) -> Int {
        guard let earliest = sortedCompleted.first else { return 0 }
        let target = max(1, timesPerWeek)
        let earliestWeek = Self.monday(ofWeekContaining: earliest)
        var week = Self.monday(ofWeekContaining: reference)
        // Grace: the in-progress week not yet meeting the target doesn't break the streak.
        if completions(inWeekStarting: week, through: horizon) < target { week -= 7 }
        var streak = 0
        while week >= earliestWeek {
            guard completions(inWeekStarting: week, through: horizon) >= target else { break }
            streak += 1
            week -= 7
        }
        return streak
    }

    private func completions(inWeekStarting monday: Int, through horizon: Int = .max) -> Int {
        let last = min(monday + 6, horizon)
        guard monday <= last else { return 0 }
        return (monday...last).reduce(0) { $0 + (completed.contains($1) ? 1 : 0) }
    }

    /// Every run, oldest first, by the rules of `currentStreak`: scheduled days for daily and
    /// specific days, Monday-anchored met weeks for times-per-week.
    private lazy var runs: [StreakRange] = {
        guard let first = sortedCompleted.first, let last = sortedCompleted.last else { return [] }
        var found: [(start: Int, end: Int, length: Int)] = []
        if schedule == .timesPerWeek {
            let target = max(1, timesPerWeek)
            var runStart: Int?, runLength = 0, lastMet = 0
            var week = Self.monday(ofWeekContaining: first)
            let lastWeek = Self.monday(ofWeekContaining: last)
            while week <= lastWeek {
                if completions(inWeekStarting: week) >= target {
                    if runStart == nil { runStart = week }
                    runLength += 1
                    lastMet = week
                } else if let s = runStart {
                    found.append((s, lastMet + 6, runLength))
                    runStart = nil; runLength = 0
                }
                week += 7
            }
            if let s = runStart { found.append((s, lastMet + 6, runLength)) }
        } else {
            var runStart: Int?, runLength = 0, lastDone = 0
            for day in first...last where isScheduled(day) {
                if completed.contains(day) {
                    if runStart == nil { runStart = day }
                    runLength += 1
                    lastDone = day
                } else if let s = runStart {
                    found.append((s, lastDone, runLength))
                    runStart = nil; runLength = 0
                }
            }
            if let s = runStart { found.append((s, lastDone, runLength)) }
        }
        // The current streak's run is the most recent one, when there is a current streak.
        let current = currentStreak()
        let currentIndex = current > 0 ? found.indices.last : nil
        assert(currentIndex.map { found[$0].length == current } ?? true,
               "the newest run is not the current streak")
        return found.enumerated().map { index, run in
            // A met week that is still in progress ends at its last completed day, not a Sunday
            // that has not happened.
            let end = run.end > todayNumber ? (sortedCompleted.last ?? run.end) : run.end
            return StreakRange(start: Self.key(ofDay: run.start), end: Self.key(ofDay: end),
                               length: run.length, isCurrent: index == currentIndex)
        }
    }()

    /// The longest run; always `bestStreakRanges.first?.length ?? 0` (a parity rule).
    private(set) lazy var bestStreak: Int = bestStreakRanges.first?.length ?? 0

    /// The top 5 runs, dated, longest first, ties broken by the most recent. Times-per-week
    /// runs are Monday-anchored weeks; the current run is among them when it is long enough,
    /// marked `isCurrent`.
    private(set) lazy var bestStreakRanges: [StreakRange] = Array(runs.sorted {
        $0.length != $1.length ? $0.length > $1.length : $0.end > $1.end
    }.prefix(5))

    /// Completed days in the 7 days from `start` (`start` and the 6 days after it), as 1.4.0's
    /// `Habit.weeklyCompletions(weekStarting:)` counted them. Callers pass a Monday.
    func weeklyCompletions(weekStarting start: Date) -> Int {
        // 1.4.0 compared day-keys against `start` itself, unkeyed: [start, start + 6 d].
        let t = start.timeIntervalSince1970
        let first = Int((t / 86_400).rounded(.up))
        let last = Int(((t + 6 * 86_400) / 86_400).rounded(.down))
        guard first <= last else { return 0 }
        return (first...last).reduce(0) { $0 + (completed.contains($1) ? 1 : 0) }
    }

    /// Completed days in the Monday-anchored week containing `day`.
    func weeklyCompletions(containing day: Date) -> Int {
        completions(inWeekStarting: Self.monday(ofWeekContaining: dayNumber(of: day)))
    }

    /// The rate over the last `days` days ending `today`, from `startDay` at the earliest.
    func completionRate(days: Int = 30) -> Double {
        rate(from: todayNumber - (days - 1), to: todayNumber)
    }

    /// The rate over an inclusive range, clamped to `startDay` and to `today`; never above 1.
    ///
    /// - Daily and specific days: completed scheduled days ÷ scheduled days, so rest days don't
    ///   drag it down.
    /// - Times per week: for each Monday-anchored week the range touches, the share of the goal
    ///   that falls inside the range is expected, and the week's completions up to the end of the
    ///   range (from its Monday: the goal belongs to the week) are credited against it, capped at
    ///   that share. 1.4.0's `Habit.weeklyGoalRate` says why.
    func completionRate(from start: Date, to end: Date) -> Double {
        rate(from: dayNumber(of: start), to: dayNumber(of: end))
    }

    private func rate(from startNumber: Int, to endNumber: Int) -> Double {
        dueRate(from: startNumber, to: endNumber) ?? 0
    }

    /// `rate`'s answer, or nil when no day of the range is due: it lies wholly before `startDay` or
    /// after `today`, or (specific days) holds rest days only. `rate` reads that as 0.
    private func dueRate(from startNumber: Int, to endNumber: Int) -> Double? {
        let last = min(endNumber, todayNumber)
        let first = max(startNumber, startDayNumber)
        guard first <= last else { return nil }
        if schedule == .timesPerWeek { return min(1, weeklyGoalRate(from: first, to: last)) }
        var expected = 0, done = 0
        for day in first...last where isScheduled(day) {
            expected += 1
            if completed.contains(day) { done += 1 }
        }
        guard expected > 0 else { return nil }
        return min(1, Double(done) / Double(expected))
    }

    // MARK: Weeks as the Pro cards count them (2026-10-22)

    /// The last day the Pro cards' week rates and weekday tallies count: today once it is
    /// complete, yesterday until then — an unfinished today is not a miss yet. Insights' momentum,
    /// Weekly Review and the 8-week Trend counted it as one, so every Monday before the check-in a
    /// user who never misses read 0% and "Down vs last week (100% → 0%)" (churn investigation,
    /// 2026-10-22). The strength walk waits for today the same way (`todayIsComplete`).
    private var lastCountedDayNumber: Int {
        completed.contains(todayNumber) ? todayNumber : todayNumber - 1
    }

    /// The rate of the Monday-anchored week starting `monday` (a day-key) as the Pro cards show it:
    /// from `startDay`, through the last counted day. Nil when no day of it has come due — the
    /// habit had not started, or it is this week and nothing is due or done yet — which the cards
    /// show as nothing to count, never as a missed week: the Trend drew the weeks before a habit
    /// existed as grey bars marked 0, so a new Pro user's chart was mostly zeros.
    func countedRate(ofWeekStarting monday: Date) -> Double? {
        countedRate(ofWeekStartingDay: dayNumber(of: monday))
    }

    private func countedRate(ofWeekStartingDay monday: Int) -> Double? {
        dueRate(from: monday, to: min(monday + 6, lastCountedDayNumber))
    }

    /// This week so far (`countedRate(ofWeekStarting:)`): Insights' momentum, Weekly Review.
    var thisWeekRate: Double? { countedRate(ofWeekStartingDay: Self.monday(ofWeekContaining: todayNumber)) }

    /// Last week, all seven days of it (the last counted day is never before last Sunday).
    var lastWeekRate: Double? { countedRate(ofWeekStartingDay: Self.monday(ofWeekContaining: todayNumber) - 7) }

    /// Per weekday (1 = Sunday … 7 = Saturday): how many scheduled days there have been from
    /// `startDay` through the last counted day, and how many of them were completed. What
    /// Insights' strongest and toughest weekday compare (`StatsInsights.weekdayExtremes`) — as
    /// rates, where `completionsPerWeekday` (By Weekday's bars) counts every completed day. Only
    /// scheduled weekdays that have come due are present; empty for times-per-week, which has no
    /// weekday schedule.
    private(set) lazy var weekdayTallies: [Int: StatsInsights.WeekdayTally] = {
        guard schedule != .timesPerWeek else { return [:] }
        let first = startDayNumber, last = lastCountedDayNumber
        guard first <= last else { return [:] }
        let span = last - first + 1
        var due: [Int: Int] = [:]
        // The span's days at `offset`, `offset + 7`, …: (span − offset + 6) ÷ 7 of each weekday.
        for offset in 0..<min(7, span) where isScheduled(first + offset) {
            due[Self.weekday(ofDay: first + offset)] = (span - offset + 6) / 7
        }
        var done: [Int: Int] = [:]
        for day in completed where day >= first && day <= last && isScheduled(day) {
            done[Self.weekday(ofDay: day), default: 0] += 1
        }
        return due.reduce(into: [:]) { tallies, entry in
            tallies[entry.key] = StatsInsights.WeekdayTally(done: done[entry.key] ?? 0, due: entry.value)
        }
    }()

    private func weeklyGoalRate(from first: Int, to last: Int) -> Double {
        let goal = Double(max(1, timesPerWeek))
        var earned = 0.0, expected = 0.0
        var week = Self.monday(ofWeekContaining: first)
        while week <= last {
            let from = max(week, first), to = min(week + 6, last)
            let share = goal * Double(to - from + 1) / 7
            let done = Double((week...to).reduce(0) { $0 + (completed.contains($1) ? 1 : 0) })
            earned += min(done, share)
            expected += share
            week += 7
        }
        return expected > 0 ? earned / expected : 0
    }

    /// Completed days per weekday (1 = Sunday … 7 = Saturday).
    private(set) lazy var completionsPerWeekday: [Int: Int] = {
        var counts: [Int: Int] = [:]
        for day in completed { counts[Self.weekday(ofDay: day), default: 0] += 1 }
        return counts
    }()

    // MARK: Strength (D9; only when read)

    /// The strength walk, from `startDay` to today (or yesterday, until today is complete).
    private(set) lazy var strengthSeries: HabitScore.Series = HabitScore.series(
        completedDays: completed, valuesByDay: values, kind: kind, targetValue: targetValue,
        schedule: schedule, timesPerWeek: timesPerWeek, activeDaysMask: activeDaysMask,
        startDay: startDayNumber, today: todayNumber, todayIsComplete: completed.contains(todayNumber))

    /// Today's strength, 0…1 (shown 0–100 via `HabitScore.displayValue`).
    private(set) lazy var strength: Double = strengthSeries.current

    /// The change in strength over the last 30 / 90 days, in score units (−1…1).
    private(set) lazy var strengthDelta30: Double = strengthSeries.delta(days: 30)
    private(set) lazy var strengthDelta90: Double = strengthSeries.delta(days: 90)

    /// Weekly-bucketed strength for StrengthCard's bars (D10), the 8 Monday-anchored weeks
    /// ending with this one (as the 8-week Trend), oldest first. `strengthSeries.weekly(weeks:)`
    /// gives any other count.
    private(set) lazy var weeklyStrength: [Double] = strengthSeries.weekly(weeks: 8)
}
