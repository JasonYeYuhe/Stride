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
                    }
                    .listRowBackground(Color.clear)
                    // The ring hides itself, so a label on it had no element to attach to and
                    // VoiceOver read the bare "3/5" — "three slash five", counting nothing.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(completedCount) of \(habits.count) habits completed")
                    // Otherwise "0 of 0 habits completed" is the first stop in a fresh app,
                    // ahead of the one row that says anything.
                    .accessibilityHidden(habits.isEmpty)
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
        // Was a yes/no toggle that deleted EVERY record for the day, count habits included.
        let result = HabitCheckIn.tap(habit, on: Date(), in: modelContext)
        do {
            try modelContext.save()
            // Record deletions for sync only after a successful save, mirroring the
            // widget. (Full watch↔backend sync arrives in a later release via
            // WatchConnectivity; this keeps the tombstone plumbing correct.)
            if let deletedID = result.deletedRecordID {
                SyncDeletionQueue.live.trackSharedEntry(deletedID)
            }
        } catch {
            // Revert will happen on next fetch; log for debugging
            print("Failed to save: \(error)")
        }
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

    private var isCountHabit: Bool {
        habit.habitKind == .count
    }

    /// "6 of 8 glasses" — spelled out, because VoiceOver reads "6/8" as a date or a fraction.
    /// TodayView's copy lives in an iOS-only file, so the watch keeps its own.
    private var spokenCount: String {
        let logged = Self.numberFormat(habit.loggedValue(on: Date()))
        let target = Self.numberFormat(habit.targetValue)
        let progress = String(localized: "\(logged) of \(target)")
        guard let unit = habit.unit, !unit.isEmpty else { return progress }
        return "\(progress) \(unit)"
    }

    private static func numberFormat(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The row still has to say whether the day is done — a count habit is complete once it
    /// reaches its target — so the state stays in the label for both kinds. What the tap does
    /// differs, and that belongs in the hint.
    private var spokenLabel: Text {
        isCompleted ? Text("\(habit.name), completed") : Text("\(habit.name), not completed")
    }

    /// The explicit label replaces everything `.combine` merged, so the streak badge — and a count
    /// habit's progress, which this row never draws at all — is announced only from here. Being the
    /// value, it is also re-spoken on each tap: the only feedback a count habit has.
    private var spokenDetail: String {
        var parts: [String] = []
        if isCountHabit { parts.append(spokenCount) }
        if streak > 0 {
            // Not "\(streak) \(habit.streakUnit) streak": the unit would reach every language
            // as the English word.
            parts.append(habit.streakUnit == "week"
                ? String(localized: "\(streak) week streak")
                : String(localized: "\(streak) day streak"))
        }
        return parts.joined(separator: ", ")
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
                            Text(habit.streakUnit == "week" ? "\(streak)w" : "\(streak)d")
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
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenDetail)
        // A count tap adds one unit and never clears the day; only a binary tap toggles.
        .accessibilityHint(isCountHabit ? Text("Double tap to add one") : Text("Double tap to toggle completion"))
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
