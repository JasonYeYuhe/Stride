import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os.log
#if os(iOS)
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
struct ExportShareButton<Label: View>: View {
    let file: ExportFile
    let sync: SyncService
    let label: () -> Label

    @Environment(\.modelContext) private var modelContext

    @State private var isWriting = false
    @State private var failed = false
    #if os(iOS)
    @State private var anchor = ExportShareAnchor()
    #else
    @State private var savePanelFile: URL?
    @State private var showingSavePanel = false
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
            .background(ExportShareAnchorView(anchor: anchor))
            #else
            .fileMover(isPresented: $showingSavePanel, file: savePanelFile) { result in
                // The file stays in tmp when the move fails; the next sweep takes it.
                if case .failure = result { showFailure() }
            } onCancellation: {}
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
            // been closed while the file was written (`ExportSharePresenter.present`).
            ExportSharePresenter.present(written.url, from: anchor.view)
            #else
            // A button whose sheet closed meanwhile is gone, and so is this state: no panel.
            savePanelFile = written.url
            showingSavePanel = true
            #endif
        }
    }

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

#if os(iOS)

// MARK: - iOS: the share sheet

/// The button's own UIView, for the share sheet's presenter and the iPad popover's anchor. Weak:
/// a button whose sheet was closed while its file was written lets go of its view, and the share
/// is then dropped rather than anchored to nothing.
final class ExportShareAnchor {
    weak var view: UIView?
}

/// An empty view behind the button that hands its UIView to `anchor`.
private struct ExportShareAnchorView: UIViewRepresentable {
    let anchor: ExportShareAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
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

    /// The share sheet for `url`, anchored to `anchor`: every presentation is built here, so the
    /// popover's source is never forgotten. On iPad a popover with no source cannot be presented;
    /// the iPhone presents the same controller as a sheet, and the hosted suite (an iPhone) pins
    /// the anchor on it.
    static func controller(sharing url: URL, from anchor: UIView) -> UIActivityViewController {
        let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider(for: url)])
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        return controller
    }

    /// Presents the share sheet for `url` from the anchor's own view controller, if — checked
    /// here, at presentation time, after the write — the anchor is still in a window and that
    /// controller presents nothing. Otherwise the share is dropped quietly: the sheet holding the
    /// button was closed meanwhile, or something else is up (design review,
    /// "export-ipad-popover-untested"). The file is left to the tmp sweeps. Returns whether it
    /// presented.
    ///
    /// The anchor's own controller, never "the topmost" one: the button lives inside sheets
    /// (Delete Account, the restore hand-over, the account screen in the login sheet), and its
    /// own controller is that sheet's; anything found by walking down from the window could be a
    /// screen the user is not looking at.
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
