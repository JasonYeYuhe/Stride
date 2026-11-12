import SwiftUI
import SwiftData

struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    /// Every number here comes from the cache Statistics reads (RELEASE-1.4.2.md D8): the app's
    /// one, or the one a hosted test put in the environment over a store of its own. 1.4.1 read
    /// `StatsCache.shared`, so no test could hold it.
    @Environment(\.statsCache) private var cache
    @Environment(\.colorScheme) private var colorScheme
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    /// Any day of the week asked for (`ShellRequest.weeklyReview(week:)`: Today's card asks for
    /// last week), or nil for the review's own choice (`WeeklyReviewMath.openingWeek`).
    private let requestedWeek: Date?
    #if DEBUG
    /// The hosted tests' clock (WeeklyReviewRenderTests): a fixed instant, so a test can stand on
    /// a Monday or a Thursday. Nil: the real clock.
    private let fixedNow: Date?
    #endif

    init(week: Date? = nil) {
        requestedWeek = week
        #if DEBUG
        fixedNow = nil
        #endif
    }

    #if DEBUG
    /// The review as it reads at `now` (hosted tests only).
    init(week: Date? = nil, now: Date) {
        requestedWeek = week
        fixedNow = now
    }
    #endif

    private var now: Date {
        #if DEBUG
        fixedNow ?? Date()
        #else
        Date()
        #endif
    }

    /// The review of the opening week (D8), from ONE `HabitStats` per habit (StatsCache) for the
    /// whole render, never kept: every rate is the model's rule (`countedRate(ofWeekStarting:)`),
    /// and what may be said about them — the change and the highlights, each only from a finished
    /// week or from a habit's fourth counted day — is `WeeklyReviewMath.review`.
    ///
    /// 1.4.1 showed this week only: every Monday before the check-in each habit with months of
    /// history was a dash, and so was the ring; Best and Needs work were picked by raw percentage,
    /// and a change in points was labelled "%". Monday to Wednesday it now opens on last week.
    private struct Summary {
        let opening: WeeklyReviewMath.OpeningWeek
        let review: WeeklyReviewMath.Review
        /// Today's day-key: whether the dates need their year.
        let today: Date
    }

    private func summary() -> Summary {
        let now = self.now
        let calendar = Calendar.current
        let opening = WeeklyReviewMath.openingWeek(now: now, calendar: calendar, requested: requestedWeek)
        let stats = cache.stats(for: habits, today: now, calendar: calendar)
        let inputs = zip(habits, stats).map { WeeklyReviewMath.HabitInput(habit: $0, stats: $1) }
        return Summary(opening: opening,
                       review: WeeklyReviewMath.review(of: inputs, week: opening.week),
                       today: HabitCalendar.dayKey(forInstant: now, calendar: calendar))
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
        // button and View → Weekly Review both open it (sheet audit, 2026-10-22). D8: ideally
        // 560 × 680, never below 420 × 520.
        .frame(minWidth: 420, idealWidth: 560, minHeight: 520, idealHeight: 680)
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

    // MARK: - The week

    /// The week's dates in the picked language: "Nov 3 – 9" ("11月3日～9日"), with the year only
    /// when the week is not all inside today's year. Formatted in UTC, because a day-key is its
    /// day's UTC midnight: west of UTC a local formatter would draw every date a day early (as
    /// `BestStreaksCard.dates`).
    static func dates(of week: WeeklyReviewMath.WeekRange, today: Date, locale: Locale) -> String {
        let utc = HabitCalendar.utc
        let year = utc.component(.year, from: today)
        var style = Date.IntervalFormatStyle(locale: locale, calendar: utc, timeZone: utc.timeZone).month(.abbreviated).day()
        if utc.component(.year, from: week.monday) != year || utc.component(.year, from: week.sunday) != year {
            style = style.year()
        }
        return (week.monday..<week.sunday).formatted(style)
    }

    /// "This week so far" from its fourth day, or "Last week", each over its dates; an earlier
    /// week asked for is titled by its dates (the copy deck has no other name for it).
    private func header(_ summary: Summary) -> some View {
        let dates = Self.dates(of: summary.opening.week, today: summary.today, locale: appLocale)
        return VStack(spacing: 4) {
            Group {
                switch summary.opening.relation {
                case .thisWeek: Text("This week so far")
                case .lastWeek: Text("Last week")
                case .earlier: Text(verbatim: dates)
                }
            }
            .font(.title3.bold())
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            if summary.opening.relation != .earlier {
                Text(verbatim: dates)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    /// The ring's words to VoiceOver, by the week it shows.
    private func ringLabel(_ rate: Double, relation: WeeklyReviewMath.Relation) -> Text {
        let percent = StatsInsights.percent(rate)
        switch relation {
        case .thisWeek: return Text("This week, \(percent) percent complete")
        case .lastWeek: return Text("Last week: \(percent)%")
        case .earlier: return Text("\(percent)%")
        }
    }

    /// A rise in the palette's Green, a drop in its Orange, as readable text (D8, as StrengthCard's
    /// changes): the system green and orange were about 2:1 on the light background.
    private func changeColor(_ points: Int) -> Color {
        points > 0 ? Color.readableText(hex: StrengthCard.riseHex, in: colorScheme)
            : points < 0 ? Color.readableText(hex: StrengthCard.dropHex, in: colorScheme)
            : Color.secondary
    }

    /// "+12 points vs previous week" or "−5 points vs previous week" (the stringsdict plurals; a
    /// drop is passed as a positive number after "−"), or "Level with the previous week".
    private func changeText(_ points: Int) -> Text {
        if points > 0 { return Text("+\(points) points vs previous week") }
        if points < 0 {
            let points = -points
            return Text("−\(points) points vs previous week")
        }
        return Text("Level with the previous week")
    }

    private func review(_ summary: Summary) -> some View {
        let review = summary.review
        return VStack(spacing: 20) {
            VStack(spacing: 12) {
                header(summary)

                // Nothing to count in the whole week (every habit began after it): no ring, rather
                // than a dash that reads as a missed week.
                if let overall = review.overall {
                    WeeklyRateRing(rate: overall)
                        // Past .accessibility2 the ring only pushes the per-habit rows — the part
                        // with the detail — further down; its number is already about 1.5x body there.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(ringLabel(overall, relation: summary.opening.relation))
                }

                // Points, never "%" (D8): each habit against itself, and in a week not over only
                // from a habit's fourth counted day (`WeeklyReviewMath.review`).
                if let points = review.changePoints {
                    HStack(spacing: 4) {
                        if points != 0 {
                            Image(systemName: points > 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption.bold())
                                .accessibilityHidden(true)
                        }
                        changeText(points)
                            .font(.caption)
                    }
                    .foregroundStyle(changeColor(points))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top)

            // Per-habit breakdown
            VStack(alignment: .leading, spacing: 12) {
                Text("Habit Breakdown")
                    .font(.headline)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)

                ForEach(review.rows, id: \.index) { row in
                    breakdownRow(habits[row.index], row: row)
                }
            }

            highlights(review)

            Spacer(minLength: 40)
        }
    }

    private func breakdownRow(_ habit: Habit, row: WeeklyReviewMath.Row) -> some View {
        let rate = row.rate
        return HStack(spacing: 12) {
            Text(habit.emoji)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(habit.name)
                    .font(.subheadline.weight(.medium))

                // Nothing to count (a habit begun after this week, or nothing due yet this week):
                // no bar, never an empty bar that reads as 0%.
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
                if let percent = rate.map(StatsInsights.percent) {
                    Text("\(percent)%")
                } else if row.endsBeforeStart {
                    Text("Not started")
                } else {
                    Text(verbatim: "–")
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        // Without a rate, the name alone, as the dash, unless the week ended before the habit
        // began: "Not started" only then (a habit with months of history heard it every Monday
        // before its check-in, review of bab8acf, 2026-10-22).
        .accessibilityLabel(rate.map(StatsInsights.percent).map { percent in Text("\(habit.emoji) \(habit.name), \(percent) percent") }
                            ?? Text(verbatim: "\(habit.emoji) \(habit.name)"))
        .accessibilityValue(rate == nil && row.endsBeforeStart ? Text("Not started") : Text(verbatim: ""))
    }

    /// "Most improved" and "Slipped" (D8), from each habit's change against itself: at least 10
    /// points, never "Slipped" at 80 % or more this week, and only from a finished week or a
    /// habit's fourth counted day (`WeeklyReviewMath.review`); "Highlights so far" while the week
    /// is not over. No row when nothing qualifies, and no heading when neither does. They replace
    /// Best and Needs work, which a 90 % habit could be.
    @ViewBuilder
    private func highlights(_ review: WeeklyReviewMath.Review) -> some View {
        let improved = review.mostImproved.flatMap { index in review.rows.first { $0.index == index } }
        let slipped = review.slipped.flatMap { index in review.rows.first { $0.index == index } }
        if improved != nil || slipped != nil {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if review.isFinished { Text("Highlights") } else { Text("Highlights so far") }
                }
                .font(.headline)
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)

                if let improved, let points = improved.changePoints {
                    highlightRow(Text("Most improved"), habit: habits[improved.index], points: points)
                }
                if let slipped, let points = slipped.changePoints {
                    highlightRow(Text("Slipped"), habit: habits[slipped.index], points: points)
                }
            }
        }
    }

    private func highlightRow(_ title: Text, habit: Habit, points: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: points > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.subheadline.bold())
                .foregroundStyle(changeColor(points))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(habit.emoji) \(habit.name)")
                    .font(.subheadline)
                changeText(points)
                    .font(.caption)
                    .foregroundStyle(changeColor(points))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

/// The week's overall rate: a number inside a ring.
///
/// The number was a fixed 36 pt and the ring a fixed 120 pt, so at the accessibility sizes it
/// outgrew a ring that did not. Both now scale with `.largeTitle` (the number is the screen's
/// headline figure) through `@ScaledMetric`, which returns the base value exactly at the default
/// size — so the default layout, and the store screenshots, do not move. A separate view because
/// the caller's `.dynamicTypeSize(...)` cap has to be in the environment the scaled metrics read;
/// on `WeeklyReviewView` itself they would read the uncapped size.
///
/// No caption since 1.4.2: the header above it names the week ("This week so far", "Last week"),
/// and a ring that said "This Week" over last week would contradict it. Drawn only with a rate:
/// a week with nothing to count has no ring (D8: no dash ring).
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

            let percent = StatsInsights.percent(rate)
            Text("\(percent)%")
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 18)
        }
        .frame(width: diameter, height: diameter)
    }
}
