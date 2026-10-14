import SwiftUI
import SwiftData

/// A habit's History: a month grid and the selected day's editor (RELEASE-1.4.1.md D6, with
/// D7's notes and D8's backdating window). **Owner: W4.** Scaffolded by W0: the shell presents
/// it for `ShellRequest.history(habitID:day:)` (ContentView), but nothing issues that request
/// yet and the body is empty.
///
/// TODO(W4): implement D6.
/// - Entry points (they set `shell.request = .history(habitID:day:)`): the detail card's
///   visible "Edit history" button (W3), a heatmap cell (D5, W3), the grid's VoiceOver action
///   (W3), and a checked, noted widget row through the app route (D7, W2).
/// - A shell sheet: it survives a size-class crossing and never pushes into the shared stack.
///   No nested sheet and no separate day sheet; on the Mac the menu sheet probe covers it.
/// - Layout: a month grid with ‹ › and 44 pt cells, each an accessibility element with day,
///   date and state; under it the selected day's editor — a check toggle (yes/no) or a value
///   stepper (count) — and a note. The header carries the check-in count, which left the
///   detail card's tiles when "Total" became "Strength" (D10).
/// - Days: from `HabitStats.startDay` − 365 d up to today, never a future day (D8). `createdAt`
///   is never written.
/// - Notes only on days with a record (D7): yes/no once the day is checked, count at a value
///   ≥ 1. The 500-character cap applies to new input only (`acceptsNoteDraft`).
/// - State holds the habit id, the day and the draft. Every write goes through HabitCheckIn's
///   D4 setters inside `HabitEntryCommit.commit`, re-resolving the habit and the record at
///   commit time; `.needsConfirmation` asks first (D7); `.saveFailed` resets the editor; the
///   sheet dismisses if the habit is gone.
/// - Strings: the new keys are in the W0 key list (scratchpad w0/keys.json, for the catalogs).
struct HabitHistoryView: View {
    /// The cap on a new note's length (D6). An existing longer note is never truncated.
    static let noteCharacterLimit = 500

    /// The habit, by id: it is re-resolved at commit (D6), never held as a model object.
    let habitID: UUID
    /// The day the sheet opened on (a local instant; keyed with `HabitCalendar.dayKey`).
    let day: Date

    /// The editor's draft, only in view state (2026-10-15).
    private struct Draft: Equatable {
        var checked: Bool?
        var value: Double?
        var note: String = ""
    }

    @State private var displayedMonth: Date
    @State private var selectedDay: Date
    @State private var draft = Draft()

    init(habitID: UUID, day: Date) {
        self.habitID = habitID
        self.day = day
        _displayedMonth = State(initialValue: day)
        _selectedDay = State(initialValue: day)
    }

    var body: some View {
        // TODO(W4): the month grid and the day editor.
        EmptyView()
    }

    /// Whether `draft` may replace `stored` as a day's note: within the cap, or exactly the
    /// stored note (an existing longer note survives a value edit; Data safety 1).
    static func acceptsNoteDraft(_ draft: String, stored: String?) -> Bool {
        // TODO(W4)
        true
    }
}
