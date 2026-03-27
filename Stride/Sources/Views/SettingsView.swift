import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Habit.createdAt) private var allHabits: [Habit]

    @State private var showingDeleteAlert = false
    @State private var habitToDelete: Habit?

    // Notification states
    @State private var reminderEnabled = NotificationService.shared.isReminderEnabled
    @State private var reminderTime = NotificationService.shared.reminderTime
    @State private var morningEnabled = NotificationService.shared.isMorningMotivationEnabled
    @State private var notificationDenied = false

    // Store
    @State private var showingPaywall = false
    private var store = StoreService.shared

    private var activeHabits: [Habit] {
        allHabits.filter { !$0.isArchived }
    }

    private var archivedHabits: [Habit] {
        allHabits.filter { $0.isArchived }
    }

    var body: some View {
        NavigationStack {
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
                                    Text("Unlimited habits, widgets, smart reminders & more")
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
                                        try? modelContext.save()
                                    }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.orange)
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
                                        try? modelContext.save()
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

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    LabeledContent("Platform") {
                        #if os(macOS)
                        Text("macOS")
                        #else
                        Text("iOS")
                        #endif
                    }
                    LabeledContent("Data Storage", value: "On Device")
                }
            }
            .navigationTitle("Settings")
            .alert("Delete Habit", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    habitToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let habit = habitToDelete {
                        modelContext.delete(habit)
                        try? modelContext.save()
                        habitToDelete = nil
                    }
                }
            } message: {
                Text("This will permanently delete this habit and all its records. This cannot be undone.")
            }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView()
            }
            .task {
                await checkNotificationStatus()
                await store.refreshPurchasedProducts()
            }
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

    private func checkNotificationStatus() async {
        let status = await NotificationService.shared.checkPermission()
        if status == .denied && reminderEnabled {
            notificationDenied = true
        }
    }
}
