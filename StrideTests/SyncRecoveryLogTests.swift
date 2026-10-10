import XCTest
import Foundation

/// The file recovery log — `Shared/SyncRecoveryLog.swift`, the code that ships (DEV-PLAN-1.3.md
/// M2, "Recovery log"). The log is where an offline edit goes when a deletion from another device
/// takes its row, so every test here reads the bytes back from disk rather than trusting what the
/// writer says it wrote: a line that is not on disk when `archive` returns is an edit the next
/// delete loses.
///
/// Not @MainActor as a class: the concurrency test must call the log from several threads at
/// once, which is the point of its lock file. The sink test is @MainActor on its own.
final class SyncRecoveryLogTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncRecoveryLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Tests chmod things read-only; give everything back before removing it.
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in walker {
                chmod(root.appendingPathComponent(path).path, 0o700)
            }
        }
        chmod(root.path, 0o700)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var directory: URL { root.appendingPathComponent("SyncRecoveryLog", isDirectory: true) }

    private func makeLog(cap: Int = SyncRecoveryLog.defaultCapBytes, directory: URL? = nil) -> SyncRecoveryLog {
        SyncRecoveryLog(directory: directory ?? self.directory, capBytes: cap)
    }

    /// Millisecond-exact, so the round trip through the file's timestamps compares equal.
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func group(_ name: String = "Morning") -> SyncRecoveryItem {
        SyncRecoveryItem(archivedAt: at(1_790_000_000.125), reason: .deletedElsewhere, row: .group(BackupGroup(
            id: UUID(), name: name, colorHex: "#FF9500", sortOrder: 2.5,
            createdAt: at(1_780_000_000), updatedAt: at(1_789_000_000.5))))
    }

    private func habit(_ name: String = "Read", records: [BackupRecord] = []) -> SyncRecoveryItem {
        SyncRecoveryItem(archivedAt: at(1_790_000_000.250), reason: .tombstoned, row: .habit(BackupHabit(
            id: UUID(), name: name, emoji: "📚", colorHex: "#34C759", createdAt: at(1_780_000_000),
            updatedAt: at(1_789_500_000.75), isArchived: false, sortOrder: 1_780_000_000,
            reminderEnabled: true, reminderHour: 21, reminderMinute: 30, note: "before bed",
            kind: "count", targetValue: 20, unit: "pages", scheduleKind: "specificDays",
            timesPerWeek: 3, activeDaysMask: 0b0101010, groupId: UUID(), records: records)))
    }

    private func record(note: String? = "felt good", value: Double = 12, habitName: String? = "Read",
                        archivedAt: Date? = nil) -> SyncRecoveryItem {
        SyncRecoveryItem(archivedAt: archivedAt ?? at(1_790_000_000.375), reason: .deletedElsewhere, row: .record(
            BackupRecord(id: UUID(), date: "2026-09-27", value: value, note: note, updatedAt: at(1_789_900_000.001)),
            habitID: UUID(), habitName: habitName))
    }

    /// A record line of a known encoded size, for the cap tests: `note` pads it.
    private func padded(_ index: Int, note length: Int = 200) -> SyncRecoveryItem {
        record(note: String(repeating: "x", count: length), value: Double(index), habitName: "h\(index)")
    }

    private func fileURL(_ accountID: String?) -> URL {
        SyncRecoveryLog.Paths(directory: directory, accountID: accountID).log
    }

    private func rawLines(_ accountID: String?) throws -> [String] {
        let text = try String(contentsOf: fileURL(accountID), encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"), "every line ends in a newline")
        return text.split(separator: "\n").map(String.init)
    }

    private func fileSize(_ accountID: String?) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: fileURL(accountID).path)[.size] as? Int) ?? -1
    }

    private func values(_ log: SyncRecoveryLog, _ accountID: String?) throws -> [Double] {
        try log.read(accountID: accountID).lines.compactMap { $0.record?.value }
    }

    // MARK: - Append, flush, read back

    func testEachRowIsOneLineOnDiskWhenAppendReturnsAndReadsBackAsItWasArchived() throws {
        let log = makeLog()
        let items = [group(), habit(), record()]
        try log.append(items, accountID: "42")

        // Read with a separate reader, not through the log: this is what is on disk.
        let lines = try rawLines("42")
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(object["archivedAt"])
            XCTAssertNotNil(object["reason"])
            XCTAssertEqual(object["accountId"] as? String, "42")
        }
        XCTAssertTrue(lines[0].contains("\"group\":{"))
        XCTAssertTrue(lines[0].contains("\"reason\":\"deleted_elsewhere\""))
        XCTAssertTrue(lines[1].contains("\"habit\":{"))
        XCTAssertTrue(lines[1].contains("\"reason\":\"tombstoned\""))
        XCTAssertTrue(lines[2].contains("\"record\":{"))
        XCTAssertTrue(lines[0].contains("\"archivedAt\":\"2026-09-21T"), "DataBackup's UTC millisecond timestamps")
        XCTAssertTrue(lines[0].contains(".125Z\""))

        let read = try log.read(accountID: "42")
        XCTAssertEqual(read.lines.compactMap(\.item), items)
        XCTAssertEqual(read.lines.map(\.accountId), ["42", "42", "42"])
        XCTAssertEqual(read.dropped, 0)
        XCTAssertEqual(read.unreadable, 0)
        XCTAssertEqual(try log.lineCount(accountID: "42"), 3)
    }

    func testARecordLineCarriesItsHabitsIdAndNameBesideTheV2Record() throws {
        let log = makeLog()
        let item = record(habitName: "Drink water")
        try log.append([item], accountID: "7")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try rawLines("7")[0].utf8)) as? [String: Any])
        guard case .record(let r, let habitID, _) = item.row else { return XCTFail() }
        XCTAssertEqual(object["habitName"] as? String, "Drink water")
        XCTAssertEqual(object["habitId"] as? String, habitID?.uuidString)
        // The record itself is exactly the backup's item, so the backup's type decodes it.
        let recordJSON = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["record"]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try XCTUnwrap(SyncTimestamp.parse($0.singleValueContainer().decode(String.self))) }
        XCTAssertEqual(try decoder.decode(BackupRecord.self, from: recordJSON), r)
    }

    func testAHabitLineHoldsNoRecords() throws {
        let log = makeLog()
        let nested = BackupRecord(id: UUID(), date: "2026-09-01", value: 1, note: nil, updatedAt: nil)
        try log.append([habit(records: [nested])], accountID: "1")

        let line = try XCTUnwrap(log.read(accountID: "1").lines.first)
        XCTAssertEqual(line.habit?.records, [])
        XCTAssertTrue(try rawLines("1")[0].contains("\"records\":[]"), "still the v2 habit shape")
    }

    @MainActor
    func testTheEngineArchivesThroughTheSinkProtocol() throws {
        let log = makeLog()
        let sink: any SyncRecoveryLogSink = log
        try sink.archive([record(), record()], accountID: "42")
        XCTAssertEqual(try log.lineCount(accountID: "42"), 2)
    }

    func testAnEmptyPassWritesNothing() throws {
        let log = makeLog()
        try log.append([], accountID: "42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try log.summary(accountID: "42"), .empty)
    }

    func testPassesAppendInOrder() throws {
        let log = makeLog()
        try log.append([padded(1), padded(2)], accountID: "42")
        try log.append([padded(3)], accountID: "42")
        XCTAssertEqual(try values(log, "42"), [1, 2, 3])
    }

    func testANonFiniteValueDoesNotBlockTheArchive() throws {
        // A log that can never be written is a deletion that can never happen: the pull would be
        // rolled back on every sync, forever.
        let log = makeLog()
        try log.append([record(value: .nan), record(value: .infinity)], accountID: "42")
        let values = try values(log, "42")
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values[0].isNaN)
        XCTAssertEqual(values[1], .infinity)
    }

    func testATornTailIsCutOffByTheNextAppend() throws {
        // A crash inside a write leaves bytes after the last newline. That pass never returned,
        // so its rows were never deleted; the fragment must not glue itself to the next line.
        let log = makeLog()
        try log.append([padded(1)], accountID: "42")
        let handle = try FileHandle(forWritingTo: fileURL("42"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"archivedAt\":\"2026-09-2".utf8))
        try handle.close()
        XCTAssertEqual(try log.read(accountID: "42").unreadable, 1)
        XCTAssertEqual(try log.lineCount(accountID: "42"), 1)

        try log.append([padded(2)], accountID: "42")
        XCTAssertEqual(try values(log, "42"), [1, 2])
        XCTAssertEqual(try log.read(accountID: "42").unreadable, 0)
        XCTAssertEqual(try rawLines("42").count, 2)
    }

    // MARK: - Cap

    func testTheCapDropsTheOldestLinesAndCountsThem() throws {
        let lineBytes = try oneLineBytes()
        let cap = lineBytes * 5 + 100 // five lines and a header fit, six do not
        let log = makeLog(cap: cap)
        for i in 1...12 { try log.append([padded(i)], accountID: "42") }

        let kept = try values(log, "42")
        XCTAssertEqual(kept.last, 12, "the newest line is never the one dropped")
        XCTAssertEqual(kept, (13 - kept.count...12).map(Double.init), "only the oldest go, in order")
        let summary = try log.summary(accountID: "42")
        XCTAssertEqual(summary.dropped + summary.lines, 12)
        XCTAssertGreaterThan(summary.dropped, 0)
        XCTAssertLessThanOrEqual(try fileSize("42"), cap)
        XCTAssertEqual(summary.bytes, try fileSize("42"))
    }

    func testTheDroppedCountAccumulatesAcrossTrims() throws {
        let lineBytes = try oneLineBytes()
        let log = makeLog(cap: lineBytes * 3 + 100)
        for i in 1...4 { try log.append([padded(i)], accountID: "42") }
        let first = try log.summary(accountID: "42").dropped
        XCTAssertGreaterThan(first, 0)
        for i in 5...10 { try log.append([padded(i)], accountID: "42") }
        let summary = try log.summary(accountID: "42")
        XCTAssertGreaterThan(summary.dropped, first)
        XCTAssertEqual(summary.dropped + summary.lines, 10)
    }

    func testAPassBiggerThanTheCapIsKeptWholeAndTheNextPassTrimsIt() throws {
        let lineBytes = try oneLineBytes()
        let cap = lineBytes * 4
        let log = makeLog(cap: cap)
        try log.append([padded(1), padded(2)], accountID: "42")

        // Ten lines: well past the cap on their own.
        try log.append((100..<110).map { padded($0) }, accountID: "42")
        XCTAssertEqual(try values(log, "42"), (100..<110).map(Double.init), "the whole pass, nothing older")
        XCTAssertGreaterThan(try fileSize("42"), cap, "the file grows past the cap for that pass")
        XCTAssertEqual(try log.summary(accountID: "42").dropped, 2)

        try log.append([padded(200)], accountID: "42")
        XCTAssertLessThanOrEqual(try fileSize("42"), cap, "the next pass trims")
        let kept = try values(log, "42")
        XCTAssertEqual(kept.last, 200)
        XCTAssertEqual(Array(kept.dropLast()), (110 - (kept.count - 1)..<110).map(Double.init),
                       "the big pass loses its oldest lines first")
        XCTAssertEqual(try log.summary(accountID: "42").dropped + kept.count, 13)
    }

    /// At the cap an append drops the oldest line as it adds its own, so `lines` reads the same
    /// before and after an edit nobody has seen — and Clear, Erase and Delete Account compared
    /// exactly that (review recovery-backup-1). `archivedTotal` (lines + dropped) moves with every
    /// archived line, and only a clear takes it back.
    func testAtTheCapTheLineCountStaysPutWhileTheArchivedTotalMoves() throws {
        let lineBytes = try oneLineBytes()
        let log = makeLog(cap: lineBytes * 5 + 100)
        for i in 1...8 { try log.append([padded(i)], accountID: "42") }
        let before = try log.summary(accountID: "42")
        XCTAssertGreaterThan(before.dropped, 0, "precondition: at the cap")
        XCTAssertEqual(before.archivedTotal, 8)

        for i in 9...11 {
            try log.append([padded(i)], accountID: "42")
            let now = try log.summary(accountID: "42")
            XCTAssertEqual(now.lines, before.lines, "the count a guard used to compare did not move")
            XCTAssertEqual(now.archivedTotal, i, "the total did")
        }

        try log.clear(accountID: "42")
        XCTAssertEqual(try log.summary(accountID: "42").archivedTotal, 0)
    }

    /// The encoded size of one `padded` line, newline included.
    private func oneLineBytes() throws -> Int {
        let probe = makeLog(directory: root.appendingPathComponent("probe"))
        try probe.append([padded(1)], accountID: "probe")
        return try probe.summary(accountID: "probe").bytes
    }

    // MARK: - Export

    func testTheExportDecodesWithItsHeader() throws {
        let log = makeLog(cap: try oneLineBytes() * 2 + 100)
        for i in 1...4 { try log.append([padded(i)], accountID: "42") }
        let exportedAt = at(1_790_100_000.5)

        let data = try log.exportData(accountID: "42", exportedAt: exportedAt)
        let document = try SyncRecoveryLog.decodeExport(data)
        XCTAssertEqual(document.recoveryLogVersion, 1)
        XCTAssertEqual(document.exportedAt, exportedAt)
        XCTAssertEqual(document.accountId, "42")
        XCTAssertEqual(document.dropped, try log.summary(accountID: "42").dropped)
        XCTAssertEqual(document.items, try log.read(accountID: "42").lines)
        XCTAssertEqual(document.items.count + document.dropped, 4)

        // Plain JSON a person (or support) can read, not JSON lines.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["items"] as? [Any])?.count, document.items.count)
        XCTAssertEqual(object["exportedAt"] as? String, "2026-09-22T18:00:00.500Z")
    }

    /// What an export holds is what Clear and Erase may take (1.4.0, RELEASE-1.4.0.md D6): the
    /// total that comes with the file is its own lines + dropped — past the cap too, where the
    /// lines alone undercount — and the same number `summary` gives for that log.
    func testAnExportCarriesTheArchivedTotalItHolds() throws {
        let log = makeLog(cap: try oneLineBytes() * 2 + 100)
        for i in 1...4 { try log.append([padded(i)], accountID: "42") }

        let export = try log.export(accountID: "42")

        let document = try SyncRecoveryLog.decodeExport(export.data)
        XCTAssertGreaterThan(document.dropped, 0, "precondition: past the cap")
        XCTAssertEqual(export.archivedTotal, document.items.count + document.dropped)
        XCTAssertEqual(export.archivedTotal, 4)
        XCTAssertEqual(export.archivedTotal, try log.summary(accountID: "42").archivedTotal)
        XCTAssertEqual(try makeLog().export(accountID: "nobody").archivedTotal, 0, "an empty log")
    }

    func testTheExportIsNotMistakenForABackup() throws {
        // Picked in Restore by mistake, it must say "not a backup" — not "a 1.2.3 export", which
        // is what a `schemaVersion: 1` key would have made DataBackup answer.
        let log = makeLog()
        try log.append([record()], accountID: "42")
        XCTAssertThrowsError(try DataBackup.decode(try log.exportData(accountID: "42"))) {
            XCTAssertEqual($0 as? DataBackupError, .notABackup)
        }
    }

    func testAnEmptyLogExportsAnEmptyDocument() throws {
        let document = try SyncRecoveryLog.decodeExport(try makeLog().exportData(accountID: "42"))
        XCTAssertEqual(document.items, [])
        XCTAssertEqual(document.dropped, 0)
    }

    // MARK: - Clear

    func testClearRemovesTheOwnersLinesAndDroppedCountOnly() throws {
        let log = makeLog(cap: try oneLineBytes() * 2 + 100)
        for i in 1...4 { try log.append([padded(i)], accountID: "42") }
        try log.append([record()], accountID: "43")
        XCTAssertGreaterThan(try log.summary(accountID: "42").dropped, 0)

        try log.clear(accountID: "42")
        XCTAssertEqual(try log.summary(accountID: "42"), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL("42").path))
        XCTAssertEqual(try log.lineCount(accountID: "43"), 1, "another owner's log is untouched")

        try log.append([padded(9)], accountID: "42")
        XCTAssertEqual(try log.summary(accountID: "42").dropped, 0, "the count starts again")
        XCTAssertEqual(try values(log, "42"), [9])
    }

    func testClearAllRemovesEveryOwnersLog() throws {
        let log = makeLog()
        try log.append([record()], accountID: "42")
        try log.append([record()], accountID: "43")
        try log.append([record()], accountID: nil)
        try log.clearAll()
        for owner in ["42", "43", nil] as [String?] {
            XCTAssertEqual(try log.lineCount(accountID: owner), 0)
        }
    }

    func testClearingALogThatWasNeverWrittenIsNotAnError() throws {
        XCTAssertNoThrow(try makeLog().clear(accountID: "42"))
        XCTAssertNoThrow(try makeLog().clearAll())
    }

    // MARK: - Per owner

    func testEachOwnerHasItsOwnFile() throws {
        let log = makeLog()
        try log.append([padded(1), padded(2)], accountID: "42")
        try log.append([padded(3)], accountID: "43")
        try log.append([padded(4)], accountID: nil)

        XCTAssertEqual(try values(log, "42"), [1, 2])
        XCTAssertEqual(try values(log, "43"), [3])
        XCTAssertEqual(try values(log, nil), [4])
        XCTAssertEqual(try log.read(accountID: "43").lines.map(\.accountId), ["43"])
        XCTAssertEqual(try log.read(accountID: nil).lines.map(\.accountId), [nil])
        XCTAssertNotEqual(fileURL("42"), fileURL("43"))
    }

    func testNoOwnerIdCanEscapeTheDirectoryOrShareAFile() throws {
        let ids = ["../escape", "a/b", "a_2fb", "a_b", "no-account", "", "é", "42"]
        let stems = ids.map { SyncRecoveryLog.Paths.stem(for: $0) } + [SyncRecoveryLog.Paths.stem(for: nil)]
        XCTAssertEqual(Set(stems).count, stems.count, "one file per owner, nil included")
        for stem in stems {
            XCTAssertFalse(stem.contains("/"))
            XCTAssertFalse(stem.contains(".."))
        }

        let log = makeLog()
        try log.append([record()], accountID: "../escape")
        XCTAssertEqual(try log.lineCount(accountID: "../escape"), 1)
        let inside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(inside.contains { $0.hasSuffix(".jsonl") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.jsonl").path))
    }

    // MARK: - Failure: an error, never a partial line

    func testADirectoryThatCannotBeCreatedIsAnErrorAndWritesNothing() throws {
        let parent = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o555), 0)
        let log = makeLog(directory: parent.appendingPathComponent("SyncRecoveryLog"))

        XCTAssertThrowsError(try log.append([record()], accountID: "42")) { error in
            guard case .directoryUnavailable = error as? SyncRecoveryLogError else {
                return XCTFail("expected directoryUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testAFileThatCannotBeOpenedIsAnErrorAndTheLogIsUnchanged() throws {
        let log = makeLog()
        try log.append([padded(1)], accountID: "42")
        let before = try Data(contentsOf: fileURL("42"))
        XCTAssertEqual(chmod(fileURL("42").path, 0o444), 0)

        XCTAssertThrowsError(try log.append([padded(2)], accountID: "42")) { error in
            XCTAssertEqual(error as? SyncRecoveryLogError, .openFailed(errno: EACCES))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL("42")), before, "no partial line")
    }

    func testATrimThatCannotWriteItsNewFileIsAnErrorAndTheLogIsUnchanged() throws {
        let log = makeLog(cap: try oneLineBytes() * 2)
        try log.append([padded(1), padded(2)], accountID: "42")
        let before = try Data(contentsOf: fileURL("42"))
        // The log itself stays writable; only a new file (the trim's) cannot be created.
        XCTAssertEqual(chmod(directory.path, 0o555), 0)

        XCTAssertThrowsError(try log.append([padded(3)], accountID: "42")) { error in
            XCTAssertEqual(error as? SyncRecoveryLogError, .openFailed(errno: EACCES))
        }
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        XCTAssertEqual(try Data(contentsOf: fileURL("42")), before, "no partial line, nothing dropped")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    @MainActor
    func testAFailedArchiveThrowsThroughTheSink() throws {
        let parent = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o555), 0)
        let sink: any SyncRecoveryLogSink = makeLog(directory: parent.appendingPathComponent("SyncRecoveryLog"))
        XCTAssertThrowsError(try sink.archive([record()], accountID: "42"))
    }

    // MARK: - Nothing for Sentry but counts

    func testWhatMayBeLoggedCarriesNoRowContent() throws {
        let log = makeLog()
        try log.append([record(note: "private note", habitName: "Secret habit"), group("Secret group")], accountID: "42")

        let summary = String(describing: try log.summary(accountID: "42"))
        XCTAssertEqual(summary, "lines=2 dropped=0 unreadable=0 bytes=\(try fileSize("42"))")

        chmod(fileURL("42").path, 0o444)
        do {
            try log.append([record(note: "another private note")], accountID: "42")
            XCTFail("expected a throw")
        } catch {
            let text = String(describing: error)
            for secret in ["private", "Secret", "42", root.path] {
                XCTAssertFalse(text.contains(secret), "\(text) leaks \(secret)")
            }
        }
    }

    // MARK: - File protection

    func testTheFileIsReadableUntilFirstUnlockClass() throws {
        #if os(iOS)
        let log = makeLog()
        try log.append([record()], accountID: "42")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL("42").path)
        guard let protection = attributes[.protectionKey] as? FileProtectionType else {
            throw XCTSkip("this runtime reports no protection class (the simulator does not)")
        }
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        #else
        throw XCTSkip("data protection classes are iOS-only")
        #endif
    }

    // MARK: - Concurrency

    /// The default cap is far above what the passes write, so every append goes in place.
    func testConcurrentAppendsFromTwoInstancesNeverInterleaveLines() throws {
        try assertNoInterleaving(cap: SyncRecoveryLog.defaultCapBytes, trims: false)
    }

    /// Sized from the passes' own ~3 KB lines (review recovery-backup-2). It was 25 of
    /// `oneLineBytes()`'s 200-character lines, about 12 KB, less than one six-line pass: every
    /// append replaced the whole file, the file ended as one pass, and the checks on interleaving
    /// and pass order had nothing to look at — the trim that keeps older lines never ran under
    /// concurrency. 27½ lines does not line up with a six-line pass: each trim keeps whole older
    /// passes beside the new one and cuts the oldest partway.
    func testConcurrentAppendsThatTrimNeverInterleaveOrLoseCount() throws {
        let line = try passLineBytes()
        try assertNoInterleaving(cap: line * 27 + line / 2, trims: true)
    }

    /// One line of `assertNoInterleaving`'s passes. ~3 KB: long enough that an unlocked writer
    /// would split it.
    private func passLine(pass: Int, index: Int) -> SyncRecoveryItem {
        record(note: String(repeating: "n", count: 3_000), value: Double(index), habitName: "pass-\(pass)")
    }

    /// The encoded size of the longest `passLine` (a two-digit pass), newline included.
    private func passLineBytes() throws -> Int {
        let probe = makeLog(directory: root.appendingPathComponent("probe-pass"))
        try probe.append([passLine(pass: 10, index: 0)], accountID: "probe")
        return try probe.summary(accountID: "probe").bytes
    }

    /// Two instances over one directory — two processes, as far as the lock is concerned, since
    /// `flock` locks belong to an open file description — each appending passes of several long
    /// lines from many threads at once. Every line must decode, a pass's lines must be contiguous
    /// and in order, and lines on disk plus lines dropped must be every line written. `trims`: the
    /// cap is one the passes outgrow, and the file must end holding what makes the contiguity and
    /// order checks able to fail — more than one pass, the oldest cut partway.
    private func assertNoInterleaving(cap: Int, trims: Bool) throws {
        let a = makeLog(cap: cap), b = makeLog(cap: cap)
        let passes = 40, perPass = 6
        let errors = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: passes) { pass in
            let items = (0..<perPass).map { passLine(pass: pass, index: $0) }
            do { try (pass.isMultiple(of: 2) ? a : b).append(items, accountID: "42") } catch {
                errors.add(error)
            }
        }
        XCTAssertEqual(errors.count, 0, "\(errors)")

        let contents = try a.read(accountID: "42")
        XCTAssertEqual(contents.unreadable, 0, "a line that does not decode is two writes interleaved")
        XCTAssertEqual(contents.lines.count + contents.dropped, passes * perPass)

        var seen: [String] = []
        var runs: [(pass: String, values: [Double])] = []
        for line in contents.lines {
            let pass = try XCTUnwrap(line.habitName)
            if runs.last?.pass == pass { runs[runs.count - 1].values.append(line.record?.value ?? -1) }
            else { runs.append((pass, [line.record?.value ?? -1])); seen.append(pass) }
        }
        if trims {
            XCTAssertGreaterThan(contents.dropped, 0)
            XCTAssertGreaterThan(runs.count, 1, "older passes are kept beside the newest")
            XCTAssertLessThan(runs.first?.values.count ?? perPass, perPass, "the oldest pass is cut partway")
        } else {
            XCTAssertEqual(contents.dropped, 0)
            XCTAssertEqual(runs.count, passes)
        }
        XCTAssertEqual(Set(seen).count, seen.count, "each pass is one contiguous run")
        for (index, run) in runs.enumerated() {
            let whole = (0..<perPass).map(Double.init)
            if index == 0 {
                XCTAssertEqual(run.values, Array(whole.suffix(run.values.count)), "only the oldest pass may be cut, from its front")
            } else {
                XCTAssertEqual(run.values, whole, "\(run.pass) is whole and in order")
            }
        }
    }
}
