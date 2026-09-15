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
            if let existing = habit.record(on: date) {
                let id = existing.id.uuidString
                context.delete(existing)
                // Stated rather than recomputed: until the context saves, `habit.records` can
                // still contain the object just deleted.
                return Result(deletedRecordID: id, isCompleted: false, loggedValue: 0)
            }
            habit.records.append(HabitRecord(date: date))
            return Result(deletedRecordID: nil, isCompleted: true, loggedValue: 1)

        case .count:
            if let existing = habit.record(on: date) {
                existing.value += 1
                existing.touch()
            } else {
                habit.records.append(HabitRecord(date: date, value: 1))
            }
            return Result(deletedRecordID: nil,
                          isCompleted: habit.isCompletedOn(date),
                          loggedValue: habit.loggedValue(on: date))
        }
    }

    /// "Complete this habit" — Siri and Shortcuts. Unlike `tap`, it never removes anything:
    /// returns nil and changes nothing when the habit is already complete for the day;
    /// otherwise it is a `tap` (checks a yes/no habit, adds one unit to a count habit).
    static func markDone(_ habit: Habit, on date: Date, in context: ModelContext) -> Result? {
        guard !habit.isCompletedOn(date) else { return nil }
        return tap(habit, on: date, in: context)
    }
}
