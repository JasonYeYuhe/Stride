import SwiftUI
import SwiftData
import WidgetKit

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.createdAt)
    private var habits: [Habit]

    @State private var showingAddHabit = false
    @State private var selectedDate = Date()

    private var dateTitle: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return String(localized: "Today")
        } else if Calendar.current.isDateInYesterday(selectedDate) {
            return String(localized: "Yesterday")
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: selectedDate)
        }
    }

    private var completedCount: Int {
        habits.filter { $0.isCompletedOn(selectedDate) }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    WeekStripView(selectedDate: $selectedDate)
                        .padding(.horizontal)

                    if !habits.isEmpty {
                        ProgressSummaryCard(
                            completed: completedCount,
                            total: habits.count
                        )
                        .padding(.horizontal)
                    }

                    if habits.isEmpty {
                        EmptyStateView(showingAddHabit: $showingAddHabit)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(habits) { habit in
                                HabitRowView(
                                    habit: habit,
                                    date: selectedDate
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color.appBackground)
            .navigationTitle(dateTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddHabit = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingAddHabit) {
                AddHabitView()
            }
        }
    }
}

// MARK: - Week Strip
struct WeekStripView: View {
    @Binding var selectedDate: Date
    private let days = Date.lastNDays(7)

    var body: some View {
        HStack(spacing: 8) {
            ForEach(days, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)

                VStack(spacing: 4) {
                    Text(day.shortWeekday)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white : .secondary)

                    Text(day.dayNumber)
                        .font(.callout.bold())
                        .foregroundStyle(isSelected ? .white : .primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.green : Color.clear)
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedDate = day
                    }
                }
                .accessibilityLabel("\(day.shortWeekday) \(day.dayNumber)\(isSelected ? ", selected" : "")")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Progress Summary
struct ProgressSummaryCard: View {
    let completed: Int
    let total: Int

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(completed)/\(total) completed")
                    .font(.headline)
                Text(motivationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: progress)

                Text("\(Int(progress * 100))%")
                    .font(.caption.bold())
            }
            .frame(width: 50, height: 50)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completed) of \(total) habits completed, \(Int(progress * 100)) percent")
    }

    private var motivationMessage: LocalizedStringKey {
        switch progress {
        case 1.0: return "All done! Perfect day!"
        case 0.75..<1.0: return "Almost there! Keep going!"
        case 0.5..<0.75: return "Halfway done! Nice!"
        case 0.01..<0.5: return "Good start! Keep it up!"
        default: return "Let's get started!"
        }
    }
}

// MARK: - Habit Row
struct HabitRowView: View {
    @Environment(\.modelContext) private var modelContext
    let habit: Habit
    let date: Date

    @State private var justCompleted = false

    private var isCompleted: Bool {
        habit.isCompletedOn(date)
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(habit.emoji)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name)
                    .font(.body.weight(.medium))
                let streak = habit.currentStreak(from: date)
                if streak > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("\(streak) day streak")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    toggleCompletion()
                }
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(isCompleted ? habit.color : .gray.opacity(0.4))
                    .scaleEffect(justCompleted ? 1.3 : (isCompleted ? 1.1 : 1.0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Mark \(habit.name) incomplete" : "Mark \(habit.name) complete")
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(habit.emoji) \(habit.name), \(isCompleted ? "completed" : "not completed")")
        .accessibilityHint("Double tap to toggle completion")
    }

    private func toggleCompletion() {
        let calendar = Calendar.current
        if let existingRecord = habit.records.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            SyncService.shared.trackDeletedEntry(existingRecord.id.uuidString)
            modelContext.delete(existingRecord)
            justCompleted = false
        } else {
            let record = HabitRecord(date: date)
            habit.records.append(record)
            justCompleted = true
            AnalyticsService.shared.send("habitCompleted")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.2)) {
                    justCompleted = false
                }
            }

            #if os(iOS)
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            #endif
        }
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Failed to save habit completion: \(error)")
            #endif
        }
        WidgetCenter.shared.reloadAllTimelines()
        NotificationService.shared.updateBadge(modelContainer: modelContext.container)
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    @Binding var showingAddHabit: Bool
    @State private var showingTemplates = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green.opacity(0.6))

            Text("Start Your Journey")
                .font(.title2.bold())

            Text("Add your first habit and begin\nbuilding better routines.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingAddHabit = true
            } label: {
                Label("Add First Habit", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.green))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Button {
                showingTemplates = true
            } label: {
                Label("Browse Templates", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingTemplates) {
            HabitTemplatesView()
        }
    }
}
