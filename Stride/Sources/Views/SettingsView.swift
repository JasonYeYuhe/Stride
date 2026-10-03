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
    @State private var showingDeleteAccountConfirm = false
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
    @State private var restoreError: String?
    /// Set when a restore was refused as `storeNotEmpty` although no habit or group is listed:
    /// check-ins orphaned by an old bug. Offers the erase that clears them.
    @State private var storeHasHiddenRows = false
    @State private var showingEraseConfirm = false
    @State private var isErasing = false
    @State private var eraseError: String?

    // Store
    @State private var showingPaywall = false
    @State private var showingLogin = false
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
        settingsContent
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
                    if auth.isLoggedIn {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(auth.userEmail ?? "")
                                    .font(.subheadline)
                                Text("Signed in")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .accessibilityElement(children: .combine)

                        Button {
                            Task {
                                await sync.sync(context: modelContext)
                            }
                        } label: {
                            HStack {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if sync.isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if let lastSync = sync.lastSyncTime {
                                    Text(formatSyncTime(lastSync))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(sync.isSyncing)
                        .accessibilityLabel("Sync Now")
                        .accessibilityValue(syncAccessibilityValue)

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
                    } else {
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
                } header: {
                    Text("Account")
                } footer: {
                    if let error = sync.syncError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            // Red text is the only thing marking this as a failure.
                            .accessibilityLabel("Sync error: \(error)")
                    }
                }

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
                    ShareLink(
                        item: HabitsCSVFile(container: modelContext.container),
                        subject: Text("Stride Habits Export"),
                        message: Text("CSV export of all habits"),
                        preview: SharePreview(DataExportService.fileName("Stride-Export", extension: "csv"))
                    ) {
                        Label("Export as CSV", systemImage: "tablecells")
                    }

                    ShareLink(
                        item: BackupJSONFile(container: modelContext.container),
                        subject: Text("Stride Habits Export"),
                        message: Text("JSON export of all habits"),
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
                        // and remove what it restored (performRestore also waits it out).
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
                        Button(role: .destructive) {
                            eraseError = nil
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
                    LabeledContent("Data Storage", value: auth.isLoggedIn ? appLocalized("Synced") : appLocalized("On Device"))
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
            .alert("Delete Account?", isPresented: $showingDeleteAccountAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    showingDeleteAccountConfirm = true
                }
            } message: {
                Text("This will permanently delete your account and all synced data. This action cannot be undone.")
            }
            .alert("Are you sure?", isPresented: $showingDeleteAccountConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete My Account", role: .destructive) {
                    Task { await performAccountDeletion() }
                }
            } message: {
                Text("All your habits, records, and account information will be permanently removed from our servers.")
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
                Button("Cancel", role: .cancel) {}
                Button("Restore") {
                    Task { await performRestore(pending.document) }
                }
            } message: { pending in
                Text(verbatim: pending.summary)
            }
            .confirmationDialog("Erase Local Data?", isPresented: $showingEraseConfirm, titleVisibility: .visible) {
                Button("Erase", role: .destructive) {
                    Task { await performErase() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if eraseSignsOut {
                    Text("Stride syncs one last time, signs you out, then deletes every habit, check-in and group on this device. Your account's data on the server is not touched: sign in again to download it.")
                } else {
                    Text("Every habit, check-in and group on this device will be deleted. This cannot be undone.")
                }
            }
            .onChange(of: auth.isLoggedIn) { _, loggedIn in
                if loggedIn {
                    Task { await sync.sync(context: modelContext) }
                }
            }
            .task {
                await checkNotificationStatus()
                await store.refreshPurchasedProducts()
            }
    }

    // MARK: - Backup, Restore, Erase

    private struct PendingRestore {
        let document: BackupDocument
        /// Built once when the file is read, not on every render of the alert.
        let summary: String
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
            pendingRestore = PendingRestore(document: document, summary: backupSummary(document))
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

    private func performRestore(_ document: BackupDocument) async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            // Waits for a sync in flight first; see DataExportService.restore.
            try await DataExportService.restore(document, into: modelContext)
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
        switch await DataExportService.eraseLocalData(in: modelContext) {
        case .erased:
            break
        case .syncFailed:
            showEraseError(appLocalized("Couldn't sync, so nothing was erased. Check your connection and try again, or log out first to erase without syncing."))
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
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    // Each branch is a whole phrase so it stays one localization key, not a %@ argument.
    private var syncAccessibilityValue: Text {
        if sync.isSyncing { return Text("Syncing") }
        guard let lastSync = sync.lastSyncTime else { return Text(verbatim: "") }
        return Text("Last synced \(formatSyncTime(lastSync))")
    }

    private func formatSyncTime(_ iso: String) -> String {
        guard let date = SyncTimestamp.parse(iso) else { return iso }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func performAccountDeletion() async {
        isDeletingAccount = true
        do {
            try await auth.deleteAccount()
        } catch {
            deleteAccountError = error.localizedDescription
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
