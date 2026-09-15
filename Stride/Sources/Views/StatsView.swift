import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    // An id, not a Habit. Holding the @Model object in @State kept it alive outside the @Query
    // result set, and nothing cleared it when that habit was deleted — in Settings, or with no
    // user action at all by a sync tombstone from another device. The next render then read
    // properties of an invalidated model. Resolving the id against the live query can't do that.
    @State private var selectedHabitID: UUID?

    private var selectedHabit: Habit? {
        habits.first { $0.id == selectedHabitID } ?? habits.first
    }
    @State private var showingWeeklyReview = false
    @State private var showingPaywall = false
    private var store = StoreService.shared

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
                                        selectedHabitID = habit.id
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let habit = selectedHabit {
                        VStack(spacing: 16) {
                            HabitDetailStatsCard(habit: habit)
                            if store.isPro {
                                InsightsCard(habit: habit)
                                TrendCard(habit: habit)
                            } else {
                                ProLockedCard(
                                    title: "Advanced Analytics",
                                    message: "8-week trends, insights & weekly review"
                                ) { showingPaywall = true }
                            }
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
                    if store.isPro { showingWeeklyReview = true } else { showingPaywall = true }
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
            }
        }
        .sheet(isPresented: $showingWeeklyReview) {
            WeeklyReviewView()
        }
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView()
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
                        Text(habit.streakUnit == "week" ? "weeks" : "days")
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

// MARK: - Pro Locked Card
struct ProLockedCard: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Unlock with Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.green))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trend (last 8 weeks completion rate)
struct TrendCard: View {
    let habit: Habit
    private let utc = HabitCalendar.utc
    private let weekCount = 8

    private struct WeekPoint: Identifiable {
        let id = UUID()
        let label: String
        let rate: Double
    }

    private var points: [WeekPoint] {
        // Monday-anchored weeks ending with the current week.
        let todayKey = HabitCalendar.dayKey(for: Date())
        let weekday = utc.component(.weekday, from: todayKey)
        let daysFromMonday = (weekday + 5) % 7
        guard let thisWeekStart = utc.date(byAdding: .day, value: -daysFromMonday, to: todayKey) else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        fmt.timeZone = TimeZone(identifier: "UTC")

        return (0..<weekCount).reversed().compactMap { back in
            guard let start = utc.date(byAdding: .day, value: -7 * back, to: thisWeekStart),
                  let end = utc.date(byAdding: .day, value: 6, to: start) else { return nil }
            return WeekPoint(label: fmt.string(from: start), rate: habit.completionRate(from: start, to: end))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("8-Week Trend")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(points) { point in
                    VStack(spacing: 4) {
                        Text("\(Int(point.rate * 100))")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(point.rate > 0 ? habit.color.opacity(0.4 + 0.6 * point.rate) : Color.gray.opacity(0.2))
                            .frame(height: max(4, CGFloat(point.rate) * 80))
                        Text(point.label)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }
}

// MARK: - Insights (best/worst day, momentum)
struct InsightsCard: View {
    let habit: Habit
    private let utc = HabitCalendar.utc

    private var insights: [(icon: String, text: String)] {
        var out: [(String, String)] = []
        let symbols = Calendar.current.weekdaySymbols // index 0 = Sunday
        let counts = habit.completionsPerWeekday()    // keys 1...7

        if let best = counts.max(by: { $0.value < $1.value }), best.value > 0 {
            out.append(("star.fill", "Strongest on \(symbols[best.key - 1])"))
        }
        // Toughest = scheduled weekday with the fewest completions
        let scheduledWeekdays = (1...7).filter { weekdayScheduled($0) }
        if scheduledWeekdays.count > 1,
           let worst = scheduledWeekdays.min(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) {
            out.append(("exclamationmark.triangle", "Toughest on \(symbols[worst - 1])"))
        }

        // Momentum: this week vs last week
        let todayKey = HabitCalendar.dayKey(for: Date())
        let weekday = utc.component(.weekday, from: todayKey)
        let daysFromMonday = (weekday + 5) % 7
        if let thisStart = utc.date(byAdding: .day, value: -daysFromMonday, to: todayKey),
           let lastStart = utc.date(byAdding: .day, value: -7, to: thisStart),
           let lastEnd = utc.date(byAdding: .day, value: -1, to: thisStart) {
            let thisRate = habit.completionRate(from: thisStart, to: todayKey)
            let lastRate = habit.completionRate(from: lastStart, to: lastEnd)
            if lastRate > 0 || thisRate > 0 {
                if thisRate >= lastRate {
                    out.append(("arrow.up.right", "Up vs last week (\(Int(lastRate*100))% → \(Int(thisRate*100))%)"))
                } else {
                    out.append(("arrow.down.right", "Down vs last week (\(Int(lastRate*100))% → \(Int(thisRate*100))%)"))
                }
            }
        }
        return out
    }

    private func weekdayScheduled(_ weekday: Int) -> Bool {
        switch habit.schedule {
        case .daily, .timesPerWeek: return true
        case .specificDays: return (habit.activeDaysMask & (1 << (weekday - 1))) != 0
        }
    }

    var body: some View {
        let items = insights
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Insights")
                    .font(.headline)
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Image(systemName: items[i].icon)
                            .font(.caption)
                            .foregroundStyle(habit.color)
                            .frame(width: 18)
                        Text(items[i].text)
                            .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
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
