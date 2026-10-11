import SwiftUI
import SwiftData
import WidgetKit

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Habit> { !$0.isArchived },
           sort: \Habit.sortOrder)
    private var habits: [Habit]

    @Query(sort: \HabitGroup.sortOrder)
    private var groups: [HabitGroup]

    /// The day shown, its anchor and the title live in the window's shell (RELEASE-1.4.0.md D2):
    /// at regular width and on the Mac this view is kept alive while hidden, or may not exist yet,
    /// and a size-class crossing rebuilds it — so it can neither own the day nor be the one that
    /// re-anchors it (`ShellState.reanchor`, called by ContentView).
    @Bindable var shell: ShellState
    /// False while the shell keeps this tab hidden; its toolbar item is withdrawn then.
    @Environment(\.shellTabIsActive) private var isActive
    @Environment(\.shellUsesRegularLayout) private var regularLayout
    @State private var showingAddHabit = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var collapsedGroups: Set<UUID> = []
    /// Pending and held counts for the sync line, read from the store when it changes — not on
    /// every render (`SyncStatusCounts`). Zero while signed out, when nothing reads them.
    @State private var syncCounts = SyncStatusCounts.Counts()
    /// "Sign in again": the row's tap and the login sheet it opens, presented from here because
    /// the sign-in removes the row, and a sheet the row presented closed with it before its account
    /// step could appear (review critic-1).
    @State private var signInAgain = SignInAgainFlow()
    private var auth = AuthService.shared
    private var sync = SyncService.shared
    #if DEBUG
    /// Counts this view's creations for the hosted shell tests (`ShellTabLifetime`).
    @StateObject private var lifetime: ShellTabLifetime
    #endif

    init(shell: ShellState) {
        self.shell = shell
        #if DEBUG
        _lifetime = StateObject(wrappedValue: ShellTabLifetime(.today, shell: shell))
        #endif
    }

    /// The day the screen shows and checks in to.
    private var selectedDate: Date { shell.todayDate }

    /// Habits split into ordered sections by group; falls back to a single flat
    /// section when the user has no groups.
    private var groupedSections: [(group: HabitGroup?, habits: [Habit])] {
        guard !groups.isEmpty else { return [(nil, habits)] }
        let groupIds = Set(groups.map { $0.id })
        var sections: [(group: HabitGroup?, habits: [Habit])] = []
        for g in groups {
            let hs = habits.filter { $0.groupId == g.id }
            if !hs.isEmpty { sections.append((g, hs)) }
        }
        let ungrouped = habits.filter { $0.groupId == nil || !groupIds.contains($0.groupId!) }
        if !ungrouped.isEmpty { sections.append((nil, ungrouped)) }
        return sections
    }

    private var completedCount: Int {
        habits.filter { $0.isCompletedOn(selectedDate) }.count
    }

    var body: some View {
        #if DEBUG
        let _ = lifetime
        #endif
        todayContent
    }

    private var todayContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                WeekStripView(selectedDate: $shell.todayDate)
                    .padding(.horizontal)

                // The sync line sits under the progress card (M2, "Sync status where the user
                // works"); with no habits there is no card, and only the reauth row can show.
                // `syncStatus` is nil when signed out, so a signed-out Today — the store
                // screenshots — is laid out exactly as before: the card alone in its stack.
                let syncStatus = SyncStatusLine.today(auth: auth, sync: sync, counts: syncCounts)
                if !habits.isEmpty {
                    VStack(spacing: 8) {
                        ProgressSummaryCard(
                            completed: completedCount,
                            total: habits.count
                        )
                        if let syncStatus {
                            SyncStatusRow(line: syncStatus, signInAgain: signInAgain)
                        }
                    }
                    .padding(.horizontal)
                } else if let syncStatus, syncStatus == .signInAgain {
                    SyncStatusRow(line: syncStatus, signInAgain: signInAgain)
                        .padding(.horizontal)
                }

                if habits.isEmpty {
                    EmptyStateView(showingAddHabit: $showingAddHabit)
                        .padding(.top, 40)
                } else if groups.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(habits) { habit in
                            HabitRowView(habit: habit, date: selectedDate)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(groupedSections, id: \.group?.id) { section in
                            VStack(spacing: 12) {
                                groupHeader(for: section.group, count: section.habits.count)
                                if !isCollapsed(section.group) {
                                    ForEach(section.habits) { habit in
                                        HabitRowView(habit: habit, date: selectedDate)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .shellReadableWidth(regularLayout)
        }
        .background(Color.appBackground)
        // No title of its own: the shell sets it from its own state (ContentView.title).
        .toolbar {
            // Gated inside the builder, not around the view: at regular width and on the Mac
            // every kept tab's toolbar lands in the one navigation bar, and only the place that
            // shows may contribute (D2).
            if isActive {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddHabit = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel("New Habit")
                }
            }
        }
        .sheet(isPresented: $showingAddHabit) {
            AddHabitView()
        }
        // The "Sign in again" row's sign-in. Here, not on the row: the sign-in removes the row,
        // and the sheet has to stay for its next step — the account screen, when the device holds
        // another account's habits or habits of unknown owner — and for the sync as it closes.
        .sheet(isPresented: Bindable(signInAgain).showingLogin, onDismiss: {
            Task { await signInAgain.loginClosed(context: modelContext) }
        }) {
            LoginView(prefilledEmail: signInAgain.loginEmail)
        }
        // Coming back to the app: the widget saves check-ins and queues deletions in its own
        // process. (Re-anchoring the day is the shell's, above the size-class branch.)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSyncCounts()
            }
        }
        // The counts change with every save (an edit makes a row pending), when a sync ends (it
        // acknowledged or held rows), and at sign-in and sign-out.
        .task { refreshSyncCounts() }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelContext.didSave)
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            refreshSyncCounts()
        }
        .onChange(of: sync.isSyncing) { _, syncing in
            if !syncing { refreshSyncCounts() }
        }
        .onChange(of: auth.isLoggedIn) { _, _ in refreshSyncCounts() }
    }

    /// Reads the store only while signed in: signed out, Today shows no sync line, and a store of
    /// years of check-ins is not walked for nothing. A read that fails keeps the last counts.
    private func refreshSyncCounts() {
        guard auth.isLoggedIn else {
            syncCounts = SyncStatusCounts.Counts()
            return
        }
        if let counts = try? SyncStatusCounts.read(in: modelContext, deletions: SyncDeletionQueue.live.pending()) {
            syncCounts = counts
        }
    }

    private func isCollapsed(_ group: HabitGroup?) -> Bool {
        guard let group else { return false }
        return collapsedGroups.contains(group.id)
    }

    @ViewBuilder
    private func groupHeader(for group: HabitGroup?, count: Int) -> some View {
        let title = group?.name ?? appLocalized("Ungrouped")
        let collapsed = isCollapsed(group)
        let header = Button {
            guard let id = group?.id else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsedGroups.contains(id) { collapsedGroups.remove(id) }
                else { collapsedGroups.insert(id) }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(group?.color ?? Color.gray)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if group != nil {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group == nil)
        .accessibilityLabel("\(title), \(count) habits")
        .accessibilityAddTraits(.isHeader)

        if group == nil {
            // The Ungrouped header is a section title, not a control. Removing .isButton from a
            // real Button is not reliable — the trait is intrinsic — so the button is replaced
            // by a plain element here instead of being annotated into one.
            header
                .accessibilityRemoveTraits(.isButton)
                .accessibilityRespondsToUserInteraction(false)
        } else {
            // The chevron is the only sign of the collapsed state, so nothing tells VoiceOver
            // what the double tap did without a value that changes with it.
            header.accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        }
    }
}

// MARK: - Week Strip
struct WeekStripView: View {
    @Binding var selectedDate: Date
    private let days = Date.lastNDays(7)
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Seven equal cells get about 46 pt each. From the first accessibility size "21" in
    /// .callout.bold no longer fits one and wrapped a digit per line ("2" over "1"), and "Mon"
    /// became "M" over "on". There the strip scrolls instead, opening on today at the trailing
    /// end, and each cell is as wide as its text.
    var body: some View {
        if typeSize.isAccessibilitySize {
            ScrollView(.horizontal) {
                strip(scrolling: true)
            }
            .defaultScrollAnchor(.trailing)
        } else {
            strip(scrolling: false)
        }
    }

    /// Names from `appCalendar`, not `Date.shortWeekday` (Shared/DateHelpers.swift): that builds a
    /// `DateFormatter` with no locale, so the strip drew and spoke "Mon Tue Wed" at the top of a
    /// Japanese-picked Today on an English device. `shortWeekdaySymbols` is the same "EEE" form.
    private func weekdayName(_ day: Date, in calendar: Calendar) -> String {
        calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
    }

    private func strip(scrolling: Bool) -> some View {
        let calendar = appCalendar
        return HStack(spacing: 8) {
            ForEach(days, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDate)
                let weekday = weekdayName(day, in: calendar)
                let dayNumber = String(calendar.component(.day, from: day))

                VStack(spacing: 4) {
                    Text(weekday)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white : .secondary)

                    Text(dayNumber)
                        .font(.callout.bold())
                        .foregroundStyle(isSelected ? .white : .primary)
                }
                .frame(maxWidth: .infinity)
                // A scroll view proposes no width, so the cell would hug its text; this keeps
                // the selected day's green pill around it.
                .padding(.horizontal, scrolling ? 12 : 0)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isSelected ? Color.green : Color.clear)
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedDate = day
                    }
                }
                // Without this the labels below land on both Texts, so the strip reads as
                // fourteen stops of duplicated static text instead of seven day buttons.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(isSelected ? "\(weekday) \(dayNumber), selected" : "\(weekday) \(dayNumber)")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                // .onTapGesture is not forwarded as the combined element's activation, so
                // without this the cell announces "button" and double-tap does nothing.
                .accessibilityAction {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedDate = day }
                }
            }
        }
    }
}

// MARK: - Progress Summary
struct ProgressSummaryCard: View {
    let completed: Int
    let total: Int
    @Environment(\.dynamicTypeSize) private var typeSize

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var body: some View {
        // At accessibility sizes the ring goes under the text: beside it, it leaves "completed"
        // too little width at .headline and the word breaks mid-way.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout())
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(completed)/\(total) completed")
                    .font(.headline)
                Text(motivationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !typeSize.isAccessibilitySize {
                Spacer()
            }

            ProgressRing(progress: progress)
                // The ring grows with its label (see ProgressRing); past .accessibility1 it
                // would only be a larger circle around the same information.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(completed) of \(total) habits completed, \(Int(progress * 100)) percent")
        // `.ignore` drops the motivation line; as the value it stays out of the label and is
        // re-announced when the count changes.
        .accessibilityValue(motivationMessage)
    }

    private var motivationMessage: LocalizedStringKey {
        switch progress {
        case 1.0: return "All done! Perfect day!"
        case 0.75..<1.0: return "Almost there! Keep going!"
        case 0.5..<0.75: return "Halfway done! Nice!"
        case 0.01..<0.5: return "Good start! Keep it up!"
        default: return "Let's get started!"
        }
    }
}

/// The completion ring of ProgressSummaryCard. It was a fixed 50 pt around a `.caption` label,
/// so from the first accessibility size "100%" truncated to "1…". The diameter now scales with
/// the same text style as the label, so the label fits at every size it fits at the default
/// (50 pt exactly there). Its own view so the cap applied by the card reaches the metric.
private struct ProgressRing: View {
    let progress: Double
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 50

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)

            Text("\(Int(progress * 100))%")
                .font(.caption.bold())
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Habit Row
struct HabitRowView: View {
    @Environment(\.modelContext) private var modelContext
    let habit: Habit
    let date: Date

    @State private var justCompleted = false
    @State private var showingEdit = false
    @State private var showingNote = false
    @State private var noteText = ""

    private var isCompleted: Bool {
        habit.isCompletedOn(date)
    }

    private var todayRecord: HabitRecord? {
        return habit.records.first { HabitCalendar.record($0.date, isOnSameDayAs: date) }
    }

    var body: some View {
        // The adjustable action brings the adjustable trait with it, so it has to stay off
        // binary rows — VoiceOver would otherwise offer to adjust a value they do not have.
        if habit.habitKind == .count {
            rowContent
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: withAnimation { incrementCount() }
                    case .decrement: withAnimation { decrementCount() }
                    @unknown default: break
                    }
                }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(habit.emoji)
                    .font(.title2)

                habitInfo

                Spacer()

                trailingControl
            }
            .padding()

            if let record = todayRecord, let note = record.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSecondaryBackground)
        )
        .contextMenu {
            Button {
                showingEdit = true
            } label: {
                Label("Edit Habit", systemImage: "pencil")
            }
            if habit.habitKind == .count {
                Button {
                    withAnimation { incrementCount() }
                } label: {
                    Label("Add 1", systemImage: "plus")
                }
                if habit.loggedValue(on: date) > 0 {
                    Button {
                        withAnimation { decrementCount() }
                    } label: {
                        Label("Subtract 1", systemImage: "minus")
                    }
                    Button(role: .destructive) {
                        withAnimation { resetCount() }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            if isCompleted {
                Button {
                    noteText = todayRecord?.note ?? ""
                    showingNote = true
                } label: {
                    Label(todayRecord?.note != nil ? "Edit Note" : "Add Note", systemImage: "note.text")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddHabitView(editingHabit: habit)
        }
        .alert("Note", isPresented: $showingNote) {
            TextField("How did it go?", text: $noteText)
            Button("Save") {
                todayRecord?.note = noteText.isEmpty ? nil : noteText
                todayRecord?.touch()
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add a note for today's check-in.")
        }
        .accessibilityElement(children: .combine)
        // A ternary nested inside the interpolation would be a plain String argument, never
        // translated; each whole phrase has to be its own key.
        // The emoji is decorative and is already drawn above — its CLDR name ("droplet") would
        // be spoken before every habit in the list.
        .accessibilityLabel(isCompleted ? "\(habit.name), completed" : "\(habit.name), not completed")
        // The label overrides everything `.combine` merged, so the rest of the row has to be
        // rebuilt here or it is never announced.
        .accessibilityValue(spokenDetail)
        // On a count habit the combined element activates the increment button, not a toggle.
        .accessibilityHint(habit.habitKind == .count ? "Double tap to add one" : "Double tap to toggle completion")
        // Whether SwiftUI republishes `.contextMenu` items as custom actions varies by platform
        // and version, and this row also overrides its children with `.combine`. These are the
        // actions VoiceOver is guaranteed to get; the cost if the menu does publish its own is a
        // duplicated rotor entry, against an unreachable Reset / Subtract 1 if it does not.
        .accessibilityActions {
            Button("Edit Habit") { showingEdit = true }
            if habit.habitKind == .count {
                Button("Add 1") { withAnimation { incrementCount() } }
                if habit.loggedValue(on: date) > 0 {
                    Button("Subtract 1") { withAnimation { decrementCount() } }
                    Button("Reset") { withAnimation { resetCount() } }
                }
            }
            if isCompleted {
                Button(todayRecord?.note != nil ? "Edit Note" : "Add Note") {
                    noteText = todayRecord?.note ?? ""
                    showingNote = true
                }
            }
        }
    }

    /// Everything the row draws besides its name and completion state, in the order it is drawn.
    ///
    /// A count row re-speaks this on every increment (it is the adjustable value), so the note —
    /// the one unbounded part — is left to the binary rows, where nothing re-reads it.
    private var spokenDetail: String {
        var parts: [String] = []
        if habit.habitKind == .count { parts.append(spokenCount) }
        if !habit.isScheduled(on: date) {
            parts.append(appLocalized("Rest day"))
        } else if habit.schedule == .timesPerWeek {
            parts.append(appLocalized("\(habit.weeklyCompletions(containing: date))/\(habit.timesPerWeek) this week"))
        }
        let streak = habit.currentStreak(from: date)
        if streak > 0 {
            parts.append(habit.streakUnit == "week"
                ? appLocalized("\(streak) week streak")
                : appLocalized("\(streak) day streak"))
        }
        if habit.habitKind != .count, let note = todayRecord?.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: ", ")
    }

    /// `countLabel` spelled out: VoiceOver reads "3/8" as a date or a fraction.
    private var spokenCount: String {
        let logged = SafeNumber.amount(habit.loggedValue(on: date))
        let target = SafeNumber.amount(habit.targetValue)
        let progress = appLocalized("\(logged) of \(target)")
        guard let unit = habit.unit, !unit.isEmpty else { return progress }
        return "\(progress) \(unit)"
    }

    @ViewBuilder
    private var habitInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(habit.name)
                .font(.body.weight(.medium))
            if habit.habitKind == .count {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !habit.isScheduled(on: date) {
                Text("Rest day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if habit.schedule == .timesPerWeek {
                Text("\(habit.weeklyCompletions(containing: date))/\(habit.timesPerWeek) this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let streak = habit.currentStreak(from: date)
            if streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    // Not "\(streak) \(habit.streakUnit) streak": the unit would reach every
                    // language as the English word.
                    Text(habit.streakUnit == "week" ? "\(streak) week streak" : "\(streak) day streak")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if habit.habitKind == .count {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { incrementCount() }
            } label: {
                countRing
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add one to \(habit.name)")
            .accessibilityValue(countLabel)
        } else {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { toggleCompletion() }
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(isCompleted ? habit.color : Color.gray.opacity(0.4))
                    .scaleEffect(justCompleted ? 1.3 : (isCompleted ? 1.1 : 1.0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Mark \(habit.name) incomplete" : "Mark \(habit.name) complete")
        }
    }

    private var countRing: some View {
        ZStack {
            Circle()
                .stroke(habit.color.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: SafeNumber.unitInterval(habit.progress(on: date)))
                .stroke(habit.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(habit.color)
            } else {
                Text(SafeNumber.amount(habit.loggedValue(on: date)))
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 40, height: 40)
        .scaleEffect(justCompleted ? 1.2 : 1.0)
    }

    private func toggleCompletion() {
        // Shared with the widget, the watch and Siri — see HabitCheckIn.
        let result = HabitCheckIn.tap(habit, on: date, in: modelContext)
        if result.isCompleted {
            justCompleted = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.2)) {
                    justCompleted = false
                }
            }

            #if os(iOS)
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            #endif
        } else {
            justCompleted = false
        }
        do {
            try modelContext.save()
            // Queue the tombstone only once the deletion is actually saved.
            if let id = result.deletedRecordID { SyncService.shared.trackDeletedEntry(id) }
        } catch {
            #if DEBUG
            print("Failed to save habit completion: \(error)")
            #endif
        }
        refresh(checkedIn: result.deletedRecordID == nil)
    }

    /// After a save: the widgets and the badge, always. A check-in goes through `CheckInEffects`
    /// (RELEASE-1.4.0.md D4), which also ends the habit's snooze and withdraws its banners, but
    /// only for a day those can be asking for (`CheckInEffects.endsReminders`): `date` is the week
    /// strip's, and a backfill of Wednesday at 20:30 on Thursday must leave Thursday's snooze and
    /// banner alone. Taking a check-in back (an un-check, a unit removed) leaves them too, since
    /// they still ask for something not done.
    private func refresh(checkedIn: Bool) {
        if checkedIn {
            CheckInEffects.afterCheckIn(habitID: habit.id, container: modelContext.container,
                                        endsReminders: CheckInEffects.endsReminders(checkingIn: date))
        } else {
            WidgetCenter.shared.reloadAllTimelines()
            NotificationService.shared.updateBadge(modelContainer: modelContext.container)
        }
    }

    // MARK: - Count habit logging

    /// Through `SafeNumber`, never `Int(_:)`: a synced amount can be anything, and a trap here
    /// took down Today on every launch.
    private var countLabel: String {
        let logged = SafeNumber.amount(habit.loggedValue(on: date))
        let target = SafeNumber.amount(habit.targetValue)
        let unit = habit.unit.map { " \($0)" } ?? ""
        return "\(logged)/\(target)\(unit)"
    }

    private func incrementCount() {
        // A count tap adds one unit and never deletes — shared with the widget, watch and Siri.
        if HabitCheckIn.tap(habit, on: date, in: modelContext).isCompleted {
            justCompleted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.2)) { justCompleted = false }
            }
        }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        saveAndRefresh(checkedIn: true)
    }

    private func decrementCount() {
        guard let record = habit.record(on: date) else { return }
        if record.value <= 1 {
            SyncService.shared.trackDeletedEntry(record.id.uuidString)
            modelContext.delete(record)
        } else {
            record.value -= 1
            record.touch()
        }
        saveAndRefresh(checkedIn: false)
    }

    private func resetCount() {
        guard let record = habit.record(on: date) else { return }
        SyncService.shared.trackDeletedEntry(record.id.uuidString)
        modelContext.delete(record)
        saveAndRefresh(checkedIn: false)
    }

    private func saveAndRefresh(checkedIn: Bool) {
        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            print("Failed to save count update: \(error)")
            #endif
        }
        refresh(checkedIn: checkedIn)
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    @Binding var showingAddHabit: Bool
    @State private var showingTemplates = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.fill")
                .scaledSystemFont(size: 60, relativeTo: .largeTitle)
                .foregroundStyle(.green.opacity(0.6))
                .accessibilityHidden(true)
                // Decoration: uncapped it pushes the "Add Habit" button below the fold.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)

            Text("Start Your Journey")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Add your first habit and begin\nbuilding better routines.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingAddHabit = true
            } label: {
                Label("Add First Habit", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.green))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Button {
                showingTemplates = true
            } label: {
                Label("Browse Templates", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingTemplates) {
            HabitTemplatesView()
        }
    }
}
