import SwiftUI
import SwiftData

struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    /// Every rate the review shows, from ONE `HabitStats` per habit (StatsCache) for the whole
    /// render. The rates are the model's rule (`countedRate(ofWeekStarting:)`). The local version
    /// divided a raw count of records by elapsed calendar days, ignoring the schedule and count
    /// targets, so on a Sunday "Gym — Mon/Wed/Fri" done on all three days scored 43% and was
    /// tagged "Needs work", while "Water — 8 glasses" with one glass a day scored 100% and was
    /// crowned "Best".
    ///
    /// This week ends yesterday until today is done (`HabitStats.thisWeekRate`), as Insights'
    /// momentum: counted as a miss, today made every Monday before the check-in 0% and "Down 100%
    /// vs last week". What the numbers may say — a rate only with something to count, a Best and
    /// Needs work only when alone — is `StatsInsights.weeklyReview` (2026-10-22).
    ///
    /// Built once per render and never kept (W1's carried "per-call wrapper cost"): through the
    /// `Habit` wrappers the body asked about 11 rates per habit, each building its own
    /// `HabitStats` with a store query — ~270 ms for 10 habits × 730 records.
    private struct Summary {
        /// This week's rate of each habit, in `habits`' order; nil: nothing to count yet.
        let rates: [Double?]
        let overall: Double?
        let change: Double?
        let best: Habit?
        let needsWork: Habit?
    }

    private func summary() -> Summary {
        let stats = StatsCache.shared.stats(for: habits)
        let review = StatsInsights.weeklyReview(thisWeek: stats.map(\.thisWeekRate),
                                                lastWeek: stats.map(\.lastWeekRate))
        return Summary(rates: review.rates,
                       overall: review.overall,
                       change: review.change,
                       best: review.best.map { habits[$0] },
                       needsWork: review.needsWork.map { habits[$0] })
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
                    .accessibilityLabel(summary.overall.map { Text("This week, \(Int($0 * 100)) percent complete") } ?? Text("This Week"))
                    .accessibilityValue(summary.overall == nil ? Text("Not started") : Text(verbatim: ""))

                if let diff = summary.change {
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

                            // Nothing to count yet (Monday before the check-in, or nothing due so
                            // far): no bar and a dash, never an empty bar that reads as 0%.
                            GeometryReader { geo in
                                if let rate {
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.green.opacity(0.15))
                                            .frame(height: 8)
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(habit.color)
                                            .frame(width: geo.size.width * rate, height: 8)
                                    }
                                }
                            }
                            .frame(height: 8)
                        }

                        Group {
                            if let rate {
                                Text("\(Int(rate * 100))%")
                            } else {
                                Text(verbatim: "–")
                            }
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rate.map { Text("\(habit.emoji) \(habit.name), \(Int($0 * 100)) percent") }
                                        ?? Text(verbatim: "\(habit.emoji) \(habit.name)"))
                    .accessibilityValue(rate == nil ? Text("Not started") : Text(verbatim: ""))
                }
            }

            // Highlights: only a habit alone at the top or the bottom (StatsInsights.weeklyReview).
            if summary.best != nil || summary.needsWork != nil {
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
    /// Nil: nothing to count yet this week — an empty ring and a dash, not 0%.
    let rate: Double?
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 120
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.2), lineWidth: 12)
            Circle()
                .trim(from: 0, to: rate ?? 0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: rate)

            VStack(spacing: 2) {
                Group {
                    if let rate {
                        Text("\(Int(rate * 100))%")
                    } else {
                        Text(verbatim: "–")
                    }
                }
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
