import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The app side of backup and export: the export files, reading a picked file, and the words for
/// what went wrong. The formats, validation, restore and erase themselves are in
/// Shared/DataBackup.swift, where StrideTests can run them.
///
/// Write first, then share (1.4.0, RELEASE-1.4.0.md D6). 1.3.x handed ShareLink lazy
/// `Transferable` items whose file was written only when the share sheet asked for it, with the
/// sheet blocking the main thread while it waited (`NSExtensionURLResult wait:` in the stack) —
/// and the backup's snapshot needs the main actor. That was STRIDE-APPLE-7 (a 2 s+ hang in macOS
/// 1.3.0's NSSharingServicePicker, Sentry) and the 6–7 s before the iOS share sheet appeared. Now the Export button (`ExportShareButton`)
/// writes the file on the tap — the snapshot on the main actor, the encode and the write off
/// it — and presents the share sheet (iOS) or the save panel (macOS) only once the file exists.
/// Settings used to build both exports as `String`s in its body on every render; nothing is
/// serialised now until a button is tapped.
enum DataExportService {

    // MARK: - Producing the files

    /// `account` is the store's sync owner (`SyncOwnerStore.owner`), recorded in the file so a
    /// restore can tell whether it may keep the file's ids (`DataBackup.restoreDecision`). The
    /// caller passes it — signed in or not, the owner is whose ids the rows carry; nil for a
    /// store with no owner.
    @MainActor
    static func backupJSONData(from context: ModelContext, account: BackupAccount?,
                               exportedAt: Date = Date()) throws -> Data {
        try DataBackup.encode(DataBackup.snapshot(of: context, exportedAt: exportedAt, account: account))
    }

    /// The store's sync owner as a backup records it, or nil for a store with no owner. The
    /// owner, not whoever is signed in: a backup must name the account whose ids the rows carry,
    /// and a signed-out device (or one signed into another account, before the account screen
    /// settles it) still holds the owner's rows.
    static func storeOwnerAccount(defaults: UserDefaults = .standard) -> BackupAccount? {
        SyncOwnerStore(defaults: defaults).owner.map { BackupAccount(id: $0.id, email: $0.email) }
    }

    @MainActor
    static func csvData(from context: ModelContext) throws -> Data {
        DataBackup.csvData(try DataBackup.snapshot(of: context))
    }

    /// `Stride-Backup-2026-09-27.json`, dated in the user's own time zone. ASCII on purpose: the
    /// name travels through mail, cloud drives and other people's machines.
    static func fileName(_ stem: String, extension ext: String, date: Date = Date()) -> String {
        "\(stem)-\(fileDateFormatter.string(from: date)).\(ext)"
    }

    // MARK: - Writing an export (write first, then share)

    /// What the Export button at `file` writes, written: `writeBackupFile`, `writeCSVFile`, or
    /// the recovered edits through `SyncService.writeRecoveredEditsFile`, which remembers the
    /// total the file holds for Clear and Erase. The one call `ExportShareButton` makes, so the
    /// hosted tests run exactly what a tap runs. `root` is tmp; tests pass their own directory.
    ///
    /// Counted in `SyncService.exportWrites` from the tap to the written file: the buttons that
    /// erase what an export copies are disabled meanwhile (`SyncService.isWritingExport`).
    @MainActor
    static func write(_ file: ExportFile, container: ModelContainer, sync: SyncService? = nil,
                      in root: URL = FileManager.default.temporaryDirectory) async throws -> WrittenExport {
        let sync = sync ?? .shared   // see `restore` for the optionals
        return try await sync.countingExportWrite {
            switch file {
            case .backup(let account):
                return try await writeBackupFile(container: container, account: account, in: root)
            case .ownerBackup:
                // The owner as the tap finds it, read in the same main-actor turn as the snapshot:
                // the descriptor, built at render, can be older than a sync that settled the owner.
                let owner = sync.storeOwner.map { BackupAccount(id: $0.id, email: $0.email) }
                return try await writeBackupFile(container: container, account: owner, in: root)
            case .csv:
                return try await writeCSVFile(container: container, in: root)
            case .recoveredEdits(let accountID):
                return try await sync.writeRecoveredEditsFile(accountID: accountID, in: root)
            }
        }
    }

    /// The lossless v2 backup, `Stride-Backup-<date>.json`, naming `account`. The snapshot is read
    /// on the main actor (SwiftData models belong to the context's actor); the encode and the
    /// write run off it, so a multi-year history does not hold the main thread while it is
    /// serialised.
    @MainActor
    static func writeBackupFile(container: ModelContainer, account: BackupAccount?,
                                in root: URL = FileManager.default.temporaryDirectory) async throws -> WrittenExport {
        let document = try DataBackup.snapshot(of: container.mainContext, account: account)
        let name = fileName("Stride-Backup", extension: "json", date: document.exportedAt)
        let url = try await Task.detached(priority: .userInitiated) {
            try writeExportFile(try DataBackup.encode(document), named: name, in: root)
        }.value
        return WrittenExport(url: url)
    }

    /// One row per check-in, `Stride-Export-<date>.csv`, for spreadsheets. As `writeBackupFile`:
    /// the snapshot on the main actor, the rest off it.
    @MainActor
    static func writeCSVFile(container: ModelContainer,
                             in root: URL = FileManager.default.temporaryDirectory) async throws -> WrittenExport {
        let document = try DataBackup.snapshot(of: container.mainContext)
        let name = fileName("Stride-Export", extension: "csv", date: document.exportedAt)
        let url = try await Task.detached(priority: .userInitiated) {
            try writeExportFile(DataBackup.csvData(document), named: name, in: root)
        }.value
        return WrittenExport(url: url)
    }

    /// The recovery log's export (`SyncRecoveryExport`) for `accountID`,
    /// `Stride-RecoveredEdits-<date>.json`, with the archived total it holds. All of it off the
    /// main actor: the read takes the log's flock — which the main-actor sync engine takes to
    /// append — and reads a file of up to 5 MB. Deliberately not a backup: picked in Restore it is
    /// `notABackup` (its version key is `recoveryLogVersion`). Call it through
    /// `SyncService.writeRecoveredEditsFile`, which remembers the total.
    static func writeRecoveredEditsFile(log: SyncRecoveryLog, accountID: String?,
                                        in root: URL = FileManager.default.temporaryDirectory) async throws -> WrittenExport {
        try await Task.detached(priority: .userInitiated) {
            let export = try log.export(accountID: accountID)
            let url = try writeExportFile(export.data, named: fileName("Stride-RecoveredEdits", extension: "json"),
                                          in: root)
            return WrittenExport(url: url, recoveredEditsTotal: export.archivedTotal)
        }.value
    }

    // MARK: - The files in tmp

    /// Every export file is written into a directory of its own in tmp, named with this prefix.
    /// scripts/sim_e2e/app.sh `exports` lists them by it.
    static let exportDirectoryPrefix = "StrideExport-"

    /// Writes one export into a new `StrideExport-<UUID>` directory under `root`: two exports on
    /// the same day must not overwrite a file a share sheet may still be reading. A write that
    /// fails takes its directory with it, so a failed export leaves nothing behind.
    static func writeExportFile(_ data: Data, named name: String,
                                in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent(exportDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    /// Deletes the export at `url` — its whole `StrideExport-<UUID>` directory — at once, for an
    /// export that was written and then handed to no one: the Mac menu Export's save panel
    /// cancelled, or its pass dropped before the panel came up (ContentView). Nothing can be
    /// reading such a file, so it does not wait for a sweep: on a Mac, launches can be weeks
    /// apart, and every ⇧⌘E → Cancel used to leave one more full backup of every habit in tmp
    /// until the next launch (W6 review). Never for a file a share sheet or a save panel still
    /// has (D6: a share cannot tell when its receiver is done reading); those are the sweeps'.
    ///
    /// Only a directory named with `exportDirectoryPrefix`: a URL that is not one of ours removes
    /// nothing. Returns whether the directory went.
    @discardableResult
    static func removeUnsharedExport(at url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix(exportDirectoryPrefix) else { return false }
        return (try? FileManager.default.removeItem(at: directory)) != nil
    }

    /// How long a fresh export survives an erase (RELEASE-1.4.0.md D6, "Cleanup").
    static let exportGracePeriod: TimeInterval = 10 * 60

    /// Deletes the export directories under `root` — every one, or with `olderThan`, only those
    /// made at least that long before `now` — and returns how many went (E2E S-DEL).
    ///
    /// Nothing ever removed them: tmp kept every backup, CSV and recovered-edits file shared since
    /// the app was installed (three copies per tap in 1.3.0), and after Delete Account the deleted
    /// account's habits and edits were still there, although the deletion erases this device's
    /// copy. Called in full at launch (StrideApp; no share sheet is open then), and after the
    /// erases (`removeExportFilesAfterErase`).
    ///
    /// The receiver of a share gets its own copy of the file when it loads it — the share sheet's
    /// item provider registers it without open-in-place (`ExportSharePresenter`), as 1.3.x's
    /// `SentTransferredFile` did — so deleting ours after that cuts nothing off. What a sweep can
    /// still cut off is a share that has not loaded yet: the sheet still open, or a Mac service
    /// that reads later. So an erase spares the exports of the last `exportGracePeriod`.
    ///
    /// A directory whose age cannot be read counts as fresh: an erase leaves it to the deferred
    /// sweep or the next launch rather than risk the backup of what it erased. One that cannot be
    /// removed now is left for the next call.
    @discardableResult
    static func removeExportFiles(in root: URL = FileManager.default.temporaryDirectory,
                                  olderThan age: TimeInterval = 0, now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(exportDirectoryPrefix) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if age > 0 {
                let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                guard let made = values?.creationDate ?? values?.contentModificationDate,
                      now.timeIntervalSince(made) >= age else { continue }
            }
            if (try? fileManager.removeItem(at: directory)) != nil { removed += 1 }
        }
        return removed
    }

    /// After an erase (Erase Local Data, Start from This Account's Data, account deletion): the
    /// exports go with the data they copy (E2E S-DEL), except those of the last
    /// `exportGracePeriod`, which one deferred sweep takes once they are that old.
    ///
    /// 1.3.x deleted every export here, on the premise that the flow's exports "were shared
    /// before the button that erased could be tapped". Not on a Mac: the share or save UI lets go
    /// of the window while the receiver may still be reading, and an iOS AirDrop can outlast the
    /// sheet. The export a user just made of the data they are erasing is the one copy that must
    /// not go (design review, "export-cleanup-races-inflight-share").
    ///
    /// The deferred sweep spares the last `exportGracePeriod` too: it runs once everything that
    /// existed at the erase is past it, so it takes all of that, and an export made after the
    /// erase gets its own window. On a Mac, where launches can be weeks apart, a deleted account's
    /// export does not linger; the launch sweep still covers an iOS app suspended meanwhile.
    ///
    /// Returns the deferred sweep, for the hosted tests: with `deferredExportSweepDelay`
    /// shortened, they await it to see the erase's own call schedule it (W4 review: a test that
    /// scheduled one itself passed with this line gone).
    @discardableResult
    static func removeExportFilesAfterErase(in root: URL = FileManager.default.temporaryDirectory) -> Task<Int, Never> {
        removeExportFiles(in: root, olderThan: exportGracePeriod)
        return scheduleDeferredExportSweep(in: root)
    }

    #if DEBUG
    /// How long after an erase its deferred sweep runs: just past `exportGracePeriod`, so
    /// everything that existed at the erase has left the window by then. Settable in DEBUG only,
    /// for the hosted tests, which shorten it to see the sweep an erase schedules run
    /// (ExportTests, LocalDataFlowTests); the sweep's rule stays the grace period.
    static var deferredExportSweepDelay: Duration = .seconds(exportGracePeriod + 5)
    #else
    static let deferredExportSweepDelay: Duration = .seconds(exportGracePeriod + 5)
    #endif

    /// The deferred half of `removeExportFilesAfterErase`, off the main actor: after `delay`,
    /// every export directory older than the grace period.
    @discardableResult
    static func scheduleDeferredExportSweep(in root: URL = FileManager.default.temporaryDirectory,
                                            after delay: Duration = deferredExportSweepDelay) -> Task<Int, Never> {
        Task.detached(priority: .utility) {
            do { try await Task.sleep(for: delay) } catch { return 0 }
            return removeExportFiles(in: root, olderThan: exportGracePeriod)
        }
    }

    // MARK: - Reading a picked file

    /// Reads a file from `.fileImporter` and decodes it (`DataBackup.decode`). Checks the size
    /// on disk before reading, so picking a 2 GB video by mistake fails at once instead of
    /// loading it into memory. Not main-actor: call it from a detached task for large files.
    static func readBackup(at url: URL, limits: DataBackup.Limits = .default) throws -> BackupDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limits.maxBytes {
            throw DataBackupError.fileTooLarge(bytes: size, limit: limits.maxBytes)
        }
        let data = try Data(contentsOf: url)
        return try DataBackup.decode(data, limits: limits)
    }

    // MARK: - Restore and erase, around sync

    /// What the restore screen offers for `document` on this device (`DataBackup.restoreDecision`,
    /// M2 "Restore into another account"): keep the ids when the file is the signed-in account's
    /// own — or, signed out, the account the user names as `next` — and otherwise "Restore as new
    /// copies", with keeping the ids still offered for a file that names no account (every 1.3.0
    /// backup). The screen restores with `plan` (or `keepIDsInstead`) through
    /// `restore(_:into:plan:…)`.
    @MainActor
    static func restoreDecision(for document: BackupDocument, next: BackupAccount? = nil,
                                sync: SyncService? = nil) -> RestoreDecision {
        let sync = sync ?? .shared   // see `restore` for the optionals
        return DataBackup.restoreDecision(for: document, device: sync.restoreDevice(next: next))
    }

    /// `DataBackup.restore` once no sync is in flight, with `plan`'s identity, and then the
    /// store's owner set to `plan.owner` (`SyncService.adoptRestoredStore`): copies restored
    /// while signed into B belong to B and go up on the next sync with no second sign-in; a
    /// restore made signed out, naming no account, leaves the store for the next sign-in to adopt.
    ///
    /// A full pull already awaiting its response — the first sync after a sign-in, on a slow
    /// link, easily outlasts picking a file and confirming — used to land after the restore and
    /// delete every restored habit, group and check-in the account did not hold (SyncReconciler's
    /// full-pull pass), with no message. After the wait the store is checked again: if that pull
    /// brought the account's habits down, this is `storeNotEmpty`. The owner is set only once the
    /// restore has saved; a refused or failed restore changes no owner.
    @MainActor
    @discardableResult
    static func restore(_ document: BackupDocument, into context: ModelContext, plan: RestorePlan,
                        sync: SyncService? = nil,
                        deletionQueue: SyncDeletionQueue = .live) async throws -> BackupPreview {
        let sync = sync ?? .shared
        await sync.waitUntilIdle()
        let preview = try DataBackup.restore(document, into: context, identity: plan.identity,
                                             withdrawingDeletionsFrom: deletionQueue)
        sync.adoptRestoredStore(owner: plan.owner)
        return preview
    }

    /// What the restore confirmation offers for `document` here and now: `restoreDecision` as
    /// the screen needs it, one case per wording (M2, "Restore into another account"; phase C).
    ///
    /// Signed out, the decision is asked twice when the file names an account: `restoreDecision`
    /// can keep the ids only for the account the user says this device will use next, and the
    /// screen asks exactly that ("Restore as It Was" = yes, that account; copies = no). Asking
    /// only when the file names one keeps a 1.3.0 file's question the same signed in or out.
    @MainActor
    static func restoreChoices(for document: BackupDocument, sync: SyncService? = nil) -> RestoreChoices {
        let sync = sync ?? .shared   // see `restore` for the optionals
        let decision = restoreDecision(for: document, sync: sync)
        guard decision.offersCopies else {
            return RestoreChoices(kind: .sameAccount, primary: decision.plan, keepIDs: nil)
        }
        let email = document.account.map(\.email).flatMap { $0.isEmpty ? nil : $0 }
        let signedIn: Bool
        if case .signedIn = sync.restoreDevice() { signedIn = true } else { signedIn = false }
        if !signedIn, let account = document.account {
            let named = restoreDecision(for: document, next: account, sync: sync)
            return RestoreChoices(kind: .namedAccountWhileSignedOut(email: email),
                                  primary: decision.plan, keepIDs: named.plan)
        }
        if let keep = decision.keepIDsInstead {
            return RestoreChoices(kind: .noAccount(signedIn: signedIn), primary: decision.plan, keepIDs: keep)
        }
        return RestoreChoices(kind: .otherAccount(email: email), primary: decision.plan, keepIDs: nil)
    }

    /// The phase B rule for the restore screen (DEV-PLAN-1.3.md M2 progress log, 2026-09-29): a
    /// restore with `plan` that would move the store away from an owner who still has queued
    /// deletions or recovery-log lines must not drop them silently. `restore(_:into:plan:…)`
    /// hands the store over through `SyncService.adoptRestoredStore`, which clears the previous
    /// owner's deletion queue (a queue is true only for its account) and leaves that owner's
    /// recovered edits on disk where only that owner, owning the store again, is shown them.
    ///
    /// nil when nothing is left behind: no owner, the same owner, or an owner with an empty
    /// queue and log. Otherwise the screen shows what goes and offers the export first (the
    /// account screen's "This device holds … from <owner>", in the restore's words), and restores
    /// only on a second, explicit confirmation.
    ///
    /// A log that cannot be read counts as something to lose (`recoveredEdits == nil`), as in
    /// `SyncService.hasSomethingToLose`: asking once too often is cheap, dropping lines is not.
    @MainActor
    static func restoreHandover(for plan: RestorePlan, sync: SyncService? = nil,
                                deletionQueue: SyncDeletionQueue = .live,
                                defaults: UserDefaults = .standard) -> RestoreHandover? {
        let sync = sync ?? .shared
        guard let owner = storeOwnerAccount(defaults: defaults), plan.owner?.id != owner.id else { return nil }
        let queued = deletionQueue.pending().count
        let lines = try? sync.recoveryLog.lineCount(accountID: owner.id)
        guard queued > 0 || (lines ?? 1) > 0 else { return nil }
        return RestoreHandover(previousOwner: owner, queuedDeletions: queued, recoveredEdits: lines)
    }

    /// 1.3.0's restore: the file's ids, every row marked `restoredAt` (so no pull deletes it — a
    /// tombstoned one is held for "Restore as new copies"), and no owner change. Settings no
    /// longer calls it (phase C restores through `restoreChoices` and `restore(_:into:plan:…)`);
    /// LocalDataFlowTests still pins the wait and the withdrawn deletion through it, which are
    /// the same code in both.
    @MainActor
    @discardableResult
    static func restore(_ document: BackupDocument, into context: ModelContext,
                        sync: SyncService? = nil,
                        deletionQueue: SyncDeletionQueue = .live) async throws -> BackupPreview {
        // Optional rather than `= .shared`: a default argument is evaluated outside the main
        // actor, where `shared` is not reachable (an error in Swift 6).
        let sync = sync ?? .shared
        await sync.waitUntilIdle()
        return try DataBackup.restore(document, into: context, withdrawingDeletionsFrom: deletionQueue)
    }

    enum EraseOutcome: Equatable {
        case erased
        /// A device with a session could not sync first, so nothing was erased.
        case syncFailed
        /// The pre-erase sync archived recovered edits the confirmation never counted (a row
        /// edited here was deleted on another device meanwhile), or the log holds more than the
        /// last Export Recovered Edits wrote. Nothing was erased and a device with a session is
        /// still signed in: the new count is on screen with its export, and Erase asks again.
        case recoveredEditsChanged
        case saveFailed
    }

    /// Erase Local Data: this device's habits, check-ins and groups, never the account's.
    ///
    /// A device with a session syncs first — waiting out one already in flight, then running
    /// its own — so edits made offline reach the account before this device forgets them; if
    /// that sync fails nothing is erased. Then it signs out, which resets the cursor, so the
    /// next sign-in does a full pull that brings everything back instead of an incremental one
    /// that never re-fetches it.
    ///
    /// "A session" is a loaded user OR a stored token. After a launch whose session check
    /// failed offline, `isLoggedIn` is false while the token and the old cursor are still
    /// stored; deciding on `isLoggedIn` alone erased without syncing or signing out, and the
    /// next launch with a network was signed in again, pulling incrementally from the old
    /// cursor into an empty store — "Signed in", no habits, and Sync Now could not repair it.
    ///
    /// Signed out, the cursor is reset anyway: it can only belong to an account that synced
    /// here before, and after an erase no incremental pull from it is right.
    ///
    /// `clearingRecoveredEdits`: the owner's recovery log goes too. Settings passes true only
    /// when it showed the lines' count and offered "Export Recovered Edits" above the Erase
    /// button (phase C: "offer the recovery-log export first"), and its confirmation said they go;
    /// a log it could not count is kept. Kept, the lines would stay on disk under the old owner's
    /// key, shown again only if that account ever owns the store — for a user who asked to erase
    /// this device, a copy of their edits nobody can see.
    ///
    /// `recoveredEditTotalShown`: what the confirmation was built from, as the log's
    /// `Summary.archivedTotal` (lines + dropped). The pre-erase sync can archive more — an edit
    /// here to a row another device deleted — and those lines were never counted, shown or offered
    /// for export; clearing them with the rest (or hiding them under the old owner's key) would
    /// lose the only copy of an edit the user never saw. So when the total moved, nothing is
    /// erased (`.recoveredEditsChanged`) and Settings asks again. Not the line count: at the log's
    /// 5 MB cap the sync's line pushes the oldest out, and the count reads the same (review
    /// recovery-backup-1).
    ///
    /// And when the lines go, they go only as far as they were exported (1.4.0, RELEASE-1.4.0.md
    /// D6): once Export Recovered Edits wrote this owner's file, a total above what it held is
    /// `.recoveredEditsChanged` too (`SyncService.hasRecoveredEditsNotExported`). The count on
    /// screen refreshes after a sync, so a confirmation "as shown" no longer proves the user has
    /// the lines: export N, a sync archives one more, the row reads N + 1, and Erase confirmed
    /// against N + 1 cleared a line that was never exported — the only copy of that edit. Checked
    /// signed out too, where no pre-erase sync runs but a sync before the tap may have archived.
    ///
    /// An erase also deletes the export files in tmp, all but the last few minutes' at once and
    /// those later (`removeExportFilesAfterErase`; `exportRoot` is tmp itself, a test's own
    /// directory in tests): they are copies of what it erased (E2E S-DEL).
    @MainActor
    static func eraseLocalData(in context: ModelContext,
                               clearingRecoveredEdits: Bool = false,
                               recoveredEditTotalShown: Int? = nil,
                               auth: AuthService? = nil,
                               sync: SyncService? = nil,
                               exportRoot: URL = FileManager.default.temporaryDirectory) async -> EraseOutcome {
        let auth = auth ?? .shared, sync = sync ?? .shared   // see `restore` for the optionals
        if auth.isLoggedIn || auth.hasStoredSession {
            guard await sync.syncAfterInFlight(context: context) else { return .syncFailed }
            if let shown = recoveredEditTotalShown {
                sync.refreshRecoveredEdits()
                guard (sync.recoveredEdits?.archivedTotal ?? 0) == shown else { return .recoveredEditsChanged }
            }
            // After the pre-erase sync, which can archive; before the sign-out, which the
            // outcome promises has not happened.
            if clearingRecoveredEdits, sync.hasRecoveredEditsNotExported() { return .recoveredEditsChanged }
            await auth.logout()
        } else if clearingRecoveredEdits, sync.hasRecoveredEditsNotExported() {
            return .recoveredEditsChanged
        }
        // Also what stops a sync that started during logout's request from writing into the
        // store or the cursor after this point (SyncService.stateGeneration).
        sync.signedOut()
        // The rows first, THEN the sync state. Cleared first, a failed save left the rows with
        // their `syncedAt` marks and no owner: the next account signed into adopted them without
        // the account screen, its first full pull deleted every delivered row as "deleted
        // elsewhere", and the never-pushed ones went up into it (phase C review, F5). Nothing
        // suspends between the two, so no sync can run in between.
        do {
            try DataBackup.eraseLocalData(in: context)
        } catch {
            return .saveFailed
        }
        // Asked again at the clear (W4 review): an Export Recovered Edits tapped while this
        // waited on the pre-erase sync or the sign-out's request may still be writing, and it
        // reads the log after this turn. Those lines are kept, as a log nobody could count is,
        // rather than cleared from under the export the user has just asked for.
        let clearing = clearingRecoveredEdits && !sync.hasRecoveredEditsNotExported()
        sync.resetSyncState(clearingRecoveryLog: clearing)
        removeExportFilesAfterErase(in: exportRoot)
        return .erased
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
}

// MARK: - The restore screen

/// What the restore confirmation offers (`DataExportService.restoreChoices`).
struct RestoreChoices: Equatable {
    enum Kind: Equatable {
        /// The signed-in account's own backup: its ids are kept. One button, "Restore".
        case sameAccount
        /// Signed in, a file from another account: new copies only — kept ids would be answered
        /// `not_owned`. `email` is the file's, when it recorded one.
        case otherAccount(email: String?)
        /// A file that names no account (every 1.3.0 backup): new copies, or "Restore as It Was"
        /// for the user who knows it is the account this device syncs with (or will).
        case noAccount(signedIn: Bool)
        /// Signed out, a file naming an account: "Restore as It Was" says this device will sign
        /// in to that account next; new copies say it will not.
        case namedAccountWhileSignedOut(email: String?)
    }

    var kind: Kind
    /// New copies, or — for `.sameAccount` — the file's ids.
    var primary: RestorePlan
    /// "Restore as It Was": the file's ids. nil when the screen must not offer them.
    var keepIDs: RestorePlan?
}

/// A restore that would leave the previous owner's queued deletions or recovered edits behind
/// (`DataExportService.restoreHandover`).
struct RestoreHandover: Equatable {
    var previousOwner: BackupAccount
    var queuedDeletions: Int
    /// nil when the log could not be read.
    var recoveredEdits: Int?
}

// MARK: - Export buttons

/// What an Export button writes (`DataExportService.write`): which file, for which account. A
/// plain value, free to build on every render — nothing is read or serialised until the tap.
/// Replaces 1.3.x's lazy `Transferable` items (`BackupJSONFile`, `HabitsCSVFile`,
/// `RecoveredEditsJSONFile`) and the `ExportFileMemo` that kept their repeated asks to one file.
enum ExportFile: Equatable, Sendable {
    /// The v2 backup naming `account`: the account screen's "Export a Backup", which names the
    /// conflict's OWNER — whose ids the rows carry — not the account just signed into
    /// (`SyncService.backupFile(for:)`).
    case backup(account: BackupAccount?)
    /// The v2 backup naming the store's owner as the tap finds it (Settings, Delete Account);
    /// nil for a store with no owner.
    case ownerBackup
    /// One row per check-in, for spreadsheets.
    case csv
    /// The recovery log of `accountID` (nil: the no-account log): the store owner's for Settings
    /// (`SyncService.recoveredEditsFile`), the conflict owner's on the account screen
    /// (`SyncService.recoveredEditsFile(for:)`).
    case recoveredEdits(accountID: String?)
}

/// One export, written (`DataExportService.write`).
struct WrittenExport: Equatable, Sendable {
    /// `tmp/StrideExport-<UUID>/<name>`.
    var url: URL
    /// Recovered edits only: `Summary.archivedTotal` of what the file holds, read under the same
    /// flock as its lines (`SyncRecoveryLog.export`). nil for a backup or a CSV.
    var recoveredEditsTotal: Int? = nil
}

// MARK: - What the user reads

extension DataBackupError {
    /// One sentence per thing the user can act on. The detail (which id, which field) is in the
    /// case itself, for logs; a person restoring a backup can do nothing with a UUID.
    @MainActor
    var userMessage: String {
        switch self {
        case .fileTooLarge, .tooManyHabits, .tooManyGroups, .tooManyRecords:
            return appLocalized("This file is too large to restore.")
        case .notABackup:
            return appLocalized("This file isn't a Stride backup.")
        case .version1Export:
            return appLocalized("This file was exported by an older version of Stride and doesn't contain everything needed to restore. Export a new backup from Stride 1.3 or later.")
        case .newerVersion:
            return appLocalized("This backup was made by a newer version of Stride. Update the app to restore it.")
        case .malformed, .duplicateID, .duplicateDay, .invalidDate:
            return appLocalized("This backup is damaged and can't be restored.")
        case .storeNotEmpty:
            return appLocalized("Restore works only when there are no habits on this device. Erase local data first, then restore.")
        }
    }
}
