import SwiftUI
import SwiftData
import OSLog
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Template Model

struct HabitTemplate: Identifiable {
    let id = UUID()
    /// English, and the lookup key into Localizable.strings. Show and save `displayName`.
    let name: String
    let emoji: String
    let colorHex: String
    let category: String
    /// What the habit is created as (RELEASE-1.4.1.md D15): a count template starts with its
    /// daily goal and unit set, as AddHabitView's Measurable type saves them.
    let kind: HabitKind
    /// A count template's daily goal (`Habit.targetValue`); 1, and unused, for yes/no.
    let target: Int
    /// A count template's unit as a catalog key (one of W0's template units: "km", "glasses",
    /// "hours" are in use), never shown or saved as it is: see `displayUnit`. nil for yes/no.
    let unit: String?

    init(name: String, emoji: String, colorHex: String, category: String,
         kind: HabitKind = .binary, target: Int = 1, unit: String? = nil) {
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.category = category
        self.kind = kind
        self.target = target
        self.unit = unit
    }

    /// The name in the app's language — also what the created habit is called, so a Japanese
    /// user picking "Drink Water" gets a habit named in Japanese.
    @MainActor
    var displayName: String { appLocalized(String.LocalizationValue(name)) }

    /// The unit in the app's language, and what the created habit's `unit` holds. `Habit.unit` is
    /// the free text AddHabitView's Unit field saves and every screen shows as it is ("3/8
    /// glasses"), so it is stored translated, as the name is: a Japanese user's water habit reads
    /// "3/8 杯", not "3/8 glasses".
    @MainActor
    var displayUnit: String? { unit.map { appLocalized(String.LocalizationValue($0)) } }
}

// MARK: - Template Data

enum HabitTemplateLibrary {
    @MainActor
    static func displayCategory(_ category: String) -> String {
        appLocalized(String.LocalizationValue(category))
    }

    static let categories = [
        "Health & Fitness",
        "Learning",
        "Productivity",
        "Wellness",
        "Creative",
    ]

    /// Count templates are the ones whose goal a few taps reach: Morning Run 5 km, Drink Water 8
    /// glasses, Sleep 8hrs 8 hours. Every way the app logs a count adds exactly 1 — Today's ring
    /// and its "Add 1", History's stepper, the widget, Siri and the reminder's action — and
    /// nothing enters an amount or completes the day at once. So Walk 10k Steps (10,000 taps a
    /// day, past AddHabitView's 1...1000 goal stepper too), Write 500 Words (500) and Read 30min
    /// (30) stay yes/no, as they were in 1.4.0: one check-in completes the day. They can become
    /// count templates once a count habit can be logged by amount.
    static let templates: [HabitTemplate] = [
        // Health & Fitness
        HabitTemplate(name: "Morning Run", emoji: "\u{1F3C3}", colorHex: "#34C759", category: "Health & Fitness",
                      kind: .count, target: 5, unit: "km"),
        HabitTemplate(name: "Drink Water", emoji: "\u{1F4A7}", colorHex: "#5AC8FA", category: "Health & Fitness",
                      kind: .count, target: 8, unit: "glasses"),
        HabitTemplate(name: "Meditate", emoji: "\u{1F9D8}", colorHex: "#AF52DE", category: "Health & Fitness"),
        HabitTemplate(name: "Exercise", emoji: "\u{1F3CB}\u{FE0F}", colorHex: "#FF9500", category: "Health & Fitness"),
        HabitTemplate(name: "Sleep 8hrs", emoji: "\u{1F4A4}", colorHex: "#007AFF", category: "Health & Fitness",
                      kind: .count, target: 8, unit: "hours"),
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

// MARK: - Adding a template's habit

/// A template's habit, inserted and saved (RELEASE-1.4.1.md D15).
///
/// It used to `try? save()` and dismiss either way: a failed save closed the sheet as if the habit
/// had been added, and left the insert pending in mainContext — which autosaves, and which sync
/// saves on — to land later, or never, with nothing said. Now a failed save takes the new habit
/// back out (only it: `rollback()` would also throw away whatever else mainContext holds unsaved,
/// as AddHabitView's `createGroup` reasons) and the caller says so.
@MainActor
enum HabitTemplateAdd {
    enum Outcome: Equatable {
        /// Saved; the new habit's id.
        case added(UUID)
        /// Nothing added: the habit is out of the context again, and nothing else was touched.
        case saveFailed
    }

    /// The save, as a value, so the hosted tests make it fail.
    struct Environment {
        var save: @MainActor (ModelContext) throws -> Void

        /// The app's own.
        static var live: Environment { Environment(save: { try $0.save() }) }
    }

    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Templates")

    static func add(_ template: HabitTemplate, in context: ModelContext,
                    environment: Environment = .live) -> Outcome {
        let habit = Habit(name: template.displayName, emoji: template.emoji, colorHex: template.colorHex)
        habit.habitKind = template.kind
        if template.kind == .count {
            habit.targetValue = Double(template.target)
            habit.unit = template.displayUnit
        }
        context.insert(habit)
        do {
            try environment.save(context)
            return .added(habit.id)
        } catch {
            context.delete(habit)
            report(error)
            return .saveFailed
        }
    }

    /// Domain and code only, as HabitEntryCommit reports a failed save: Core Data's own error
    /// carries the store's path and the objects in `userInfo`. A no-op under XCTest for Sentry.
    private static func report(_ error: Error) {
        let ns = error as NSError
        logger.error("template add: the save failed (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)); nothing was added")
        #if canImport(Sentry)
        _ = SentrySDK.capture(error: NSError(domain: ns.domain, code: ns.code)) { scope in
            scope.setTag(value: "save", key: "template.step")
        }
        #endif
    }
}

// MARK: - Templates View

struct HabitTemplatesView: View {
    /// Runs after a template's habit is saved, before this sheet dismisses itself: AddHabitView
    /// passes its own `dismiss`, so picking a template there closes both sheets. Never on a
    /// failed save.
    var onAdded: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// nil: the app's own save (`HabitTemplateAdd.Environment.live`); the hosted tests inject one.
    @Environment(\.habitTemplateAdd) private var injectedAdd

    @State private var searchText = ""
    @State private var showSaveError = false
    /// A habit was added and the sheet is going: a second tap during the dismissal must not add
    /// the template again, or call `onAdded` twice.
    @State private var didAdd = false

    /// 36 at the default text size; grows with the emoji so large Dynamic Type sizes don't
    /// truncate it to an ellipsis.
    @ScaledMetric(relativeTo: .title2) private var emojiWidth: CGFloat = 36

    private var filteredTemplates: [String: [HabitTemplate]] {
        let templates: [HabitTemplate]
        if searchText.isEmpty {
            templates = HabitTemplateLibrary.templates
        } else {
            templates = HabitTemplateLibrary.templates.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                HabitTemplateLibrary.displayCategory($0.category).localizedCaseInsensitiveContains(searchText)
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
                    Section(HabitTemplateLibrary.displayCategory(category)) {
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
            .alert("Save Failed", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unable to save your habit. Please try again.")
            }
        }
        #if os(macOS)
        // A List has no ideal height, and a Mac sheet sized to it showed only the title, the
        // search field and Cancel: no template at all (live in 1.4.0; gate 10, 2026-10-22).
        .frame(minWidth: 420, idealWidth: 480, minHeight: 520)
        #endif
    }

    /// A count template's daily goal, "8 glasses a day", in the app's language; nil for yes/no.
    /// Its own key, "%lld %@ a day", not AddHabitView's "%lld %@": that one also carries the free
    /// text a user types as a unit, and stays spaced, while here the unit is one of the catalog's
    /// and each language writes the goal as its template names do — Japanese "1日8杯", as
    /// "8時間眠る", never "8 杯". Through local names, so the scan reads the key.
    private func goalText(_ template: HabitTemplate) -> Text? {
        guard template.kind == .count, let unit = template.displayUnit else { return nil }
        let targetValue = template.target
        return Text("\(targetValue) \(unit) a day")
    }

    private func templateRow(_ template: HabitTemplate) -> some View {
        let goal = goalText(template)
        return Button {
            addHabit(from: template)
        } label: {
            HStack(spacing: 12) {
                Text(template.emoji)
                    .font(.title2)
                    .frame(width: emojiWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(template.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let goal {
                        goal
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Overriding the label drops the merged children, so VoiceOver stops leading every row
        // with the emoji's Unicode name and the trailing plus glyph. The goal is the value.
        .accessibilityLabel("Add \(template.displayName)")
        .accessibilityValue(goal ?? Text(verbatim: ""))
    }

    private func addHabit(from template: HabitTemplate) {
        guard !didAdd else { return }
        switch HabitTemplateAdd.add(template, in: modelContext, environment: injectedAdd ?? .live) {
        case .added:
            didAdd = true
            #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
            onAdded()
            dismiss()
        case .saveFailed:
            showSaveError = true
        }
    }
}

// MARK: - The save environment

/// The `HabitTemplateAdd.Environment` the templates sheet saves with: nil means the app's own
/// (`.live`). The hosted tests put a recording one in, which they can make fail.
private struct HabitTemplateAddKey: EnvironmentKey {
    static var defaultValue: HabitTemplateAdd.Environment? { nil }
}

extension EnvironmentValues {
    var habitTemplateAdd: HabitTemplateAdd.Environment? {
        get { self[HabitTemplateAddKey.self] }
        set { self[HabitTemplateAddKey.self] = newValue }
    }
}
