import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The app side of backup and export: files for the share sheet, reading a picked file, and the
/// words for what went wrong. The formats, validation, restore and erase themselves are in
/// Shared/DataBackup.swift, where StrideTests can run them.
///
/// Settings used to build both exports as `String`s inline in its body
/// (`let csvString = DataExportService.exportCSV(habits: allHabits)`), so every render of the
/// Settings screen serialised the user's whole history twice, on the main thread, whether or not
/// anyone was exporting — and shared the result as text, which the Files app cannot save as a
/// `.json` a restore could pick. `BackupJSONFile` and `HabitsCSVFile` are `Transferable` values
/// that hold only the container: `ShareLink(item: BackupJSONFile(container: …))` costs nothing
/// to build, and the file is written when the user picks a destination.
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

    /// Reads the snapshot on the main actor (SwiftData models belong to the context's actor),
    /// then encodes and writes off it, so a large history does not stall the share sheet.
    fileprivate static func exportFile(from container: ModelContainer, account: BackupAccount? = nil,
                                       stem: String, ext: String,
                                       encode: @Sendable (BackupDocument) throws -> Data) async throws -> URL {
        let document = try await MainActor.run {
            try DataBackup.snapshot(of: container.mainContext, account: account)
        }
        return try writeExportFile(try encode(document),
                                   named: fileName(stem, extension: ext, date: document.exportedAt))
    }

    // MARK: - The files in tmp

    /// Every export file is written into a directory of its own in tmp, named with this prefix.
    static let exportDirectoryPrefix = "StrideExport-"

    /// Writes one export into a new `StrideExport-<UUID>` directory under `root`: two exports on
    /// the same day must not overwrite a file a share sheet may still be reading.
    static func writeExportFile(_ data: Data, named name: String,
                                in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root.appendingPathComponent(exportDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes every export directory under `root`, and returns how many went (E2E S-DEL).
    ///
    /// Nothing ever removed them: tmp kept every backup, CSV and recovered-edits file shared since
    /// the app was installed (three copies per tap, before `ExportFileMemo`), and after Delete
    /// Account the deleted account's habits and edits were still there, although the deletion
    /// erases this device's copy. Called at launch (StrideApp; no share sheet is open then), after
    /// Erase Local Data (`eraseLocalData`), and after the flows that erase the store from outside
    /// Settings' list — Delete Account, Start from This Account's Data (`AccountDataRefresh`). The
    /// exports those offered were shared before the button that erased could be tapped, and a
    /// share hands the receiver its own copy of the file. A directory that cannot be removed now is
    /// left for the next call.
    @discardableResult
    static func removeExportFiles(in root: URL = FileManager.default.temporaryDirectory) -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(exportDirectoryPrefix) {
            if (try? fileManager.removeItem(at: root.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
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
        /// edited here was deleted on another device meanwhile). Nothing was erased and the device
        /// is still signed in: the new count is on screen with its export, and Erase asks again.
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
    /// An erase also deletes the export files in tmp (`removeExportFiles`; `exportRoot` is tmp
    /// itself, a test's own directory in tests): they are copies of what it erased (E2E S-DEL).
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
            await auth.logout()
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
        sync.resetSyncState(clearingRecoveryLog: clearingRecoveredEdits)
        removeExportFiles(in: exportRoot)
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

// MARK: - Share sheet items

/// One share, one file (E2E S-DEL). The share sheet asks an item for its file several times (its
/// collaboration check among them, the device log shows), and each ask used to read the store and
/// write a copy of its own: one Export as JSON tap left three `StrideExport-*` directories,
/// written within 80 ms. Each item holds one of these (a class, so every copy of the item value
/// shares it): the first ask writes the file, and every ask made while it is being written or in
/// the `reuseWindow` after gets that same file. A later share of the same item — no redraw made a
/// new one — writes a fresh file, so no share is handed data more than a minute old. A failed
/// write is not kept: the next ask tries again.
final class ExportFileMemo: @unchecked Sendable {
    static let reuseWindow: TimeInterval = 60

    private let lock = NSLock()
    private var made: (task: Task<URL, Error>, at: Date)?

    func file(now: Date = Date(), write: @escaping @Sendable () async throws -> URL) async throws -> URL {
        let task: Task<URL, Error> = lock.withLock {
            if let made, now.timeIntervalSince(made.at) < Self.reuseWindow { return made.task }
            let task = Task { try await write() }
            made = (task, now)
            return task
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { if made?.task == task { made = nil } }
            throw error
        }
    }
}

/// The lossless v2 backup, as a `.json` file. Serialised only when the user picks a destination.
///
/// `account` is the store's sync owner, written into the file (`accountId`, `accountEmail`) so a
/// restore can tell a backup of this account from another's. It defaults to the owner recorded
/// when the item is made (`DataExportService.storeOwnerAccount`), so Settings' existing
/// `BackupJSONFile(container:)` records it with no change there; nil for a store with no owner.
struct BackupJSONFile: Transferable, Sendable {
    let container: ModelContainer
    var account: BackupAccount?
    let memo = ExportFileMemo()

    init(container: ModelContainer, account: BackupAccount? = DataExportService.storeOwnerAccount()) {
        self.container = container
        self.account = account
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try await file.memo.file {
                try await DataExportService.exportFile(
                    from: file.container, account: file.account, stem: "Stride-Backup", ext: "json",
                    encode: { try DataBackup.encode($0) })
            })
        }
    }
}

/// The recovery log's export (`SyncRecoveryExport`), as a `.json` file for Settings → Recovered
/// edits → Export as JSON (phase C) and the account screen's Export. Holds only the log and the
/// owner's id, and reads the file when the user picks a destination. Deliberately not a backup:
/// picked in Restore it is `notABackup` (its version key is `recoveryLogVersion`).
struct RecoveredEditsJSONFile: Transferable, Sendable {
    let log: SyncRecoveryLog
    let accountID: String?
    let memo = ExportFileMemo()

    /// `SyncService.recoveredEditsFile` makes one for the store's owner.
    init(log: SyncRecoveryLog, accountID: String?) {
        self.log = log
        self.accountID = accountID
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try await file.memo.file {
                try DataExportService.writeExportFile(
                    try file.log.exportData(accountID: file.accountID),
                    named: DataExportService.fileName("Stride-RecoveredEdits", extension: "json"))
            })
        }
    }
}

/// One row per check-in, as a `.csv` file for spreadsheets. Serialised only when shared.
struct HabitsCSVFile: Transferable, Sendable {
    let container: ModelContainer
    let memo = ExportFileMemo()

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            SentTransferredFile(try await file.memo.file {
                try await DataExportService.exportFile(
                    from: file.container, stem: "Stride-Export", ext: "csv", encode: { DataBackup.csvData($0) })
            })
        }
    }
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
