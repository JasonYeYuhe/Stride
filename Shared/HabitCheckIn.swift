import Foundation
import SwiftData

/// The one implementation of "write this habit's day" (RELEASE-1.4.1.md D4).
///
/// **Two families.**
/// - The UI's setters — `setChecked(_:on:of:in:)`, `setValue(_:on:of:in:)`,
///   `setNote(_:on:of:in:)` — take the state the user SAW and asked for (`setChecked(!shown)`,
///   `setValue(n)`), never "whatever the store holds now, toggled". Today's rows and History
///   call them inside `HabitEntryCommit.commit` (Stride/Sources), which saves, undoes on a failed
///   save, and only then queues tombstones and runs the effects. No UI path calls `tap`.
/// - The tap family — `tap`, `markDone`, `fromReminder` — for the paths that keep their own
///   semantics and save in their own contexts: the widget's toggle, Siri's "Complete a Habit",
///   a reminder's Mark Done / Add 1.
///
/// **Every write re-reads the day from the store** (`liveRecords(of:on:)`), at call time, and
/// matches `habit.records` to it by `persistentModelID` BEFORE reading any record's date, id,
/// value or note: a record another context or process deleted and saved faults on any attribute
/// read unless this context read it since (W1's progress-log entry, "Crash safety"), and it still
/// looks live in `habit.records`. The setters then take the store's current fields for those
/// records (`adoptStoredFields`) before deciding anything, so "writes only what differs" is true of
/// the store, not of a long-lived context's memory of it.
///
/// **What no write here ever does** (Data safety 2): write a value-0 record, write a note-only
/// yes/no record (a note needs the day's record, D7), write `createdAt`, or delete a record whose
/// note is non-empty without the caller's explicit `.removeNote` confirmation — the widget and
/// Siri cannot ask, so for them a noted yes/no check-in is simply not un-checked.
///
/// **Same-day duplicates** (2026-10-15 decision 7): every setter first merges a day that holds
/// more than one live record. It keeps the record D2 reads (`HabitRecord.outranks`: the largest
/// value, then the newest stamp, then the larger id — the same one on every device), moves
/// another record's non-empty note onto it — or, when two different notes would have to become
/// one, asks first (`.combineNotes`) and on confirmation joins them with a newline — and deletes
/// the rest HERE ONLY, with no tombstone, sending the kept record up again instead (`write`, "The
/// duplicates go", says why: the server holds one row per habit and day, so a duplicate's
/// tombstone could only ever delete the day). `tap` acts on the same kept record.
///
/// History of the tap (1.2.3): four places did this and only the main list got it right. The
/// widget's toggle and the watch deleted a count habit's whole partial day (6 of 8 glasses draws
/// as an empty circle, so the tap was invited, and the tombstone spread the loss to every device);
/// Siri's "Complete a Habit" appended a second record to a partially logged count day. Callers
/// save the context themselves and, only once that save succeeds, queue the tombstones for
/// `deletedRecordIDs` — so a failed save can never delete a record on the server.
enum HabitCheckIn {

    // MARK: - Confirmations (D7)

    /// What a write asks the user before it goes ahead. Nothing is written until the caller calls
    /// again with the same write and `confirmed:` set to this.
    enum Confirmation: Equatable {
        /// The write deletes the day's check-in, and the day carries a note: "Remove the check-in
        /// and its note?" — an un-check, a count stepped to 0, Reset.
        case removeNote
        /// The day holds more than one record (two devices checked it in), their notes differ, and
        /// keeping one record means keeping one note: "This day has more than one note. Combine
        /// them into one?" On confirmation they are joined, one per line.
        case combineNotes
    }

    // MARK: - The setters' result

    /// What a setter did, as `HabitEntryCommit` needs it.
    enum Change: Equatable {
        /// The store already held the target state: nothing written, no stamp, so the commit
        /// skips its save and its effects.
        case noChange
        /// Nothing written: the write needs the user's go first (`Confirmation`).
        case needsConfirmation(Confirmation)
        /// Written (not yet saved).
        case changed(Written)
    }

    struct Written: Equatable {
        /// The ids to tombstone, each once: the day's records when the write leaves the day with
        /// none (an un-check, a count set to 0, Reset). Queue them after the save, never before.
        /// Never the duplicates a day merge removed — those go on this device only — and so
        /// never an id a record of the day still carries.
        var deletedRecordIDs: [String]
        /// The day ends completed.
        var isCompleted: Bool
        /// The day's value afterwards; 0 when it holds no record.
        var loggedValue: Double
        /// The write moved the day toward done — created its record, or raised its value: a
        /// check-in, whose effects end the day's snooze and banners (`CheckInEffects`). An
        /// un-check, a lower value, a note or a merge alone is not one.
        var isCheckIn: Bool
    }

    // MARK: - The setters (D4)

    /// The day checked (`true`) or not (`false`); `nil` changes nothing but still merges the day.
    /// Pass the opposite of what the user saw (`setChecked(!shown)`), never a toggle.
    /// - yes/no: `true` creates the day's record when there is none; `false` deletes every live
    ///   record of the day (`.removeNote` first when one carries a note).
    /// - count (a stale yes/no row, or History's check): `true` raises the day to its target when
    ///   it is not complete; `false` deletes the day only when it IS complete — a day at 3 of 8 is
    ///   already "not checked", and its units are left alone.
    static func setChecked(_ checked: Bool?, on date: Date, of habit: Habit, in context: ModelContext,
                           confirmed: Confirmation? = nil, undo: Undo? = nil) -> Change {
        write(checked.map(Target.checked) ?? .unchanged, on: date, of: habit, in: context,
              confirmed: confirmed, undo: undo)
    }

    /// The day's value set to `value`; `nil` changes nothing but still merges the day.
    /// - count: a value ≤ 0 deletes the day (`.removeNote` first when one record carries a
    ///   note) — never a value-0 record; a positive value creates or edits the kept record.
    /// - yes/no: any positive value checks the day, keeping a record's own value; ≤ 0 un-checks.
    /// A value that is not finite (a NaN or an infinity from a stepper's arithmetic on a synced
    /// amount) writes nothing.
    static func setValue(_ value: Double?, on date: Date, of habit: Habit, in context: ModelContext,
                         confirmed: Confirmation? = nil, undo: Undo? = nil) -> Change {
        if let value, !value.isFinite { return .noChange }
        return write(value.map(Target.value) ?? .unchanged, on: date, of: habit, in: context,
                     confirmed: confirmed, undo: undo)
    }

    /// The day's note set to `note`; an empty string clears it; `nil` changes nothing but still
    /// merges the day. A day with no record takes no note (`.noChange`): a note-only yes/no
    /// record would read as done on every shipped client (D7). The note is stored as given —
    /// History's 500-character cap applies to new input there, and a longer stored note is
    /// never truncated here.
    static func setNote(_ note: String?, on date: Date, of habit: Habit, in context: ModelContext,
                        confirmed: Confirmation? = nil, undo: Undo? = nil) -> Change {
        write(note.map { Target.note(nonEmpty($0)) } ?? .unchanged, on: date, of: habit, in: context,
              confirmed: confirmed, undo: undo)
    }

    private enum Target {
        case unchanged
        case checked(Bool)
        case value(Double)
        /// Normalised: nil clears the note.
        case note(String?)
    }

    /// `setChecked(nil, …)` for a day whose live records the caller read from the store a moment
    /// ago (`liveRecords(of:onDays:)`), for a pass that merges many days at once: `DayKeyRepair`.
    /// The same merge, the same rules (decision 7 as amended: the record D2 reads kept, a lone note
    /// moved onto it, the others deleted here only with no tombstone, `.combineNotes` asked for two
    /// different notes), only without the per-call store read: in a context holding thousands of
    /// pending changes, that read is checked in memory against every one of them, and a read per
    /// day made the first repair of a 1,000-record store take 45 s (W10-PERF-1). `day` must be
    /// the day's live records as the store answered them, with nothing written to them since.
    static func merge(_ day: [HabitRecord], on date: Date, of habit: Habit, in context: ModelContext) -> Change {
        write(.unchanged, day: day.sorted { $0.outranks($1) }, on: date, of: habit, in: context,
              confirmed: nil, undo: nil)
    }

    /// The one write behind the three setters.
    private static func write(_ target: Target, on date: Date, of habit: Habit, in context: ModelContext,
                              confirmed: Confirmation?, undo: Undo?) -> Change {
        write(target, day: liveRecords(of: habit, on: date), on: date, of: habit, in: context,
              confirmed: confirmed, undo: undo)
    }

    /// `write` on `day`, the day's live records as the store holds them, in rank order.
    private static func write(_ target: Target, day stored: [HabitRecord], on date: Date, of habit: Habit,
                              in context: ModelContext, confirmed: Confirmation?, undo: Undo?) -> Change {
        var day = stored
        // Decided on, and compared with, what the store holds now — not this context's memory of it.
        if adoptStoredFields(of: day, in: context) { day.sort { $0.outranks($1) } }
        let kept = day.first
        let isCount = habit.habitKind == .count
        let current = kept?.value
        let completedNow = isCompleted(holding: current, habit)

        // What the kept record's value ends as; nil = the day ends with no record.
        var newValue: Double? = current
        switch target {
        case .unchanged, .note:
            break
        case .checked(let on):
            if on, !completedNow {
                // A yes/no day here has no record; a count day is raised to its goal, never lowered.
                newValue = isCount ? max(current ?? 0, habit.targetValue > 0 ? habit.targetValue : 1) : 1
            } else if !on, completedNow {
                newValue = nil
            }
        case .value(let value):
            if isCount {
                newValue = value > 0 ? value : nil
            } else {
                newValue = value > 0 ? (current ?? 1) : nil
            }
        }

        // The day ends empty: every live record of it goes, or the day stays checked.
        guard let value = newValue else {
            guard !day.isEmpty else { return .noChange }
            if day.contains(where: { nonEmpty($0.note) != nil }), confirmed != .removeNote {
                return .needsConfirmation(.removeNote)
            }
            let ids = distinctIDs(of: day)
            for record in day {
                undo?.deleted(record, of: habit)
                delete(record, of: habit, in: context)
            }
            // Stated rather than recomputed: until the context saves, `habit.records` still lists
            // the objects just deleted.
            return .changed(Written(deletedRecordIDs: ids, isCompleted: false, loggedValue: 0, isCheckIn: false))
        }

        guard let kept else {
            // An empty day gains its record. `value` > 0 here, so never a value-0 record; a note
            // alone never gets this far (`newValue` stays nil for `.note` on an empty day).
            let record = HabitRecord(date: date, value: value)
            habit.records.append(record)
            undo?.inserted(record, of: habit)
            return .changed(Written(deletedRecordIDs: [], isCompleted: isCompleted(holding: value, habit),
                                    loggedValue: value, isCheckIn: true))
        }

        // The merge's note, and this write's.
        let keptNote = nonEmpty(kept.note)
        var otherNotes: [String] = []   // distinct, in rank order, none equal to the kept note
        for record in day.dropFirst() {
            if let note = nonEmpty(record.note), note != keptNote, !otherNotes.contains(note) {
                otherNotes.append(note)
            }
        }
        let note: String?
        if case .note(let text) = target {
            // The user edited the note they saw — the kept record's. Another record's different
            // note is not theirs to drop silently.
            let extras = otherNotes.filter { $0 != text }
            if extras.isEmpty {
                note = text
            } else {
                guard confirmed == .combineNotes else { return .needsConfirmation(.combineNotes) }
                note = ([text].compactMap { $0 } + extras).joined(separator: "\n")
            }
        } else if otherNotes.isEmpty {
            note = keptNote
        } else if keptNote == nil, otherNotes.count == 1 {
            note = otherNotes[0]   // moved onto the kept record
        } else {
            guard confirmed == .combineNotes else { return .needsConfirmation(.combineNotes) }
            note = ([keptNote].compactMap { $0 } + otherNotes).joined(separator: "\n")
        }

        // Only what differs from the store is written, and the stamp moves only then.
        let valueChanges = kept.value != value
        let noteChanges = keptNote != note
        if valueChanges || noteChanges {
            undo?.edited(kept)
            if valueChanges { kept.value = value }
            if noteChanges { kept.note = note }
            kept.touch()
        }

        // The duplicates go — here only, with no tombstone (W2 review: "merge-tombstones-server-row",
        // SYNC-1, SYNC-2). The server holds ONE row per habit and day (routes/sync.js upsertEntry,
        // `ON CONFLICT(habit_id, date)`), applies a push's deletions before its rows, and blocks a
        // tombstoned id for good. So a duplicate's tombstone could only ever delete that day's one
        // row, and by its echo the day on every device (sync rehearsal M6-M8 measured each):
        // - under the duplicate's id, when the server had kept that one: the push deleted the row
        //   and nothing put it back, since a merge that left the kept record as it was sent nothing;
        // - under the kept record's OWN id, when the reconciler's day match had renamed both
        //   records onto the server's id: the kept record's push was refused `tombstoned` and
        //   dropped here too;
        // - while a chunk carrying the duplicate was in flight, the resolver passed its queued
        //   deletion on to the server's id (`SyncPushResolver.followAlias`), whichever was kept.
        // Instead the kept record goes up again. Its upsert lands on the day's one row whatever id
        // that row has; last writer wins at the kept record's stamp, which moves only when this
        // write changed the record; and the server's `aliases` answer (or the next pull's day
        // match) gives it the row's id, which no local record holds any more. So every device and
        // the server end with one record of the day, under one id. Another device's own duplicate
        // of the day stays until a write there merges it.
        let dropsDuplicates = day.count > 1
        for record in day.dropFirst() {
            undo?.deleted(record, of: habit)
            delete(record, of: habit, in: context)
        }
        if dropsDuplicates, !kept.isPending {
            // Not a `touch()`: a fresh stamp would let this device's copy of the day beat a newer
            // edit another device made to the server's row. The same stamp, sent again.
            undo?.edited(kept)
            kept.markNeedsResend()
        }
        guard valueChanges || noteChanges || dropsDuplicates else { return .noChange }
        return .changed(Written(deletedRecordIDs: [], isCompleted: isCompleted(holding: value, habit),
                                loggedValue: value, isCheckIn: value > (current ?? 0)))
    }

    // MARK: - The tap (widget, Siri, reminder actions)

    struct Result: Equatable {
        /// The records this call deleted — every live record of the day, for a yes/no un-check.
        /// Queue each one's tombstone after saving.
        var deletedRecordIDs: [String]
        var isCompleted: Bool
        var loggedValue: Double
        /// Set when the tap wrote nothing because it would have deleted a note (D7): a checked,
        /// noted yes/no day. The widget and Siri cannot ask, so the check-in stays.
        var needsConfirmation: Confirmation?

        init(deletedRecordIDs: [String] = [], isCompleted: Bool, loggedValue: Double,
             needsConfirmation: Confirmation? = nil) {
            self.deletedRecordIDs = deletedRecordIDs
            self.isCompleted = isCompleted
            self.loggedValue = loggedValue
            self.needsConfirmation = needsConfirmation
        }
    }

    /// A single tap for `date` — the widget's toggle (and the sync rehearsal's list tap). Toggles
    /// or adds one, on the day's kept record (`liveRecords(of:on:)`):
    /// - yes/no habit: checks it if unchecked; if checked, deletes every live record of the day
    ///   (two devices' duplicates included, or the day would stay checked) — unless one carries a
    ///   note, when it writes nothing and says so (`needsConfirmation`).
    /// - count habit: adds one unit to the kept record, creating the day's record at 1 if there is
    ///   none. It never deletes — not even a duplicate: taking units away is a separate, explicit
    ///   action in the app, and a merge is the setters' (which can ask).
    @discardableResult
    static func tap(_ habit: Habit, on date: Date, in context: ModelContext) -> Result {
        let day = liveRecords(of: habit, on: date)
        switch habit.habitKind {
        case .binary:
            if !day.isEmpty {
                guard !day.contains(where: { nonEmpty($0.note) != nil }) else {
                    return Result(isCompleted: true, loggedValue: 1, needsConfirmation: .removeNote)
                }
                let ids = distinctIDs(of: day)
                for record in day { delete(record, of: habit, in: context) }
                // Stated rather than recomputed: until the context saves, `habit.records` can
                // still contain the objects just deleted.
                return Result(deletedRecordIDs: ids, isCompleted: false, loggedValue: 0)
            }
            habit.records.append(HabitRecord(date: date))
            return Result(isCompleted: true, loggedValue: 1)

        case .count:
            let record: HabitRecord
            if let kept = day.first {
                kept.value += 1
                kept.touch()
                record = kept
            } else {
                record = HabitRecord(date: date, value: 1)
                habit.records.append(record)
            }
            // From the record itself, not `habit.isCompletedOn`: that reads `habit.records`, which
            // can still hold a deleted record ahead of this one (see `liveRecords(of:on:)`).
            return Result(isCompleted: isCompleted(holding: record.value, habit), loggedValue: record.value)
        }
    }

    /// The day's live records as the STORE has them — not as `habit.records` remembers them —
    /// ordered so that the first is the one D2 reads and decision 7 keeps (`HabitRecord.outranks`).
    ///
    /// `records` has no inverse relationship, and a Habit already loaded in a context keeps a
    /// deleted record in that array after the deletion is saved, until something fetches the
    /// habit again (the M2 sync rehearsal hit it as CoreData's "repairing missing delete
    /// propagation"). Measured 2026-09-28 (HabitCheckInTests, the ghost tests): after untap →
    /// save, the same Habit still listed the record — `isDeleted` false, `modelContext` nil —
    /// and `habit.record(on:)` returned it. Before 1.3.1:
    /// - a yes/no re-tap "deleted" the ghost again instead of checking the day: the day stayed
    ///   unchecked, and a second tombstone for the old id was queued;
    /// - a count tap after "remove one" took the day to zero added its unit to the ghost, which
    ///   no save writes, and reported the ghost's old value plus one.
    ///
    /// A deletion saved by ANOTHER context (the widget's intent runs in its own process) leaves a
    /// record that looks entirely live — context set, not deleted — and faults on its first
    /// attribute read, so only the store can say, and it is asked by `persistentModelID`, which
    /// reading never faults (`HabitStats.liveRecords(of:)`: one count, and the exact set only when
    /// the count is short). A record's date is read only once the store has vouched for it.
    /// Pending changes count: a record appended but not yet saved is live, one deleted but not yet
    /// saved is not. One small store query per write; a write is a user gesture, not a loop.
    static func liveRecords(of habit: Habit, on date: Date) -> [HabitRecord] {
        let counts = liveRecordFilter(of: habit)
        let day = HabitStats.dayNumber(of: date, in: .current)
        return habit.records
            .filter { counts($0) && HabitStats.dayNumber(ofKey: $0.date) == day }
            .sorted { $0.outranks($1) }
    }

    /// `liveRecords(of:on:)` for each of `days` (day numbers) at once, from ONE store answer for
    /// the habit: a day with no live record is absent. For `merge`.
    static func liveRecords(of habit: Habit, onDays days: Set<Int>) -> [Int: [HabitRecord]] {
        guard !days.isEmpty else { return [:] }
        let counts = liveRecordFilter(of: habit)
        var byDay: [Int: [HabitRecord]] = [:]
        for record in habit.records where counts(record) {
            let day = HabitStats.dayNumber(ofKey: record.date)
            if days.contains(day) { byDay[day, default: []].append(record) }
        }
        return byDay.mapValues { $0.sorted { $0.outranks($1) } }
    }

    /// Which of `habit.records` the store holds as live, decided before any record's date is read.
    private static func liveRecordFilter(of habit: Habit) -> (HabitRecord) -> Bool {
        switch HabitStats.liveRecords(of: habit) {
        case .attached: return { !$0.isDeleted && $0.modelContext != nil }
        case .persistentIDs(let ids): return { !$0.isDeleted && ids.contains($0.persistentModelID) }
        // Not an answer `liveRecords(of:)` gives; a set of ids can only be matched by reading them.
        case .ids(let ids): return { !$0.isDeleted && $0.modelContext != nil && ids.contains($0.id) }
        // The habit is in no context: there is no store to have deleted anything from.
        case .all: return { !$0.isDeleted }
        }
    }

    /// "Complete this habit" — Siri and Shortcuts. Unlike `tap`, it never removes anything:
    /// returns nil and changes nothing when the habit is already complete for the day;
    /// otherwise it is a `tap` (checks a yes/no habit, adds one unit to a count habit's kept
    /// record).
    static func markDone(_ habit: Habit, on date: Date, in context: ModelContext) -> Result? {
        // Not `habit.isCompletedOn`: a ghost of an unchecked day would read as done.
        let kept = liveRecords(of: habit, on: date).first
        let isComplete: Bool
        switch habit.habitKind {
        case .binary: isComplete = kept != nil
        case .count: isComplete = isCompleted(holding: kept?.value, habit)
        }
        guard !isComplete else { return nil }
        return tap(habit, on: date, in: context)
    }

    /// A reminder's Mark Done or Add 1 (RELEASE-1.4.0.md D4). Chosen by the habit's kind NOW, never
    /// by the button that was tapped: a delivered banner keeps the category — and so the button —
    /// it was scheduled with, while the kind can have changed since, by an edit here or a pull
    /// from another device.
    /// - yes/no → `markDone`: checks the day, or changes nothing (nil) when it is already checked.
    /// - count → `tap`: one more unit, past the target too — the button says "Add 1".
    ///
    /// **Never deletes.** `tap` on a yes/no habit that is already done removes the day's records,
    /// and the caller would queue the tombstones that remove them on every device. A stale "Add 1"
    /// on a count habit that became yes/no must leave that day alone (design review,
    /// "stale-category-addone-untoggles-binary"), so a yes/no habit never reaches `tap` here except
    /// through `markDone`, which only taps an unchecked day. There is no tombstone to queue after
    /// this call, ever.
    ///
    /// An archived habit is not checked in (nil): its reminders were removed when it was archived,
    /// so the response is a stale banner, and the habit is not on Today to show the result.
    ///
    /// `day` must be a day-key — `ReminderDay.resolve` — never `notification.date` itself
    /// (`HabitCalendar.dayKey(forInstant:)` says why).
    static func fromReminder(_ habit: Habit, on day: Date, in context: ModelContext) -> Result? {
        guard !habit.isArchived else { return nil }
        let result: Result?
        switch habit.habitKind {
        case .binary: result = markDone(habit, on: day, in: context)
        case .count: result = tap(habit, on: day, in: context)
        }
        assert(result?.deletedRecordIDs.isEmpty ?? true, "a reminder's check-in deleted a record")
        return result
    }

    // MARK: - Helpers

    /// Brings this context's copy of `records` up to the store's, where another context or
    /// process saved them since this one loaded them; true when anything was adopted.
    ///
    /// The setters run on mainContext, which lives as long as the window. A ModelContext does not
    /// take in what a sibling saves — Siri's and a reminder's check-ins (their own contexts, this
    /// process), the widget's (another process) — and a save writes the object's whole state, the
    /// fields it never touched included. Measured 2026-10-15 on this Mac (in memory and on disk,
    /// with and without main run-loop turns in between): a sibling context saved note B over A,
    /// then mainContext, still holding A, set only the value and saved — the store held A again.
    /// So a note added here after a reminder's Add 1 took the unit back, and a value edit after a
    /// note another context saved dropped that note (Data safety 1). The store is read through a
    /// context of its own (this one would hand back the same stale objects), only for records with
    /// no pending change here: one this context inserted or edited holds its own newer state.
    /// One extra small fetch per setter call; the setters are user gestures.
    @discardableResult
    private static func adoptStoredFields(of records: [HabitRecord], in context: ModelContext) -> Bool {
        guard !records.isEmpty else { return false }
        var pending = Set(context.insertedModelsArray.map(\.persistentModelID))
        pending.formUnion(context.changedModelsArray.map(\.persistentModelID))
        let ids = records.map(\.persistentModelID).filter { !pending.contains($0) }
        guard !ids.isEmpty else { return false }
        let reader = ModelContext(context.container)
        guard let stored = try? reader.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { ids.contains($0.persistentModelID) }))
        else { return false }
        let byID = Dictionary(stored.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        var adopted = false
        func adopt<Value: Equatable>(_ path: ReferenceWritableKeyPath<HabitRecord, Value>, _ record: HabitRecord,
                                     from row: HabitRecord) {
            let value = row[keyPath: path]
            if record[keyPath: path] != value {
                record[keyPath: path] = value
                adopted = true
            }
        }
        for record in records {
            guard let row = byID[record.persistentModelID] else { continue }
            adopt(\.value, record, from: row)
            adopt(\.note, record, from: row)
            adopt(\.updatedAt, record, from: row)
            adopt(\.syncedAt, record, from: row)
            adopt(\.syncHoldReason, record, from: row)
            adopt(\.syncHoldStamp, record, from: row)
            adopt(\.needsResend, record, from: row)
            adopt(\.restoredAt, record, from: row)
        }
        return adopted
    }

    /// Deletes one of the day's live records. One the context has not saved yet also leaves
    /// `habit.records`: a pending insert deleted while the habit still lists it fails the next
    /// save's validation (measured, NSCocoaErrorDomain 1560). A saved one stays listed, as it always
    /// has — the ghost every lookup here already skips.
    private static func delete(_ record: HabitRecord, of habit: Habit, in context: ModelContext) {
        if context.insertedModelsArray.contains(where: { $0 === record }) {
            habit.records.removeAll { $0 === record }
        }
        context.delete(record)
    }

    /// Whether a day whose kept record holds `value` (nil: no record) is complete.
    private static func isCompleted(holding value: Double?, _ habit: Habit) -> Bool {
        guard let value else { return false }
        switch habit.habitKind {
        case .binary: return true
        case .count: return habit.targetValue > 0 && value >= habit.targetValue
        }
    }

    /// The records' ids, each once, in order: two records of one day can carry the same id (the
    /// reconciler's day match renames onto the server's id), and one tombstone covers both.
    private static func distinctIDs(of records: [HabitRecord]) -> [String] {
        var seen = Set<String>()
        return records.map { $0.id.uuidString }.filter { seen.insert($0).inserted }
    }

    /// nil for no note and for an empty one: both mean "no note" everywhere (`HabitStats.hasNote`).
    private static func nonEmpty(_ note: String?) -> String? {
        guard let note, !note.isEmpty else { return nil }
        return note
    }

    // MARK: - Undo (HabitEntryCommit, after a failed save)

    /// What one commit's setters changed, so that a failed save can take exactly that back and
    /// nothing else (D4 step 1). mainContext autosaves and sync saves on it, so a change left
    /// pending after a failed save would land later — a deletion with no tombstone queued for it,
    /// one the server and every other device never hear of. `context.rollback()` would also throw
    /// away whatever else the context holds unsaved.
    ///
    /// Reverted in reverse order: an inserted record is removed and deleted; an edited one gets
    /// its value, note, stamp and forced-resend flag back; a deleted one is re-inserted as a copy
    /// with its id, day, value, note, stamp and delivery state — so the next save deletes the old
    /// row and writes the same row back, and sync sees nothing to send. Pass one journal to every
    /// setter of a commit.
    final class Undo {
        /// The fields a setter edits, as they were before this journal's first edit.
        fileprivate struct Before {
            let note: String?
            let updatedAt: Date?
            let value: Double
            let needsResend: Bool

            init(_ record: HabitRecord) {
                note = record.note
                updatedAt = record.updatedAt
                value = record.value
                needsResend = record.needsResend
            }

            func restore(on record: HabitRecord) {
                record.note = note
                record.updatedAt = updatedAt
                record.value = value
                record.needsResend = needsResend
            }
        }

        private struct Fields {
            let id: UUID
            let date: Date
            let note: String?
            let updatedAt: Date?
            let value: Double
            let syncedAt: Date?
            let syncHoldReason: String?
            let syncHoldStamp: Date?
            let needsResend: Bool
            let restoredAt: Date?

            /// `before`: the fields as this journal first saw them, when it edited the record
            /// before deleting it.
            init(_ record: HabitRecord, before: Before? = nil) {
                id = record.id
                date = record.date
                // `map`, not `?.`: a nil note or stamp before the edit is a value to restore.
                note = before.map { $0.note } ?? record.note
                updatedAt = before.map { $0.updatedAt } ?? record.updatedAt
                value = before.map { $0.value } ?? record.value
                syncedAt = record.syncedAt
                syncHoldReason = record.syncHoldReason
                syncHoldStamp = record.syncHoldStamp
                needsResend = before.map { $0.needsResend } ?? record.needsResend
                restoredAt = record.restoredAt
            }

            func copy() -> HabitRecord {
                let record = HabitRecord(date: date, note: note, value: value)
                record.id = id
                record.date = date
                record.updatedAt = updatedAt
                record.syncedAt = syncedAt
                record.syncHoldReason = syncHoldReason
                record.syncHoldStamp = syncHoldStamp
                record.needsResend = needsResend
                record.restoredAt = restoredAt
                return record
            }
        }

        private enum Step {
            case inserted(HabitRecord, Habit)
            case edited(HabitRecord, Before)
            case deleted(Fields, Habit)
        }

        private var steps: [Step] = []

        init() {}

        /// Nothing to take back.
        var isEmpty: Bool { steps.isEmpty }

        func inserted(_ record: HabitRecord, of habit: Habit) {
            steps.append(.inserted(record, habit))
        }

        /// Before the record's first change in this journal.
        func edited(_ record: HabitRecord) {
            let known = steps.contains {
                switch $0 {
                case .inserted(let r, _), .edited(let r, _): return r === record
                case .deleted: return false
                }
            }
            guard !known else { return }
            steps.append(.edited(record, Before(record)))
        }

        /// Before the record is deleted. A record this journal inserted is simply forgotten: its
        /// deletion already undid the insert. One it edited first comes back as it was before.
        func deleted(_ record: HabitRecord, of habit: Habit) {
            if let i = steps.firstIndex(where: { if case .inserted(let r, _) = $0 { return r === record }; return false }) {
                steps.remove(at: i)
                return
            }
            var before: Before?
            if let i = steps.firstIndex(where: { if case .edited(let r, _) = $0 { return r === record }; return false }),
               case .edited(_, let fields) = steps[i] {
                before = fields
                steps.remove(at: i)
            }
            steps.append(.deleted(Fields(record, before: before), habit))
        }

        /// Takes back every change recorded, newest first, and empties the journal.
        func revert(in context: ModelContext) {
            for step in steps.reversed() {
                switch step {
                case .inserted(let record, let habit):
                    habit.records.removeAll { $0 === record }
                    context.delete(record)
                case .edited(let record, let before):
                    before.restore(on: record)
                case .deleted(let fields, let habit):
                    habit.records.append(fields.copy())
                }
            }
            steps.removeAll()
        }
    }
}

// MARK: - The widget's noted row (D7)

/// The link a checked, noted widget row opens instead of toggling (RELEASE-1.4.1.md D7):
/// `stride://history?habit=<UUID>&day=<yyyy-MM-dd>`, which the app answers by showing that habit's
/// History on that day (`ShellRequest.history`). The extension cannot ask "Remove the check-in and
/// its note?", so it never un-checks such a row (`HabitCheckIn.tap` writes nothing there); the
/// user un-checks it in History, which asks.
///
/// A custom scheme, and deliberately not registered (no `CFBundleURLTypes`): WidgetKit hands a
/// widget's `Link` URL to its own containing app, whatever the scheme, so nothing else — another
/// app, a web page — can route into History. It carries no secret either way, unlike the sign-in
/// link, which is why that one is a universal link (`LoginLink`) and this is kept apart from it:
/// `AppURLRoute` sends exactly this shape to History and nothing else.
///
/// Pure and in Shared/: the widget builds it, the app parses it, and StrideTests pins both.
enum HistoryLink {
    static let scheme = "stride"
    static let host = "history"

    /// The link for `habitID` on `dayKey` (a day-key: UTC midnight, `HabitCalendar`).
    static func url(habitID: UUID, dayKey: Date) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "habit", value: habitID.uuidString),
                                 URLQueryItem(name: "day", value: dayString(of: dayKey))]
        return components.url!
    }

    /// The link a widget row opens, or nil while the row stays a toggle: only a yes/no row that is
    /// checked and has a note (a count row's tap adds one and never deletes, `HabitCheckIn.tap`).
    static func url(for row: WidgetTimelinePlan.Row, dayKey: Date) -> URL? {
        guard !row.isCount, row.isCompleted, row.hasNote, let habitID = UUID(uuidString: row.habitId) else { return nil }
        return url(habitID: habitID, dayKey: dayKey)
    }

    /// The habit and the day of a history link — the day as a local instant (noon of that date in
    /// `calendar`'s zone), which is what `ShellRequest.history(habitID:day:)` takes — or nil for
    /// every URL that is not exactly one: this scheme and host, no user, password, port, path or
    /// fragment, and exactly the two items, each once, a UUID and a real `yyyy-MM-dd` date.
    ///
    /// The date is Gregorian, as every day-key is (`HabitCalendar.dayCalendar`, X2): it is read in
    /// a Gregorian calendar in `calendar`'s zone, never in the device's own calendar.
    static func target(of url: URL, calendar deviceCalendar: Calendar) -> (habitID: UUID, day: Date)? {
        let calendar = HabitCalendar.dayCalendar(deviceCalendar)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              components.user == nil, components.password == nil, components.port == nil,
              components.percentEncodedPath.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 2,
              items.filter({ $0.name == "habit" }).count == 1, items.filter({ $0.name == "day" }).count == 1,
              let habitValue = items.first(where: { $0.name == "habit" })?.value, habitValue.count == 36,
              let habitID = UUID(uuidString: habitValue),
              let dayValue = items.first(where: { $0.name == "day" })?.value,
              let date = dateParts(dayValue)
        else { return nil }
        // Noon: it exists on every civil day (a DST change happens at night), so the instant is on
        // that date in `calendar` whatever the zone.
        guard let instant = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)),
              case let c = calendar.dateComponents([.year, .month, .day], from: instant),
              c.year == date.year, c.month == date.month, c.day == date.day
        else { return nil }
        return (habitID, instant)
    }

    /// `yyyy-MM-dd` of a day-key, in UTC (the key's own date).
    static func dayString(of dayKey: Date) -> String {
        let c = HabitCalendar.utc.dateComponents([.year, .month, .day], from: HabitCalendar.startOfKey(dayKey))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Exactly four, two and two ASCII digits with dashes, naming a date that exists. Any year
    /// from 1: W2's review ("W2-URL-2") took the floor out when day-keys still took their year from
    /// the device's calendar (0008-10-15 on a Japanese-calendar phone). Since X2 every key is
    /// Gregorian (`HabitCalendar.dayCalendar`); a link an older widget drew with such a year opens
    /// History on that Gregorian date, which History clamps to the days it offers.
    private static func dateParts(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for scalar in scalars[range] {
                guard ("0"..."9").contains(scalar) else { return nil }
                value = value * 10 + Int(scalar.value - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = HabitCalendar.utc.date(from: DateComponents(year: year, month: month, day: day)),
              case let c = HabitCalendar.utc.dateComponents([.year, .month, .day], from: date),
              c.year == year, c.month == month, c.day == day
        else { return nil }
        return (year, month, day)
    }
}

/// Where a URL handed to the app goes (StrideApp's `.onOpenURL` and universal-link handlers).
/// History and sign-in are kept apart: a history link (`HistoryLink`, the custom scheme) only ever
/// opens History and never reaches AuthService; a sign-in link (`LoginLink`, https on our host) only
/// ever signs in. The shapes are disjoint, and anything that is neither opens the app as it is.
enum AppURLRoute: Equatable {
    case history(habitID: UUID, day: Date)
    case signIn
    /// Neither: the app opens as it is.
    case other

    static func of(_ url: URL, calendar: Calendar) -> AppURLRoute {
        if let target = HistoryLink.target(of: url, calendar: calendar) {
            return .history(habitID: target.habitID, day: target.day)
        }
        return LoginLink.token(from: url) != nil ? .signIn : .other
    }
}
