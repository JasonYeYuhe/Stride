import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Habit.sortOrder) private var allHabits: [Habit]
    @Query(sort: \HabitGroup.sortOrder) private var allGroups: [HabitGroup]

    @State private var groupToRename: HabitGroup?
    @State private var groupNameText = ""

    @State private var showingDeleteAlert = false
    @State private var habitToDelete: Habit?
    @State private var showingDeleteAccountAlert = false
    /// Delete Account's last step, after "Delete Account?" → Continue: the export offer and the
    /// final button (`DeleteAccountView`). Fixed when Continue is tapped.
    @State private var deleteAccountStep: DeleteAccountStep?
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showSaveError = false
    @State private var habitToEdit: Habit?

    // Notification states
    @State private var reminderEnabled = NotificationService.shared.isReminderEnabled
    @State private var reminderTime = NotificationService.shared.reminderTime
    @State private var morningEnabled = NotificationService.shared.isMorningMotivationEnabled
    @State private var notificationDenied = false

    // Backup, restore, erase
    @State private var showingBackupImporter = false
    /// Reading the picked file, or waiting for a sync in flight before restoring it.
    @State private var isRestoring = false
    @State private var pendingRestore: PendingRestore?
    /// The restore's hand-over step, when the chosen restore would leave the previous owner's
    /// queued deletions or recovered edits behind (`DataExportService.restoreHandover`).
    @State private var pendingHandover: PendingHandover?
    @State private var restoreError: String?
    /// Set when a restore was refused as `storeNotEmpty` although no habit or group is listed:
    /// check-ins orphaned by an old bug. Offers the erase that clears them.
    @State private var storeHasHiddenRows = false
    @State private var showingEraseConfirm = false
    /// Whether the erase confirmed on screen said the recovered edits go too: fixed when Erase
    /// is tapped, so a count that changes under the dialog cannot clear lines it did not name.
    @State private var eraseClearsRecoveredEdits = false
    /// The recovery log as that confirmation was built from it (`Summary.archivedTotal`, lines +
    /// dropped); the erase stops if its own pre-erase sync archives more
    /// (`DataExportService.eraseLocalData`).
    @State private var eraseRecoveredEditTotal = 0
    @State private var isErasing = false
    @State private var eraseError: String?

    // Store
    @State private var showingPaywall = false
    @State private var showingLogin = false
    /// "Sign in again to keep syncing" in the Account section: the row's tap and its login sheet,
    /// as Today's (E2E S9). The sheet hangs on the List: the sign-in ends the row.
    @State private var signInAgain = SignInAgainFlow()
    /// The account screen, reopened from the sync section's row after a sign-in was left
    /// without a choice (the app quit on it), or by Sync Now while that choice blocks it (E2E S5).
    /// Only on those taps: never presented on its own.
    @State private var accountChoice: SyncOwnerConflict?
    private var store = StoreService.shared
    private var auth = AuthService.shared
    private var sync = SyncService.shared
    private var languageManager = LanguageManager.shared

    private var activeHabits: [Habit] {
        allHabits.filter { !$0.isArchived }
    }

    private var archivedHabits: [Habit] {
        allHabits.filter { $0.isArchived }
    }

    private var isStoreEmpty: Bool {
        allHabits.isEmpty && allGroups.isEmpty
    }

    /// Whether erase has to sync and sign out first, and which erase text applies: a loaded user
    /// OR a stored token (see DataExportService.eraseLocalData). The check is a Keychain read,
    /// so it is not made unless the erase row is on screen.
    private var eraseSignsOut: Bool {
        auth.isLoggedIn || auth.hasStoredSession
    }

    var body: some View {
        ScrollViewReader { proxy in
            settingsContent
                #if DEBUG
                // `-scrollTo syncHeld` etc.: the Sync rows below the fold (SweepScroll).
                .task { await SweepScroll.scroll(proxy) }
                #endif
        }
    }

    private var settingsContent: some View {
        List {
                // App header
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.run")
                            .font(.title)
                            .foregroundStyle(.green)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.green.opacity(0.15))
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stride")
                                .font(.headline)
                            Text("Habit Tracker")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                // Stride Pro
                if !store.isPro {
                    Section {
                        Button {
                            showingPaywall = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "crown.fill")
                                    .font(.title2)
                                    .foregroundStyle(.yellow)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Upgrade to Pro")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("Habit groups, advanced analytics & weekly review")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)

                        // Discoverable restore path: a returning buyer whose entitlement
                        // isn't detected can recover Pro without opening the paywall.
                        Button("Restore Purchases") {
                            Task { await store.restorePurchases() }
                        }
                    }
                } else {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "crown.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stride Pro")
                                    .font(.headline)
                                Text("All features unlocked")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }

                // Account & Sync
                Section {
                    switch accountState.header {
                    case .signedIn(let email):
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: email)
                                    .font(.subheadline)
                                Text("Signed in")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    case .signInAgain(let email):
                        signInAgainRow(email: email)
                    case .signIn:
                        Button {
                            showingLogin = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sign In")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("Sync habits across your devices")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    if accountState.showsAccountActions {
                        syncNowRow

                        Button(role: .destructive) {
                            Task { await auth.logout() }
                        } label: {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }

                        Button(role: .destructive) {
                            showingDeleteAccountAlert = true
                        } label: {
                            HStack {
                                Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
                                if isDeletingAccount {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isDeletingAccount)
                        .accessibilityValue(isDeletingAccount ? Text("Processing...") : Text(verbatim: ""))
                    }
                } header: {
                    Text("Account")
                } footer: {
                    if let error = accountState.footerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            // Red text is the only thing marking this as a failure.
                            .accessibilityLabel("Sync error: \(error)")
                    }
                }

                // Held rows, recovered edits, "Sync paused", Full Resync (M2 phase C). Absent
                // when there is nothing to show.
                SyncSectionView(onChooseAccount: { accountChoice = $0 })

                // Reminders section
                Section {
                    Toggle(isOn: $reminderEnabled) {
                        Label("Daily Reminder", systemImage: "bell.fill")
                    }
                    .tint(.green)
                    .onChange(of: reminderEnabled) { _, newValue in
                        handleReminderToggle(newValue)
                    }

                    if reminderEnabled {
                        DatePicker(
                            "Reminder Time",
                            selection: $reminderTime,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: reminderTime) { _, newValue in
                            NotificationService.shared.reminderTime = newValue
                        }

                        Toggle(isOn: $morningEnabled) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Morning Motivation")
                                    Text("Daily at 8:00 AM")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "sun.max.fill")
                            }
                        }
                        .tint(.orange)
                        .onChange(of: morningEnabled) { _, newValue in
                            NotificationService.shared.isMorningMotivationEnabled = newValue
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    if notificationDenied {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text("Notifications are disabled. Go to Settings → Stride to enable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if reminderEnabled {
                        Text("You'll receive a reminder to check your habits at the time above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Active habits
                Section("Active Habits (\(activeHabits.count))") {
                    if activeHabits.isEmpty {
                        Text("No habits yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activeHabits) { habit in
                            HStack {
                                Text(habit.emoji)
                                Text(habit.name)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(habit.records.count) check-ins")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    let streak = habit.currentStreak()
                                    if streak > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "flame.fill")
                                                .scaledSystemFont(size: 9, relativeTo: .caption2)
                                            Text(habit.streakUnit == "week" ? "\(streak)w" : "\(streak)d")
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(.orange)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel(habit.streakUnit == "week"
                                            ? "\(streak) week streak"
                                            : "\(streak) day streak")
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    habitToDelete = habit
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                // The app's green tint overrides a destructive swipe action's red (E2E upgrade run),
                                // here and on the two swipe actions below.
                                .tint(.red)

                                Button {
                                    withAnimation {
                                        habit.isArchived = true
                                        habit.touch()
                                        do {
                                            try modelContext.save()
                                            // An archived habit's repeating reminder kept firing daily.
                                            NotificationService.shared.removeHabitReminder(for: habit.id)
                                        } catch {
                                            habit.isArchived = false
                                            showSaveError = true
                                        }
                                    }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    habitToEdit = habit
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                        .onMove { indices, destination in
                            reorderHabits(from: indices, to: destination)
                        }
                    }
                }

                // Groups
                if !allGroups.isEmpty {
                    Section("Groups") {
                        ForEach(allGroups) { group in
                            let memberCount = allHabits.filter { $0.groupId == group.id && !$0.isArchived }.count
                            HStack {
                                Circle().fill(group.color).frame(width: 10, height: 10)
                                Text(group.name)
                                Spacer()
                                Text("\(memberCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { beginRename(group) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(group.name), \(memberCount) habits")
                            .accessibilityAddTraits(.isButton)
                            // An assistive-technology activation does not go through onTapGesture,
                            // so the rename has to be offered as an explicit action too.
                            .accessibilityAction { beginRename(group) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteGroup(group)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }

                // Archived
                if !archivedHabits.isEmpty {
                    Section("Archived (\(archivedHabits.count))") {
                        ForEach(archivedHabits) { habit in
                            HStack {
                                Text(habit.emoji)
                                Text(habit.name)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") {
                                    withAnimation {
                                        habit.isArchived = false
                                        habit.touch()
                                        do {
                                            try modelContext.save()
                                            // Restored habit: re-add its reminder (a no-op if it has none).
                                            NotificationService.shared.scheduleHabitReminder(for: habit)
                                        } catch {
                                            habit.isArchived = true
                                            showSaveError = true
                                        }
                                    }
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .tint(.green)
                                // Every archived row has a "Restore" button; the rotor needs them apart.
                                .accessibilityLabel("Restore \(habit.name)")
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    habitToDelete = habit
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }

                // Language
                Section {
                    Picker(selection: Binding(
                        get: { languageManager.selectedLanguage },
                        set: { languageManager.selectedLanguage = $0 }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                } header: {
                    Text("Language")
                } footer: {
                    if languageManager.selectedLanguage != .system {
                        Text("Restart the app for the change to fully take effect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Export Data
                Section {
                    // Transferable files holding only the container: nothing is serialised until
                    // the user picks a destination. Two `let`s used to stand here, running the
                    // CSV and the JSON export of the whole history on every render of this
                    // screen — every sync tick, entitlement refresh and edit — on the main thread.
                    // No `message:` on a file's ShareLink: the share sheet sends it as an item of
                    // its own, and Save to Files wrote it beside the file as text.txt ("JSON export
                    // of all habits", E2E S6). The subject is only a mail subject.
                    ShareLink(
                        item: HabitsCSVFile(container: modelContext.container),
                        subject: Text("Stride Habits Export"),
                        preview: SharePreview(DataExportService.fileName("Stride-Export", extension: "csv"))
                    ) {
                        Label("Export as CSV", systemImage: "tablecells")
                    }

                    ShareLink(
                        item: BackupJSONFile(container: modelContext.container),
                        subject: Text("Stride Habits Export"),
                        preview: SharePreview(DataExportService.fileName("Stride-Backup", extension: "json"))
                    ) {
                        Label("Export as JSON", systemImage: "curlybraces")
                    }

                    // Offered only into an empty store (fresh install, or after the erase below):
                    // merging a backup into live data has to obey sync rules 1.3.1 introduces.
                    if isStoreEmpty && !storeHasHiddenRows {
                        Button {
                            restoreError = nil
                            showingBackupImporter = true
                        } label: {
                            HStack {
                                Label("Restore from Backup…", systemImage: "clock.arrow.circlepath")
                                if isRestoring {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        // Not under a sync either: its full pull would land after the restore
                        // and remove what it restored (`restore(_:plan:)` also waits it out).
                        .disabled(isRestoring || sync.isSyncing)
                    }
                } header: {
                    Text("Export Data")
                } footer: {
                    if let restoreError {
                        inlineError(restoreError)
                    } else if isStoreEmpty && !storeHasHiddenRows {
                        Text("Choose a JSON backup exported from Stride 1.3 or later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Export as JSON saves a complete backup, which can be restored on a device with no habits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Erase local data. Clears this device, never the account: no sync deletions are
                // queued (DataBackup.eraseLocalData), and a signed-in device syncs and signs out
                // first, so nothing unsynced is lost and the next sync cannot pull it all back.
                if !isStoreEmpty || storeHasHiddenRows {
                    Section {
                        // Offered first (phase C): the erase clears the recovered edits too, and
                        // they are the only copy of the edits a deletion took.
                        if recoveredEditLines > 0 {
                            RecoveredEditsShareLink(sync: sync)
                        }
                        Button(role: .destructive) {
                            eraseError = nil
                            eraseClearsRecoveredEdits = recoveredEditLines > 0
                            eraseRecoveredEditTotal = sync.recoveredEdits?.archivedTotal ?? 0
                            showingEraseConfirm = true
                        } label: {
                            HStack {
                                Label("Erase Local Data…", systemImage: "trash")
                                if isErasing {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isErasing || sync.isSyncing)
                    } footer: {
                        if let eraseError {
                            inlineError(eraseError)
                        } else if eraseSignsOut {
                            Text("Removes every habit, check-in and group from this device only, and signs you out. Your account's data on the server is not affected: sign in again to download it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Removes every habit, check-in and group from this device. Export a backup first if you want to keep them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    LabeledContent("Platform") {
                        #if os(macOS)
                        Text("macOS")
                        #else
                        Text("iOS")
                        #endif
                    }
                    LabeledContent("Data Storage", value: dataStorageValue)
                }

                Section("Legal") {
                    Link(destination: URL(string: "https://jasonyeyuhe.github.io/stride-site/terms")!) {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                    Link(destination: URL(string: "https://jasonyeyuhe.github.io/stride-site/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Delete Habit", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    habitToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let habit = habitToDelete {
                        let habitID = habit.id
                        SyncService.shared.trackDeletedHabit(habit.id.uuidString)
                        for record in habit.records {
                            SyncService.shared.trackDeletedEntry(record.id.uuidString)
                        }
                        modelContext.delete(habit)
                        do {
                            try modelContext.save()
                            // Its repeating reminder outlived it: "💪 Gym — Time to work on your
                            // habit!" every morning, with no row left to open and turn it off.
                            NotificationService.shared.removeHabitReminder(for: habitID)
                        } catch {
                            #if DEBUG
                            print("Failed to save after delete: \(error)")
                            #endif
                        }
                        habitToDelete = nil
                    }
                }
            } message: {
                Text("This will permanently delete this habit and all its records. This cannot be undone.")
            }
            .sheet(item: $habitToEdit) { habit in
                AddHabitView(editingHabit: habit)
            }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView()
            }
            .sheet(isPresented: $showingLogin) {
                LoginView()
            }
            // "Sign in again"'s sign-in, as Today presents its own (E2E S9). No sync on close: the
            // `isLoggedIn` onChange below runs it, as for Sign In.
            .sheet(isPresented: Bindable(signInAgain).showingLogin) {
                LoginView(prefilledEmail: signInAgain.loginEmail)
            }
            // In AccountChoiceSheet, as StrideApp presents it: the screen's title and its Cancel
            // live in a navigation bar, and a sheet has none of its own. Presented bare, the iOS
            // sheet had no Cancel and no title, and it cannot be swiped away — the destructive
            // Start was the only way out (phase C review, UI-1).
            .sheet(item: $accountChoice) { conflict in
                AccountChoiceSheet(request: AccountChoiceRequest(conflict: conflict)) { accountChoice = nil }
            }
            .alert("Delete Account?", isPresented: $showingDeleteAccountAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    deleteAccountStep = DeleteAccountStep.current(
                        auth: auth, sync: sync, hasLocalData: !isStoreEmpty || storeHasHiddenRows)
                }
            } message: {
                Text("This will permanently delete your account and all synced data. This action cannot be undone.")
            }
            // The second confirmation is a sheet, not an alert: since 1.3.1 deleting the account
            // that owns this store erases the store too (AuthService.deleteAccount →
            // SyncService.accountDeleted), changes that never synced included, and an alert
            // cannot hold the export that has to come first (phase C leftovers, the owner's
            // decision 3). It continues the deletion the user started; nothing new interrupts.
            .sheet(item: $deleteAccountStep) { step in
                DeleteAccountView(
                    step: step, sync: sync,
                    onDelete: {
                        guard !step.isDemo else { deleteAccountStep = nil; return }
                        Task { await confirmAccountDeletion(step) }
                    },
                    onCancel: { deleteAccountStep = nil })
            }
            .alert("Unable to Delete Account", isPresented: Binding(
                get: { deleteAccountError != nil },
                set: { if !$0 { deleteAccountError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteAccountError ?? "")
            }
            .alert("Save Failed", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to save changes. Please try again.")
            }
            .alert("Rename Group", isPresented: Binding(
                get: { groupToRename != nil },
                set: { if !$0 { groupToRename = nil } }
            )) {
                TextField("Group name", text: $groupNameText)
                Button("Save") { renameGroup() }
                Button("Cancel", role: .cancel) { groupToRename = nil }
            }
            .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    Task { await readBackup(at: url) }
                case .failure:
                    showRestoreError(appLocalized("Stride couldn't read this file."))
                }
            }
            .alert(
                "Restore from Backup?",
                isPresented: Binding(
                    get: { pendingRestore != nil },
                    set: { if !$0 { pendingRestore = nil } }
                ),
                presenting: pendingRestore
            ) { pending in
                restoreButtons(pending)
            } message: { pending in
                Text(verbatim: pending.message)
            }
            .sheet(item: $pendingHandover) { pending in
                RestoreHandoverView(
                    handover: pending.handover, sync: sync,
                    onRestore: {
                        pendingHandover = nil
                        guard !pending.isDemo else { return }
                        Task { await restore(pending.document, plan: pending.plan) }
                    },
                    onCancel: { pendingHandover = nil })
            }
            .confirmationDialog("Erase Local Data?", isPresented: $showingEraseConfirm, titleVisibility: .visible) {
                Button("Erase", role: .destructive) {
                    Task { await performErase() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                eraseConfirmMessage
            }
            .onChange(of: auth.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    Task { await sync.sync(context: modelContext) }
                }
            }
            .task {
                #if DEBUG
                SyncSectionDemo.seedIfNeeded(context: modelContext, sync: sync)
                presentDemoSheet()
                #endif
                // The recovered-edits count is read when Settings asks, not at launch
                // (SyncService.refreshRecoveredEdits); a run that archives refreshes it too.
                sync.refreshRecoveredEdits()
                await checkNotificationStatus()
                await store.refreshPurchasedProducts()
            }
    }

    // MARK: - Backup, Restore, Erase

    private struct PendingRestore {
        let document: BackupDocument
        /// What the alert offers for this file here (`DataExportService.restoreChoices`).
        let choices: RestoreChoices
        /// The file's summary, then the choice explained. Built once when the file is read, not
        /// on every render of the alert.
        let message: String
    }

    private struct PendingHandover: Identifiable {
        let id = UUID()
        let document: BackupDocument
        let plan: RestorePlan
        let handover: RestoreHandover
        /// The DEBUG screenshot scenario (`SyncSectionDemo.restoreHandover`): Restore Anyway only
        /// closes the sheet.
        var isDemo = false
    }

    private func readBackup(at url: URL) async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            // Off the main actor: a multi-year history is tens of MB of JSON to decode.
            let document = try await Task.detached(priority: .userInitiated) {
                try DataExportService.readBackup(at: url)
            }.value
            restoreError = nil
            let choices = DataExportService.restoreChoices(for: document)
            var message = backupSummary(document)
            if let explanation = restoreExplanation(choices.kind) {
                message += "\n\n" + explanation
            }
            pendingRestore = PendingRestore(document: document, choices: choices, message: message)
        } catch let error as DataBackupError {
            showRestoreError(error.userMessage)
        } catch {
            showRestoreError(appLocalized("Stride couldn't read this file."))
        }
    }

    /// "6 habits / 133 check-ins / 2 groups / Aug 2 – Sep 27, 2026", one fact per line: each
    /// count is its own plural key, and a line break needs no locale's list punctuation.
    private func backupSummary(_ document: BackupDocument) -> String {
        let preview = DataBackup.preview(of: document)
        var lines = [
            appLocalized("\(preview.habits) habits"),
            appLocalized("\(preview.checkIns) check-ins"),
        ]
        if preview.groups > 0 {
            lines.append(appLocalized("\(preview.groups) groups"))
        }
        if let first = preview.firstDay, let last = preview.lastDay {
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.locale = LanguageManager.shared.locale ?? .current
            // Day-keys are UTC midnights: in any zone west of UTC they would read as the day before.
            formatter.timeZone = TimeZone(identifier: "UTC")
            lines.append(formatter.string(from: first, to: last))
        }
        return lines.joined(separator: "\n")
    }

    /// M2 "Restore into another account" (phase C): the file's ids only for this account's own
    /// backup; another account's file comes back as new copies; a file that names no account (a
    /// 1.3.0 backup) — or, signed out, one naming an account — lets the user say whether it is
    /// the account this device syncs with ("Restore as It Was") or not (new copies).
    @ViewBuilder
    private func restoreButtons(_ pending: PendingRestore) -> some View {
        let choices = pending.choices
        switch choices.kind {
        case .sameAccount:
            Button("Restore") { confirmRestore(pending.document, plan: choices.primary) }
        case .otherAccount:
            Button("Restore as New Copies") { confirmRestore(pending.document, plan: choices.primary) }
        case .noAccount, .namedAccountWhileSignedOut:
            Button("Restore as New Copies") { confirmRestore(pending.document, plan: choices.primary) }
            if let keep = choices.keepIDs {
                Button("Restore as It Was") { confirmRestore(pending.document, plan: keep) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    /// The choice in words, under the file's summary; nil for this account's own backup, where
    /// "Restore" needs no explanation. Whole sentences per case, so each is one key.
    private func restoreExplanation(_ kind: RestoreChoices.Kind) -> String? {
        switch kind {
        case .sameAccount:
            return nil
        case .otherAccount(let email):
            guard let email else {
                return appLocalized("This backup is from another account. Its habits will be added to this account as new copies.")
            }
            return appLocalized("This backup is from another account (\(email)). Its habits will be added to this account as new copies.")
        case .noAccount(let signedIn):
            if signedIn {
                return appLocalized("This backup doesn't say which account it came from. If it's this account's own backup, restore it as it was; otherwise restore it as new copies.")
            }
            return appLocalized("This backup doesn't say which account it came from. If you'll sign in to that account on this device, restore it as it was; otherwise restore it as new copies.")
        case .namedAccountWhileSignedOut(let email):
            guard let email else {
                return appLocalized("This backup is from a Stride account. If you'll sign in to that account on this device, restore it as it was; otherwise restore it as new copies.")
            }
            return appLocalized("This backup is from \(email). If you'll sign in to that account on this device, restore it as it was; otherwise restore it as new copies.")
        }
    }

    /// The phase B rule: a restore that would leave the previous owner's queued deletions or
    /// recovered edits behind goes through the hand-over step first (export offered, a second
    /// confirmation) — never dropped silently. Anything else restores at once.
    private func confirmRestore(_ document: BackupDocument, plan: RestorePlan) {
        if let handover = DataExportService.restoreHandover(for: plan, sync: sync) {
            pendingHandover = PendingHandover(document: document, plan: plan, handover: handover)
            return
        }
        Task { await restore(document, plan: plan) }
    }

    private func restore(_ document: BackupDocument, plan: RestorePlan) async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            // Waits for a sync in flight first, then sets the store's owner to `plan.owner`; see
            // DataExportService.restore.
            try await DataExportService.restore(document, into: modelContext, plan: plan, sync: sync)
        } catch DataBackupError.storeNotEmpty {
            // No habit or group, yet not empty: check-ins orphaned by an old bug — offer the
            // erase. (A sync that finished during the wait may instead have brought the
            // account's habits down; then the erase row is showing anyway.)
            let habits = (try? modelContext.fetchCount(FetchDescriptor<Habit>())) ?? 0
            let groups = (try? modelContext.fetchCount(FetchDescriptor<HabitGroup>())) ?? 0
            storeHasHiddenRows = habits == 0 && groups == 0
            showRestoreError(DataBackupError.storeNotEmpty.userMessage)
            return
        } catch let error as DataBackupError {
            showRestoreError(error.userMessage)
            return
        } catch {
            showRestoreError(appLocalized("Unable to save changes. Please try again."))
            return
        }
        restoreError = nil
        let container = modelContext.container
        // Restored habits carry their reminder settings, but nothing scheduled them. No
        // permission prompt here: a habit whose reminder is on asks when it is next edited, and
        // the launch-time reschedule keeps these in place once permission exists.
        NotificationService.shared.rescheduleAllHabitReminders(modelContainer: container)
        NotificationService.shared.updateBadge(modelContainer: container)
        WidgetCenter.shared.reloadAllTimelines()
        // The restore row the user activated has just disappeared; say what happened.
        AccessibilityNotification.Announcement(appLocalized("Backup restored.")).post()
    }

    private func performErase() async {
        isErasing = true
        defer { isErasing = false }

        // With a session: sync first (after any sync in flight), and erase nothing if that
        // fails — the user was promised the account keeps everything; then sign out, which
        // resets the cursor so signing back in re-downloads the account. See
        // DataExportService.eraseLocalData for why "a session" includes a stored token.
        switch await DataExportService.eraseLocalData(in: modelContext,
                                                      clearingRecoveredEdits: eraseClearsRecoveredEdits,
                                                      recoveredEditTotalShown: eraseRecoveredEditTotal) {
        case .erased:
            break
        case .syncFailed:
            showEraseError(appLocalized("Couldn't sync, so nothing was erased. Check your connection and try again, or log out first to erase without syncing."))
            return
        case .recoveredEditsChanged:
            // The export row above Erase now shows the new count.
            showEraseError(appLocalized("New recovered edits arrived. Export them, then try again."))
            return
        case .saveFailed:
            showEraseError(appLocalized("Unable to save changes. Please try again."))
            return
        }
        eraseError = nil
        storeHasHiddenRows = false
        let container = modelContext.container
        // With no habits left, this prunes every per-habit reminder (and clears the badge).
        NotificationService.shared.rescheduleAllHabitReminders(modelContainer: container)
        NotificationService.shared.updateBadge(modelContainer: container)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // Footers sit several elements below the button that caused them; VoiceOver hears them now.
    private func showRestoreError(_ message: String) {
        restoreError = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func showEraseError(_ message: String) {
        eraseError = message
        AccessibilityNotification.Announcement(message).post()
    }

    private func inlineError(_ message: String) -> some View {
        SettingsInlineError(message: message)
    }

    /// The owner's recovery-log lines (0 when none, or when the log could not be read — then
    /// nothing is offered and nothing is cleared).
    private var recoveredEditLines: Int { sync.recoveredEdits?.lines ?? 0 }

    /// "Synced" only while it is true: signed in over another account's store (the account
    /// screen was left without a choice), nothing syncs until the Sync section's row is used; a
    /// session the server refused (the Account section's "Sign in again", E2E S9), nothing syncs
    /// until the sign-in.
    private var dataStorageValue: String {
        guard auth.isLoggedIn else { return appLocalized("On Device") }
        return sync.ownerConflict == nil && !sync.needsReauth ? appLocalized("Synced") : appLocalized("Not Syncing")
    }

    private var eraseConfirmMessage: Text {
        let base = eraseSignsOut
            ? Text("Stride syncs one last time, signs you out, then deletes every habit, check-in and group on this device. Your account's data on the server is not touched: sign in again to download it.")
            : Text("Every habit, check-in and group on this device will be deleted. This cannot be undone.")
        guard eraseClearsRecoveredEdits else { return base }
        return base + Text(verbatim: "\n\n")
            + Text("The recovered edits on this device are erased too. Export them first if you might need them.")
    }

    // MARK: - Notification Logic

    private func handleReminderToggle(_ enabled: Bool) {
        if enabled {
            Task {
                let granted = await NotificationService.shared.requestPermission()
                if granted {
                    NotificationService.shared.isReminderEnabled = true
                    notificationDenied = false
                    // Per-habit reminders that arrived by sync or restore, or were saved while
                    // permission was undecided, were passed over by the launch pass; schedule
                    // them now rather than at the next cold launch, which can be days away.
                    NotificationService.shared.scheduleAllHabitReminders(modelContainer: modelContext.container)
                } else {
                    let status = await NotificationService.shared.checkPermission()
                    if status == .denied {
                        notificationDenied = true
                        reminderEnabled = false
                        // Flipping the toggle back is silent to VoiceOver, and the footer that
                        // explains why is several elements further down the section.
                        AccessibilityNotification.Announcement(
                            appLocalized("Notifications are disabled. Go to Settings → Stride to enable.")
                        ).post()
                    }
                }
            }
        } else {
            NotificationService.shared.isReminderEnabled = false
        }
    }

    // MARK: - Account

    private var accountState: SettingsAccountState {
        SettingsAccountState.current(auth: auth, sync: sync)
    }

    /// Today's "Sign in again to keep syncing", as the Account section's first row (E2E S9): the
    /// same words and the same tap (`SignInAgainFlow.start`: the session check, then the login
    /// sheet, its email filled in), laid out as the Sign In row it stands in for, with the account
    /// to sign back into under it.
    private func signInAgainRow(email: String?) -> some View {
        Button {
            Task { await signInAgain.start(context: modelContext) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in again to keep syncing")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let email {
                        Text(verbatim: email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if signInAgain.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(signInAgain.isChecking)
        .accessibilityHint("Opens sign-in")
    }

    /// Sync Now, with when this device last synced beside it in Today's words (`SyncedText`),
    /// redrawn every minute: "just now" under a minute and never a time ahead — it read "in 0s"
    /// right after every sync and still "in 0s" minutes later (E2E S4, S5, S6, S9). While the
    /// account screen's choice blocks syncing, the tap opens that screen (E2E S5).
    private var syncNowRow: some View {
        TimelineView(.everyMinute) { context in
            // The start of the minute, not now: a sync after it would read as ahead of the clock.
            // The later of the two, as Today's line.
            let now = max(context.date, Date())
            let lastSync = SyncTimestamp.parse(sync.lastSyncTime)
            Button {
                Task {
                    if let conflict = await SyncSectionActions(sync: sync, context: modelContext).syncNow() {
                        accountChoice = conflict
                    }
                }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if sync.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else if let lastSync {
                        // `Color`, not the hierarchical `.secondary`, which inside a Button
                        // resolves against the tint (SyncSectionView's rows) and drew it pale green.
                        SyncedText(date: lastSync, now: now, unitsStyle: .abbreviated)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .disabled(sync.isSyncing)
            .accessibilityLabel("Sync Now")
            .accessibilityValue(syncAccessibilityValue(lastSync: lastSync, now: now))
        }
    }

    // Each branch is a whole phrase so it stays one localization key, not a %@ argument.
    private func syncAccessibilityValue(lastSync: Date?, now: Date) -> Text {
        if sync.isSyncing { return Text("Syncing") }
        guard let lastSync else { return Text(verbatim: "") }
        return SyncedText.text(lastSync, now: now)
    }

    #if DEBUG
    /// `-demo -demoScenario deleteAccount | restoreHandover`: the two sheets no launch can reach
    /// otherwise (one needs a signed-in owner, the other a restore over a previous owner's
    /// queue), with fake accounts, for scripts/a11y_sweep.sh. Their buttons only close them.
    private func presentDemoSheet() {
        switch SyncSectionDemo.current {
        case .deleteAccount:
            deleteAccountStep = DeleteAccountStep(
                email: SyncSectionDemo.demoSignedIn, erasesDevice: true, hasLocalData: true,
                recoveredEdits: SyncRecoveryLog.Summary(lines: 2, dropped: 0, unreadable: 0, bytes: 0), isDemo: true)
        case .restoreHandover:
            let owner = BackupAccount(id: "demo-owner", email: SyncSectionDemo.demoPreviousOwner)
            pendingHandover = PendingHandover(
                document: BackupDocument(schemaVersion: 2, exportedAt: Date(), groups: [], habits: []),
                plan: RestorePlan(identity: .newCopies, owner: nil),
                handover: RestoreHandover(previousOwner: owner, queuedDeletions: 1, recoveredEdits: 2),
                isDemo: true)
        default:
            break
        }
    }
    #endif

    /// Delete My Account: the count check first (`DeleteAccountStep.recheck`), with the sheet
    /// still up. A count that moved updates the sheet in place (same account, so the same sheet)
    /// to offer the new lines, and nothing is deleted — Erase's `.recoveredEditsChanged`, here.
    private func confirmAccountDeletion(_ step: DeleteAccountStep) async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        if let changed = await step.recheck(sync: sync, context: modelContext) {
            isDeletingAccount = false
            deleteAccountStep = changed
            AccessibilityNotification.Announcement(
                appLocalized("New recovered edits arrived. Export them, then try again.")).post()
            return
        }
        deleteAccountStep = nil
        await performAccountDeletion()
    }

    private func performAccountDeletion() async {
        isDeletingAccount = true
        do {
            try await auth.deleteAccount()
        } catch {
            // In the picked language: `localizedDescription` is APIError's English, and a session
            // the server already refused (the reauth state, E2E S9) read "Please log in again"
            // in English in any language.
            deleteAccountError = APIError.displayMessage(for: error)
        }
        isDeletingAccount = false
    }

    private func beginRename(_ group: HabitGroup) {
        groupToRename = group
        groupNameText = group.name
    }

    private func renameGroup() {
        guard let group = groupToRename else { return }
        let trimmed = groupNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            group.name = trimmed
            group.touch()
            do { try modelContext.save() } catch { showSaveError = true }
        }
        groupToRename = nil
    }

    private func deleteGroup(_ group: HabitGroup) {
        // Detach member habits (they become ungrouped) before removing the group.
        for habit in allHabits where habit.groupId == group.id {
            habit.groupId = nil
            habit.touch()
        }
        let id = group.id.uuidString
        modelContext.delete(group)
        do {
            try modelContext.save()
            sync.trackDeletedGroup(id)
        } catch {
            showSaveError = true
        }
    }

    private func reorderHabits(from source: IndexSet, to destination: Int) {
        var ordered = activeHabits
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, habit) in ordered.enumerated() {
            habit.sortOrder = Double(index) * 1000.0
            habit.touch()
        }
        do {
            try modelContext.save()
        } catch {
            showSaveError = true
        }
    }

    private func checkNotificationStatus() async {
        let status = await NotificationService.shared.checkPermission()
        if status == .denied && reminderEnabled {
            notificationDenied = true
        }
    }
}

// MARK: - Account

/// What Settings' Account section shows. Pure (`make`), so the hosted tests pin it after real sync
/// answers without rendering Settings.
///
/// After a server-side revoke the section said "Signed in" in green over a red "Please log in
/// again" — the sync error the 401 set — and offered only Log Out and Delete Account; once Today's
/// row had checked the session and signed the device out, "Sign In" kept the same red line (E2E
/// S9). Now it says what Today says whenever Today says it, signed in or not: "Sign in again to
/// keep syncing", with the same tap (`SignInAgainFlow`), and no red line — a 401 sets no sync
/// error (`SyncService`), and none is shown there.
struct SettingsAccountState: Equatable {
    enum Header: Equatable {
        /// The address, and "Signed in" in green.
        case signedIn(email: String)
        /// "Sign in again to keep syncing", over the account to sign back into when it is known
        /// (`SignInAgainFlow.accountEmail`).
        case signInAgain(email: String?)
        /// "Sign In".
        case signIn
    }

    var header: Header
    /// Sync Now, Log Out and Delete Account: an account is loaded — in the reauth state too,
    /// where Log Out and Delete Account still work and Sync Now finds out whether the session is
    /// back.
    var showsAccountActions: Bool
    /// The red footer (`SyncService.syncError`): only while signed in and not asked to sign in
    /// again. Signing in again is then the one thing to do, as on Today; signed out, no sync runs
    /// for an error to be about.
    var footerError: String?

    /// `needsSignInAgain` is Today's first rule (`SyncStatusLine.make`): `SyncService.needsReauth`
    /// or `AuthService.sessionExpired`.
    static func make(signedIn: Bool, email: String?, needsSignInAgain: Bool, reauthEmail: String?,
                     syncError: String?) -> SettingsAccountState {
        if needsSignInAgain {
            return SettingsAccountState(header: .signInAgain(email: reauthEmail),
                                        showsAccountActions: signedIn, footerError: nil)
        }
        guard signedIn else {
            return SettingsAccountState(header: .signIn, showsAccountActions: false, footerError: nil)
        }
        return SettingsAccountState(header: .signedIn(email: email ?? ""), showsAccountActions: true,
                                    footerError: syncError)
    }

    @MainActor
    static func current(auth: AuthService, sync: SyncService) -> SettingsAccountState {
        make(signedIn: auth.isLoggedIn, email: auth.userEmail,
             needsSignInAgain: sync.needsReauth || auth.sessionExpired,
             reauthEmail: SignInAgainFlow.accountEmail(auth: auth, sync: sync), syncError: sync.syncError)
    }
}

// MARK: - Delete Account

/// What Delete Account's last step offers (the phase C leftovers, the owner's decision 3). Pure,
/// so the hosted tests pin it without rendering the sheet.
///
/// Deleting the account that owns this store erases the store too (`SyncOwnership.accountDeleted`),
/// its recovered edits included, and those may hold changes that never reached the server: the
/// step offers the JSON backup and the recovered edits before the final button, as Erase Local
/// Data offers them above its own. A store another account owns is left alone, so nothing is
/// offered then — only the confirmation.
struct DeleteAccountStep: Identifiable, Equatable {
    var id: String { email }
    /// The signed-in account, the one being deleted.
    let email: String
    /// The signed-in account owns this store: the deletion erases it.
    let erasesDevice: Bool
    /// "Export as JSON": the device is erased and has something to keep.
    let offersBackup: Bool
    /// "Export Recovered Edits": the device is erased and the owner's log has lines — or could
    /// not be counted (nil), since then no one can say it is empty (RestoreHandoverView's rule).
    let offersRecoveredEdits: Bool
    /// The owner's line count the step was built from (nil: it could not be counted).
    let recoveredEditLines: Int?
    /// Lines + dropped at the same read (`SyncRecoveryLog.Summary.archivedTotal`): what `recheck`
    /// compares, since at the log's cap the line count alone can stay put.
    let recoveredEditTotal: Int?
    /// Rebuilt by `recheck`: lines arrived after Continue, so the sheet says so over the export.
    var recoveredEditsChanged = false
    /// The DEBUG screenshot scenario (`SyncSectionDemo.deleteAccount`): the final button only
    /// closes the sheet.
    var isDemo = false

    /// `recoveredEdits`: the owner's recovery log as counted now (`SyncService.recoveredEdits`);
    /// nil when it could not be read.
    init(email: String, erasesDevice: Bool, hasLocalData: Bool, recoveredEdits: SyncRecoveryLog.Summary?,
         isDemo: Bool = false) {
        self.email = email
        self.erasesDevice = erasesDevice
        offersBackup = erasesDevice && hasLocalData
        offersRecoveredEdits = erasesDevice && recoveredEdits?.lines != 0
        recoveredEditLines = recoveredEdits?.lines
        recoveredEditTotal = recoveredEdits?.archivedTotal
        self.isDemo = isDemo
    }

    /// The F4 rule at the final button. `accountDeleted` clears the owner's recovery log without
    /// asking, so what this step offered must still be what is on disk: a sync since Continue —
    /// the foreground sync after the user saved the JSON in Files, or one already running — can
    /// archive a line nobody counted or offered. Then this returns the step rebuilt with the new
    /// count and the account must not be deleted yet; nil means go ahead. It compares lines +
    /// dropped (`recoveredEditTotal`), not the count: at the log's 5 MB cap the new line pushes
    /// the oldest out, and the count reads the same (review recovery-backup-1). It waits out a
    /// sync in flight first. A log that now reads 0 lines has nothing to lose, and a store another
    /// account owns loses none of its lines, so neither stops the deletion. (A sync that starts
    /// after this check and finishes inside the deletion request is not covered; one still
    /// running when the request returns is stopped by the sign-out, `SyncService.signedOut`.)
    ///
    /// The rebuilt step reads the store again (`context`), not Continue's answer: the sync that
    /// archived the line can have emptied it — the habit it removed was the last one — and the
    /// updated sheet offered Export as JSON for an empty store (E2E S-DEL).
    @MainActor
    func recheck(sync: SyncService, context: ModelContext) async -> DeleteAccountStep? {
        guard erasesDevice else { return nil }
        await sync.waitUntilIdle()
        sync.refreshRecoveredEdits()
        let now = sync.recoveredEdits
        guard now?.archivedTotal != recoveredEditTotal, now?.lines != 0 else { return nil }
        var step = DeleteAccountStep(email: email, erasesDevice: true,
                                     hasLocalData: Self.hasLocalData(in: context), recoveredEdits: now)
        step.recoveredEditsChanged = true
        return step
    }

    /// Whether Export as JSON has anything to keep: a habit or a group (a check-in is exported
    /// under its habit). A count that cannot be read counts as something.
    @MainActor
    static func hasLocalData(in context: ModelContext) -> Bool {
        func holds<Model: PersistentModel>(_ type: Model.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<Model>())) ?? 1) > 0
        }
        return holds(Habit.self) || holds(HabitGroup.self)
    }

    /// The step for whoever is signed in now, or nil when nobody is. Counts the recovery log again
    /// (a file read, on the tap): a sync since Settings appeared may have archived more lines.
    @MainActor
    static func current(auth: AuthService, sync: SyncService, hasLocalData: Bool) -> DeleteAccountStep? {
        guard let user = auth.currentUser else { return nil }
        sync.refreshRecoveredEdits()
        return DeleteAccountStep(email: user.email,
                                 erasesDevice: sync.storeOwner?.id == SyncAccount(user).id,
                                 hasLocalData: hasLocalData,
                                 recoveredEdits: sync.recoveredEdits)
    }
}

/// Delete Account's last step: what goes, the account's address on a line of its own, the export
/// when this device is erased too, and the final button. Cancel changes nothing. A sheet in the
/// flow the user started ("Delete Account?" → Continue), never one that appears on its own
/// (acceptance 10).
struct DeleteAccountView: View {
    let step: DeleteAccountStep
    let sync: SyncService
    let onDelete: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            message
                                .fixedSize(horizontal: false, vertical: true)
                            AccountAddressLine(caption: Text("Signed in as"), email: step.email)
                        }
                        .padding(.vertical, 2)
                    }

                    if step.offersBackup || step.offersRecoveredEdits {
                        Section {
                            if step.offersBackup {
                                // No `message:`: it went beside the file as text.txt (E2E S6; Settings'
                                // Export Data rows).
                                ShareLink(
                                    item: BackupJSONFile(container: modelContext.container),
                                    subject: Text("Stride Habits Export"),
                                    preview: SharePreview(DataExportService.fileName("Stride-Backup", extension: "json"))
                                ) {
                                    Label("Export as JSON", systemImage: "curlybraces")
                                }
                                .sweepAnchor("deleteExport")
                            }
                            if step.offersRecoveredEdits {
                                RecoveredEditsShareLink(sync: sync)
                                    .sweepAnchor("deleteRecoveredEdits")
                            }
                        } header: {
                            Text("Export Data")
                        } footer: {
                            // Each line wraps in full, as `message` does: updated in place by the
                            // recheck, the footer kept its first layout and cut both explanations
                            // to one line with an ellipsis (E2E S-DEL).
                            VStack(alignment: .leading, spacing: 6) {
                                if step.recoveredEditsChanged {
                                    SettingsInlineError(message: appLocalized("New recovered edits arrived. Export them, then try again."))
                                }
                                if step.offersBackup {
                                    Text("Export as JSON saves a complete backup, which can be restored on a device with no habits.")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if step.offersRecoveredEdits {
                                    Text("The recovered edits on this device are erased too. Export them first if you might need them.")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            // Red icon as well as title, as the Sync section's destructive rows.
                            // Dimmed by hand while disabled: an explicit style overrides the system's.
                            Label("Delete My Account", systemImage: "person.crop.circle.badge.minus")
                                .foregroundStyle(.red.opacity(sync.isSyncing ? 0.4 : 1))
                        }
                        // As the Erase row: a sync running now may be archiving a line this step
                        // never offered (`DeleteAccountStep.recheck` checks again on the tap).
                        .disabled(sync.isSyncing)
                        .sweepAnchor("deleteConfirm")
                    }
                }
                #if DEBUG
                .task { await SweepScroll.scroll(proxy) }
                #endif
            }
            .navigationTitle("Delete Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    /// The server half always; the device half only when this account owns the store — another
    /// owner's rows are left alone, and saying they go would be false — and the store holds
    /// something to export (`offersBackup`): on an empty one it said "export a backup first" with
    /// no Export as JSON row to do it with (E2E S-DEL). Recovered edits have their own footer line.
    @ViewBuilder
    private var message: some View {
        if step.offersBackup {
            Text("All your habits, records, and account information will be permanently removed from our servers. The habits, check-ins and groups on this device are deleted too; export a backup first if you want to keep a copy.")
        } else {
            Text("All your habits, records, and account information will be permanently removed from our servers.")
        }
    }
}
