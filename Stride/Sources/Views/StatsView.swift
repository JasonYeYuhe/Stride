import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    @State private var selectedHabit: Habit?
    @State private var showingWeeklyReview = false

    var body: some View {
        statsContent
    }

    private var statsContent: some View {
        ScrollView {
            if habits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                    Text("No habits yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Add a habit to start seeing statistics.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 100)
            } else {
                VStack(spacing: 20) {
                    OverallStatsCard(habits: habits)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(habits) { habit in
                                HabitChip(
                                    habit: habit,
                                    isSelected: selectedHabit?.id == habit.id
                                )
                                .onTapGesture {
                                    withAnimation {
                                        selectedHabit = habit
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let habit = selectedHabit ?? habits.first {
                        VStack(spacing: 16) {
                            HabitDetailStatsCard(habit: habit)
                            WeeklyBarChart(habit: habit)
                            HeatmapView(habit: habit)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
        .background(Color.appBackground)
        .navigationTitle("Statistics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingWeeklyReview = true
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
            }
        }
        .sheet(isPresented: $showingWeeklyReview) {
            WeeklyReviewView()
        }
        .onAppear {
            if selectedHabit == nil {
                selectedHabit = habits.first
            }
        }
    }
}

// MARK: - Overall Stats
struct OverallStatsCard: View {
    let habits: [Habit]

    private var todayCount: Int {
        habits.filter { $0.isCompletedOn(Date()) }.count
    }

    private var bestStreak: Int {
        habits.map { $0.currentStreak() }.max() ?? 0
    }

    private var avgCompletion: Double {
        guard !habits.isEmpty else { return 0 }
        return habits.map { $0.completionRate() }.reduce(0, +) / Double(habits.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            StatItem(value: "\(todayCount)/\(habits.count)", label: "Today", icon: "checkmark.circle")
            Divider().frame(height: 40)
            StatItem(value: "\(bestStreak)", label: "Best Streak", icon: "flame")
            Divider().frame(height: 40)
            StatItem(value: "\(Int(avgCompletion * 100))%", label: "30d Avg", icon: "chart.line.uptrend.xyaxis")
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
    }
}

struct StatItem: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.green)
            Text(verbatim: value)
                .font(.title3.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Habit Chip
struct HabitChip: View {
    let habit: Habit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(habit.emoji)
            Text(habit.name)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(isSelected ? habit.color.opacity(0.2) : Color.appSecondaryBackground)
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? habit.color : .clear, lineWidth: 1.5)
        )
        .accessibilityLabel("\(habit.name)\(isSelected ? ", selected" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : .isButton)
    }
}

// MARK: - Habit Detail Stats
struct HabitDetailStatsCard: View {
    let habit: Habit
    @State private var showShareSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(habit.emoji)
                    .font(.title2)
                Text(habit.name)
                    .font(.title3.bold())
                Spacer()
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(habit.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share streak")
            }

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(habit.currentStreak())")
                            .font(.title2.bold())
                        Text("days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Best Streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(habit.bestStreak())")
                            .font(.title2.bold())
                        Text("days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("30-Day Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(habit.completionRate() * 100))%")
                        .font(.title2.bold())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(habit.records.count)")
                        .font(.title2.bold())
                }

                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .sheet(isPresented: $showShareSheet) {
            ShareStreakView(habit: habit)
        }
    }
}

// MARK: - Weekly Bar Chart
struct WeeklyBarChart: View {
    let habit: Habit
    private let calendar = Calendar.current

    private var weekdayData: [(symbol: String, count: Int, maxCount: Int)] {
        let counts = habit.completionsPerWeekday()
        let maxCount = counts.values.max() ?? 1
        let symbols = calendar.shortWeekdaySymbols

        return (1...7).map { weekday in
            let index = weekday - 1
            return (
                symbol: symbols[index],
                count: counts[weekday] ?? 0,
                maxCount: maxCount
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Weekday")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(weekdayData, id: \.symbol) { data in
                    VStack(spacing: 4) {
                        Text("\(data.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(data.count > 0 ? habit.color : Color.gray.opacity(0.2))
                            .frame(
                                height: data.maxCount > 0
                                    ? max(4, CGFloat(data.count) / CGFloat(data.maxCount) * 80)
                                    : 4
                            )

                        Text(data.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
    }
}

// MARK: - Heatmap
struct HeatmapView: View {
    let habit: Habit
    private let weeks = 12
    private let calendar = Calendar.current

    private var days: [Date] {
        Date.lastNDays(weeks * 7)
    }

    private var weekColumns: [[Date]] {
        var columns: [[Date]] = []
        var currentWeek: [Date] = []

        for day in days {
            let weekday = calendar.component(.weekday, from: day)
            if weekday == calendar.firstWeekday && !currentWeek.isEmpty {
                columns.append(currentWeek)
                currentWeek = []
            }
            currentWeek.append(day)
        }
        if !currentWeek.isEmpty {
            columns.append(currentWeek)
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.headline)

            HStack(alignment: .top, spacing: 3) {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(0..<7, id: \.self) { i in
                        let symbols = calendar.veryShortWeekdaySymbols
                        let index = (calendar.firstWeekday - 1 + i) % 7
                        Text(symbols[index])
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(weekColumns.indices, id: \.self) { weekIndex in
                            VStack(spacing: 3) {
                                ForEach(weekColumns[weekIndex], id: \.self) { day in
                                    let completed = habit.isCompletedOn(day)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(completed ? habit.color : Color.gray.opacity(0.15))
                                        .frame(width: 14, height: 14)
                                        .accessibilityLabel("\(day.monthYear) \(day.dayNumber), \(completed ? "completed" : "not completed")")
                                }
                                if weekColumns[weekIndex].count < 7 {
                                    ForEach(0..<(7 - weekColumns[weekIndex].count), id: \.self) { _ in
                                        Color.clear.frame(width: 14, height: 14)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                Spacer()
                Text("Less")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 12, height: 12)
                RoundedRectangle(cornerRadius: 2)
                    .fill(habit.color)
                    .frame(width: 12, height: 12)
                Text("More")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
    }
}
