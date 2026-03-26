import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Habit.createdAt) private var allHabits: [Habit]

    @State private var showingDeleteAlert = false
    @State private var habitToDelete: Habit?

    private var activeHabits: [Habit] {
        allHabits.filter { !$0.isArchived }
    }

    private var archivedHabits: [Habit] {
        allHabits.filter { $0.isArchived }
    }

    var body: some View {
        NavigationStack {
            List {
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
                    LabeledContent("Version", value: "1.0.0")
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
        }
    }
}
