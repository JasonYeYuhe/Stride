import SwiftUI
import SwiftData

// MARK: - Template Model

struct HabitTemplate: Identifiable {
    let id = UUID()
    let name: String
    let emoji: String
    let colorHex: String
    let category: String
}

// MARK: - Template Data

enum HabitTemplateLibrary {
    static let categories = [
        "Health & Fitness",
        "Learning",
        "Productivity",
        "Wellness",
        "Creative",
    ]

    static let templates: [HabitTemplate] = [
        // Health & Fitness
        HabitTemplate(name: "Morning Run", emoji: "\u{1F3C3}", colorHex: "#34C759", category: "Health & Fitness"),
        HabitTemplate(name: "Drink Water", emoji: "\u{1F4A7}", colorHex: "#5AC8FA", category: "Health & Fitness"),
        HabitTemplate(name: "Meditate", emoji: "\u{1F9D8}", colorHex: "#AF52DE", category: "Health & Fitness"),
        HabitTemplate(name: "Exercise", emoji: "\u{1F3CB}\u{FE0F}", colorHex: "#FF9500", category: "Health & Fitness"),
        HabitTemplate(name: "Sleep 8hrs", emoji: "\u{1F4A4}", colorHex: "#007AFF", category: "Health & Fitness"),
        HabitTemplate(name: "Take Vitamins", emoji: "\u{1F48A}", colorHex: "#FF3B30", category: "Health & Fitness"),

        // Learning
        HabitTemplate(name: "Read 30min", emoji: "\u{1F4DA}", colorHex: "#007AFF", category: "Learning"),
        HabitTemplate(name: "Study", emoji: "\u{1F4D6}", colorHex: "#AF52DE", category: "Learning"),
        HabitTemplate(name: "Practice Language", emoji: "\u{1F310}", colorHex: "#5AC8FA", category: "Learning"),
        HabitTemplate(name: "Write Journal", emoji: "\u{270D}\u{FE0F}", colorHex: "#FFCC00", category: "Learning"),

        // Productivity
        HabitTemplate(name: "Wake Up Early", emoji: "\u{2600}\u{FE0F}", colorHex: "#FFCC00", category: "Productivity"),
        HabitTemplate(name: "No Phone Before Bed", emoji: "\u{1F4F5}", colorHex: "#AF52DE", category: "Productivity"),
        HabitTemplate(name: "Plan Tomorrow", emoji: "\u{1F4DD}", colorHex: "#007AFF", category: "Productivity"),
        HabitTemplate(name: "Deep Work", emoji: "\u{1F4BB}", colorHex: "#34C759", category: "Productivity"),

        // Wellness
        HabitTemplate(name: "Gratitude", emoji: "\u{1F64F}", colorHex: "#FF9500", category: "Wellness"),
        HabitTemplate(name: "Stretch", emoji: "\u{1F938}", colorHex: "#FF2D55", category: "Wellness"),
        HabitTemplate(name: "Walk 10k Steps", emoji: "\u{1F6B6}", colorHex: "#34C759", category: "Wellness"),
        HabitTemplate(name: "Eat Healthy", emoji: "\u{1F957}", colorHex: "#34C759", category: "Wellness"),
        HabitTemplate(name: "No Sugar", emoji: "\u{1F6AB}", colorHex: "#FF3B30", category: "Wellness"),
        HabitTemplate(name: "Skincare", emoji: "\u{1F9F4}", colorHex: "#FF2D55", category: "Wellness"),

        // Creative
        HabitTemplate(name: "Draw", emoji: "\u{1F3A8}", colorHex: "#FF2D55", category: "Creative"),
        HabitTemplate(name: "Play Music", emoji: "\u{1F3B8}", colorHex: "#AF52DE", category: "Creative"),
        HabitTemplate(name: "Write 500 Words", emoji: "\u{270F}\u{FE0F}", colorHex: "#007AFF", category: "Creative"),
        HabitTemplate(name: "Photography", emoji: "\u{1F4F8}", colorHex: "#FF9500", category: "Creative"),
    ]
}

// MARK: - Templates View

struct HabitTemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    private var filteredTemplates: [String: [HabitTemplate]] {
        let templates: [HabitTemplate]
        if searchText.isEmpty {
            templates = HabitTemplateLibrary.templates
        } else {
            templates = HabitTemplateLibrary.templates.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }

        return Dictionary(grouping: templates, by: \.category)
    }

    private var sortedCategories: [String] {
        HabitTemplateLibrary.categories.filter { filteredTemplates[$0] != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedCategories, id: \.self) { category in
                    Section(category) {
                        ForEach(filteredTemplates[category] ?? []) { template in
                            templateRow(template)
                        }
                    }
                }
            }
            .navigationTitle("Habit Templates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Search templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if sortedCategories.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func templateRow(_ template: HabitTemplate) -> some View {
        Button {
            addHabit(from: template)
        } label: {
            HStack(spacing: 12) {
                Text(template.emoji)
                    .font(.title2)
                    .frame(width: 36)

                Text(template.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addHabit(from template: HabitTemplate) {
        let habit = Habit(
            name: template.name,
            emoji: template.emoji,
            colorHex: template.colorHex
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
