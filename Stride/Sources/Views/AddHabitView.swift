import SwiftUI
import SwiftData

struct AddHabitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedEmoji = "⭐"
    @State private var selectedColor = HabitColor.all[0]

    var body: some View {
        NavigationStack {
            Form {
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
            }
            .navigationTitle("New Habit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveHabit()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .bold()
                }
            }
        }
    }

    private func saveHabit() {
        let habit = Habit(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: selectedEmoji,
            colorHex: selectedColor.hex
        )
        modelContext.insert(habit)
        try? modelContext.save()

        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif

        dismiss()
    }
}
