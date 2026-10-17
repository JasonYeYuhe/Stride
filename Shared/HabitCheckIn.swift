import Foundation
import SwiftData

/// The one implementation of "check this habit in for a day".
///
/// Four places did this and only the main list got it right. TodayView branches on the
/// habit's kind: a yes/no habit toggles, a count habit gains one unit, and only an explicit
/// "remove one" at a value of 1 ever deletes. The other three re-implemented the tap without
/// looking at the kind:
///
/// - The widget's `ToggleHabitIntent` and the watch deleted today's record whenever one
///   existed. "Drink Water" at 6 of 8 glasses draws as an EMPTY circle — it is not complete —
///   so the tap is invited, and it erased all six units and queued a sync tombstone that
///   spread the loss to every other device. The watch deleted every record for the day.
///   The widget became reachable for real users in 1.2.2, the first build that ships it.
/// - Siri's "Complete a Habit" appended a new record whenever the habit was not yet complete,
///   so a partially logged count habit gained a second record for the same day. Everything
///   downstream reads only the first match, so the app showed 5/8 or 1/8 depending on which
///   came back, and both records were pushed to the server as separate entries.
///
/// Callers save the context themselves and, only once that save succeeds, queue the tombstone
/// for `deletedRecordID` — so a failed save can never delete a record on the server.
enum HabitCheckIn {
    struct Result: Equatable {
        /// The record this call deleted, if any. Queue its sync tombstone after saving.
        var deletedRecordID: String?
        var isCompleted: Bool
        var loggedValue: Double
    }

    /// A single tap for `date` — the list row, the widget, the watch.
    /// - yes/no habit: checks it if unchecked, unchecks it if checked.
    /// - count habit: adds one unit, creating the day's record at 1 if there is none. It never
    ///   deletes; taking units away is a separate, explicit action in the app.
    @discardableResult
    static func tap(_ habit: Habit, on date: Date, in context: ModelContext) -> Result {
        switch habit.habitKind {
        case .binary:
            if let existing = liveRecord(of: habit, on: date, in: context) {
                let id = existing.id.uuidString
                context.delete(existing)
                // Stated rather than recomputed: until the context saves, `habit.records` can
                // still contain the object just deleted.
                return Result(deletedRecordID: id, isCompleted: false, loggedValue: 0)
            }
            habit.records.append(HabitRecord(date: date))
            return Result(deletedRecordID: nil, isCompleted: true, loggedValue: 1)

        case .count:
            let record: HabitRecord
            if let existing = liveRecord(of: habit, on: date, in: context) {
                existing.value += 1
                existing.touch()
                record = existing
            } else {
                record = HabitRecord(date: date, value: 1)
                habit.records.append(record)
            }
            // From the record itself, not `habit.isCompletedOn`: that reads `habit.records`, which
            // can still hold the deleted record ahead of this one (see `liveRecord`).
            return Result(deletedRecordID: nil,
                          isCompleted: habit.targetValue > 0 && record.value >= habit.targetValue,
                          loggedValue: record.value)
        }
    }

    /// The day's record as the store has it — not as `habit.records` remembers it.
    ///
    /// `records` has no inverse relationship, and a Habit already loaded in a context keeps a
    /// deleted record in that array after the deletion is saved, until something fetches the
    /// habit again (the M2 sync rehearsal hit it as CoreData's "repairing missing delete
    /// propagation"). Measured 2026-09-28 (HabitCheckInTests, the ghost tests): after untap →
    /// save, the same Habit still listed the record — `isDeleted` false, `modelContext` nil —
    /// and `habit.record(on:)` returned it. Before this (shipped in 1.2.3 and 1.3.0):
    /// - a yes/no re-tap "deleted" the ghost again instead of checking the day: the day stayed
    ///   unchecked, and a second tombstone for the old id was queued;
    /// - a count tap after "remove one" took the day to zero added its unit to the ghost, which
    ///   no save writes, and reported the ghost's old value plus one.
    /// A deletion saved by ANOTHER context (the widget's intent runs in its own process) leaves
    /// a ghost that looks entirely live — context set, not deleted — so only the store can say.
    /// One small fetch per tap; the tap is a user gesture, not a loop.
    private static func liveRecord(of habit: Habit, on date: Date, in context: ModelContext) -> HabitRecord? {
        let sameDay = habit.records.filter {
            !$0.isDeleted && HabitCalendar.record($0.date, isOnSameDayAs: date)
        }
        guard !sameDay.isEmpty else { return nil }
        let ids = sameDay.map(\.id)
        // Pending changes included (the default): a record appended but not yet saved counts,
        // one deleted but not yet saved does not.
        let descriptor = FetchDescriptor<HabitRecord>(predicate: #Predicate { ids.contains($0.id) })
        guard let stored = try? context.fetch(descriptor) else {
            // Cannot ask the store: the best local answer. It still skips a same-context ghost.
            return sameDay.first { $0.modelContext != nil }
        }
        let live = Set(stored.map(\.id))
        // First in `records` order, like `habit.record(on:)`, should an old store hold two.
        return sameDay.first { live.contains($0.id) }
    }

    /// "Complete this habit" — Siri and Shortcuts. Unlike `tap`, it never removes anything:
    /// returns nil and changes nothing when the habit is already complete for the day;
    /// otherwise it is a `tap` (checks a yes/no habit, adds one unit to a count habit).
    static func markDone(_ habit: Habit, on date: Date, in context: ModelContext) -> Result? {
        // Not `habit.isCompletedOn`: a ghost of an unchecked day would read as done (liveRecord).
        let record = liveRecord(of: habit, on: date, in: context)
        let isComplete: Bool
        switch habit.habitKind {
        case .binary: isComplete = record != nil
        case .count: isComplete = habit.targetValue > 0 && (record?.value ?? 0) >= habit.targetValue
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
    /// **Never deletes.** `tap` on a yes/no habit that is already done removes the day's record,
    /// and the caller would queue the tombstone that removes it on every device. A stale "Add 1"
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
        assert(result?.deletedRecordID == nil, "a reminder's check-in deleted a record")
        return result
    }
}
