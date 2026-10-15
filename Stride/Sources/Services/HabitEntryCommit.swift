import Foundation
import OSLog
import SwiftData
#if canImport(Sentry)
import Sentry
#endif

/// The one place a UI check-in write is saved and its effects run (RELEASE-1.4.1.md D4).
///
/// Callers (D4): every Today row write — toggle, increment, decrement, reset and the note
/// alert — and History (W4). The write itself is one or more of HabitCheckIn's setters
/// (`setChecked`, `setValue`, `setNote`, Shared/HabitCheckIn.swift), passed the target state the
/// user saw and this commit's undo journal. `.needsConfirmation` (a noted check-in would be
/// deleted, or two duplicate records' notes differ) comes back to the caller, which asks and only
/// then commits again with the same write and `confirmed:` (D7).
///
/// `commit` runs on the main actor, synchronously: the setter and the save run back to back with
/// no `await` between them (2026-10-15: History's draft lives only in view `@State`), so nothing
/// else on the main actor — a sync's reconcile, its rollback — can run in the middle. Then:
/// 1. `save()`. If it throws: undo THIS commit's own changes (`HabitCheckIn.Undo`: re-insert a
///    deleted record with its id, value, note and stamp, revert edited fields, delete inserted
///    ones), log it (Logger and Sentry), skip 2–4 and return `.saveFailed`, so the caller resets
///    its UI (`justCompleted`, History's editor). Without the undo a pending delete would land
///    with mainContext's next save — it autosaves, and sync saves on it — with no tombstone.
/// 2. Only on success: `SyncService.trackDeletedEntry` for every deleted id.
/// 3. `CheckInEffects.afterCheckIn` with `endsReminders(checkingIn: day)` for a check-in, or a
///    widget reload plus a badge update for anything else (an un-check, a lower value, a note).
/// 4. `StatsCache.bump(habitID:)`, synchronously, so the same render reads the new stats (D3
///    trigger 1).
@MainActor
enum HabitEntryCommit {
    /// What the caller learns.
    enum Outcome: Equatable {
        /// Saved; tombstones queued, effects started, stats bumped.
        case committed(HabitCheckIn.Written)
        /// The store already held the target state: no stamp, no save, no effects.
        case noChange
        /// Nothing written: ask the user, then commit the same write with `confirmed:`.
        case needsConfirmation(HabitCheckIn.Confirmation)
        /// The save threw and this commit's changes were undone; reset the UI.
        case saveFailed
    }

    /// Everything the commit does outside the context's own objects. Values, not calls on the
    /// singletons, so the hosted tests make the save fail and record the tombstones and effects
    /// without touching the host app's queue, widgets, badge or notification store.
    struct Environment {
        var save: @MainActor (ModelContext) throws -> Void
        var trackDeletedEntry: @MainActor (String) -> Void
        var effects: CheckInEffects
        var bumpStats: @MainActor (UUID) -> Void
        /// After the log line: the failure to Sentry.
        var reportSaveFailure: @MainActor (Error) -> Void
        /// For `CheckInEffects.endsReminders(checkingIn:)`.
        var now: () -> Date
        var calendar: () -> Calendar

        /// The app's own.
        static var live: Environment {
            Environment(
                save: { try $0.save() },
                trackDeletedEntry: { SyncService.shared.trackDeletedEntry($0) },
                effects: .live,
                bumpStats: { StatsCache.shared.bump(habitID: $0) },
                reportSaveFailure: { HabitEntryCommit.reportToSentry($0) },
                now: { Date() },
                calendar: { .current })
        }
    }

    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "CheckIn")

    /// Runs `write` — one or more HabitCheckIn setter calls, each handed the journal — against
    /// `context`, then saves and runs the effects above. `habitID` and `day` name what changed,
    /// for the effects and the cache; `day` is the local date the row or editor shows.
    @discardableResult
    static func commit(habitID: UUID, day: Date, in context: ModelContext,
                       environment: Environment = .live,
                       write: (HabitCheckIn.Undo) -> HabitCheckIn.Change) -> Outcome {
        let undo = HabitCheckIn.Undo()
        let written: HabitCheckIn.Written
        switch write(undo) {
        case .changed(let w):
            written = w
        case .noChange:
            // A setter that answers this has written nothing; a write that ran several setters may
            // have, before a later one declined. Nothing is saved, so nothing is left pending.
            undo.revert(in: context)
            return .noChange
        case .needsConfirmation(let about):
            undo.revert(in: context)
            return .needsConfirmation(about)
        }

        do {
            try environment.save(context)
        } catch {
            undo.revert(in: context)
            let ns = error as NSError
            logger.error("check-in commit: the save failed (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)); its changes were undone")
            environment.reportSaveFailure(error)
            return .saveFailed
        }

        // Only now: a tombstone queued before the save could delete on the server a record that
        // is still here.
        for id in written.deletedRecordIDs { environment.trackDeletedEntry(id) }

        let container = context.container
        let effects = environment.effects
        if written.isCheckIn {
            // `day` is the week strip's: a backfill of Wednesday on Thursday must leave Thursday's
            // snooze and banner alone (`CheckInEffects.endsReminders`).
            let ends = CheckInEffects.endsReminders(checkingIn: day, now: environment.now(),
                                                    calendar: environment.calendar())
            Task { @MainActor in
                await effects.afterCheckIn(habitID: habitID, container: container, endsReminders: ends)
            }
        } else {
            // Taking a check-in back (or a note, or a merge) leaves the snooze and banners: they
            // still ask for something not done. The widgets and the badge follow the day.
            effects.reloadWidgets()
            Task { @MainActor in await effects.updateBadge(container) }
        }

        environment.bumpStats(habitID)
        return .committed(written)
    }

    /// A fresh NSError with only the domain and code, as AppStoreLaunch reports a store failure:
    /// Core Data's own error carries the store's path and the objects in `userInfo`, and none of it
    /// may leave the device. A no-op under XCTest (SentryBootstrap never starts there).
    nonisolated static func reportToSentry(_ error: Error) {
        #if canImport(Sentry)
        let ns = error as NSError
        _ = SentrySDK.capture(error: NSError(domain: ns.domain, code: ns.code)) { scope in
            scope.setTag(value: "save", key: "checkin.step")
        }
        #endif
    }
}
