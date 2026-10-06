import Foundation
import SwiftData
import os.log

// The per-row delivery state 1.3.1's incremental push runs on (DEV-PLAN-1.3.md M2, "Delivery
// state, not a boolean"). Pure helpers over the model fields; nothing here talks to a network.
// It lives in Shared/ so the host-less StrideTests, the widget (which only edits through
// `touch()`) and scripts/sync_rehearsal.sh all compile the one implementation — testing a
// hand-copied replica is how the reconciler drifted before 1.2.3.

/// Why a row is held (quarantined): kept locally, never acknowledged, never re-sent until
/// edited, never deleted by a full pull. The raw values are the server's `skippedReasons`
/// codes (routes/sync.js), plus `too_large`, which the planner decides without asking.
enum SyncHoldReason: String, CaseIterable {
    case missingField = "missing_field"
    case rowError = "row_error"
    case invalidValue = "invalid_value"
    /// An entry still `unknown_habit` three syncs after its habit was acknowledged.
    case unknownHabit = "unknown_habit"
    /// The id exists under another account (`not_owned` / `not_owned_habit`): acknowledging it
    /// would let the full-pull rule delete it, dropping it would lose it. "Restore as new copies"
    /// resolves it.
    case notOwned = "not_owned"
    /// Its encoding alone exceeds what one request can carry.
    case tooLarge = "too_large"
    /// A row restored with its ids (`restoredAt`) that the server has tombstoned: held for the
    /// restore-as-copies choice instead of dropped.
    case tombstoned
}

/// The delivery state shared by `Habit`, `HabitRecord` and `HabitGroup`.
///
/// Three things, not a boolean — the first draft of M2 had one, and it broke two ways. It
/// quarantined a bad row *by acknowledging it*, and the full-pull rule deletes acknowledged rows
/// the server lacks, so the next full pull would have deleted every quarantined row. And it
/// reset "delivered" on re-login, which made "delivered, then deleted on another device"
/// indistinguishable from "never uploaded": a resurrection path the day tombstones are swept.
///
/// - `syncedAt` — the stamp the server last acknowledged; the evidence the row was delivered at
///   least once. Written only by an acknowledgement or by applying remote state, and cleared by
///   nothing — not sign-out, not re-login, not a forced resend. Only erasing the row removes it.
/// - `syncHoldReason` + `syncHoldStamp` — quarantine. Held iff `syncHoldStamp == stamp`, so an
///   edit (a new stamp) lifts the hold by itself and no mutation site has to know about holds.
/// - `needsResend` — forced resend (`409 snapshot_required`, Settings → Full resync). Sent again,
///   `syncedAt` untouched.
/// - `restoredAt` — set by a restore that kept the backup's ids; while set, no pull deletes the
///   row (it is held `tombstoned` instead). Cleared by the row's first acknowledgement.
///
/// None of these goes on the wire or into a backup.
protocol SyncDeliverable: AnyObject {
    var id: UUID { get }
    /// The edit stamp that goes on the wire as `updatedAt`.
    var stamp: Date { get }
    var syncedAt: Date? { get set }
    var syncHoldReason: String? { get set }
    var syncHoldStamp: Date? { get set }
    var needsResend: Bool { get set }
    var restoredAt: Date? { get set }
}

extension Habit: SyncDeliverable {
    /// `updatedAt` is nil only on rows from before v2 added it; they were never edited since.
    var stamp: Date { updatedAt ?? createdAt }
}

extension HabitGroup: SyncDeliverable {
    var stamp: Date { updatedAt ?? createdAt }
}

extension HabitRecord: SyncDeliverable {
    /// A record has no `createdAt`; the push has always sent `date` in its place
    /// (`SyncService.pushLocal`), so a record never edited stamps as its day-key.
    var stamp: Date { updatedAt ?? date }
}

extension SyncDeliverable {
    /// Quarantined at its current stamp. An edit since the hold was set lifts it.
    var isHeld: Bool {
        guard let holdStamp = syncHoldStamp else { return false }
        return SyncTimestamp.sameMillisecond(holdStamp, stamp)
    }

    /// The reason, while the row is held. nil when not held, including a stale reason an edit
    /// has lifted. A reason this build does not know reads as `rowError` rather than as "not
    /// held": the fields say the row was refused, and treating it as sendable would re-send it.
    var activeHold: SyncHoldReason? {
        guard isHeld else { return nil }
        return syncHoldReason.flatMap(SyncHoldReason.init(rawValue:)) ?? .rowError
    }

    /// Delivered at least once, from this device or by applying remote state. The full-pull
    /// rule keeps an absent row that has never been delivered (a failed first upload, a restore)
    /// and deletes one that has (another device deleted it).
    var hasBeenDelivered: Bool { syncedAt != nil }

    /// Sent on the next push. Inequality, not ordering: a stamp that moved BACKWARDS (the clock
    /// stepped back between two edits) is still pending. Compared at millisecond precision: the
    /// acknowledgement stores the stamp as it crossed the wire.
    var isPending: Bool {
        !isHeld && (needsResend || !SyncTimestamp.sameMillisecond(syncedAt, stamp))
    }

    /// The server accepted this row as it was sent (`applied`, or not in `skipped`).
    ///
    /// `sentStamp` is the stamp that was SENT, not the row's current one: a row edited while its
    /// push was in flight keeps the evidence of delivery and stays pending, because its new
    /// stamp differs. The first M2 draft wrote nothing on a mismatch, which left a first upload
    /// edited in flight "never delivered" — a row the full-pull rule keeps and re-pushes, so once
    /// sweeping returns, a row another device deleted would come back.
    func acknowledge(sentStamp: Date) {
        syncedAt = SyncTimestamp.floorToMillisecond(sentStamp)
        needsResend = false
        restoredAt = nil
        // Clearing is safe: a push never sends a held row, so any hold here belongs to an
        // earlier stamp, one an edit has already lifted.
        syncHoldReason = nil
        syncHoldStamp = nil
    }

    /// Quarantine at `sentStamp` (default: the current stamp, for holds the planner decides
    /// itself, like `too_large`). Holding the SENT stamp means an edit made while the push was in
    /// flight is not held: it is a new value, and it gets its own chance. `syncedAt` and
    /// `needsResend` are untouched — a held row that was delivered before stays delivered.
    func hold(_ reason: SyncHoldReason, sentStamp: Date? = nil) {
        syncHoldReason = reason.rawValue
        syncHoldStamp = SyncTimestamp.floorToMillisecond(sentStamp ?? stamp)
    }

    /// Lifts a hold without an edit: "Restore as new copies", Discard. Writes only a field that
    /// is set (see `adoptRemoteState`).
    func releaseHold() {
        if syncHoldReason != nil { syncHoldReason = nil }
        if syncHoldStamp != nil { syncHoldStamp = nil }
    }

    /// The reconciler applied the server's version of this row (update, insert, id alignment).
    /// Without this, the device's own push returns through the cursor's 60 s overlap, looks
    /// pending again, and every row echoes forever.
    ///
    /// Also clears `restoredAt`, which the spec lists only under acknowledgement: the server
    /// holding this id live for this account is the same evidence. Left set, a restored row
    /// whose first contact was a pull (not pending afterwards, so never acknowledged) could never
    /// again be deleted by another device — every later tombstone would hold it instead.
    ///
    /// Writes only the fields that differ. SwiftData counts an assignment of an equal value as a
    /// change, and most rows a pull applies are already in this state (the echo of this device's
    /// own push, a full pull of a synced store): writing them anyway made the pull's save rewrite
    /// every such row.
    func adoptRemoteState() {
        let delivered = SyncTimestamp.floorToMillisecond(stamp)
        if syncedAt != delivered { syncedAt = delivered }
        if needsResend { needsResend = false }
        if restoredAt != nil { restoredAt = nil }
        releaseHold()
    }

    /// Forced resend. `syncedAt` and holds stay: a held row is still not sent, and the evidence
    /// of delivery is what lets the full-pull rule tell "deleted elsewhere" from "never sent".
    func markNeedsResend() {
        needsResend = true
    }
}

// MARK: - Finding pending records without reading every one

/// The pending records (`isPending`), found by one fetch the store evaluates.
///
/// A store holding years of check-ins has tens of thousands of records and, on almost every
/// sync, none pending. Reading `isPending` means firing every record's fault: 3.4 s on the main
/// actor for a sync with nothing to send on a 20,000-entry store (rehearsal S12, M2 slice).
///
/// `isPending` compares at millisecond precision, which a predicate cannot express, so the
/// predicate selects a SUPERSET and `isPending` decides on what it returns. It leaves out only a
/// row whose `syncedAt` is non-nil and equal, as a `Date`, to its stamp (`updatedAt ?? date`)
/// with `needsResend` off — and equal instants are the same millisecond, so such a row is not
/// pending, held or not. Every row 1.3.1 acknowledges or pulls is stored that way:
/// `acknowledge` and `adoptRemoteState` write `floorToMillisecond(stamp)`, and every stamp 1.3.1
/// writes is already floored, which `floorToMillisecond` returns bit for bit. A stamp 1.3.0
/// wrote below the millisecond never equals its floored `syncedAt`, so that row is returned and
/// `isPending` answers for it, as it did before.
@MainActor
enum SyncPendingRows {
    static func records(in context: ModelContext) throws -> Set<PersistentIdentifier> {
        // Two fetches, not one predicate: the compiler cannot type-check the four clauses in one
        // expression in reasonable time. A record with no `updatedAt` (from before v2 added it)
        // stamps as its `date`.
        let edited = #Predicate<HabitRecord> { r in
            r.needsResend == true || r.syncedAt == nil || (r.updatedAt != nil && r.syncedAt != r.updatedAt)
        }
        let neverEdited = #Predicate<HabitRecord> { r in
            r.updatedAt == nil && r.syncedAt.flatMap { $0 != r.date } == true
        }
        var pending = Set<PersistentIdentifier>()
        for predicate in [edited, neverEdited] {
            for record in try context.fetch(FetchDescriptor<HabitRecord>(predicate: predicate)) where record.isPending {
                pending.insert(record.persistentModelID)
            }
        }
        return pending
    }
}

// MARK: - Wire stamps at the size of a whole account

/// `SyncTimestamp.parse` and `SyncTimestamp.millisecondString`, with the same results bit for
/// bit, but without a date formatter for the two shapes the wire actually carries.
///
/// `ISO8601DateFormatter` costs about 0.1 ms a call on an M1 Pro, and a pull parses one stamp per
/// entry, a push formats two: 54,750 entries with distinct stamps spent 6 s in the parse alone
/// once the reconciler's matching stopped being quadratic (M2 large-account work). The server's
/// stamps are `YYYY-MM-DDTHH:MM:SS.mmmZ` (`toISOString()`) or whole seconds from before 1.3.1;
/// those are read and written here with calendar arithmetic, anything else — another shape, a
/// field out of range, a year before 1970 — goes to `SyncTimestamp` exactly as before.
/// `StrideTests/SyncDeliveryTests` sweeps both against it.
enum SyncWireStamp {
    /// `SyncTimestamp.parse(string)`.
    static func parse(_ string: String) -> Date? {
        if let ms = milliseconds(parsing: string) { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return SyncTimestamp.parse(string)
    }

    /// `SyncTimestamp.millisecondString(from: date)`.
    static func string(from date: Date) -> String {
        let ms = SyncTimestamp.milliseconds(date)
        guard ms >= 0, ms < maxMilliseconds else { return SyncTimestamp.millisecondString(from: date) }
        let (y, m, d) = civil(fromDays: ms / 86_400_000)
        let time = ms % 86_400_000
        var bytes = [UInt8](repeating: 0, count: 24)
        func put(_ value: Int64, at offset: Int, digits: Int) {
            var v = value
            for i in stride(from: offset + digits - 1, through: offset, by: -1) {
                bytes[i] = UInt8(ascii: "0") + UInt8(v % 10)
                v /= 10
            }
        }
        put(y, at: 0, digits: 4); bytes[4] = UInt8(ascii: "-")
        put(m, at: 5, digits: 2); bytes[7] = UInt8(ascii: "-")
        put(d, at: 8, digits: 2); bytes[10] = UInt8(ascii: "T")
        put(time / 3_600_000, at: 11, digits: 2); bytes[13] = UInt8(ascii: ":")
        put(time / 60_000 % 60, at: 14, digits: 2); bytes[16] = UInt8(ascii: ":")
        put(time / 1_000 % 60, at: 17, digits: 2); bytes[19] = UInt8(ascii: ".")
        put(time % 1_000, at: 20, digits: 3); bytes[23] = UInt8(ascii: "Z")
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 10000-01-01T00:00:00Z: four-digit years only.
    private static let maxMilliseconds: Int64 = 253_402_300_800_000

    /// Milliseconds since 1970 for `YYYY-MM-DDTHH:MM:SSZ` or `YYYY-MM-DDTHH:MM:SS.mmmZ` with every
    /// field in range and a year from 1970 to 2069; nil for anything else.
    ///
    /// The years stop at 2069 because the formatter's own result stops being exact: it builds the
    /// instant in floating point, and past 2^31 s from 2001 its error can exceed the microsecond
    /// of slack `SyncTimestamp.milliseconds` allows, so it floors some stamps to the millisecond
    /// below (the sweep found two in year 3071). Matching it there would mean copying its error.
    static func milliseconds(parsing string: String) -> Int64? {
        var string = string   // `withUTF8` may make it contiguous; a decoded string already is
        return string.withUTF8(parse)
    }

    private static func parse(_ b: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard b.count == 20 || b.count == 24, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              b[b.count - 1] == UInt8(ascii: "Z")
        else { return nil }
        func number(_ offset: Int, _ digits: Int) -> Int64? {
            var v: Int64 = 0
            for i in offset..<(offset + digits) {
                let c = b[i]
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                v = v * 10 + Int64(c - UInt8(ascii: "0"))
            }
            return v
        }
        guard let y = number(0, 4), let m = number(5, 2), let d = number(8, 2),
              let hh = number(11, 2), let mm = number(14, 2), let ss = number(17, 2),
              (1970...2069).contains(y), (1...12).contains(m), d >= 1, d <= daysIn(month: m, year: y),
              hh < 24, mm < 60, ss < 60
        else { return nil }
        var fraction: Int64 = 0
        if b.count == 24 {
            guard b[19] == UInt8(ascii: "."), let f = number(20, 3) else { return nil }
            fraction = f
        }
        let seconds = days(fromCivil: y, m, d) * 86_400 + hh * 3_600 + mm * 60 + ss
        return seconds * 1_000 + fraction
    }

    private static func isLeap(_ y: Int64) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    private static func daysIn(month m: Int64, year y: Int64) -> Int64 {
        switch m {
        case 2: return isLeap(y) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Howard Hinnant's `days_from_civil` / `civil_from_days` (proleptic Gregorian, which is what
    // the formatter uses for every year this handles).
    private static func days(fromCivil year: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

// MARK: - Migrated rows (sub-decision (b), 2026-09-28)

/// The first 1.3.1 launch, once: marks as delivered the rows 1.3.0 had certainly pushed.
///
/// Every row of a 1.3.0 store opens with `syncedAt == nil`, "never delivered", which a full
/// pull keeps and the next push re-sends. Harmless while tombstones are kept (the answer is
/// `tombstoned`), but the device the 426 floor forces to update is exactly the dormant one
/// whose deletions have been swept — its re-send would be a new insert, and a habit deleted a
/// year ago on another device would come back.
///
/// 1.3.0 wrote `stride_last_sync_time` only after a full snapshot went up and the pull came
/// back, and the same device clock stamped both, so a row whose stamp is at least 5 minutes
/// before it was in that snapshot. Later rows stay pending (a re-send is harmless). A fresh
/// 1.3.1 install has no key and stamps nothing.
///
/// The marks are true only for the account 1.3.0 last synced as, which 1.3.0 never recorded.
/// And the key does not say the device is still signed into it: a session that EXPIRED
/// (1.3.0's `{user: null}` launch check, a 401) deleted the token and kept the key, so a dormant
/// device can arrive stamped and signed out (M2 slice review). Adopted by another account, its
/// first full pull would delete every stamped row as "delivered, then deleted elsewhere", with
/// nothing in the recovery log (they are not pending). So a store this rule stamped starts with
/// its marks **unproven** (`SyncMarksProof`), and the first full pull of the account that adopts
/// it decides them before its deletion pass (`SyncReconciler`, owner decision 2026-09-28).
///
/// Proven, a mark still says only that 1.3.0 PUSHED the row, not that the server took it: 1.3.0
/// never read `skipped`, so a restore that kept another account's ids, or ids this account had
/// deleted, was pushed and refused on every sync, with the check-ins made on it since kept only
/// here (review data-safety-1). The marks are therefore also **unverified** until one full-pull
/// absence pass has run after the proof, and that pass has to tell such a row from one another
/// device deleted after this device's last 1.3.0 sync — the snapshot lacks both. 1.3.0 kept that
/// sync's pull cursor (`SyncDefaultsCursorStore.legacyKey`: the server's time less the overlap),
/// so the rule pins it at its first attempt, next to the last-sync time, and the pass's pull asks
/// the server for the account's deletions since it (`SyncMarksProof.deletionsSince`, where the
/// branches and why each holds after a sweep are set out).
enum SyncDeliveryMigration {
    /// Written by 1.3.0's `SyncService` (whole seconds, `SyncTimestamp.string`) and still by
    /// 1.3.1's, for the Settings display — which is why the rule must run before 1.3.1's first
    /// sync, and never again after it.
    static let lastSyncTimeKey = "stride_last_sync_time"
    static let doneKey = "stride_delivery_migration_v1_done"
    /// The 1.3.0 value, pinned at the first attempt. If that attempt fails (the save throws) the
    /// app may still sync before the next launch and overwrite `lastSyncTimeKey` with a 1.3.1
    /// time; the retry must use what 1.3.0 wrote, not that. "" pins "there was none".
    static let pinnedLastSyncKey = "stride_delivery_migration_v1_last_sync"
    static let margin: TimeInterval = 5 * 60

    struct Counts: Equatable {
        var habits = 0
        var records = 0
        var groups = 0
        var total: Int { habits + records + groups }
    }

    enum Outcome: Equatable {
        case alreadyDone
        case stamped(Counts)
        case failed
    }

    /// The rule itself, over a context: sets `syncedAt = stamp` on every never-delivered row
    /// whose stamp is at least `margin` before `lastSyncTime`. Mutates, does not save. With no
    /// value, or one that does not parse, nothing is stamped.
    static func stampMigratedRows(in context: ModelContext, lastSyncTime: String?) throws -> Counts {
        guard let lastSync = SyncTimestamp.parse(lastSyncTime) else { return Counts() }
        let cutoff = SyncTimestamp.milliseconds(lastSync) - Int64(margin * 1000)
        func markDelivered<Row: SyncDeliverable>(_ rows: [Row]) -> Int {
            var n = 0
            for row in rows where row.syncedAt == nil && SyncTimestamp.milliseconds(row.stamp) <= cutoff {
                row.syncedAt = SyncTimestamp.floorToMillisecond(row.stamp)
                n += 1
            }
            return n
        }
        var counts = Counts()
        counts.groups = markDelivered(try context.fetch(FetchDescriptor<HabitGroup>()))
        counts.habits = markDelivered(try context.fetch(FetchDescriptor<Habit>()))
        counts.records = markDelivered(try context.fetch(FetchDescriptor<HabitRecord>()))
        return counts
    }

    /// Every row's `syncedAt` back to nil, so a full pull keeps the rows (never delivered) and
    /// the push uploads them — or has them answered `not_owned` (held) or `tombstoned`
    /// (dropped, archived first). Holds, `needsResend` and `restoredAt` are untouched. Mutates,
    /// does not save: the reconciler forgets inside the pull it saves once.
    static func forgetMarks(habits: [Habit], groups: [HabitGroup]) -> Counts {
        func forget<Row: SyncDeliverable>(_ rows: [Row]) -> Int {
            var n = 0
            for row in rows where row.syncedAt != nil {
                row.syncedAt = nil
                n += 1
            }
            return n
        }
        var counts = Counts()
        counts.groups = forget(groups)
        counts.habits = forget(habits)
        counts.records = habits.reduce(0) { $0 + forget($1.records) }
        return counts
    }

    /// `forgetMarks` over the whole store, saved; on failure rolls back and throws. For
    /// `SyncMarksProof.forgetMarks(in:)` ("Upload these habits to this account").
    @discardableResult
    static func forgetDeliveryMarks(in context: ModelContext) throws -> Counts {
        do {
            let counts = forgetMarks(habits: try context.fetch(FetchDescriptor<Habit>()),
                                     groups: try context.fetch(FetchDescriptor<HabitGroup>()))
            if context.hasChanges { try context.save() }
            return counts
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Runs the rule once per install and saves. `defaults` is where `SyncService` keeps
    /// `stride_last_sync_time` (`UserDefaults.standard` in the app). Call it before the first
    /// sync of the launch.
    @discardableResult
    static func runOnceIfNeeded(in context: ModelContext, defaults: UserDefaults) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        // In the app's defaults the flags are per INSTALL, so the rule runs only on the install's
        // real store (upgrade race, E2E U123): a fallback store opened in its place got the done
        // flag, stamped 0 rows and pinned nothing, and the real store later pushed every row. A
        // test's throwaway suite is an install of its own. Refused like a failed save: no flag
        // is set, and `SyncService.sync` does not sync. A refusal, not an assertion, so the tests
        // (Debug builds) can prove it.
        if defaults === UserDefaults.standard, !SharedModelContainer.isRealStore(context.container) {
            Logger(subsystem: "yyh.stride.habittracker", category: "Migration")
                .error("Delivery-state migration refused: not the real store")
            return .failed
        }

        let proof = SyncMarksProof(defaults: defaults)
        let lastSync: String?
        if let pinned = defaults.string(forKey: pinnedLastSyncKey) {
            lastSync = pinned.isEmpty ? nil : pinned
        } else {
            lastSync = defaults.string(forKey: lastSyncTimeKey)
            defaults.set(lastSync ?? "", forKey: pinnedLastSyncKey)
            // 1.3.0's pull cursor, pinned with the time it was written at: the pass that verifies
            // the marks asks for the deletions since it (review data-safety-1). Pinned, a later
            // removal of 1.3.0's key (an erase, an account deletion) cannot change what it asks.
            proof.pinDeletionsSince(defaults.string(forKey: SyncDefaultsCursorStore.legacyKey))
        }

        do {
            let counts = try stampMigratedRows(in: context, lastSyncTime: lastSync)
            // Before the save: a crash between the two must not leave marks without the flags
            // (the retry finds them stamped and stamps nothing, so it would never set them). Flags
            // whose marks were rolled back are harmless — the proof finds nothing to forget. Both
            // flags: the proof, and the first absence pass after it (review data-safety-1).
            if counts.total > 0 { proof.require() }
            if context.hasChanges { try context.save() }
            defaults.set(true, forKey: doneKey)
            defaults.removeObject(forKey: pinnedLastSyncKey)
            // No mark waits for that pass: nothing will ask for deletions since the cursor.
            if !proof.isUnverified { proof.unpinDeletionsSince() }
            return .stamped(counts)
        } catch {
            // Not fatal: until it succeeds every row is merely "never delivered", which the
            // next push re-sends and a tombstone still answers. The pinned value keeps the
            // retry honest.
            context.rollback()
            Logger(subsystem: "yyh.stride.habittracker", category: "Migration")
                .error("Delivery-state migration failed: \(error.localizedDescription)")
            return .failed
        }
    }
}

// MARK: - The first full pull proves the account (owner decision, 2026-09-28)

/// Whether this store's delivery marks still wait for their proof.
///
/// Set when `SyncDeliveryMigration` stamps a row: those marks were inferred from 1.3.0's
/// last-sync time, for an account 1.3.0 never recorded — whether or not a session was still
/// stored at the first 1.3.1 launch, since an expired session keeps the key (M2 slice review).
/// Until the proof, the marks are provisional:
///
/// - Every run of `SyncEngine` starts with a FULL pull, whatever cursor the owner has, and no
///   push goes before it. (It would anyway: the first run after adoption has no cursor.)
/// - That pull decides, before its deletion pass (`SyncReconciler`): if the snapshot holds at
///   least one habit, group or entry id this device holds as delivered, the marks are this
///   account's and stand — ids are global primary keys on the server (`not_owned` exists
///   because of it), so another account's snapshot cannot hold one. If it holds none, every
///   mark is forgotten first, so the rows are kept and uploaded once, and an unproven store
///   never has a row deleted by its absence from another account's snapshot.
/// - A snapshot whose totals match its arrays decides even when a row in it is malformed: its
///   ids are all there, and every id this device delivered is a UUID. One whose totals are
///   missing or do not match (a truncated body proves nothing) decides only if it proves;
///   otherwise it applies nothing, the run ends before its push, and the next run full-pulls
///   again (review data-safety-2: what an undecided pull inserted, or its run acknowledged,
///   would otherwise be taken for proof by the next one).
///
/// Proven, the marks are still **unverified** until a full-pull absence pass has run after the
/// proof (review data-safety-1). A mark says 1.3.0 pushed the row, not that the server took it,
/// and a delivered row that pass finds absent from the account is one of two things:
///
/// - (a) deleted on another device after this store's last 1.3.0 pull — the everyday case for
///   anyone with two devices: an untap on the iPad, a habit deleted there;
/// - (b) refused by the 1.3.0 server and kept only here, since 1.3.0 never read `skipped`: a
///   restore that kept another account's ids (`not_owned`), or ids this account had deleted
///   before the restore (`tombstoned`), with every check-in made on it since. A row deleted
///   before that pull and still here can only be such a restore: every 1.3.0 pull applied the
///   deletions it carried, and a full pull deleted what the account lacked.
///
/// The snapshot lacks both. So the pass's pull sends 1.3.0's cursor, pinned by the migration
/// (`deletionsSince`), and the server lists, in the snapshot's own transaction, every habit, entry
/// and group the account deleted after it (`SyncPullResponse.deletionsSince`). The pass
/// (`SyncReconciler.apply`, `SyncUnverifiedPass`):
///
/// - **Listed** — its id is in the lists, a record's also when its habit's is: (a). Deleted by the
///   normal rule, as an incremental pull from that cursor would have: quietly for a row nobody
///   edited here, archived first when pending or held, held when restored.
/// - **Not listed, lists complete**: (b). Resent (`needsResend`) with `restoredAt` set, as the
///   restore it was, and the push's answer decides: `tombstoned` holds it — a habit with its
///   check-ins and those made on it since — for Restore as New Copies / Discard; `not_owned` holds
///   it; a row no server holds is inserted. The server refuses an id another account owns, so no
///   row crosses accounts.
/// - **No lists** — no cursor was pinned (1.3.0 never finished a sync on this store, or it came
///   from 1.2.2 or earlier, whose cursor was the device's clock), the cursor is past the server's
///   horizon (the device slept more than 355 days), or the server does not answer the field: (a)
///   and (b) cannot be told apart. Every such row is deleted, and archived first, pending or not.
///
/// Why each holds once tombstones are swept again (M0: only behind a 426 floor ≥ 1.3.1, and only
/// tombstones older than retention, 365 days). The server lists only for a cursor inside its
/// horizon — retention less the 10 days' grace, the `cursor_expired` rule — so every tombstone
/// newer than the cursor still exists, and a complete list misses no deletion made after it: a
/// row deleted elsewhere after the last 1.3.0 sync is never resent. Past the horizon nothing is
/// resent at all. What a resend can still insert after a sweep is a row whose deletion is older
/// than the cursor and older than retention: only (b)'s same-account restore, which today comes
/// back held `tombstoned` for the user's choice and after such a sweep is inserted — the restore
/// the user made, not a resurrection. Nothing is lost on any branch: (b) is held or inserted, and
/// what the no-lists branch deletes is in the recovery log.
///
/// Residuals. A (b) row another device deletes between this pull and the push that resends it is
/// held `tombstoned`, not dropped (its `restoredAt`), as a restored row is: the user's choice, not
/// a loss. A row deleted elsewhere after the last 1.3.0 sync and then brought back here by a 1.3.0
/// restore is listed and goes, unarchived when unedited, as 1.3.0's own next pull would have
/// removed it; the backup still holds it. The no-lists branch puts (a)'s rows in Recovered Edits
/// though nobody edited them here, and (b)'s there instead of the Restore as New Copies row. A
/// proving pull that decides but skips its absence pass (a row-level issue) leaves the marks
/// unverified until the next full pull, whenever that is, and by then the pinned cursor may be
/// past the horizon (no lists); incremental pulls meanwhile apply deletions as ever.
///
/// Settled by the deciding pull, by "Upload these habits to this account" (`forgetMarks`), and
/// by an erase (`SyncService.resetSyncState`: no rows, no marks). A sign-in to the same account
/// later needs no proof — the owner and its cursor resume. One residual of the proof itself: a
/// store whose every delivered row was deleted elsewhere holds nothing the snapshot can show, so
/// its marks are forgotten and it re-uploads. While tombstones are kept the answers are
/// `tombstoned` and the rows land in the recovery log; after a sweep they come back into the
/// account — a restore the user can undo, not a loss (DEV-PLAN-1.3.md M2, "Migrated rows").
struct SyncMarksProof {
    static let key = "stride_delivery_marks_unproven"
    /// Set with `key`, cleared by the first full-pull absence pass after the proof (review
    /// data-safety-1; `isUnverified`).
    static let unverifiedKey = "stride_delivery_marks_unverified"
    /// 1.3.0's pull cursor (`SyncDefaultsCursorStore.legacyKey`) as the migration found it at its
    /// first attempt; "" = there was none. What the pass that verifies the marks asks the server
    /// for the deletions since (`deletionsSince`). Removed with the unverified flag.
    static let deletionsSinceKey = "stride_delivery_marks_deletions_since"

    /// Where `SyncService` keeps the cursors and the owner (`UserDefaults.standard` in the app).
    let defaults: UserDefaults

    /// The marks wait for the first full pull of the adopting account.
    var isAwaited: Bool { defaults.bool(forKey: Self.key) }

    /// No full-pull absence pass has run since the proof: the next one asks for the deletions
    /// since 1.3.0's cursor and decides by them (`SyncReconciler.apply`'s `unverifiedPass`).
    var isUnverified: Bool { defaults.bool(forKey: Self.unverifiedKey) }

    /// The pinned 1.3.0 cursor, while it is a timestamp; nil when none was pinned (or it does not
    /// parse, which no server could list deletions since either).
    var deletionsSince: String? {
        guard let pinned = defaults.string(forKey: Self.deletionsSinceKey),
              SyncTimestamp.parse(pinned) != nil else { return nil }
        return pinned
    }

    /// The migration's first attempt: `cursor` is what 1.3.0 left under its key, nil for none.
    func pinDeletionsSince(_ cursor: String?) {
        defaults.set(cursor ?? "", forKey: Self.deletionsSinceKey)
    }

    func unpinDeletionsSince() { defaults.removeObject(forKey: Self.deletionsSinceKey) }

    /// The migration stamped rows: they wait for the proof, and for the first pass after it.
    func require() {
        defaults.set(true, forKey: Self.key)
        defaults.set(true, forKey: Self.unverifiedKey)
    }

    /// The proving pull held a row this device delivered: the marks are this account's and
    /// stand. They stay unverified until an absence pass has run (`markVerified`).
    func markProven() { defaults.removeObject(forKey: Self.key) }

    /// A full pull's absence pass ran after the proof and settled what the marks could not vouch
    /// for. From here on a delivered row the account lacks was deleted elsewhere, and the pass
    /// deletes it; the pinned cursor has done its job.
    func markVerified() {
        defaults.removeObject(forKey: Self.unverifiedKey)
        unpinDeletionsSince()
    }

    /// Nothing is left to prove or verify: every mark was forgotten (a proof that found none of
    /// the rows, "Upload these habits") or erased with the rows.
    func settle() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.unverifiedKey)
        unpinDeletionsSince()
    }

    /// "Upload these habits to this account" (the account screen, M2 phase C; sub-decision (e)).
    /// The user said these rows go up, so no mark may let the adoption's full pull delete one —
    /// even when the account is the marks' own: its deletions come back as `tombstoned` answers
    /// (dropped, archived first) while tombstones are kept. Forgets every mark, saves, settles.
    @MainActor @discardableResult
    func forgetMarks(in context: ModelContext) throws -> SyncDeliveryMigration.Counts {
        let counts = try SyncDeliveryMigration.forgetDeliveryMarks(in: context)
        settle()
        return counts
    }
}

/// What a proving full pull decided (`SyncMarksProof`).
enum SyncMarksVerdict: Equatable {
    /// The snapshot holds this row, which the device holds as delivered: the marks stand.
    case proven(SyncRowRef)
    /// It holds none of them: every mark was forgotten before the deletion pass.
    case forgotten(SyncDeliveryMigration.Counts)
    /// It holds none, but its totals are missing or do not match its arrays: nothing decided,
    /// nothing applied, and the run ends before its push (review data-safety-2).
    case undecided
}

/// What the first full-pull absence pass after the proof knows of the account's deletions since
/// this store's last 1.3.0 pull (`SyncMarksProof`, review data-safety-1), and so what it does with
/// a delivered row the account lacks.
enum SyncUnverifiedPass: Equatable {
    /// Every deletion since that pull is listed: a row in the lists goes by the normal rule, one
    /// not in them is resent as the restore it was.
    case deletionsListed(SyncDeletedIDs)
    /// No list (no pinned cursor, one past the server's horizon, a server that does not answer):
    /// such a row is deleted, and archived first whatever its state.
    case deletionsUnknown

    /// The lists only when the pull asked for them (`asked`, the pinned cursor it sent) and the
    /// server answered them complete. A list the pull did not ask for could be about any time.
    @MainActor
    init(asked: String?, answer: SyncDeletionsSince?) {
        if asked != nil, let lists = answer?.lists {
            self = .deletionsListed(lists)
        } else {
            self = .deletionsUnknown
        }
    }

    /// Which of the two ran, for the report and the run's summary (without the lists).
    enum Mode: Equatable {
        case deletionsListed
        case deletionsUnknown
    }

    var mode: Mode {
        switch self {
        case .deletionsListed: return .deletionsListed
        case .deletionsUnknown: return .deletionsUnknown
        }
    }
}
