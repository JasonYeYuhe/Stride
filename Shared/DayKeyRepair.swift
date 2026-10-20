import Foundation
import SwiftData
import os.log

// X2 (RELEASE-1.4.1.md W10; docs/X2-non-gregorian-day-keys.md, sections 1, 2 and 5): the day-keys
// builds 1.2.0–1.4.0 wrote on a device whose calendar is not Gregorian, read back to their real
// days and put there. Pure Shared/ code — no `appCalendar`, no UIKit/AppKit, no user-facing text —
// so StrideTests and scripts/sync_rehearsal.sh run exactly what the app runs.

// MARK: - Reading an old key back

/// Reads a key a build before 1.4.1 wrote back to its real day.
///
/// **What those builds wrote.** `HabitCalendar.dayKey` took the year, month and day of the moment
/// in the DEVICE's calendar and wrote them as a Gregorian date: 2026-10-15 became 0008-10-15 on a
/// Japanese-calendar phone (Reiwa 8), 2569-10-15 on a Buddhist one, 5787-02-04 on a Hebrew one,
/// 1448-05-04 under Umm al-Qura. A month 13 or a day 30 the Gregorian month lacks rolled over into
/// the next month, so in some calendars two real days share one key (Hebrew's Elul and Tishri,
/// Chinese leap months) and others have none. Every such key lies outside the real days
/// (`HabitCalendar.realDayNumbers`: 2025-01-01 to today + 2) — years 7–8, 114–115, 1403–1405,
/// 1446–1448, 1741–1743, 1946–1948, 2017–2019, 2568–2569, 5785–5787, 7517–7519 or 41–43 — which
/// is how a stray key is told from a real one. The window, not "a year before 1900 or after 2200":
/// that misses Indian (1946–1948) and Ethiopic Amete Mihret (2017–2019) keys.
///
/// **Reading one back.** For each calendar, the old formula is run over every real day, which
/// gives that calendar's inverse map (key → the real days that wrote it). The device's own
/// calendar is tried first, then the others in `calendars`' order; the first that wrote the key
/// decides. Where several real days share the key, the one on the local day of the record's
/// `updatedAt` wins, else the latest on or before that day (before today without a stamp), else
/// the earliest. A key no calendar wrote — a clock set years ahead, a hand-edited backup — is left
/// alone. Maps are built on first use, one per calendar: about 2 ms each over 650 days.
///
/// **The Islamic variants.** No key of one calendar family is a key of another (their years are
/// far apart), except within the Islamic family: Umm al-Qura, civil, astronomical and tabular
/// write the same keys, often a day apart. Which of them wrote a store's keys is decided once
/// for the whole batch (`settleIslamicVariant(by:)`, before any decoding): the variant that puts
/// the most of the batch's records on their stamp's local day, the device's own on a tie, the
/// fixed order with no stamps. Not record by record: a check-in made the next day (yesterday's,
/// from the strip) has a stamp a day late, which another variant's map often holds for the same
/// key, so a per-record match moves it a day (the review measured 298 of 654 Umm al-Qura keys off
/// with every stamp a day late); a batch's stray Islamic keys all come from the one device that
/// wrote them. Not "the device's own first" either: a Gregorian iPad that pulled an Islamic-civil
/// phone's rows, a restore of that phone's backup on a phone left at Umm al-Qura, or a user who
/// has since changed variant read the civil, astronomical and tabular keys with Umm al-Qura's map
/// — 295, 301 and 415 of 654 days a day off on a Gregorian device (W10-DECODE-1).
final class DayKeyDecoder {
    /// Every calendar a key could have been written in besides Gregorian and ISO 8601 (which write
    /// Gregorian's Y/M/D), in the order tried after the device's own. A device on a calendar not
    /// listed here (a newer system's) is still tried first, as the device's own.
    static let calendars: [Calendar.Identifier] = [
        .japanese, .buddhist, .republicOfChina,
        .islamicUmmAlQura, .islamicCivil, .islamic, .islamicTabular,
        .hebrew, .persian, .indian, .coptic, .ethiopicAmeteMihret, .ethiopicAmeteAlem, .chinese,
    ]

    /// The four variants that write overlapping keys (see the type's note), in `calendars`' order.
    static let islamicVariants: [Calendar.Identifier] = [.islamicUmmAlQura, .islamicCivil, .islamic, .islamicTabular]

    /// Today's day number, as a key of the device's day (Gregorian, in its zone).
    let todayNumber: Int
    /// The days a key can name (`HabitCalendar.realDayNumbers`); nil when the clock says today is
    /// before 2025 — then nothing is decoded.
    let realDays: ClosedRange<Int>?
    /// The calendars tried, in order: the device's own first when it wrote stray keys, and the
    /// Islamic variant `settleIslamicVariant(by:)` chose ahead of every other but a non-Islamic own.
    private(set) var order: [Calendar.Identifier]
    /// The variant `settleIslamicVariant(by:)` chose; nil before it ran, or when the batch's stamps
    /// did not say (then the device's own variant, or the fixed order, decides as before).
    private(set) var islamicVariant: Calendar.Identifier?
    /// The device's own calendar.
    private let own: Calendar.Identifier
    /// For a stamp's local day: Gregorian, in the device's zone.
    private let stampCalendar: Calendar
    private var maps: [Calendar.Identifier: [Int: [Int]]] = [:]

    init(today: Date = Date(), calendar: Calendar = .current) {
        stampCalendar = HabitCalendar.dayCalendar(calendar)
        todayNumber = HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: today, calendar: calendar))
        realDays = HabitCalendar.realDayNumbers(todayNumber: todayNumber)
        let own = calendar.identifier
        self.own = own
        order = HabitCalendar.wroteGregorianKeys(calendar)
            ? Self.calendars
            : [own] + Self.calendars.filter { $0 != own }
    }

    /// Whether `day` (a day number) is one a key can name.
    func isRealDay(_ day: Int) -> Bool {
        realDays?.contains(day) ?? false
    }

    /// Decides which Islamic variant wrote the Islamic keys among `batch` — every stored key about
    /// to be read back, with its record's stamp (`updatedAt`) — and tries it first from now on.
    /// For each variant, the records it would put on their stamp's local day are counted; the
    /// most wins, the device's own variant on a tie (else the first in `calendars`' order). A
    /// batch with no Islamic key, or whose stamps match no variant, changes nothing. Call it once,
    /// before reading any of the batch back: every key of the batch is then read by the same
    /// variant. Builds the four Islamic maps only when the batch holds a stray key.
    func settleIslamicVariant(by batch: [(keyDay: Int, stamp: Date?)]) {
        guard realDays != nil else { return }
        // A device on a calendar outside the Islamic family reads the keys it wrote itself first,
        // as before, and those are no Islamic variant's: the vote skips them, so a Japanese phone's
        // own keys never build the four Islamic maps.
        let ownFirst = order.first == own && !Self.islamicVariants.contains(own)
        var score: [Calendar.Identifier: Int] = [:]
        for item in batch where !isRealDay(item.keyDay) {
            guard let stamp = item.stamp else { continue }
            if ownFirst, map(for: own)[item.keyDay] != nil { continue }
            let stampDay = stampDayNumber(of: stamp)
            for variant in Self.islamicVariants where map(for: variant)[item.keyDay]?.contains(stampDay) == true {
                score[variant, default: 0] += 1
            }
        }
        guard let best = score.values.max(), best > 0 else { return }
        let leaders = Self.islamicVariants.filter { score[$0] == best }
        let choice = leaders.contains(own) ? own : leaders[0]
        islamicVariant = choice
        let rest = order.filter { $0 != choice }
        order = ownFirst ? [own, choice] + rest.dropFirst() : [choice] + rest
    }

    /// The real day of the stored key `key`, or nil when no calendar wrote it (or it is a real day
    /// already, which needs no reading back). `stamp`: the record's `updatedAt`, which breaks a tie.
    func realDay(ofKey key: Date, stamp: Date?) -> Date? {
        realDay(ofKeyDay: HabitStats.dayNumber(ofKey: key), stamp: stamp).map(HabitStats.key(ofDay:))
    }

    /// `realDay(ofKey:stamp:)` by day number.
    func realDay(ofKeyDay keyDay: Int, stamp: Date?) -> Int? {
        guard realDays != nil, !isRealDay(keyDay) else { return nil }
        let stampDay = stamp.map(stampDayNumber(of:))
        for identifier in order {
            guard let days = map(for: identifier)[keyDay], let first = days.first else { continue }
            if days.count == 1 { return first }
            if let stampDay, days.contains(stampDay) { return stampDay }
            let reference = stampDay ?? todayNumber
            return days.last(where: { $0 <= reference }) ?? first
        }
        return nil
    }

    /// The local day (Gregorian, in the device's zone) of a stamp.
    private func stampDayNumber(of stamp: Date) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: stamp, calendar: stampCalendar))
    }

    /// The day number of the key a build before 1.4.1 wrote, under `calendar`, for real day `day`:
    /// that day's Y/M/D in `calendar`, written as a Gregorian date — 1.4.0's
    /// `HabitCalendar.dayKey(for:localCalendar:)`, line for line. `calendar` must be in UTC (the
    /// day's noon is read there, which gives the civil day's date in any zone).
    static func oldKeyDay(ofRealDay day: Int, in calendar: Calendar) -> Int {
        let noon = HabitStats.key(ofDay: day).addingTimeInterval(12 * 3_600)
        let c = calendar.dateComponents([.year, .month, .day], from: noon)
        let key = HabitCalendar.utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))
            ?? HabitCalendar.utc.startOfDay(for: noon)
        return HabitStats.dayNumber(ofKey: key)
    }

    /// The key → real days map of one calendar over `realDays`, ascending, built once.
    private func map(for identifier: Calendar.Identifier) -> [Int: [Int]] {
        if let built = maps[identifier] { return built }
        var built: [Int: [Int]] = [:]
        if let realDays {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = HabitCalendar.utc.timeZone
            built.reserveCapacity(realDays.count)
            for day in realDays {
                let key = Self.oldKeyDay(ofRealDay: day, in: calendar)
                // A Gregorian-looking key is a real day already: nothing to read back.
                guard !isRealDay(key) else { continue }
                built[key, default: []].append(day)
            }
        }
        maps[identifier] = built
        return built
    }
}

// MARK: - The repair

/// Puts every stray key in the store back on its real day: once at the first 1.4.1 launch, and
/// again — cheaply, one fetch that finds nothing — at every launch after, for keys pulled from a
/// device still on an older build (X2 section 5(b); RELEASE-1.4.1.md W10).
///
/// **Applying it, by what the server may hold.**
/// - **Never delivered** (`syncedAt` nil and not restored with its id): re-keyed in place, same
///   id. The push sends it at its real day as the new row it always was.
/// - **Delivered, or restored with its id** (`restoredAt`): the server may hold that id at the
///   wrong day, and a push of the same id at another day is answered `row_error` (the server
///   keeps one row per id and one per habit and day; measured on a server copy, X2 section 2). So
///   a NEW record takes the real day — the same value, note and stamp — the old one is deleted,
///   and only once the save succeeds is a tombstone queued for the old id: it deletes only the
///   wrong-day row. (Not a duplicate's tombstone, which decision 7 forbids: no record of the real
///   day goes by that id.)
/// - **Held as `invalid_value`** (the server's date guard refused the wrong day): re-keyed by the
///   rule above, and the hold is lifted — the value is fine now.
/// - **Held for another reason**: re-keyed in place, still held, when never delivered; left as it
///   is when delivered — the hold is the user's to resolve in Settings, and a new id would decide
///   it for them. The next launch's pass takes it once it is no longer held.
/// - **No calendar wrote the key**: left as it is.
///
/// **Days that end with two records** (the real day already had one — a check-in from another
/// device, or a UTC+0 device's strip pick, which always keyed Gregorian) are merged as every write
/// merges them (2026-10-15 decision 7, amended): `HabitCheckIn.merge`, `setChecked(nil, …)`'s merge,
/// keeps the record D2 reads, moves a lone note onto it, deletes the others here only, with no
/// tombstone, and sends the kept one again. Two different notes are not combined without the user:
/// that day stays as it is until its next write, which asks (`.combineNotes`).
///
/// **Order.** The caller runs `SyncDeliveryMigration` first (`launchPass`): on a store from 1.3.0
/// every row opens "never delivered" until that rule marks what 1.3.0 had pushed, and a row
/// re-keyed in place and marked afterwards would be delivered at a day the server does not hold.
///
/// **Cost** (W10-PERF-1). The pass runs before the first frame (`StrideApp.prepareStore`), so it
/// never asks the store once per day: in a context holding the move's pending changes, every
/// fetch is checked in memory against each of them, and the first build asked once per repaired
/// day — a 1,000-record store took 45 s, a 4,000-record one more than ten minutes, past the launch
/// watchdog, and a kill before the save kept nothing, so every launch began again. Now the moves
/// are saved first; the days that may hold two records are then read once per habit
/// (`HabitCheckIn.liveRecords(of:onDays:)`), with no change pending, before any merge; and only
/// the days that do are merged (`HabitCheckIn.merge`, with that answer), then saved. The tombstones
/// go in one write (`SyncDeletionQueue.trackEntries`). Measured 2026-10-16 in a Debug build, on
/// disk and cold: 0.6 s for 2,000 stray records, 3.0 s for 10,000 — linear (StrideTests'
/// `testTheFirstPassOverARealisticStoreIsFast`). A merge save that fails leaves decision 7's
/// ordinary state — the day's next write merges it — and is reported (`Outcome.mergeSaveFailed`),
/// not thrown: the moves and their tombstones stand.
enum DayKeyRepair {
    /// Set in the App Group's defaults once the first pass has completed on this install, whatever
    /// it found. The widget on a non-Gregorian device opens the store only after it
    /// (`ExtensionStoreOpen`). Later passes run whether or not it is set.
    static let doneKey = "stride_daykey_migration_v3_done"

    static func isDone(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: doneKey)
    }

    /// What a pass did.
    struct Outcome: Equatable {
        /// Live records outside the real days.
        var found = 0
        /// Re-keyed in place: never delivered, the same id at its real day.
        var rekeyed = 0
        /// Replaced by a record with a new id at its real day; their old ids are `tombstones`.
        var replaced = 0
        /// `invalid_value` holds lifted.
        var holdsLifted = 0
        /// Left as they are: no calendar wrote the key.
        var undecodable = 0
        /// Left as they are: delivered and held for a reason the user resolves.
        var leftHeld = 0
        /// Days with two records after the repair, merged (decision 7).
        var mergedDays = 0
        /// Days left with two records whose notes differ, for their next write to ask.
        var daysAskingToCombineNotes = 0
        /// The merges' save failed: those days were left with two records, for their next write to
        /// merge (`mergedDays` is then 0). The moves were saved and their tombstones queued.
        var mergeSaveFailed = false
        /// The old ids queued as tombstones, after the save.
        var tombstones: [String] = []

        /// Whether anything in the store changed.
        var changedStore: Bool { rekeyed + replaced + mergedDays > 0 }
    }

    /// One pass over `context`'s store: moves the stray records and saves (on a failed save rolls
    /// back and throws), queues the tombstones, then merges the days left with two records and
    /// saves again. `now` and `calendar` decide today, the real days and the device's own calendar
    /// (the app passes `Calendar.current`, never `appCalendar`). `save` is the context's own,
    /// injected only so the tests can make it fail.
    @MainActor
    static func run(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current,
                    deletionQueue: SyncDeletionQueue?,
                    save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Outcome {
        var outcome = Outcome()
        let decoder = DayKeyDecoder(today: now, calendar: calendar)
        // Held for the whole pass: the fetch loaded their rows, which the records below read; let
        // go, each would fault its row back one query at a time (0.2 s for 2,000).
        guard let fetched = try strayRecords(in: context, decoder: decoder), !fetched.isEmpty else { return outcome }
        let stray = Set(fetched.map(\.persistentModelID))
        defer { withExtendedLifetime(fetched) {} }

        // The stray records, habit by habit. By `persistentModelID`, which reading never faults: a
        // record another context deleted and saved is not among `stray` (the store answered it)
        // and is never read.
        var strays: [(habit: Habit, records: [HabitRecord])] = []
        for habit in try context.fetch(FetchDescriptor<Habit>()) {
            let records = habit.records.filter { stray.contains($0.persistentModelID) && !$0.isDeleted }
            if !records.isEmpty { strays.append((habit, records)) }
        }
        // Which Islamic variant wrote them, decided once for all of them (`DayKeyDecoder`).
        decoder.settleIslamicVariant(by: strays.flatMap { $0.records.map {
            (keyDay: HabitStats.dayNumber(ofKey: $0.date), stamp: $0.updatedAt)
        } })

        var touched: [(habit: Habit, days: Set<Int>)] = []
        var oldIDs: [String] = []
        var seenOldIDs = Set<String>()
        for (habit, records) in strays {
            var days = Set<Int>()
            var copies: [HabitRecord] = []
            for record in records {
                outcome.found += 1
                guard let day = decoder.realDay(ofKeyDay: HabitStats.dayNumber(ofKey: record.date),
                                                stamp: record.updatedAt) else {
                    outcome.undecodable += 1
                    continue
                }
                let hold = record.activeHold
                let mayBeOnServer = record.hasBeenDelivered || record.restoredAt != nil
                if let hold, hold != .invalidValue, mayBeOnServer {
                    outcome.leftHeld += 1
                    continue
                }
                let key = HabitStats.key(ofDay: day)
                if mayBeOnServer {
                    let copy = HabitRecord(date: key, note: record.note, value: record.value)
                    copy.date = key
                    // Its own edit time, never now: a fresh stamp would let this copy beat a newer
                    // edit another device made to the day. nil stays nil (a record never edited
                    // since before v2): its stamp is then its real day, no longer year 8 or 2569.
                    copy.updatedAt = record.updatedAt
                    copies.append(copy)
                    // Once each: two records can go by one id (a same-id pair, X1).
                    let old = record.id.uuidString
                    if seenOldIDs.insert(old).inserted { oldIDs.append(old) }
                    context.delete(record)
                    outcome.replaced += 1
                    if hold == .invalidValue { outcome.holdsLifted += 1 }
                } else {
                    record.date = key
                    if hold == .invalidValue {
                        record.releaseHold()
                        outcome.holdsLifted += 1
                    } else if let hold {
                        // At the stamp it has now: a record with no `updatedAt` stamps as its day,
                        // which just moved, and a hold left at the old one would lift by itself.
                        record.hold(hold)
                    }
                    outcome.rekeyed += 1
                }
                days.insert(day)
            }
            // One append per habit: each append to the relationship rewrites the whole array.
            if !copies.isEmpty { habit.records.append(contentsOf: copies) }
            if !days.isEmpty { touched.append((habit, days)) }
        }

        if context.hasChanges {
            do {
                try save(context)
            } catch {
                context.rollback()
                throw error
            }
        }
        // Only now: a tombstone queued before the save could delete on the server a row this store
        // still holds at its wrong day. And never for an id a record here still goes by (a same-id
        // pair, X1): that would delete its row too. If the store cannot be asked, every id goes, as
        // `HabitEntryCommit.tombstones` does.
        let carried = carriedIDs(oldIDs, in: context)
        outcome.tombstones = oldIDs.filter { !(carried?.contains($0) ?? false) }
        deletionQueue?.trackEntries(outcome.tombstones)

        // The days that end with two records: every touched habit's days read first, with nothing
        // pending, then merged (no merge changes another day's records).
        let duplicates = touched.flatMap { habit, days in
            HabitCheckIn.liveRecords(of: habit, onDays: days)
                .filter { $0.value.count > 1 }
                .sorted { $0.key < $1.key }
                .map { (habit: habit, day: $0.key, records: $0.value) }
        }
        var merged = 0
        for item in duplicates {
            switch HabitCheckIn.merge(item.records, on: HabitStats.key(ofDay: item.day), of: item.habit, in: context) {
            case .changed: merged += 1
            case .needsConfirmation: outcome.daysAskingToCombineNotes += 1
            case .noChange: break
            }
        }
        if context.hasChanges {
            do {
                try save(context)
                outcome.mergedDays = merged
            } catch {
                context.rollback()
                outcome.mergeSaveFailed = true
            }
        }
        return outcome
    }

    /// The live records outside the real days; nil when the clock says today is before 2025
    /// (nothing is taken for a stray key then).
    @MainActor
    static func strayRecords(in context: ModelContext, decoder: DayKeyDecoder) throws -> [HabitRecord]? {
        try strays(decoder).map { try context.fetch($0) }
    }

    /// How many `strayRecords` there are, counted without loading any: the launch's question.
    @MainActor
    static func strayRecordCount(in context: ModelContext, decoder: DayKeyDecoder) throws -> Int {
        try strays(decoder).map { try context.fetchCount($0) } ?? 0
    }

    private static func strays(_ decoder: DayKeyDecoder) -> FetchDescriptor<HabitRecord>? {
        guard let real = decoder.realDays else { return nil }
        let first = HabitStats.key(ofDay: real.lowerBound)
        let end = HabitStats.key(ofDay: real.upperBound + 1)
        return FetchDescriptor<HabitRecord>(predicate: #Predicate { $0.date < first || $0.date >= end })
    }

    /// Of `ids`, those a record in the store still goes by; nil when it cannot be asked.
    @MainActor
    private static func carriedIDs(_ ids: [String], in context: ModelContext) -> Set<String>? {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        guard !uuids.isEmpty else { return [] }
        var carried = Set<String>()
        for start in stride(from: 0, to: uuids.count, by: HabitStats.liveRecordFetchChunk) {
            let chunk = Array(uuids[start..<min(start + HabitStats.liveRecordFetchChunk, uuids.count)])
            guard let records = try? context.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { chunk.contains($0.id) }))
            else { return nil }
            for record in records { carried.insert(record.id.uuidString) }
        }
        return carried
    }

    // MARK: The launch's pass

    /// What the launch's pass did.
    enum LaunchResult: Equatable {
        /// No stray key in the store.
        case nothingToRepair
        case repaired(Outcome)
        /// `SyncDeliveryMigration` could not run yet, so this pass did not either (retried at the
        /// next launch; no sync runs until that migration has).
        case deferred
        /// The save failed; nothing changed. Retried at the next launch.
        case failed
    }

    /// The launch's pass (`SharedModelContainer.repairDayKeysIfNeeded`, on the real store only;
    /// StrideApp.prepareStore, after the v2 migration and before `SyncService.prepareLaunch`).
    /// Sets `doneKey` in `flags` (the App Group's defaults) when it completes; returns whether it
    /// set it now, so the app reloads a widget that was waiting for it.
    ///
    /// - Parameters:
    ///   - syncDefaults: where `SyncService` keeps the delivery migration's keys (`.standard`).
    @MainActor
    static func launchPass(in context: ModelContext, flags: UserDefaults, syncDefaults: UserDefaults,
                           deletionQueue: SyncDeletionQueue?, now: Date = Date(),
                           calendar: Calendar = .current) -> (result: LaunchResult, flagSet: Bool) {
        let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Migration")
        let result: LaunchResult
        do {
            let decoder = DayKeyDecoder(today: now, calendar: calendar)
            if try strayRecordCount(in: context, decoder: decoder) == 0 {
                result = .nothingToRepair
            } else if SyncDeliveryMigration.runOnceIfNeeded(in: context, defaults: syncDefaults) == .failed {
                logger.error("Day-key repair deferred: the delivery-state migration has not run")
                return (.deferred, false)
            } else {
                let outcome = try run(in: context, now: now, calendar: calendar, deletionQueue: deletionQueue)
                logger.notice("Day-key repair: \(outcome.found, privacy: .public) found, \(outcome.rekeyed, privacy: .public) re-keyed, \(outcome.replaced, privacy: .public) replaced, \(outcome.holdsLifted, privacy: .public) holds lifted, \(outcome.undecodable, privacy: .public) undecodable, \(outcome.leftHeld, privacy: .public) left held, \(outcome.mergedDays, privacy: .public) days merged, \(outcome.daysAskingToCombineNotes, privacy: .public) asking, \(outcome.tombstones.count, privacy: .public) tombstones\(outcome.mergeSaveFailed ? "; the merges' save failed (left for their next write)" : "", privacy: .public)")
                result = .repaired(outcome)
            }
        } catch {
            let ns = error as NSError
            logger.error("Day-key repair failed (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)); retried at the next launch")
            return (.failed, false)
        }
        let flagSet = !isDone(in: flags)
        if flagSet { flags.set(true, forKey: doneKey) }
        return (result, flagSet)
    }
}
