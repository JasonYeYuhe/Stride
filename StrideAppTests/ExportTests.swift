import XCTest
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import Stride

/// Write first, then share (1.4.0, RELEASE-1.4.0.md D6): the writers every Export button calls
/// (`DataExportService.write`), the share sheet's item and anchor (`ExportSharePresenter`), and
/// the erases' grace for fresh exports. 1.3.x's lazy items and their memo are gone; what their
/// tests pinned — one share, one file; a failed write kept nowhere — is pinned here on the
/// writers instead.
///
/// Every file goes into a scratch directory of the test's own, never the host app's tmp.
@MainActor
final class ExportTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var recovery: ScratchRecoveryLog!
    private var sync: SyncService!
    private var root: URL!
    private var hostedWindow: UIWindow?

    private var owners: SyncOwnerStore { SyncOwnerStore(defaults: local.defaults) }

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        local = ScratchDefaults("export.local")
        appGroup = ScratchDefaults("export.appGroup")
        recovery = ScratchRecoveryLog()
        sync = SyncService(api: server.makeClient(tokenStore: InMemoryTokenStore()), defaults: local.defaults,
                           deletionQueue: SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults),
                           sessions: FakeSyncSessions(nil), recoveryLog: recovery.log)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-exports-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let window = hostedWindow {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
            hostedWindow = nil
        }
        server.stop()
        local.remove()
        appGroup.remove()
        recovery.remove()
        try? FileManager.default.removeItem(at: root)
        root = nil
        sync = nil
        recovery = nil
        server = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func seedStore() throws {
        let habit = Habit(name: "Read")
        habit.records.append(HabitRecord(date: HabitCalendar.dayKey(for: Date())))
        context.insert(habit)
        context.insert(HabitGroup(name: "Morning"))
        try context.save()
    }

    /// The `StrideExport-*` directories under `root`, by name.
    private func exportDirectories() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { $0.hasPrefix(DataExportService.exportDirectoryPrefix) })
    }

    /// One export written: exactly one new directory under `root`, holding exactly that file.
    private func assertOneFile(_ written: WrittenExport, file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = written.url.deletingLastPathComponent()
        XCTAssertEqual(exportDirectories(), [directory.lastPathComponent], file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       [written.url.lastPathComponent], "one file, and no text.txt beside it", file: file, line: line)
    }

    private func appendRecoveredEdit(named name: String = "Edited offline", for account: String?) throws {
        let row = DataBackup.snapshot(habits: [Habit(name: name)], groups: []).habits[0]
        try recovery.log.append([SyncRecoveryItem(archivedAt: Date(), reason: .deletedElsewhere, row: .habit(row))],
                                accountID: account)
    }

    /// Makes an export directory look `age` old (its creation and modification dates).
    private func backdate(_ url: URL, by age: TimeInterval) throws {
        let made = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.creationDate: made, .modificationDate: made],
                                              ofItemAtPath: url.deletingLastPathComponent().path)
    }

    // MARK: - The writers: one call, one file that decodes

    /// The account screen's "Export a Backup": the v2 backup of the whole store, naming the
    /// account it was asked for — the conflict's owner there (AccountSwitchTests) — in one file.
    func testABackupIsOneFileThatDecodesAndNamesItsAccount() async throws {
        try seedStore()
        let account = BackupAccount(id: "7", email: "a@example.com")

        let written = try await DataExportService.write(.backup(account: account), container: container,
                                                        sync: sync, in: root)

        try assertOneFile(written)
        XCTAssertTrue(written.url.lastPathComponent.hasPrefix("Stride-Backup-"))
        XCTAssertEqual(written.url.pathExtension, "json")
        XCTAssertNil(written.recoveredEditsTotal)
        let document = try DataBackup.decode(try Data(contentsOf: written.url))
        XCTAssertEqual(document.habits.map(\.name), ["Read"])
        XCTAssertEqual(document.habits.first?.records.count, 1)
        XCTAssertEqual(document.groups.map(\.name), ["Morning"])
        XCTAssertEqual(document.accountId, "7")
        XCTAssertEqual(document.accountEmail, "a@example.com")
    }

    /// Settings' and Delete Account's Export as JSON name the store's owner as the tap finds it —
    /// not as a render long before it did — and no account for a store with no owner.
    func testTheOwnersBackupNamesTheOwnerAtTheTap() async throws {
        try seedStore()
        owners.set(SyncOwner(SyncSession.accountA.account))
        let owned = try await DataExportService.write(.ownerBackup, container: container, sync: sync, in: root)
        XCTAssertEqual(try DataBackup.decode(try Data(contentsOf: owned.url)).accountId, "7")

        owners.clear()
        let unowned = try await DataExportService.write(.ownerBackup, container: container, sync: sync, in: root)
        XCTAssertNil(try DataBackup.decode(try Data(contentsOf: unowned.url)).accountId)
        XCTAssertEqual(exportDirectories().count, 2, "two taps, two files")
    }

    func testACSVIsOneFileWithTheCheckIns() async throws {
        try seedStore()

        let written = try await DataExportService.write(.csv, container: container, sync: sync, in: root)

        try assertOneFile(written)
        XCTAssertTrue(written.url.lastPathComponent.hasPrefix("Stride-Export-"))
        XCTAssertEqual(written.url.pathExtension, "csv")
        let data = try Data(contentsOf: written.url)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "the BOM spreadsheets read UTF-8 by")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Read"))
    }

    /// The recovered edits of the account asked for — only theirs — with the total the file
    /// holds, which Clear and Erase are then bound to (SyncSectionTests).
    func testRecoveredEditsAreTheAccountsLogWithTheTotalItHolds() async throws {
        try appendRecoveredEdit(for: "7")
        try appendRecoveredEdit(named: "Another", for: "7")
        try appendRecoveredEdit(named: "Someone else's", for: "99")

        let written = try await DataExportService.write(.recoveredEdits(accountID: "7"), container: container,
                                                        sync: sync, in: root)

        try assertOneFile(written)
        XCTAssertTrue(written.url.lastPathComponent.hasPrefix("Stride-RecoveredEdits-"))
        let data = try Data(contentsOf: written.url)
        let export = try SyncRecoveryLog.decodeExport(data)
        XCTAssertEqual(export.accountId, "7")
        XCTAssertEqual(export.items.compactMap(\.habit?.name), ["Edited offline", "Another"])
        XCTAssertEqual(written.recoveredEditsTotal, 2)
        XCTAssertThrowsError(try DataBackup.decode(data), "picked in Restore, it is not a backup")
    }

    /// A write that fails leaves nothing behind, wherever it fails: a directory that cannot be
    /// made, or a file that cannot be written into the directory just made.
    func testAFailedWriteLeavesNothing() async throws {
        try seedStore()
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocked)
        do {
            _ = try await DataExportService.write(.ownerBackup, container: container, sync: sync, in: blocked)
            XCTFail("the write's error is the button's")
        } catch {}
        do {
            _ = try DataExportService.writeExportFile(Data("{}".utf8), named: "missing/Stride-Backup.json", in: root)
            XCTFail("no such subdirectory")
        } catch {}

        XCTAssertEqual(exportDirectories(), [], "the directory the failed write made went with it")
    }

    // MARK: - The share sheet (iOS)

    /// Every presentation is built by the one factory, and it anchors the popover to the button.
    /// The iPad needs the anchor to present at all; the iPhone has the same property, so this
    /// pins it without an iPad.
    func testTheShareSheetIsAnchoredToItsButton() throws {
        let url = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup-2026-10-10.json", in: root)
        let anchor = UIView(frame: CGRect(x: 40, y: 300, width: 160, height: 44))

        let controller = ExportSharePresenter.controller(sharing: url, from: anchor)

        let popover = try XCTUnwrap(controller.popoverPresentationController)
        XCTAssertTrue(popover.sourceView === anchor)
        XCTAssertEqual(popover.sourceRect, anchor.bounds)
    }

    /// The one item is the written file, registered with copy semantics: every receiver loads a
    /// copy of its own, so a later sweep of tmp cuts no transfer off — and nothing else, so no
    /// text.txt (E2E S6).
    func testTheShareItemIsACopyOfTheWrittenFile() throws {
        let contents = Data(#"{"schemaVersion":2}"#.utf8)
        let url = try DataExportService.writeExportFile(contents, named: "Stride-Backup-2026-10-10.json", in: root)

        let provider = ExportSharePresenter.itemProvider(for: url)

        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.json.identifier])
        XCTAssertFalse(provider.hasRepresentationConforming(toTypeIdentifier: UTType.json.identifier,
                                                            fileOptions: .openInPlace), "never opened in place")
        XCTAssertEqual(provider.suggestedName, "Stride-Backup-2026-10-10")
        let loaded = expectation(description: "loaded")
        let result = LoadedFile()
        provider.loadFileRepresentation(forTypeIdentifier: UTType.json.identifier) { copy, _ in
            result.set(path: copy?.path, data: copy.flatMap { try? Data(contentsOf: $0) })
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)
        XCTAssertEqual(result.data, contents)
        XCTAssertNotEqual(result.path, url.path, "the receiver's own copy")

        let csv = try DataExportService.writeExportFile(Data("a,b\n".utf8), named: "Stride-Export-2026-10-10.csv", in: root)
        XCTAssertEqual(ExportSharePresenter.itemProvider(for: csv).registeredTypeIdentifiers,
                       [UTType.commaSeparatedText.identifier])
    }

    /// The anchor is checked when the file is ready, not at the tap: a button whose sheet was
    /// closed while it wrote (no view, or a view out of every window), or whose controller has
    /// something else up, drops the share quietly. Otherwise the sheet comes up from the button's
    /// own controller.
    func testAShareIsPresentedOnlyFromAButtonStillOnScreen() async throws {
        let url = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup-2026-10-10.json", in: root)
        XCTAssertFalse(ExportSharePresenter.present(url, from: nil), "the button's view is gone")
        XCTAssertFalse(ExportSharePresenter.present(url, from: UIView()), "in no window")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = UIViewController()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        hostedWindow = window
        let anchor = UIView(frame: CGRect(x: 40, y: 300, width: 160, height: 44))
        screen.view.addSubview(anchor)

        let alreadyUp = UIViewController()
        screen.present(alreadyUp, animated: false)
        try await waitUntil { screen.presentedViewController === alreadyUp && !alreadyUp.isBeingPresented }
        XCTAssertFalse(ExportSharePresenter.present(url, from: anchor), "its controller presents something")
        XCTAssertTrue(screen.presentedViewController === alreadyUp, "and that is left alone")
        screen.dismiss(animated: false)
        try await waitUntil { screen.presentedViewController == nil }

        XCTAssertTrue(ExportSharePresenter.present(url, from: anchor))
        try await waitUntil { screen.presentedViewController is UIActivityViewController }
        // Its anchor is the factory's (testTheShareSheetIsAnchoredToItsButton). Not asserted here:
        // once presented on an iPhone the popover has adapted to a sheet, and the property is nil.
        let sheet = try XCTUnwrap(screen.presentedViewController as? UIActivityViewController)
        try await waitUntil { !sheet.isBeingPresented }
        screen.dismiss(animated: false)
        try await waitUntil { screen.presentedViewController == nil }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition())
    }

    // MARK: - The erases' grace (RELEASE-1.4.0.md D6, "Cleanup")

    /// An erase takes every export but those of the last ten minutes: a share of the backup just
    /// made can still be loading. The launch sweep takes everything.
    func testTheEraseSweepSparesTheLastTenMinutesExports() throws {
        let old = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)
        try backdate(old, by: DataExportService.exportGracePeriod + 60)
        let fresh = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)

        XCTAssertEqual(DataExportService.removeExportFiles(in: root, olderThan: DataExportService.exportGracePeriod), 1)
        XCTAssertEqual(exportDirectories(), [fresh.deletingLastPathComponent().lastPathComponent])

        XCTAssertEqual(DataExportService.removeExportFiles(in: root), 1, "the launch's sweep: everything")
        XCTAssertEqual(exportDirectories(), [])
    }

    /// The deferred sweep after an erase takes what the erase spared once it is past the window
    /// (here: backdated, as ten minutes later), and spares an export made after the erase.
    func testTheDeferredSweepTakesWhatTheEraseSpared() async throws {
        let spared = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)
        DataExportService.removeExportFilesAfterErase(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spared.path), "the erase spared it")

        try backdate(spared, by: DataExportService.exportGracePeriod + 5)   // ten minutes on
        let afterTheErase = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)
        let removed = await DataExportService.scheduleDeferredExportSweep(in: root, after: .zero).value

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(exportDirectories(), [afterTheErase.deletingLastPathComponent().lastPathComponent])
    }
}

/// What a load handler saw, handed back to the test's thread.
private final class LoadedFile: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?
    private var _data: Data?

    var path: String? { lock.withLock { _path } }
    var data: Data? { lock.withLock { _data } }

    func set(path: String?, data: Data?) {
        lock.withLock {
            _path = path
            _data = data
        }
    }
}
