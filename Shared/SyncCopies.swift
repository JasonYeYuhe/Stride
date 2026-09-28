import Foundation
import SwiftData

// Converting held rows in place: "Restore as new copies" and "Discard" for rows the server will
// never take under their ids (DEV-PLAN-1.3.md M2, "Restore into another account, and restores
// the server has tombstoned"; review 2). Two holds end here:
//
// - `not_owned`: the id exists under another account — a restore that kept another account's
//   ids (a 1.3.0 backup has no account to tell), or a device whose owner was unknown and whose
//   user chose "Upload these habits".
// - `tombstoned`: a row restored with its ids (`restoredAt`) whose id another device deleted.
//   A restore undoes that deletion only when the user says so, and then as new rows — the
//   tombstone stays authoritative for the old id.
//
// Not `DataBackup.restore`, which refuses any store that is not empty (`storeNotEmpty`): held
// rows sit in a live store beside rows that sync normally. Pure over a context handed in, in
// Shared/ so StrideTests run the code that ships (README, "The Shared/ rule"). The sync section's
// inline rows and their buttons are phase C.

/// Held rows, as the sync section lists them and as the two operations take them.
///
/// A habit stands for all of its check-ins: they are converted or discarded with it, held or
/// not, so they are not listed again in `records`. `records` holds only check-ins held on their
/// own — a restored check-in whose day was untapped on another device, on a habit that is fine.
struct SyncHeldRows {
    var groups: [HabitGroup] = []
    var habits: [Habit] = []
    var records: [HabitRecord] = []

    var isEmpty: Bool { groups.isEmpty && habits.isEmpty && records.isEmpty }
    var counts: SyncRowCounts {
        SyncRowCounts(groups: groups.count, habits: habits.count, entries: records.count)
    }
}

@MainActor
enum SyncCopies {
    /// The holds whose cause is the id itself, so a new id resolves them. The other reasons
    /// (`missing_field`, `row_error`, `invalid_value`, `unknown_habit`, `too_large`) are about
    /// the row's content, which a new id would re-send unchanged into the same refusal; an edit
    /// lifts those. `nonisolated`: it is a constant, and `heldRows`' default argument (evaluated
    /// outside the main actor) reads it — main-actor isolated, that is an error in Swift 6.
    nonisolated static let convertibleReasons: Set<SyncHoldReason> = [.notOwned, .tombstoned]

    /// What an operation did.
    struct Outcome: Equatable {
        /// Rows converted (new id) or discarded (deleted); a habit's check-ins are counted in
        /// `entries`.
        var rows = SyncRowCounts()
        /// Rows passed in that were left exactly as they were: not held for one of
        /// `convertibleReasons` any more (an edit since the list was drawn lifted the hold — the
        /// widget can do that under an open Settings screen), deleted, from another context, or
        /// a check-in whose habit is itself held and not part of this call.
        var ignored = SyncRowCounts()
        /// Old id → new id, habits and groups. Reminders are scheduled under the habit's id and a
        /// configured widget names one: the caller moves them (for reminders,
        /// `NotificationService.rescheduleAllHabitReminders` prunes the old ids).
        var habitIDs: [UUID: UUID] = [:]
        var groupIDs: [UUID: UUID] = [:]
        /// Habits that were not converted but pointed at a converted group: their `groupId` now
        /// names the group's new id, and they were `touch()`ed so the change goes up.
        var regroupedHabits = 0
    }

    // MARK: Listing

    /// The rows held for one of `reasons` — for the sync section's counts ("N restored habits
    /// were deleted on another device") and as the input of `reidentify` / `discard`. Reads the
    /// store; mutates nothing.
    static func heldRows(in context: ModelContext,
                         reasons: Set<SyncHoldReason> = convertibleReasons) throws -> SyncHeldRows {
        func wanted(_ row: some SyncDeliverable) -> Bool {
            row.activeHold.map(reasons.contains) ?? false
        }
        // `syncHoldStamp != nil` narrows each fetch to rows that were ever held; `activeHold`
        // then decides at millisecond precision, which a predicate cannot express.
        var held = SyncHeldRows()
        held.groups = try context.fetch(FetchDescriptor<HabitGroup>(
            predicate: #Predicate { $0.syncHoldStamp != nil })).filter { wanted($0) }
        held.habits = try context.fetch(FetchDescriptor<Habit>(
            predicate: #Predicate { $0.syncHoldStamp != nil })).filter { wanted($0) }
        let records = try context.fetch(FetchDescriptor<HabitRecord>(
            predicate: #Predicate { $0.syncHoldStamp != nil })).filter { wanted($0) }
        guard !records.isEmpty else { return held }

        // A record's habit is known only from the habit's side (`Habit.records` has no inverse).
        var coveredByHabit = Set<PersistentIdentifier>()
        for habit in held.habits { coveredByHabit.formUnion(habit.records.map(\.persistentModelID)) }
        held.records = records.filter { !coveredByHabit.contains($0.persistentModelID) }
        return held
    }

    // MARK: Restore as new copies

    /// Gives held rows fresh ids in place, the way the reconciler's id alignment re-ids a row:
    ///
    /// - a held habit gets a fresh id together with ALL of its check-ins, held or not — they are
    ///   the server's rows of the old habit id as much as it is;
    /// - a held group gets a fresh id, and every habit pointing at it follows. A habit that is
    ///   not converted with it is `touch()`ed, so its new `groupId` goes up (the planner sends
    ///   groups before habits, so the group lands first); one still held for another reason is
    ///   remapped without an edit, which would lift that hold, and sends the new id with its
    ///   next real edit;
    /// - a held check-in whose habit is live gets a fresh id alone (a check-in has no `habitId`
    ///   of its own to remap). One whose habit is held and not in this call is ignored: under a
    ///   refused habit id the server would refuse it again (`not_owned_habit`,
    ///   `tombstoned_habit`).
    ///
    /// Every converted row loses its hold and `restoredAt`, and gets `syncedAt = nil` (and no
    /// forced resend): it is a new row, never delivered. That is written, not assumed. A
    /// `syncedAt` left from the old id (a check-in the old habit delivered before it was
    /// refused) would read as "delivered, then deleted elsewhere" at the next full pull, which
    /// deletes it. `createdAt` / `updatedAt` are kept, as in a restore: the same history, and no
    /// fresh stamp to let an old value beat newer edits.
    ///
    /// No deletion is queued for the old ids — there is no queue parameter to queue into. The
    /// tombstone, or the other account's row, stays exactly as it is; a deletion sent under this
    /// account would be answered for a row it never had, or delete the one it has.
    ///
    /// Rows that are not held for a `convertibleReasons` reason are **ignored**, not refused
    /// (`Outcome.ignored`): the list the user tapped was drawn earlier, and an edit since, in the
    /// app or the widget, lifts a hold by itself. That row is pending again and gets its own
    /// answer; converting it anyway would turn an edit of a live row into a duplicate.
    ///
    /// Unsaved edits in the context are saved first, on their own, so the rollback on a failed
    /// save never takes a check-in the user just made (the reconciler's rule). Then one save.
    /// The caller runs this with no sync in flight (`SyncService.waitUntilIdle`), reschedules
    /// reminders and reloads widgets.
    @discardableResult
    static func reidentify(_ rows: SyncHeldRows, in context: ModelContext) throws -> Outcome {
        if context.hasChanges { try context.save() }

        var outcome = Outcome()
        let groups = eligible(rows.groups, in: context, ignored: &outcome.ignored.groups)
        let habits = eligible(rows.habits, in: context, ignored: &outcome.ignored.habits)
        let convertingHabits = Set(habits.map(\.persistentModelID))

        do {
            // Groups first, so the habits below remap to their new ids.
            for group in groups {
                let new = UUID()
                outcome.groupIDs[group.id] = new
                group.id = new
                becomeNewRow(group)
                outcome.rows.groups += 1
            }

            let allHabits = try context.fetch(FetchDescriptor<Habit>())
            if !outcome.groupIDs.isEmpty {
                for habit in allHabits {
                    guard let old = habit.groupId, let new = outcome.groupIDs[old] else { continue }
                    habit.groupId = new
                    if convertingHabits.contains(habit.persistentModelID) || habit.isHeld { continue }
                    habit.touch()
                    outcome.regroupedHabits += 1
                }
            }

            for habit in habits {
                let new = UUID()
                outcome.habitIDs[habit.id] = new
                habit.id = new
                becomeNewRow(habit)
                outcome.rows.habits += 1
                for record in live(habit.records) {
                    record.id = UUID()
                    becomeNewRow(record)
                    outcome.rows.entries += 1
                }
            }

            if !rows.records.isEmpty {
                let owners = habitsByRecord(allHabits)
                var seen = Set<PersistentIdentifier>()
                for record in rows.records where seen.insert(record.persistentModelID).inserted {
                    let habit = owners[record.persistentModelID]
                    // Converted with its habit above, and counted there.
                    if let habit, convertingHabits.contains(habit.persistentModelID) { continue }
                    // No habit at all (an orphan from an old bug) is ignored too: the planner
                    // walks habits, so a check-in without one is never sent under any id.
                    guard isEligible(record, in: context), let habit,
                          !(habit.activeHold.map(convertibleReasons.contains) ?? false)
                    else { outcome.ignored.entries += 1; continue }
                    record.id = UUID()
                    becomeNewRow(record)
                    outcome.rows.entries += 1
                }
            }

            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
        return outcome
    }

    // MARK: Discard

    /// Deletes held rows locally and queues nothing: the server keeps the tombstone, or the
    /// other account keeps its row, and nothing about either is this device's to change. A
    /// restored row's backup file still has it.
    ///
    /// - A habit goes with all its check-ins (`.cascade`).
    /// - A check-in held alone is taken out of its habit's `records` before it is deleted: the
    ///   relationship has no inverse, and a habit already loaded keeps a deleted record in that
    ///   array until it is fetched again (the ghost `HabitCheckIn.liveRecord` guards against).
    /// - A group goes alone. Habits pointing at it keep their `groupId`, as when a group is
    ///   deleted on another device: a `groupId` naming no group reads as ungrouped everywhere,
    ///   and clearing it would be an edit to upload for a row the user did not touch.
    ///
    /// Not archived to the recovery log: the user chose this, on rows the list showed them.
    /// Rows not held for a `convertibleReasons` reason are ignored, as in `reidentify` — a
    /// discard must never delete a row an edit has since made live. Saves once, after saving the
    /// context's own pending edits first.
    @discardableResult
    static func discard(_ rows: SyncHeldRows, in context: ModelContext) throws -> Outcome {
        if context.hasChanges { try context.save() }

        var outcome = Outcome()
        let groups = eligible(rows.groups, in: context, ignored: &outcome.ignored.groups)
        let habits = eligible(rows.habits, in: context, ignored: &outcome.ignored.habits)
        let discardingHabits = Set(habits.map(\.persistentModelID))

        do {
            if !rows.records.isEmpty {
                let owners = habitsByRecord(try context.fetch(FetchDescriptor<Habit>()))
                var seen = Set<PersistentIdentifier>()
                for record in rows.records where seen.insert(record.persistentModelID).inserted {
                    let habit = owners[record.persistentModelID]
                    if let habit, discardingHabits.contains(habit.persistentModelID) { continue } // goes with it
                    guard isEligible(record, in: context) else { outcome.ignored.entries += 1; continue }
                    if let habit { habit.records.removeAll { $0.persistentModelID == record.persistentModelID } }
                    context.delete(record)
                    outcome.rows.entries += 1
                }
            }
            for habit in habits {
                outcome.rows.entries += live(habit.records).count
                context.delete(habit)
                outcome.rows.habits += 1
            }
            for group in groups {
                context.delete(group)
                outcome.rows.groups += 1
            }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
        return outcome
    }

    // MARK: Helpers

    /// Held for a convertible reason, and a live row of this context.
    private static func isEligible(_ row: some SyncDeliverable & PersistentModel, in context: ModelContext) -> Bool {
        guard row.modelContext === context, !row.isDeleted else { return false }
        return row.activeHold.map(convertibleReasons.contains) ?? false
    }

    /// `rows` without the ineligible ones (counted) and without repeats.
    private static func eligible<Row: SyncDeliverable & PersistentModel>(
        _ rows: [Row], in context: ModelContext, ignored: inout Int
    ) -> [Row] {
        var seen = Set<PersistentIdentifier>()
        return rows.filter { row in
            guard seen.insert(row.persistentModelID).inserted else { return false }
            guard isEligible(row, in: context) else { ignored += 1; return false }
            return true
        }
    }

    /// The row as a fresh insert would be: never delivered, not held, not restored.
    private static func becomeNewRow(_ row: some SyncDeliverable) {
        row.releaseHold()
        if row.syncedAt != nil { row.syncedAt = nil }
        if row.needsResend { row.needsResend = false }
        if row.restoredAt != nil { row.restoredAt = nil }
    }

    /// `habit.records` without the ghosts a deletion leaves in it (see `HabitCheckIn.liveRecord`).
    private static func live(_ records: [HabitRecord]) -> [HabitRecord] {
        records.filter { $0.modelContext != nil && !$0.isDeleted }
    }

    private static func habitsByRecord(_ habits: [Habit]) -> [PersistentIdentifier: Habit] {
        var owners: [PersistentIdentifier: Habit] = [:]
        for habit in habits {
            for record in habit.records { owners[record.persistentModelID] = habit }
        }
        return owners
    }
}
