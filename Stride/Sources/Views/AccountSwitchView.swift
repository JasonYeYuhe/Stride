import SwiftUI
import SwiftData
import WidgetKit

/// The account screen (DEV-PLAN-1.3.md M2, "Account isolation"; Acceptance (5) and (10)): a
/// sign-in into an account that does not own this device's habits continues with ONE screen —
/// "This device holds another account's habits.", with the owner's email — and no sync request
/// is made, by any trigger,
/// until the user chooses (`SyncService.ownerConflict` blocks every run by construction).
///
/// - **Export a backup** first: M1's v2 JSON with the OWNER's `accountId` (whose ids the rows
///   carry), and the owner's recovered edits when the recovery log has lines.
/// - **Start from this account's data** (confirmed): the local rows, the deletion queue, the
///   cursor, the backoff and the recovery log go, the signed-in account becomes the owner, and
///   a full pull brings its habits down (`SyncService.startFromSignedInAccountsData`).
/// - **Upload these habits to this account** — only for an owner-unknown store, one that reached
///   1.3.1 signed out with rows 1.3.0 never tied to an account (sub-decision (e)). It forgets
///   every delivery mark first (`SyncService.uploadLocalHabits`), so nothing is deleted by
///   absence from the account's snapshot.
/// - **Cancel** signs out of the account just signed into; the store and its owner are untouched,
///   and Today's "Sign in again" row, if it was up before that sign-in, is up again.
///
/// There is no "keep these habits and add them to this account" for a known owner: reactive
/// `not_owned` handling cannot find a habit the other account created offline and never pushed,
/// so it would land in this account with no skip reason (M2, "Why no keep-and-add").
///
/// Not interruptive UI: it is shown only as the next step of a sign-in the user started — inside
/// LoginView for a typed code (or a link tapped while LoginView waits), and as a sheet from
/// StrideApp for a one-tap link with no LoginView open. A launch or foreground sync that finds
/// the same conflict (the user quit with this screen up) blocks silently; Settings shows it
/// inline. It cannot be swiped away: leaving it without a choice would leave the device signed in
/// and never syncing, so its Cancel is the way out, and it signs out.
struct AccountSwitchView: View {
    let conflict: SyncOwnerConflict
    /// The DEBUG screenshot scenarios (`-demoScenario accountConflict | accountUnknownOwner`):
    /// fake accounts over the demo store; no button touches the store, the session or the
    /// network — each just closes the screen.
    var isDemo = false
    /// The choice is made (or the conflict is gone): the presenter closes the flow.
    var onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    private var sync = SyncService.shared
    private var auth = AuthService.shared

    @State private var holdings: SyncOwnerHoldings?
    @State private var confirmingStart = false
    @State private var working: Choice?
    @State private var failure: String?

    private enum Choice { case start, upload, cancel }

    init(conflict: SyncOwnerConflict, isDemo: Bool = false, onFinish: @escaping () -> Void) {
        self.conflict = conflict
        self.isDemo = isDemo
        self.onFinish = onFinish
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let holdings { holdingsSummary(holdings).sweepAnchor("accountHoldings") }
                    explanation
                    exportButtons.sweepAnchor("accountExport")
                    choiceButtons.sweepAnchor("accountChoices")
                    if let failure {
                        Label {
                            Text(verbatim: failure)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    cancelNote
                }
                .padding(24)
                // A readable measure on the Mac and on iPad sheets; phones use the full width.
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            #if DEBUG
            .task { await SweepScroll.scroll(proxy) }
            #endif
        }
        .navigationTitle("This Device's Habits")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { Task { await cancel() } }
                    .disabled(choicesDisabled)
            }
        }
        .interactiveDismissDisabled()
        .confirmationDialog("Start from this account's data?", isPresented: $confirmingStart, titleVisibility: .visible) {
            Button("Start from This Account's Data", role: .destructive) {
                Task { await start() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every habit, check-in and group on this device will be deleted, and this account's habits will be downloaded. Changes that were never synced can't be recovered unless you exported a backup.")
        }
        .task { holdings = isDemo ? demoHoldings : sync.holdings(for: conflict, in: modelContext) }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
                // Decoration: at the largest sizes it only pushes the question further down.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            Group {
                if conflict.owner != nil {
                    Text("This device holds another account's habits.")
                } else {
                    Text("This device has habits that aren't linked to an account.")
                }
            }
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)

            // The addresses on lines of their own, not inside the sentences: wrapped inside a
            // sentence they were hyphenated at accessibility sizes ("alex@exam-" / "ple.com.")
            // and broken mid-address in Japanese even at the default size — the one thing this
            // screen asks the user to recognise, misprinted (phase C review, UI-5 / L6).
            if let owner = conflict.owner {
                AccountAddressLine(caption: Text("Habits from"), email: owner.email)
            }
            AccountAddressLine(caption: Text("Signed in as"), email: conflict.signedIn.email)
        }
    }

    /// What Start would erase, so the choice is made knowing it. Counts use the plural keys.
    private func holdingsSummary(_ h: SyncOwnerHoldings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Each count is bound to `count` first: the runtime key is "%lld habits" whatever
            // the expression, and LocalizationSourceScanTests types interpolations by name.
            if h.habits > 0 {
                let count = h.habits
                summaryLine("checklist", Text("\(count) habits"))
            }
            if h.checkIns > 0 {
                let count = h.checkIns
                summaryLine("checkmark.circle", Text("\(count) check-ins"))
            }
            if h.groups > 0 {
                let count = h.groups
                summaryLine("folder", Text("\(count) groups"))
            }
            if h.queuedDeletions > 0 {
                let count = h.queuedDeletions
                summaryLine("trash", Text("\(count) deletions not yet synced"))
            }
            if let count = h.recoveredEdits, count > 0 {
                summaryLine("clock.arrow.circlepath", Text("\(count) recovered edits"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
        // One stop for VoiceOver: "3 habits, 120 check-ins".
        .accessibilityElement(children: .combine)
    }

    private func summaryLine(_ symbol: String, _ text: Text) -> some View {
        Label { text } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conflict.isOwnerUnknown {
                Text("Stride can't tell which account these habits came from. Upload them to this account, or start from this account's data instead.")
            } else {
                Text("Stride keeps each account's habits separate. Starting from this account's data removes these habits from this device and downloads this account's habits. Anything already synced stays in the other account.")
            }
            Text("Changes that never synced exist only on this device. Export a backup first to keep a copy.")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Written on the tap, then shared (ExportShareButton). The store is frozen while this screen
    /// is up — no sync runs until the choice — so what is written is what Start would erase.
    private var exportButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExportShareButton(sync.backupFile(for: conflict), sync: sync) {
                Label("Export a Backup", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(working != nil)

            // The edits a deletion took from rows the user had changed: the only copy, and Start
            // clears it. Offered when the log has lines — or could not be read, since then no
            // one can say it is empty.
            // `if let` first: before `.task` has counted, `holdings` is nil, and `nil != 0` offered
            // the button on the first frame only to remove it a moment later.
            if let holdings, holdings.recoveredEdits != 0 {
                ExportShareButton(sync.recoveredEditsFile(for: conflict), sync: sync) {
                    Label("Export Recovered Edits", systemImage: "square.and.arrow.up.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(working != nil)
            }
        }
    }

    /// A choice is running, or an export above is still being written: every choice closes this
    /// screen, which drops a share whose file is not written yet — and Start erases what that file
    /// copies (`SyncService.isWritingExport`). The exports wait only on a choice.
    private var choicesDisabled: Bool { working != nil || sync.isWritingExport }

    private var choiceButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conflict.isOwnerUnknown {
                Button {
                    Task { await upload() }
                } label: {
                    progressLabel(for: .upload) { Text("Upload These Habits to This Account") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(choicesDisabled)
                .accessibilityLabel(Text("Upload These Habits to This Account"))
                .accessibilityValue(working == .upload ? Text("In progress") : Text(verbatim: ""))
            }

            Button(role: .destructive) {
                confirmingStart = true
            } label: {
                progressLabel(for: .start) { Text("Start from This Account's Data") }
            }
            .buttonStyle(.bordered)
            // Red, as its confirmation's button is: under the app's green tint the role alone drew
            // it exactly like "Export a Backup", the one irreversible choice on the screen looking
            // like the safe one (E2E S5).
            .tint(.red)
            .disabled(choicesDisabled)
            .accessibilityLabel(Text("Start from This Account's Data"))
            .accessibilityValue(working == .start ? Text("In progress") : Text(verbatim: ""))
        }
    }

    /// The button's title, or a spinner while its choice runs. The title stays for VoiceOver
    /// (the spinner alone has no name), as LoginView's buttons do.
    private func progressLabel(for choice: Choice, @ViewBuilder title: () -> Text) -> some View {
        ZStack {
            title().opacity(working == choice ? 0 : 1)
            if working == choice { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 20)
        .multilineTextAlignment(.center)
    }

    /// "This account" is the "Signed in as" address above it (no address here: see `header`).
    private var cancelNote: some View {
        Text("Cancel signs you out of this account and leaves this device as it is.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Choices

    private func start() async {
        guard !isDemo else { return onFinish() }
        working = .start
        defer { working = nil }
        await sync.startFromSignedInAccountsData(conflict, in: modelContext)
        finishOrShowFailure(afterErase: true)
    }

    private func upload() async {
        guard !isDemo else { return onFinish() }
        working = .upload
        defer { working = nil }
        await sync.uploadLocalHabits(conflict, in: modelContext)
        finishOrShowFailure(afterErase: false)
    }

    /// Cancel: sign out of the account just signed into (`signedOut` clears `ownerConflict`); the
    /// store, its owner, its cursor and its queue are untouched, and a "Sign in again" row the
    /// sign-in ended comes back (`AuthService.cancelSignIn`, review accounts-2).
    private func cancel() async {
        guard !isDemo else { return onFinish() }
        working = .cancel
        defer { working = nil }
        await auth.cancelSignIn()
        onFinish()
    }

    /// The choice took effect when the conflict is gone — `ownerConflict` is cleared by a
    /// successful erase or upload (the sync after it may still have failed; Settings shows that
    /// like any other), and by a sign-out elsewhere, which also ends this screen. Otherwise the
    /// store refused the write and nothing changed: say so and stay.
    private func finishOrShowFailure(afterErase: Bool) {
        guard sync.ownerConflict != nil else {
            if afterErase { AccountDataRefresh.afterLocalChange(in: modelContext.container) }
            return onFinish()
        }
        let message = sync.syncError ?? appLocalized("Unable to save changes. Please try again.")
        failure = message
        AccessibilityNotification.Announcement(message).post()
    }

    /// The screenshot scenarios' list: the demo store's real counts, plus a queued deletion and
    /// two recovered edits so every line of the screen is on the capture.
    private var demoHoldings: SyncOwnerHoldings {
        var h = SyncOwnerHoldings()
        h.habits = (try? modelContext.fetchCount(FetchDescriptor<Habit>())) ?? 0
        h.checkIns = (try? modelContext.fetchCount(FetchDescriptor<HabitRecord>())) ?? 0
        h.groups = (try? modelContext.fetchCount(FetchDescriptor<HabitGroup>())) ?? 0
        h.queuedDeletions = conflict.isOwnerUnknown ? 0 : 1
        h.recoveredEdits = conflict.isOwnerUnknown ? 0 : 2
        return h
    }
}

/// A caption and an email address that never wraps: one line, shrunk to fit rather than broken
/// or hyphenated. One VoiceOver stop ("Habits from, alex@example.com"). The account screen's
/// header, and every other screen that names an account (the restore hand-over, Delete Account):
/// an address inside a sentence was hyphenated at accessibility sizes (phase C review, UI-5).
struct AccountAddressLine: View {
    let caption: Text
    let email: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: email)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Presentation

/// One account-screen presentation from the root (StrideApp's sheet).
struct AccountChoiceRequest: Identifiable {
    var conflict: SyncOwnerConflict
    var isDemo = false
    var id: String { conflict.id }
}

/// Who shows the account screen for a sign-in that just completed.
///
/// A typed code — and a login link tapped while LoginView waits on "Check your email" — continue
/// inside LoginView's own sheet (SwiftUI shows one sheet at a time, and that one is already up).
/// A one-tap link with no LoginView open (Mail → the app on Today, or the Mac's main window)
/// continues in a sheet StrideApp presents from `request`. LoginView counts itself in
/// `loginFlowsOpen` so StrideApp knows which case it is.
@MainActor
@Observable
final class AccountChoiceRouter {
    static let shared = AccountChoiceRouter()

    var request: AccountChoiceRequest?
    @ObservationIgnored var loginFlowsOpen = 0

    #if DEBUG
    /// `-demoScenario accountConflict | accountUnknownOwner` (with `-demo`, for the demo store):
    /// the account screen at launch, with fake accounts and no network sign-in, for
    /// scripts/screenshots and the accessibility sweep. DEBUG-only, like `-paywall`: release
    /// builds have no screen that appears without a user action.
    static func demoRequest(arguments: [String] = CommandLine.arguments) -> AccountChoiceRequest? {
        guard let idx = arguments.firstIndex(of: "-demoScenario"), idx + 1 < arguments.count else { return nil }
        let signedIn = SyncAccount(id: "demo-signed-in", email: "sam@example.com")
        switch arguments[idx + 1] {
        case "accountConflict":
            let owner = SyncOwner(SyncAccount(id: "demo-owner", email: "alex@example.com"))
            return AccountChoiceRequest(conflict: SyncOwnerConflict(owner: owner, signedIn: signedIn), isDemo: true)
        case "accountUnknownOwner":
            return AccountChoiceRequest(conflict: SyncOwnerConflict(owner: nil, signedIn: signedIn), isDemo: true)
        default:
            return nil
        }
    }
    #endif
}

/// StrideApp's sheet: the screen in a navigation stack of its own (in LoginView it shares the
/// login sheet's).
struct AccountChoiceSheet: View {
    let request: AccountChoiceRequest
    var onFinish: () -> Void

    var body: some View {
        NavigationStack {
            AccountSwitchView(conflict: request.conflict, isDemo: request.isDemo, onFinish: onFinish)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

// MARK: - After the store changed under the UI

/// What hangs off the store once a flow outside the list screens erased or replaced it (Start
/// from this account's data, account deletion): per-habit reminders of habits that are gone, the
/// badge, the widgets — as Erase Local Data does in Settings — and the export files in tmp, which
/// hold copies of what was erased (E2E S-DEL: after Delete Account the deleted account's backup
/// and recovered edits were still there).
///
/// Not every export at once, though (1.4.0, RELEASE-1.4.0.md D6). 1.3.x swept them all on the
/// premise that every export these flows offered was shared before the button that erased the
/// store could be tapped. A receiver does get its own copy of the file when it loads it
/// (`ExportSharePresenter.itemProvider`), but a Mac service or an iOS AirDrop can load after the
/// sheet has gone, while Start or Delete My Account are already tappable — and that export is the
/// copy of exactly what is being erased. So the exports of the last ten minutes stay, and one
/// deferred sweep takes them (`DataExportService.removeExportFilesAfterErase`).
@MainActor
enum AccountDataRefresh {
    static func afterLocalChange(in container: ModelContainer) {
        NotificationService.shared.rescheduleAllHabitReminders(modelContainer: container)
        NotificationService.shared.updateBadge(modelContainer: container)
        WidgetCenter.shared.reloadAllTimelines()
        DataExportService.removeExportFilesAfterErase()
    }
}
