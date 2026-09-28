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

    /// Lifts a hold without an edit: "Restore as new copies", Discard.
    func releaseHold() {
        syncHoldReason = nil
        syncHoldStamp = nil
    }

    /// The reconciler applied the server's version of this row (update, insert, id alignment).
    /// Without this, the device's own push returns through the cursor's 60 s overlap, looks
    /// pending again, and every row echoes forever.
    ///
    /// Also clears `restoredAt`, which the spec lists only under acknowledgement: the server
    /// holding this id live for this account is the same evidence. Left set, a restored row
    /// whose first contact was a pull (not pending afterwards, so never acknowledged) could never
    /// again be deleted by another device — every later tombstone would hold it instead.
    func adoptRemoteState() {
        syncedAt = SyncTimestamp.floorToMillisecond(stamp)
        needsResend = false
        restoredAt = nil
        releaseHold()
    }

    /// Forced resend. `syncedAt` and holds stay: a held row is still not sent, and the evidence
    /// of delivery is what lets the full-pull rule tell "deleted elsewhere" from "never sent".
    func markNeedsResend() {
        needsResend = true
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
/// before it was in that snapshot. Later rows stay pending (a re-send is harmless). A 1.3.0
/// device that signed out cleared the key; its rows stay "never delivered" and the owner-unknown
/// choice decides them. A fresh 1.3.1 install has no key and stamps nothing.
///
/// The marks are true only for the account 1.3.0 last synced as, which 1.3.0 never recorded —
/// and a session that EXPIRED (1.3.0's `{user: null}` launch check, a 401) deleted the token
/// without clearing the key, so a dormant device can arrive stamped and signed out (M2 slice
/// review). Adopted by any other account, its first full pull would delete every stamped row as
/// "delivered, then deleted elsewhere", with nothing in the recovery log (they are not pending).
/// So `SyncService` forgets the marks (`forgetDeliveryMarks`) when a store with no owner is
/// adopted by an account it cannot prove is that one (`SyncOwnerStore.MarksAttribution`).
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

    /// Undoes the rule for a store adopted by an account the marks may not belong to: every
    /// row's `syncedAt` back to nil, so the adoption's full pull keeps the rows (never delivered)
    /// and the push uploads them — or has them answered `not_owned` (held) or `tombstoned`. Holds,
    /// `needsResend` and `restoredAt` are untouched. Saves; on failure rolls back and throws.
    @discardableResult
    static func forgetDeliveryMarks(in context: ModelContext) throws -> Counts {
        func forget<Row: SyncDeliverable>(_ rows: [Row]) -> Int {
            var n = 0
            for row in rows where row.syncedAt != nil {
                row.syncedAt = nil
                n += 1
            }
            return n
        }
        do {
            var counts = Counts()
            counts.groups = forget(try context.fetch(FetchDescriptor<HabitGroup>()))
            counts.habits = forget(try context.fetch(FetchDescriptor<Habit>()))
            counts.records = forget(try context.fetch(FetchDescriptor<HabitRecord>()))
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

        let lastSync: String?
        if let pinned = defaults.string(forKey: pinnedLastSyncKey) {
            lastSync = pinned.isEmpty ? nil : pinned
        } else {
            lastSync = defaults.string(forKey: lastSyncTimeKey)
            defaults.set(lastSync ?? "", forKey: pinnedLastSyncKey)
        }

        do {
            let counts = try stampMigratedRows(in: context, lastSyncTime: lastSync)
            if context.hasChanges { try context.save() }
            defaults.set(true, forKey: doneKey)
            defaults.removeObject(forKey: pinnedLastSyncKey)
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
