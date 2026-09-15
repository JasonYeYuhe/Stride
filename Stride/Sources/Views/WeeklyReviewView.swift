import SwiftUI
import SwiftData

struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    private let calendar = Calendar.current

    private var weekRange: (start: Date, end: Date) {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysBack = weekday == 1 ? 6 : weekday - 2 // Monday start
        let start = calendar.date(byAdding: .day, value: -daysBack, to: today)!
        return (start, today)
    }

    private var lastWeekRange: (start: Date, end: Date) {
        let start = calendar.date(byAdding: .day, value: -7, to: weekRange.start)!
        let end = calendar.date(byAdding: .day, value: -1, to: weekRange.start)!
        return (start, end)
    }

    // Delegates to the model. The local version divided a raw count of records by elapsed calendar
    // days, ignoring the schedule and count targets, so on a Sunday "Gym — Mon/Wed/Fri" done on all
    // three days scored 43% and was tagged "Needs work", while "Water — 8 glasses" with one glass a
    // day scored 100% and was crowned "Best".
    private func completionRate(for habit: Habit, in range: (start: Date, end: Date)) -> Double {
        habit.completionRate(from: range.start, to: range.end)
    }

    private var overallRate: Double {
        guard !habits.isEmpty else { return 0 }
        return habits.map { completionRate(for: $0, in: weekRange) }.reduce(0, +) / Double(habits.count)
    }

    private var lastWeekOverallRate: Double {
        guard !habits.isEmpty else { return 0 }
        return habits.map { completionRate(for: $0, in: lastWeekRange) }.reduce(0, +) / Double(habits.count)
    }

    private var bestHabit: Habit? {
        habits.max { completionRate(for: $0, in: weekRange) < completionRate(for: $1, in: weekRange) }
    }

    private var needsWorkHabit: Habit? {
        habits.min { completionRate(for: $0, in: weekRange) < completionRate(for: $1, in: weekRange) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Overall progress
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(Color.green.opacity(0.2), lineWidth: 12)
                            Circle()
                                .trim(from: 0, to: overallRate)
                                .stroke(Color.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.6), value: overallRate)

                            VStack(spacing: 2) {
                                Text("\(Int(overallRate * 100))%")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                Text("This Week")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 120, height: 120)

                        let diff = overallRate - lastWeekOverallRate
                        if abs(diff) > 0.01 {
                            HStack(spacing: 4) {
                                Image(systemName: diff > 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption.bold())
                                Text("\(Int(abs(diff) * 100))% vs last week")
                                    .font(.caption)
                            }
                            .foregroundStyle(diff > 0 ? .green : .orange)
                        }
                    }
                    .padding(.top)

                    // Per-habit breakdown
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Habit Breakdown")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(habits) { habit in
                            let rate = completionRate(for: habit, in: weekRange)
                            HStack(spacing: 12) {
                                Text(habit.emoji)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(habit.name)
                                        .font(.subheadline.weight(.medium))

                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.green.opacity(0.15))
                                                .frame(height: 8)
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(habit.color)
                                                .frame(width: geo.size.width * rate, height: 8)
                                        }
                                    }
                                    .frame(height: 8)
                                }

                                Text("\(Int(rate * 100))%")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Highlights
                    if habits.count >= 2 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Highlights")
                                .font(.headline)
                                .padding(.horizontal)

                            if let best = bestHabit {
                                HStack(spacing: 10) {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                    Text("Best: \(best.emoji) \(best.name)")
                                        .font(.subheadline)
                                }
                                .padding(.horizontal)
                            }

                            if let worst = needsWorkHabit, worst.id != bestHabit?.id {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.up.heart.fill")
                                        .foregroundStyle(.orange)
                                    Text("Needs work: \(worst.emoji) \(worst.name)")
                                        .font(.subheadline)
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    Spacer(minLength: 40)
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Weekly Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
