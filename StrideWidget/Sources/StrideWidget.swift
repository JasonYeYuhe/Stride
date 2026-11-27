import WidgetKit
import SwiftUI
import SwiftData
import AppIntents
import UserNotifications
import os.log

// MARK: - Timeline Entry

/// A row is the plan's plain value (Shared/WidgetTimelinePlan.swift), so what the tests pin is
/// exactly what the views draw.
typealias HabitSnapshot = WidgetTimelinePlan.Row

extension WidgetTimelinePlan.Row {
    var color: Color {
        Color(hex: colorHex) ?? .green
    }
}

struct HabitEntry: TimelineEntry {
    let date: Date
    /// The habit-day the rows describe (the plan's `Entry.dayKey`): the midnight entry's is
    /// tomorrow's. A noted row's History link opens on it.
    let dayKey: Date
    let habits: [HabitSnapshot]
    /// The store is not the widget's to open yet: the app has not opened it at this schema
    /// (`StoreSchemaGate` — a fresh install, or an upgrade whose migration only the app may run;
    /// upgrade race, E2E U123), or the open failed. Drawn as one calm line, never as "No habits
    /// yet", which would say the user's habits are gone.
    var isWaitingForApp = false

    /// The entry's day by `DailyProgress` (RELEASE-1.5.0.md D1, D2, Gemini A7): the same rule as
    /// Today's card, the badge and the Dock, for this entry's own day-key. Every count, ring and
    /// VoiceOver label below reads it, never the rows directly: until 1.5.0 a rest day and a met
    /// times-per-week week counted as remaining, and a count habit with a target of 0 drew full.
    var day: DailyProgress { DailyProgress(states: habits.map(\.dayState)) }

    /// Habits done on the entry's day.
    var completedCount: Int { day.done }
    /// Habits due on the entry's day: rest days, met weeks and habits not started are not counted.
    var totalCount: Int { day.due }

    /// done ÷ due, 0 when nothing is due (an empty ring, never a full one).
    var progress: Double { day.fraction }

    /// Habits are listed and none is due on the entry's day: every view reads "Rest day", never
    /// "0 of 0".
    var isRestDay: Bool { !isWaitingForApp && !habits.isEmpty && day.isRestDay }

    init(date: Date, dayKey: Date? = nil, habits: [HabitSnapshot], isWaitingForApp: Bool = false) {
        self.date = date
        self.dayKey = dayKey ?? WidgetTimelinePlan.dayKey(of: date, in: .current)
        self.habits = habits
        self.isWaitingForApp = isWaitingForApp
    }

    init(_ planned: WidgetTimelinePlan.Entry) {
        self.init(date: planned.date, dayKey: planned.dayKey, habits: planned.rows)
    }

    /// The one line under the ring: small and large widgets. Each phrase is its own key.
    var statusText: LocalizedStringKey {
        if isWaitingForApp { return "Open Stride to see your habits" }
        if habits.isEmpty { return "No habits yet" }
        if isRestDay { return "Rest day" }
        if day.isPerfect { return "All done! 🎉" }
        return "\(totalCount - completedCount) remaining"
    }

    /// Also what the widget gallery shows (`getSnapshot` in preview), so it holds a full large
    /// widget's worth of rows. Names are the template names, which every catalog translates — a
    /// Japanese gallery used to preview "Exercise / Read / Meditate" in English.
    static var placeholder: HabitEntry {
        func row(_ id: String, _ name: String.LocalizationValue, _ emoji: String, _ colorHex: String,
                 done: Bool, streak: Int, count: Bool = false, progress: Double? = nil) -> HabitSnapshot {
            HabitSnapshot(habitId: id, name: String(localized: name), emoji: emoji, colorHex: colorHex,
                          isCount: count, isCompleted: done, progress: progress ?? (done ? 1 : 0),
                          streak: streak, streakInWeeks: false)
        }
        return HabitEntry(date: .now, habits: [
            row("1", "Drink Water", "\u{1F4A7}", "#5AC8FA", done: false, streak: 4, count: true, progress: 0.75),
            row("2", "Meditate", "\u{1F9D8}", "#AF52DE", done: true, streak: 12),
            row("3", "Exercise", "\u{1F3CB}\u{FE0F}", "#FF9500", done: true, streak: 5),
            row("4", "Read 30min", "\u{1F4DA}", "#007AFF", done: false, streak: 3),
            row("5", "Take Vitamins", "\u{1F48A}", "#FF3B30", done: true, streak: 21),
            row("6", "Stretch", "\u{1F938}", "#FF2D55", done: false, streak: 0),
            row("7", "Write Journal", "\u{270D}\u{FE0F}", "#FFCC00", done: true, streak: 8),
            row("8", "Walk 10k Steps", "\u{1F6B6}", "#34C759", done: false, streak: 2),
        ])
    }

    static var empty: HabitEntry {
        HabitEntry(date: .now, habits: [])
    }

    static var waitingForApp: HabitEntry {
        HabitEntry(date: .now, habits: [], isWaitingForApp: true)
    }

    /// The VoiceOver summary of a ring or an accessory with nothing due to count: no rows yet, or
    /// a rest day.
    var emptySummary: LocalizedStringKey {
        if isWaitingForApp { return "Open Stride to see your habits" }
        if habits.isEmpty { return "No habits yet" }
        return "Rest day"
    }
}

// MARK: - Widget Toggle Intent

struct ToggleHabitIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Habit"
    static var description: IntentDescription = "Toggle a habit's completion for today."

    @Parameter(title: "Habit ID")
    var habitId: String

    init() {}

    init(habitId: String) {
        self.habitId = habitId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Runs in the widget extension, so it never opens a store the app has not opened at this
        // schema (upgrade race, E2E U123): a row left over from before an upgrade writes nothing
        // until the app has migrated the store; the reload draws the waiting line instead.
        guard let container = SharedModelContainer.openForExtension() else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Habit>(
            predicate: #Predicate<Habit> { !$0.isArchived }
        )
        let habits = try context.fetch(descriptor)
        guard let habit = habits.first(where: { $0.id.uuidString == habitId }) else {
            return .result()
        }

        // Was a yes/no toggle for every habit: on a count habit it DELETED the day's partial
        // progress (6 of 8 glasses draws as an empty circle, so the tap was invited) and queued a
        // tombstone that deleted it on every other device. HabitCheckIn branches on the kind.
        let result = HabitCheckIn.tap(habit, on: Date(), in: context)
        guard result.needsConfirmation == nil else {
            // A checked, noted yes/no day: the widget cannot ask "Remove the check-in and its
            // note?", so it deletes nothing (RELEASE-1.4.1.md D7). Such a row is drawn as a link to
            // History (`HabitRowView`), so this is a timeline drawn before the note arrived — by
            // sync, or from the app. The reload draws the row checked again, and as that link.
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }

        // Persist first; only record the deletion tombstones for sync once the
        // save actually succeeded, so a failed save can't emit a tombstone for
        // a record that still exists. Every live record of the day goes on an
        // un-check — two devices' duplicates too — so there can be more than one.
        try context.save()
        for deletedID in result.deletedRecordIDs {
            SyncDeletionQueue.live.trackSharedEntry(deletedID)
        }
        WidgetCenter.shared.reloadAllTimelines()
        // The reminders follow the day (RELEASE-1.5.0.md D4, D5): quiet once done, back on an
        // un-check, the evening on a perfect day. After the save, so a lost write here only leaves
        // the requests as they were — the store is right, and the app's next plan repairs them.
        await WidgetReminderWrite.afterTap(of: habit, becameDone: result.isCompleted, habits: habits, in: context)
        return .result()
    }
}

// MARK: - Reminders after a widget check-in (1.5.0)

/// The widget's half of "quiet when done" (RELEASE-1.5.0.md D4, D5; Gemini A6). A check-in from
/// the widget runs in this process, where the app's save observer never hears it, so the reminder
/// it makes quiet would still fire tonight. The spike (D3) showed the extension reads and writes
/// the app's pending requests.
///
/// - **The same full plan as the app** (`ReminderPlan.plan` over every reminder-on habit and the
///   Daily Reminder, with each habit's quiet days and today's perfect day), so a tap that makes or
///   breaks a perfect day moves the evening's overlay too, and an un-check brings the bare request
///   back. Only the habits (and the evening) whose pending ids or triggers differ are replaced.
/// - **It never builds notification text.** Each replaced habit's requests copy the content of
///   any of its pending reminder requests (bare, `.<w>` or `.n<w>`; never the snooze) with
///   `userInfo["day"]` removed; the evening's copy any pending `stride.daily.evening*`. So this
///   process never needs the app's language or its message list. A habit (or the evening) with
///   nothing pending to copy from is left alone: the app's next plan rebuilds it. That only
///   over-fires or waits, never deletes.
/// - **When the habit becomes done**, its snooze is cancelled and its delivered banners are
///   withdrawn, as `CheckInEffects.afterCheckIn` does in the app.
/// - **Read back** before `perform` returns: each add is awaited, then the pending list is read
///   again, so the writes have reached the system before the extension can be suspended (D3).
@MainActor
enum WidgetReminderWrite {
    private static let logger = Logger(subsystem: "yyh.stride.habittracker.widget", category: "Notifications")

    static func afterTap(of tapped: Habit, becameDone: Bool, habits: [Habit], in context: ModelContext) async {
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let today = ReminderPlan.Today(now: Date(), calendar: calendar)
        // The app's order (`NotificationService.makePlan`), so a tie in the budget's overlay order
        // resolves the same way in both processes.
        let ordered = habits.filter { !$0.isArchived }
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        let live = HabitStats.liveRecordIDs(of: ordered, in: context)
        var stats: [UUID: HabitStats] = [:]
        for habit in ordered {
            stats[habit.id] = HabitStats(habit: habit, liveRecordIDs: live, calendar: calendar, today: today.dayKey)
        }
        let settings = ordered.compactMap { habit in
            stats[habit.id].flatMap { ReminderPlan.settings(for: habit, stats: $0, today: today.dayKey) }
        }
        let progress = DailyProgress(of: ordered.compactMap { stats[$0.id] }, on: today.dayKey)
        let plan = ReminderPlan.plan(settings, evening: .storedInAppGroup(isPerfectToday: progress.isPerfect),
                                     today: today)

        if becameDone {
            center.removePendingNotificationRequests(withIdentifiers: [ReminderPlan.snoozeIdentifier(for: tapped.id)])
            center.removeDeliveredNotifications(withIdentifiers: ReminderPlan.allIdentifiers(for: tapped.id))
        }

        let pending = await center.pendingNotificationRequests()
        let byID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var writes: [(identifiers: [String], requests: [UNNotificationRequest])] = []
        for habit in settings {
            let ids = ReminderPlan.reminderIdentifiers(for: habit.habitID)
            if let requests = replacement(of: ids, with: plan.requests(for: habit.habitID), pending: byID) {
                writes.append((ids, requests))
            }
        }
        if !plan.evening.isEmpty,
           let requests = replacement(of: ReminderPlan.allEveningIdentifiers, with: plan.evening, pending: byID) {
            writes.append((ReminderPlan.allEveningIdentifiers, requests))
        }
        guard !writes.isEmpty else { return }

        var added: [String] = []
        for write in writes {
            center.removePendingNotificationRequests(withIdentifiers: write.identifiers)
            for request in write.requests {
                do {
                    try await center.add(request)
                    added.append(request.identifier)
                } catch {
                    logger.error("widget reminder write: the center refused a request")
                }
            }
        }
        // The read-back (D3): the writes are in the system's store before the extension returns.
        let after = Set(await center.pendingNotificationRequests().map(\.identifier))
        let missing = added.filter { !after.contains($0) }.count
        // Counts only, no habit ids in a production log line (D4).
        logger.notice("widget reminder write: \(writes.count, privacy: .public) replaced, \(missing, privacy: .public) missing on read-back")
    }

    /// The requests that replace one group (a habit's reminder ids, or the evening's), or nil to
    /// leave it: nothing pending to copy the content from, or the pending ids and triggers are
    /// already the plan's.
    private static func replacement(of identifiers: [String], with planned: [ReminderPlan.Request],
                                    pending: [String: UNNotificationRequest]) -> [UNNotificationRequest]? {
        let current = identifiers.compactMap { pending[$0] }
        guard let template = current.first else { return nil }
        let pendingShape = Set(current.map { request in
            Shape(identifier: request.identifier,
                  fire: (request.trigger as? UNCalendarNotificationTrigger)
                    .map { ReminderPlan.Fire($0.dateComponents, repeats: $0.repeats) })
        })
        let plannedShape = Set(planned.map { Shape(identifier: $0.identifier, fire: $0.fire) })
        guard pendingShape != plannedShape else { return nil }
        guard let content = template.content.mutableCopy() as? UNMutableNotificationContent else { return nil }
        // A snooze's day must never ride along: a copied day would make a later Mark Done credit
        // that day. (The snooze is never a template; this holds whatever the template.)
        content.userInfo.removeValue(forKey: NotificationRouter.UserInfoKey.day)
        return planned.map { request in
            UNNotificationRequest(identifier: request.identifier, content: content,
                                  trigger: UNCalendarNotificationTrigger(dateMatching: request.dateComponents,
                                                                         repeats: request.repeats))
        }
    }

    private struct Shape: Hashable {
        let identifier: String
        let fire: ReminderPlan.Fire?
    }
}

// MARK: - Timeline Provider

struct HabitTimelineProvider: TimelineProvider {
    /// How soon to try again when the store could not be read. Before 1.3.0 a failed fetch drew
    /// "No habits yet" with the same `.after(tomorrow)` policy as a good one, so one bad read
    /// blanked the widget until the next day.
    private static let retryAfterFailure: TimeInterval = 15 * 60

    /// How soon to look again while the store is not the widget's to open. Only the fallback: the
    /// app reloads every timeline as soon as it has opened the store and written the marker.
    private static let retryWhileWaiting: TimeInterval = 15 * 60

    private enum Read {
        case plan(WidgetTimelinePlan)
        case waitingForApp
        case failed
    }

    func placeholder(in context: Context) -> HabitEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (HabitEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        switch read(now: .now) {
        case .plan(let plan): completion(plan.entries.first.map(HabitEntry.init) ?? .empty)
        case .waitingForApp: completion(.waitingForApp)
        case .failed: completion(.empty)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HabitEntry>) -> Void) {
        let now = Date()
        switch read(now: now) {
        case .plan(let plan):
            // [now, next local midnight]: the flip to a new day is already in the timeline, so it
            // no longer waits on WidgetKit granting a reload. See WidgetTimelinePlan.
            completion(Timeline(entries: plan.entries.map(HabitEntry.init), policy: .after(plan.refreshAfter)))
        case .waitingForApp:
            completion(Timeline(entries: [.waitingForApp], policy: .after(now.addingTimeInterval(Self.retryWhileWaiting))))
        case .failed:
            completion(Timeline(entries: [.empty], policy: .after(now.addingTimeInterval(Self.retryAfterFailure))))
        }
    }

    /// The device's calendar, as `ToggleHabitIntent` uses when it writes (`HabitCheckIn` keys
    /// the day with `Calendar.current`): the widget must roll over at the same midnight the
    /// check-ins do. It deliberately ignores the in-app language picker, like the rest of the
    /// widget.
    private func read(now: Date) -> Read {
        // Opened only once the app has opened the store at this schema (upgrade race, E2E U123).
        guard let container = SharedModelContainer.openForExtension() else { return .waitingForApp }
        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<Habit>(
                predicate: #Predicate<Habit> { !$0.isArchived },
                sortBy: [SortDescriptor(\Habit.sortOrder)]
            )
            let habits = try context.fetch(descriptor)
            return .plan(WidgetTimelinePlan(now: now, calendar: .current,
                                            rows: WidgetTimelinePlan.rowInputs(for: habits, in: context, now: now, calendar: .current)))
        } catch {
            return .failed
        }
    }
}

// MARK: - Widget Views

/// Small widget: Progress ring + count (tap opens app)
struct SmallWidgetView: View {
    let entry: HabitEntry

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: entry.progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // "0 of 0" would read as a count while nothing has been read, or on a rest day
                // (the status line says "Rest day").
                if !entry.isWaitingForApp && entry.totalCount > 0 {
                    VStack(spacing: 0) {
                        Text("\(entry.completedCount)")
                            .font(.title.bold())
                            .foregroundStyle(.primary)
                        Text("of \(entry.totalCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 70, height: 70)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.completedCount) of \(entry.totalCount) habits completed")
            // "0 of 0 habits completed" is nonsense; the status line below already says it ("No
            // habits yet", "Rest day").
            .accessibilityHidden(entry.totalCount == 0)

            Text(entry.statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                // The waiting line is longer than any count; one line truncated it mid-word.
                .lineLimit(entry.isWaitingForApp ? 2 : 1)
                .multilineTextAlignment(.center)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Medium widget: Progress + interactive habit list
struct MediumWidgetView: View {
    let entry: HabitEntry

    var body: some View {
        HStack(spacing: 12) {
            // Left: Progress ring
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.2), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: entry.progress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    // No percent of nothing due: the ring stays empty on a rest day.
                    if entry.totalCount > 0 {
                        Text("\(Int(entry.progress * 100))%")
                            .font(.callout.bold())
                    }
                }
                .frame(width: 56, height: 56)

                Text(entry.isRestDay ? "Rest day" : "Today")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 72)
            .accessibilityElement(children: .ignore)
            // Each whole phrase is its own key: a ternary inside the interpolation would
            // collapse to a plain %@ argument and never be translated.
            .accessibilityLabel(entry.totalCount == 0 ? entry.emptySummary : "\(entry.completedCount) of \(entry.totalCount) habits completed, \(Int(entry.progress * 100)) percent")

            // Right: Interactive habit list
            VStack(alignment: .leading, spacing: 4) {
                let displayHabits = Array(entry.habits.prefix(4))

                ForEach(displayHabits) { habit in
                    HabitRowView(habit: habit, dayKey: entry.dayKey, font: .caption)
                }

                if entry.habits.count > 4 {
                    Text("+\(entry.habits.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(entry.habits.count - 4) more habits")
                }

                if entry.isWaitingForApp {
                    Text("Open Stride to see your habits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if entry.habits.isEmpty {
                    Text("Tap to add habits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Large widget (and Extra Large on iPad, as two columns): the Today list, with streaks.
///
/// Eight rows at the default text size. The widget's height is fixed and its text still
/// follows Dynamic Type, so at larger sizes it lists fewer rather than clipping the bottom
/// rows — and with them the "+N more" that says they exist. The budgets were measured by
/// rendering this view at the smallest iOS 17 large widget (iPhone SE, 321 × 324 pt, 16 pt
/// margins): eight lines leave ~60 pt spare at the default size, seven fit at xxxLarge, five
/// at accessibility1.
struct LargeWidgetView: View {
    let entry: HabitEntry
    var columns: Int = 1

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isHuge: Bool { dynamicTypeSize >= .accessibility3 }

    private var rowsPerColumn: Int {
        if dynamicTypeSize >= .accessibility3 { return 3 }
        if dynamicTypeSize >= .accessibility1 { return 5 }
        if dynamicTypeSize >= .xxLarge { return 7 }
        return 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if entry.habits.isEmpty {
                Spacer(minLength: 0)
                Text(entry.isWaitingForApp ? "Open Stride to see your habits" : "Tap to add habits")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                list
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: entry.progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                // A formatted percent, not a "\(n)%" key: no catalog has one, and the
                // formatter puts the sign where each language wants it.
                // Past accessibility3 it truncated to "5…"; the ring alone still says it.
                if !isHuge && entry.totalCount > 0 {
                    Text(entry.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.bold())
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text("Today")
                    .font(.headline)
                // While waiting the body says it; twice would be noise.
                if !entry.isWaitingForApp {
                    Text(entry.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // The day the rows describe. The midnight entry shows tomorrow's date, which is
            // also the one visible proof on a device that the rollover happened. Dropped at
            // accessibility sizes, where it truncated to "Sun, Sep…" and squeezed the status.
            if !dynamicTypeSize.isAccessibilitySize {
                Text(entry.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.totalCount == 0 ? entry.emptySummary : "\(entry.completedCount) of \(entry.totalCount) habits completed, \(Int(entry.progress * 100)) percent")
    }

    private var list: some View {
        let capacity = rowsPerColumn * columns
        let layout = WidgetTimelinePlan.visibleRows(total: entry.habits.count, capacity: capacity)
        let shown = Array(entry.habits.prefix(layout.shown))

        // Column-major, so both columns read in the app's sort order, top to bottom.
        return HStack(alignment: .top, spacing: 16) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(shown.dropFirst(column * rowsPerColumn).prefix(rowsPerColumn)) { habit in
                        // At the largest sizes the badge squeezed the name to one letter.
                        HabitRowView(habit: habit, dayKey: entry.dayKey, font: .subheadline, showsStreak: !isHuge)
                    }
                    if column == columns - 1, layout.more > 0 {
                        Text("+\(layout.more) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(layout.more) more habits")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Habit rows (medium and large)

/// One tappable habit row.
///
/// A yes/no habit is a `Toggle(isOn:intent:)`: the system flips it the moment it is tapped and
/// runs the intent behind it, where a `Button` drew the old state until the timeline reloaded.
/// A count habit stays a `Button` — its tap adds one unit (`HabitCheckIn.tap`), which is not an
/// on/off switch, and drawing it as one would promise that a second tap clears the day. That
/// promise is the bug 1.2.3 fixed: the widget's tap used to delete a count habit's whole day.
///
/// A checked yes/no row whose day has a note is neither (RELEASE-1.4.1.md D7): un-checking it
/// would delete the note, and the extension cannot ask "Remove the check-in and its note?". It is
/// a `Link` that opens the app on that habit's History for the row's day (`HistoryLink`), where
/// the un-check asks. Drawn exactly like the checked toggle, so nothing moves.
struct HabitRowView: View {
    let habit: HabitSnapshot
    /// The day the row describes: its entry's (`HabitEntry.dayKey`).
    let dayKey: Date
    var font: Font = .caption
    var showsStreak = false

    var body: some View {
        if let history = HistoryLink.url(for: habit, dayKey: dayKey) {
            Link(destination: history) {
                HabitRowLabel(habit: habit, isOn: true, font: font, showsStreak: showsStreak)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(habit.name), completed")
            .accessibilityValue(streakPhrase)
            .accessibilityHint("Opens History")
        } else if habit.isCount {
            Button(intent: ToggleHabitIntent(habitId: habit.habitId)) {
                HabitRowLabel(habit: habit, isOn: habit.isCompleted, font: font, showsStreak: showsStreak)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(habit.isCompleted ? "\(habit.name), completed" : "\(habit.name), not completed")
            .accessibilityValue(countValue)
            .accessibilityHint("Double tap to add one")
        } else {
            Toggle(isOn: habit.isCompleted, intent: ToggleHabitIntent(habitId: habit.habitId)) {
                Text(verbatim: habit.name)
            }
            .toggleStyle(HabitRowToggleStyle(habit: habit, font: font, showsStreak: showsStreak, streakPhrase: streakPhrase))
        }
    }

    /// A count habit part-way to its goal draws a partial ring around the check mark
    /// (`HabitCheckMark`), but VoiceOver only said "not completed" — 6 of 8 glasses sounded the
    /// same as none. The rate is system-formatted ("75%"), so it needs no catalog key and follows
    /// the system language like the rest of the widget. The row holds no logged/target numbers
    /// (`WidgetTimelinePlan.Row` keeps only the fraction), so the percentage is what can be said.
    private var countValue: Text {
        guard !habit.isCompleted, habit.progress > 0 else { return streakPhrase }
        // Rounded down: 999 of 1000 must not be read out as "100%, not completed".
        let percent = Text(habit.progress, format: .percent.precision(.fractionLength(0)).rounded(rule: .down))
        guard showsStreak, habit.streak > 0 else { return percent }
        return percent + Text(verbatim: ", ") + streakPhrase
    }

    /// Spoken only where the streak is drawn. Whole-phrase keys per unit (RELEASE-1.2.3.md:
    /// an interpolated unit reached every language in English).
    private var streakPhrase: Text {
        guard showsStreak, habit.streak > 0 else { return Text(verbatim: "") }
        return habit.streakInWeeks ? Text("\(habit.streak) week streak") : Text("\(habit.streak) day streak")
    }
}

/// Draws a yes/no row from the toggle's own state, so the optimistic flip shows at once.
struct HabitRowToggleStyle: ToggleStyle {
    let habit: HabitSnapshot
    let font: Font
    let showsStreak: Bool
    let streakPhrase: Text

    func makeBody(configuration: Configuration) -> some View {
        HabitRowLabel(habit: habit, isOn: configuration.isOn, font: font, showsStreak: showsStreak)
            .accessibilityElement(children: .ignore)
            // The completion state lives only in the icon's shape and colour, so without this
            // VoiceOver never says whether the habit is already done.
            .accessibilityLabel(configuration.isOn ? "\(habit.name), completed" : "\(habit.name), not completed")
            .accessibilityValue(streakPhrase)
            .accessibilityHint("Double tap to toggle completion")
    }
}

struct HabitRowLabel: View {
    let habit: HabitSnapshot
    let isOn: Bool
    let font: Font
    let showsStreak: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(habit.emoji)
                .font(font)

            Text(habit.name)
                .font(font.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            if showsStreak, habit.streak > 0 {
                // "12d" / "12w", as the app's rows draw it; the spoken form is the row's value.
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                    Text(habit.streakInWeeks ? "\(habit.streak)w" : "\(habit.streak)d")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            }

            HabitCheckMark(habit: habit, isOn: isOn)
                .font(font)
                // Dims while the intent runs and the timeline reloads, so a state the system
                // has not confirmed yet does not read as final.
                .invalidatableContent()
        }
        // The whole row is the tap target, not just its glyphs: a plain-style label is hit-tested
        // on what it draws, so the gap before the check mark used to do nothing.
        .contentShape(Rectangle())
    }
}

struct HabitCheckMark: View {
    let habit: HabitSnapshot
    let isOn: Bool

    var body: some View {
        if isOn {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(habit.color)
        } else if habit.isCount, habit.progress > 0 {
            // Part-way through a count goal. This drew as the same empty circle as "nothing
            // logged", which is what made 6 of 8 glasses look like an invitation to tap.
            Image(systemName: "circle")
                .hidden()
                .overlay {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: habit.progress)
                            .stroke(habit.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(1.5)
                }
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.gray.opacity(0.4))
        }
    }
}

/// Lock screen circular widget
struct LockScreenCircularView: View {
    let entry: HabitEntry

    var body: some View {
        Gauge(value: entry.progress) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            if entry.isRestDay {
                // Nothing due: no count to show. The label says "Rest day".
                Image(systemName: "moon.zzz.fill")
            } else {
                Text("\(entry.completedCount)")
                    .font(.system(.body, design: .rounded).bold())
            }
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel(entry.totalCount == 0 ? entry.emptySummary : "\(entry.completedCount) of \(entry.totalCount) habits completed")
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Lock screen inline widget
struct LockScreenInlineView: View {
    let entry: HabitEntry

    var body: some View {
        if entry.isWaitingForApp {
            Text("Open Stride to see your habits")
        } else if entry.habits.isEmpty {
            Text("Stride: No habits yet")
        } else if entry.isRestDay {
            Text("Rest day")
        } else if entry.day.isPerfect {
            // Spoken form only: the leading emoji reads as its symbol name and "2/3" as
            // "2 slash 3", both noise on an accessory whose whole point is one short phrase.
            Text("🔥 All \(entry.totalCount) habits done!")
                .accessibilityLabel("\(entry.completedCount) of \(entry.totalCount) habits completed")
        } else {
            Text("🏃 \(entry.completedCount)/\(entry.totalCount) habits done")
                .accessibilityLabel("\(entry.completedCount) of \(entry.totalCount) habits completed")
        }
    }
}

/// Lock screen rectangular widget
struct LockScreenRectangularView: View {
    let entry: HabitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Stride")
                    .font(.caption.bold())
                Spacer()
                if entry.isRestDay {
                    Text("Rest day")
                        .font(.caption.bold())
                } else if !entry.isWaitingForApp && entry.totalCount > 0 {
                    Text("\(entry.completedCount)/\(entry.totalCount)")
                        .font(.caption.bold())
                }
            }

            if entry.isWaitingForApp {
                Text("Open Stride to see your habits")
                    .font(.caption2)
                    .lineLimit(2)
            }

            let displayHabits = Array(entry.habits.prefix(3))
            ForEach(displayHabits) { habit in
                HStack(spacing: 4) {
                    Text(habit.emoji)
                        .font(.caption2)
                    Text(habit.name)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: habit.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(habit.isCompleted ? .primary : .secondary)
                }
            }
        }
        // Nothing here is interactive, so one summary beats swiping through eight fragments
        // ("Stride", "2 slash 3", then every emoji and name as its own stop).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.totalCount == 0 ? entry.emptySummary : "\(entry.completedCount) of \(entry.totalCount) habits completed")
        // .ignore would otherwise drop the habits this accessory lists.
        .accessibilityValue(Text(verbatim: entry.habits.prefix(3).map(\.name).joined(separator: ", ")))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct StrideWidget: Widget {
    let kind = "StrideWidget"

    // No container here. `init()` opened the store the moment chronod launched the extension —
    // on the first launch after an upgrade, the same moment the app opened it, and both migrated
    // it (upgrade race, E2E U123). The provider opens it per reload, through the schema gate.

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: HabitTimelineProvider()
        ) { entry in
            StrideWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Stride Habits")
        .description("Track your daily habit progress at a glance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            // Offered only on iPad; iPhone ignores it. macOS desktop widgets are not built
            // (this extension is iOS-only; Sonoma's desktop rendering is its own work).
            .systemExtraLarge,
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular,
        ])
    }
}

struct StrideWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: HabitEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        case .systemExtraLarge:
            LargeWidgetView(entry: entry, columns: 2)
        case .accessoryCircular:
            LockScreenCircularView(entry: entry)
        case .accessoryInline:
            LockScreenInlineView(entry: entry)
        case .accessoryRectangular:
            LockScreenRectangularView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Bundle

@main
struct StrideWidgetBundle: WidgetBundle {
    var body: some Widget {
        StrideWidget()
    }
}
