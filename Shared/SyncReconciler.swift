import Foundation
import SwiftData

/// Applies a `/v1/sync/pull` response to the local store.
///
/// This is the body of `SyncService.pullRemote` minus the network call, moved into Shared/
/// so StrideTests can run the real thing. It used to be tested through a copy pasted into
/// the test file, which is how the two bugs below stayed green.
///
/// 1. Ids were compared as raw strings. Swift's `UUID.uuidString` is UPPERCASE; the server
///    generates ids with Node's `crypto.randomUUID()`, which is lowercase (seed-demo.js,
///    routes/habits.js). Every map lookup and set membership therefore missed server-made
///    ids: pulled entries found no habit and were dropped, and a full pull then deleted
///    every local record because none of the local ids appeared in the server's set. Habits
///    survived only because their upsert happened to parse through `UUID(uuidString:)`,
///    which is case-insensitive — so they showed up with no history. The app itself only
///    ever sends uppercase ids, which means the one account guaranteed to hit this is the
///    App Review demo account, seeded server-side: a reviewer would see six habits with
///    0-day streaks and empty calendars.
/// 2. The habit maps were built with `Dictionary(uniqueKeysWithValues:)`, which traps on a
///    duplicate key. `Habit.id` has no uniqueness constraint, and bug 1 produced duplicates
///    (a lowercase id missed the map and inserted a second habit with the same UUID), so the
///    second sync crashed — inside the launch sync, i.e. on every launch.
///
/// Every id is now compared through `canonicalID`, maps use `uniquingKeysWith:`, and an
/// inserted habit or group is registered in its map so the same id appearing twice in one
/// response updates the row instead of inserting another.
///
/// From 1.3.1 (DEV-PLAN-1.3.md M2, "Reconciler", "Deletions", "Full-pull deletion rule"):
///
/// - Applying remote state marks the row delivered at the applied stamp and clears
///   `needsResend` and any hold (`SyncDeliverable.adoptRemoteState`) — otherwise this device's
///   own push comes back through the cursor's 60 s overlap, looks pending again, and every row
///   echoes forever.
/// - Habits, entries AND groups keep a local value that is strictly newer at millisecond
///   precision. Up to 1.3.0 only entries had the guard, flooring the local side to whole
///   seconds: right while the wire carried seconds, wrong from 1.3.1 — an edit at :18.700 made
///   while this device's :18.300 push was in flight floored to :18 and lost to its own echo.
/// - Every deletion path (`deleted*Ids`, full-pull absence, a habit's cascade to its records)
///   archives each affected pending or held row to the recovery log, one row per line, before
///   anything is deleted, and never deletes a row restored with its ids (`restoredAt`): that
///   row is held `tombstoned` for the restore-as-copies choice instead.
/// - The full-pull deletion pass runs only on a snapshot that was validated and applied whole
///   (`validate`). A failed check still applies the upserts — they are LWW-safe — and skips
///   only the deletion pass (sub-decision (d), 2026-09-28).
/// - One save per pull, after the recovery log is on disk. Anything that throws rolls the
///   context back: nothing is saved, and the caller writes no cursor.
/// - Deletions this device has queued but not yet delivered are authoritative until they are
///   (`queuedDeletions`): a pull applies no remote row with a queued id. Found by the M2 slice
///   review: a run that pulls before it pushes (no cursor — every device's first 1.3.1 sync —,
///   Full resync, `snapshot_required`, a forced resend) still gets the untapped check-in X back,
///   the day match below renamed the user's re-tap Y to X, and the push then carried both
///   `deletedEntryIds: [X]` and an upsert of X — which the server answers `tombstoned` (it
///   deletes first), so the re-tap was dropped on every device. 1.3.0 pushed before it pulled
///   and never met this.
/// - A full pull asked to prove a store's migrated delivery marks (`proveMarks`,
///   `SyncMarksProof`) decides them before anything is applied or deleted: they stand if the
///   snapshot holds a row this device holds as delivered, and are forgotten otherwise — so the
///   deletion pass of an account that is not the marks' own finds nothing delivered to delete.
///   One whose totals do not match cannot decide, and then applies nothing (review
///   data-safety-2).
/// - Until a full pull's absence pass has run after that proof (`unverifiedPass`), a delivered row
///   the account lacks goes by the deletions the account made since the store's last 1.3.0 pull:
///   listed, by the normal rule; not in a complete list, resent as the restore it was; with no
///   list, deleted and archived whatever its state — because a migrated mark says 1.3.0 pushed
///   the row, not that the server took it (review data-safety-1; `SyncMarksProof`).
@MainActor
enum SyncReconciler {
    /// The one form ids are compared in: the uppercase `uuidString` of the parsed UUID.
    /// A string that is not a UUID is upper-cased so it still compares consistently.
    static func canonicalID(_ raw: String) -> String {
        UUID(uuidString: raw)?.uuidString ?? raw.uppercased()
    }

    /// Applies `response`.
    ///
    /// - Parameters:
    ///   - isFullPull: the pull was made without `since`. Only a full pull runs the absence pass.
    ///   - proveMarks: the store's delivery marks are unproven (`SyncMarksProof.isAwaited`): this
    ///     full pull decides them first (`report.marks`). Ignored on an incremental pull, which
    ///     deletes only by explicit tombstones and cannot show what an account lacks. Undecided,
    ///     the pull applies nothing at all.
    ///   - unverifiedPass: no absence pass has run since the marks' proof
    ///     (`SyncMarksProof.isUnverified`), and what this pull says of the account's deletions
    ///     since the store's last 1.3.0 pull. This full pull's pass, if it runs, deletes a
    ///     delivered row the account lacks only when it is listed (or, with no list, archiving it
    ///     first whatever its state); one not in a complete list is kept, marked `needsResend`
    ///     and `restoredAt` (`report.markedForResend`). nil: verified, the normal rule. Ignored
    ///     on an incremental pull, which runs no pass.
    ///   - queuedDeletions: this device's deletion queue (`SyncDeletionQueue.pending()`), read
    ///     for this pull. A remote habit, entry or group whose id is queued — or an entry of a
    ///     queued habit — is not applied: the push carrying the deletion is still to come, and
    ///     the server will tombstone it then.
    ///   - recoveryLog: where pending and held rows go before a deletion takes them. The engine
    ///     always passes one. nil (1.3.0's `SyncService`, until it is rewired onto the engine)
    ///     deletes without archiving, as 1.3.0 did.
    ///   - accountID: the owner the run is bound to, recorded on each archived line.
    ///   - now: `archivedAt` for the lines this pull writes.
    /// - Throws: whatever the store or the recovery log threw. The context is rolled back first,
    ///   so a caller that catches it must write no cursor: the next sync retries the same pull.
    @discardableResult
    static func apply(
        _ response: SyncPullResponse,
        to context: ModelContext,
        isFullPull: Bool,
        proveMarks: Bool = false,
        unverifiedPass: SyncUnverifiedPass? = nil,
        queuedDeletions: SyncDeletionQueue.Batch = .init(),
        recoveryLog: (any SyncRecoveryLogSink)? = nil,
        accountID: String? = nil,
        now: Date = Date()
    ) throws -> SyncReconcileReport {
        // Edits the user made before this pull are saved on their own first, so a rollback below
        // discards only what this pull did — never an unsaved check-in.
        if context.hasChanges { try context.save() }

        var report = SyncReconcileReport(isFullPull: isFullPull)
        let parsed = ParsedEntries(response)
        report.issues = validate(response, entries: parsed, isFullPull: isFullPull)
        do {
            try applyValidated(response, entries: parsed, to: context, isFullPull: isFullPull,
                               proveMarks: proveMarks && isFullPull,
                               unverifiedPass: isFullPull ? unverifiedPass : nil,
                               queuedDeletions: queuedDeletions, report: &report, recoveryLog: recoveryLog,
                               accountID: accountID, now: now)
            return report
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Validation

    /// The checks a full pull must pass before its absence pass may delete anything
    /// ("Full-pull deletion rule", review 2). `totals` equal to the arrays is necessary — a
    /// truncated body or a timed-out query must never purge the local store — but not enough:
    /// the upserts silently skip ids that are not UUIDs, entries whose habit is missing and
    /// dates that do not parse, and the server accepts any non-empty string as an id, so two
    /// case variants of one UUID are two rows there and one row here. Each of those would make a
    /// row the server holds look absent.
    ///
    /// For an incremental pull only the row-level checks run (an entry's habit legitimately may
    /// not be in it), and they only report: its deletions are explicit tombstones.
    static func validate(_ response: SyncPullResponse, isFullPull: Bool) -> [SyncPullIssue] {
        validate(response, entries: ParsedEntries(response), isFullPull: isFullPull)
    }

    private static func validate(_ response: SyncPullResponse, entries parsed: ParsedEntries,
                                 isFullPull: Bool) -> [SyncPullIssue] {
        var issues: [SyncPullIssue] = []
        let groups = response.groups ?? []

        if isFullPull {
            if let totals = response.totals {
                if totals.habits != response.habits.count || totals.entries != response.entries.count
                    || totals.groups != groups.count {
                    issues.append(SyncPullIssue(kind: nil, id: nil, reason: .totalsMismatch))
                }
            } else {
                // Every server since M0 (deployed 2026-09-27) sends them; one that does not
                // cannot prove the snapshot is whole.
                issues.append(SyncPullIssue(kind: nil, id: nil, reason: .totalsMissing))
            }
        }

        func checkIDs(_ kind: SyncRowKind, _ ids: [String]) -> Set<String> {
            var seen = Set<String>()
            for id in ids {
                guard UUID(uuidString: id) != nil else {
                    issues.append(SyncPullIssue(kind: kind, id: id, reason: .invalidID)); continue
                }
                if !seen.insert(canonicalID(id)).inserted {
                    issues.append(SyncPullIssue(kind: kind, id: id, reason: .duplicateID))
                }
            }
            return seen
        }
        let habitIDs = checkIDs(.habit, response.habits.map(\.id))
        // Entries from the parse, not `checkIDs`: the same checks, over ids already parsed once.
        var seenEntries = Set<String>(minimumCapacity: parsed.rows.count)
        for (entry, row) in zip(response.entries, parsed.rows) {
            guard row.uuid != nil else {
                issues.append(SyncPullIssue(kind: .entry, id: entry.id, reason: .invalidID)); continue
            }
            if !seenEntries.insert(row.key).inserted {
                issues.append(SyncPullIssue(kind: .entry, id: entry.id, reason: .duplicateID))
            }
        }
        _ = checkIDs(.group, groups.map(\.id))

        for habit in response.habits where stamps(habit.createdAt, habit.updatedAt) == nil {
            issues.append(SyncPullIssue(kind: .habit, id: habit.id, reason: .invalidDate))
        }
        for group in groups where stamps(group.createdAt, group.updatedAt) == nil {
            issues.append(SyncPullIssue(kind: .group, id: group.id, reason: .invalidDate))
        }
        var days = Set<String>(minimumCapacity: parsed.rows.count)
        for (entry, row) in zip(response.entries, parsed.rows) {
            if row.date == nil || row.stamp == nil {
                issues.append(SyncPullIssue(kind: .entry, id: entry.id, reason: .invalidDate))
            }
            let habit = row.habitKey
            if isFullPull, !habitIDs.contains(habit) {
                issues.append(SyncPullIssue(kind: .entry, id: entry.id, reason: .missingHabit))
            }
            if !days.insert(habit + "|" + entry.date).inserted {
                // The reconciler matches an entry to a local record by habit and day, so the
                // second one re-keys the record and the first id then looks absent.
                issues.append(SyncPullIssue(kind: .entry, id: entry.id, reason: .duplicateDay))
            }
        }
        return issues
    }

    /// Both stamps of a habit or group, parsed; nil if either does not parse.
    private static func stamps(_ created: String, _ updated: String) -> (created: Date, updated: Date)? {
        guard let c = SyncTimestamp.parse(created), let u = SyncTimestamp.parse(updated) else { return nil }
        return (c, u)
    }

    // MARK: - Apply

    private static func applyValidated(
        _ response: SyncPullResponse,
        entries parsed: ParsedEntries,
        to context: ModelContext,
        isFullPull: Bool,
        proveMarks: Bool,
        unverifiedPass: SyncUnverifiedPass?,
        queuedDeletions: SyncDeletionQueue.Batch,
        report: inout SyncReconcileReport,
        recoveryLog: (any SyncRecoveryLogSink)?,
        accountID: String?,
        now: Date
    ) throws {
        let existingHabits = try context.fetch(FetchDescriptor<Habit>())
        let existingGroups = try context.fetch(FetchDescriptor<HabitGroup>())
        var habitMap = Dictionary(existingHabits.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var groupMap = Dictionary(existingGroups.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var removal = SyncLocalRemoval(reason: .deletedElsewhere, archivedAt: now)

        // Every local record an entry of this pull could match, loaded by one fetch over the days
        // the entries span, before the proof, the day index or the absence pass reads a record.
        // `Habit.records` hands back records whose fields are not loaded, and reading one then
        // costs a query of its own: a full pull onto a synced 54,750-entry store spent most of its
        // time firing those one by one. Held until the save, so the rows stay in memory.
        let preloaded = try SyncDayIndex.preload(parsed, in: context)
        defer { withExtendedLifetime(preloaded) {} }

        // Before anything below: the upserts mark what they apply as delivered and align record
        // ids to the server's, either of which would make the proof find what it put there.
        if proveMarks {
            let whole = !report.issues.contains { $0.reason == .totalsMissing || $0.reason == .totalsMismatch }
            report.marks = decideMarks(response, entryIDs: parsed.keys, habits: existingHabits,
                                       groups: existingGroups, snapshotIsWhole: whole)
            // Undecided, the pull applies nothing (review data-safety-2). Its upserts would mark
            // what they insert delivered, and the next proving pull would find those rows in the
            // same account's snapshot and take them for proof of marks this one could not prove.
            // The engine ends the run here too, so no push acknowledges a row either.
            if report.marks == .undecided { return }
        }

        // Remote deletions first, so nothing below resurrects them or matches onto them
        // (`removal.touches`). Collected, not yet applied: the recovery log must be on disk
        // before anything is deleted.
        let deletedHabitSet = Set((response.deletedHabitIds ?? []).map(canonicalID))
        let deletedEntrySet = Set((response.deletedEntryIds ?? []).map(canonicalID))
        let deletedGroupSet = Set((response.deletedGroupIds ?? []).map(canonicalID))
        // Deleted here, not yet delivered: the server still has these rows, so any pull before
        // the push that carries the deletion brings them back. Applying one would re-insert what
        // the user deleted, and — through the day match below — rename a re-tap of the same day
        // to the deleted id, which the push then deletes along with it.
        let queuedHabitSet = Set(queuedDeletions.habits.map(canonicalID))
        let queuedEntrySet = Set(queuedDeletions.entries.map(canonicalID))
        let queuedGroupSet = Set(queuedDeletions.groups.map(canonicalID))

        // Every local habit with the id, not only the map's first: `Habit.id` has no uniqueness
        // constraint, and the server holds one row for it.
        for habit in existingHabits where deletedHabitSet.contains(habit.id.uuidString) {
            removal.removeHabit(habit)
            habitMap.removeValue(forKey: habit.id.uuidString)
        }
        if !deletedEntrySet.isEmpty {
            // Fetched by id, then recognised by identifier on the walk through the habits (which
            // names each record's habit for the log): no other record's fields are read. An untap
            // on another device is an incremental pull with one deleted id, and reading every
            // record's id to find it meant a query per record of the store.
            let ids = (response.deletedEntryIds ?? []).compactMap { UUID(uuidString: $0) }
            let deleted = Set(try context.fetch(FetchDescriptor<HabitRecord>(
                predicate: #Predicate { ids.contains($0.id) })).map(\.persistentModelID))
            for habit in existingHabits where !deleted.isEmpty {
                for record in habit.records where deleted.contains(record.persistentModelID) {
                    removal.removeRecord(record, of: habit)
                }
            }
        }
        for group in existingGroups where deletedGroupSet.contains(group.id.uuidString) {
            removal.removeGroup(group)
            groupMap.removeValue(forKey: group.id.uuidString)
        }

        // Habits.
        for remoteHabit in response.habits {
            guard let uuid = UUID(uuidString: remoteHabit.id),
                  let parsed = stamps(remoteHabit.createdAt, remoteHabit.updatedAt)
            else { continue }   // reported by validate
            let (created, remoteStamp) = parsed
            let key = uuid.uuidString
            guard !deletedHabitSet.contains(key) else { continue }
            if queuedHabitSet.contains(key) {
                report.skippedQueuedDeletion.habits += 1
                continue
            }

            if let local = habitMap[key] {
                // Edited here after this device's push went out (a tap mid-sync, or a row fetched
                // again through the cursor's overlap): the local value is newer and goes up with
                // the next push — it stays pending, since its stamp is not the one delivered.
                if SyncTimestamp.isNewer(local.stamp, than: remoteStamp) {
                    report.keptLocalNewer.append(SyncRowRef(kind: .habit, id: key))
                    continue
                }
                assign(remoteHabit, to: local)
                local.updatedAt = remoteStamp
                local.adoptRemoteState()
                report.applied.habits += 1
            } else {
                let habit = Habit(name: remoteHabit.name, emoji: remoteHabit.emoji, colorHex: remoteHabit.colorHex)
                habit.id = uuid
                assign(remoteHabit, to: habit)
                habit.reminderEnabled = remoteHabit.reminderEnabled ?? false
                habit.reminderHour = remoteHabit.reminderHour ?? 20
                habit.reminderMinute = remoteHabit.reminderMinute ?? 0
                habit.createdAt = created
                habit.updatedAt = remoteStamp
                habit.adoptRemoteState()
                context.insert(habit)
                // Register it: the same id appearing again in this response, in either
                // case, must update this row rather than insert a second one.
                habitMap[key] = habit
                report.applied.habits += 1
            }
        }

        // Entries.
        //
        // Matched to local records through a per-habit index of days, built once per habit the
        // pull touches, and new records attached in one assignment per habit after the loop. Up
        // to the M2 slice this was `habit.records.first(where: isDate(_:inSameDayAs:))` per pulled
        // entry — a walk of the habit's whole history each time — and `habit.records.append` one
        // record at a time, each a whole-relationship write SwiftData diffs: a second device
        // joining a 20,000-entry account spent 51 s on the main actor (rehearsal S12, 1.3.1 slice
        // review; release/1.3.0 has the same two lines). Same match as before — the first record of
        // that UTC day no deletion in this pull has reached, a record this pull inserted included —
        // so a second entry for one day (`duplicate_day`) still lands on the record the first made.
        var days = SyncDayIndex(preloaded: preloaded)
        var missingHabitIssues = Set(report.issues.lazy.filter { $0.reason == .missingHabit }.compactMap(\.id))
        for (remoteEntry, row) in zip(response.entries, parsed.rows) {
            guard let entryUUID = row.uuid, let entryDate = row.date, let remoteStamp = row.stamp
            else { continue }   // reported by validate
            guard !deletedEntrySet.contains(row.key) else { continue }
            // Before the habit lookup: an entry of a habit deleted here is no missing habit, and
            // on a full pull a `missing_habit` issue would skip the whole deletion pass.
            if queuedEntrySet.contains(row.key) || queuedHabitSet.contains(row.habitKey) {
                report.skippedQueuedDeletion.entries += 1
                continue
            }
            guard let habit = habitMap[row.habitKey] else {
                // A full pull's validate already said so; an incremental one's entry for a habit
                // deleted here (or skipped above) is a skip all the same.
                if missingHabitIssues.insert(remoteEntry.id).inserted {
                    report.issues.append(SyncPullIssue(kind: .entry, id: remoteEntry.id, reason: .missingHabit))
                }
                continue
            }

            // Never a record a deletion in this same pull has reached. Another device that
            // untapped and re-tapped a day sends `deletedEntryIds: [X]` and the new entry Y
            // together; matched to X, Y's values went onto the object `removal.commit` then
            // deleted, and the device had no record for the day until a full pull (M2 slice
            // review). Y is inserted instead, and X goes (to the recovery log first if pending).
            if let existingRecord = days.record(of: habit, onDayOf: entryDate, excluding: removal) {
                // Align local ID to server ID so full-pull reconciliation won't delete it
                let realigned = existingRecord.id != entryUUID
                if realigned { existingRecord.id = entryUUID }
                // The local-newer guard, at milliseconds, strictly: see the type's comment. Only
                // against an edit stamp the server actually sent: a server before 2026-09-15 sent
                // none, and its `createdAt` (the day) says nothing about when the value changed.
                //
                // Under a new id, only for a value that still has to go up: pending, or held,
                // which the hold decides (review data-safety-3). A record delivered at its current
                // stamp that the server now holds under another id, with an older stamp, was
                // deleted there and its day added again (another device untapped and re-tapped
                // it, or took a count to zero and back). An incremental pull brings X's tombstone
                // and inserts Y: delete wins. A full pull brings no tombstone, and keeping the
                // "newer" local value under Y left a record neither pending nor equal to the
                // server's, on this device alone, until the day was edited again.
                if remoteEntry.updatedAt != nil, SyncTimestamp.isNewer(existingRecord.stamp, than: remoteStamp),
                   !realigned || existingRecord.isPending || existingRecord.isHeld {
                    report.keptLocalNewer.append(SyncRowRef(kind: .entry, id: entryUUID.uuidString))
                    continue
                }
                // Only what differs is written. Most entries a pull brings are rows this device
                // already holds as they are — its own push echoed back through the cursor's 60 s
                // overlap, a full pull of a synced store — and SwiftData counts every assignment as
                // a change, equal or not: the save then rewrote every such row (most of the time a
                // full pull onto a synced 54,750-entry store took, M2 large-account work).
                if existingRecord.note != remoteEntry.note { existingRecord.note = remoteEntry.note }
                let value = remoteEntry.value ?? 1
                if existingRecord.value != value { existingRecord.value = value }
                if existingRecord.updatedAt != remoteStamp { existingRecord.updatedAt = remoteStamp }
                existingRecord.adoptRemoteState()
            } else {
                let record = HabitRecord(date: entryDate, note: remoteEntry.note, value: remoteEntry.value ?? 1)
                record.id = entryUUID
                // Keep the edit time it was downloaded with. Left at init's Date(), a check-in
                // this device merely received would look freshly edited here and beat a genuinely
                // newer edit still waiting to sync on another device.
                record.updatedAt = remoteStamp
                // entryDate is already a UTC day-key parsed from the server's
                // yyyy-MM-dd; store it verbatim rather than re-deriving it from
                // the local calendar (which would shift it in non-UTC zones).
                record.date = HabitCalendar.startOfKey(entryDate)
                record.adoptRemoteState()
                days.add(record, to: habit)
            }
            report.applied.entries += 1
        }
        days.attachNewRecords()

        // Groups.
        for remoteGroup in response.groups ?? [] {
            guard let uuid = UUID(uuidString: remoteGroup.id),
                  let parsed = stamps(remoteGroup.createdAt, remoteGroup.updatedAt)
            else { continue }   // reported by validate
            let (created, remoteStamp) = parsed
            let key = uuid.uuidString
            guard !deletedGroupSet.contains(key) else { continue }
            if queuedGroupSet.contains(key) {
                report.skippedQueuedDeletion.groups += 1
                continue
            }
            if let local = groupMap[key] {
                if SyncTimestamp.isNewer(local.stamp, than: remoteStamp) {
                    report.keptLocalNewer.append(SyncRowRef(kind: .group, id: key))
                    continue
                }
                local.name = remoteGroup.name
                local.colorHex = remoteGroup.colorHex
                local.sortOrder = remoteGroup.sortOrder
                local.updatedAt = remoteStamp
                local.adoptRemoteState()
            } else {
                let group = HabitGroup(name: remoteGroup.name, colorHex: remoteGroup.colorHex, sortOrder: remoteGroup.sortOrder)
                group.id = uuid
                group.createdAt = created
                group.updatedAt = remoteStamp
                group.adoptRemoteState()
                context.insert(group)
                groupMap[key] = group
            }
            report.applied.groups += 1
        }

        // The full-pull absence pass: only on a snapshot validated and applied whole. A skip in
        // the upserts above lands in `issues` too, so this one condition covers both.
        //
        // While the store's delivery marks are unverified (`unverifiedPass`, review
        // data-safety-1), a delivered row the account lacks may have been deleted on another
        // device after the store's last 1.3.0 pull, or refused by the 1.3.0 server and kept only
        // here — 1.3.0 never read a refusal. The account's deletions since that pull tell them
        // apart (`SyncMarksProof`, which sets out why each branch holds once tombstones are swept):
        // - listed: deleted elsewhere. The normal rule, as an incremental pull from 1.3.0's cursor
        //   would have applied it: quiet for a row nobody edited here.
        // - not in a complete list: refused. Kept and resent with `restoredAt`, so the push's
        //   answer decides: `tombstoned` holds it (and the check-ins made on it since) for Restore
        //   as New Copies / Discard, `not_owned` holds it, a row no server holds is inserted. The
        //   server refuses an id another account owns, so no row crosses accounts.
        // - no list: the two cannot be told apart. Deleted, and archived first whatever its state:
        //   nothing lost, nothing resent into an account that may have swept its tombstone.
        // The engine clears the flag once this pass has run and saved.
        if isFullPull, report.issues.isEmpty {
            report.deletionPassRan = true
            report.unverifiedPass = unverifiedPass?.mode
            let remoteHabitIds = Set(response.habits.map { canonicalID($0.id) })
            let remoteEntryIds = parsed.keys
            let remoteGroupIds = Set((response.groups ?? []).map { canonicalID($0.id) })

            /// What becomes of a delivered, unheld row the snapshot lacks. `habit` is a record's.
            func absence(_ kind: SyncRowKind, _ id: UUID, habit: Habit? = nil) -> AbsentRow {
                guard let unverifiedPass else { return .delete }
                guard case .deletionsListed(let deleted) = unverifiedPass else { return .deleteArchiving }
                let listed: Bool
                switch kind {
                case .habit: listed = deleted.habits.contains(id.uuidString)
                case .group: listed = deleted.groups.contains(id.uuidString)
                case .entry:
                    listed = deleted.entries.contains(id.uuidString)
                        || habit.map { deleted.habits.contains($0.id.uuidString) } == true
                }
                return listed ? .delete : .resend
            }
            func resend(_ row: some SyncDeliverable, _ count: WritableKeyPath<SyncRowCounts, Int>) {
                if !row.needsResend { row.markNeedsResend() }
                if row.restoredAt == nil { row.restoredAt = now }
                report.markedForResend[keyPath: count] += 1
            }

            for habit in existingHabits where !remoteHabitIds.contains(habit.id.uuidString) {
                if absentRowIsKept(habit) { continue }
                switch absence(.habit, habit.id) {
                case .delete: removal.removeHabit(habit)
                case .deleteArchiving: removal.removeHabit(habit, archivingEveryRow: true)
                case .resend: resend(habit, \.habits)
                }
            }
            // Records of every surviving local habit — duplicates of one id included, and one kept
            // above as held, never delivered or resent. A habit this pull inserted has only pulled
            // records.
            for habit in existingHabits where !removal.isRemoving(habit) {
                for record in habit.records where !remoteEntryIds.contains(record.id.uuidString) {
                    if absentRowIsKept(record) { continue }
                    switch absence(.entry, record.id, habit: habit) {
                    case .delete: removal.removeRecord(record, of: habit)
                    case .deleteArchiving: removal.removeRecord(record, of: habit, archivingEveryRow: true)
                    case .resend: resend(record, \.entries)
                    }
                }
            }
            for group in existingGroups where !remoteGroupIds.contains(group.id.uuidString) {
                if absentRowIsKept(group) { continue }
                switch absence(.group, group.id) {
                case .delete: removal.removeGroup(group)
                case .deleteArchiving: removal.removeGroup(group, archivingEveryRow: true)
                case .resend: resend(group, \.groups)
                }
            }
        }

        // On disk before the delete (review 2). If the append fails, this pull's deletions are
        // not applied: the caller's catch rolls the context back and writes no cursor.
        if !removal.archive.isEmpty, let recoveryLog {
            do {
                try recoveryLog.archive(removal.archive, accountID: accountID)
            } catch {
                throw SyncReconcileError.recoveryLogFailed(String(describing: error))
            }
        }
        removal.commit(in: context)
        report.deleted = removal.deleted
        report.archived = removal.archive.count
        report.heldTombstoned = removal.heldTombstoned

        try context.save()
    }

    /// The proof (`SyncMarksProof`, owner decision 2026-09-28): does this snapshot hold a row
    /// this device holds as delivered? The account that adopted the store may not be the one the
    /// migrated marks were inferred for — a 1.3.0 session that expired keeps
    /// `stride_last_sync_time`, so "the device signed out" cannot be read from the key.
    ///
    /// Habit ids, as the owner put it, and group and entry ids as well: each is a global primary
    /// key on the server (routes/sync.js answers `not_owned` because of it), so another account's
    /// snapshot can hold none of them either. Without them, two stores with marks would fail a
    /// proof they should pass and re-upload: one holding only groups (every habit deleted), and
    /// one whose every habit was edited after the last 1.3.0 sync while its history was not (a
    /// reorder touches every active habit).
    ///
    /// Proven → the marks stand. None held and the snapshot whole → every mark forgotten, here,
    /// before the deletion pass. None held and not whole — totals missing, or not matching the
    /// arrays: a truncated body could have cut the very row that proves it → undecided, and the
    /// caller applies nothing.
    ///
    /// Whole means the totals, not every validation check (review data-safety-2). With matching
    /// totals the id sets are complete whatever else is wrong with a row — an id that is not a
    /// UUID, a case variant, a date that does not parse, an entry without its habit — and every
    /// id this device delivered is a UUID, so a malformed row cannot hide one. Such an issue still
    /// skips the deletion pass; it no longer leaves the marks provisional for a later pull to
    /// decide on rows this one inserted.
    private static func decideMarks(_ response: SyncPullResponse, entryIDs remoteEntries: Set<String>,
                                    habits: [Habit], groups: [HabitGroup],
                                    snapshotIsWhole: Bool) -> SyncMarksVerdict {
        let remoteHabits = Set(response.habits.map { canonicalID($0.id) })
        let remoteGroups = Set((response.groups ?? []).map { canonicalID($0.id) })
        if let habit = habits.first(where: { $0.hasBeenDelivered && remoteHabits.contains($0.id.uuidString) }) {
            return .proven(SyncRowRef(kind: .habit, id: habit.id.uuidString))
        }
        if let group = groups.first(where: { $0.hasBeenDelivered && remoteGroups.contains($0.id.uuidString) }) {
            return .proven(SyncRowRef(kind: .group, id: group.id.uuidString))
        }
        for habit in habits {
            if let record = habit.records.first(where: { $0.hasBeenDelivered && remoteEntries.contains($0.id.uuidString) }) {
                return .proven(SyncRowRef(kind: .entry, id: record.id.uuidString))
            }
        }
        guard snapshotIsWhole else { return .undecided }
        return .forgotten(SyncDeliveryMigration.forgetMarks(habits: habits, groups: groups))
    }

    /// A local row a validated full pull lacks is kept if held (the server refused it, so of
    /// course it lacks it) or never delivered (`syncedAt == nil`: a partially failed first
    /// upload, or a restore followed by a full pull, must not delete it). One restored with its
    /// ids is never deleted either: it is held `tombstoned` for the restore-as-copies choice.
    /// Everything else was delivered and the server no longer has it — another device deleted
    /// it — so it goes, `needsResend` or not: after a sweep a resend would be a new insert.
    /// (The `restoredAt` hold is `SyncLocalRemoval`'s, shared with every other deletion path.
    /// While the migrated marks are unverified, `AbsentRow` decides instead.)
    private static func absentRowIsKept<Row: SyncDeliverable>(_ row: Row) -> Bool {
        row.isHeld || !row.hasBeenDelivered
    }

    /// What the absence pass does with a delivered, unheld row a validated full pull lacks.
    private enum AbsentRow {
        /// Deleted elsewhere: the normal rule — pending and held rows archived first, a restored
        /// row held `tombstoned` (`SyncLocalRemoval`). Verified marks, or listed in the account's
        /// deletions since the store's last 1.3.0 pull.
        case delete
        /// Unverified marks and no list: deleted, and archived first whatever its state — it may
        /// be a row the 1.3.0 server refused, whose only copy this is.
        case deleteArchiving
        /// Unverified marks, not in the complete list: a row the 1.3.0 server refused. Kept and
        /// resent with `restoredAt`, for the push's answer to decide.
        case resend
    }

    private static func assign(_ remote: SyncHabit, to local: Habit) {
        local.name = remote.name
        local.emoji = remote.emoji
        local.colorHex = remote.colorHex
        local.isArchived = remote.isArchived
        local.sortOrder = Double(remote.sortOrder)
        if let re = remote.reminderEnabled { local.reminderEnabled = re }
        if let rh = remote.reminderHour { local.reminderHour = rh }
        if let rm = remote.reminderMinute { local.reminderMinute = rm }
        local.note = remote.note
        local.kind = remote.kind ?? HabitKind.binary.rawValue
        local.targetValue = remote.targetValue ?? 1
        local.unit = remote.unit
        local.scheduleKind = remote.scheduleKind ?? HabitSchedule.daily.rawValue
        local.timesPerWeek = remote.timesPerWeek ?? 7
        local.activeDaysMask = remote.activeDaysMask ?? 127
        local.groupId = remote.groupId.flatMap { UUID(uuidString: $0) }
    }
}

// MARK: - Parsing and matching, once per pull

/// A pull's entries, parsed once for both `validate` and the upserts: the id, the day and the
/// edit stamp of each, and its habit's canonical id. Up to the M2 slice each was parsed twice,
/// by `ISO8601DateFormatter` and `DateFormatter`, whose cost per call dominated a large pull
/// once the matching below stopped being quadratic. Stamps go through `SyncWireStamp` (the same
/// dates as `SyncTimestamp.parse`, without the formatter), and a string that repeats — a day
/// across every habit, a habit id across its history — is parsed once.
@MainActor
private struct ParsedEntries {
    struct Row {
        /// nil when the id is not a UUID (`invalid_id`).
        let uuid: UUID?
        /// `SyncReconciler.canonicalID(entry.id)`.
        let key: String
        let date: Date?
        /// The edit stamp. The server sends `COALESCE(client_updated_at, updated_at, created_at)`
        /// as `updatedAt`; a server from before 2026-09-15 sent none, and `createdAt` is then the
        /// best it said.
        let stamp: Date?
        /// `SyncReconciler.canonicalID(entry.habitId)`.
        let habitKey: String
    }

    let rows: [Row]
    /// Every entry's canonical id: the full pull's absence pass and the marks proof.
    let keys: Set<String>

    init(_ response: SyncPullResponse) {
        var days: [String: Date?] = [:]
        var stamps: [String: Date?] = [:]
        var habits: [String: String] = [:]
        func cached<V>(_ cache: inout [String: V], _ key: String, _ make: (String) -> V) -> V {
            if let hit = cache[key] { return hit }
            let value = make(key)
            cache[key] = value
            return value
        }
        var rows: [Row] = []
        rows.reserveCapacity(response.entries.count)
        for entry in response.entries {
            let uuid = UUID(uuidString: entry.id)
            // Day-only dates are UTC day-keys, matching the stored representation (HabitCalendar).
            let stampString = entry.updatedAt ?? entry.createdAt
            rows.append(Row(
                uuid: uuid,
                key: uuid?.uuidString ?? entry.id.uppercased(),
                date: cached(&days, entry.date) { HabitCalendar.dayStringFormatter.date(from: $0) },
                stamp: cached(&stamps, stampString) { SyncWireStamp.parse($0) },
                habitKey: cached(&habits, entry.habitId) { SyncReconciler.canonicalID($0) }))
        }
        self.rows = rows
        self.keys = Set(rows.lazy.map(\.key))
    }
}

/// The reconciler's day match for entries, one habit at a time: the local records of each UTC
/// day, in `habit.records` order, built on the first entry a pull brings for that habit, and the
/// records the pull inserts, attached to their habits in one assignment each at the end.
///
/// Keyed by `startOfDay` in `HabitCalendar.utc`, which is exactly `isDate(_:inSameDayAs:)`, the
/// comparison the match used to make record by record. A record a deletion in this pull reaches
/// (`SyncLocalRemoval.touches`) is left out when the day list is built: the deletions are all
/// collected before the first entry, so what it touches no longer changes. So is a record outside
/// the days the pull's entries span (`preload`): no entry can match it, and leaving it out means
/// its fields are never read.
@MainActor
private struct SyncDayIndex {
    /// The records `preload` fetched: only these can be on an entry's day.
    private let candidates: Set<PersistentIdentifier>
    private var days: [ObjectIdentifier: [Date: [HabitRecord]]] = [:]
    private var inserted: [(habit: Habit, records: [HabitRecord])] = []
    private var insertedSlot: [ObjectIdentifier: Int] = [:]

    init(preloaded: [HabitRecord]) {
        candidates = Set(preloaded.lazy.map(\.persistentModelID))
    }

    private static func day(_ date: Date) -> Date { HabitCalendar.utc.startOfDay(for: date) }

    /// Every local record dated inside the UTC days from the pull's first entry day to its last,
    /// in one fetch; none when it has no entry with a readable day.
    static func preload(_ parsed: ParsedEntries, in context: ModelContext) throws -> [HabitRecord] {
        let entryDays = parsed.rows.lazy.compactMap(\.date)
        guard let first = entryDays.min(), let last = entryDays.max(),
              let end = HabitCalendar.utc.date(byAdding: .day, value: 1, to: day(last))
        else { return [] }
        let start = day(first)
        return try context.fetch(FetchDescriptor<HabitRecord>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))
    }

    /// The first record of `habit` on `date`'s UTC day that `removal` has not reached — one this
    /// pull inserted included, after the habit's own.
    mutating func record(of habit: Habit, onDayOf date: Date, excluding removal: SyncLocalRemoval) -> HabitRecord? {
        let id = ObjectIdentifier(habit)
        if days[id] == nil {
            var byDay: [Date: [HabitRecord]] = [:]
            for record in habit.records where candidates.contains(record.persistentModelID) && !removal.touches(record) {
                byDay[Self.day(record.date), default: []].append(record)
            }
            days[id] = byDay
        }
        return days[id]?[Self.day(date)]?.first
    }

    /// A record this pull inserts. Call `attachNewRecords` before anything reads `habit.records`.
    mutating func add(_ record: HabitRecord, to habit: Habit) {
        let id = ObjectIdentifier(habit)
        days[id, default: [:]][Self.day(record.date), default: []].append(record)
        if let slot = insertedSlot[id] {
            inserted[slot].records.append(record)
        } else {
            insertedSlot[id] = inserted.count
            inserted.append((habit, [record]))
        }
    }

    /// One relationship write per habit, in the order the pull first inserted into each.
    func attachNewRecords() {
        for (habit, records) in inserted { habit.records.append(contentsOf: records) }
    }
}

// MARK: - Report

/// Something in a pull the reconciler could not apply whole. Ids as the server sent them and a
/// reason code — never a name, note or value: this is what a Sentry report carries.
struct SyncPullIssue: Equatable, Hashable {
    enum Reason: String {
        case totalsMissing = "totals_missing"
        case totalsMismatch = "totals_mismatch"
        case invalidID = "invalid_id"
        case duplicateID = "duplicate_id"
        case missingHabit = "missing_habit"
        case invalidDate = "invalid_date"
        case duplicateDay = "duplicate_day"
    }

    var kind: SyncRowKind?
    var id: String?
    var reason: Reason
}

struct SyncRowCounts: Equatable {
    var groups = 0
    var habits = 0
    var entries = 0

    var total: Int { groups + habits + entries }

    static func += (lhs: inout SyncRowCounts, rhs: SyncRowCounts) {
        lhs.groups += rhs.groups
        lhs.habits += rhs.habits
        lhs.entries += rhs.entries
    }
}

/// What one pull did, for the engine's summary and its reports.
struct SyncReconcileReport: Equatable {
    var isFullPull = false
    /// Validation failures and rows the upserts skipped. On a full pull, any of these skips the
    /// deletion pass; the upserts still applied.
    var issues: [SyncPullIssue] = []
    var deletionPassRan = false
    var applied = SyncRowCounts()
    /// Rows deleted (a habit's cascaded records counted as entries).
    var deleted = SyncRowCounts()
    /// Lines written to the recovery log.
    var archived = 0
    /// Rows restored with their ids that a deletion reached: held `tombstoned`, not deleted.
    var heldTombstoned: [SyncRowRef] = []
    /// Delivered rows the full pull lacked that its pass kept and marked `needsResend` and
    /// `restoredAt`: the store's delivery marks were unverified and the account's complete list of
    /// deletions since its last 1.3.0 pull did not name them (`unverifiedPass`, review
    /// data-safety-1). The next push lets the server answer for each.
    var markedForResend = SyncRowCounts()
    /// Which rule an absence pass under unverified marks ran by: the account's deletions listed,
    /// or unknown (every row it deleted archived). nil when the marks were verified or no pass ran.
    var unverifiedPass: SyncUnverifiedPass.Mode?
    /// Remote values not applied because the local stamp is strictly newer; those rows stay
    /// pending.
    var keptLocalNewer: [SyncRowRef] = []
    /// Remote rows not applied because this device has queued their deletion (or, for an entry,
    /// its habit's) and not yet delivered it.
    var skippedQueuedDeletion = SyncRowCounts()
    /// What this pull decided about unproven delivery marks; nil unless asked (`proveMarks`).
    var marks: SyncMarksVerdict?

    var deletionPassSkipped: Bool { isFullPull && !deletionPassRan }

    /// The report for Sentry when the pull had issues: ids and reason codes, counts per reason.
    var diagnostic: SyncDiagnosticReport? {
        guard !issues.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var reasons: [String: String] = [:]
        for issue in issues {
            counts[issue.reason.rawValue, default: 0] += 1
            if let id = issue.id { reasons[id] = issue.reason.rawValue }
        }
        counts["deletion_pass_skipped"] = deletionPassSkipped ? 1 : 0
        return SyncDiagnosticReport(event: isFullPull ? "full_pull_invalid" : "pull_rows_skipped",
                                    code: nil, status: 200, counts: counts, reasons: reasons)
    }
}

enum SyncReconcileError: Error, Equatable {
    /// The recovery log could not be written (disk full; file protection during a locked
    /// background sync). Nothing was deleted and nothing saved.
    case recoveryLogFailed(String)
}

// MARK: - Local removal (every deletion path)

/// Deletes local rows the server says are gone — a pull's `deleted*Ids`, full-pull absence, a
/// push answered `tombstoned` — by the one rule all of those paths share (DEV-PLAN-1.3.md M2,
/// "Deletions", review 2):
///
/// - every affected row that is pending or held is archived to the recovery log first, a
///   deleted habit's records one by one (checking only the habit missed an offline edit to a
///   check-in of a habit nobody touched) — every affected row, whatever its state, when the
///   caller cannot tell a deletion elsewhere from a refusal (`archivingEveryRow`);
/// - a row carrying `restoredAt` is never deleted: it is held `tombstoned`, as a push answered
///   `tombstoned` holds it — otherwise the restore-as-copies choice would be decided by whichever
///   request came back first. A habit with restored records is held with them: the records
///   cannot outlive their habit.
///
/// Collects first and mutates only in `commit`, after the caller has put `archive` on disk.
@MainActor
struct SyncLocalRemoval {
    let reason: SyncRecoveryReason
    let archivedAt: Date

    private(set) var archive: [SyncRecoveryItem] = []
    private(set) var deleted = SyncRowCounts()
    private(set) var heldTombstoned: [SyncRowRef] = []

    private var seen = Set<PersistentIdentifier>()
    private var habits: [Habit] = []
    private var records: [HabitRecord] = []
    private var groups: [HabitGroup] = []
    private var holds: [any SyncDeliverable] = []
    private var removingHabits = Set<PersistentIdentifier>()

    init(reason: SyncRecoveryReason, archivedAt: Date) {
        self.reason = reason
        self.archivedAt = archivedAt
    }

    var isEmpty: Bool { habits.isEmpty && records.isEmpty && groups.isEmpty && holds.isEmpty }

    /// Whether `habit` is about to be deleted (its records need no pass of their own).
    func isRemoving(_ habit: Habit) -> Bool { removingHabits.contains(habit.persistentModelID) }

    /// Whether a deletion has reached `record` — to be deleted, or held `tombstoned` — so no
    /// remote entry may be matched onto it by day.
    func touches(_ record: HabitRecord) -> Bool { seen.contains(record.persistentModelID) }

    /// `archivingEveryRow`: the habit and each of its records go to the log whatever their state —
    /// the full-pull pass under unverified marks with no list of the account's deletions, where
    /// the row may be one the 1.3.0 server refused and this its only copy (review data-safety-1).
    mutating func removeHabit(_ habit: Habit, archivingEveryRow: Bool = false) {
        guard seen.insert(habit.persistentModelID).inserted else { return }
        let restoredRecords = habit.records.filter { $0.restoredAt != nil }
        if habit.restoredAt != nil || !restoredRecords.isEmpty {
            hold(habit, ref: SyncRowRef(kind: .habit, id: habit.id.uuidString))
            for record in restoredRecords where seen.insert(record.persistentModelID).inserted {
                hold(record, ref: SyncRowRef(kind: .entry, id: record.id.uuidString))
            }
            return
        }
        if archivingEveryRow || habit.isPending || habit.isHeld { archive.append(item(habit)) }
        for record in habit.records.sorted(by: { $0.date < $1.date }) {
            guard seen.insert(record.persistentModelID).inserted else { continue }
            if archivingEveryRow || record.isPending || record.isHeld { archive.append(item(record, of: habit)) }
            deleted.entries += 1
        }
        habits.append(habit)
        removingHabits.insert(habit.persistentModelID)
        deleted.habits += 1
    }

    /// `habit` is the record's owner, for the archived line (`Habit.records` has no inverse).
    mutating func removeRecord(_ record: HabitRecord, of habit: Habit?, archivingEveryRow: Bool = false) {
        guard seen.insert(record.persistentModelID).inserted else { return }
        if record.restoredAt != nil {
            hold(record, ref: SyncRowRef(kind: .entry, id: record.id.uuidString)); return
        }
        if archivingEveryRow || record.isPending || record.isHeld { archive.append(item(record, of: habit)) }
        records.append(record)
        deleted.entries += 1
    }

    mutating func removeGroup(_ group: HabitGroup, archivingEveryRow: Bool = false) {
        guard seen.insert(group.persistentModelID).inserted else { return }
        if group.restoredAt != nil {
            hold(group, ref: SyncRowRef(kind: .group, id: group.id.uuidString)); return
        }
        // An offline rename of a group deleted elsewhere is an edit too (review 2).
        if archivingEveryRow || group.isPending || group.isHeld { archive.append(item(group)) }
        groups.append(group)
        deleted.groups += 1
    }

    /// Applies the holds and deletions. Call only once `archive` is on disk. Does not save.
    func commit(in context: ModelContext) {
        for row in holds { row.hold(.tombstoned) }
        // Records first: a record the habit's cascade would also take is not in `records`
        // (`seen`), so nothing is deleted twice.
        for record in records { context.delete(record) }
        for habit in habits { context.delete(habit) }   // `.cascade` takes its records
        for group in groups { context.delete(group) }
    }

    private mutating func hold(_ row: any SyncDeliverable, ref: SyncRowRef) {
        holds.append(row)
        heldTombstoned.append(ref)
    }

    // The v2 backup shapes (DataBackup), so the log reads like a backup and merge-import (M6)
    // can take it. A habit line holds the habit without its records; they get lines of their
    // own, so one line is one row.

    private func item(_ habit: Habit) -> SyncRecoveryItem {
        SyncRecoveryItem(archivedAt: archivedAt, reason: reason, row: .habit(BackupHabit(
            id: habit.id, name: habit.name, emoji: habit.emoji, colorHex: habit.colorHex,
            createdAt: habit.createdAt, updatedAt: habit.updatedAt, isArchived: habit.isArchived,
            sortOrder: habit.sortOrder, reminderEnabled: habit.reminderEnabled,
            reminderHour: habit.reminderHour, reminderMinute: habit.reminderMinute, note: habit.note,
            kind: habit.kind, targetValue: habit.targetValue, unit: habit.unit,
            scheduleKind: habit.scheduleKind, timesPerWeek: habit.timesPerWeek,
            activeDaysMask: habit.activeDaysMask, groupId: habit.groupId, records: [])))
    }

    /// A record carries its habit's id and name, so the line reads on its own.
    private func item(_ record: HabitRecord, of habit: Habit?) -> SyncRecoveryItem {
        SyncRecoveryItem(archivedAt: archivedAt, reason: reason, row: .record(
            BackupRecord(id: record.id,
                         date: HabitCalendar.dayStringFormatter.string(from: HabitCalendar.startOfKey(record.date)),
                         value: record.value, note: record.note, updatedAt: record.updatedAt),
            habitID: habit?.id, habitName: habit?.name))
    }

    private func item(_ group: HabitGroup) -> SyncRecoveryItem {
        SyncRecoveryItem(archivedAt: archivedAt, reason: reason, row: .group(BackupGroup(
            id: group.id, name: group.name, colorHex: group.colorHex, sortOrder: group.sortOrder,
            createdAt: group.createdAt, updatedAt: group.updatedAt)))
    }
}
