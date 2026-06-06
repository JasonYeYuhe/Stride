import SwiftUI
import SwiftData

struct WatchTodayView: View {
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    @Environment(\.modelContext) private var modelContext

    private var completedCount: Int {
        habits.filter { $0.isCompletedOn(Date()) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("\(completedCount)/\(habits.count)")
                            .font(.title2.bold())
                            .foregroundStyle(.green)
                        Spacer()
                        CircularProgressView(
                            progress: habits.isEmpty ? 0 : Double(completedCount) / Double(habits.count)
                        )
                        .frame(width: 36, height: 36)
                        .accessibilityLabel("\(completedCount) of \(habits.count) habits completed")
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    if habits.isEmpty {
                        Text("No habits yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(habits) { habit in
                            WatchHabitRow(habit: habit) {
                                toggleCompletion(habit)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Stride")
        }
    }

    private func toggleCompletion(_ habit: Habit) {
        let today = Date()
        let matchingRecords = habit.records.filter {
            HabitCalendar.record($0.date, isOnSameDayAs: today)
        }
        let deletedIds = matchingRecords.map { $0.id.uuidString }
        if !matchingRecords.isEmpty {
            for record in matchingRecords {
                modelContext.delete(record)
            }
        } else {
            let record = HabitRecord(date: today)
            habit.records.append(record)
        }
        do {
            try modelContext.save()
            // Record deletions for sync only after a successful save, mirroring the
            // widget. (Full watch↔backend sync arrives in a later release via
            // WatchConnectivity; this keeps the tombstone plumbing correct.)
            for id in deletedIds {
                Self.trackDeletedEntry(id)
            }
        } catch {
            // Revert will happen on next fetch; log for debugging
            print("Failed to save: \(error)")
        }
    }

    /// Track a deleted entry ID in the shared app group UserDefaults for sync.
    private static func trackDeletedEntry(_ id: String) {
        let key = "stride_deleted_entry_ids_widget"
        guard let defaults = UserDefaults(suiteName: SharedModelContainer.appGroupIdentifier) else { return }
        var ids = defaults.stringArray(forKey: key) ?? []
        ids.append(id)
        defaults.set(ids, forKey: key)
    }
}

struct WatchHabitRow: View {
    let habit: Habit
    let onToggle: () -> Void

    private var isCompleted: Bool {
        habit.isCompletedOn(Date())
    }

    private var streak: Int {
        habit.currentStreak()
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Text(habit.emoji)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(habit.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    if streak > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("\(streak)d")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompleted ? habit.color : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(habit.name), \(isCompleted ? "completed" : "not completed")")
        .accessibilityHint("Double tap to toggle completion")
    }
}

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}
