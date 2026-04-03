import SwiftUI
import SwiftData

struct AddHabitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing habit to enter edit mode; nil = create mode
    var editingHabit: Habit?

    @State private var name = ""
    @State private var selectedEmoji = "⭐"
    @State private var selectedColor = HabitColor.all[0]
    @State private var showingTemplates = false
    @State private var showSaveError = false
    @State private var reminderEnabled = false
    @State private var reminderTime = Calendar.current.date(from: DateComponents(hour: 20, minute: 0)) ?? Date()

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
    }

    private func createHabit() {
        let habit = Habit(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: selectedEmoji,
            colorHex: selectedColor.hex
        )
        habit.reminderEnabled = reminderEnabled
        habit.reminderTimeDate = reminderTime
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

    private func updateHabit() {
        guard let habit = editingHabit else { return }
        habit.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        habit.emoji = selectedEmoji
        habit.colorHex = selectedColor.hex
        habit.reminderEnabled = reminderEnabled
        habit.reminderTimeDate = reminderTime
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
