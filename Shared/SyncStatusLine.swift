import Foundation
import SwiftData

// What Today says about sync (DEV-PLAN-1.3.md M2, "Sign-in that stays" and the optional "Sync
// status where the user works"; acceptance 9 and 10). Pure: the state goes in, one status (or
// none) comes out, so StrideTests pin every mapping without an app, a server or a clock. The
// view that draws it is Stride/Sources/Views/SyncStatusRow.swift.
//
// Until 1.3.1 the only sync signal was the red footer in Settings, and it showed a rate limit,
// the pause switch and a lost network in the same red as a real failure. The spec's rules:
// - the reauth row and every line are INLINE — never a sheet, an alert or a banner that appears
//   because a background sync answered something (acceptance 10);
// - 429 and 503 `sync_paused` read "Sync paused", never an error: the server asked this device
//   to wait, which the user cannot fix and should not be alarmed by (`showsSyncPaused`);
// - nothing at all when signed out, so a signed-out Today — the store screenshots — is laid out
//   exactly as before.

/// One line (or the reauth row) under Today's progress card.
enum SyncStatusLine: Equatable {
    /// The last sync was answered 401: "Sign in again to keep syncing", a row that opens sign-in.
    case signInAgain
    /// 429 `rate_limited` or 503 `sync_paused`: "Sync paused".
    case paused
    /// No answer at all (offline, timeout, DNS) with changes this device has not delivered:
    /// "Offline — 3 changes waiting".
    case offline(waiting: Int)
    /// A server error or a request this build got wrong, with changes waiting: the rows are safe
    /// and the backoff retries, so it is a count, not an error ("3 changes waiting to sync").
    case waiting(Int)
    /// Rows the server refused (held): "2 changes can't sync — see Settings", where the inline
    /// rows and their actions are.
    case held(Int)
    /// The last successful sync, by this device's clock: "Synced 2 min ago".
    case synced(Date)
}

/// Everything the mapping reads, gathered by the view from AuthService, SyncService and the store.
struct SyncStatusInput: Equatable {
    /// A session is stored and its account is known (`AuthService.isLoggedIn`).
    var signedIn: Bool
    /// `SyncService.needsReauth`: the last run was answered 401.
    var needsReauth: Bool
    /// Signed into an account that is not the store's owner, with something to lose
    /// (`SyncService.ownerConflict`). The account screen of that sign-in is where this is
    /// settled; Today adds nothing beside it.
    var ownerConflict: Bool = false
    /// Why the owner's automatic syncs are backing off (`SyncService.backoff?.reason`); nil after
    /// a successful run ("success resets").
    var backoff: SyncBackoffReason?
    /// `SyncService.lastSyncTime`, parsed.
    var lastSync: Date?
    /// What the next push would carry: pending rows plus queued deletions (`SyncStatusCounts`).
    var pending: Int = 0
    /// Held rows, a held habit counting once for itself and its check-ins (`SyncCopies.heldRows`).
    var held: Int = 0
}

extension SyncStatusLine {
    /// The one thing Today shows, or nil for nothing.
    ///
    /// Order, most actionable first:
    /// 1. **Reauth**, even when the session is gone: that is exactly when the user needs the way
    ///    back in. A deliberate sign-out clears `needsReauth` (`SyncService.signedOut`), so this
    ///    never follows someone who chose to leave.
    /// 2. **Signed out** → nothing (the screenshots' layout). **Owner conflict** → nothing: the
    ///    account screen is part of the sign-in the user started, and no sync has run.
    /// 3. **Paused / rate-limited** — whatever is pending: nothing will move until the server
    ///    says so, and the line says why.
    /// 4. **Offline or a server error with changes waiting.** With nothing waiting, "offline" is
    ///    not news: every change is on the server, so the last-synced line stays true.
    /// 5. **Held rows**, which only an edit or a Settings action resolves.
    /// 6. **Last synced.** Pending rows right after an edit are not shown: there is no failure,
    ///    the next sync takes them, and a count flickering after every tap is not calm.
    static func make(_ input: SyncStatusInput) -> SyncStatusLine? {
        if input.needsReauth { return .signInAgain }
        guard input.signedIn, !input.ownerConflict else { return nil }
        if let reason = input.backoff {
            if reason.showsSyncPaused { return .paused }
            if input.pending > 0 {
                return reason == .offline ? .offline(waiting: input.pending) : .waiting(input.pending)
            }
        }
        if input.held > 0 { return .held(input.held) }
        if let lastSync = input.lastSync { return .synced(lastSync) }
        return nil
    }
}

// MARK: - Counting without planning

/// The two counts the status line needs, read from the store without planning a push.
///
/// `SyncPushPlanner.plan` would give the exact pending count, but it encodes every pending row to
/// measure it — on a first upload of years of check-ins, seconds of work on the main actor every
/// time Today appears. This counts what the planner would send with the same rules and no
/// encoding: pending groups and habits (a few hundred at most), pending check-ins through
/// `SyncPendingRows` (one fetch the store evaluates), minus the check-ins of a held habit (the
/// planner keeps those back), plus queued deletions. It can differ from a plan only by a row the
/// planner would hold on the way (`too_large`, a NaN) — which the next sync turns into `held`.
@MainActor
enum SyncStatusCounts {
    struct Counts: Equatable {
        var pending = 0
        var held = 0
    }

    static func read(in context: ModelContext, deletions: SyncDeletionQueue.Batch) throws -> Counts {
        let heldRows = try SyncCopies.heldRows(in: context, reasons: Set(SyncHoldReason.allCases))

        var pending = deletions.count
        pending += try context.fetch(FetchDescriptor<HabitGroup>()).filter(\.isPending).count
        pending += try context.fetch(FetchDescriptor<Habit>()).filter(\.isPending).count

        let pendingRecords = try SyncPendingRows.records(in: context)
        if !pendingRecords.isEmpty {
            // A held habit's check-ins are not sent until the habit is resolved; only held habits
            // are walked, and they are few.
            var keptBack = Set<PersistentIdentifier>()
            for habit in heldRows.habits { keptBack.formUnion(habit.records.map(\.persistentModelID)) }
            pending += pendingRecords.subtracting(keptBack).count
        }
        return Counts(pending: pending, held: heldRows.counts.total)
    }
}
