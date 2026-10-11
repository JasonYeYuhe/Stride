import XCTest
import SwiftData
import SwiftUI
import UIKit
import LinkPresentation
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

    /// The verification's minor: at regular width a kept-alive Settings tab stays in the window at
    /// opacity 0 when the user moves to Today (D2), so "in a window, nothing presented" let an
    /// export that finished meanwhile put its popover over Today, its arrow at an invisible row.
    /// The anchor carries whether its tab is shown; hidden, the share is dropped like any other
    /// whose button cannot be seen, and nothing is presented.
    func testAShareFromAHiddenTabIsDropped() async throws {
        let url = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup-2026-10-10.json", in: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = UIViewController()
        window.rootViewController = screen
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        hostedWindow = window
        let view = UIView(frame: CGRect(x: 40, y: 300, width: 160, height: 44))
        screen.view.addSubview(view)
        let anchor = ExportShareAnchor()
        anchor.view = view

        anchor.isShown = false
        XCTAssertFalse(ExportSharePresenter.present(url, from: anchor), "its tab is hidden")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(screen.presentedViewController, "nothing comes up over the tab that shows")

        anchor.isShown = true
        XCTAssertTrue(ExportSharePresenter.present(url, from: anchor), "the same button, its tab shown")
        try await waitUntil { screen.presentedViewController is UIActivityViewController }
        let sheet = try XCTUnwrap(screen.presentedViewController)
        try await waitUntil { !sheet.isBeingPresented }
        screen.dismiss(animated: false)
        try await waitUntil { screen.presentedViewController == nil }
    }

    /// The real button, not a copy of its wiring: `ExportShareButton` hosted under
    /// `\.shellTabIsActive` as the shell sets it (`shellTab(isActive:)`), tapped through its
    /// accessibility action (`AccessibilityAutomation`, as ShellTests), its file written, and then
    /// whether a share comes up — shown, the sheet; hidden, none; shown again, the sheet. The first
    /// fix pass pinned a probe view that repeated the button's one line,
    /// `ExportShareAnchorView(anchor: anchor, isShown: isTabShown)`, and the anchor view's
    /// `isShown` defaulted to true: that line could lose its argument with no compile error and no
    /// failing test (verification, second fix pass). The default is gone, and this hosts the
    /// button itself; its files go to the test's own directory (`in: root`).
    ///
    /// Shown first: the first share sheet of a process can take longer to come up than the hidden
    /// step watches for one. A button wired to `isShown: true` got past a hidden FIRST step that
    /// way in the mutation check, and was caught by a later one.
    func testTheButtonOfAHiddenTabPresentsNoShare() async throws {
        let automation = try XCTUnwrap(AccessibilityAutomation.enable(), "the accessibility runtime's automation switch")
        addTeardownBlock { @MainActor in AccessibilityAutomation.restore(automation) }
        try seedStore()
        struct Host: View {
            let tab: ExportProbeTab
            let sync: SyncService
            let root: URL
            var body: some View {
                ExportShareButton(.csv, sync: sync, in: root) { Text(verbatim: "Export probe") }
                    .padding(40)
                    .environment(\.shellTabIsActive, tab.isActive)
            }
        }
        let tab = ExportProbeTab()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = UIHostingController(rootView: Host(tab: tab, sync: sync, root: root).modelContainer(container))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        hostedWindow = window

        /// Taps the button once it can be tapped (it is disabled while it writes), and waits for
        /// its file: the share is decided right after, in the same main-actor turn.
        func export(writing count: Int) async throws {
            var button: NSObject?
            try await waitUntil {
                button = self.element(labeled: "Export probe", in: window)
                return button.map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
            }
            XCTAssertEqual(button?.accessibilityActivate(), true, "the button's tap")
            try await waitUntil { self.exportDirectories().count == count }
        }

        /// The sheet the export put up, then closed again.
        func dismissTheSheet() async throws {
            try await waitUntil { screen.presentedViewController is UIActivityViewController }
            let sheet = try XCTUnwrap(screen.presentedViewController)
            try await waitUntil { !sheet.isBeingPresented }
            screen.dismiss(animated: false)
            try await waitUntil { screen.presentedViewController == nil }
        }

        try await export(writing: 1)
        try await dismissTheSheet()

        tab.isActive = false
        try await export(writing: 2)
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(screen.presentedViewController, "hidden: written, and nothing comes up over the tab that shows")

        tab.isActive = true
        try await export(writing: 3)
        try await dismissTheSheet()
    }

    /// The first accessibility element under `root` labelled `label`.
    private func element(labeled label: String, in root: NSObject) -> NSObject? {
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children {
            if let found = element(labeled: label, in: child) { return found }
        }
        return nil
    }

    /// The share sheet's header (verification, iPad E2E: a blank placeholder with no name, on the
    /// iPhone too). The configuration names the file in LinkPresentation metadata — the header's
    /// preview and nothing else — and still hands activities exactly one item, the file: no
    /// title, no message body, so no subject and nothing that could be saved as text.txt (D6).
    func testTheShareHeaderNamesTheFileAndAddsNoItem() throws {
        let url = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup-2026-10-10.json", in: root)

        let configuration = ExportSharePresenter.itemsConfiguration(sharing: url)

        // As the share sheet reads it: through the protocol, whose metadata methods are optional.
        let reading: UIActivityItemsConfigurationReading = configuration
        let providers = reading.itemProvidersForActivityItemsConfiguration
        XCTAssertEqual(providers.count, 1, "the file alone")
        XCTAssertEqual(providers.first?.registeredTypeIdentifiers, [UTType.json.identifier])
        let header = try XCTUnwrap(reading.activityItemsConfigurationMetadata?(key: .linkPresentationMetadata) as? LPLinkMetadata)
        XCTAssertEqual(header.title, "Stride-Backup-2026-10-10.json")
        XCTAssertNil(header.url, "a file, not a link")
        XCTAssertNil(header.originalURL)
        XCTAssertNil(reading.activityItemsConfigurationMetadata?(key: .title) as Any?, "no subject")
        XCTAssertNil(reading.activityItemsConfigurationMetadata?(key: .messageBody) as Any?, "no text")
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

    /// The deferred sweep the erase itself schedules (`removeExportFilesAfterErase`, which every
    /// erase calls; LocalDataFlowTests runs it through Erase Local Data) takes what the erase
    /// spared once it is past the window (here: backdated, as ten minutes later), and spares an
    /// export made after the erase. Awaited from the erase's own call, with its delay shortened:
    /// a sweep this test scheduled itself passed with the erase scheduling nothing (W4 review).
    func testTheEraseSchedulesADeferredSweepOfWhatItSpared() async throws {
        let delay = DataExportService.deferredExportSweepDelay
        DataExportService.deferredExportSweepDelay = .milliseconds(500)
        addTeardownBlock { DataExportService.deferredExportSweepDelay = delay }
        let spared = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)

        let sweep = DataExportService.removeExportFilesAfterErase(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spared.path), "the erase spared it")
        try backdate(spared, by: DataExportService.exportGracePeriod + 5)   // ten minutes on
        let afterTheErase = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)
        let removed = await sweep.value

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(exportDirectories(), [afterTheErase.deletingLastPathComponent().lastPathComponent])
    }

    // MARK: - An export handed to no one (the Mac menu Export, W6 review)

    /// The menu Export's save panel cancelled, or its pass dropped before the panel came up: the
    /// file was never handed to anything, so its directory goes at once instead of waiting weeks
    /// for a Mac's next launch (ContentView.writeRequestedExport). Only that export's directory:
    /// another export beside it stays, and a URL outside a `StrideExport-*` directory removes
    /// nothing — not the directory a stray URL happens to sit in.
    func testAnExportHandedToNoOneGoesAtOnceAndAloneAndNothingElseDoes() throws {
        let dropped = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)
        let kept = try DataExportService.writeExportFile(Data("a,b\n".utf8), named: "Stride-Export.csv", in: root)

        XCTAssertTrue(DataExportService.removeUnsharedExport(at: dropped))
        XCTAssertEqual(exportDirectories(), [kept.deletingLastPathComponent().lastPathComponent])
        XCTAssertFalse(DataExportService.removeUnsharedExport(at: dropped), "already gone")

        let notOurs = root.appendingPathComponent("Picked", isDirectory: true)
        try FileManager.default.createDirectory(at: notOurs, withIntermediateDirectories: true)
        let picked = notOurs.appendingPathComponent("Stride-Backup.json")
        try Data("{}".utf8).write(to: picked)
        XCTAssertFalse(DataExportService.removeUnsharedExport(at: picked))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path), "not an export directory: untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    // MARK: - A file under an open save panel (verification, minor)

    /// A Mac save panel holds its file from the offer to its answer (ContentView's menu Export,
    /// `ExportShareButton`), and Settings' Erase or Delete Account can run in another window
    /// meanwhile: no sweep — the erase's own, its deferred one ten minutes on, the launch's —
    /// takes a held file, whatever its age. Released, it is the sweeps' again. Held twice (never
    /// expected), it needs both releases.
    func testASweepSparesAFileASavePanelHolds() async throws {
        let held = try DataExportService.writeExportFile(Data("{}".utf8), named: "Stride-Backup.json", in: root)
        let other = try DataExportService.writeExportFile(Data("a,b\n".utf8), named: "Stride-Export.csv", in: root)
        try backdate(held, by: DataExportService.exportGracePeriod + 60)
        try backdate(other, by: DataExportService.exportGracePeriod + 60)
        let inUse = DataExportService.exportsInUse
        inUse.hold(held)
        addTeardownBlock { inUse.release(held); inUse.release(held) }

        XCTAssertEqual(DataExportService.removeExportFiles(in: root, olderThan: DataExportService.exportGracePeriod), 1,
                       "the erase's sweep takes the other old export only")
        XCTAssertEqual(exportDirectories(), [held.deletingLastPathComponent().lastPathComponent])
        let delay = DataExportService.deferredExportSweepDelay
        DataExportService.deferredExportSweepDelay = .milliseconds(100)
        addTeardownBlock { DataExportService.deferredExportSweepDelay = delay }
        let deferred = await DataExportService.scheduleDeferredExportSweep(in: root).value
        XCTAssertEqual(deferred, 0, "the deferred sweep, ten minutes on, spares it")
        XCTAssertEqual(DataExportService.removeExportFiles(in: root), 0, "so does a full sweep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path), "the panel's Save still has its file")

        inUse.hold(held)
        inUse.release(held)
        XCTAssertEqual(DataExportService.removeExportFiles(in: root), 0, "still held once")
        inUse.release(held)
        XCTAssertEqual(DataExportService.removeExportFiles(in: root), 1, "the panel answered: the sweeps' again")
        XCTAssertEqual(exportDirectories(), [])
    }

    // MARK: - A write in flight (W4 review)

    /// From the tap to the written file, an export is counted (`SyncService.isWritingExport`),
    /// which holds the buttons that erase what it copies: 1.3.x's share sheet froze the screen
    /// until the file existed, write-first does not. Written or failed, it is counted no more.
    func testAWriteIsCountedUntilItsFileIsWritten() async throws {
        try seedStore()
        XCTAssertFalse(sync.isWritingExport)

        let write = Task { @MainActor in
            try await DataExportService.write(.ownerBackup, container: self.container, sync: self.sync, in: self.root)
        }
        await yieldUntilWriting()
        XCTAssertTrue(sync.isWritingExport, "the snapshot is taken, the file is being written")
        _ = try await write.value
        XCTAssertFalse(sync.isWritingExport)

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocked)
        _ = try? await DataExportService.write(.csv, container: container, sync: sync, in: blocked)
        XCTAssertFalse(sync.isWritingExport, "a failed write is not counted either")
    }

    /// Lets a write started in a Task run to its first suspension. Its file is then written off
    /// the main actor, and it cannot finish — its last step is on the main actor — before this
    /// test suspends again.
    private func yieldUntilWriting() async {
        var tries = 0
        while !sync.isWritingExport, tries < 20 {
            await Task.yield()
            tries += 1
        }
    }
}

/// The shell's selection as `testTheButtonOfAHiddenTabPresentsNoShare` flips it (`@Observable`
/// cannot be on a type local to a function).
@Observable
private final class ExportProbeTab {
    var isActive = true
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
