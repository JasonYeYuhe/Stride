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

    @MainActor
    static func backupJSONData(from context: ModelContext, exportedAt: Date = Date()) throws -> Data {
        try DataBackup.encode(DataBackup.snapshot(of: context, exportedAt: exportedAt))
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
    fileprivate static func exportFile(from container: ModelContainer, stem: String, ext: String,
                                       encode: @Sendable (BackupDocument) throws -> Data) async throws -> URL {
        let document = try await MainActor.run { try DataBackup.snapshot(of: container.mainContext) }
        let data = try encode(document)
        // A directory per export: two exports on the same day must not overwrite a file the
        // share sheet may still be reading.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(stem, extension: ext, date: document.exportedAt))
        try data.write(to: url, options: .atomic)
        return url
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

    /// `DataBackup.restore` once no sync is in flight, withdrawing the restored ids from the
    /// deletion queues. A full pull already awaiting its response — the first sync after a
    /// sign-in, on a slow link, easily outlasts picking a file and confirming — used to land
    /// after the restore and delete every restored habit, group and check-in the account did
    /// not hold (SyncReconciler's full-pull pass), with no message. After the wait the store is
    /// checked again: if that pull brought the account's habits down, this is `storeNotEmpty`.
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
    @MainActor
    static func eraseLocalData(in context: ModelContext,
                               auth: AuthService? = nil,
                               sync: SyncService? = nil) async -> EraseOutcome {
        let auth = auth ?? .shared, sync = sync ?? .shared   // see `restore` for the optionals
        if auth.isLoggedIn || auth.hasStoredSession {
            guard await sync.syncAfterInFlight(context: context) else { return .syncFailed }
            await auth.logout()
        }
        // Also what stops a sync that started during logout's request from writing into the
        // store or the cursor after this point (SyncService.stateGeneration).
        sync.resetSyncState()
        do {
            try DataBackup.eraseLocalData(in: context)
        } catch {
            return .saveFailed
        }
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

// MARK: - Share sheet items

/// The lossless v2 backup, as a `.json` file. Serialised only when the user picks a destination.
struct BackupJSONFile: Transferable, Sendable {
    let container: ModelContainer

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try await DataExportService.exportFile(
                from: file.container, stem: "Stride-Backup", ext: "json", encode: { try DataBackup.encode($0) }))
        }
    }
}

/// One row per check-in, as a `.csv` file for spreadsheets. Serialised only when shared.
struct HabitsCSVFile: Transferable, Sendable {
    let container: ModelContainer

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            SentTransferredFile(try await DataExportService.exportFile(
                from: file.container, stem: "Stride-Export", ext: "csv", encode: { DataBackup.csvData($0) }))
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
