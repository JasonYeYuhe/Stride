import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    /// The habit shown is the window's shell's (`ShellState.statsHabitID`, an id resolved against
    /// the live query below — see there why never a Habit): at regular width and on the Mac this
    /// view is created on the first visit and kept, and a size-class crossing rebuilds it, so it
    /// cannot own the pick (RELEASE-1.4.0.md D2).
    let shell: ShellState
    /// False while the shell keeps this tab hidden; its toolbar item is withdrawn then.
    @Environment(\.shellTabIsActive) private var isActive
    @Environment(\.shellUsesRegularLayout) private var regularLayout

    private var selectedHabit: Habit? {
        habits.first { $0.id == shell.statsHabitID } ?? habits.first
    }
    @State private var showingWeeklyReview = false
    @State private var showingPaywall = false
    private var store = StoreService.shared
    #if DEBUG
    /// Counts this view's creations for the hosted shell tests (`ShellTabLifetime`).
    @StateObject private var lifetime: ShellTabLifetime
    #endif

    init(shell: ShellState) {
        self.shell = shell
        #if DEBUG
        _lifetime = StateObject(wrappedValue: ShellTabLifetime(.stats, shell: shell))
        #endif
    }

    var body: some View {
        #if DEBUG
        let _ = lifetime
        ScrollViewReader { proxy in
            statsContent
                .task { await scrollToLaunchAnchor(proxy) }
        }
        #else
        statsContent
        #endif
    }

    #if DEBUG
    @State private var didScrollToLaunchAnchor = false

    /// `-statsScrollTo detail|insights|trend|weekday|heatmap` scrolls to that card once, on launch,
    /// so scripts/a11y_sweep.sh can capture what sits below the fold. `simctl` has no touch input,
    /// and at accessibility-XXXL the charts this release made scale (acceptance (4)) start two
    /// screens down — the first sweep's PNGs proved the top of the screen only. DEBUG-only for the
    /// same reason as ContentView's `-paywall`, and it draws nothing: the anchors are `.id`s that
    /// a release build never compiles.
    ///
    /// Insights and the trend are Pro-only. Without Pro both anchors land on the locked card that
    /// replaces them, so a sweep on a simulator with no purchase shows that card twice.
    ///
    /// "On launch" means when this view is created. With `-tab 1` that is the launch on every
    /// layout; since 1.4.0 the regular-width shell creates Stats on its first visit, and this
    /// `.task` runs then.
    private func scrollToLaunchAnchor(_ proxy: ScrollViewProxy) async {
        let arguments = CommandLine.arguments
        guard !didScrollToLaunchAnchor,
              let idx = arguments.firstIndex(of: "-statsScrollTo"), idx + 1 < arguments.count
        else { return }
        didScrollToLaunchAnchor = true
        var anchor = arguments[idx + 1]
        if !store.isPro, anchor == "insights" || anchor == "trend" { anchor = "analytics" }
        // After the first layout pass (and the @Query's first fetch): a scrollTo issued before
        // the target has a frame does nothing, silently.
        try? await Task.sleep(for: .milliseconds(500))
        proxy.scrollTo(anchor, anchor: .top)
    }
    #endif

    private var statsContent: some View {
        ScrollView {
            Group {
                if habits.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "chart.bar")
                            .scaledSystemFont(size: 50, relativeTo: .largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                            // Decoration: past .accessibility2 it would only push the text that
                            // explains the empty screen below the fold.
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
                                            shell.statsHabitID = habit.id
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }

                        if let habit = selectedHabit {
                            VStack(spacing: 16) {
                                HabitDetailStatsCard(habit: habit)
                                    .statsLaunchAnchor("detail")
                                if store.isPro {
                                    InsightsCard(habit: habit)
                                        .statsLaunchAnchor("insights")
                                    TrendCard(habit: habit)
                                        .statsLaunchAnchor("trend")
                                } else {
                                    ProLockedCard(
                                        title: "Advanced Analytics",
                                        message: "8-week trends, insights & weekly review"
                                    ) { showingPaywall = true }
                                    .statsLaunchAnchor("analytics")
                                }
                                WeeklyBarChart(habit: habit)
                                    .statsLaunchAnchor("weekday")
                                HeatmapView(habit: habit)
                                    .statsLaunchAnchor("heatmap")
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
            .shellReadableWidth(regularLayout)
        }
        .background(Color.appBackground)
        // No title of its own: the shell sets it (ContentView.title).
        .toolbar {
            // With no habits the review has nothing to show, and for a free user the button
            // opened the paywall to sell a feature that would then be empty. And only while this
            // tab shows: every kept tab's toolbar lands in the shell's one navigation bar (D2).
            if isActive && !habits.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if store.isPro { showingWeeklyReview = true } else { showingPaywall = true }
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("Weekly Review")
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

private extension View {
    /// A scroll target for `-statsScrollTo` (see StatsView.scrollToLaunchAnchor). Release builds
    /// return the view untouched, so the anchor cannot change identity or layout there.
    @ViewBuilder
    func statsLaunchAnchor(_ name: String) -> some View {
        #if DEBUG
        id(name)
        #else
        self
        #endif
    }
}

// MARK: - Overall Stats
struct OverallStatsCard: View {
    let habits: [Habit]

    private var todayCount: Int {
        habits.filter { $0.isCompletedOn(Date()) }.count
    }

    /// The longest streak across habits. This was the maximum CURRENT streak under a "Best Streak"
    /// label, so the moment a long streak broke the tile dropped to 0 as if the record were erased.
    /// Times-per-week habits count streaks in weeks, so they are only compared with each other.
    private var bestStreak: (value: Int, inWeeks: Bool) {
        let dayUnitHabits = habits.filter { $0.schedule != .timesPerWeek }
        if dayUnitHabits.isEmpty {
            return (habits.map { $0.bestStreak() }.max() ?? 0, true)
        }
        return (dayUnitHabits.map { $0.bestStreak() }.max() ?? 0, false)
    }

    private var avgCompletion: Double {
        guard !habits.isEmpty else { return 0 }
        return habits.map { $0.completionRate() }.reduce(0, +) / Double(habits.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            StatItem(value: "\(todayCount)/\(habits.count)", label: "Today", icon: "checkmark.circle",
                     a11yValue: "\(todayCount) of \(habits.count) habits completed")
            Divider().frame(height: 40)
            StatItem(value: "\(bestStreak.value)", label: bestStreak.inWeeks ? "Best Streak (weeks)" : "Best Streak", icon: "flame")
            Divider().frame(height: 40)
            StatItem(value: "\(Int(avgCompletion * 100))%", label: "30d Avg", icon: "chart.line.uptrend.xyaxis",
                     a11yLabel: "30-day average")
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
    /// Spoken instead of the visible ones where the glyph form doesn't survive being read aloud:
    /// "30d Avg" becomes "thirty d avg", and "3/5" becomes "three fifths".
    var a11yLabel: LocalizedStringKey?
    var a11yValue: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: value)
                .font(.title3.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel ?? label)
        .accessibilityValue(a11yValue.map { Text($0) } ?? Text(verbatim: value))
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSelected ? "\(habit.name), selected" : "\(habit.name)")
        // The chip stays actionable when selected, so .isSelected has to be added to .isButton
        // rather than replace it — otherwise it reads as a static status label.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Habit Detail Stats
struct HabitDetailStatsCard: View {
    let habit: Habit
    @State private var showShareSheet = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The unit drawn beside a streak number, which is drawn separately and larger.
    ///
    /// This was `Text(habit.streakUnit == "week" ? "weeks" : "days")`: "weeks" existed in no
    /// catalog, so every language showed English beside a times-per-week habit's streaks, and
    /// "days" had no singular, so English read "1 days". The key now carries the count so the
    /// plural rules pick the form, and the forms are the unit alone. One key per unit, chosen
    /// outside the interpolation — a ternary inside one is never looked up.
    private func streakUnit(_ count: Int) -> Text {
        habit.streakUnit == "week"
            ? Text("weeks (unit after \(count))")
            : Text("days (unit after \(count))")
    }

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

            // Four tiles side by side leave each about 70 pt: at accessibility sizes "100%" in
            // .title2 no longer fits one and the captions break mid-word. Stacked there instead.
            let tiles = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 20))
            tiles {
                let current = habit.currentStreak()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(current)")
                            .font(.title2.bold())
                        streakUnit(current)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                let best = habit.bestStreak()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Best Streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(best)")
                            .font(.title2.bold())
                        streakUnit(best)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 4) {
                    Text("30-Day Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(habit.completionRate() * 100))%")
                        .font(.title2.bold())
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(habit.records.count)")
                        .font(.title2.bold())
                }
                .accessibilityElement(children: .combine)

                if !typeSize.isAccessibilitySize {
                    Spacer()
                }
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
                    .accessibilityHidden(true)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Room for the value and date labels around the bars: 30 at the default size, where the
    /// chart was a fixed 110 pt that the labels overflowed as soon as they could grow.
    @ScaledMetric(relativeTo: .caption2) private var labelRoom: CGFloat = 30

    private struct WeekPoint: Identifiable {
        let id = UUID()
        let label: String
        /// Spoken instead of `label`: the visible "M/d" is a fixed field order VoiceOver reads
        /// as "nine slash eight".
        let spokenDate: String
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

        // Same instants as `fmt`, so the spoken date has to stay UTC-anchored too.
        var spokenFmt = Date.FormatStyle.dateTime.month().day()
        spokenFmt.timeZone = utc.timeZone
        // Spoken inside a picked-language sentence, so the month name must follow the picker too.
        spokenFmt.locale = appLocale

        return (0..<weekCount).reversed().compactMap { back in
            guard let start = utc.date(byAdding: .day, value: -7 * back, to: thisWeekStart),
                  let end = utc.date(byAdding: .day, value: 6, to: start) else { return nil }
            return WeekPoint(
                label: fmt.string(from: start),
                spokenDate: start.formatted(spokenFmt),
                rate: habit.completionRate(from: start, to: end)
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
                    let fill = point.rate > 0 ? habit.color.opacity(0.4 + 0.6 * point.rate) : Color.gray.opacity(0.2)
                    Group {
                        if rows {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(point.label)
                                        .scaledSystemFont(size: 8)
                                    Spacer()
                                    Text("\(Int(point.rate * 100))")
                                        .scaledSystemFont(size: 9)
                                }
                                .foregroundStyle(.secondary)
                                HorizontalBar(fraction: point.rate, fill: fill)
                            }
                        } else {
                            VStack(spacing: 4) {
                                Text("\(Int(point.rate * 100))")
                                    .scaledSystemFont(size: 9)
                                    .foregroundStyle(.secondary)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(fill)
                                    .frame(height: max(4, CGFloat(point.rate) * 80))
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
                    .accessibilityValue(Text(verbatim: "\(Int(point.rate * 100))%"))
                }
            }
            // The tallest bar is 80 pt; the rest is the two labels, so only that part scales.
            .frame(height: rows ? nil : 80 + labelRoom)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }
}

// MARK: - Insights (best/worst day, momentum)
struct InsightsCard: View {
    let habit: Habit
    private let utc = HabitCalendar.utc

    // LocalizedStringKey, not String: a String reaches Text() as verbatim content, so these rows
    // rendered in English in every language. Each phrase is built whole so it is one key.
    private var insights: [(icon: String, text: LocalizedStringKey)] {
        var out: [(String, LocalizedStringKey)] = []
        let symbols = appCalendar.weekdaySymbols // index 0 = Sunday
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
                // Formatted outside the key so the key carries no literal "%" to escape.
                let was = "\(Int(lastRate*100))%"
                let now = "\(Int(thisRate*100))%"
                if thisRate >= lastRate {
                    out.append(("arrow.up.right", "Up vs last week (\(was) → \(now))"))
                } else {
                    out.append(("arrow.down.right", "Down vs last week (\(was) → \(now))"))
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

// MARK: - Weekly Bar Chart
struct WeeklyBarChart: View {
    let habit: Habit
    @Environment(\.dynamicTypeSize) private var typeSize
    /// See TrendCard: 30 at the default size keeps the chart at its 110 pt there.
    @ScaledMetric(relativeTo: .caption2) private var labelRoom: CGFloat = 30
    private var weekdayData: [(symbol: String, fullSymbol: String, count: Int, maxCount: Int)] {
        let counts = habit.completionsPerWeekday()
        let maxCount = counts.values.max() ?? 1
        let calendar = appCalendar
        let symbols = calendar.shortWeekdaySymbols
        // The abbreviations are for the axis only — VoiceOver mangles "Mon"/"Tue".
        let fullSymbols = calendar.weekdaySymbols

        return (1...7).map { weekday in
            let index = weekday - 1
            return (
                symbol: symbols[index],
                fullSymbol: fullSymbols[index],
                count: counts[weekday] ?? 0,
                maxCount: maxCount
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Weekday")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // Same breakpoint as TrendCard: seven ~41 pt columns cannot hold "Mon" at accessibility
            // sizes, so those draw one row per weekday — with room for the full name.
            let rows = typeSize.isAccessibilitySize
            let layout = rows
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
            layout {
                ForEach(weekdayData, id: \.symbol) { data in
                    let fill = data.count > 0 ? habit.color : Color.gray.opacity(0.2)
                    let fraction = data.maxCount > 0 ? Double(data.count) / Double(data.maxCount) : 0
                    Group {
                        if rows {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(data.fullSymbol)
                                    Spacer()
                                    Text("\(data.count)")
                                }
                                .scaledSystemFont(size: 10)
                                .foregroundStyle(.secondary)
                                HorizontalBar(fraction: fraction, fill: fill)
                            }
                        } else {
                            VStack(spacing: 4) {
                                Text("\(data.count)")
                                    .scaledSystemFont(size: 10)
                                    .foregroundStyle(.secondary)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(fill)
                                    .frame(height: max(4, CGFloat(fraction) * 80))

                                Text(data.symbol)
                                    .scaledSystemFont(size: 10)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(data.fullSymbol)
                    .accessibilityValue("\(data.count) check-ins")
                }
            }
            .frame(height: rows ? nil : 80 + labelRoom)
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
    private var calendar: Calendar { appCalendar }
    /// The legend's swatches grow with the "Less"/"More" beside them; 12 at the default size.
    @ScaledMetric(relativeTo: .caption2) private var swatch: CGFloat = 12

    /// Twelve weeks ending today as week columns of seven cells, each day in the row of its own
    /// weekday and the oldest week padded at the TOP (`HeatmapLayout`, RELEASE-1.4.0.md D2). The
    /// grid used to split the days at `firstWeekday` and pad every short column at the bottom, so
    /// the oldest, partial week was drawn from the top row down — Thursday beside "S" — whenever
    /// the twelve weeks did not start on the first day of a week, six days in seven.
    private var weekColumns: [[Date?]] {
        let calendar = self.calendar
        return HeatmapLayout.columns(of: HeatmapLayout.days(endingOn: Date(), calendar: calendar), calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            HeatmapGrid(habit: habit, columns: weekColumns, calendar: calendar)
                // The cells scale with the weekday letters. Past .accessibility2 that only makes
                // the grid taller than the screen while showing fewer weeks, and VoiceOver reads
                // each cell anyway (the letters are hidden from it).
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)

            HStack(spacing: 4) {
                Spacer()
                Text("Less")
                    .scaledSystemFont(size: 9)
                    .foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: swatch, height: swatch)
                RoundedRectangle(cornerRadius: 2)
                    .fill(habit.color)
                    .frame(width: swatch, height: swatch)
                Text("More")
                    .scaledSystemFont(size: 9)
                    .foregroundStyle(.secondary)
            }
            // A colour ramp legend; every cell states completed / not completed outright.
            .accessibilityHidden(true)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
    }
}

/// The weekday letters and the 12-week grid. Its own view so that the `@ScaledMetric` cell size
/// reads the Dynamic Type size HeatmapView caps, not the uncapped one.
///
/// Compact width (phones): the `@ScaledMetric` cell, 14 pt at the default size, as in 1.3.x. The
/// 12 or 13 columns (at most 218 pt) fit beside the letters with room to spare. The cells scale
/// with the letters, and from the first accessibility size the grid is wider than a phone: it
/// becomes a horizontally scrolling strip that opens on the CURRENT week (the trailing end) with
/// its indicator shown, instead of overflowing the card or opening on the oldest week.
///
/// Regular width and the Mac (D2): the fixed cell drew the grid across about a quarter of an
/// iPad's card. There the cell grows until 13 columns and the letters fill the row
/// (`HeatmapLayout.cellSize`; 41 pt at the 680 pt cap, 99.5 % of the card), never below the
/// scaled cell, so a narrow window or the accessibility strip still scrolls as on a phone. The
/// row is measured here, OUTSIDE the horizontal ScrollView, which proposes unlimited width to
/// what is inside it. The grid hugs its columns at the row's trailing edge: on the one day in
/// seven with only 12 columns the spare width sits on the leading side and the current week
/// still ends at the card's edge, and the cell, sized for 13, does not change from day to day.
private struct HeatmapGrid: View {
    let habit: Habit
    /// Seven cells each, top to bottom in the letters' order; nil is an empty cell.
    let columns: [[Date?]]
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shellUsesRegularLayout) private var regularLayout
    @ScaledMetric(relativeTo: .caption2) private var scaledCell: CGFloat = 14
    /// The row's width (the card's inside), 0 until the first layout pass has measured it.
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        let strip = typeSize.isAccessibilitySize
        let cell = HeatmapLayout.cellSize(scaled: scaledCell, availableWidth: rowWidth, regular: regularLayout)
        HStack(alignment: .top, spacing: HeatmapLayout.spacing) {
            // Row labels that only mean anything through visual alignment with the grid;
            // each cell names its own weekday instead.
            VStack(alignment: .trailing, spacing: HeatmapLayout.spacing) {
                ForEach(0..<7, id: \.self) { i in
                    let symbols = calendar.veryShortWeekdaySymbols
                    let index = (calendar.firstWeekday - 1 + i) % 7
                    Text(symbols[index])
                        .scaledSystemFont(size: 9)
                        .foregroundStyle(.secondary)
                        .frame(width: cell, height: cell)
                }
            }
            .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: strip) {
                HStack(spacing: HeatmapLayout.spacing) {
                    ForEach(columns.indices, id: \.self) { weekIndex in
                        VStack(spacing: HeatmapLayout.spacing) {
                            ForEach(0..<7, id: \.self) { row in
                                dayCell(columns[weekIndex][row], side: cell)
                            }
                        }
                    }
                }
            }
            // nil (the system default) below the breakpoint, where the grid is narrower than the
            // scroll view: an anchor can also position content like that, and at the default
            // size nothing may move (store screenshots are diffed).
            .defaultScrollAnchor(strip ? .trailing : nil)
            .frame(width: scrollWidth(cell: cell))
        }
        .frame(maxWidth: .infinity, alignment: regularLayout ? .trailing : .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
    }

    /// At regular width, once measured: the columns' own width, or what the row leaves beside the
    /// letters when they are wider (the strip, a narrow Mac window) — so the grid can sit at the
    /// trailing edge. Otherwise nil, and the scroll view takes the row, as in 1.3.x.
    private func scrollWidth(cell: CGFloat) -> CGFloat? {
        guard regularLayout, rowWidth > 0, !columns.isEmpty else { return nil }
        let spacing = HeatmapLayout.spacing
        let columnsWidth = CGFloat(columns.count) * cell + CGFloat(columns.count - 1) * spacing
        return min(columnsWidth, max(0, rowWidth - cell - spacing))
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, side: CGFloat) -> some View {
        if let day {
            let completed = habit.isCompletedOn(day)
            // `monthYear` is a hard-coded "MMMM yyyy", so cells announced
            // "September 2026 16" — English field order, the year on all 84
            // cells, and never the weekday the columns are organised by.
            let dateLabel = day.formatted(.dateTime.weekday(.wide).month().day().locale(appLocale))
            RoundedRectangle(cornerRadius: 2)
                .fill(completed ? habit.color : Color.gray.opacity(0.15))
                .frame(width: side, height: side)
                .accessibilityLabel(completed ? "\(dateLabel), completed" : "\(dateLabel), not completed")
        } else {
            // Before the twelve weeks, or after today: room, not a day.
            Color.clear.frame(width: side, height: side)
        }
    }
}

// MARK: - Dynamic Type helpers

/// `.font(.system(size:))` that grows with Dynamic Type. SwiftUI has
/// `Font.custom(_:size:relativeTo:)` but no system-font equivalent, and moving the 8–10 pt chart
/// labels to `.caption2` (11 pt) would shift every chart at the default size, where the store
/// screenshots are diffed against the previous release. `@ScaledMetric` returns the base size
/// exactly at the default (`.large`) size, so only the other sizes change.
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight?

    init(size: CGFloat, weight: Font.Weight?, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    /// A fixed-size system font that scales like `style`. To cap it (decorative symbols), put
    /// `.dynamicTypeSize(...)` AFTER this modifier: the cap has to be in the environment the
    /// scaled metric reads.
    func scaledSystemFont(size: CGFloat, weight: Font.Weight? = nil,
                          relativeTo style: Font.TextStyle = .caption2) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, relativeTo: style))
    }
}

/// A left-to-right bar for the accessibility-size rows of the bar charts; `fraction` in 0...1.
/// Never shorter than the 4 pt stub the columns draw for zero, and drawn over a faint full-width
/// track, so an empty week still reads as a value on a scale and not as missing data.
private struct HorizontalBar: View {
    let fraction: Double
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: 12)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
    }
}
