import SwiftUI

// The Pro cards M4 adds to Statistics (RELEASE-1.4.1.md D10), shown inside StatsView's
// `store.isPro` branch after InsightsCard and TrendCard; ProLockedCard sells them for everyone
// else, in D11's words ("the strength chart and your top 5 streaks"). The free tier keeps the
// detail card's Best Streak tile, and its fourth tile is the Strength score (D10, O7), so no copy
// sells "your best streaks" as Pro.
//
// Both read the `HabitStats` StatsView takes from StatsCache once per render (D3), never
// `Habit`'s wrappers, and keep it no longer than the render. Their `-statsScrollTo` anchors are
// `strength` and `beststreaks` (StatsView.scrollToLaunchAnchor).

/// Strength, 0–100 (D9): the score, its change over 30 and 90 days, and the score at the end of
/// each of the last 8 Monday-anchored weeks as bars in TrendCard's hand-rolled style (no Swift
/// Charts), under D9's one-sentence explanation. From `HabitStats.strength`,
/// `strengthDelta30`/`strengthDelta90` and `weeklyStrength`.
struct StrengthCard: View {
    let habit: Habit
    /// This render's stats (StatsView).
    let stats: HabitStats
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Room for the value and date labels around the bars, as TrendCard: 30 at the default size.
    @ScaledMetric(relativeTo: .caption2) private var labelRoom: CGFloat = 30

    private struct WeekPoint: Identifiable {
        /// The week's Monday (a day-key): stable across renders.
        let id: Date
        let label: String
        /// Spoken instead of `label` (StatsWeeks.spoken).
        let spokenDate: String
        /// The score at the end of the week (today's, for this week), 0…1.
        let score: Double
        /// As drawn: 0–100.
        let value: Int
    }

    /// The weeks TrendCard draws, oldest first; `weeklyStrength` buckets the same Mondays.
    private var points: [WeekPoint] {
        let spoken = StatsWeeks.spoken
        let mondays = StatsWeeks.mondays(endingWithWeekOf: stats.today)
        return zip(mondays, stats.weeklyStrength).map { start, score in
            WeekPoint(id: start, label: StatsWeeks.label.string(from: start), spokenDate: start.formatted(spoken),
                      score: score, value: HabitScore.displayValue(score))
        }
    }

    /// The change drawn beside the score, in the points the card shows: the score now minus the
    /// score `delta` ago, each rounded as drawn — so "74" over "+5" always means it read 69 then,
    /// where rounding the difference itself could say +4 or +6. `delta` is
    /// `strengthDelta30`/`strengthDelta90`, in score units.
    nonisolated static func displayedChange(current: Double, delta: Double) -> Int {
        HabitScore.displayValue(current) - HabitScore.displayValue(current - delta)
    }

    var body: some View {
        let score = HabitScore.displayValue(stats.strength)
        let change30 = Self.displayedChange(current: stats.strength, delta: stats.strengthDelta30)
        let change90 = Self.displayedChange(current: stats.strength, delta: stats.strengthDelta90)
        // D9's sentence. The rolling-week clause matters only where the streak counts weeks.
        let explanation: LocalizedStringKey = habit.schedule == .timesPerWeek ? "Strength grows with every check-in and recovers after a miss; it counts a rolling 7 days, the streak counts calendar weeks." : "Strength grows with every check-in and recovers after a miss."
        VStack(alignment: .leading, spacing: 12) {
            // The title and the score are one heading: "Strength, 74".
            HStack(alignment: .firstTextBaseline) {
                Text("Strength")
                    .font(.headline)
                Spacer()
                Text(score, format: .number)
                    .font(.title.bold())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            // Side by side, or stacked at accessibility sizes, as the detail card's tiles.
            let tiles = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 20))
            tiles {
                changeTile(title: "30-Day Change", change: change30)
                changeTile(title: "90-Day Change", change: change90)
                if !typeSize.isAccessibilitySize {
                    Spacer()
                }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            bars
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }

    /// "+5", "−3" or "0", signed in the locale's own way.
    private func changeTile(title: LocalizedStringKey, change: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(change, format: .number.sign(strategy: .always(includingZero: false)))
                .font(.title3.bold())
                .foregroundStyle(change > 0 ? Color.green : change < 0 ? Color.orange : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// TrendCard's bars, of the score instead of the rate: eight columns, or one row per week at
    /// accessibility sizes (eight ~37 pt columns cannot hold "12/28" there).
    private var bars: some View {
        let rows = typeSize.isAccessibilitySize
        let layout = rows
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 6))
        return layout {
            ForEach(points) { point in
                let fill = point.score > 0 ? habit.color.opacity(0.4 + 0.6 * point.score) : Color.gray.opacity(0.2)
                Group {
                    if rows {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(point.label)
                                    .scaledSystemFont(size: 8)
                                Spacer()
                                Text(point.value, format: .number)
                                    .scaledSystemFont(size: 9)
                            }
                            .foregroundStyle(.secondary)
                            HorizontalBar(fraction: point.score, fill: fill)
                        }
                    } else {
                        VStack(spacing: 4) {
                            Text(point.value, format: .number)
                                .scaledSystemFont(size: 9)
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(fill)
                                .frame(height: max(4, CGFloat(point.score) * 80))
                            Text(point.label)
                                .scaledSystemFont(size: 8)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Week of \(point.spokenDate)")
                .accessibilityValue(Text(point.value, format: .number))
            }
        }
        // The tallest bar is 80 pt; the rest is the two labels, so only that part scales.
        .frame(height: rows ? nil : 80 + labelRoom)
    }
}

/// The habit's top 5 runs, longest first, ties to the most recent (`HabitStats.bestStreakRanges`),
/// each with its dates, in the habit's streak unit — scheduled days, or Monday-anchored weeks for
/// times-per-week — and the one still going marked Current.
struct BestStreaksCard: View {
    let habit: Habit
    /// This render's stats (StatsView).
    let stats: HabitStats
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ranges = stats.bestStreakRanges
        let longest = max(1, ranges.first?.length ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Top 5 Streaks")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if ranges.isEmpty {
                Text("No streaks yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ranges, id: \.self) { range in
                    row(range, longest: longest)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }

    /// The unit drawn beside a run's length: the detail card's keys, which carry the count so the
    /// plural rules pick the form. One key per unit, chosen outside the interpolation.
    private func unit(_ count: Int) -> Text {
        habit.streakUnit == "week"
            ? Text("weeks (unit after \(count))")
            : Text("days (unit after \(count))")
    }

    /// One run: its length, its dates, Current when it is still going, and a bar of its length
    /// against the longest. One accessibility element: "12 days, Sep 1 – 12, Current".
    private func row(_ range: HabitStats.StreakRange, longest: Int) -> some View {
        let count = range.length
        let dates = Self.dates(of: range, today: stats.today, locale: appLocale)
        let stacked = typeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(count)")
                        .font(.title3.bold())
                    unit(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !stacked {
                    Text(dates)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if range.isCurrent {
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(habit.color))
                }
            }
            if stacked {
                Text(dates)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HorizontalBar(fraction: Double(count) / Double(longest), fill: habit.color.opacity(range.isCurrent ? 1 : 0.6))
        }
        .accessibilityElement(children: .combine)
    }

    /// A run's dates in `locale`: "Sep 1 – 12" (or "9月1日～12日"), one date for a one-day run, and
    /// the year only when the run is not all inside `today`'s year. Formatted in UTC, because a
    /// day-key is its day's UTC midnight: in any zone west of UTC a local formatter would draw
    /// every date one day early (HabitCalendar.dayKey says why).
    static func dates(of range: HabitStats.StreakRange, today: Date, locale: Locale) -> String {
        let utc = HabitCalendar.utc
        let year = utc.component(.year, from: today)
        let showsYear = utc.component(.year, from: range.start) != year || utc.component(.year, from: range.end) != year
        if range.end <= range.start {
            var style = Date.FormatStyle(locale: locale, calendar: utc, timeZone: utc.timeZone).month(.abbreviated).day()
            if showsYear { style = style.year() }
            return range.start.formatted(style)
        }
        var style = Date.IntervalFormatStyle(locale: locale, calendar: utc, timeZone: utc.timeZone).month(.abbreviated).day()
        if showsYear { style = style.year() }
        return (range.start..<range.end).formatted(style)
    }
}

// MARK: - Trend (last 8 weeks completion rate)
struct TrendCard: View {
    let habit: Habit
    /// This render's stats (StatsView): eight `Habit.completionRate` calls built eight.
    let stats: HabitStats
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Room for the value and date labels around the bars: 30 at the default size, where the
    /// chart was a fixed 110 pt that the labels overflowed as soon as they could grow.
    @ScaledMetric(relativeTo: .caption2) private var labelRoom: CGFloat = 30

    private struct WeekPoint: Identifiable {
        /// The week's Monday: stable across renders (a fresh UUID per render rebuilt every bar).
        let id: Date
        let label: String
        /// Spoken instead of `label` (StatsWeeks.spoken).
        let spokenDate: String
        /// Nil: nothing of the week to count (`HabitStats.countedRate`) — before the habit
        /// started, or this week before anything is due or done. Drawn as no bar and no number,
        /// where it was a grey bar marked 0 like a missed week (2026-10-22).
        let rate: Double?
        /// The week ended before the habit existed (`HabitStats.endsBeforeStart`): only then is a
        /// week without a rate "Not started" to VoiceOver.
        let beforeStart: Bool
    }

    private var points: [WeekPoint] {
        let spoken = StatsWeeks.spoken
        return StatsWeeks.mondays(endingWithWeekOf: stats.today).map { start in
            WeekPoint(
                id: start,
                label: StatsWeeks.label.string(from: start),
                spokenDate: start.formatted(spoken),
                // This week counts today once it is done, as Insights' momentum does.
                rate: stats.countedRate(ofWeekStarting: start),
                beforeStart: stats.endsBeforeStart(weekStarting: start)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("8-Week Trend")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // Eight columns get about 37 pt each: past the largest non-accessibility size "12/28"
            // no longer fits one, so accessibility sizes draw one row per week instead.
            let rows = typeSize.isAccessibilitySize
            let layout = rows
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 6))
            layout {
                ForEach(points) { point in
                    Group {
                        if rows {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(point.label)
                                        .scaledSystemFont(size: 8)
                                    Spacer()
                                    if let rate = point.rate {
                                        Text("\(Int(rate * 100))")
                                            .scaledSystemFont(size: 9)
                                    }
                                }
                                .foregroundStyle(.secondary)
                                if let rate = point.rate {
                                    HorizontalBar(fraction: rate, fill: fill(rate))
                                }
                            }
                        } else {
                            VStack(spacing: 4) {
                                // The column is bottom-aligned: a week with no rate keeps only its
                                // date, under an empty slot.
                                if let rate = point.rate {
                                    Text("\(Int(rate * 100))")
                                        .scaledSystemFont(size: 9)
                                        .foregroundStyle(.secondary)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(fill(rate))
                                        .frame(height: max(4, CGFloat(rate) * 80))
                                }
                                Text(point.label)
                                    .scaledSystemFont(size: 8)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    // Between the default and the accessibility sizes (XL–XXXL)
                                    // "12/28" can outgrow a narrow phone's column by a few points.
                                    .minimumScaleFactor(0.7)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Week of \(point.spokenDate)")
                    // The bar's own label truncates; rounding here would speak a different number.
                    // A week the habit has begun with nothing counted yet says only its date, as
                    // its empty slot: "Not started" was false for it (review of bab8acf, 2026-10-22).
                    .accessibilityValue(point.rate.map { Text(verbatim: "\(Int($0 * 100))%") }
                                        ?? (point.beforeStart ? Text("Not started") : Text(verbatim: "")))
                }
            }
            // The tallest bar is 80 pt; the rest is the two labels, so only that part scales.
            .frame(height: rows ? nil : 80 + labelRoom)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }

    private func fill(_ rate: Double) -> Color {
        rate > 0 ? habit.color.opacity(0.4 + 0.6 * rate) : Color.gray.opacity(0.2)
    }
}

// MARK: - Insights (best/worst day, momentum)
struct InsightsCard: View {
    let habit: Habit
    /// This render's stats (StatsView): the weekday tallies and both weeks read one HabitStats
    /// instead of building three.
    let stats: HabitStats

    // LocalizedStringKey, not String: a String reaches Text() as verbatim content, so these rows
    // rendered in English in every language. Each phrase is built whole so it is one key.
    private var insights: [(icon: String, text: LocalizedStringKey)] { Self.lines(for: stats) }

    /// The card's lines for `stats`, in order; none: the card draws nothing. Static so that
    /// Statistics' locked card counts the very lines this card would draw ("Stride Pro has N
    /// insights about this habit", RELEASE-1.4.2.md D12; extracted by W4, unchanged).
    /// Real insights only: an empty-state or placeholder line (D7's "Not enough recent check-ins
    /// to compare") belongs in the card's body, not here, or the locked card would sell it.
    static func lines(for stats: HabitStats) -> [(icon: String, text: LocalizedStringKey)] {
        var out: [(String, LocalizedStringKey)] = []
        let symbols = appCalendar.weekdaySymbols // index 0 = Sunday

        // A day only when its rate stands alone, and never for times-per-week
        // (StatsInsights.weekdayExtremes): the first of equal counts was "Toughest on Sunday" for a
        // user who never misses, and the strongest day changed between launches (2026-10-22).
        let days = StatsInsights.weekdayExtremes(stats.weekdayTallies, schedule: stats.schedule,
                                                 activeDaysMask: stats.activeDaysMask)
        if let best = days.strongest {
            out.append(("star.fill", "Strongest on \(symbols[best - 1])"))
        }
        if let worst = days.toughest {
            out.append(("exclamationmark.triangle", "Toughest on \(symbols[worst - 1])"))
        }

        // Momentum: this week so far (an unfinished today is not a miss yet) vs last week.
        if let momentum = StatsInsights.momentum(thisWeek: stats.thisWeekRate, lastWeek: stats.lastWeekRate) {
            // Formatted outside the key so the key carries no literal "%" to escape.
            let was = "\(momentum.was)%"
            let now = "\(momentum.now)%"
            if momentum.isUp {
                out.append(("arrow.up.right", "Up vs last week (\(was) → \(now))"))
            } else {
                out.append(("arrow.down.right", "Down vs last week (\(was) → \(now))"))
            }
        }
        return out
    }

    var body: some View {
        let items = insights
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Insights")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Image(systemName: items[i].icon)
                            .font(.caption)
                            .foregroundStyle(habit.color)
                            .frame(width: 18)
                            .accessibilityHidden(true)
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
