import SwiftUI
import SwiftData
import UserNotifications

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stride")
                                .font(.headline)
                            Text("Habit Tracker")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stride Pro")
                                    .font(.headline)
                                Text("All features unlocked")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Account & Sync
                Section {
                    if auth.isLoggedIn {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(auth.userEmail ?? "")
                                    .font(.subheadline)
                                Text("Signed in")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

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
                    } else {
                        Button {
                            showingLogin = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.title2)
                                    .foregroundStyle(.green)
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
                                    if habit.currentStreak() > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "flame.fill")
                                                .font(.system(size: 9))
                                            Text("\(habit.currentStreak())d")
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(.orange)
                                    }
                                }
                            }
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
                            HStack {
                                Circle().fill(group.color).frame(width: 10, height: 10)
                                Text(group.name)
                                Spacer()
                                Text("\(allHabits.filter { $0.groupId == group.id && !$0.isArchived }.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                groupToRename = group
                                groupNameText = group.name
                            }
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
                    let csvString = DataExportService.exportCSV(habits: allHabits)
                    let jsonString = DataExportService.exportJSON(habits: allHabits)

                    ShareLink(
                        item: csvString,
                        subject: Text("Stride Habits Export"),
                        message: Text("CSV export of all habits"),
                        preview: SharePreview("stride_export.csv")
                    ) {
                        Label("Export as CSV", systemImage: "tablecells")
                    }

                    ShareLink(
                        item: jsonString,
                        subject: Text("Stride Habits Export"),
                        message: Text("JSON export of all habits"),
                        preview: SharePreview("stride_export.json")
                    ) {
                        Label("Export as JSON", systemImage: "curlybraces")
                    }
                } header: {
                    Text("Export Data")
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
                    LabeledContent("Data Storage", value: auth.isLoggedIn ? String(localized: "Synced") : String(localized: "On Device"))
                    Toggle(isOn: Binding(
                        get: { AnalyticsService.shared.isEnabled },
                        set: { AnalyticsService.shared.isEnabled = $0 }
                    )) {
                        Label("Share Anonymous Analytics", systemImage: "chart.bar.xaxis")
                    }
                    .tint(.green)
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
                        AnalyticsService.shared.send("habitDeleted")
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

    // MARK: - Notification Logic

    private func handleReminderToggle(_ enabled: Bool) {
        if enabled {
            Task {
                let granted = await NotificationService.shared.requestPermission()
                if granted {
                    NotificationService.shared.isReminderEnabled = true
                    notificationDenied = false
                } else {
                    let status = await NotificationService.shared.checkPermission()
                    if status == .denied {
                        notificationDenied = true
                        reminderEnabled = false
                    }
                }
            }
        } else {
            NotificationService.shared.isReminderEnabled = false
        }
    }

    private func formatSyncTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
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
