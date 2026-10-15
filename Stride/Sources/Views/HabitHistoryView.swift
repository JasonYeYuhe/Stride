import SwiftUI
import SwiftData

/// A habit's History: a month grid and the selected day's editor (RELEASE-1.4.1.md D6, with D7's
/// notes and D8's backdating window).
///
/// **Where it comes from.** The shell presents it for `ShellRequest.history(habitID:day:)`
/// (ContentView), from the detail card's "Edit history" button, a heatmap cell, the grid's
/// VoiceOver action (W3) and a checked, noted widget row (D7, W2's route). A shell sheet: it
/// survives a size-class crossing and never pushes into the shared stack. There is no nested
/// sheet and no separate day sheet; on the Mac the menu commands beep under it, as under any
/// sheet (`MenuCommandPress`).
///
/// **What it holds.** The habit's id, the selected day (a day number, `HabitStats`' whole days),
/// the month shown and the note draft — never the Habit or a record. Every write re-resolves the
/// habit by id (`resolve`) and goes through one of HabitCheckIn's D4 setters inside
/// `HabitEntryCommit.commit`, which re-reads the day from the store; the sheet dismisses when the
/// habit is gone, at a write or as soon as a save or the query says so. A check and a value are
/// written alone: the note is written only when the user changed it (`NoteDraft.isDirty`), so a
/// note another device sent while the editor is open is never written back over (Data safety 1).
///
/// **What it shows** is read from `StatsCache` — the store's live records, so a check-in the
/// widget took back shows as gone here — except the selected day's note text, which is read from
/// the store when the day is picked and after every save (`storedDay`).
///
/// **Days** run from `HabitStats.startDay` (min(creation day, earliest live record)) − 365 d up
/// to today, never before 2025-01-01 (`window`, X2) and never a future day (D8). `createdAt` is
/// never written. Notes go only on days with a record (D7): a yes/no day once it is checked, a
/// count day once it holds a value. The 500-
/// character cap applies to new input only (`acceptsNoteDraft`): an existing longer note is shown
/// and kept whole, and a value edit never touches it.
///
/// **A changed note is never dropped without the user's word** while the sheet is up (W4 review,
/// "W4-HIST-1", "W4-HIST-2"). Done, another day, the toggle and the stepper each write the draft
/// first; a draft that cannot be written as it is — over the cap, or one whose day holds a
/// second, different note the user declines to combine — stops them with a question that offers
/// "Discard Changes", which puts the stored note back and then does what was asked. A swipe is
/// refused for a changed draft (`interactiveDismissDisabled`), so only a close the app makes on its
/// own (the habit deleted, another request) drops one.
struct HabitHistoryView: View {
    /// The cap on a new note's length (D6). An existing longer note is never truncated.
    static let noteCharacterLimit = 500
    /// How far before the habit's start History reaches (D8).
    static let backdatingDays = 365

    /// The habit, by id: it is re-resolved at every write (D6), never held as a model object.
    let habitID: UUID
    /// The day the sheet opened on: a LOCAL instant (Today's date, a heatmap cell's local
    /// midnight, a widget link's noon), never a day-key — keyed with
    /// `HabitCalendar.dayKey(forInstant:)`.
    let day: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// nil: the app's own commit (`HabitEntryCommit.Environment.live`); the hosted tests inject one.
    @Environment(\.habitEntryCommit) private var injectedCommit
    /// At accessibility sizes the month title and the Amount label take their own lines
    /// ("W4-AX-1"), as Today's rows and the progress card do.
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The habit, re-fetched by the query whenever the store changes: empty once it is gone.
    @Query private var matches: [Habit]

    /// The day the editor edits, as a day number (`HabitStats.dayNumber`).
    @State private var selectedDay: Int
    /// Noon of the first day of the month the grid shows, in `Calendar.current`.
    @State private var displayedMonth: Date
    /// The editor's note, only in view state (2026-10-15).
    @State private var draft = NoteDraft()
    /// A write waiting for the user's go (D7), committed again unchanged on confirmation.
    @State private var confirming: PendingWrite?
    /// A changed note over the cap that stood in front of what the user asked for: never written,
    /// and dropped only by "Discard Changes".
    @State private var overCap: OverCapDraft?
    @FocusState private var noteFocused: Bool
    private var cache = StatsCache.shared

    init(habitID: UUID, day: Date) {
        self.habitID = habitID
        self.day = day
        let calendar = Calendar.current
        let opened = Self.dayNumber(ofInstant: day, in: calendar)
        _selectedDay = State(initialValue: opened)
        _displayedMonth = State(initialValue: Self.monthStart(containing: Self.noon(ofDay: opened, in: calendar),
                                                              in: calendar))
        let id = habitID
        _matches = Query(filter: #Predicate<Habit> { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            Group {
                // Resolved from the store on every render, not taken from `matches`: a habit
                // another context deleted is still in this context, and still in the query until
                // it refreshes, but its backing data is gone, and the first attribute read of it or
                // of its records traps (measured: "backing data could no longer be found"). One
                // small fetch by id.
                if !matches.isEmpty, let habit = Self.resolve(habitID, in: modelContext) {
                    content(habit)
                } else {
                    // Gone: the sheet is being dismissed (below).
                    Color.appBackground
                }
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
        }
        // A swipe would drop a changed note without a word. Done writes it, or asks when it
        // cannot be written as it is (`flushNote`), so both ways out keep the user's text.
        .interactiveDismissDisabled(draft.isDirty)
        .onChange(of: matches.isEmpty, initial: true) { _, gone in
            if gone { dismiss() }
        }
        // A save anywhere (another context, another process's merge, a sync) — the habit may be
        // gone, and an untouched note follows the store.
        .onChange(of: cache.generation) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { _ in
            refresh()
        }
        .onAppear { refresh() }
        // Leaving the field writes what can be written without a question, and keeps the rest:
        // a question comes only from something the user asked for (Done, a day, a write, Save),
        // never from a scroll — nor from the alert that took the focus, whose own follow-up it
        // would replace.
        .onChange(of: noteFocused) { _, focused in
            if !focused { flushNote(asking: false) }
        }
        // A close the app made on its own (the habit deleted, another shell request): nothing can
        // be asked any more, so a draft that needs a question, or is over the cap, is dropped.
        // The user's own ways out never get here with one: a swipe is refused and Done asks.
        .onDisappear { flushNote(asking: false) }
        .alert("Remove the check-in and its note?", isPresented: isConfirming(.removeNote), presenting: confirming) { pending in
            Button("Remove", role: .destructive) {
                if perform(pending.write, on: pending.day, confirmed: pending.about) { proceed(pending.then) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("This day has more than one note. Combine them into one?", isPresented: isConfirming(.combineNotes),
               presenting: confirming) { pending in
            Button("Combine") {
                if perform(pending.write, on: pending.day, confirmed: pending.about) { proceed(pending.then) }
            }
            // The draft's own question: without this way out, Cancel left a changed note that
            // Done, another day, the toggle and the stepper each asked about again, and that a
            // swipe could not drop ("W4-HIST-2"). Cancel still keeps it, to edit further.
            if pending.isNoteDraft {
                Button("Discard Changes", role: .destructive) { discardDraft(then: pending.then) }
            }
            Button("Cancel", role: .cancel) {}
        }
        // A changed note over the cap cannot be written, and is not dropped without asking
        // ("W4-HIST-1"): the cap line says why, and Cancel goes back to shorten it.
        .alert("Notes can be up to 500 characters.", isPresented: isOverCap, presenting: overCap) { pending in
            Button("Discard Changes", role: .destructive) { discardDraft(then: pending.then) }
            Button("Cancel", role: .cancel) {}
        }
        #if os(macOS)
        // A bare ScrollView has no ideal height, and a sheet sized to it would be a sliver.
        .frame(minWidth: 460, idealWidth: 520, minHeight: 620)
        #endif
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(_ habit: Habit) -> some View {
        let calendar = Calendar.current
        let now = Date()
        let stats = cache.stats(for: habit, today: now, calendar: calendar)
        let window = Self.window(startDay: stats.startDay, today: now, calendar: calendar)
        let selected = min(max(selectedDay, window.lowerBound), window.upperBound)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(habit, stats: stats)
                monthSection(habit, stats: stats, window: window, selected: selected, calendar: calendar)
                editor(habit, stats: stats, day: selected, calendar: calendar)
            }
            .padding()
            .frame(maxWidth: ShellLayout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.appBackground)
    }

    /// The habit and its check-in count: the days with a live record up to today. It used to be
    /// the detail card's "Total" tile (`records.count`, ghosts and same-day duplicates included),
    /// which became "Strength" (D10).
    private func header(_ habit: Habit, stats: HabitStats) -> some View {
        let count = stats.valuesByDay.count
        return HStack(spacing: 12) {
            Text(habit.emoji)
                .font(.largeTitle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name)
                    .font(.headline)
                Text("\(count) check-ins")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private enum GridCell: Hashable {
        case weekday(Int)
        case lead(Int)
        case day(Int)
    }

    private func monthSection(_ habit: Habit, stats: HabitStats, window: ClosedRange<Int>, selected: Int,
                              calendar: Calendar) -> some View {
        let earliest = Self.monthStart(containing: Self.noon(ofDay: window.lowerBound, in: calendar), in: calendar)
        let latest = Self.monthStart(containing: Self.noon(ofDay: window.upperBound, in: calendar), in: calendar)
        let month = min(max(displayedMonth, earliest), latest)
        let names = appCalendar
        let symbols = names.veryShortStandaloneWeekdaySymbols
        let cells: [GridCell] = (0..<7).map { GridCell.weekday((names.firstWeekday - 1 + $0) % 7) }
            + Self.monthCells(month, in: calendar).enumerated().map { index, day in
                day.map(GridCell.day) ?? .lead(index)
            }
        let title = Text(verbatim: month.formatted(.dateTime.month(.wide).year().locale(appLocale)))
            .font(.headline)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
        return VStack(spacing: 8) {
            if typeSize.isAccessibilitySize {
                // The title gets the row's whole width, the chevrons the line under it: between two
                // fixed 44 pt buttons "September 2026" had about 250 pt at AX5 and broke inside
                // "September", and Spanish's "septiembre de 2026" even on a Pro Max ("W4-AX-1").
                // Not capped: it is the page's context. Wrapped, it breaks between words.
                title.frame(maxWidth: .infinity)
                HStack {
                    monthButton(-1, from: month, disabled: month <= earliest, calendar: calendar)
                    Spacer()
                    monthButton(1, from: month, disabled: month >= latest, calendar: calendar)
                }
            } else {
                HStack {
                    monthButton(-1, from: month, disabled: month <= earliest, calendar: calendar)
                    Spacer()
                    title
                    Spacer()
                    monthButton(1, from: month, disabled: month >= latest, calendar: calendar)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(cells, id: \.self) { cell in
                    switch cell {
                    case .weekday(let index):
                        // Each day's own label names its weekday; the letters are for the eye.
                        Text(verbatim: symbols[index])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    case .lead:
                        Color.clear.frame(height: 44).accessibilityHidden(true)
                    case .day(let n):
                        dayCell(n, habit: habit, stats: stats, window: window, selected: selected, calendar: calendar)
                    }
                }
            }
            // Two-digit day numbers in seven columns: past here they would only shrink to fit.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }

    /// ‹ or ›: a 44 pt button that shows the month before (-1) or after (1).
    private func monthButton(_ delta: Int, from month: Date, disabled: Bool, calendar: Calendar) -> some View {
        Button {
            showMonth(delta, from: month, calendar: calendar)
        } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(delta < 0 ? "Previous Month" : "Next Month")
        .accessibilityIdentifier(delta < 0 ? "history.previousMonth" : "history.nextMonth")
    }

    /// One day: a 44 pt button, filled when the day is completed, a ring for a count day under its
    /// goal, a 4 pt dot for a note. One accessibility element with the date (its weekday
    /// included), the amount for a count habit (on a rest day too, after "rest day"), and the
    /// state as its value — the per-day equivalent of the heatmap's single element (D5).
    ///
    /// The circle is at most 36 pt and shrinks with its column ("W4-AX-2"): with a fixed 36 pt
    /// (42 with its ring) the cells overlapped below a 366 pt width — Display Zoom's 320 pt, a
    /// narrow iPad window — the selected ring drew over the next day and a tap near the edge
    /// picked the later one. At 320 pt the circle is about 29 pt and the ring fills its 35 pt
    /// column; from 375 pt up nothing changes.
    private func dayCell(_ n: Int, habit: Habit, stats: HabitStats, window: ClosedRange<Int>, selected: Int,
                         calendar: Calendar) -> some View {
        let key = HabitStats.key(ofDay: n)
        let noon = Self.noon(ofDay: n, in: calendar)
        let inWindow = window.contains(n)
        let completed = stats.isCompleted(on: key)
        let value = stats.loggedValue(on: key)
        let noted = stats.hasNote(on: key)
        let scheduled = stats.isScheduled(on: key)
        let isSelected = n == selected
        let digits = String(calendar.component(.day, from: noon))
        let numberStyle: Color = completed ? .white : (!inWindow ? Color.secondary.opacity(0.4) : (scheduled ? .primary : .secondary))
        return Button {
            select(n)
        } label: {
            ZStack {
                // Takes the square the cell is offered, so a day with no circle (the digits alone)
                // is as big as one with a circle, and its ring as round.
                Color.clear
                if completed {
                    Circle().fill(habit.color)
                } else if value > 0 {
                    Circle().stroke(habit.color.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: SafeNumber.unitInterval(stats.progress(on: key)))
                        .stroke(habit.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(verbatim: digits)
                    .font(.callout.weight(n == window.upperBound ? .bold : .regular))
                    .foregroundStyle(numberStyle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if noted {
                    Circle()
                        .fill(completed ? Color.white : habit.color)
                        .frame(width: 4, height: 4)
                        .offset(y: 12)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 36, maxHeight: 36)
            .padding(3)
            .overlay {
                if isSelected { Circle().stroke(Color.primary, lineWidth: 2) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!inWindow)
        .accessibilityLabel(Self.cellLabel(noon: noon, habit: habit, value: value, scheduled: scheduled))
        .accessibilityValue(Self.cellValue(completed: completed, noted: noted))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // For the sim kit (D14), which picks a day by its date: `history.day.yyyy-MM-dd`.
        .accessibilityIdentifier("history.day." + HistoryLink.dayString(of: key))
    }

    /// The date with its weekday, then "rest day" on a rest day; for a count habit then the amount
    /// of the goal, on a scheduled day always and on a rest day when it holds one — the ring the
    /// cell draws for it, spoken ("W4-AX-3": it said only "…, rest day", as Today's row never
    /// would). A yes/no rest day's check is its value, "Completed".
    static func cellLabel(noon: Date, habit: Habit, value: Double, scheduled: Bool) -> String {
        var dateLabel = noon.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(appLocale))
        if !scheduled { dateLabel = appLocalized("\(dateLabel), rest day") }
        guard habit.habitKind == .count, scheduled || value > 0 else { return dateLabel }
        let logged = SafeNumber.amount(value)
        let target = SafeNumber.amount(habit.targetValue)
        // The same "%@, %@ of %@" as a scheduled day's, its first argument already localized.
        return appLocalized("\(dateLabel), \(logged) of \(target)")
    }

    private static func cellValue(completed: Bool, noted: Bool) -> String {
        var parts: [String] = []
        if completed { parts.append(appLocalized("Completed")) }
        if noted { parts.append(appLocalized("Has a note")) }
        return parts.joined(separator: ", ")
    }

    /// The selected day: its date, a check toggle (yes/no) or a value stepper (count), and its note.
    private func editor(_ habit: Habit, stats: HabitStats, day n: Int, calendar: Calendar) -> some View {
        let key = HabitStats.key(ofDay: n)
        let noon = Self.noon(ofDay: n, in: calendar)
        let shown = stats.loggedValue(on: key)
        let checked = stats.isCompleted(on: key)
        // A record exists: any live one checks a yes/no day; a count day needs a value (no write
        // ever leaves a value-0 record, D7).
        let hasRecord = habit.habitKind == .binary ? checked : shown > 0
        return VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: noon.formatted(.dateTime.weekday(.wide).month(.wide).day().year().locale(appLocale)))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !stats.isScheduled(on: key) {
                Text("Rest day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if habit.habitKind == .count {
                amountStepper(habit, shown: shown, day: n)
            } else {
                // The state the user saw, flipped (`setChecked(!shown)`): the setter re-reads the
                // store and writes only what differs.
                Toggle(isOn: Binding(get: { checked }, set: { write(.checked($0), on: n) })) {
                    Text("Completed")
                }
                .tint(.green)
                .accessibilityIdentifier("history.completed")
            }
            Divider()
            noteEditor(hasRecord: hasRecord)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
    }

    /// The amount: one more or one less than what the user saw, set (never added); stepping down
    /// from 1 deletes the day, asking first when it carries a note (D7).
    private func amountStepper(_ habit: Habit, shown: Double, day n: Int) -> some View {
        let logged = SafeNumber.amount(shown)
        let target = SafeNumber.amount(habit.targetValue)
        let unit = habit.unit.flatMap { $0.isEmpty ? nil : $0 }
        let progress = appLocalized("\(logged) of \(target)")
        let spoken = unit.map { "\(progress) \($0)" } ?? progress
        let increment: () -> Void = { write(.value(shown + 1), on: n) }
        // Nothing to take away from an empty day.
        let decrement: (() -> Void)? = shown > 0 ? { write(.value(max(0, shown - 1)), on: n) } : nil
        let amount = "\(logged)/\(target)" + (unit.map { " \($0)" } ?? "")
        return Group {
            if typeSize.isAccessibilitySize {
                // The words get the row's whole width, one line each, and the control the line
                // under them: beside a stepper that does not grow, "Amount" and "3/8 glasses"
                // shared about 236 pt at AX5 and both broke mid-word ("W4-AX-1").
                VStack(alignment: .leading, spacing: 8) {
                    Text("Amount")
                    Text(verbatim: amount)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper(onIncrement: increment, onDecrement: decrement, onEditingChanged: { _ in }) {
                        Text("Amount")
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Stepper(onIncrement: increment, onDecrement: decrement, onEditingChanged: { _ in }) {
                    HStack {
                        Text("Amount")
                        Spacer()
                        Text(verbatim: amount)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // One adjustable element, as Today's count row is: "Amount, 3 of 8 glasses", swipe up or
        // down — not a label beside two unnamed buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Amount")
        .accessibilityValue(spoken)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement?()
            @unknown default: break
            }
        }
        .accessibilityIdentifier("history.amount")
    }

    @ViewBuilder
    private func noteEditor(hasRecord: Bool) -> some View {
        let accepted = Self.acceptsNoteDraft(draft.text, stored: draft.seen)
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)   // the field's own label says it
            TextField("How did it go?", text: $draft.text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .focused($noteFocused)
                .disabled(!hasRecord)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.appBackground))
                .accessibilityLabel("Note")
                .accessibilityIdentifier("history.note")
            if !hasRecord {
                Text("Check in to add a note.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !accepted {
                Text("Notes can be up to 500 characters.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if hasRecord && draft.isDirty {
                Button("Save") { flushNote() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!accepted)
                    .accessibilityIdentifier("history.saveNote")
            }
        }
    }

    // MARK: - Actions

    private func showMonth(_ delta: Int, from month: Date, calendar: Calendar) {
        guard let moved = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        displayedMonth = Self.monthStart(containing: moved, in: calendar)
    }

    /// Picks another day. A note being typed is written first; when that needs a question, the
    /// question comes up and the day stays until it is answered.
    private func select(_ n: Int) {
        guard n != selectedDay else { return }
        guard flushNote(then: .select(n)) else { return }
        noteFocused = false
        selectedDay = n
        refresh()
    }

    /// Done: the note being typed is written, then the sheet closes — unless that write asks
    /// first (the answer then closes it, or Cancel stays), or its save failed (the editor then
    /// shows the store again).
    private func finish() {
        guard flushNote(then: .close) else { return }
        dismiss()
    }

    /// A check or a value, after any note the user typed: the note is written first, so an
    /// un-check that follows it asks about the note the user just wrote.
    private func write(_ write: Write, on n: Int) {
        guard flushNote(then: .write(write, n)) else { return }
        perform(write, on: n)
    }

    /// Writes the note draft if the user changed it; false when that stopped what was to follow
    /// (`followUp`): a question is up, the save failed, or the habit is gone.
    ///
    /// - `asking` (the user asked for something): a draft over the cap (`acceptsNoteDraft`) is
    ///   not written and stops it, with "Notes can be up to 500 characters." and Discard
    ///   Changes / Cancel; a write that needs the user's go asks, its question offering Discard
    ///   Changes too. An answer that writes or discards goes on with `followUp`.
    /// - not `asking` (the field lost focus, or the sheet is gone): what can be written without a
    ///   question is; the rest is left as it is, and stops nothing.
    @discardableResult
    private func flushNote(asking: Bool = true, then followUp: FollowUp? = nil) -> Bool {
        guard draft.isDirty, let day = draft.day else { return true }
        guard Self.acceptsNoteDraft(draft.text, stored: draft.seen) else {
            guard asking else { return true }
            overCap = OverCapDraft(then: followUp)
            return false
        }
        return perform(.note(draft.text), on: day, asking: asking, then: followUp)
    }

    /// "Discard Changes": the note goes back to what the store holds, then what the user asked
    /// for goes on. Nothing is written for the draft.
    private func discardDraft(then followUp: FollowUp?) {
        draft = draft.discarded()
        refresh()
        proceed(followUp)
    }

    /// Goes on with what a note draft stood in front of, once the question that stood between is
    /// gone: on the next turn, after the alert's own dismissal has cleared its state, so a step
    /// that asks again puts up a question of its own rather than having it cleared.
    private func proceed(_ followUp: FollowUp?) {
        guard let followUp else { return }
        DispatchQueue.main.async {
            switch followUp {
            case .close: finish()
            case .select(let n): select(n)
            case .write(let write, let n): self.write(write, on: n)
            }
        }
    }

    /// One write, re-resolved now. True when it went through (or there was nothing to write).
    @discardableResult
    private func perform(_ write: Write, on n: Int, confirmed: HabitCheckIn.Confirmation? = nil,
                         asking: Bool = true, then followUp: FollowUp? = nil) -> Bool {
        let result = Self.commit(write, habitID: habitID, dayKey: HabitStats.key(ofDay: n), in: modelContext,
                                 confirmed: confirmed, environment: injectedCommit ?? .live)
        switch result {
        case .habitGone:
            dismiss()
            return false
        case .outcome(.committed), .outcome(.noChange):
            // The note went in: the field shows the stored note now, untouched. It is not always
            // the text written — a combine stores both notes — and a draft kept against it would
            // be written again at the next Done, over the other device's note.
            if case .note = write { draft = NoteDraft() }
            refresh()
            return true
        case .outcome(.needsConfirmation(let about)):
            if asking { confirming = PendingWrite(write: write, day: n, about: about, then: followUp) }
            return false
        case .outcome(.saveFailed):
            // Undone by the commit; the editor shows the store again (D4 step 1).
            draft = NoteDraft()
            refresh()
            return false
        }
    }

    /// Re-reads what the editor shows from the store, and dismisses when the habit is gone.
    private func refresh() {
        guard let habit = Self.resolve(habitID, in: modelContext) else {
            dismiss()
            return
        }
        let stored = Self.storedDay(of: habit, onKey: HabitStats.key(ofDay: selectedDay), in: modelContext)
        let next = draft.refreshed(day: selectedDay, stored: stored.note, hasRecord: stored.hasRecord)
        if next != draft { draft = next }
    }

    private func isConfirming(_ about: HabitCheckIn.Confirmation) -> Binding<Bool> {
        Binding(get: { confirming?.about == about },
                set: { if !$0 { confirming = nil } })
    }

    private var isOverCap: Binding<Bool> {
        Binding(get: { overCap != nil }, set: { if !$0 { overCap = nil } })
    }

    // MARK: - The model (static, for the hosted tests)

    /// What the editor writes.
    enum Write: Equatable {
        case checked(Bool)
        case value(Double)
        case note(String)
    }

    /// What the user asked for that a changed note stood in front of (`flushNote`); it goes on
    /// once the note is written or discarded.
    enum FollowUp: Equatable {
        /// Done.
        case close
        /// Another day in the grid.
        case select(Int)
        /// A check or a value (`write(_:on:)`).
        case write(Write, Int)
    }

    struct PendingWrite: Equatable {
        let write: Write
        let day: Int
        let about: HabitCheckIn.Confirmation
        /// For a note draft's write, what the user asked for behind it; nil for a check or value
        /// write, the Save button, or a question with nothing behind it.
        var then: FollowUp? = nil

        /// The question is about the note draft: it offers "Discard Changes" as well.
        var isNoteDraft: Bool {
            if case .note = write { return true }
            return false
        }
    }

    /// A changed note over the cap that stood in front of `then`.
    struct OverCapDraft: Equatable {
        var then: FollowUp?
    }

    enum CommitResult: Equatable {
        /// The habit is not in the store any more: nothing written; the sheet closes.
        case habitGone
        case outcome(HabitEntryCommit.Outcome)
    }

    /// One History write: the habit re-resolved by id, then its setter inside
    /// `HabitEntryCommit.commit` on `dayKey` (a day-key, so every keying below keeps it as it is).
    @MainActor
    static func commit(_ write: Write, habitID: UUID, dayKey: Date, in context: ModelContext,
                       confirmed: HabitCheckIn.Confirmation? = nil,
                       environment: HabitEntryCommit.Environment = .live) -> CommitResult {
        guard let habit = resolve(habitID, in: context) else { return .habitGone }
        let outcome = HabitEntryCommit.commit(habitID: habitID, day: dayKey, in: context, environment: environment) { undo in
            switch write {
            case .checked(let checked):
                return HabitCheckIn.setChecked(checked, on: dayKey, of: habit, in: context, confirmed: confirmed, undo: undo)
            case .value(let value):
                return HabitCheckIn.setValue(value, on: dayKey, of: habit, in: context, confirmed: confirmed, undo: undo)
            case .note(let text):
                return HabitCheckIn.setNote(text, on: dayKey, of: habit, in: context, confirmed: confirmed, undo: undo)
            }
        }
        return .outcome(outcome)
    }

    /// The habit with `habitID` in `context`, as the store (and this context's pending changes)
    /// holds it now; nil once it is deleted, here or by another context.
    @MainActor
    static func resolve(_ habitID: UUID, in context: ModelContext) -> Habit? {
        var descriptor = FetchDescriptor<Habit>(predicate: #Predicate { $0.id == habitID })
        descriptor.fetchLimit = 1
        guard let habit = try? context.fetch(descriptor).first, !habit.isDeleted else { return nil }
        return habit
    }

    /// Whether the day holds a record, and its kept record's note (`HabitCheckIn.liveRecords`) as
    /// the STORE has it: read through a context of its own unless this one holds a change of its
    /// own to it — mainContext keeps its copy of a record another context saved over
    /// (`HabitCheckIn.adoptStoredFields` says why), and the editor follows the store.
    @MainActor
    static func storedDay(of habit: Habit, onKey key: Date, in context: ModelContext) -> (hasRecord: Bool, note: String?) {
        guard let kept = HabitCheckIn.liveRecords(of: habit, on: key).first else { return (false, nil) }
        let id = kept.persistentModelID
        let pending = context.insertedModelsArray.contains { $0.persistentModelID == id }
            || context.changedModelsArray.contains { $0.persistentModelID == id }
        guard !pending else { return (true, kept.note) }
        let ids = [id]
        let reader = ModelContext(context.container)
        guard let row = try? reader.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { ids.contains($0.persistentModelID) })).first
        else { return (true, kept.note) }
        return (true, row.note)
    }

    /// The editor's note. `seen` is the day's stored note as last read ("" for none): an untouched
    /// draft follows the store, so a note pulled while the editor is open shows; one the user
    /// changed keeps their text until it is written.
    struct NoteDraft: Equatable {
        /// The day it belongs to; nil before the first read.
        var day: Int?
        var seen = ""
        var text = ""

        /// The user changed it.
        var isDirty: Bool { text != seen }

        /// After a read of the store: a new day, a day with no record, or an untouched draft
        /// takes the stored note; a changed draft keeps its text, against the new stored note.
        func refreshed(day: Int, stored: String?, hasRecord: Bool) -> NoteDraft {
            let stored = hasRecord ? (stored ?? "") : ""
            guard hasRecord, day == self.day, isDirty else { return NoteDraft(day: day, seen: stored, text: stored) }
            return NoteDraft(day: day, seen: stored, text: text)
        }

        /// "Discard Changes": the stored note as last read, untouched again.
        func discarded() -> NoteDraft {
            NoteDraft(day: day, seen: seen, text: seen)
        }
    }

    /// Whether `draft` may replace `stored` as a day's note: within the cap, or exactly the
    /// stored note (an existing longer note survives a value edit; Data safety 1).
    static func acceptsNoteDraft(_ draft: String, stored: String?) -> Bool {
        draft.count <= noteCharacterLimit || draft == (stored ?? "")
    }

    // MARK: - Days

    /// The days History offers (D8): from min(creation day, earliest live record) − 365 days to
    /// today, as day numbers, but never before `HabitCalendar.firstRealDayKey` (2025-01-01, X2):
    /// a key before it is one a non-Gregorian device wrote, which `DayKeyRepair` takes for a stray
    /// key and moves, so a backfill must never land there. Never a future day.
    static func window(startDay: Date, today: Date, calendar: Calendar) -> ClosedRange<Int> {
        let last = dayNumber(ofInstant: today, in: calendar)
        let start = min(HabitStats.dayNumber(ofKey: startDay), last)
        return min(max(start - backdatingDays, HabitCalendar.firstRealDayNumber), last)...last
    }

    /// The day number of a LOCAL instant's date in `calendar` — never taking the instant for a
    /// day-key, which an instant at exactly UTC midnight would be taken for
    /// (`HabitCalendar.dayKey(forInstant:)`).
    static func dayNumber(ofInstant instant: Date, in calendar: Calendar) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: instant, calendar: calendar))
    }

    /// Noon of a day number's date in `calendar`'s zone: an instant on that date in every zone (a
    /// DST change happens at night), for the grid's and the editor's dates. The key's date is
    /// Gregorian, so it is read back in a Gregorian calendar (`HabitCalendar.dayCalendar`, X2): in
    /// the device's own, 2026-10-15 would be Reiwa 2026 on a Japanese-calendar phone.
    static func noon(ofDay day: Int, in calendar: Calendar) -> Date {
        let key = HabitStats.key(ofDay: day)
        let c = HabitCalendar.utc.dateComponents([.year, .month, .day], from: key)
        return HabitCalendar.dayCalendar(calendar).date(from: DateComponents(year: c.year, month: c.month,
                                                                             day: c.day, hour: 12)) ?? key
    }

    /// Noon of the first day of the month containing `instant`, in `calendar`.
    static func monthStart(containing instant: Date, in calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.era, .year, .month], from: instant)
        return calendar.date(from: DateComponents(era: c.era, year: c.year, month: c.month, day: 1, hour: 12)) ?? instant
    }

    /// The grid's cells for the month starting at `monthStart`: nil for each cell before its first
    /// day (the week starts on `calendar.firstWeekday`), then each day's number.
    static func monthCells(_ monthStart: Date, in calendar: Calendar) -> [Int?] {
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let lead = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let first = dayNumber(ofInstant: monthStart, in: calendar)
        return Array(repeating: nil, count: lead) + (0..<count).map { first + $0 }
    }
}

// MARK: - The commit environment

/// The `HabitEntryCommit.Environment` Today's rows and History commit with: nil means the app's
/// own (`.live`). The hosted tests put a recording one in, so a row or History write they drive
/// never reaches the host app's deletion queue, widgets, badge or notification store.
private struct HabitEntryCommitKey: EnvironmentKey {
    static var defaultValue: HabitEntryCommit.Environment? { nil }
}

extension EnvironmentValues {
    var habitEntryCommit: HabitEntryCommit.Environment? {
        get { self[HabitEntryCommitKey.self] }
        set { self[HabitEntryCommitKey.self] = newValue }
    }
}
