import SwiftUI
import SwiftData
import StoreKit
import UserNotifications

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
    /// The folded group headers, per device (RELEASE-1.4.1.md D15): their ids, comma-separated.
    /// Neither synced nor in a backup — how this screen is folded is this device's — and it
    /// survives a relaunch, a size-class crossing and the tab being rebuilt, which the 1.4.0
    /// `@State` did not. An id whose group is gone is never asked about again.
    @AppStorage("stride_today_collapsed_groups") private var collapsedGroupsStorage = ""
    /// The app's one cache, or the one a hosted test put in the environment over a store of its
    /// own (RELEASE-1.5.0.md D9, as WeeklyReviewView). 1.4.2 read `StatsCache.shared`.
    @Environment(\.statsCache) private var cache
    /// Pending and held counts for the sync line, read from the store when it changes — not on
    /// every render (`SyncStatusCounts`). Zero while signed out, when nothing reads them.
    @State private var syncCounts = SyncStatusCounts.Counts()
    /// "Sign in again": the row's tap and the login sheet it opens, presented from here because
    /// the sign-in removes the row, and a sheet the row presented closed with it before its account
    /// step could appear (review critic-1).
    @State private var signInAgain = SignInAgainFlow()
    private var auth = AuthService.shared
    private var sync = SyncService.shared
    /// The week card's copy and its tap (RELEASE-1.4.2.md D12, D8): read at the render and at the tap.
    private var store = StoreService.shared
    /// Bumped by each write of the inline cards' dismissal state, which lives in
    /// `UserDefaults.standard` (`InlinePromptStore`) and is read at every render.
    @State private var cardStateRevision = 0
    /// The cards' state for this view only, in an automated run, where `InlinePromptStore.live` is
    /// read-only: × and "Not now" still hide a card on screen, and nothing reaches the app's
    /// defaults.
    @State private var unsavedCardState: InlinePrompts.DismissalState?
    /// The system's notification permission, for the reminder offer (RELEASE-1.5.0.md D5): read
    /// when Today appears, when the scene becomes active and after the offer's tap. Nil until read,
    /// which offers nothing.
    @State private var notificationStatus: UNAuthorizationStatus?
    /// The at-risk rows, latched (D7): set when Today becomes the shown tab, the day changes or the
    /// scene becomes active, and read by every render in between, so a check-in never moves a row
    /// under the user's finger. A render whose key differs from the latch's reads the live set
    /// (the next pass), which the latch then takes.
    @State private var atRiskLatch: AtRiskLatch?
    /// The row VoiceOver is moved to when the Weekly Review asks for a habit (D6, `todayFocusHabitID`).
    @AccessibilityFocusState private var focusedHabitID: UUID?
    /// The system's rating prompt (N3), asked only through `ReviewPrompter`.
    @Environment(\.requestReview) private var requestReview
    #if DEBUG
    /// Counts this view's creations for the hosted shell tests (`ShellTabLifetime`).
    @StateObject private var lifetime: ShellTabLifetime
    /// The hosted tests' seams (TodayRenderTests, RELEASE-1.5.0.md D9): a fixed clock, a
    /// NotificationService over a recording center, the cards' state on scratch defaults, and the
    /// entitlement. Nil: the app's own.
    private let testClock: (() -> Date)?
    private let injectedNotifications: NotificationService?
    private let injectedCardStore: InlinePromptStore?
    private let injectedIsPro: Bool?
    #endif

    init(shell: ShellState) {
        self.shell = shell
        #if DEBUG
        _lifetime = StateObject(wrappedValue: ShellTabLifetime(.today, shell: shell))
        testClock = nil
        injectedNotifications = nil
        injectedCardStore = nil
        injectedIsPro = nil
        #endif
    }

    #if DEBUG
    /// Today as it reads at `clock()` (hosted tests only), over the given services. A test moves
    /// the clock and then re-anchors the shell, as ContentView does when the day changes.
    init(shell: ShellState, clock: @escaping () -> Date, notifications: NotificationService? = nil,
         cardStore: InlinePromptStore? = nil, isPro: Bool? = nil) {
        self.shell = shell
        _lifetime = StateObject(wrappedValue: ShellTabLifetime(.today, shell: shell))
        testClock = clock
        injectedNotifications = notifications
        injectedCardStore = cardStore
        injectedIsPro = isPro
    }

    /// Today as it reads at the fixed instant `now` (hosted tests only).
    init(shell: ShellState, now: Date, notifications: NotificationService? = nil,
         cardStore: InlinePromptStore? = nil, isPro: Bool? = nil) {
        self.init(shell: shell, clock: { now }, notifications: notifications, cardStore: cardStore, isPro: isPro)
    }

    /// Each row Today moved VoiceOver focus to for `todayFocusHabitID`, in order (hosted tests:
    /// VoiceOver is not running there, so `UIAccessibility.focusedElement` says nothing).
    @MainActor static var focusRequests: [UUID] = []
    #endif

    /// The clock: the real one, or a hosted test's.
    private var now: Date {
        #if DEBUG
        testClock?() ?? Date()
        #else
        Date()
        #endif
    }

    private var notifications: NotificationService {
        #if DEBUG
        injectedNotifications ?? .shared
        #else
        .shared
        #endif
    }

    private var cardStore: InlinePromptStore {
        #if DEBUG
        injectedCardStore ?? .live
        #else
        .live
        #endif
    }

    private var isPro: Bool {
        #if DEBUG
        injectedIsPro ?? store.isPro
        #else
        store.isPro
        #endif
    }

    /// The day the screen shows and checks in to.
    private var selectedDate: Date { shell.todayDate }

    /// What the at-risk order is latched for (D7): the shown tab, today and the day shown. A
    /// change of any of them is a new pass.
    struct AtRiskKey: Hashable {
        let isActive: Bool
        let today: Int
        let selected: Int
    }

    struct AtRiskLatch: Equatable {
        let key: AtRiskKey
        let ids: Set<UUID>
    }

    /// The habits the day shows (`shownHabits`) split into ordered sections by group; falls back
    /// to a single flat section when the user has no groups.
    private func groupedSections(_ shown: [Habit]) -> [(group: HabitGroup?, habits: [Habit])] {
        guard !groups.isEmpty else { return [(nil, shown)] }
        let groupIds = Set(groups.map { $0.id })
        var sections: [(group: HabitGroup?, habits: [Habit])] = []
        for g in groups {
            let hs = shown.filter { $0.groupId == g.id }
            if !hs.isEmpty { sections.append((g, hs)) }
        }
        let ungrouped = shown.filter { $0.groupId == nil || !groupIds.contains($0.groupId!) }
        if !ungrouped.isEmpty { sections.append((nil, ungrouped)) }
        return sections
    }

    /// The habits a day shows (RELEASE-1.4.1.md D8, O11). Today shows every habit. A past day shows
    /// only those that had started by then: min(creation day, earliest live record) on or before
    /// it (`HabitStats.startDay`), so a habit created today is not on yesterday — until a check-in
    /// is backfilled there in History, which moves its start. Today itself is never filtered, so
    /// Today, the widget and the badge (which counts only today) still agree. `stats` are the
    /// habits' own, in order (`StatsCache.stats(for:)`). `dayKey` and `todayKey` are day-keys
    /// (`DailyProgress.today(now:calendar:)` of the week strip's date and of the clock), never
    /// instants: `HabitStats.dayNumber(of:in:)` takes an instant at exactly UTC midnight (Sunday
    /// 16:00:00 PST) for Monday's key, which made today a "past day" here (Gemini review,
    /// 2026-11-27).
    static func shownHabits(_ habits: [Habit], stats: [HabitStats], on dayKey: Date, todayKey: Date) -> [Habit] {
        let shown = HabitStats.dayNumber(ofKey: dayKey)
        guard shown < HabitStats.dayNumber(ofKey: todayKey) else { return habits }
        return zip(habits, stats).filter { HabitStats.dayNumber(ofKey: $0.1.startDay) <= shown }.map(\.0)
    }

    var body: some View {
        #if DEBUG
        let _ = lifetime
        #endif
        todayContent
    }

    /// Everything one render says about the day, read once: every habit's stats from the cache
    /// (ONE store fetch after a clear-all; the rows' own reads are then dictionary hits), the
    /// habits the day shows, the card's `DailyProgress`, and — on today only — each row's D7 words
    /// and the at-risk set the order uses.
    struct Pass {
        let now: Date
        let calendar: Calendar
        let stats: [HabitStats]
        let shown: [Habit]
        /// The card (RELEASE-1.5.0.md D2): the day shown, every habit's `DailyProgress` state.
        let progress: DailyProgress
        let key: AtRiskKey
        var isTodaySelected: Bool { key.selected == key.today }
        /// D7's words by habit; empty unless today is shown.
        let words: [UUID: TodayAtRisk.Words]
        /// The at-risk habits as this moment reads them.
        let liveAtRisk: Set<UUID>
        /// The set the order uses: the latch's for this key, else the live one.
        let atRisk: Set<UUID>
    }

    private func makePass() -> Pass {
        let now = self.now
        let calendar = Calendar.current
        // Both days keyed once, as instants (`HabitCalendar.dayKey(forInstant:)`), and only the
        // keys go on: the cache and `shownHabits` would key `now` with `HabitStats.dayNumber(of:)`,
        // which reads an exact UTC midnight (Sunday 16:00:00 PST) as Monday's day-key while the
        // card, the words and the review read Sunday (as WeeklyReviewView and TodayCards key it).
        let todayKey = DailyProgress.today(now: now, calendar: calendar)
        let selectedKey = DailyProgress.today(now: selectedDate, calendar: calendar)
        let stats = cache.stats(for: habits, today: todayKey, calendar: calendar)
        let shown = Self.shownHabits(habits, stats: stats, on: selectedKey, todayKey: todayKey)
        let key = AtRiskKey(isActive: isActive, today: HabitStats.dayNumber(ofKey: todayKey),
                            selected: HabitStats.dayNumber(ofKey: selectedKey))
        let words = key.selected == key.today
            ? Self.rowWords(habits, stats: stats, now: now, calendar: calendar,
                            dailyReminder: WeeklyReviewView.dailyReminderTime(notifications))
            : [:]
        let live = Set(words.filter { $0.value.isAtRisk }.map(\.key))
        let latched = atRiskLatch.flatMap { $0.key == key ? $0.ids : nil }
        return Pass(now: now, calendar: calendar, stats: stats, shown: shown,
                    progress: DailyProgress(of: stats, on: selectedKey), key: key,
                    words: words, liveAtRisk: live, atRisk: latched ?? live)
    }

    /// D7's words for each habit at `now` (today only), by `TodayAtRisk`: the evening a daily or
    /// specific-days habit is judged by is its own reminder's when on, else the Daily Reminder's
    /// when on, else 18:00 (`WeeklyReviewMath.eveningTime`).
    static func rowWords(_ habits: [Habit], stats: [HabitStats], now: Date, calendar: Calendar,
                         dailyReminder: WeeklyReviewMath.TimeOfDay?) -> [UUID: TodayAtRisk.Words] {
        var words: [UUID: TodayAtRisk.Words] = [:]
        for (habit, stats) in zip(habits, stats) {
            let own = habit.reminderEnabled
                ? WeeklyReviewMath.TimeOfDay(hour: habit.reminderHour, minute: habit.reminderMinute) : nil
            let evening = WeeklyReviewMath.eveningTime(habitReminder: own, dailyReminder: dailyReminder)
            if let said = TodayAtRisk.words(for: stats, now: now, calendar: calendar, eveningTime: evening) {
                words[habit.id] = said
            }
        }
        return words
    }

    /// One section's rows in D7's order: at risk first, on today only, by the pass's latched set.
    private func ordered(_ section: [Habit], in pass: Pass) -> [Habit] {
        guard pass.isTodaySelected, !pass.atRisk.isEmpty else { return section }
        return TodayAtRisk.atRiskFirst(section) { pass.atRisk.contains($0.id) }
    }

    /// Latches the at-risk set for this pass (D7). Called when the key changes — Today shown or
    /// hidden, the day changing, another day picked — and when the scene becomes active.
    private func latchAtRisk() {
        let pass = makePass()
        let latch = AtRiskLatch(key: pass.key, ids: pass.liveAtRisk)
        if atRiskLatch != latch { atRiskLatch = latch }
    }

    private var todayContent: some View {
        let pass = makePass()
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    WeekStripView(selectedDate: $shell.todayDate, today: pass.now)
                        .padding(.horizontal)

                    summary(pass)

                    rows(pass)
                }
                .padding(.vertical)
                .shellReadableWidth(regularLayout)
                .sweepScrollable()
            }
            // The Weekly Review's "At risk this week" (D6): `todayFocusHabitID`, consumed once
            // Today is the shown tab — it may be created after the id is set, and a kept-alive
            // Today sees it change.
            .task(id: FocusRequest(habitID: shell.todayFocusHabitID, isActive: isActive)) {
                await bringFocusedHabitIntoView(proxy)
            }
        }
        .background(Color.appBackground)
        // D7: the at-risk order, latched for this pass.
        .task(id: pass.key) { latchAtRisk() }
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
        // process. (Re-anchoring the day is the shell's, above the size-class branch.) A new pass
        // for the at-risk order (D7), and the permission may have changed in Settings (D5).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSyncCounts()
                latchAtRisk()
                Task { await refreshNotificationStatus() }
            }
        }
        // The counts change with every save (an edit makes a row pending), when a sync ends (it
        // acknowledged or held rows), and at sign-in and sign-out.
        .task { refreshSyncCounts() }
        .task { await refreshNotificationStatus() }
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
        // N3: the install date `ReviewPromptRule` counts its 3 days from, recorded once (never in
        // an automated run: `recordInstallDateIfNeeded`).
        .task { ReviewPrompter.live.recordInstallDateIfNeeded() }
        // N3: the rows ask, after a write, through this hook; it knows what is presented.
        .environment(\.reviewPromptHook, reviewPromptHook)
    }

    /// The progress card, the sync line and the one inline card.
    @ViewBuilder
    private func summary(_ pass: Pass) -> some View {
        // The sync line sits under the progress card (M2, "Sync status where the user
        // works"); with no habits there is no card, and only the reauth row can show.
        // `syncStatus` is nil when signed out, so a signed-out Today — the store
        // screenshots — is laid out exactly as before: the card alone in its stack.
        let syncStatus = SyncStatusLine.today(auth: auth, sync: sync, counts: syncCounts)
        if !pass.shown.isEmpty {
            VStack(spacing: 8) {
                ProgressSummaryCard(progress: pass.progress)
                if let syncStatus {
                    SyncStatusRow(line: syncStatus, signInAgain: signInAgain)
                }
            }
            .padding(.horizontal)

            // At most one inline card, under the progress card (D5): missed yesterday, the week
            // card (Monday and Tuesday), the reminder offer.
            if let card = inlineCard(pass) {
                inlineCardView(card)
                    .padding(.horizontal)
            }
        } else if let syncStatus, !habits.isEmpty || syncStatus == .signInAgain {
            // A past day before any habit started: the line is about the store, not the day.
            SyncStatusRow(line: syncStatus, signInAgain: signInAgain)
                .padding(.horizontal)
        }
    }

    /// The habit rows, in sections when the user has groups.
    @ViewBuilder
    private func rows(_ pass: Pass) -> some View {
        if habits.isEmpty {
            EmptyStateView(showingAddHabit: $showingAddHabit)
                .padding(.top, 40)
        } else if pass.shown.isEmpty {
            // Every habit started after this day (D8). Backfilling one moves to History.
            Text("No habits had started by this day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.top, 24)
        } else if groups.isEmpty {
            LazyVStack(spacing: 12) {
                ForEach(ordered(pass.shown, in: pass)) { habit in
                    row(habit, pass)
                }
            }
            .padding(.horizontal)
            // `-scrollTo todayHabits`: the rows, under the tab bar at accessibility sizes,
            // for scripts/a11y_sweep.sh (DEBUG only).
            .sweepAnchor("todayHabits")
        } else {
            LazyVStack(spacing: 16) {
                ForEach(groupedSections(pass.shown), id: \.group?.id) { section in
                    VStack(spacing: 12) {
                        groupHeader(for: section.group, count: section.habits.count)
                        if !isCollapsed(section.group) {
                            ForEach(ordered(section.habits, in: pass)) { habit in
                                row(habit, pass)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            // The same anchor with groups (the Pro sweep's data, RELEASE-1.5.0.md V5).
            .sweepAnchor("todayHabits")
        }
    }

    private func row(_ habit: Habit, _ pass: Pass) -> some View {
        HabitRowView(habit: habit, date: selectedDate, now: pass.now, words: pass.words[habit.id])
            // The focus target (D6): what `todayFocusHabitID` scrolls to and moves VoiceOver to.
            .id(habit.id)
            .accessibilityFocused($focusedHabitID, equals: habit.id)
    }

    // MARK: - The focus target (RELEASE-1.5.0.md D6)

    struct FocusRequest: Hashable {
        let habitID: UUID?
        let isActive: Bool
    }

    /// Brings `shell.todayFocusHabitID` into view, as ShellState documents it: expands the habit's
    /// group if it is folded (a UI preference, never the store), scrolls its row into view, moves
    /// VoiceOver focus to it, then consumes the id. A habit Today does not show (deleted or
    /// archived meanwhile) is consumed all the same. Waits while Today is hidden.
    private func bringFocusedHabitIntoView(_ proxy: ScrollViewProxy) async {
        guard isActive, let id = shell.todayFocusHabitID else { return }
        if let habit = habits.first(where: { $0.id == id }) {
            if let group = habit.groupId, collapsedGroups.contains(group) {
                var folded = collapsedGroups
                folded.remove(group)
                collapsedGroupsStorage = Self.storage(ofCollapsedGroups: folded)
            }
            // One layout pass for a group just expanded, or a Today created a moment ago.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, shell.todayFocusHabitID == id else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
            focusedHabitID = id
            #if DEBUG
            Self.focusRequests.append(id)
            #endif
        }
        shell.consumeTodayFocus()
    }

    // MARK: - The inline cards (RELEASE-1.4.2.md D12, RELEASE-1.5.0.md D5)

    /// Today's one inline card, from `InlinePrompts` (TodayCards.card). The dismissal state is read
    /// here at every render (`cardStateRevision` redraws after a write); so are the Daily
    /// Reminder (NotificationService is not observable) and the habits' reminders.
    private func inlineCard(_ pass: Pass) -> InlinePrompts.Card? {
        _ = cardStateRevision
        let live = InlinePrompts.TodayFacts(
            isTodaySelected: pass.isTodaySelected,
            permissionUndecided: notificationStatus == .notDetermined,
            anyReminderOn: TodayCards.anyReminderOn(habits: habits, dailyReminderOn: notifications.isReminderEnabled))
        return TodayCards.card(habits: habits, cache: cache, now: pass.now, calendar: pass.calendar, isPro: isPro,
                               state: cardState, live: live, override: TodayCards.launchOverride)
    }

    private var cardState: InlinePrompts.DismissalState {
        unsavedCardState ?? cardStore.state
    }

    @ViewBuilder
    private func inlineCardView(_ card: InlinePrompts.Card) -> some View {
        switch card {
        case .missedYesterday(let missed):
            missedYesterdayCard(missed)
        case .week(let week):
            weekCard(week)
        case .reminderOffer:
            reminderOfferCard
        }
    }

    private func weekCard(_ card: InlinePrompts.WeekCard) -> some View {
        TodayWeekCard(card: card) {
            // Decided at the tap (D8): the review on last week for Pro, the paywall resuming it.
            shell.issue(card.issuer, isPro: isPro)
        } onDismiss: {
            withAnimation(.easeInOut(duration: 0.2)) {
                updateCardState { InlinePrompts.dismissed(card, in: $0) }
            }
        }
        // A free card counts its week once it is on screen: not while the shell keeps Today
        // hidden (regular width, the Mac).
        .task(id: isActive ? card.shownWeek.mondayNumber : nil) {
            guard isActive else { return }
            updateCardState { InlinePrompts.shown(card, in: $0) }
        }
    }

    /// D5's first card: "Show yesterday" moves Today to yesterday (the shell's day; the title then
    /// reads "Yesterday"), where each habit can be checked in place. Nothing is written to the
    /// store until the user checks something. "Not now" hides it for the rest of today.
    private func missedYesterdayCard(_ card: InlinePrompts.MissedYesterdayCard) -> some View {
        TodayPromptCard(kind: .missedYesterday(openCount: card.openCount)) {
            let calendar = Calendar.current
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
            else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                shell.todayDate = yesterday
            }
        } onNotNow: {
            withAnimation(.easeInOut(duration: 0.2)) {
                updateCardState { InlinePrompts.dismissed(card, in: $0) }
            }
        }
    }

    /// D5's last card: "Turn on" asks for permission on the tap (rule 4's own exception: the
    /// system prompt appears only here or on a reminder toggle) and turns the Daily Reminder on
    /// at its time (default 20:00). Answered either way, and on "Not now", it never shows again.
    private var reminderOfferCard: some View {
        TodayPromptCard(kind: .reminderOffer) {
            withAnimation(.easeInOut(duration: 0.2)) {
                updateCardState { InlinePrompts.reminderOfferAnswered(in: $0) }
            }
            let notifications = self.notifications
            let container = modelContext.container
            Task {
                // Every reminder-on habit is scheduled at a grant (`permissionGranted`), then the
                // Daily Reminder itself, as Settings' switch does.
                if await notifications.ensureReminderPermission(schedulingExistingIn: container) == .allowed {
                    notifications.isReminderEnabled = true
                }
                await refreshNotificationStatus()
                cardStateRevision += 1
            }
        } onNotNow: {
            withAnimation(.easeInOut(duration: 0.2)) {
                updateCardState { InlinePrompts.reminderOfferAnswered(in: $0) }
            }
        }
    }

    private func refreshNotificationStatus() async {
        let status = await notifications.checkPermission()
        if notificationStatus != status { notificationStatus = status }
    }

    /// Writes the cards' state, unless DEBUG's `-inlineCard` fixes the card. In an automated run
    /// (a sweep, the E2E kit, a hosted test) the store is read-only: the change stays in this view.
    private func updateCardState(_ change: (InlinePrompts.DismissalState) -> InlinePrompts.DismissalState) {
        guard TodayCards.launchOverride == nil else { return }
        let store = cardStore
        let current = unsavedCardState ?? store.state
        let next = change(current)
        guard next != current else { return }
        if store.readOnly {
            unsavedCardState = next
        } else {
            store.save(next)
        }
        cardStateRevision += 1
    }

    // MARK: - The review prompt (N3)

    /// What the rows call after a write: `ReviewPrompter` decides, and asks the system only when
    /// nothing is presented — the shell's sheet, anything the window presents, Today's own sheets.
    private var reviewPromptHook: ReviewPromptHook {
        let shell = self.shell
        let requestReview = self.requestReview
        let todaySheet = showingAddHabit || signInAgain.showingLogin
        return ReviewPromptHook { checkIn in
            let presenting = todaySheet || shell.sheetOnScreen != nil || shell.presentation.isPresenting
            ReviewPrompter.live.afterCheckIn(checkIn, sheetShowing: presenting) { requestReview() }
        }
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

    /// The folded groups' ids (`collapsedGroupsStorage`).
    private var collapsedGroups: Set<UUID> {
        Self.collapsedGroups(from: collapsedGroupsStorage)
    }

    static func collapsedGroups(from storage: String) -> Set<UUID> {
        Set(storage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// Sorted, so the same set is always the same string.
    static func storage(ofCollapsedGroups ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
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
                var folded = collapsedGroups
                if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
                collapsedGroupsStorage = Self.storage(ofCollapsedGroups: folded)
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
    /// The strip's last day: Today's clock (a hosted test's fixed one, RELEASE-1.5.0.md D9).
    var today: Date = Date()
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The seven days ending today, at their local midnights (`Date.lastNDays(7)` on `today`).
    private var days: [Date] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: today)
        guard let start = calendar.date(byAdding: .day, value: -6, to: end) else { return [] }
        return Date.daysInRange(from: start, to: end)
    }

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
///
/// The selected day's `DailyProgress` (RELEASE-1.5.0.md D2): "done/due", where due counts only the
/// habits the day asks for (rest days, met weeks and habits not started yet are in neither), so a
/// rest day no longer reads as unfinished. "All done! Perfect day!" only when `isPerfect`; a day
/// with nothing due reads "Rest day" over an empty ring.
struct ProgressSummaryCard: View {
    let progress: DailyProgress
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the ring goes under the text: beside it, it leaves "completed"
        // too little width at .headline and the word breaks mid-way.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout())
        let completed = progress.done
        let total = progress.due
        let percent = Int(progress.fraction * 100)
        layout {
            VStack(alignment: .leading, spacing: 4) {
                if progress.isRestDay {
                    Text("Rest day")
                        .font(.headline)
                } else {
                    Text("\(completed)/\(total) completed")
                        .font(.headline)
                    Text(motivationMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !typeSize.isAccessibilitySize {
                Spacer()
            }

            ProgressRing(progress: progress.fraction, showsPercent: !progress.isRestDay)
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
        .modifier(SummaryAccessibility(progress: progress, completed: completed, total: total, percent: percent,
                                       motivation: motivationMessage))
        .accessibilityIdentifier("today.progressCard")
    }

    /// The card's spoken label: the count and percentage, or "Rest day"; the motivation line as
    /// the value (`.ignore` drops it; as the value it stays out of the label and is re-announced
    /// when the count changes).
    private struct SummaryAccessibility: ViewModifier {
        let progress: DailyProgress
        let completed: Int
        let total: Int
        let percent: Int
        let motivation: LocalizedStringKey

        func body(content: Content) -> some View {
            if progress.isRestDay {
                content.accessibilityLabel("Rest day")
            } else {
                content
                    .accessibilityLabel("\(completed) of \(total) habits completed, \(percent) percent")
                    .accessibilityValue(motivation)
            }
        }
    }

    private var motivationMessage: LocalizedStringKey {
        if progress.isPerfect { return "All done! Perfect day!" }
        switch progress.fraction {
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
    /// False on a rest day: an empty ring and no "0%" (D2).
    var showsPercent = true
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

            if showsPercent {
                Text("\(Int(progress * 100))%")
                    .font(.caption.bold())
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Habit Row
struct HabitRowView: View {
    @Environment(\.modelContext) private var modelContext
    /// nil: the app's own commit (`HabitEntryCommit.Environment.live`); the hosted tests inject one.
    @Environment(\.habitEntryCommit) private var injectedCommit
    let habit: Habit
    let date: Date
    /// Today's clock (TodayView's, a hosted test's fixed one): the day the cache builds for.
    let now: Date
    /// D7's words (RELEASE-1.5.0.md), nil unless the day shown is today (`TodayAtRisk`).
    let words: TodayAtRisk.Words?

    @State private var justCompleted = false
    @State private var showingEdit = false
    @State private var showingNote = false
    @State private var noteText = ""
    /// A write waiting for the user's go (D7): asked, and only then committed again, unchanged.
    @State private var confirming: PendingConfirmation?
    /// Today's N3 hook: called after a write, it may ask the system for a rating. Nil elsewhere.
    @Environment(\.reviewPromptHook) private var reviewPromptHook
    /// TodayView's cache (RELEASE-1.5.0.md D9).
    @Environment(\.statsCache) private var cache
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    init(habit: Habit, date: Date, now: Date = Date(), words: TodayAtRisk.Words? = nil) {
        self.habit = habit
        self.date = date
        self.now = now
        self.words = words
    }

    /// The orange D7's at-risk words are drawn in: #FF9500 made readable on the card, as the
    /// streak words are (#FF9500 itself is 1.97:1 on the light card).
    static func atRiskColor(in colorScheme: ColorScheme) -> Color {
        Color.readableText(hex: "#FF9500", in: colorScheme)
    }

    /// The check and count state is the habit's own, never the cache's (D4): the state the user
    /// sees is the one a tap flips, and the setter then re-reads the store.
    private var isCompleted: Bool {
        habit.isCompletedOn(date)
    }

    /// The day's kept record — the one a write edits (`Habit.record(on:)`), ghosts skipped.
    private var todayRecord: HabitRecord? {
        habit.record(on: date)
    }

    /// The streak and "x/y this week" text, from the cache (D3; W1's carried "per-call wrapper
    /// cost": two aggregate wrapper calls per row per render built two `HabitStats` each). Asked
    /// on every read, never kept across renders; TodayView's read of every habit has just
    /// refilled the cache, so this is a dictionary hit. Built for today's day-key, as TodayView
    /// asks: `now` itself at exactly UTC midnight would be keyed as the next day.
    private var stats: HabitStats {
        cache.stats(for: habit, today: DailyProgress.today(now: now, calendar: .current))
    }

    /// The day the row shows, as a day-key (`DailyProgress.today(now:calendar:)` of `date`): what
    /// the cache's answers are read for, as the card above reads the same day. The habit's own
    /// check state and the writes key `date` as `HabitCheckIn` does (RELEASE-1.4.1.md D4).
    private var dayKey: Date {
        DailyProgress.today(now: date, calendar: .current)
    }

    /// The week words the row shows: D7's on today (TodayView's); on another day, a
    /// times-per-week habit's week as it stood at that day's end (`TodayAtRisk.asOf`), so the
    /// row and the card above it read the same week.
    private func shownWords(_ stats: HabitStats) -> TodayAtRisk.Words? {
        words ?? TodayAtRisk.asOf(stats, on: dayKey)
    }

    /// The habit's description (`Habit.note`, D7): one secondary line under the name.
    private var habitDescription: String? {
        guard let text = habit.note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
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
                    beginNote()
                } label: {
                    Label(hasDayNote ? "Edit Note" : "Add Note", systemImage: "note.text")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddHabitView(editingHabit: habit)
        }
        .alert("Note", isPresented: $showingNote) {
            TextField("How did it go?", text: $noteText)
            Button("Save") {
                perform(.note(noteText))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add a note for today's check-in.")
        }
        .alert("Remove the check-in and its note?", isPresented: isConfirming(.removeNote), presenting: confirming) { pending in
            Button("Remove", role: .destructive) {
                withAnimation { perform(pending.write, confirmed: pending.about) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("This day has more than one note. Combine them into one?", isPresented: isConfirming(.combineNotes),
               presenting: confirming) { pending in
            Button("Combine") {
                withAnimation { perform(pending.write, confirmed: pending.about) }
            }
            Button("Cancel", role: .cancel) {}
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
                Button(hasDayNote ? "Edit Note" : "Add Note") {
                    beginNote()
                }
            }
        }
        // The description, on demand (VoiceOver's More Content): in the value, a count row would
        // re-speak it on every increment.
        .accessibilityCustomContent(AccessibilityCustomContentKey("Description"), habitDescription.map { Text(verbatim: $0) })
    }

    private var hasDayNote: Bool {
        guard let note = todayRecord?.note else { return false }
        return !note.isEmpty
    }

    /// Everything the row draws besides its name and completion state, in the order it is drawn.
    ///
    /// A count row re-speaks this on every increment (it is the adjustable value), so the note —
    /// the one unbounded part — is left to the binary rows, where nothing re-reads it.
    private var spokenDetail: String {
        let stats = self.stats
        var parts: [String] = []
        if habit.habitKind == .count { parts.append(spokenCount) }
        if !habit.isScheduled(on: date) {
            parts.append(appLocalized("Rest day"))
        } else if let words = shownWords(stats) {
            // D7: the same words the row draws, in the value (the label is completion only).
            parts.append(Self.spoken(words))
        }
        let streak = stats.currentStreak(asOf: dayKey)
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

    // MARK: D7's words

    // Each phrase is one key with its own numbers (positional in the catalogs, a plural on
    // each "more" and "days"): a phrase built from pieces cannot be ordered per language. The
    // locals carry names LocalizationSourceScanTests types as Int.

    /// The words drawn (RELEASE-1.5.0.md D7).
    static func text(_ words: TodayAtRisk.Words) -> Text {
        switch words {
        case .weekSoFar(let current, let total):
            return Text("\(current)/\(total) this week")
        case .weekOwing(let current, let total, let count):
            return Text("\(current)/\(total) this week · \(count) more")
        case .atRiskDaysLeft(let count, let days):
            return Text("\(count) more · \(days) days left")
        case .atRiskToday(let count):
            return Text("\(count) more · today")
        case .dueToday:
            return Text("Due today")
        }
    }

    /// The same words, spoken: in the row's accessibility value, in the picked language.
    static func spoken(_ words: TodayAtRisk.Words) -> String {
        switch words {
        case .weekSoFar(let current, let total):
            return appLocalized("\(current)/\(total) this week")
        case .weekOwing(let current, let total, let count):
            return appLocalized("\(current)/\(total) this week · \(count) more")
        case .atRiskDaysLeft(let count, let days):
            return appLocalized("\(count) more · \(days) days left")
        case .atRiskToday(let count):
            return appLocalized("\(count) more · today")
        case .dueToday:
            return appLocalized("Due today")
        }
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
        let stats = self.stats
        VStack(alignment: .leading, spacing: 2) {
            Text(habit.name)
                .font(.body.weight(.medium))
            if let habitDescription {
                // One line (D7), but whole at accessibility sizes, as the day's note under the
                // row is: the name column is about 230 pt there and "Morning Run" itself wraps,
                // so one line cut nearly every description off after a word or two, and three
                // still cut "Before breakfast, one lap of the park" (gate 8).
                Text(habitDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            if habit.habitKind == .count {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !habit.isScheduled(on: date) {
                Text("Rest day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let words = shownWords(stats) {
                Self.text(words)
                    .font(.caption)
                    .foregroundStyle(words.isAtRisk ? Self.atRiskColor(in: colorScheme) : Color.secondary)
            }
            let streak = stats.currentStreak(asOf: dayKey)
            if streak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    // Not "\(streak) \(habit.streakUnit) streak": the unit would reach every
                    // language as the English word.
                    // The flame keeps the system orange; the words are a darker shade of it where
                    // that does not read: #FF9500 is 1.97:1 on the light card (gate 8).
                    Text(habit.streakUnit == "week" ? "\(streak) week streak" : "\(streak) day streak")
                        .font(.caption)
                        .foregroundStyle(Color.readableText(hex: "#FF9500", in: colorScheme))
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

    // MARK: - Writes (RELEASE-1.4.1.md D4)

    /// What a row asks for. Kept while a confirmation is up, so the write the user confirms is
    /// exactly the one they asked for — re-resolved against the store again when it runs.
    enum RowWrite: Equatable {
        case checked(Bool)
        case value(Double)
        case note(String)
    }

    struct PendingConfirmation: Equatable {
        let write: RowWrite
        let about: HabitCheckIn.Confirmation
    }

    /// One alert per kind of question; dismissing it drops the pending write.
    private func isConfirming(_ about: HabitCheckIn.Confirmation) -> Binding<Bool> {
        Binding(get: { confirming?.about == about },
                set: { if !$0 { confirming = nil } })
    }

    /// Every row write: one HabitCheckIn setter inside `HabitEntryCommit.commit`, which saves,
    /// undoes on a failed save, queues tombstones only after it, and runs the effects (widgets,
    /// the snooze and banners for a check-in, the badge) and the stats bump.
    private func perform(_ write: RowWrite, confirmed: HabitCheckIn.Confirmation? = nil) {
        let habit = self.habit
        let date = self.date
        let context = modelContext
        // N3: the streak and the week before the write, to tell a milestone afterwards.
        let before = reviewPromptHook == nil ? nil : stats
        let outcome = HabitEntryCommit.commit(habitID: habit.id, day: date, in: context,
                                              environment: injectedCommit ?? .live) { undo in
            switch write {
            case .checked(let checked):
                return HabitCheckIn.setChecked(checked, on: date, of: habit, in: context, confirmed: confirmed, undo: undo)
            case .value(let value):
                return HabitCheckIn.setValue(value, on: date, of: habit, in: context, confirmed: confirmed, undo: undo)
            case .note(let text):
                return HabitCheckIn.setNote(text, on: date, of: habit, in: context, confirmed: confirmed, undo: undo)
            }
        }
        switch outcome {
        case .committed(let written):
            guard written.isCheckIn else {
                justCompleted = false
                return
            }
            if written.isCompleted { celebrate() }
            #if os(iOS)
            // A yes/no check-in, or any unit added — as before 1.4.1.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            // N3: a check-in that completes a 7-day streak or meets a week may ask for a rating
            // (`ReviewPromptRule`); the commit has bumped the cache, so this read is fresh.
            if let reviewPromptHook, let before {
                reviewPromptHook.afterCheckIn(ReviewPromptRule.CheckIn(
                    habit: habit, day: date, before: before, after: stats, written: written))
            }
        case .needsConfirmation(let about):
            confirming = PendingConfirmation(write: write, about: about)
        case .saveFailed:
            justCompleted = false
        case .noChange:
            break
        }
    }

    private func celebrate() {
        justCompleted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.2)) { justCompleted = false }
        }
    }

    /// The note editor opens on the note of the day's kept record — the one a write edits
    /// (`HabitCheckIn.liveRecords(of:on:)`, `Habit.record(on:)`).
    private func beginNote() {
        noteText = habit.record(on: date)?.note ?? ""
        showingNote = true
    }

    /// The row's state as the user saw it, flipped: a check the widget already took back is not
    /// deleted again, and one checked elsewhere is not un-checked by a stale row
    /// (`setChecked` re-reads the store and writes only what differs).
    private func toggleCompletion() {
        perform(.checked(!isCompleted))
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

    /// The value the row shows, plus one — set, not added: the user asked for what they saw + 1.
    private func incrementCount() {
        perform(.value(habit.loggedValue(on: date) + 1))
    }

    /// At 1 this deletes the day (and asks first when it carries a note, D7).
    private func decrementCount() {
        let shown = habit.loggedValue(on: date)
        guard shown > 0 else { return }
        perform(.value(max(0, shown - 1)))
    }

    private func resetCount() {
        perform(.value(0))
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
