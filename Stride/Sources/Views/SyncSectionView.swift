import SwiftUI
import SwiftData
import WidgetKit

// Settings → Sync (DEV-PLAN-1.3.md M2, phase C): the inline rows of the safe core — changes the
// server refused ("N changes can't sync", by reason), rows only a new id can resolve (`not_owned`,
// and restored habits another device deleted) with "Restore as New Copies" / "Discard", the
// recovery log ("Recovered Edits (N)" → Export / Clear), "Sync paused", and Full Resync.
//
// Acceptance (10): no new interruptive UI. Everything here is a row in Settings that is simply
// absent when there is nothing to say; the only dialogs are confirmations of a destructive button
// the user just tapped (Discard, Clear, Full Resync). The operations themselves are SyncService's
// (phase B); this file decides what is shown and wires the buttons.

/// What the sync section shows, from the service's state. Pure, so the hosted tests pin which rows
/// appear without rendering a view.
struct SyncSectionContent: Equatable {
    /// Held for the row's content (`missing_field`, `row_error`, `invalid_value`,
    /// `unknown_habit`, `too_large`): a line each under "N changes can't sync". An edit lifts
    /// these holds, so they have no button — a new id would re-send the same content into the
    /// same refusal (`SyncCopies.convertibleReasons`).
    var refused: [SyncService.HeldRows] = []
    /// Held because of the id (`not_owned`, `tombstoned`): one row each, with the two actions.
    var convertible: [SyncService.HeldRows] = []
    /// The owner's recovery-log lines; 0 hides the row.
    var recoveredEdits = 0
    var isPaused = false
    var offersFullResync = false
    /// Signed into an account that does not own this store (`SyncService.ownerConflict`) after the
    /// account screen was left without a choice (the app quit on it): nothing syncs until the
    /// choice is made, and this row is the way back to that screen.
    var needsOwnerChoice = false

    init(held: [SyncService.HeldRows], recoveredEdits: Int, isPaused: Bool, offersFullResync: Bool,
         needsOwnerChoice: Bool = false) {
        refused = held.filter { !$0.canRestoreAsCopies && $0.counts.total > 0 }
        convertible = held.filter { $0.canRestoreAsCopies && $0.counts.total > 0 }
        self.recoveredEdits = max(0, recoveredEdits)
        self.isPaused = isPaused
        self.offersFullResync = offersFullResync
        self.needsOwnerChoice = needsOwnerChoice
    }

    /// "N changes can't sync": every held row, a held habit once (its check-ins are not counted
    /// again — `SyncCopies.heldRows`). The same number as Today's "N changes can't sync — see
    /// Settings" (`SyncStatusCounts.held`), so the pointer and the place it points to agree; the
    /// rows below it then say why, and which of them have a button.
    var heldCount: Int { (refused + convertible).reduce(0) { $0 + $1.counts.total } }

    /// Nothing to show: the section is not drawn at all.
    var isEmpty: Bool {
        refused.isEmpty && convertible.isEmpty && recoveredEdits == 0 && !isPaused && !offersFullResync
            && !needsOwnerChoice
    }
}

/// The section's actions — and the Account section's Sync Now — apart from the view so the hosted
/// tests run exactly what the buttons run. Side effects outside sync (reminders, widgets,
/// VoiceOver) stay in the view.
@MainActor
struct SyncSectionActions {
    let sync: SyncService
    let context: ModelContext

    /// Sync Now: a user-initiated sync. While the account screen's choice is pending
    /// (`SyncService.ownerConflict`) that sync is blocked and makes no request, and the tap showed
    /// nothing at all (E2E S5) — the row pointing at the choice sits below the fold. So the
    /// conflict comes back, and Settings presents the account screen, the same one the "Choose
    /// What Happens to This Device's Habits…" row opens: the user asked for this sync, and that
    /// choice is what it waits for. nil otherwise, whatever the sync's outcome — a failure is the
    /// Account footer's. Launch and foreground syncs still block silently (acceptance 10).
    func syncNow() async -> SyncOwnerConflict? {
        guard !(await sync.sync(context: context)) else { return nil }
        return sync.ownerConflict
    }

    /// "Restore as New Copies": fresh ids in place, then a sync, so the copies reach the account
    /// without a second tap (`SyncService.restoreHeldRowsAsNewCopies`).
    func restoreAsCopies(_ reason: SyncHoldReason) async throws -> SyncCopies.Outcome {
        try await sync.restoreHeldRowsAsNewCopies(reason, in: context)
    }

    /// "Discard": deleted on this device; no deletion is queued — the old id is another account's
    /// row or a tombstone, and a deletion sent for it would be answered for a row this account
    /// never had.
    func discard(_ reason: SyncHoldReason) async throws -> SyncCopies.Outcome {
        try await sync.discardHeldRows(reason, in: context)
    }

    /// Clears only what the user was shown (`expectedTotal`, the log's `Summary.archivedTotal`
    /// then); false (nothing cleared) when a sync has archived more since
    /// (`SyncService.clearRecoveredEdits(expectedTotal:)`).
    @discardableResult
    func clearRecoveredEdits(expectedTotal: Int? = nil) throws -> Bool {
        try sync.clearRecoveredEdits(expectedTotal: expectedTotal)
    }

    /// Full Resync: every row `needsResend`, a pull on the current cursor, the push, then the
    /// cursor cleared (`SyncRunOptions.fullResync`, "Forced resend waits until deletions are
    /// settled"). A sync already running would turn this one away (`sync` returns false at once),
    /// so it waits that one out first: the user asked for a resync, not for "maybe".
    @discardableResult
    func fullResync() async -> Bool {
        await sync.waitUntilIdle()
        return await sync.sync(context: context, options: .fullResync)
    }
}

struct SyncSectionView: View {
    @Environment(\.modelContext) private var modelContext

    // Rows that were ever held (`syncHoldStamp != nil`). Nearly always empty, and then nothing
    // else is fetched; otherwise `held` asks SyncService, which decides at millisecond precision
    // whether an edit has lifted each hold. The queries are also what redraws the section when a
    // sync holds a row, or an edit lifts one.
    @Query(filter: #Predicate<Habit> { $0.syncHoldStamp != nil }) private var everHeldHabits: [Habit]
    @Query(filter: #Predicate<HabitGroup> { $0.syncHoldStamp != nil }) private var everHeldGroups: [HabitGroup]
    @Query(filter: #Predicate<HabitRecord> { $0.syncHoldStamp != nil }) private var everHeldRecords: [HabitRecord]

    private var sync = SyncService.shared
    private var auth = AuthService.shared

    /// The reason whose Restore as New Copies / Discard is running.
    @State private var busyReason: SyncHoldReason?
    @State private var discardReason: SyncHoldReason?
    @State private var showingClearConfirm = false
    /// What the Clear confirmation was opened for, as `Summary.archivedTotal` (lines + dropped —
    /// at the log's cap the line count alone can stay put): a sync meanwhile can archive more
    /// lines, and Clear must not take ones the user never saw (`SyncService.clearRecoveredEdits`).
    @State private var clearExpectedTotal = 0
    @State private var showingFullResyncConfirm = false
    @State private var isResyncing = false
    @State private var actionError: String?

    /// The owner-choice row's tap: Settings presents the account screen from the List, not from
    /// this row — "Start from this account's data" settles the conflict before its sync finishes,
    /// and a sheet anchored to the row would close with the row, under the screen's progress.
    private let onChooseAccount: (SyncOwnerConflict) -> Void

    init(onChooseAccount: @escaping (SyncOwnerConflict) -> Void) {
        self.onChooseAccount = onChooseAccount
    }

    private var actions: SyncSectionActions { SyncSectionActions(sync: sync, context: modelContext) }

    private var held: [SyncService.HeldRows] {
        guard !(everHeldHabits.isEmpty && everHeldGroups.isEmpty && everHeldRecords.isEmpty) else { return [] }
        return (try? sync.heldRows(in: modelContext)) ?? []
    }

    private var content: SyncSectionContent {
        // 429 as well as the pause switch, like Today's line: either way the server asked this
        // device to wait (`showsSyncPaused`), and neither is an error.
        var paused = auth.isLoggedIn && (sync.backoff?.reason.showsSyncPaused ?? false)
        // Signed in as the owner: Full Resync has an account to resend to. Not while another
        // account is signed in over this store — nothing syncs until the account screen settles
        // it, and a resync would only be turned away.
        var fullResync = auth.isLoggedIn && sync.ownerConflict == nil
        // Held rows are the server's answers to a signed-in account, and their words and buttons
        // are about "this account" ("Restore them as new copies to add them to this account"):
        // signed out there is none, and Today's pointer to this list is hidden too (SyncStatusLine
        // shows nothing signed out). They are still held, and come back at the next sign-in.
        // Recovered edits are this device's file and stay listed.
        var showsHeld = auth.isLoggedIn
        #if DEBUG
        if let demo = SyncSectionDemo.current {
            paused = paused || demo.showsPaused
            fullResync = fullResync || demo.showsFullResync
            // The screenshot scenarios run signed out; they draw the signed-in rows.
            showsHeld = true
        }
        #endif
        return SyncSectionContent(held: showsHeld ? held : [], recoveredEdits: sync.recoveredEdits?.lines ?? 0,
                                  isPaused: paused, offersFullResync: fullResync,
                                  needsOwnerChoice: auth.isLoggedIn && sync.ownerConflict != nil)
    }

    var body: some View {
        let content = self.content
        if !content.isEmpty {
            Section {
                if content.needsOwnerChoice { ownerChoiceRow }
                if content.isPaused { pausedRow.sweepAnchor("syncPaused") }
                if content.heldCount > 0 { heldSummaryRow(content).sweepAnchor("syncHeld") }
                ForEach(content.convertible, id: \.reason) { group in
                    convertibleRows(group)
                }
                if content.recoveredEdits > 0 { recoveredEditsRows(count: content.recoveredEdits) }
                if content.offersFullResync { fullResyncRow.sweepAnchor("syncFullResync") }
            } header: {
                Text("Sync")
            } footer: {
                if let actionError {
                    SettingsInlineError(message: actionError)
                }
            }
        }
    }

    // MARK: - Rows

    /// Opens the account screen only when tapped: the choice continues the sign-in the user
    /// started, and nothing here appears on its own (acceptance 10).
    private var ownerChoiceRow: some View {
        Button {
            if let conflict = sync.ownerConflict { onChooseAccount(conflict) }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose What Happens to This Device's Habits…")
                        .foregroundStyle(Color.primary)
                    // `Color`, not the hierarchical `.secondary`: inside a Button that resolves
                    // against the tint and drew the subtitle pale green, below 4.5:1 on white.
                    Text("Syncing starts once you choose.")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            } icon: {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var pausedRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync paused")
                Text("The server asked devices to wait. Stride will try again automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "pause.circle")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
    }

    /// "N changes can't sync", with a line per content reason and its count. Those have nothing
    /// to tap — an edit sends the row again; the id holds follow as rows of their own, with their
    /// buttons.
    private func heldSummaryRow(_ content: SyncSectionContent) -> some View {
        let count = content.heldCount
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) changes can't sync")
                    if !content.refused.isEmpty {
                        Text("Editing a change sends it again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(content.refused, id: \.reason) { group in
                LabeledContent {
                    Text(verbatim: group.counts.total.formatted(.number.locale(appLocale)))
                } label: {
                    reasonText(group.reason)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Short names for the refusal reasons. One literal per case, so each is its own key.
    @ViewBuilder
    private func reasonText(_ reason: SyncHoldReason) -> some View {
        switch reason {
        case .rowError: Text("Server error")
        case .invalidValue: Text("A value the server doesn't accept")
        case .missingField: Text("Missing information")
        case .unknownHabit: Text("Its habit isn't on the server yet")
        case .tooLarge: Text("Too large to upload")
        // Never listed here (`SyncSectionContent.refused` excludes them); named anyway so a new
        // reason has to be placed on purpose.
        case .notOwned, .tombstoned: Text("Server error")
        }
    }

    @ViewBuilder
    private func convertibleRows(_ group: SyncService.HeldRows) -> some View {
        let busy = busyReason == group.reason
        let count = group.counts.total
        VStack(alignment: .leading, spacing: 2) {
            convertibleTitle(group)
            convertibleExplanation(group)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .sweepAnchor("syncConvertible-\(group.reason.rawValue)")

        Button {
            Task { await restoreAsCopies(group.reason) }
        } label: {
            HStack {
                // In the number the rows above count (E2E upgrade run: "Restore it as a new copy" over
                // "Restore as New Copies"); "(… held)" in the key only picks the form.
                Label("Restore as New Copies (\(count) held)", systemImage: "plus.square.on.square")
                if busy {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        // Not under a sync either: SyncService waits one out, but a second tap meanwhile would
        // queue a second conversion of rows the first has already converted.
        .disabled(busyReason != nil || sync.isSyncing)
        .accessibilityValue(busy ? Text("Processing...") : Text(verbatim: ""))

        Button(role: .destructive) {
            actionError = nil
            discardReason = group.reason
        } label: {
            // Red icon as well as title: the role colours the title only, and a green (tint)
            // trash can beside a red "Discard…" split the destructive cue.
            Label("Discard…", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .disabled(busyReason != nil || sync.isSyncing)
        // Each dialog hangs on the button that opens it (on iPad it points at it), never on the
        // Section: a modifier on a Section is applied to every row in it.
        .confirmationDialog(
            Text("Discard These Items? (\(count) held)"),
            isPresented: Binding(get: { discardReason == group.reason },
                                 set: { if !$0 { discardReason = nil } }),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                Task { await discard(group.reason) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            discardMessage(group.reason, count: group.counts.total)
        }
    }

    /// "N restored habits were deleted on another device" when only habits are held; rows held on
    /// their own (a group, a check-in on a live habit) make the count "items", since calling them
    /// habits would be wrong.
    @ViewBuilder
    private func convertibleTitle(_ group: SyncService.HeldRows) -> some View {
        let count = group.counts.total
        let habitsOnly = group.counts.groups == 0 && group.counts.entries == 0
        switch (group.reason, habitsOnly) {
        case (.tombstoned, true): Text("\(count) restored habits were deleted on another device")
        case (.tombstoned, false): Text("\(count) restored items were deleted on another device")
        case (_, true): Text("\(count) habits belong to another account")
        case (_, false): Text("\(count) items belong to another account")
        }
    }

    /// In the number the title counts: "1 restored habit was deleted on another device" stood over
    /// "Restore them as new copies … Your backup file keeps them either way." (E2E S6). The count
    /// only picks the plural form — "(… held)" in the key is never shown — as the Stats unit keys
    /// do ("days (unit after %lld)").
    @ViewBuilder
    private func convertibleExplanation(_ group: SyncService.HeldRows) -> some View {
        let count = group.counts.total
        if group.reason == .tombstoned {
            Text("Restore them as new copies to bring them back to your account, or discard them. Your backup file keeps them either way. (\(count) held)")
        } else {
            Text("They came from another account's data, so this account can't sync them as they are. Restore them as new copies to add them to this account. (\(count) held)")
        }
    }

    @ViewBuilder
    private func recoveredEditsRows(count: Int) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recovered Edits (\(count))")
                Text("Changes made on this device to items that were deleted on another device. Export them to keep a copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle")
        }
        .accessibilityElement(children: .combine)
        .sweepAnchor("syncRecovered")

        RecoveredEditsShareLink(sync: sync)

        Button(role: .destructive) {
            actionError = nil
            // The summary `count` was drawn from (the row shows only while it could be read).
            clearExpectedTotal = sync.recoveredEdits?.archivedTotal ?? 0
            showingClearConfirm = true
        } label: {
            Label("Clear Recovered Edits…", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .confirmationDialog("Clear Recovered Edits?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { clearRecoveredEdits(expectedTotal: clearExpectedTotal) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the only copy of these edits. Export them first if you might need them.")
        }
    }

    private var fullResyncRow: some View {
        Button {
            actionError = nil
            showingFullResyncConfirm = true
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Resync…")
                        // `Color.secondary`: see `ownerChoiceRow`.
                        Text("Sends everything on this device to your account again.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                if isResyncing {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(isResyncing)
        .accessibilityValue(isResyncing ? Text("Syncing") : Text(verbatim: ""))
        .confirmationDialog("Full Resync?", isPresented: $showingFullResyncConfirm, titleVisibility: .visible) {
            Button("Resync Everything") {
                Task { await fullResync() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stride first downloads your account's latest changes, then sends every habit, check-in and group on this device to your account again. Use it when another device is missing something.")
        }
    }

    // MARK: - Discard confirmation

    @ViewBuilder
    private func discardMessage(_ reason: SyncHoldReason, count: Int) -> some View {
        // The service's own note: a `not_owned` row from an owner-unknown upload may exist nowhere
        // else, and the confirmation must say so. A restored row's backup file still has it. In the
        // number the dialog discards; "(… held)" in the key only picks the form.
        if reason == .tombstoned {
            Text("They're removed from this device. Your backup file still has them. (\(count) held)")
        } else {
            Text("They're removed from this device, and they may not exist anywhere else. Export a backup first if you might want them. (\(count) held)")
        }
    }

    // MARK: - Actions

    private func restoreAsCopies(_ reason: SyncHoldReason) async {
        busyReason = reason
        actionError = nil
        defer { busyReason = nil }
        do {
            let outcome = try await actions.restoreAsCopies(reason)
            guard outcome.rows.total > 0 else { return }
            // Reminders are scheduled under the habit's id: the reschedule prunes the old ids and
            // schedules the new ones (SyncCopies.Outcome.habitIDs).
            rowsChanged()
            AccessibilityNotification.Announcement(appLocalized("Restored as new copies.")).post()
        } catch {
            showError()
        }
    }

    private func discard(_ reason: SyncHoldReason) async {
        busyReason = reason
        actionError = nil
        defer { busyReason = nil }
        do {
            let outcome = try await actions.discard(reason)
            guard outcome.rows.total > 0 else { return }
            rowsChanged()
            AccessibilityNotification.Announcement(appLocalized("Discarded.")).post()
        } catch {
            showError()
        }
    }

    private func clearRecoveredEdits(expectedTotal: Int) {
        actionError = nil
        do {
            guard try actions.clearRecoveredEdits(expectedTotal: expectedTotal) else {
                // More lines than the dialog was opened for: the row above shows the new count.
                let message = appLocalized("New recovered edits arrived. Export them, then try again.")
                actionError = message
                AccessibilityNotification.Announcement(message).post()
                return
            }
            AccessibilityNotification.Announcement(appLocalized("Recovered edits cleared.")).post()
        } catch {
            showError()
        }
    }

    private func fullResync() async {
        isResyncing = true
        defer { isResyncing = false }
        // A failure is the Account footer's (`SyncService.syncError`), like Sync Now's.
        if await actions.fullResync() {
            AccessibilityNotification.Announcement(appLocalized("Full resync finished.")).post()
        }
    }

    private func rowsChanged() {
        let container = modelContext.container
        NotificationService.shared.rescheduleAllHabitReminders(modelContainer: container)
        NotificationService.shared.updateBadge(modelContainer: container)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // The footer sits below the button that failed; VoiceOver hears it now.
    private func showError() {
        let message = appLocalized("Unable to save changes. Please try again.")
        actionError = message
        AccessibilityNotification.Announcement(message).post()
    }
}

/// "Export Recovered Edits": the owner's recovery log as a `.json` file
/// (`RecoveredEditsJSONFile`, written only when a destination is picked). Shared by the sync
/// section, Erase Local Data (offered before the erase, which hides the lines until that account
/// owns the store again) and the restore hand-over.
struct RecoveredEditsShareLink: View {
    let sync: SyncService

    var body: some View {
        ShareLink(
            item: sync.recoveredEditsFile,
            preview: SharePreview(DataExportService.fileName("Stride-RecoveredEdits", extension: "json"))
        ) {
            Label("Export Recovered Edits", systemImage: "square.and.arrow.up")
        }
    }
}

/// The orange-triangle footer line Settings uses for an error under the control that caused it.
///
/// `Color.secondary`, not the hierarchical `.secondary`: every use is in a section footer, whose
/// text is secondary already, and the hierarchical style resolved a level below it — the one line
/// that says what went wrong was the palest text on the screen (E2E S-DEL, Delete Account's "New
/// recovered edits arrived"). It wraps rather than truncating, as the footers' other text must.
struct SettingsInlineError: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Screenshots (DEBUG only)

#if DEBUG
/// `-demo -demoScenario <name>` states for screenshots of every row (DemoData reads the same
/// argument and falls back to its standard set for these names). DEBUG-only like `-paywall`: a
/// store build has no way to reach them, and `seed` writes into the store and the recovery log.
/// Requires `-demo` too, so the seeding only ever touches the demo set `-demo` just wrote.
///
/// - `heldRows`: one habit refused (`row_error`), one check-in `too_large`, two habits
///   `not_owned`, one restored habit deleted elsewhere (`tombstoned`).
/// - `recoveredEdits`: three recovery-log lines for the store's owner (or for no owner).
/// - `syncPaused`: the paused row (drawn, nothing written).
/// - `syncAll`: all of the above, plus the Full Resync row even when signed out.
/// - `deleteAccount`: Delete Account's last step (the export offer and the final button) for a
///   fake signed-in owner with two recovered edits; its buttons only close it.
/// - `restoreHandover`: the restore's hand-over step ("Before You Restore") for a fake previous
///   owner with one queued deletion and two recovered edits; Restore Anyway only closes it.
enum SyncSectionDemo: String {
    case heldRows, recoveredEdits, syncPaused, syncAll, deleteAccount, restoreHandover

    static let current: SyncSectionDemo? = {
        let arguments = CommandLine.arguments
        guard arguments.contains("-demo"), let idx = arguments.firstIndex(of: "-demoScenario"),
              idx + 1 < arguments.count else { return nil }
        return SyncSectionDemo(rawValue: arguments[idx + 1])
    }()

    /// The fake accounts the two sheet scenarios name (the account screen's demo uses the same).
    static let demoSignedIn = "sam@example.com"
    static let demoPreviousOwner = "alex@example.com"

    var showsPaused: Bool { self == .syncPaused || self == .syncAll }
    var showsFullResync: Bool { self == .syncAll }
    private var seedsHeldRows: Bool { self == .heldRows || self == .syncAll }
    private var seedsRecoveredEdits: Bool { self == .recoveredEdits || self == .syncAll }

    @MainActor private static var seeded = false

    /// Once per launch, when Settings first appears.
    @MainActor
    static func seedIfNeeded(context: ModelContext, sync: SyncService) {
        guard let demo = current, !seeded else { return }
        seeded = true
        if demo.seedsHeldRows { seedHeldRows(in: context) }
        if demo.seedsRecoveredEdits { seedRecoveredEdits(sync: sync) }
    }

    @MainActor
    private static func seedHeldRows(in context: ModelContext) {
        let habits = (try? context.fetch(FetchDescriptor<Habit>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        habits.first?.hold(.rowError)
        if habits.count > 1, let record = habits[1].records.max(by: { $0.date < $1.date }) {
            record.hold(.tooLarge)
        }
        for name in ["Evening Walk", "Stretch"] {
            let habit = Habit(name: name, emoji: "\u{1F6B6}", colorHex: "#5AC8FA")
            habit.sortOrder = 10_000
            context.insert(habit)
            habit.hold(.notOwned)
        }
        let restored = Habit(name: "Guitar Practice", emoji: "\u{1F3B8}", colorHex: "#FF2D55")
        restored.sortOrder = 11_000
        restored.restoredAt = Date()
        context.insert(restored)
        restored.hold(.tombstoned)
        try? context.save()
    }

    @MainActor
    private static func seedRecoveredEdits(sync: SyncService) {
        let owner = SyncOwnerStore(defaults: .standard).owner?.id
        let habit = Habit(name: "Piano", emoji: "\u{1F3B9}", colorHex: "#AF52DE")
        habit.records = [HabitRecord(date: HabitCalendar.dayKey(for: Date()), note: "Scales, 20 min"),
                         HabitRecord(date: HabitCalendar.dayKey(for: Date().addingTimeInterval(-86_400)))]
        let row = DataBackup.snapshot(habits: [habit], groups: []).habits[0]
        var items = [SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))]
        items += row.records.map {
            SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere,
                             row: .record($0, habitID: row.id, habitName: row.name))
        }
        try? sync.recoveryLog.clear(accountID: owner)
        try? sync.recoveryLog.append(items, accountID: owner)
        sync.refreshRecoveredEdits()
    }
}

/// `-scrollTo <anchor>`: the screen that has that anchor scrolls to it once, on launch, so
/// scripts/a11y_sweep.sh can capture what sits below the fold at accessibility sizes — the
/// `-statsScrollTo` idea (StatsView) for Settings' Sync rows, the account screen and the two
/// sheets. `simctl` has no touch input; the phase C frames under the fold were swiped by hand and
/// went stale with the first fix after them. Every screen with anchors asks; a proxy that has no
/// view with that id does nothing.
enum SweepScroll {
    static let anchor: String? = {
        let arguments = CommandLine.arguments
        guard let idx = arguments.firstIndex(of: "-scrollTo"), idx + 1 < arguments.count else { return nil }
        return arguments[idx + 1]
    }()

    private static let bottomSuffix = "@bottom"

    @MainActor
    static func scroll(_ proxy: ScrollViewProxy) async {
        guard let anchor else { return }
        // After the first layout pass (and a sheet's presentation): a scrollTo issued before the
        // target has a frame does nothing, silently.
        try? await Task.sleep(for: .milliseconds(800))
        // `<anchor>@bottom` puts the row at the bottom edge instead, so what sits just above it
        // is in the frame: Delete Account's "Signed in as" line, above its first export row, is
        // part of a row whose message fills the screen at accessibility sizes.
        if anchor.hasSuffix(bottomSuffix) {
            proxy.scrollTo(String(anchor.dropLast(bottomSuffix.count)), anchor: .bottom)
        } else {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}
#endif

extension View {
    /// A scroll target for `-scrollTo` (`SweepScroll`). Release builds return the view untouched,
    /// so the anchor cannot change identity or layout there.
    @ViewBuilder
    func sweepAnchor(_ name: String) -> some View {
        #if DEBUG
        id(name)
        #else
        self
        #endif
    }
}
