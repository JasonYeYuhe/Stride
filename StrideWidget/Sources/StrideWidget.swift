import WidgetKit
import SwiftUI
import SwiftData

// MARK: - Timeline Entry

struct HabitEntry: TimelineEntry {
    let date: Date
    let habits: [HabitSnapshot]
    let completedCount: Int
    let totalCount: Int

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    static var placeholder: HabitEntry {
        HabitEntry(
            date: .now,
            habits: [
                HabitSnapshot(name: "Exercise", emoji: "💪", colorHex: "#34C759", isCompleted: true, streak: 5),
                HabitSnapshot(name: "Read", emoji: "📚", colorHex: "#007AFF", isCompleted: true, streak: 3),
                HabitSnapshot(name: "Meditate", emoji: "🧘", colorHex: "#AF52DE", isCompleted: false, streak: 0),
            ],
            completedCount: 2,
            totalCount: 3
        )
    }

    static var empty: HabitEntry {
        HabitEntry(date: .now, habits: [], completedCount: 0, totalCount: 0)
    }
}

struct HabitSnapshot: Identifiable {
    let id = UUID()
    let name: String
    let emoji: String
    let colorHex: String
    let isCompleted: Bool
    let streak: Int

    var color: Color {
        Color(hex: colorHex) ?? .green
    }
}

// MARK: - Timeline Provider

struct HabitTimelineProvider: TimelineProvider {
    let modelContainer: ModelContainer

    func placeholder(in context: Context) -> HabitEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (HabitEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(fetchEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HabitEntry>) -> Void) {
        let entry = fetchEntry()

        // Refresh at the start of the next day so the widget resets
        let calendar = Calendar.current
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: .now)!)
        let timeline = Timeline(entries: [entry], policy: .after(tomorrow))

        completion(timeline)
    }

    private func fetchEntry() -> HabitEntry {
        let context = ModelContext(modelContainer)
        let today = Calendar.current.startOfDay(for: .now)

        do {
            let descriptor = FetchDescriptor<Habit>(
                predicate: #Predicate<Habit> { !$0.isArchived },
                sortBy: [SortDescriptor(\Habit.createdAt)]
            )
            let habits = try context.fetch(descriptor)

            let snapshots = habits.map { habit in
                HabitSnapshot(
                    name: habit.name,
                    emoji: habit.emoji,
                    colorHex: habit.colorHex,
                    isCompleted: habit.isCompletedOn(today),
                    streak: habit.currentStreak(from: today)
                )
            }

            let completedCount = snapshots.filter(\.isCompleted).count

            return HabitEntry(
                date: .now,
                habits: snapshots,
                completedCount: completedCount,
                totalCount: habits.count
            )
        } catch {
            return .empty
        }
    }
}

// MARK: - Widget Views

/// Small widget: Progress ring + count
struct SmallWidgetView: View {
    let entry: HabitEntry

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: entry.progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(entry.completedCount)")
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                    Text("of \(entry.totalCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, height: 70)

            Text(smallStatusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var smallStatusText: String {
        if entry.totalCount == 0 { return "No habits yet" }
        if entry.completedCount == entry.totalCount { return "All done! 🎉" }
        return "\(entry.totalCount - entry.completedCount) remaining"
    }
}

/// Medium widget: Progress + habit list
struct MediumWidgetView: View {
    let entry: HabitEntry

    var body: some View {
        HStack(spacing: 12) {
            // Left: Progress ring
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.2), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: entry.progress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(entry.progress * 100))%")
                        .font(.callout.bold())
                }
                .frame(width: 56, height: 56)

                Text("Today")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 72)

            // Right: Habit list
            VStack(alignment: .leading, spacing: 4) {
                let displayHabits = Array(entry.habits.prefix(4))

                ForEach(displayHabits) { habit in
                    HStack(spacing: 6) {
                        Text(habit.emoji)
                            .font(.caption)

                        Text(habit.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: habit.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(habit.isCompleted ? habit.color : .gray.opacity(0.4))
                    }
                }

                if entry.habits.count > 4 {
                    Text("+\(entry.habits.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if entry.habits.isEmpty {
                    Text("Tap to add habits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Lock screen circular widget
struct LockScreenCircularView: View {
    let entry: HabitEntry

    var body: some View {
        Gauge(value: entry.progress) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            Text("\(entry.completedCount)")
                .font(.system(.body, design: .rounded).bold())
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Lock screen inline widget
struct LockScreenInlineView: View {
    let entry: HabitEntry

    var body: some View {
        if entry.totalCount == 0 {
            Text("Stride: No habits yet")
        } else if entry.completedCount == entry.totalCount {
            Text("🔥 All \(entry.totalCount) habits done!")
        } else {
            Text("🏃 \(entry.completedCount)/\(entry.totalCount) habits done")
        }
    }
}

/// Lock screen rectangular widget
struct LockScreenRectangularView: View {
    let entry: HabitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Stride")
                    .font(.caption.bold())
                Spacer()
                Text("\(entry.completedCount)/\(entry.totalCount)")
                    .font(.caption.bold())
            }

            let displayHabits = Array(entry.habits.prefix(3))
            ForEach(displayHabits) { habit in
                HStack(spacing: 4) {
                    Text(habit.emoji)
                        .font(.caption2)
                    Text(habit.name)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: habit.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(habit.isCompleted ? .primary : .secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct StrideWidget: Widget {
    let kind = "StrideWidget"

    private let modelContainer: ModelContainer

    init() {
        self.modelContainer = SharedModelContainer.modelContainer
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: HabitTimelineProvider(modelContainer: modelContainer)
        ) { entry in
            StrideWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Stride Habits")
        .description("Track your daily habit progress at a glance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular,
        ])
    }
}

struct StrideWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: HabitEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .accessoryCircular:
            LockScreenCircularView(entry: entry)
        case .accessoryInline:
            LockScreenInlineView(entry: entry)
        case .accessoryRectangular:
            LockScreenRectangularView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Bundle

@main
struct StrideWidgetBundle: WidgetBundle {
    var body: some Widget {
        StrideWidget()
    }
}
