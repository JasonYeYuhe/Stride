import SwiftUI
import SwiftData

struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    /// Every number here comes from the cache Statistics reads (RELEASE-1.4.2.md D8): the app's
    /// one, or the one a hosted test put in the environment over a store of its own. 1.4.1 read
    /// `StatsCache.shared`, so no test could hold it.
    @Environment(\.statsCache) private var cache
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]
    /// The user's groups in their order: the sections' order (RELEASE-1.5.0.md D6), as Today's.
    /// 1.4.2 passed no `groupOrder`, so `WeeklyReviewMath.review` drew one section.
    @Query(sort: \HabitGroup.sortOrder)
    private var groups: [HabitGroup]

    /// Any day of the week asked for, as a day-key (`ShellRequest.weeklyReview(week:)`: Today's
    /// card asks for last week's Monday; `WeeklyReviewMath.openingWeek` says why it must be a
    /// day-key), or nil for the review's own choice (`WeeklyReviewMath.openingReview`).
    private let requestedWeek: Date?
    /// The window's shell, for the "At risk this week" tap (`ShellState.focusOnToday`, D6). Nil
    /// outside the shell (a hosted test of the view alone): the tap then only closes the review.
    private let shell: ShellState?
    /// The week ‹ and › moved to (D6); nil until one is pressed: the opening week. Only the week
    /// is kept here, never the stats: they are read from the cache for today on every render, one
    /// entry per habit holding its whole history, so a page costs no rebuild.
    @State private var pagedWeek: WeeklyReviewMath.WeekRange?
    #if DEBUG
    /// The hosted tests' clock (WeeklyReviewRenderTests): a fixed instant, so a test can stand on
    /// a Monday or a Thursday. Nil: the real clock.
    private let fixedNow: Date?
    #endif

    init(week: Date? = nil, shell: ShellState? = nil) {
        requestedWeek = week
        self.shell = shell
        #if DEBUG
        fixedNow = nil
        #endif
    }

    #if DEBUG
    /// The review as it reads at `now` (hosted tests only).
    init(week: Date? = nil, now: Date, shell: ShellState? = nil) {
        requestedWeek = week
        self.shell = shell
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

    /// The Daily Reminder's time when it is on, else nil: the evening `WeeklyReviewMath.isAtRisk`
    /// falls back to for a habit with no reminder of its own (D7). Read per render: the service is
    /// not observable.
    @MainActor
    static func dailyReminderTime(_ service: NotificationService? = nil) -> WeeklyReviewMath.TimeOfDay? {
        let service = service ?? NotificationService.shared
        return service.isReminderEnabled
            ? WeeklyReviewMath.TimeOfDay(hour: service.reminderHour, minute: service.reminderMinute) : nil
    }

    /// The week shown and everything said about it, from ONE `HabitStats` per habit (StatsCache,
    /// built for today) for the whole render, never kept: every rate is the model's rule
    /// (`countedRate(ofWeekStarting:)`), and what may be said about them — the change and the
    /// highlights, each only from a finished week or from a habit's fourth counted day — is
    /// `WeeklyReviewMath.review`. Any week ‹ and › reach is read from the same entries.
    ///
    /// 1.4.1 showed this week only: every Monday before the check-in each habit with months of
    /// history was a dash, and so was the ring; Best and Needs work were picked by raw percentage,
    /// and a change in points was labelled "%". Monday to Wednesday it now opens on last week,
    /// unless nothing existed then (a brand-new user): this week, "so far".
    private struct Summary {
        let week: WeeklyReviewMath.WeekRange
        let relation: WeeklyReviewMath.Relation
        let review: WeeklyReviewMath.Review
        /// Today's day-key: whether the dates need their year.
        let today: Date
        /// The weeks ‹ and › reach (`WeeklyReviewMath.weekBounds`).
        let bounds: ClosedRange<WeeklyReviewMath.WeekRange>
        /// Each row's 7 cells (`WeeklyReviewMath.dayStates`), by the row's index.
        let strips: [Int: [WeeklyReviewMath.DayState]]
        /// Each row's strip in words (`WeeklyReviewMath.stripSummary`), by the row's index: the
        /// habit's rest days come from its schedule, so a done rest day still counts as one.
        let stripSummaries: [Int: WeeklyReviewMath.StripSummary]
        /// Each row's strength change in points (`strengthChangePoints`), by the row's index; no
        /// entry for a week the habit did not exist in.
        let strength: [Int: Int]
        /// The week's perfect days (`WeeklyReviewMath.perfectDayCount`).
        let perfectDays: Int
        /// This week only: the habits at risk now (`WeeklyReviewMath.isAtRisk`), by index, in the
        /// rows' order.
        let atRisk: [Int]
    }

    private func summary() -> Summary {
        let now = self.now
        let calendar = Calendar.current
        // The stats are built for the day the opening week is judged from: `now` itself would be
        // keyed by `HabitStats.dayNumber(of:)`, which reads an exact UTC midnight (Sunday
        // 16:00:00 PST) as Monday's day-key while the header said Sunday's "so far".
        let today = WeeklyReviewMath.today(now: now, calendar: calendar)
        let stats = cache.stats(for: habits, today: today, calendar: calendar)
        let inputs = zip(habits, stats).map { WeeklyReviewMath.HabitInput(habit: $0, stats: $1) }
        let groupOrder = groups.map(\.id)
        let thisWeek = WeeklyReviewMath.weekRange(containing: today, in: calendar)
        let week: WeeklyReviewMath.WeekRange
        let review: WeeklyReviewMath.Review
        if let pagedWeek {
            week = pagedWeek
            review = WeeklyReviewMath.review(of: inputs, week: pagedWeek, groupOrder: groupOrder)
        } else {
            // The opening week, or the other of this week and last when it has nothing to count
            // (pre-freeze review A6), with its review.
            let opened = WeeklyReviewMath.openingReview(of: inputs, now: now, calendar: calendar,
                                                        requested: requestedWeek, groupOrder: groupOrder)
            week = opened.opening.week
            review = opened.review
        }
        // The title follows the week shown, by `openingWeek`'s rule.
        let relation: WeeklyReviewMath.Relation = week == thisWeek ? .thisWeek
            : week == thisWeek.previous ? .lastWeek : .earlier

        var strips: [Int: [WeeklyReviewMath.DayState]] = [:]
        var stripSummaries: [Int: WeeklyReviewMath.StripSummary] = [:]
        var strength: [Int: Int] = [:]
        for row in review.rows {
            let cells = WeeklyReviewMath.dayStates(of: stats[row.index], week: week)
            strips[row.index] = cells
            stripSummaries[row.index] = WeeklyReviewMath.stripSummary(of: stats[row.index], week: week, states: cells)
            strength[row.index] = WeeklyReviewMath.strengthChangePoints(of: stats[row.index], week: week)
        }
        // "At risk this week" is about now: never on another week.
        var atRisk: [Int] = []
        if relation == .thisWeek {
            let reminder = Self.dailyReminderTime()
            atRisk = review.rows.map(\.index).filter {
                WeeklyReviewMath.isAtRisk(habits[$0], stats: stats[$0], now: now, calendar: calendar,
                                          dailyReminder: reminder)
            }
        }
        return Summary(week: week, relation: relation, review: review, today: today,
                       bounds: WeeklyReviewMath.weekBounds(of: inputs, now: now, calendar: calendar),
                       strips: strips, stripSummaries: stripSummaries, strength: strength,
                       perfectDays: WeeklyReviewMath.perfectDayCount(of: inputs, week: week),
                       atRisk: atRisk)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if habits.isEmpty {
                    emptyState
                } else {
                    review(summary())
                        // `-scrollTo reviewAtRisk|reviewBreakdown`: the rows below the fold, for
                        // scripts/a11y_sweep.sh (DEBUG only; RELEASE-1.5.0.md V5, gate 5).
                        .sweepScrollable()
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
        // 560 × 680, never below 420 × 520. At 420 a row still holds its strip, its rate and its
        // chip at the default text size (1.5.0 D6): the name wraps first.
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

    /// "This week so far", or "Last week", each over its dates; an earlier week is titled by its
    /// dates (the copy deck has no other name for it). Between ‹ and › (D6): from the week of the
    /// earliest habit's start to this week, each disabled at its end. ⌘← and ⌘→ reach them from
    /// the keyboard (on the Mac, and an iPad with one).
    private func header(_ summary: Summary) -> some View {
        let dates = Self.dates(of: summary.week, today: summary.today, locale: appLocale)
        return HStack(alignment: .center, spacing: 4) {
            pageButton(previous: true, summary: summary)
            VStack(spacing: 4) {
                Group {
                    switch summary.relation {
                    case .thisWeek: Text("This week so far")
                    case .lastWeek: Text("Last week")
                    case .earlier: Text(verbatim: dates)
                    }
                }
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                if summary.relation != .earlier {
                    Text(verbatim: dates)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            pageButton(previous: false, summary: summary)
        }
        .padding(.horizontal)
    }

    /// ‹ or ›: one week back or on, never past `summary.bounds`. The week only is set; the stats
    /// are the render's own (no rebuild).
    @ViewBuilder
    private func pageButton(previous: Bool, summary: Summary) -> some View {
        let target = previous ? summary.week.previous : summary.week.next
        let enabled = previous ? summary.week > summary.bounds.lowerBound : summary.week < summary.bounds.upperBound
        let button = Button {
            pagedWeek = target
        } label: {
            Image(systemName: previous ? "chevron.left" : "chevron.right")
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityIdentifier(previous ? "review.previousWeek" : "review.nextWeek")
        if previous {
            button
                .accessibilityLabel(Text("Previous week"))
                .help("Previous week")
                .keyboardShortcut(.leftArrow, modifiers: .command)
        } else {
            button
                .accessibilityLabel(Text("Next week"))
                .help("Next week")
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
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
                        .accessibilityLabel(ringLabel(overall, relation: summary.relation))
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

                perfectDays(summary.perfectDays)
            }
            .padding(.top)

            atRisk(summary)
                .sweepAnchor("reviewAtRisk")

            // Per-habit breakdown, by group (D6)
            VStack(alignment: .leading, spacing: 12) {
                Text("Habit Breakdown")
                    .font(.headline)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)

                let rows = Dictionary(uniqueKeysWithValues: review.rows.map { ($0.index, $0) })
                ForEach(review.sections, id: \.groupID) { section in
                    // No headers for a user without groups: one section, as 1.4.2 drew it.
                    if !groups.isEmpty {
                        sectionHeader(section)
                    }
                    ForEach(section.members, id: \.self) { index in
                        if let row = rows[index] {
                            breakdownRow(habits[index], row: row, strip: summary.strips[index] ?? [],
                                         stripSummary: summary.stripSummaries[index]
                                            ?? WeeklyReviewMath.StripSummary(summary.strips[index] ?? []),
                                         strength: summary.strength[index])
                        }
                    }
                }
            }
            .sweepAnchor("reviewBreakdown")

            highlights(review)

            Spacer(minLength: 40)
        }
    }

    // MARK: - Perfect days and at risk (D6)

    /// "N perfect days" for the week: days on which something was due and everything due was done
    /// (`DailyProgress`, through today). Said only when there is at least one: "0 perfect days" is
    /// true, but it is not news.
    @ViewBuilder
    private func perfectDays(_ count: Int) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("\(count) perfect days")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("review.perfectDays")
        }
    }

    /// "At risk this week" (this week only): each habit `WeeklyReviewMath.isAtRisk` names now. A
    /// tap closes the review and brings the habit into view on Today (`ShellState.focusOnToday`).
    /// It writes nothing to the store.
    @ViewBuilder
    private func atRisk(_ summary: Summary) -> some View {
        if !summary.atRisk.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("At risk this week")
                    .font(.headline)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                ForEach(summary.atRisk, id: \.self) { index in
                    atRiskRow(habits[index])
                }
            }
        }
    }

    private func atRiskRow(_ habit: Habit) -> some View {
        let id = habit.id
        return Button {
            focusOnToday(id)
        } label: {
            HStack(spacing: 12) {
                Text(habit.emoji)
                    .font(.title3)
                Text(habit.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityLabel(Text(verbatim: "\(habit.emoji) \(habit.name)"))
        .accessibilityHint(Text("Show on Today"))
        .help("Show on Today")
        .accessibilityIdentifier("review.atRisk.\(id.uuidString)")
    }

    /// The at-risk tap: through the shell when there is one (the review is its sheet), else just
    /// closed.
    private func focusOnToday(_ habitID: UUID) {
        if let shell {
            shell.focusOnToday(habitID: habitID, now: now)
        } else {
            dismiss()
        }
    }

    // MARK: - Sections and rows

    /// A group's header: its name and its members' mean counted rate (D6), "Ungrouped" last.
    private func sectionHeader(_ section: WeeklyReviewMath.Section) -> some View {
        let group = section.groupID.flatMap { id in groups.first { $0.id == id } }
        let title = group?.name ?? appLocalized("Ungrouped")
        let percent = section.rate.map(StatsInsights.percent)
        return HStack(spacing: 8) {
            Circle()
                .fill(group?.color ?? Color.gray)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let percent {
                Text("\(percent)%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { percent in Text("\(title), \(percent) percent") } ?? Text(verbatim: title))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("review.section")
    }

    /// One habit's week: its emoji, its name over the 7-cell strip, its rate, and the strength
    /// chip. The name, the strip and the rate are ONE accessibility element (D6): the label names
    /// the habit and its rate, the value is the strip's summary ("5 of 7 done, 1 rest day"),
    /// never 7 stops. The chip is its own element. At accessibility sizes the row wraps: the
    /// strip under the name, the rate and the chip under the strip.
    private func breakdownRow(_ habit: Habit, row: WeeklyReviewMath.Row, strip: [WeeklyReviewMath.DayState],
                              stripSummary: WeeklyReviewMath.StripSummary, strength: Int?) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let core = rowCore(habit, row: row, strip: strip, summary: stripSummary, stacked: stacked)
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    core
                    if let strength { strengthChip(strength) }
                }
            } else {
                HStack(spacing: 8) {
                    core
                    if let strength { strengthChip(strength) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func rowCore(_ habit: Habit, row: WeeklyReviewMath.Row, strip: [WeeklyReviewMath.DayState],
                         summary: WeeklyReviewMath.StripSummary, stacked: Bool) -> some View {
        let rate = row.rate
        let content = Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(habit.emoji)
                            .font(.title3)
                        Text(habit.name)
                            .font(.subheadline.weight(.medium))
                    }
                    DayStrip(states: strip, color: habit.color)
                    rateText(row)
                }
            } else {
                HStack(spacing: 12) {
                    Text(habit.emoji)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(habit.name)
                            .font(.subheadline.weight(.medium))
                        DayStrip(states: strip, color: habit.color)
                    }
                    Spacer(minLength: 0)
                    rateText(row)
                }
            }
        }
        content
            .accessibilityElement(children: .ignore)
            // Without a rate, the name alone, as the dash, unless the week ended before the habit
            // began: "Not started" only then (a habit with months of history heard it every Monday
            // before its check-in, review of bab8acf, 2026-10-22).
            .accessibilityLabel(rate.map(StatsInsights.percent).map { percent in Text("\(habit.emoji) \(habit.name), \(percent) percent") }
                                ?? Text(verbatim: "\(habit.emoji) \(habit.name)"))
            .accessibilityValue(rate == nil && row.endsBeforeStart ? Text("Not started") : stripValue(summary))
            .accessibilityIdentifier("review.row.\(habit.id.uuidString)")
    }

    private func rateText(_ row: WeeklyReviewMath.Row) -> some View {
        Group {
            if let percent = row.rate.map(StatsInsights.percent) {
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

    /// The strip as words (D6): "5 of 7 done", and ", 1 rest day" when there is one; nothing for a
    /// week the habit has no day in yet. `total` is every day the habit existed for that has begun,
    /// today only once it is no longer open, as the rate beside it counts (`StripSummary.days`);
    /// the rest days are the habit's unscheduled days, a done one included (`StripSummary.rest`).
    static func stripValue(_ summary: WeeklyReviewMath.StripSummary) -> Text {
        let completed = summary.done
        let total = summary.days
        guard total > 0 else { return Text(verbatim: "") }
        if summary.rest > 0 {
            let count = summary.rest
            return Text("\(completed) of \(total) done, \(count) rest days")
        }
        return Text("\(completed) of \(total) done")
    }

    private func stripValue(_ summary: WeeklyReviewMath.StripSummary) -> Text {
        Self.stripValue(summary)
    }

    /// The strength chip (D6): the change in the habit's strength over the week, in the points
    /// the scores print (`WeeklyReviewMath.strengthChangePoints`), in the change colours
    /// (`Color.readableText`, as the change line and StrengthCard's tiles).
    private func strengthChip(_ points: Int) -> some View {
        HStack(spacing: 2) {
            if points != 0 {
                Image(systemName: points > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.bold())
            }
            strengthText(points)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(changeColor(points))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(changeColor(points).opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(points == 0 ? Text("Strength unchanged") : strengthText(points))
        .accessibilityIdentifier("review.strength")
    }

    /// "Strength +4", "Strength −3" (a drop is passed as a positive number after "−", as the
    /// change line), or "Strength ±0".
    private func strengthText(_ points: Int) -> Text {
        if points > 0 { return Text("Strength +\(points)") }
        if points < 0 {
            let points = -points
            return Text("Strength −\(points)")
        }
        return Text("Strength ±0")
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

/// A habit's week as 7 cells, Monday to Sunday (D6; `WeeklyReviewMath.DayState`): done filled in
/// the habit's colour; missed a grey cell with a cross; a rest day a dash; a times-per-week day
/// without a check-in a plain grey cell (neutral, never a miss); before the start nothing; a
/// future day a dashed outline; today not yet done an outline in the habit's colour. Shape tells
/// them apart, not colour alone. Hidden from VoiceOver: the row speaks it as one summary.
private struct DayStrip: View {
    let states: [WeeklyReviewMath.DayState]
    let color: Color
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 14

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                cell(state)
                    .frame(width: side, height: side)
            }
        }
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cell(_ state: WeeklyReviewMath.DayState) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.25)
        switch state {
        case .done:
            shape.fill(color)
        case .missed:
            shape.fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: side * 0.5, weight: .bold))
                        .foregroundStyle(.secondary))
        case .rest:
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: side * 0.6, height: max(2, side * 0.15))
        case .neutral:
            shape.fill(Color.secondary.opacity(0.15))
        case .beforeStart:
            Color.clear
        case .future:
            shape.strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        case .todayOpen:
            shape.strokeBorder(color, lineWidth: 1.5)
        }
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
