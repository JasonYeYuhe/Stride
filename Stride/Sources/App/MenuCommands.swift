#if os(macOS)
import SwiftUI
import SwiftData
import AppKit

// MARK: - What a main window offers the menu bar

/// One main window's side of the menu commands (RELEASE-1.4.0.md D3): its shell, which the
/// commands act on (`ShellState.selection`, and its item-based `request`), and the habit count
/// Weekly Review's rule reads. ContentView publishes it with `.focusedSceneValue`, so the menu
/// always acts on the window in front, and reads nil — every window-scoped item disabled — with
/// Settings key or no main window open.
struct ShellCommands: Equatable {
    let shell: ShellState
    /// Unarchived habits (`MenuCommandRules.State.habitCount`).
    let habitCount: Int

    /// By the shell's identity: a redraw of the same window publishes an equal value, and the
    /// menu is rebuilt only when the window in front or its habit count changes.
    static func == (lhs: ShellCommands, rhs: ShellCommands) -> Bool {
        lhs.shell === rhs.shell && lhs.habitCount == rhs.habitCount
    }
}

private struct ShellCommandsKey: FocusedValueKey {
    typealias Value = ShellCommands
}

extension FocusedValues {
    var shellCommands: ShellCommands? {
        get { self[ShellCommandsKey.self] }
        set { self[ShellCommandsKey.self] = newValue }
    }
}

/// Publishes this window's `ShellCommands` (ContentView, macOS), with the count of unarchived
/// habits — the same query Stats' Weekly Review button is gated on.
struct ShellCommandsPublisher: ViewModifier {
    let shell: ShellState
    @Query(filter: #Predicate<Habit> { !$0.isArchived }) private var habits: [Habit]

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.shellCommands, ShellCommands(shell: shell, habitCount: habits.count))
    }
}

// MARK: - The menu bar

/// The Mac's menu commands (D3). Every enable rule is `MenuCommandRules` (Shared, pinned
/// host-less); this only draws the items and runs them.
///
/// - **File:** New Habit ⌘N in place of New Window — one main window, so the tab bar's + is gone
///   too (`NSWindow.allowsAutomaticWindowTabbing`, StrideApp.init) — then Sync Now ⌘R, Export
///   Backup… ⇧⌘E and Export as CSV….
/// - **View:** Today ⌘1, Statistics ⌘2, Weekly Review ⇧⌘R.
/// - **Window:** Stride ⌘0, always enabled: the way back to a closed main window. With Settings
///   open and the main window closed, a Dock click opens nothing — AppKit reopens only when no
///   window is visible — and File → New Window went with ⌘N (design review,
///   "mac-main-window-unrecoverable").
///
/// Titles come from `appLocalized`, so they follow the in-app language; AppKit's own items (Close,
/// Edit, the Window list) follow the system's, as in every Mac app — a known, accepted mix (D3).
/// Each item is a small View, so what it reads from the @Observable services (Sync Now's account
/// and sync state) redraws it.
struct StrideCommands: Commands {
    @FocusedValue(\.shellCommands) private var window: ShellCommands?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            WindowCommandButton(.newHabit, title: appLocalized("New Habit"), window: window,
                                shortcut: KeyboardShortcut("n")) { $0.shell.request = .newHabit }
        }
        CommandGroup(after: .newItem) {
            SyncNowCommandButton()
            Divider()
            WindowCommandButton(.exportBackup, title: appLocalized("Export Backup…"), window: window,
                                shortcut: KeyboardShortcut("e", modifiers: [.command, .shift])) {
                $0.shell.request = .export(.json)
            }
            WindowCommandButton(.exportCSV, title: appLocalized("Export as CSV…"), window: window,
                                shortcut: nil) { $0.shell.request = .export(.csv) }
        }
        // The View menu, above its toolbar items (and Enter Full Screen).
        CommandGroup(before: .toolbar) {
            WindowCommandButton(.today, title: appLocalized("Today"), window: window,
                                shortcut: KeyboardShortcut("1")) { $0.shell.selection = .today }
            WindowCommandButton(.statistics, title: appLocalized("Statistics"), window: window,
                                shortcut: KeyboardShortcut("2")) { $0.shell.selection = .stats }
            Divider()
            // ContentView presents the review for Pro and the paywall for anyone else, decided when
            // the sheet is built — whether or not Stats was ever opened in this window.
            WindowCommandButton(.weeklyReview, title: appLocalized("Weekly Review"), window: window,
                                shortcut: KeyboardShortcut("r", modifiers: [.command, .shift])) {
                $0.shell.request = .weeklyReview
            }
            Divider()
        }
        CommandGroup(before: .windowList) {
            ShowMainWindowButton()
            Divider()
        }
    }
}

/// What a press does while a sheet is up (D3).
@MainActor
enum MenuCommandPress {
    /// Whether the key window shows a sheet: has one, or is one. While a SwiftUI sheet, an alert
    /// or a save panel is up it is the SHEET that is key — it takes the typing — so
    /// `NSApp.keyWindow?.attachedSheet` alone, D3's wording, is nil exactly then; the sheet's
    /// `sheetParent` is the window under it.
    static var keyWindowShowsSheet: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return key.attachedSheet != nil || key.sheetParent != nil
    }

    /// Runs `action`, or beeps and does nothing when the key window shows a sheet and `command`
    /// does not act under one (`MenuCommandRules.actsUnderSheet`). Requests are items (D2), so a
    /// refused press leaves nothing behind that could swallow the next one.
    static func perform(_ command: MenuCommandRules.Command, _ action: () -> Void) {
        if keyWindowShowsSheet && !MenuCommandRules.actsUnderSheet(command) {
            NSSound.beep()
            return
        }
        action()
    }
}

/// A command on the focused main window: enabled by its rule, refused under a sheet.
private struct WindowCommandButton: View {
    let command: MenuCommandRules.Command
    let title: String
    let window: ShellCommands?
    let shortcut: KeyboardShortcut?
    let action: (ShellCommands) -> Void

    init(_ command: MenuCommandRules.Command, title: String, window: ShellCommands?,
         shortcut: KeyboardShortcut?, action: @escaping (ShellCommands) -> Void) {
        self.command = command
        self.title = title
        self.window = window
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(title) {
            // Again at the press: a shortcut can arrive before the menu was redrawn.
            guard let window, isEnabled else { return }
            MenuCommandPress.perform(command) { action(window) }
        }
        .keyboardShortcut(shortcut)
        .disabled(!isEnabled)
    }

    private var isEnabled: Bool {
        // The account and sync fields are Sync Now's, which no window-scoped rule reads.
        MenuCommandRules.isEnabled(command, in: MenuCommandRules.State(
            hasFocusedMainWindow: window != nil, showsAccountActions: false, isSyncing: false,
            habitCount: window?.habitCount ?? 0))
    }
}

/// File → Sync Now ⌘R: Settings' Sync Now row from the menu (D3). Not window-scoped — the row lives
/// in the Settings window, and with Settings key the two are enabled together (W1 code review).
/// It runs on the process's container, as the launch and activation syncs do, and needs no
/// window.
private struct SyncNowCommandButton: View {
    @Environment(\.openWindow) private var openWindow
    private var auth = AuthService.shared
    private var sync = SyncService.shared

    var body: some View {
        Button(appLocalized("Sync Now")) { syncNow() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!isEnabled)
    }

    /// The row's rule: an account loaded (the reauth state included, where Sync Now finds out
    /// whether the session is back), and no sync running.
    private var isEnabled: Bool {
        MenuCommandRules.syncNowEnabled(
            showsAccountActions: SettingsAccountState.current(auth: auth, sync: sync).showsAccountActions,
            isSyncing: sync.isSyncing)
    }

    private func syncNow() {
        guard isEnabled else { return }
        MenuCommandPress.perform(.syncNow) {
            // No store, no row: Settings shows the store's error screen then.
            guard let container = SharedModelContainer.opened else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                // While the account screen's choice is pending the sync is blocked and makes no
                // request; the row then opens that screen, and so does this. Its sheet hangs off
                // the main window (`AccountChoiceRouter`), so that window comes forward first —
                // or is opened, when Settings is all that is left.
                guard let conflict = await SyncSectionActions(sync: sync, context: container.mainContext).syncNow()
                else { return }
                MainWindows.bringForward(openWindow: openWindow)
                AccountChoiceRouter.shared.request = AccountChoiceRequest(conflict: conflict)
            }
        }
    }
}

/// Window → Stride ⌘0. Always enabled (`MenuCommandRules.isEnabled(.showMainWindow, …)`) and
/// never refused under a sheet.
private struct ShowMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(appLocalized("Stride")) {
            MenuCommandPress.perform(.showMainWindow) {
                MainWindows.bringForward(openWindow: openWindow)
            }
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}

// MARK: - The main windows

/// The main windows that exist, for Window → Stride and Sync Now's account screen (D3).
///
/// SwiftUI has no call that brings an existing WindowGroup window forward: `openWindow(id:)`
/// always opens another, which would be a second main window with its own launch work and its
/// own copy of every app-level sheet. So the windows are counted — raised when one's content
/// appears, lowered when it disappears, i.e. when the window closes — and held weakly to bring one
/// forward; `openWindow(id:)` runs only when none is open.
@MainActor
enum MainWindows {
    /// The main scene's id: `WindowGroup(id:)` in StrideApp, and `openWindow(id:)` here.
    static let id = "main"

    /// Main windows open now.
    fileprivate(set) static var count = 0
    /// Their NSWindows, weakly: a closed window SwiftUI lets go of drops out by itself.
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    fileprivate static func register(_ window: NSWindow) {
        windows.add(window)
    }

    /// Brings the main window forward, out of the Dock if it was minimized; opens one only when
    /// none is open. A window SwiftUI still holds after its close is neither visible nor
    /// minimized, so it is never "brought forward" invisibly.
    static func bringForward(openWindow: OpenWindowAction) {
        if count > 0, let window = windows.allObjects.first(where: { $0.isVisible || $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: id)
        }
    }
}

extension View {
    /// Marks the main scene's window content (StrideApp): counted in `MainWindows` while its
    /// window is open, and its NSWindow registered. On the window's root, not on ContentView,
    /// so a window showing the store's error screen counts too: ⌘0 then brings that window
    /// forward rather than opening a second one beside it.
    func countsAsMainWindow() -> some View {
        background(MainWindowReader())
            .onAppear { MainWindows.count += 1 }
            .onDisappear { MainWindows.count -= 1 }
    }
}

/// An empty view that hands its window to `MainWindows`. It takes no clicks and no accessibility
/// focus: it sits behind the whole window's content.
private struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowReportingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindows.register(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
