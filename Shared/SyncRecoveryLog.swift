import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The recovery log (DEV-PLAN-1.3.md M2, "Recovery log"; the owner's revision 3): where a row goes
// when a deletion from another device takes it while it held an edit this device never
// delivered. Delete still wins — "skip all pending rows" would resurrect deletions on a device
// whose cursor expired — but the edit is kept here instead of only a log line, so the user (or
// support, or M6's merge-import) can put it back.
//
// One append-only JSON-lines file per OWNER (the server account id), in the app's own
// Application Support, one line per displaced row: `{archivedAt, reason, accountId, group | habit
// | record}` in DataBackup's v2 item shapes. The engine and the reconciler call it through
// `SyncRecoveryLogSink` (Shared/SyncEngine.swift); Settings (phase C) reads counts, exports and
// clears through the methods below.
//
// Why the app's Application Support and not the app-group container the store lives in: only
// the app process ever deletes a row because of sync. The widget toggles check-ins and queues
// deletions but never syncs, and M3's background sync is a BGAppRefreshTask in the app process.
// The lines hold habit names and notes; putting them where the widget process can read them buys
// nothing. If a widget ever needs the count, it is one file move, done once.
//
// Why a lock FILE and not a lock on the log: the trim replaces the log by rename, and a process
// that was waiting on a lock of the old inode would then append to a file nobody reads.
//
// Durability, the spec's "on disk before the delete" (review 2): `append` returns only after the
// bytes are written and `FileHandle.synchronize()`d; a trim writes a complete new file, syncs it
// and renames it over the old one, so a crash leaves the old file or the new one, never half of
// each. Anything that fails throws, and a throw means the caller deletes nothing (the reconciler
// rolls the pull back and writes no cursor; a push drop leaves the row pending).
//
// Privacy: the lines hold names and notes, so nothing here may reach a Sentry payload. What the
// rest of the app gets to log is `Summary` (counts) and `SyncRecoveryLogError` (errno codes).

// MARK: - The line

/// One line of the log: one displaced row.
///
/// The row is exactly DataBackup's v2 item (`BackupGroup` / `BackupHabit` / `BackupRecord`), so
/// M6's merge-import can read it with the backup decoder's types. A record line carries its
/// habit's id and name next to the record rather than inside it, so the record stays the v2
/// shape; a habit line holds the habit with `records: []` — its records have lines of their own,
/// so one line is one row.
struct SyncRecoveryLine: Codable, Equatable, Sendable {
    var archivedAt: Date
    var reason: SyncRecoveryReason
    /// The owner the run was bound to. nil only for a caller with no owner (tests).
    var accountId: String?
    var group: BackupGroup?
    var habit: BackupHabit?
    var record: BackupRecord?
    var habitId: UUID?
    var habitName: String?

    init(_ item: SyncRecoveryItem, accountID: String?) {
        archivedAt = item.archivedAt
        reason = item.reason
        accountId = accountID
        switch item.row {
        case .group(let g):
            group = g
        case .habit(var h):
            h.records = []
            habit = h
        case .record(let r, let habitID, let name):
            record = r
            habitId = habitID
            habitName = name
        }
    }

    /// The line as the engine's item again (for a browsable list later); nil for a line that
    /// holds no row, which this code never writes.
    var item: SyncRecoveryItem? {
        let row: SyncRecoveryItem.Row
        if let group { row = .group(group) }
        else if let habit { row = .habit(habit) }
        else if let record { row = .record(record, habitID: habitId, habitName: habitName) }
        else { return nil }
        return SyncRecoveryItem(archivedAt: archivedAt, reason: reason, row: row)
    }
}

/// What "Export as JSON" hands the ShareLink: the log as one JSON document.
///
/// Its version key is `recoveryLogVersion`, deliberately NOT `schemaVersion`: a user who picks
/// this file in Restore would otherwise be told it is a 1.2.3 export (`DataBackup.decode` reads
/// `schemaVersion: 1` as `version1Export`). Without the key it is `notABackup`, which is true.
struct SyncRecoveryExport: Codable, Equatable, Sendable {
    static let version = 1

    var recoveryLogVersion: Int
    var exportedAt: Date
    var accountId: String?
    /// Lines the 5 MB cap dropped since the log was last cleared — support asks for the export
    /// and needs to know it is not the whole history.
    var dropped: Int
    /// Lines on disk that could not be read. Only a torn tail can produce one (a crash inside a
    /// write whose pass never returned, so its rows were never deleted).
    var unreadable: Int
    /// Oldest first.
    var items: [SyncRecoveryLine]
}

// MARK: - Errors

/// Why the log could not be written or read. errno codes only: the reconciler turns this into
/// `recoveryLogFailed(String(describing:))`, which may reach a diagnostic report, and neither a
/// path nor a row belongs there.
///
/// EPERM / EACCES on iOS while the device has not been unlocked since boot is the file-protection
/// case (M3's locked background sync): the caller deletes nothing and the next sync retries.
enum SyncRecoveryLogError: Error, Equatable, CustomStringConvertible {
    /// Application Support (or the log's directory in it) could not be created.
    case directoryUnavailable(code: Int)
    case openFailed(errno: Int32)
    case lockFailed(errno: Int32)
    case readFailed(errno: Int32)
    /// The write or the flush failed; the file was cut back to where it was.
    case writeFailed(errno: Int32)
    /// A trim's new file could not replace the old one; the old one is as it was.
    case replaceFailed(errno: Int32)
    /// A row could not be encoded. Nothing was written.
    case encodingFailed

    var description: String {
        switch self {
        case .directoryUnavailable(let code): return "recovery_log_directory_unavailable(\(code))"
        case .openFailed(let e): return "recovery_log_open_failed(errno \(e))"
        case .lockFailed(let e): return "recovery_log_lock_failed(errno \(e))"
        case .readFailed(let e): return "recovery_log_read_failed(errno \(e))"
        case .writeFailed(let e): return "recovery_log_write_failed(errno \(e))"
        case .replaceFailed(let e): return "recovery_log_replace_failed(errno \(e))"
        case .encodingFailed: return "recovery_log_encoding_failed"
        }
    }
}

// MARK: - The file

/// The file recovery log. Thread-safe and process-safe (every operation holds a `flock` on the
/// owner's lock file), so the engine's main-actor calls and any later caller cannot interleave
/// lines or trim under each other.
final class SyncRecoveryLog: Sendable {
    /// The spec's cap. A pass that alone needs more is written whole and trimmed by the next one.
    static let defaultCapBytes = 5 * 1024 * 1024

    /// `<Application Support>/SyncRecoveryLog/`. Not created here: `append` creates it, so a
    /// failure to create it is an archive error the engine handles, not a crash at launch.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory // never on iOS/macOS; keeps the type non-optional
        return base.appendingPathComponent("SyncRecoveryLog", isDirectory: true)
    }

    let directory: URL
    let capBytes: Int

    init(directory: URL = SyncRecoveryLog.defaultDirectory, capBytes: Int = SyncRecoveryLog.defaultCapBytes) {
        self.directory = directory
        self.capBytes = capBytes
    }

    /// Counts for Settings ("Recovered edits (N)"), the owner gate ("something to lose") and a
    /// diagnostic report. Only counts — this is the one view of the log that may be logged.
    struct Summary: Equatable, Sendable, CustomStringConvertible {
        var lines: Int
        var dropped: Int
        var unreadable: Int
        var bytes: Int

        static let empty = Summary(lines: 0, dropped: 0, unreadable: 0, bytes: 0)

        var description: String { "lines=\(lines) dropped=\(dropped) unreadable=\(unreadable) bytes=\(bytes)" }
    }

    /// What is on disk for one owner, oldest line first.
    struct Contents: Equatable, Sendable {
        var lines: [SyncRecoveryLine]
        var dropped: Int
        var unreadable: Int
        var bytes: Int
    }

    // MARK: Append

    /// Appends one line per item for `accountID` and returns once they are flushed to disk.
    ///
    /// If the file would pass the cap, the oldest lines are dropped (and counted) until it fits —
    /// never a line of this pass: a pass that alone passes the cap replaces everything older and
    /// leaves the file over the cap until the next append trims it. On a throw nothing of this
    /// pass is in the file (an in-place append is cut back; a trim never replaced the file).
    func append(_ items: [SyncRecoveryItem], accountID: String?) throws {
        guard !items.isEmpty else { return }
        // Encoded before the disk is touched, so an encoding failure cannot leave half a pass.
        var pass = Data()
        for item in items {
            pass.append(try Self.encodeLine(SyncRecoveryLine(item, accountID: accountID)))
            pass.append(Self.newline)
        }

        try ensureDirectory()
        let paths = Paths(directory: directory, accountID: accountID)
        try withLock(paths, exclusive: true) {
            let fd = open(paths.log.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SyncRecoveryLogError.openFailed(errno: errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            Self.protect(paths.log)

            let existing: Data
            do { existing = try handle.readToEnd() ?? Data() } catch { throw SyncRecoveryLogError.readFailed(errno: Self.errnoOf(error)) }
            // A torn tail — bytes after the last newline — is a pass that never returned, whose
            // rows were therefore never deleted. It is cut off, not counted.
            let clean = Self.cleanLength(of: existing)

            if clean + pass.count <= capBytes {
                try appendInPlace(pass, to: handle, at: clean, tornFrom: existing.count)
            } else {
                try rewriteTrimmed(existing.prefix(clean), adding: pass, paths: paths)
            }
        }
    }

    private func appendInPlace(_ pass: Data, to handle: FileHandle, at offset: Int, tornFrom length: Int) throws {
        do {
            if length != offset { try handle.truncate(atOffset: UInt64(offset)) }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: pass)
            try handle.synchronize()
        } catch {
            // No partial line: whatever of this pass reached the file is cut away again.
            try? handle.truncate(atOffset: UInt64(offset))
            try? handle.synchronize()
            throw SyncRecoveryLogError.writeFailed(errno: Self.errnoOf(error))
        }
    }

    /// Drops the oldest lines until the file fits, writes the survivors and the pass to a new
    /// file, syncs it and renames it over the log.
    private func rewriteTrimmed(_ existing: Data, adding pass: Data, paths: Paths) throws {
        let parsed = Self.split(existing)
        var kept = parsed.lines[...]
        var dropped = parsed.dropped
        // The header's own length depends on the count; a few bytes of slack for its digits.
        let headerAllowance = Self.header(dropped: Int(Int32.max)).count
        var keptBytes = kept.reduce(0) { $0 + $1.count + 1 }
        while !kept.isEmpty, headerAllowance + keptBytes + pass.count > capBytes {
            keptBytes -= kept.removeFirst().count + 1
            dropped += 1
        }

        var body = Self.header(dropped: dropped)
        for line in kept {
            body.append(line)
            body.append(Self.newline)
        }
        body.append(pass)

        let temp = directory.appendingPathComponent(".\(paths.stem).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SyncRecoveryLogError.openFailed(errno: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            Self.protect(temp)
            try handle.write(contentsOf: body)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temp.path)
            throw SyncRecoveryLogError.writeFailed(errno: Self.errnoOf(error))
        }
        guard rename(temp.path, paths.log.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw SyncRecoveryLogError.replaceFailed(errno: code)
        }
        // The rename is durable only once the directory is.
        try syncDirectory()
    }

    // MARK: Read

    /// Counts only; safe to log. A missing file is an empty log.
    func summary(accountID: String?) throws -> Summary {
        let contents = try read(accountID: accountID)
        return Summary(lines: contents.lines.count, dropped: contents.dropped,
                       unreadable: contents.unreadable, bytes: contents.bytes)
    }

    /// "Recovered edits (N)".
    func lineCount(accountID: String?) throws -> Int {
        try summary(accountID: accountID).lines
    }

    /// The decoded lines, oldest first. Lines that do not decode are counted, not thrown on:
    /// one bad line must not hide the rest of a user's recovered edits.
    func read(accountID: String?) throws -> Contents {
        let paths = Paths(directory: directory, accountID: accountID)
        guard FileManager.default.fileExists(atPath: paths.log.path) else {
            return Contents(lines: [], dropped: 0, unreadable: 0, bytes: 0)
        }
        let data: Data = try withLock(paths, exclusive: false) {
            let fd = open(paths.log.path, O_RDONLY | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { return Data() } // cleared since the check above
                throw SyncRecoveryLogError.openFailed(errno: errno)
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            do { return try handle.readToEnd() ?? Data() } catch {
                throw SyncRecoveryLogError.readFailed(errno: Self.errnoOf(error))
            }
        }
        let clean = Self.cleanLength(of: data)
        let parsed = Self.split(data.prefix(clean))
        var lines: [SyncRecoveryLine] = []
        var unreadable = clean == data.count ? 0 : 1
        let decoder = Self.decoder()
        for raw in parsed.lines {
            if let line = try? decoder.decode(SyncRecoveryLine.self, from: raw) { lines.append(line) } else { unreadable += 1 }
        }
        return Contents(lines: lines, dropped: parsed.dropped, unreadable: unreadable, bytes: data.count)
    }

    // MARK: Export

    /// The owner's log as one pretty-printed JSON document (`SyncRecoveryExport`) for Settings →
    /// Recovered edits → Export as JSON. Name the file with
    /// `DataExportService.fileName("Stride-RecoveredEdits", extension: "json")`.
    func exportData(accountID: String?, exportedAt: Date = Date()) throws -> Data {
        let contents = try read(accountID: accountID)
        let document = SyncRecoveryExport(recoveryLogVersion: SyncRecoveryExport.version, exportedAt: exportedAt,
                                          accountId: accountID, dropped: contents.dropped,
                                          unreadable: contents.unreadable, items: contents.lines)
        let encoder = Self.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(document) } catch { throw SyncRecoveryLogError.encodingFailed }
    }

    /// Decodes what `exportData` wrote (tests, support tooling, M6's merge-import).
    static func decodeExport(_ data: Data) throws -> SyncRecoveryExport {
        try decoder().decode(SyncRecoveryExport.self, from: data)
    }

    // MARK: Clear

    /// Settings → Recovered edits → Clear, and "Start from this account's data" for the previous
    /// owner: the owner's lines and dropped count are gone. The lock file stays — removing it
    /// while another caller waits on it is the rename problem again.
    func clear(accountID: String?) throws {
        let paths = Paths(directory: directory, accountID: accountID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try withLock(paths, exclusive: true) {
            if unlink(paths.log.path) != 0, errno != ENOENT {
                throw SyncRecoveryLogError.writeFailed(errno: errno)
            }
        }
    }

    /// Every owner's log (account deletion, a full erase). Lock files stay, for the reason above.
    func clearAll() throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(Paths.logExtension) {
            let stem = String(name.dropLast(Paths.logExtension.count))
            let paths = Paths(directory: directory, stem: stem)
            try withLock(paths, exclusive: true) {
                if unlink(paths.log.path) != 0, errno != ENOENT {
                    throw SyncRecoveryLogError.writeFailed(errno: errno)
                }
            }
        }
    }

    // MARK: - Files and locks

    struct Paths {
        static let logExtension = ".jsonl"
        let stem: String
        let log: URL
        let lock: URL

        init(directory: URL, accountID: String?) {
            self.init(directory: directory, stem: Self.stem(for: accountID))
        }

        init(directory: URL, stem: String) {
            self.stem = stem
            log = directory.appendingPathComponent(stem + Self.logExtension)
            lock = directory.appendingPathComponent(stem + ".lock")
        }

        /// A file name per owner that no id can escape or collide in: letters, digits and `-`
        /// stay, every other byte (`_` included, which keeps it one-to-one) becomes `_xx`.
        /// Account ids are server integers today; nothing here relies on it.
        static func stem(for accountID: String?) -> String {
            guard let accountID else { return "no-account" }
            var out = "account-"
            for byte in accountID.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
                    out.append(Character(UnicodeScalar(byte)))
                default:
                    out += String(format: "_%02x", byte)
                }
            }
            return out
        }
    }

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SyncRecoveryLogError.directoryUnavailable(code: (error as NSError).code)
        }
        Self.protect(directory)
    }

    private func withLock<T>(_ paths: Paths, exclusive: Bool, _ body: () throws -> T) throws -> T {
        let fd = open(paths.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SyncRecoveryLogError.openFailed(errno: errno) }
        defer { close(fd) } // closing releases the lock
        Self.protect(paths.lock)
        while flock(fd, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            guard errno == EINTR else { throw SyncRecoveryLogError.lockFailed(errno: errno) }
        }
        return try body()
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SyncRecoveryLogError.replaceFailed(errno: errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw SyncRecoveryLogError.replaceFailed(errno: errno) }
    }

    /// Complete-until-first-user-authentication: M3 syncs in the background while the device is
    /// locked, which class A (`complete`) would refuse. It is already the default class for an
    /// app without a data-protection entitlement (Stride has none); setting it explicitly keeps
    /// it if one is ever added. Best effort: if setting it fails the file keeps the default, and
    /// the worst case is an append refused while locked — a throw, so nothing is deleted.
    private static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    // MARK: - Encoding

    private static let newline = Data([0x0A])

    /// The first line of a trimmed file: `{"recoveryLogHeader":1,"dropped":N}`. It is the only
    /// place the dropped count can live and be updated atomically with the trim itself (the same
    /// rename); a sidecar file could disagree with the log after a crash. A line of the log has
    /// no `recoveryLogHeader` key, and a header has no `archivedAt`, so neither reads as the other.
    private struct Header: Codable {
        var recoveryLogHeader: Int
        var dropped: Int
    }

    private static func header(dropped: Int) -> Data {
        guard dropped > 0 else { return Data() }
        return Data("{\"dropped\":\(dropped),\"recoveryLogHeader\":1}\n".utf8)
    }

    /// Lines (without their newline) and the header's dropped count, from newline-terminated data.
    private static func split(_ data: Data) -> (lines: [Data], dropped: Int) {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        var dropped = 0
        if let first = lines.first, let header = try? JSONDecoder().decode(Header.self, from: first) {
            dropped = header.dropped
            lines.removeFirst()
        }
        return (lines, dropped)
    }

    /// The length up to and including the last newline.
    private static func cleanLength(of data: Data) -> Int {
        guard let last = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: last) + 1
    }

    private static func encodeLine(_ line: SyncRecoveryLine) throws -> Data {
        let encoder = encoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] // one line: never pretty
        do { return try encoder.encode(line) } catch { throw SyncRecoveryLogError.encodingFailed }
    }

    /// DataBackup's timestamps (UTC, milliseconds). Non-finite numbers are written as strings
    /// rather than failing: a check-in whose value is NaN would otherwise throw on every attempt,
    /// and a log that can never be written is a deletion that can never happen — the sync would
    /// stop at that pull forever.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DataBackup.timestamp(date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = SyncTimestamp.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "timestamp")
            }
            return date
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }

    private static func errnoOf(_ error: Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return Int32(ns.code)
    }
}

// MARK: - The engine's sink

/// The engine and the reconciler archive through this; `archive` returns only once the lines
/// are flushed, and throws otherwise (the caller then deletes nothing and writes no cursor).
extension SyncRecoveryLog: SyncRecoveryLogSink {
    func archive(_ items: [SyncRecoveryItem], accountID: String?) throws {
        try append(items, accountID: accountID)
    }
}
