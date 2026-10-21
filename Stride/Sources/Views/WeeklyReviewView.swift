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

    /// Every rate the review shows, from ONE `HabitStats` per habit (StatsCache) for the whole
    /// render. The rates are the model's rule (`completionRate(from:to:)`). The local version
    /// divided a raw count of records by elapsed calendar days, ignoring the schedule and count
    /// targets, so on a Sunday "Gym — Mon/Wed/Fri" done on all three days scored 43% and was
    /// tagged "Needs work", while "Water — 8 glasses" with one glass a day scored 100% and was
    /// crowned "Best".
    ///
    /// Built once per render and never kept (W1's carried "per-call wrapper cost"): through the
    /// `Habit` wrappers the body asked about 11 rates per habit, each building its own
    /// `HabitStats` with a store query — ~270 ms for 10 habits × 730 records.
    private struct Summary {
        /// This week's rate of each habit, in `habits`' order.
        let rates: [Double]
        let overall: Double
        let lastWeekOverall: Double
        let best: Habit?
        let needsWork: Habit?
    }

    private func summary() -> Summary {
        let stats = StatsCache.shared.stats(for: habits)
        let week = weekRange, lastWeek = lastWeekRange
        let rates = stats.map { $0.completionRate(from: week.start, to: week.end) }
        let lastRates = stats.map { $0.completionRate(from: lastWeek.start, to: lastWeek.end) }
        // As `max(by:)` / `min(by:)` over the habits picked them: the first of equal rates.
        var best: Int?, worst: Int?
        for (index, rate) in rates.enumerated() {
            if best.map({ rates[$0] < rate }) ?? true { best = index }
            if worst.map({ rate < rates[$0] }) ?? true { worst = index }
        }
        let count = Double(max(1, habits.count))
        return Summary(rates: rates,
                       overall: rates.reduce(0, +) / count,
                       lastWeekOverall: lastRates.reduce(0, +) / count,
                       best: best.map { habits[$0] },
                       needsWork: worst.map { habits[$0] })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if habits.isEmpty {
                    emptyState
                } else {
                    review(summary())
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
        #if os(macOS)
        // A ScrollView has no ideal height, and a Mac sheet sized to it is a sliver: Stats' toolbar
        // button and View → Weekly Review both open it (sheet audit, 2026-10-22).
        .frame(minWidth: 420, idealWidth: 480, minHeight: 520)
        #endif
    }

    // Stats hides its Weekly Review button when there are no habits, but this sheet can still
    // be open when the last one goes — archived on another device and pulled by sync, or
    // erased. It showed a 0% ring over an empty "Habit Breakdown" heading, as if every habit
    // had been missed. Same wording as the Stats empty state.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .scaledSystemFont(size: 50, relativeTo: .largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            Text("No habits yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Add a habit to start seeing statistics.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 100)
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
    }

    private func review(_ summary: Summary) -> some View {
        VStack(spacing: 20) {
            // Overall progress
            VStack(spacing: 12) {
                WeeklyRateRing(rate: summary.overall)
                    // Past .accessibility2 the ring only pushes the per-habit rows — the part
                    // with the detail — further down; its number is already about 1.5x body there.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .accessibilityElement(children: .ignore)
                .accessibilityLabel("This week, \(Int(summary.overall * 100)) percent complete")

                let diff = summary.overall - summary.lastWeekOverall
                if abs(diff) > 0.01 {
                    HStack(spacing: 4) {
                        Image(systemName: diff > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption.bold())
                        Text("\(Int(abs(diff) * 100))% vs last week")
                            .font(.caption)
                    }
                    .foregroundStyle(diff > 0 ? .green : .orange)
                    .accessibilityElement(children: .ignore)
                    // Direction lives in the arrow glyph and the tint; neither reaches VoiceOver.
                    .accessibilityLabel(diff > 0
                        ? "Up \(Int(abs(diff) * 100)) percent vs last week"
                        : "Down \(Int(abs(diff) * 100)) percent vs last week")
                }
            }
            .padding(.top)

            // Per-habit breakdown
            VStack(alignment: .leading, spacing: 12) {
                Text("Habit Breakdown")
                    .font(.headline)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(habits.enumerated()), id: \.element.id) { index, habit in
                    let rate = summary.rates[index]
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(habit.emoji) \(habit.name), \(Int(rate * 100)) percent")
                }
            }

            // Highlights
            if habits.count >= 2 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Highlights")
                        .font(.headline)
                        .padding(.horizontal)
                        .accessibilityAddTraits(.isHeader)

                    if let best = summary.best {
                        HStack(spacing: 10) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            Text("Best: \(best.emoji) \(best.name)")
                                .font(.subheadline)
                        }
                        .padding(.horizontal)
                    }

                    if let worst = summary.needsWork, worst.id != summary.best?.id {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.heart.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
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
}

/// The week's overall rate: a number inside a ring.
///
/// The number was a fixed 36 pt and the ring a fixed 120 pt, so at the accessibility sizes the
/// caption under the number grew into a ring that did not. Both now scale with `.largeTitle`
/// (the number is the screen's headline figure) through `@ScaledMetric`, which returns the base
/// value exactly at the default size — so the default layout, and the store screenshots, do not
/// move. A separate view because the caller's `.dynamicTypeSize(...)` cap has to be in the
/// environment the scaled metrics read; on `WeeklyReviewView` itself they would read the
/// uncapped size.
private struct WeeklyRateRing: View {
    let rate: Double
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 120
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: rate)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: rate)

            VStack(spacing: 2) {
                Text("\(Int(rate * 100))%")
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                Text("This Week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // .caption grows faster than .largeTitle, so at the larger sizes the words
                    // reached the stroke ("Esta semana" did from xxxLarge). Kept inside the
                    // ring's inner chord; at the default size every caption fits unshrunk.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 18)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
