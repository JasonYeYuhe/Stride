import SwiftUI
import SwiftData
import WidgetKit

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    @Query(sort: \HabitGroup.sortOrder)
    private var groups: [HabitGroup]

    @State private var showingAddHabit = false
    @State private var selectedDate = Date()
    @State private var collapsedGroups: Set<UUID> = []

    /// Habits split into ordered sections by group; falls back to a single flat
    /// section when the user has no groups.
    private var groupedSections: [(group: HabitGroup?, habits: [Habit])] {
        guard !groups.isEmpty else { return [(nil, habits)] }
        let groupIds = Set(groups.map { $0.id })
        var sections: [(group: HabitGroup?, habits: [Habit])] = []
        for g in groups {
            let hs = habits.filter { $0.groupId == g.id }
            if !hs.isEmpty { sections.append((g, hs)) }
        }
        let ungrouped = habits.filter { $0.groupId == nil || !groupIds.contains($0.groupId!) }
        if !ungrouped.isEmpty { sections.append((nil, ungrouped)) }
        return sections
    }

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
        todayContent
    }

    private var todayContent: some View {
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
                } else if groups.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(habits) { habit in
                            HabitRowView(habit: habit, date: selectedDate)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(groupedSections, id: \.group?.id) { section in
                            VStack(spacing: 12) {
                                groupHeader(for: section.group, count: section.habits.count)
                                if !isCollapsed(section.group) {
                                    ForEach(section.habits) { habit in
                                        HabitRowView(habit: habit, date: selectedDate)
                                    }
                                }
                            }
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

    private func isCollapsed(_ group: HabitGroup?) -> Bool {
        guard let group else { return false }
        return collapsedGroups.contains(group.id)
    }

    @ViewBuilder
    private func groupHeader(for group: HabitGroup?, count: Int) -> some View {
        let title = group?.name ?? String(localized: "Ungrouped")
        let collapsed = isCollapsed(group)
        Button {
            guard let id = group?.id else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsedGroups.contains(id) { collapsedGroups.remove(id) }
                else { collapsedGroups.insert(id) }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(group?.color ?? Color.gray)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if group != nil {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group == nil)
        .accessibilityLabel("\(title), \(count) habits")
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
    @State private var showingEdit = false
    @State private var showingNote = false
    @State private var noteText = ""

    private var isCompleted: Bool {
        habit.isCompletedOn(date)
    }

    private var todayRecord: HabitRecord? {
        return habit.records.first { HabitCalendar.record($0.date, isOnSameDayAs: date) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(habit.emoji)
                    .font(.title2)

                habitInfo

                Spacer()

                trailingControl
            }
            .padding()

            if let record = todayRecord, let note = record.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .contextMenu {
            Button {
                showingEdit = true
            } label: {
                Label("Edit Habit", systemImage: "pencil")
            }
            if habit.habitKind == .count {
                Button {
                    withAnimation { incrementCount() }
                } label: {
                    Label("Add 1", systemImage: "plus")
                }
                if habit.loggedValue(on: date) > 0 {
                    Button {
                        withAnimation { decrementCount() }
                    } label: {
                        Label("Subtract 1", systemImage: "minus")
                    }
                    Button(role: .destructive) {
                        withAnimation { resetCount() }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            if isCompleted {
                Button {
                    noteText = todayRecord?.note ?? ""
                    showingNote = true
                } label: {
                    Label(todayRecord?.note != nil ? "Edit Note" : "Add Note", systemImage: "note.text")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddHabitView(editingHabit: habit)
        }
        .alert("Note", isPresented: $showingNote) {
            TextField("How did it go?", text: $noteText)
            Button("Save") {
                todayRecord?.note = noteText.isEmpty ? nil : noteText
                todayRecord?.touch()
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add a note for today's check-in.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(habit.emoji) \(habit.name), \(isCompleted ? "completed" : "not completed")")
        .accessibilityHint("Double tap to toggle completion")
    }

    @ViewBuilder
    private var habitInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(habit.name)
                .font(.body.weight(.medium))
            if habit.habitKind == .count {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !habit.isScheduled(on: date) {
                Text("Rest day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if habit.schedule == .timesPerWeek {
                Text("\(habit.weeklyCompletions(containing: date))/\(habit.timesPerWeek) this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let streak = habit.currentStreak(from: date)
            if streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("\(streak) \(habit.streakUnit) streak")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if habit.habitKind == .count {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { incrementCount() }
            } label: {
                countRing
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add one to \(habit.name)")
            .accessibilityValue(countLabel)
        } else {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { toggleCompletion() }
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(isCompleted ? habit.color : Color.gray.opacity(0.4))
                    .scaleEffect(justCompleted ? 1.3 : (isCompleted ? 1.1 : 1.0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Mark \(habit.name) incomplete" : "Mark \(habit.name) complete")
        }
    }

    private var countRing: some View {
        ZStack {
            Circle()
                .stroke(habit.color.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: habit.progress(on: date))
                .stroke(habit.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(habit.color)
            } else {
                Text(Self.numberFormat(habit.loggedValue(on: date)))
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 40, height: 40)
        .scaleEffect(justCompleted ? 1.2 : 1.0)
    }

    private func toggleCompletion() {
        // Shared with the widget, the watch and Siri — see HabitCheckIn.
        let result = HabitCheckIn.tap(habit, on: date, in: modelContext)
        if result.isCompleted {
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
        } else {
            justCompleted = false
        }
        do {
            try modelContext.save()
            // Queue the tombstone only once the deletion is actually saved.
            if let id = result.deletedRecordID { SyncService.shared.trackDeletedEntry(id) }
        } catch {
            #if DEBUG
            print("Failed to save habit completion: \(error)")
            #endif
        }
        WidgetCenter.shared.reloadAllTimelines()
        NotificationService.shared.updateBadge(modelContainer: modelContext.container)
    }

    // MARK: - Count habit logging

    private var countLabel: String {
        let logged = Self.numberFormat(habit.loggedValue(on: date))
        let target = Self.numberFormat(habit.targetValue)
        let unit = habit.unit.map { " \($0)" } ?? ""
        return "\(logged)/\(target)\(unit)"
    }

    static func numberFormat(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func incrementCount() {
        // A count tap adds one unit and never deletes — shared with the widget, watch and Siri.
        if HabitCheckIn.tap(habit, on: date, in: modelContext).isCompleted {
            justCompleted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.2)) { justCompleted = false }
            }
        }
        AnalyticsService.shared.send("habitCompleted")
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        saveAndRefresh()
    }

    private func decrementCount() {
        guard let record = habit.record(on: date) else { return }
        if record.value <= 1 {
            SyncService.shared.trackDeletedEntry(record.id.uuidString)
            modelContext.delete(record)
        } else {
            record.value -= 1
            record.touch()
        }
        saveAndRefresh()
    }

    private func resetCount() {
        guard let record = habit.record(on: date) else { return }
        SyncService.shared.trackDeletedEntry(record.id.uuidString)
        modelContext.delete(record)
        saveAndRefresh()
    }

    private func saveAndRefresh() {
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Failed to save count update: \(error)")
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
