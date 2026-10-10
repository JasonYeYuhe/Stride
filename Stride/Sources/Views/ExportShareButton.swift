import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os.log
#if os(iOS)
import LinkPresentation
import UIKit
#endif

/// An Export button that writes the file first and shares it after (1.4.0, RELEASE-1.4.0.md D6).
/// It replaces every export ShareLink: Settings' Export as CSV / Export as JSON, Delete Account's
/// export step, the account screen's two buttons, and "Export Recovered Edits" wherever it is
/// offered (`RecoveredEditsExportButton`).
///
/// 1.3.x's ShareLinks were handed lazy `Transferable` items, so the file was written only when the
/// share sheet asked for it — with the sheet waiting on the main thread for a provider whose
/// snapshot needed that thread. That was STRIDE-APPLE-7 (a 2 s+ hang in macOS 1.3.0) and the
/// 6–7 s before the iOS sheet appeared. Here the tap writes the file (`DataExportService.write`:
/// the snapshot on the main actor, the encode and the write off it) while the button shows a
/// spinner and cannot be tapped again — one tap, one `StrideExport-*` folder, as E2E S-DEL counts
/// them — and only then:
///
/// - **iOS:** the share sheet over the written file (`ExportSharePresenter`), from this button's
///   own view controller, anchored to the button for the iPad popover. No text item (E2E S6: a
///   ShareLink `message:` was saved beside the file as text.txt).
/// - **macOS:** a save panel (`fileMover`) that moves the written file where the user picks — the
///   menu Export's panel. The Mac share picker has no "save to a folder", which is what 1.3.1's
///   What's New told users to do with Export as JSON.
///
/// A write that fails says so under the button, in one line, and leaves no file behind.
///
/// While it writes, the screen is not frozen as 1.3.x's was, so the buttons that erase what the
/// file copies wait on it instead (`SyncService.isWritingExport`): a share is dropped when its
/// button's sheet has closed, its tab is hidden, or a confirmation is up by the time the file is
/// ready.
struct ExportShareButton<Label: View>: View {
    let file: ExportFile
    let sync: SyncService
    let label: () -> Label

    @Environment(\.modelContext) private var modelContext

    @State private var isWriting = false
    @State private var failed = false
    #if os(iOS)
    @State private var anchor = ExportShareAnchor()
    /// Whether the shell shows this button's tab (D2; true outside the shell), for the anchor: a
    /// kept-alive hidden tab is still in the window at opacity 0, so "in a window" alone let a
    /// share come up over Today, anchored to an invisible row (verification, minor).
    @Environment(\.shellTabIsActive) private var isTabShown
    #else
    /// The written file while its save panel is offered, and until the panel answers: the
    /// panel's Cancel deletes it, and while it is held no erase's sweep may (`ExportsInUse`).
    @State private var savePanelFile: URL?
    @State private var showingSavePanel = false
    /// Whether this button is still on screen when its file is ready (see `export()`). A
    /// reference, so the write's task reads the live answer, not a copy of the view's state.
    @State private var presence = ExportButtonPresence()
    #endif

    init(_ file: ExportFile, sync: SyncService, @ViewBuilder label: @escaping () -> Label) {
        self.file = file
        self.sync = sync
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                export()
            } label: {
                // The spinner beside the title, as Restore from Backup's: the title stays for
                // VoiceOver, which hears "In progress" as the value.
                HStack(spacing: 8) {
                    label()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isWriting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isWriting)
            .accessibilityValue(isWriting ? Text("In progress") : Text(verbatim: ""))
            #if os(iOS)
            .background(ExportShareAnchorView(anchor: anchor, isShown: isTabShown))
            #else
            .fileMover(isPresented: $showingSavePanel, file: savePanelFile) { result in
                // Moved: nothing is left in tmp. A failed move leaves the file to the sweeps — a
                // move to another volume copies, then deletes, and its error does not say which
                // step failed, so the file in tmp may be the only whole copy (the menu Export's
                // rule, ContentView).
                releaseSavePanelFile()
                if case .failure = result { showFailure() }
            } onCancellation: {
                // Handed to no one: deleted at once, as the menu Export's Cancel is (D3, W6
                // review). Until the fix pass this was `{}`, and every Settings → Export as JSON →
                // Cancel kept a full backup in tmp until the next launch, weeks away on a Mac
                // (verification, minor).
                if let file = savePanelFile { DataExportService.removeUnsharedExport(at: file) }
                releaseSavePanelFile()
            }
            .onAppear { presence.isOnScreen = true }
            .onDisappear { presence.isOnScreen = false }
            #endif

            if failed {
                SettingsInlineError(message: appLocalized("Couldn't create the file. Try again."))
            }
        }
    }

    private func export() {
        guard !isWriting else { return }
        failed = false
        isWriting = true
        let container = modelContext.container
        #if os(macOS)
        let presence = presence
        #endif
        Task { @MainActor in
            defer { isWriting = false }
            let written: WrittenExport
            do {
                written = try await DataExportService.write(file, container: container, sync: sync)
            } catch {
                showFailure()
                return
            }
            #if os(iOS)
            // The anchor is checked now, not at the tap: the sheet holding the button can have
            // been closed, or its tab hidden, while the file was written
            // (`ExportSharePresenter.present`). A dropped share's file is the sweeps'.
            ExportSharePresenter.present(written.url, from: anchor)
            #else
            // A button whose view went while the file was written — its sheet dismissed, the
            // Settings window closed — took its `fileMover` with it: no panel will come up, and
            // nothing else has the file. Deleted at once, as the menu Export's dropped pass is
            // (verification, minor); it used to be set on dead state and left in tmp.
            guard presence.isOnScreen else {
                DataExportService.removeUnsharedExport(at: written.url)
                Self.logger.info("Export save panel dropped: its button is no longer on screen")
                return
            }
            releaseSavePanelFile()
            DataExportService.exportsInUse.hold(written.url)
            savePanelFile = written.url
            showingSavePanel = true
            #endif
        }
    }

    #if os(macOS)
    private static var logger: Logger { Logger(subsystem: "yyh.stride.habittracker", category: "Export") }

    /// The panel answered (or a new file replaces one it never showed): the file is no longer the
    /// panel's, and the sweeps may take whatever of it is left.
    private func releaseSavePanelFile() {
        if let file = savePanelFile { DataExportService.exportsInUse.release(file) }
        savePanelFile = nil
    }
    #endif

    private func showFailure() {
        failed = true
        AccessibilityNotification.Announcement(appLocalized("Couldn't create the file. Try again.")).post()
    }
}

/// "Export Recovered Edits": the owner's recovery log as a `.json` file
/// (`SyncService.recoveredEditsFile`). Shared by the sync section, Erase Local Data (offered
/// before the erase, which hides the lines until that account owns the store again), Delete
/// Account and the restore hand-over. Writing it remembers the total it holds, which Clear and
/// Erase are bound to (`SyncService.hasRecoveredEditsNotExported`).
struct RecoveredEditsExportButton: View {
    let sync: SyncService

    var body: some View {
        ExportShareButton(sync.recoveredEditsFile, sync: sync) {
            Label("Export Recovered Edits", systemImage: "square.and.arrow.up")
        }
    }
}

#if os(macOS)

/// Whether an Export button is on screen, between its `onAppear` and `onDisappear` — read by
/// the write's task once the file is ready. A row scrolled out of a lazy list counts as gone too,
/// as on iOS, where its anchor leaves the window.
@MainActor
final class ExportButtonPresence {
    var isOnScreen = false
}

#endif

#if os(iOS)

// MARK: - iOS: the share sheet

/// The button's own UIView, for the share sheet's presenter and the iPad popover's anchor. Weak:
/// a button whose sheet was closed while its file was written lets go of its view, and the share
/// is then dropped rather than anchored to nothing.
final class ExportShareAnchor {
    weak var view: UIView?
    /// Whether the shell shows the button's tab (`\.shellTabIsActive`, true outside the shell).
    /// A kept-alive hidden tab stays in the window at opacity 0, so the view's window alone does
    /// not say the button can be seen.
    var isShown = true
}

/// An empty view behind the button that hands its UIView, and whether its tab is shown, to
/// `anchor`. `isShown` is a property, not an environment read here, so a change of tab is a
/// change of input and always reaches `updateUIView`.
struct ExportShareAnchorView: UIViewRepresentable {
    let anchor: ExportShareAnchor
    var isShown = true

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        anchor.view = view
        anchor.isShown = isShown
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
        anchor.isShown = isShown
    }
}

/// Presents the share sheet for a written export file.
@MainActor
enum ExportSharePresenter {
    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Export")

    /// The file as the share sheet's one item: an item provider that registers it with copy
    /// semantics (`fileOptions: []`, never `.openInPlace`), so every receiver loads its own copy,
    /// as 1.3.x's `SentTransferredFile` gave. A cleanup of tmp after that load cuts nothing off,
    /// which is why the erases can sweep at all (`DataExportService.removeExportFilesAfterErase`).
    /// The file exists, so the load handler answers at once: nothing waits on the main thread.
    static func itemProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        // Without the extension: the receiver adds the type's own (a `.json.json` otherwise).
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// The sheet's items: the one file provider, and the header's metadata. With none, the header
    /// — the iPad popover's and the iPhone sheet's — was a blank placeholder icon with no name
    /// (verification, iPad E2E). `.linkPresentationMetadata` is the header's preview and nothing
    /// else (`activityViewControllerLinkMetadata`'s counterpart for a configuration), and it
    /// names the file as the receiver will save it. It is answered by `metadataProvider`, which
    /// adds no activity item: the items stay the provider alone, so nothing beside the file can
    /// turn into text.txt (checked on the iOS 26.5 Simulator: the header then reads the file's
    /// name, and the targets are unchanged). Not `.title`, which filled the header the same way
    /// there: the header documents it only as the items' title, and whether an activity such as
    /// Mail takes it as a subject is not documented — the ShareLinks' Mail subject was dropped on
    /// purpose (D6, "As built (W4)"). Never `.messageBody`, a text. No URL in the metadata: it
    /// describes a file, not a link.
    static func itemsConfiguration(sharing url: URL) -> UIActivityItemsConfiguration {
        let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider(for: url)])
        let header = LPLinkMetadata()
        header.title = url.lastPathComponent
        configuration.metadataProvider = { key in
            key == .linkPresentationMetadata ? header : nil
        }
        return configuration
    }

    /// The share sheet for `url`, anchored to `anchor`: every presentation is built here, so the
    /// popover's source is never forgotten. On iPad a popover with no source cannot be presented;
    /// the iPhone presents the same controller as a sheet, and the hosted suite (an iPhone) pins
    /// the anchor on it.
    static func controller(sharing url: URL, from anchor: UIView) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItemsConfiguration: itemsConfiguration(sharing: url))
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        return controller
    }

    /// Presents the share sheet for `url` from the anchor's own view controller, if — checked
    /// here, at presentation time, after the write — the anchor's tab is shown, the anchor is
    /// still in a window and that controller presents nothing. Otherwise the share is dropped
    /// quietly: the user moved to another place, the sheet holding the button was closed
    /// meanwhile, or something else is up (design review, "export-ipad-popover-untested"). The
    /// file is left to the tmp sweeps. Returns whether it presented.
    ///
    /// The anchor's own controller, never "the topmost" one: the button lives inside sheets
    /// (Delete Account, the restore hand-over, the account screen in the login sheet), and its
    /// own controller is that sheet's; anything found by walking down from the window could be a
    /// screen the user is not looking at.
    @discardableResult
    static func present(_ url: URL, from anchor: ExportShareAnchor) -> Bool {
        // A kept-alive tab the user has left (D2): still in the window, at opacity 0. Presented,
        // the popover came up over Today or Statistics, its arrow at an invisible row
        // (verification, minor). Dropped like every other share whose button cannot be seen.
        guard anchor.isShown else {
            logger.info("Export share dropped: its button's tab is hidden")
            return false
        }
        return present(url, from: anchor.view)
    }

    /// `present(_:from:)` over the anchor's view alone: the window and controller checks.
    @discardableResult
    static func present(_ url: URL, from anchor: UIView?) -> Bool {
        guard let anchor, anchor.window != nil,
              let presenter = owningViewController(of: anchor),
              presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil else {
            logger.info("Export share dropped: its button is no longer on screen")
            return false
        }
        presenter.present(controller(sharing: url, from: anchor), animated: true)
        return true
    }

    /// The first view controller up the responder chain: the hosting controller (or a child of
    /// it) that holds the button.
    private static func owningViewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

#endif
