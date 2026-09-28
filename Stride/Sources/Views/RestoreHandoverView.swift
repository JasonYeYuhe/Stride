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
                        RecoveredEditsShareLink(sync: sync)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onRestore()
                    } label: {
                        Label("Restore Anyway", systemImage: "clock.arrow.circlepath")
                    }
                }
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

    @ViewBuilder
    private var headline: some View {
        let email = handover.previousOwner.email
        if email.isEmpty {
            Text("This device still holds changes from another account that restoring this backup leaves behind.")
        } else {
            Text("This device still holds changes from \(email) that restoring this backup leaves behind.")
        }
    }
}
