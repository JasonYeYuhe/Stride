import SwiftUI

/// The restore's hand-over step: the phase B rule for the restore screen (DEV-PLAN-1.3.md M2
/// progress log, 2026-09-29). A restore that moves the store away from an owner who still has
/// queued deletions or recovery-log lines says what is left behind and offers the export first —
/// the account screen's "This device holds … from <owner>", in the restore's words — instead of
/// dropping them silently (`DataExportService.restoreHandover`).
///
/// It continues the restore the user started (file picked, choice confirmed): a sheet in that
/// flow, never one that appears on its own (acceptance 10). Cancel changes nothing; "Restore
/// Anyway" is the second, explicit confirmation.
struct RestoreHandoverView: View {
    let handover: RestoreHandover
    let sync: SyncService
    let onRestore: () -> Void
    let onCancel: () -> Void

    /// nil (the log could not be counted) still offers the export: the lines may be there.
    private var offersExport: Bool { handover.recoveredEdits != 0 }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        headline
                        if handover.queuedDeletions > 0 {
                            let count = handover.queuedDeletions
                            // The account screen's key for the same queue: one wording, one plural entry.
                            Label("\(count) deletions not yet synced", systemImage: "trash")
                        }
                        if let count = handover.recoveredEdits, count > 0 {
                            Label("\(count) recovered edits", systemImage: "arrow.uturn.backward.circle")
                        }
                    } footer: {
                        footer
                    }

                    if offersExport {
                        Section {
                            RecoveredEditsExportButton(sync: sync)
                                .sweepAnchor("handoverExport")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            onRestore()
                        } label: {
                            // Red icon as well as title, as the Sync section's destructive rows
                            // (phase C review, UI-6): the role colours the title only. Dimmed by
                            // hand while disabled, as Delete My Account.
                            Label("Restore Anyway", systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.red.opacity(sync.isWritingExport ? 0.4 : 1))
                        }
                        // Not while the export above is being written: this closes the sheet
                        // under it, and its share was dropped (`SyncService.isWritingExport`).
                        .disabled(sync.isWritingExport)
                        .sweepAnchor("handoverRestore")
                    }
                }
                #if DEBUG
                .task { await SweepScroll.scroll(proxy) }
                #endif
            }
            .navigationTitle("Before You Restore")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    /// What the restore does to what is listed — only what is listed: a hand-over for recovered
    /// edits alone used to warn about deletions that did not exist. A log that could not be read
    /// (`recoveredEdits == nil`) counts as having lines, as it does for the export.
    @ViewBuilder
    private var footer: some View {
        let hasDeletions = handover.queuedDeletions > 0
        let hasEdits = handover.recoveredEdits != 0
        if hasDeletions && hasEdits {
            Text("If you restore, the deletions are dropped, and the recovered edits are shown again only when that account uses this device. To send the deletions instead, cancel, sign in to that account and sync first.")
        } else if hasDeletions {
            Text("If you restore, the deletions are dropped. To send them instead, cancel, sign in to that account and sync first.")
        } else {
            Text("If you restore, the recovered edits are shown again only when that account uses this device.")
        }
    }

    /// The sentence, then the owner's address on a line of its own, as the account screen's
    /// header (`AccountAddressLine`): inside the sentence the address was hyphenated at
    /// accessibility sizes (phase C review, UI-5; the owner's decision 4 for this screen). An
    /// owner recorded without an email keeps the sentence alone.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This device still holds changes from another account that restoring this backup leaves behind.")
                .fixedSize(horizontal: false, vertical: true)
            let email = handover.previousOwner.email
            if !email.isEmpty {
                AccountAddressLine(caption: Text("Changes from"), email: email)
            }
        }
        .padding(.vertical, 2)
    }
}
