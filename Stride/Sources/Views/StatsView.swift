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
    /// Every number on this screen comes from here (RELEASE-1.4.1.md D3), read once per render
    /// and handed down — never kept across renders.
    @Environment(\.statsCache) private var cache
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

    /// `-statsScrollTo detail|insights|trend|strength|beststreaks|weekday|heatmap` scrolls to that
    /// card once, on launch, so scripts/a11y_sweep.sh can capture what sits below the fold.
    /// `simctl` has no touch input, and at accessibility-XXXL the charts this release made scale
    /// (acceptance (4)) start two screens down — the first sweep's PNGs proved the top of the
    /// screen only. DEBUG-only for the same reason as ContentView's `-paywall`, and it draws
    /// nothing: the anchors are `.id`s that a release build never compiles.
    ///
    /// Insights, the trend, strength and the best streaks (1.4.1, D10) are Pro-only. Without Pro
    /// each of those anchors lands on the locked card that replaces them, so a sweep on a
    /// simulator with no purchase shows that card four times.
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
        if !store.isPro, ["insights", "trend", "strength", "beststreaks"].contains(anchor) { anchor = "analytics" }
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
                            // One read of the cache for every card below, in this render (D3).
                            // A commit bumps the cache before it returns, so the render after a
                            // check-in — in History, on Today — already reads the new numbers.
                            let stats = cache.stats(for: habit)
                            VStack(spacing: 16) {
                                HabitDetailStatsCard(habit: habit, stats: stats, shell: shell)
                                    .statsLaunchAnchor("detail")
                                if store.isPro {
                                    InsightsCard(habit: habit, stats: stats)
                                        .statsLaunchAnchor("insights")
                                    TrendCard(habit: habit, stats: stats)
                                        .statsLaunchAnchor("trend")
                                    StrengthCard(habit: habit, stats: stats)
                                        .statsLaunchAnchor("strength")
                                    BestStreaksCard(habit: habit, stats: stats)
                                        .statsLaunchAnchor("beststreaks")
                                } else {
                                    // Exactly what Advanced Analytics holds (D11). Weekly Review
                                    // is Pro too, but it is not behind this card: its toolbar
                                    // button sells it. The paywall's row says the same
                                    // (LocalizationSourceScanTests.testProClaimsNameExactlyD11sSet).
                                    ProLockedCard(
                                        title: "Advanced Analytics",
                                        message: "Insights, the 8-week trend, the strength chart and your top 5 streaks"
                                    ) { showingPaywall = true }
                                    .statsLaunchAnchor("analytics")
                                }
                                WeeklyBarChart(habit: habit, stats: stats)
                                    .statsLaunchAnchor("weekday")
                                HeatmapView(habit: habit, stats: stats, shell: shell)
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

// MARK: - The cache

extension EnvironmentValues {
    /// The `StatsCache` Statistics reads (RELEASE-1.4.1.md D3): the app's one cache, which
    /// `HabitEntryCommit` bumps. A hosted test puts its own here (StatsRenderTests), over a store
    /// of its own, so it never fills or empties the host app's.
    var statsCache: StatsCache {
        get { self[StatsCacheKey.self] }
        set { self[StatsCacheKey.self] = newValue }
    }
}

private struct StatsCacheKey: EnvironmentKey {
    // SwiftUI reads the environment on the main actor, where the cache lives.
    static var defaultValue: StatsCache { MainActor.assumeIsolated { StatsCache.shared } }
}

// MARK: - Overall Stats
struct OverallStatsCard: View {
    let habits: [Habit]
    @Environment(\.statsCache) private var cache

    /// Every habit's stats in one read (D3): after a clear-all, ONE store fetch refills them all.
    private struct Summary {
        let todayCount: Int
        let bestStreak: (value: Int, inWeeks: Bool)
        let avgCompletion: Double
    }

    private var summary: Summary {
        let now = Date()
        let all = cache.stats(for: habits, today: now)
        let todayCount = all.filter { $0.isCompleted(on: now) }.count
        // The longest streak across habits. This was the maximum CURRENT streak under a "Best
        // Streak" label, so the moment a long streak broke the tile dropped to 0 as if the record
        // were erased. Times-per-week habits count streaks in weeks, so they are only compared
        // with each other.
        let dayUnit = all.filter { $0.schedule != .timesPerWeek }
        let bestStreak = dayUnit.isEmpty
            ? (all.map(\.bestStreak).max() ?? 0, true)
            : (dayUnit.map(\.bestStreak).max() ?? 0, false)
        let avgCompletion = all.isEmpty ? 0 : all.map { $0.completionRate(days: 30) }.reduce(0, +) / Double(all.count)
        return Summary(todayCount: todayCount, bestStreak: bestStreak, avgCompletion: avgCompletion)
    }

    var body: some View {
        let summary = self.summary
        let todayCount = summary.todayCount
        let bestStreak = summary.bestStreak
        let avgCompletion = summary.avgCompletion
        // The three values on one baseline (`statValue`): centred, a column whose caption wraps
        // ("Best / Streak" at AX5) sat higher than one whose caption does not, "5/5" about 50 pt
        // below "7" (gate 8). The dividers stay centred on their columns, as before.
        HStack(alignment: .statValue, spacing: 0) {
            StatItem(value: "\(todayCount)/\(habits.count)", label: "Today", icon: "checkmark.circle",
                     a11yValue: "\(todayCount) of \(habits.count) habits completed")
            StatItem(value: "\(bestStreak.value)", label: bestStreak.inWeeks ? "Best Streak (weeks)" : "Best Streak", icon: "flame")
                .overlay(alignment: .leading) { Divider().frame(height: 40) }
            StatItem(value: "\(Int(avgCompletion * 100))%", label: "30d Avg", icon: "chart.line.uptrend.xyaxis",
                     a11yLabel: "30-day average")
                .overlay(alignment: .leading) { Divider().frame(height: 40) }
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
                .alignmentGuide(.statValue) { $0[.firstTextBaseline] }
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

private extension VerticalAlignment {
    /// OverallStatsCard's row: each column's value baseline.
    enum StatValue: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let statValue = VerticalAlignment(StatValue.self)
}

extension View {
    /// A tap area that reaches past a small label by `horizontal` and `vertical` on each side,
    /// with the layout unchanged: the padding is taken back right after the content shape, so the
    /// parent still places and draws the label at its own size. SwiftUI hit-tests the shape where
    /// it lies, past the parent's frame too, and VoiceOver's frame for the control is the same
    /// area (measured in StatsRenderTests).
    func tapTargetOutset(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
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
    /// This render's stats for `habit`, from StatsCache (StatsView reads it once per render).
    let stats: HabitStats
    /// The window's shell: Edit history opens History through it (D6), as a shell sheet that
    /// survives a size-class crossing and never pushes into the shared stack.
    let shell: ShellState
    @State private var showShareSheet = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    /// The sim kit's handle on the Edit history button (RELEASE-1.4.1.md D6, E2E H1).
    static let editHistoryIdentifier = "stats.editHistory"
    /// How far each button's tap area reaches past its label (`tapTargetOutset`), so both are
    /// 44 pt tall and Share 44 pt wide at the default size (gate 8: 18 pt of text and a
    /// 19 × 22 pt glyph before). Edit history's is vertical only; Share's is on every side, and
    /// its 13 pt to the leading side still leaves 3 pt of `DetailCardHeaderLayout.rowSpacing`
    /// before Edit history's label. Their accessibility frames are these areas too
    /// (StatsRenderTests takes them back off to measure the drawn header).
    static let editHistoryTapOutset: CGFloat = 13
    static let shareTapOutset = CGSize(width: 13, height: 11)

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

    /// History, opened on today (D6). The heatmap's tap opens it on the tapped day instead.
    private func openHistory() {
        shell.request = .history(habitID: habit.id, day: Date())
    }

    /// The two buttons' colour: the habit's, as text on this card — a darker shade of it where the
    /// colour itself does not read there (gate 8: Green measured 1.99:1 on the light card, and
    /// Yellow, 1.35:1, all but hid the button D6 makes the way into History).
    private var buttonTint: Color {
        Color.readableText(hex: habit.colorHex, in: colorScheme)
    }

    /// Edit history is a visible, titled button — the one keyboard and Full Keyboard Access path
    /// into History, since the heatmap's cells are not focusable.
    private var editHistoryButton: some View {
        Button(action: openHistory) {
            Label("Edit history", systemImage: "calendar")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(buttonTint)
                // 18 pt of text: a 44 pt tall target, the layout unchanged (gate 8).
                .tapTargetOutset(vertical: Self.editHistoryTapOutset)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.editHistoryIdentifier)
    }

    private var shareButton: some View {
        Button {
            showShareSheet = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.body)
                .foregroundStyle(buttonTint)
                // A 19 × 22 pt glyph: 45 × 44 pt to tap.
                .tapTargetOutset(horizontal: Self.shareTapOutset.width, vertical: Self.shareTapOutset.height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share streak")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The buttons beside the name while it keeps its widest word, under it otherwise —
            // by what fits, at every text size (DetailCardHeaderLayout).
            DetailCardHeaderLayout {
                HStack {
                    Text(habit.emoji)
                        .font(.title2)
                    Text(habit.name)
                        .font(.title3.bold())
                }
                editHistoryButton
                shareButton
                // The narrowest the title above can be without breaking a word: the same emoji
                // and font, the name's unbreakable runs one per line. Measured, never drawn.
                HStack {
                    Text(habit.emoji)
                        .font(.title2)
                    Text(verbatim: DetailCardHeaderLayout.unbreakableRuns(of: habit.name).joined(separator: "\n"))
                        .font(.title3.bold())
                }
                .hidden()
                .accessibilityHidden(true)
            }

            // Four tiles side by side leave each about 70 pt: at accessibility sizes "100%" in
            // .title2 no longer fits one and the captions break mid-word. Stacked there instead.
            // Side by side they share their bottom edge, so the values stay on one line when a
            // caption wraps ("30-Day / Rate" at xLarge, all but "Strength" at xxxLarge); centred,
            // the wrapped tiles' values sat lower than the rest (gate 8).
            let tiles = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 20))
            tiles {
                let current = stats.currentStreak()
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

                let best = stats.bestStreak
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
                    Text("\(Int(stats.completionRate(days: 30) * 100))%")
                        .font(.title2.bold())
                }
                .accessibilityElement(children: .combine)

                // Was "Total", `records.count`: it counted partial count days and records a
                // deletion elsewhere had left behind. The check-in count is History's header
                // now (D10, O7); the tile stays the fourth, so the layout does not move.
                let strength = HabitScore.displayValue(stats.strength)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Strength")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(strength, format: .number)
                        .font(.title2.bold())
                }
                .accessibilityElement(children: .combine)
                .help("Strength grows with every check-in and recovers after a miss.")

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

/// The detail card's header (D6): the emoji and name, then Edit history and Share. They share
/// one row while the name keeps at least its widest word beside the buttons; otherwise the
/// buttons get a row of their own under the name.
///
/// Chosen by what fits, at every text size and width. The buttons used to move only at the
/// accessibility sizes, and below them they kept their full width beside the name whatever was
/// left of it. At xxxLarge on a 375 pt iPhone the Spanish buttons ("Editar historial") left the
/// name about 50 pt, so "Meditación" broke inside the word, a few letters a line (W3-1,
/// W3-A11Y-1; StatsRenderTests measures it). A name that is only long, not wide, still wraps at
/// its spaces beside the buttons, as before.
///
/// The content is four views, in this order, which is also VoiceOver's:
/// 1. the title (emoji and name);
/// 2. Edit history;
/// 3. Share;
/// 4. a hidden probe: the same emoji and font with the name's unbreakable runs one per line, so
///    its width is the narrowest the title can take without breaking a word.
///
/// On one row the buttons keep their full width ("Edit hi…" never), as the `.fixedSize()` they
/// had. On their own row they get the card's width, and "Edit history" wraps only when even that
/// is too narrow (accessibility sizes in a compact iPad window).
struct DetailCardHeaderLayout: Layout {
    /// Between the name and the buttons, and between the two buttons, on one row.
    static let rowSpacing: CGFloat = 16
    /// Between the buttons on a row of their own, as at the accessibility sizes before.
    static let stackedButtonSpacing: CGFloat = 24
    /// Between the name and the buttons' row under it: the card's own spacing.
    static let lineSpacing: CGFloat = 12

    /// The runs of `name` that a line never breaks inside: its words, with the punctuation and
    /// symbols that touch them ("(30", "min)", "30%"). A line may break between two runs.
    /// Japanese and Chinese have no spaces, so their words come from the system's dictionary
    /// segmentation; there a line may break anywhere, so a run is the cautious bound.
    static func unbreakableRuns(of name: String) -> [String] {
        var runs: [String] = []
        name.enumerateSubstrings(in: name.startIndex..<name.endIndex,
                                 options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            var lower = range.lowerBound, upper = range.upperBound
            while lower > name.startIndex, sticks(name[name.index(before: lower)]) {
                lower = name.index(before: lower)
            }
            while upper < name.endIndex, sticks(name[upper]) {
                upper = name.index(after: upper)
            }
            runs.append(String(name[lower..<upper]))
        }
        // No word at all (only emoji or punctuation): the name is one run.
        return runs.isEmpty ? [name] : runs
    }

    private static func sticks(_ character: Character) -> Bool {
        !character.isWhitespace && (character.isPunctuation || character.isSymbol)
    }

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width proposed: CGFloat?, subviews: Subviews) -> Arrangement {
        guard subviews.count == 4 else {
            assertionFailure("DetailCardHeaderLayout takes the title, Edit history, Share and the probe")
            return Arrangement(frames: [], size: .zero)
        }
        let title = subviews[0], edit = subviews[1], share = subviews[2], probe = subviews[3]
        let editSize = edit.sizeThatFits(.unspecified)
        let shareSize = share.sizeThatFits(.unspecified)
        let probeSize = probe.sizeThatFits(.unspecified)
        let probeFrame = CGRect(origin: .zero, size: probeSize)
        let buttons = editSize.width + Self.rowSpacing + shareSize.width

        // No width proposed (an ideal-size query): one row, the name on one line.
        guard let width = proposed, width.isFinite else {
            let titleSize = title.sizeThatFits(.unspecified)
            return oneRow(width: titleSize.width + Self.rowSpacing + buttons, title: titleSize,
                          edit: editSize, share: shareSize, probe: probeFrame)
        }

        let room = width - Self.rowSpacing - buttons
        if room >= probeSize.width.rounded(.up) {
            let titleSize = title.sizeThatFits(ProposedViewSize(width: room, height: nil))
            return oneRow(width: width, title: CGSize(width: room, height: titleSize.height),
                          edit: editSize, share: shareSize, probe: probeFrame)
        }

        // The buttons under the name, which gets the whole width. "Edit history" gives way only
        // if the two buttons are wider than the card.
        let titleSize = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
        var editFits = editSize
        if editSize.width + Self.stackedButtonSpacing + shareSize.width > width {
            let editRoom = max(0, width - Self.stackedButtonSpacing - shareSize.width)
            editFits = edit.sizeThatFits(ProposedViewSize(width: editRoom, height: nil))
            editFits.width = min(editFits.width, editRoom)
        }
        let top = titleSize.height + Self.lineSpacing
        let rowHeight = max(editFits.height, shareSize.height)
        return Arrangement(
            frames: [
                CGRect(x: 0, y: 0, width: width, height: titleSize.height),
                CGRect(x: 0, y: top + (rowHeight - editFits.height) / 2,
                       width: editFits.width, height: editFits.height),
                CGRect(x: editFits.width + Self.stackedButtonSpacing, y: top + (rowHeight - shareSize.height) / 2,
                       width: shareSize.width, height: shareSize.height),
                probeFrame,
            ],
            size: CGSize(width: width, height: top + rowHeight))
    }

    /// Title at the leading edge, the buttons at the trailing one, all centred on the row.
    private func oneRow(width: CGFloat, title: CGSize, edit: CGSize, share: CGSize, probe: CGRect) -> Arrangement {
        let height = max(title.height, edit.height, share.height)
        let shareX = width - share.width
        let editX = shareX - Self.rowSpacing - edit.width
        return Arrangement(
            frames: [
                CGRect(x: 0, y: (height - title.height) / 2, width: title.width, height: title.height),
                CGRect(x: editX, y: (height - edit.height) / 2, width: edit.width, height: edit.height),
                CGRect(x: shareX, y: (height - share.height) / 2, width: share.width, height: share.height),
                probe,
            ],
            size: CGSize(width: width, height: height))
    }
}

// MARK: - Pro Locked Card
struct ProLockedCard: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A capsule while the label is one line. At accessibility sizes it wraps ("Unlock / with Pro"
    /// at AX5), and a capsule's half-height ends ran into both lines (gate 8).
    private var buttonShape: AnyShape {
        typeSize.isAccessibilitySize
            ? AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            : AnyShape(Capsule())
    }

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
                    // Centred like the rest of the card when it wraps.
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(buttonShape.fill(.green))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
        }
        .buttonStyle(.plain)
    }
}

/// The Monday-anchored weeks the 8-week cards draw (TrendCard, StrengthCard), as day-keys, and
/// their labels.
enum StatsWeeks {
    static let count = 8

    /// The Mondays of the `count` weeks ending with the one holding `today` (a day-key, as
    /// `HabitStats.today`), oldest first — the weeks `HabitStats.weeklyStrength` buckets.
    static func mondays(endingWithWeekOf today: Date, count: Int = count) -> [Date] {
        let thisMonday = HabitStats.monday(ofWeekContaining: HabitStats.dayNumber(ofKey: today))
        return (0..<count).reversed().map { HabitStats.key(ofDay: thisMonday - 7 * $0) }
    }

    /// "M/d" in UTC (day-keys are UTC midnights), under each bar. Built once: TrendCard made a
    /// DateFormatter on every render (D10).
    static let label: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// What VoiceOver says instead of `label`: the visible "M/d" is a fixed field order it reads
    /// as "nine slash eight". UTC like `label`, and in the picked language, since it is spoken
    /// inside a picked-language sentence. A FormatStyle is a value, not a formatter to cache.
    @MainActor
    static var spoken: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month().day()
        style.timeZone = HabitCalendar.utc.timeZone
        style.locale = appLocale
        return style
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
        let rate: Double
    }

    private var points: [WeekPoint] {
        let spoken = StatsWeeks.spoken
        return StatsWeeks.mondays(endingWithWeekOf: stats.today).map { start in
            let end = start.addingTimeInterval(6 * 86_400)
            return WeekPoint(
                id: start,
                label: StatsWeeks.label.string(from: start),
                spokenDate: start.formatted(spoken),
                rate: stats.completionRate(from: start, to: end)
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
    /// This render's stats (StatsView): the weekday counts and both rates read one HabitStats
    /// instead of building three.
    let stats: HabitStats
    private let utc = HabitCalendar.utc

    // LocalizedStringKey, not String: a String reaches Text() as verbatim content, so these rows
    // rendered in English in every language. Each phrase is built whole so it is one key.
    private var insights: [(icon: String, text: LocalizedStringKey)] {
        var out: [(String, LocalizedStringKey)] = []
        let symbols = appCalendar.weekdaySymbols // index 0 = Sunday
        let counts = stats.completionsPerWeekday     // keys 1...7

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
        let todayKey = stats.today
        let weekday = utc.component(.weekday, from: todayKey)
        let daysFromMonday = (weekday + 5) % 7
        if let thisStart = utc.date(byAdding: .day, value: -daysFromMonday, to: todayKey),
           let lastStart = utc.date(byAdding: .day, value: -7, to: thisStart),
           let lastEnd = utc.date(byAdding: .day, value: -1, to: thisStart) {
            let thisRate = stats.completionRate(from: thisStart, to: todayKey)
            let lastRate = stats.completionRate(from: lastStart, to: lastEnd)
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
    /// This render's stats (StatsView).
    let stats: HabitStats
    @Environment(\.dynamicTypeSize) private var typeSize
    /// See TrendCard: 30 at the default size keeps the chart at its 110 pt there.
    @ScaledMetric(relativeTo: .caption2) private var labelRoom: CGFloat = 30
    private var weekdayData: [(symbol: String, fullSymbol: String, count: Int, maxCount: Int)] {
        let counts = stats.completionsPerWeekday
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
    /// This render's stats (StatsView), passed on to the grid: its 84 cells, its note dots and
    /// its summary read this one cached set (D3) instead of 84 `isCompletedOn` lookups.
    let stats: HabitStats
    /// The window's shell, for the grid's tap and its VoiceOver action (D5).
    let shell: ShellState
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

            HeatmapGrid(habit: habit, stats: stats, shell: shell, columns: weekColumns, calendar: calendar)
                // The cells scale with the weekday letters. Past .accessibility2 that only makes
                // the grid taller than the screen while showing fewer weeks, and VoiceOver reads
                // the grid as one summary anyway.
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
            // A colour ramp legend; the grid's summary states the count outright.
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
///
/// **A tap opens History on that day, at every width (RELEASE-1.4.1.md D5).** No cell toggles:
/// a phone's cell is 14 pt, a regular-width one can be too (`cellSize` never goes below the
/// scaled cell), and an untick tombstones on every device. One tap gesture over the columns
/// finds the day through `HeatmapLayout.day(at:in:cell:)`, so the 3 pt gaps are not dead and no
/// cell is a Button: on the Mac nothing here takes keyboard focus (no 84 Tab stops). The Edit
/// history button on the detail card is the keyboard path.
///
/// **Accessibility (a D5 decision).** The grid is ONE element: "Activity", its value the
/// completed days of the 84 and the current streak, and an "Edit history" action — VoiceOver's
/// double-tap does the same — that opens History on today. History's month grid is the
/// per-day accessible equivalent; 84 stops here told no more than its summary does.
private struct HeatmapGrid: View {
    let habit: Habit
    let stats: HabitStats
    let shell: ShellState
    /// Seven cells each, top to bottom in the letters' order; nil is an empty cell.
    let columns: [[Date?]]
    let calendar: Calendar
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shellUsesRegularLayout) private var regularLayout
    @ScaledMetric(relativeTo: .caption2) private var scaledCell: CGFloat = 14
    /// The row's width (the card's inside), 0 until the first layout pass has measured it.
    @State private var rowWidth: CGFloat = 0

    /// History on `day` (a local midnight from the columns, or now): a shell sheet (D6).
    private func openHistory(on day: Date) {
        shell.request = .history(habitID: habit.id, day: day)
    }

    /// The grid's VoiceOver value: "N of 84 days completed", then the current streak in the
    /// habit's unit. One key per unit, chosen outside the interpolation; the counts are locals,
    /// so the source scan can type them.
    private var summary: Text {
        let tally = HeatmapLayout.tally(columns) { stats.isCompleted(on: $0) }
        let completed = tally.completed
        let total = tally.total
        let streak = stats.currentStreak()
        return habit.schedule == .timesPerWeek
            ? Text("\(completed) of \(total) days completed, \(streak) week streak")
            : Text("\(completed) of \(total) days completed, \(streak) day streak")
    }

    var body: some View {
        let strip = typeSize.isAccessibilitySize
        let cell = HeatmapLayout.cellSize(scaled: scaledCell, availableWidth: rowWidth, regular: regularLayout)
        HStack(alignment: .top, spacing: HeatmapLayout.spacing) {
            // Row labels that only mean anything through visual alignment with the grid.
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
                // The whole block, gaps included, takes the tap; the location is in the columns'
                // own space, so it scrolls with the strip.
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    if let day = HeatmapLayout.day(at: location, in: columns, cell: cell) { openHistory(on: day) }
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
        #if os(macOS)
        // Said outright, although nothing inside is a control: a Tab never stops in the grid.
        .focusable(false)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity")
        .accessibilityValue(summary)
        .accessibilityHint("Opens History")
        .accessibilityAddTraits(.isButton)
        // VoiceOver's double-tap: without a default action it would tap the element's centre — a
        // day about six weeks back, picked by geometry.
        .accessibilityAction { openHistory(on: Date()) }
        .accessibilityAction(named: "Edit history") { openHistory(on: Date()) }
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
            let model = HeatmapLayout.Cell(completed: stats.isCompleted(on: day), hasNote: stats.hasNote(on: day))
            let completed = model.fill == .completed
            RoundedRectangle(cornerRadius: 2)
                .fill(completed ? habit.color : Color.gray.opacity(0.15))
                .frame(width: side, height: side)
                .overlay {
                    // The day carries a note (D5, D7): a dot that contrasts with either fill — on
                    // the habit's colour white, or black where white would not show (Yellow,
                    // Green, Orange, Teal; `Color.content(onFillHex:)`). A count day below its
                    // target can carry one too, on the empty fill.
                    if model.hasNote {
                        Circle()
                            .fill(completed ? Color.content(onFillHex: habit.colorHex) : habit.color)
                            .frame(width: HeatmapLayout.noteDot, height: HeatmapLayout.noteDot)
                    }
                }
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
/// track, so an empty week still reads as a value on a scale and not as missing data. Also
/// StrengthCard's (StatsProCards.swift).
struct HorizontalBar: View {
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
