import Foundation
import SwiftData

/// The one place a UI check-in write is saved and its effects run (RELEASE-1.4.1.md D4).
/// **Owner: W2.** Scaffolded by W0: the API sketch only — `commit` runs nothing and answers
/// `.noChange`, and nothing calls it yet.
///
/// TODO(W2): implement D4. On the main actor, with no `await` between the write and the save
/// (2026-10-15: History's draft lives only in view `@State`), in this order:
/// 1. `save()`. If it throws: undo THIS commit's own changes (re-insert a deleted record with
///    its id, value, note and stamp; `context.rollback()` only when mainContext is known to
///    hold nothing else unsaved — it autosaves, and sync saves on it), log it (Logger and
///    Sentry), skip 2–4 and return `.saveFailed`, so the caller resets its UI (`justCompleted`,
///    History's editor). Without the undo a pending delete would land later with no tombstone.
/// 2. Only on success: `SyncService.trackDeletedEntry` for every deleted id.
/// 3. `CheckInEffects.afterCheckIn` with `endsReminders(checkingIn: day)` for a check-in, or a
///    widget reload plus badge update for an un-check.
/// 4. `StatsCache.bump()` — synchronously, so the same render reads the new stats (D3 trigger 1).
///
/// Callers (D4): History (W4) and every Today row write — toggle, increment, decrement, reset
/// and the note alert (W2). The write itself is one of HabitCheckIn's D4 setters
/// (`setChecked(_:on:)`, `setValue(_:on:)`, `setNote(_:on:)`, W2, Shared/HabitCheckIn.swift),
/// passed the target state the user saw. `.needsConfirmation` (a noted check-in would be
/// deleted, or two duplicate notes differ) comes back to the caller, which asks and only then
/// calls again (D7).
@MainActor
enum HabitEntryCommit {
    /// What a D4 setter did, as the commit needs it.
    /// TODO(W2): fold into (or map from) the setters' own result type in Shared/HabitCheckIn.swift.
    enum Change: Equatable {
        /// The store already held the target state: no stamp, no save, no effects.
        case noChange
        /// Deleting would lose a non-empty note, or two duplicate records' notes differ.
        case needsConfirmation
        /// Written. `deletedRecordIDs`: records deleted (an un-check, a count set to 0, Reset,
        /// or the duplicates a day merge removed), each to be tombstoned after the save.
        /// `checkedIn`: the day ends completed (drives step 3).
        case changed(deletedRecordIDs: [String], checkedIn: Bool)
    }

    /// What the caller learns.
    enum Outcome: Equatable {
        case committed
        case noChange
        case needsConfirmation
        /// The save threw and this commit's changes were undone; reset the UI.
        case saveFailed
    }

    /// Runs `write` (one D4 setter call) against `context`, then saves and runs the effects
    /// above. `habitID` and `day` name what changed, for the effects and the cache.
    @discardableResult
    static func commit(habitID: UUID, day: Date, in context: ModelContext,
                       write: () -> Change) -> Outcome {
        // TODO(W2): run `write`, then steps 1–4.
        .noChange
    }
}
