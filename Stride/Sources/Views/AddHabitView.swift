import SwiftUI
import SwiftData

struct AddHabitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \HabitGroup.sortOrder) private var groups: [HabitGroup]

    /// Pass an existing habit to enter edit mode; nil = create mode
    var editingHabit: Habit?

    @State private var name = ""
    @State private var selectedEmoji = "⭐"
    @State private var selectedColor = HabitColor.all[0]
    @State private var showingTemplates = false
    @State private var showSaveError = false
    @State private var reminderEnabled = false
    @State private var reminderTime = Calendar.current.date(from: DateComponents(hour: 20, minute: 0)) ?? Date()
    @State private var kind: HabitKind = .binary
    @State private var targetValue = 1
    @State private var unit = ""
    @State private var schedule: HabitSchedule = .daily
    @State private var timesPerWeek = 3
    @State private var activeDays: Set<Int> = Set(0...6)   // 0=Sun … 6=Sat
    @State private var selectedGroupId: UUID?
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var showingPaywall = false
    private var store: StoreService { StoreService.shared }

    /// Weekday symbols starting Sunday, matching the activeDays index.
    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    private var isEditing: Bool { editingHabit != nil }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    Section {
                        Button {
                            showingTemplates = true
                        } label: {
                            Label("Browse Templates", systemImage: "square.grid.2x2")
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section("Habit Name") {
                    TextField("e.g., Read 30 minutes", text: $name)
                        #if os(macOS)
                        .textFieldStyle(.plain)
                        #endif
                }

                Section {
                    Picker("Type", selection: $kind) {
                        Text("Yes / No").tag(HabitKind.binary)
                        Text("Measurable").tag(HabitKind.count)
                    }
                    .pickerStyle(.segmented)

                    if kind == .count {
                        Stepper(value: $targetValue, in: 1...1000) {
                            HStack {
                                Text("Daily goal")
                                Spacer()
                                Text("\(targetValue)\(unit.isEmpty ? "" : " \(unit)")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        TextField("Unit (e.g. glasses, min, km)", text: $unit)
                            #if os(macOS)
                            .textFieldStyle(.plain)
                            #endif
                    }
                } header: {
                    Text("Goal")
                } footer: {
                    if kind == .count {
                        Text("Log a number each day and reach your target to complete the habit.")
                    } else {
                        Text("A simple done / not-done check each day.")
                    }
                }

                frequencySection

                groupSection

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(HabitEmoji.all, id: \.self) { emoji in
                            Text(emoji)
                                .font(.title2)
                                .frame(width: 40, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedEmoji == emoji ? Color.green.opacity(0.2) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedEmoji == emoji ? Color.green : Color.clear, lineWidth: 2)
                                )
                                .onTapGesture {
                                    selectedEmoji = emoji
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(HabitColor.all) { color in
                            Circle()
                                .fill(color.color)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: selectedColor.hex == color.hex ? 3 : 0)
                                        .shadow(radius: 2)
                                )
                                .scaleEffect(selectedColor.hex == color.hex ? 1.15 : 1.0)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedColor = color
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    HStack(spacing: 14) {
                        Text(selectedEmoji)
                            .font(.title2)
                        Text(name.isEmpty ? "Your Habit" : name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(selectedColor.color)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                }

                Section {
                    Toggle(isOn: $reminderEnabled) {
                        Label("Reminder", systemImage: "bell.fill")
                    }
                    .tint(.green)

                    if reminderEnabled {
                        DatePicker(
                            "Time",
                            selection: $reminderTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    if reminderEnabled {
                        Text("You'll receive a daily reminder for this habit.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Habit" : "New Habit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isEditing ? updateHabit() : createHabit()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .bold()
                }
            }
            .onAppear {
                if let habit = editingHabit {
                    name = habit.name
                    selectedEmoji = habit.emoji
                    reminderEnabled = habit.reminderEnabled
                    reminderTime = habit.reminderTimeDate
                    kind = habit.habitKind
                    targetValue = max(1, Int(habit.targetValue))
                    unit = habit.unit ?? ""
                    schedule = habit.schedule
                    timesPerWeek = max(1, habit.timesPerWeek)
                    activeDays = Self.daySet(from: habit.activeDaysMask)
                    selectedGroupId = habit.groupId
                    if let match = HabitColor.all.first(where: { $0.hex == habit.colorHex }) {
                        selectedColor = match
                    }
                }
            }
        }
        .sheet(isPresented: $showingTemplates) {
            HabitTemplatesView()
        }
        .alert("Save Failed", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Unable to save your habit. Please try again.")
        }
        .alert("New Group", isPresented: $showingNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { createGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Organize related habits together.")
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
        }
    }

    private func createGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let maxOrder = (groups.map(\.sortOrder).max() ?? -1) + 1
        let group = HabitGroup(name: trimmed, colorHex: selectedColor.hex, sortOrder: maxOrder)
        modelContext.insert(group)
        try? modelContext.save()
        selectedGroupId = group.id
    }

    private func createHabit() {
        let habit = Habit(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: selectedEmoji,
            colorHex: selectedColor.hex
        )
        habit.reminderEnabled = reminderEnabled
        habit.reminderTimeDate = reminderTime
        habit.habitKind = kind
        habit.targetValue = Double(targetValue)
        habit.unit = (kind == .count && !unit.trimmingCharacters(in: .whitespaces).isEmpty)
            ? unit.trimmingCharacters(in: .whitespaces) : nil
        applySchedule(to: habit)
        modelContext.insert(habit)
        do {
            try modelContext.save()
            if reminderEnabled {
                NotificationService.shared.scheduleHabitReminder(for: habit)
            }
            AnalyticsService.shared.send("habitCreated")

            #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif

            dismiss()
        } catch {
            modelContext.rollback()
            showSaveError = true
            #if DEBUG
            print("Failed to save new habit: \(error)")
            #endif
        }
    }

    @ViewBuilder
    private var frequencySection: some View {
        Section {
            Picker("Frequency", selection: $schedule) {
                Text("Every day").tag(HabitSchedule.daily)
                Text("Specific days").tag(HabitSchedule.specificDays)
                Text("Times per week").tag(HabitSchedule.timesPerWeek)
            }

            if schedule == .specificDays {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        weekdayToggle(day)
                    }
                }
                .padding(.vertical, 2)
            } else if schedule == .timesPerWeek {
                Stepper(value: $timesPerWeek, in: 1...7) {
                    HStack {
                        Text("Goal")
                        Spacer()
                        Text("\(timesPerWeek)× per week").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Frequency")
        } footer: {
            switch schedule {
            case .daily: Text("Tracked every day.")
            case .specificDays: Text("Only the selected days count toward your streak — other days are rest days.")
            case .timesPerWeek: Text("Hit your weekly goal any days you like; your streak counts weeks.")
            }
        }
    }

    private func weekdayToggle(_ day: Int) -> some View {
        let on = activeDays.contains(day)
        return Button {
            if on { activeDays.remove(day) } else { activeDays.insert(day) }
        } label: {
            Text(weekdaySymbols[day])
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(on ? Color.green.opacity(0.25) : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(on ? Color.green : Color.clear, lineWidth: 1.5)
                )
                .foregroundStyle(on ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.weekdayName(day))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var groupSection: some View {
        Section {
            Picker("Group", selection: $selectedGroupId) {
                Text("None").tag(UUID?.none)
                ForEach(groups) { group in
                    Text(group.name).tag(Optional(group.id))
                }
            }
            Button {
                if store.isPro {
                    newGroupName = ""
                    showingNewGroup = true
                } else {
                    showingPaywall = true
                }
            } label: {
                HStack {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .foregroundStyle(.green)
                    if !store.isPro {
                        Spacer()
                        Image(systemName: "crown.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
            }
        } header: {
            Text("Group")
        } footer: {
            if !store.isPro {
                Text("Habit groups are a Stride Pro feature.")
            }
        }
    }

    private func applySchedule(to habit: Habit) {
        habit.schedule = schedule
        habit.timesPerWeek = timesPerWeek
        // An empty day selection would mean "never" — fall back to every day.
        habit.activeDaysMask = (schedule == .specificDays && !activeDays.isEmpty)
            ? Self.mask(from: activeDays) : 127
        habit.groupId = selectedGroupId
    }

    private static func mask(from days: Set<Int>) -> Int {
        days.reduce(0) { $0 | (1 << $1) }
    }

    private static func daySet(from mask: Int) -> Set<Int> {
        Set((0..<7).filter { mask & (1 << $0) != 0 })
    }

    private static func weekdayName(_ index: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]
    }

    private func updateHabit() {
        guard let habit = editingHabit else { return }
        habit.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        habit.emoji = selectedEmoji
        habit.colorHex = selectedColor.hex
        habit.reminderEnabled = reminderEnabled
        habit.reminderTimeDate = reminderTime
        habit.habitKind = kind
        habit.targetValue = Double(targetValue)
        habit.unit = (kind == .count && !unit.trimmingCharacters(in: .whitespaces).isEmpty)
            ? unit.trimmingCharacters(in: .whitespaces) : nil
        applySchedule(to: habit)
        habit.touch()
        do {
            try modelContext.save()
            if reminderEnabled {
                NotificationService.shared.scheduleHabitReminder(for: habit)
            } else {
                NotificationService.shared.removeHabitReminder(for: habit.id)
            }
            AnalyticsService.shared.send("habitEdited")
            dismiss()
        } catch {
            showSaveError = true
            #if DEBUG
            print("Failed to update habit: \(error)")
            #endif
        }
    }
}
