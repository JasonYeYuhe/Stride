import XCTest
import SwiftData
import SwiftUI
@testable import Stride

/// `HabitEntryCommit` (RELEASE-1.4.1.md D4, Data safety 1), hosted, through its injected
/// environment: an in-memory store, a save that can be made to fail, a deletion queue on scratch
/// defaults, and recording closures for the effects and the stats bump — nothing here reaches the
/// host app's queue, widgets, badge or notification store.
@MainActor
final class HabitEntryCommitTests: XCTestCase {

    /// What the commit did outside the store, in order.
    private final class Recorder {
        var events: [String] = []
        /// How many of the next saves throw before reaching the context.
        var failingSaves = 0
        var badge: XCTestExpectation?
    }

    private struct InjectedSaveFailure: Error {}

    private var container: ModelContainer!
    private var context: ModelContext!
    private var recorder: Recorder!
    private var scratch: ScratchDefaults!
    private var queue: SyncDeletionQueue!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    /// 2026-09-16 15:00 in Los Angeles: the commit's "now", for `endsReminders`.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 15))! }
    /// The day written: 2026-09-16 as a day-key, which every keying keeps as it is — the setters
    /// key with the device's calendar, whatever zone the simulator is in.
    private let today = HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: 16))!

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        recorder = Recorder()
        scratch = ScratchDefaults("commit.local")
        queue = SyncDeletionQueue(local: scratch.defaults, shared: nil)
    }

    override func tearDown() {
        scratch.remove()
        queue = nil
        scratch = nil
        recorder = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func environment() -> HabitEntryCommit.Environment {
        let recorder = self.recorder!
        let queue = self.queue!
        let now = self.now, calendar = self.calendar
        return HabitEntryCommit.Environment(
            save: { context in
                recorder.events.append("save")
                if recorder.failingSaves > 0 {
                    recorder.failingSaves -= 1
                    throw InjectedSaveFailure()
                }
                try context.save()
            },
            trackDeletedEntry: { id in
                recorder.events.append("tombstone \(id)")
                queue.trackEntry(id)
            },
            effects: CheckInEffects(
                reloadWidgets: { recorder.events.append("reload") },
                updateBadge: { _ in
                    recorder.events.append("badge")
                    recorder.badge?.fulfill()
                },
                cancelSnooze: { _ in recorder.events.append("cancelSnooze") },
                withdrawDelivered: { _ in recorder.events.append("withdraw") },
                submitRefresh: { recorder.events.append("submitRefresh") }),
            bumpStats: { _ in recorder.events.append("bump") },
            reportSaveFailure: { _ in recorder.events.append("report") },
            now: { now },
            calendar: { calendar })
    }

    private func habit(_ kind: HabitKind = .binary, value: Double? = nil, note: String? = nil) throws -> Habit {
        let habit = Habit(name: kind == .count ? "Drink Water" : "Meditate")
        habit.habitKind = kind
        if kind == .count { habit.targetValue = 8 }
        context.insert(habit)
        if let value { habit.records.append(HabitRecord(date: today, note: note, value: value)) }
        try context.save()
        return habit
    }

    /// The habit's records as the store holds them now, through a context of their own.
    private func stored(_ habit: Habit) throws -> [HabitRecord] {
        let id = habit.id
        let fresh = ModelContext(container)
        return try XCTUnwrap(fresh.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first).records
    }

    @discardableResult
    private func commit(_ habit: Habit, on day: Date? = nil,
                        _ write: @escaping (Habit, Date, HabitCheckIn.Undo) -> HabitCheckIn.Change) -> HabitEntryCommit.Outcome {
        let day = day ?? today
        return HabitEntryCommit.commit(habitID: habit.id, day: day, in: context, environment: environment()) { undo in
            write(habit, day, undo)
        }
    }

    /// Waits for the effects' Task to reach the badge, the last effect on every path.
    private func awaitEffects() async {
        await fulfillment(of: [recorder.badge!], timeout: 5)
    }

    // MARK: - Tombstones only after the save

    /// An un-check queues exactly one tombstone, after the save; then the widgets and the badge,
    /// never the snooze or banners (they still ask for something not done).
    func testAnUncheckQueuesExactlyOneTombstoneAfterTheSave() async throws {
        let habit = try habit(value: 1)
        let id = try XCTUnwrap(habit.records.first).id.uuidString
        recorder.badge = expectation(description: "badge")

        let outcome = commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(false, on: day, of: habit, in: self.context, undo: undo)
        }
        XCTAssertEqual(outcome, .committed(.init(deletedRecordIDs: [id], isCompleted: false, loggedValue: 0, isCheckIn: false)))
        XCTAssertEqual(Array(recorder.events.prefix(2)), ["save", "tombstone \(id)"])
        XCTAssertEqual(queue.pending().entries, [id])
        XCTAssertTrue(try stored(habit).isEmpty)

        await awaitEffects()
        XCTAssertEqual(recorder.events, ["save", "tombstone \(id)", "reload", "bump", "badge"])
    }

    /// A check-in on the day the reminders ask for ends them; a backfill of an earlier day does not.
    func testACheckInRunsTheCheckInEffectsForItsDay() async throws {
        let habit = try habit()
        recorder.badge = expectation(description: "badge")
        let outcome = commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: self.context, undo: undo)
        }
        guard case .committed(let written) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(written.isCheckIn)
        await awaitEffects()
        XCTAssertEqual(recorder.events, ["save", "bump", "reload", "cancelSnooze", "withdraw", "submitRefresh", "badge"])

        recorder.events = []
        recorder.badge = expectation(description: "badge, backfill")
        let threeDaysAgo = HabitCalendar.utc.date(byAdding: .day, value: -3, to: today)!
        commit(habit, on: threeDaysAgo) { habit, day, undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: self.context, undo: undo)
        }
        await awaitEffects()
        XCTAssertEqual(recorder.events, ["save", "bump", "reload", "submitRefresh", "badge"])
    }

    // MARK: - A failed save

    /// The un-check's save fails: nothing is queued, nothing runs, and the deletion is taken back
    /// — so an unrelated save afterwards (mainContext autosaves; sync saves on it) does not land it
    /// with no tombstone. The record is still in the store and the deletion queue is empty.
    func testAFailedSaveIsUndoneAndAnUnrelatedSaveKeepsTheRecord() throws {
        let habit = try habit(value: 1, note: "a note worth keeping")
        let record = try XCTUnwrap(habit.records.first)
        record.acknowledge(sentStamp: record.stamp)
        try context.save()
        let before = (id: record.id, note: record.note, stamp: record.updatedAt, value: record.value)

        recorder.failingSaves = 1
        let outcome = commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(false, on: day, of: habit, in: self.context, confirmed: .removeNote, undo: undo)
        }
        XCTAssertEqual(outcome, .saveFailed)
        XCTAssertEqual(recorder.events, ["save", "report"], "no tombstone, no effects, no bump")
        XCTAssertTrue(queue.pending().isEmpty)

        // Something else entirely, saved on the same context.
        context.insert(Habit(name: "Unrelated"))
        try context.save()

        let stored = try stored(habit)
        XCTAssertEqual(stored.count, 1, "the record is still in the store")
        let kept = try XCTUnwrap(stored.first)
        XCTAssertEqual(kept.id, before.id)
        XCTAssertEqual(kept.note, before.note)
        XCTAssertEqual(kept.updatedAt, before.stamp)
        XCTAssertEqual(kept.value, before.value)
        XCTAssertFalse(kept.isPending, "nothing for sync to send")
        XCTAssertTrue(queue.pending().isEmpty, "the deletion queue is empty")
        XCTAssertTrue(habit.isCompletedOn(today), "the row still reads checked")
    }

    /// A failed edit and a failed check-in are taken back too.
    func testAFailedEditOrCheckInLeavesTheStoreAsItWas() throws {
        let count = try habit(.count, value: 3)
        let record = try XCTUnwrap(count.records.first)
        let stamp = record.updatedAt
        recorder.failingSaves = 1
        XCTAssertEqual(commit(count) { habit, day, undo in
            HabitCheckIn.setValue(5, on: day, of: habit, in: self.context, undo: undo)
        }, .saveFailed)
        XCTAssertEqual(record.value, 3)
        XCTAssertEqual(record.updatedAt, stamp)

        let yesNo = try habit()
        recorder.failingSaves = 1
        XCTAssertEqual(commit(yesNo) { habit, day, undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: self.context, undo: undo)
        }, .saveFailed)
        XCTAssertFalse(yesNo.isCompletedOn(today))

        context.insert(Habit(name: "Unrelated"))
        try context.save()
        XCTAssertEqual(try stored(count).map(\.value), [3])
        XCTAssertEqual(try stored(count).map(\.updatedAt), [stamp])
        XCTAssertTrue(try stored(yesNo).isEmpty, "the failed check-in did not land later")
    }

    /// A failed day merge brings every duplicate back.
    func testAFailedMergeBringsTheDuplicatesBack() throws {
        let count = try habit(.count, value: 8)
        let other = HabitRecord(date: today, note: "from the iPad", value: 2)
        count.records.append(other)
        try context.save()
        recorder.failingSaves = 1
        XCTAssertEqual(commit(count) { habit, day, undo in
            HabitCheckIn.setValue(3, on: day, of: habit, in: self.context, undo: undo)
        }, .saveFailed)
        context.insert(Habit(name: "Unrelated"))
        try context.save()
        let stored = try stored(count)
        XCTAssertEqual(stored.map(\.value).sorted(), [2, 8])
        XCTAssertEqual(stored.first { $0.id == other.id }?.note, "from the iPad")
        XCTAssertTrue(queue.pending().isEmpty)
    }

    // MARK: - A day merge (decision 7; W2 review)

    /// Two delivered records of one day, as two devices' check-ins leave it: `older` first, then
    /// `newer` (equal values, so D2 keeps the newer one).
    private func deliveredPair(note: String? = nil) throws -> (habit: Habit, older: HabitRecord, newer: HabitRecord) {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        let older = HabitRecord(date: today, note: note)
        older.updatedAt = SyncTimestamp.floorToMillisecond(Date(timeIntervalSince1970: 1_790_000_000))
        let newer = HabitRecord(date: today, note: note)
        newer.updatedAt = SyncTimestamp.floorToMillisecond(Date(timeIntervalSince1970: 1_790_000_060))
        [older, newer].forEach { $0.acknowledge(sentStamp: $0.stamp) }
        habit.records = [older, newer]
        try context.save()
        return (habit, older, newer)
    }

    /// A merge-only write (a stale row's check of a checked day): saved, effects run, NO tombstone
    /// — the server's one row of the day may be under the dropped record's id, and deleting it
    /// lost the day on every device — and the kept record is sent again at its own stamp, so that
    /// row takes it whatever its id (W2 review, "merge-tombstones-server-row", SYNC-2).
    func testAMergeQueuesNoTombstoneAndSendsTheKeptRecordAgain() async throws {
        let (habit, _, newer) = try deliveredPair(note: "same")
        let stamp = newer.updatedAt
        recorder.badge = expectation(description: "badge")
        let outcome = commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: self.context, undo: undo)
        }
        XCTAssertEqual(outcome, .committed(.init(deletedRecordIDs: [], isCompleted: true, loggedValue: 1, isCheckIn: false)))
        XCTAssertTrue(queue.pending().isEmpty, "no tombstone for a merge")
        let stored = try stored(habit)
        XCTAssertEqual(stored.map(\.id), [newer.id])
        XCTAssertEqual(stored.first?.updatedAt, stamp, "its own stamp, not a new one")
        XCTAssertEqual(stored.first?.note, "same")
        XCTAssertTrue(try XCTUnwrap(stored.first).isPending, "sent again")
        await awaitEffects()
        XCTAssertEqual(recorder.events, ["save", "reload", "bump", "badge"])
    }

    /// The same merge, its save failing: both records come back as they were, the forced resend
    /// is taken back, and an unrelated save afterwards lands none of it.
    func testAFailedMergeOnlyCommitLeavesBothRecordsAsTheyWere() throws {
        let (habit, older, newer) = try deliveredPair()
        recorder.failingSaves = 1
        XCTAssertEqual(commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: self.context, undo: undo)
        }, .saveFailed)
        XCTAssertFalse(newer.needsResend)
        context.insert(Habit(name: "Unrelated"))
        try context.save()
        let stored = try stored(habit)
        XCTAssertEqual(Set(stored.map(\.id)), [older.id, newer.id])
        XCTAssertTrue(stored.allSatisfy { !$0.isPending }, "nothing for sync to send")
        XCTAssertTrue(queue.pending().isEmpty)
    }

    /// The commit's own guard: whatever a write returns, no tombstone is queued for an id a record
    /// in the store still carries after the save — that would delete the record's row on the
    /// server and, by its echo, the record here — and each id is queued once.
    func testTheCommitNeverTombstonesAnIDARecordStillCarries() throws {
        let habit = try habit(value: 1)
        let gone = try XCTUnwrap(habit.records.first)
        let goneID = gone.id.uuidString
        let survivor = HabitRecord(date: HabitCalendar.utc.date(byAdding: .day, value: -1, to: today)!)
        habit.records.append(survivor)
        try context.save()
        let outcome = commit(habit) { habit, _, undo in
            undo.deleted(gone, of: habit)
            self.context.delete(gone)
            return .changed(.init(deletedRecordIDs: [goneID, survivor.id.uuidString, goneID], isCompleted: false,
                                  loggedValue: 0, isCheckIn: false))
        }
        guard case .committed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(queue.pending().entries, [goneID])
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("tombstone") }, ["tombstone \(goneID)"])
        XCTAssertEqual(try stored(habit).map(\.id), [survivor.id])
    }

    // MARK: - No change, and a question

    /// `.noChange` saves nothing and runs no effects.
    func testNoChangeSavesNothingAndRunsNoEffects() throws {
        let habit = try habit(value: 1)
        XCTAssertEqual(commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(true, on: day, of: habit, in: self.context, undo: undo)
        }, .noChange)
        XCTAssertEqual(recorder.events, [])
        XCTAssertFalse(context.hasChanges)
    }

    /// A noted check-in: asked first, nothing written; confirmed, deleted with its one tombstone.
    func testANotedUncheckAsksThenCommitsOnConfirmation() async throws {
        let habit = try habit(value: 1, note: "ran in the rain")
        let id = try XCTUnwrap(habit.records.first).id.uuidString
        XCTAssertEqual(commit(habit) { habit, day, undo in
            HabitCheckIn.setChecked(false, on: day, of: habit, in: self.context, undo: undo)
        }, .needsConfirmation(.removeNote))
        XCTAssertEqual(recorder.events, [])
        XCTAssertFalse(context.hasChanges)

        recorder.badge = expectation(description: "badge")
        guard case .committed(let written) = commit(habit, { habit, day, undo in
            HabitCheckIn.setChecked(false, on: day, of: habit, in: self.context, confirmed: .removeNote, undo: undo)
        }) else { return XCTFail("not committed") }
        XCTAssertEqual(written.deletedRecordIDs, [id])
        XCTAssertEqual(queue.pending().entries, [id])
        await awaitEffects()
    }

    /// A multi-setter write whose second setter asks: the first one's change is taken back too.
    func testAWriteThatEndsInAQuestionLeavesNothingPending() throws {
        let count = try habit(.count, value: 1, note: "one")
        let record = try XCTUnwrap(count.records.first)
        let stamp = record.updatedAt
        let outcome = commit(count) { habit, day, undo in
            _ = HabitCheckIn.setNote("changed", on: day, of: habit, in: self.context, undo: undo)
            return HabitCheckIn.setValue(0, on: day, of: habit, in: self.context, undo: undo)
        }
        XCTAssertEqual(outcome, .needsConfirmation(.removeNote))
        XCTAssertEqual(record.note, "one")
        XCTAssertEqual(record.updatedAt, stamp)
        XCTAssertEqual(recorder.events, [], "nothing saved")
    }

    // MARK: - Notes survive value edits (Data safety 1)

    /// A pull changes the note while an edit is in flight — the row (or History's editor) still
    /// shows the old state — and the user then changes the value: the setter writes only the
    /// value, so the pulled note survives. The pull lands on mainContext, as the sync engine's
    /// reconcile does, and again from a context of its own.
    func testAPulledNoteSurvivesALaterValueEdit() throws {
        let count = try habit(.count, value: 3, note: "mine")
        let record = try XCTUnwrap(count.records.first)
        let shown = count.loggedValue(on: today)   // what the row drew

        record.note = "pulled from the iPad"
        record.touch()
        try context.save()

        XCTAssertNotEqual(commit(count) { habit, day, undo in
            HabitCheckIn.setValue(shown + 1, on: day, of: habit, in: self.context, undo: undo)
        }, .saveFailed)
        var stored = try stored(count)
        XCTAssertEqual(stored.map(\.value), [4])
        XCTAssertEqual(stored.map(\.note), ["pulled from the iPad"])

        // From another context: this one's copy of the record may still hold the old note.
        let id = count.id
        let other = ModelContext(container)
        let elsewhere = try XCTUnwrap(other.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        let theirs = try XCTUnwrap(elsewhere.records.first)
        theirs.note = "pulled again"
        theirs.touch()
        try other.save()

        let outcome = commit(count) { habit, day, undo in
            HabitCheckIn.setValue(5, on: day, of: habit, in: self.context, undo: undo)
        }
        guard case .committed = outcome else { return XCTFail("\(outcome)") }
        stored = try self.stored(count)
        XCTAssertEqual(stored.map(\.value), [5])
        XCTAssertEqual(stored.map(\.note), ["pulled again"])
    }

    /// A 600-character stored note (longer than History's cap on new input) survives a value edit
    /// untruncated.
    func testASixHundredCharacterNoteSurvivesAValueEdit() throws {
        let long = String(repeating: "日記 note ", count: 75)   // 600 characters
        XCTAssertEqual(long.count, 600)
        let count = try habit(.count, value: 2, note: long)
        let outcome = commit(count) { habit, day, undo in
            HabitCheckIn.setValue(6, on: day, of: habit, in: self.context, undo: undo)
        }
        guard case .committed = outcome else { return XCTFail("\(outcome)") }
        let stored = try stored(count)
        XCTAssertEqual(stored.map(\.value), [6])
        XCTAssertEqual(stored.first?.note, long)
    }
}

/// The app's half of the widget's noted row (RELEASE-1.4.1.md D7): the history link the row opens
/// becomes the shell request that presents that habit's History on that day
/// (`StrideApp.historyRequest`, which `.onOpenURL` hands to the window's shell) — and only a habit
/// that is here and not archived does; anything else opens the app as it is. The sign-in path
/// never sees a history link, and a login link never becomes a history request.
@MainActor
final class HistoryRouteTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    /// 2026-09-16 21:00 in Los Angeles: already the 17th in UTC.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 21))! }

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    private func key(_ year: Int, _ month: Int, _ day: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func request(_ url: URL) -> ShellRequest? {
        StrideApp.historyRequest(for: url, in: context, now: now, calendar: calendar)
    }

    private func habit(archived: Bool = false) throws -> Habit {
        let habit = Habit(name: "Read")
        habit.isArchived = archived
        context.insert(habit)
        try context.save()
        return habit
    }

    /// The day-key of the day the request opens History on, if it is a history request for `habit`.
    private func openedDay(_ habit: Habit, _ dayKey: Date) -> Date? {
        guard case .history(let id, let day)? = request(HistoryLink.url(habitID: habit.id, dayKey: dayKey)),
              id == habit.id else { return nil }
        return HabitCalendar.dayKey(forInstant: day, calendar: calendar)
    }

    func testAHistoryLinkOpensThatHabitsHistoryOnThatDay() throws {
        let habit = try habit()
        XCTAssertEqual(openedDay(habit, key(2026, 9, 12)), key(2026, 9, 12),
                       "the row's day, as a local instant in the device's zone")
        XCTAssertEqual(openedDay(habit, key(2026, 9, 16)), key(2026, 9, 16),
                       "today in Los Angeles, though UTC is on the 17th")
    }

    /// History never shows a future day (D8): a link to one opens on today.
    func testADayAfterTodayOpensOnToday() throws {
        let habit = try habit()
        XCTAssertEqual(openedDay(habit, key(2026, 9, 17)), key(2026, 9, 16))
        XCTAssertEqual(openedDay(habit, key(2026, 9, 20)), key(2026, 9, 16))
    }

    /// Deleted, archived, or never synced here: the app just opens.
    func testAHabitThatIsNotHereOpensTheAppAsItIs() throws {
        XCTAssertNil(request(HistoryLink.url(habitID: UUID(), dayKey: key(2026, 9, 12))))
        let archived = try habit(archived: true)
        XCTAssertNil(request(HistoryLink.url(habitID: archived.id, dayKey: key(2026, 9, 12))))
    }

    /// A Japanese-calendar device (W2 review, "W2-URL-2"): the widget keys today as year 8 of
    /// Reiwa, 0008-10-15, and the link opens History on that same day — 2026-10-15 — re-keyed to
    /// the widget's key.
    func testAJapaneseCalendarDevicesLinkOpensThatDay() throws {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = japanese.timeZone
        let now = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 21)))
        let habit = try habit()
        let widgetKey = WidgetTimelinePlan.dayKey(of: now, in: japanese)
        let url = HistoryLink.url(habitID: habit.id, dayKey: widgetKey)
        XCTAssertTrue(url.absoluteString.hasSuffix("day=0008-10-15"), url.absoluteString)
        guard case .history(let id, let day)? = StrideApp.historyRequest(for: url, in: context, now: now, calendar: japanese)
        else { return XCTFail("no history request for \(url)") }
        XCTAssertEqual(id, habit.id)
        XCTAssertEqual(HabitCalendar.dayKey(forInstant: day, calendar: japanese), widgetKey)
        XCTAssertEqual(gregorian.dateComponents([.year, .month, .day], from: day), DateComponents(year: 2026, month: 10, day: 15))
    }

    // MARK: - Handing the request to the shell (W2 review, "W2-URL-1")

    func testARequestIsSetOnlyWhenNothingIsPresented() throws {
        let request = ShellRequest.history(habitID: UUID(), day: now)
        let shell = ShellState(launchArguments: [])
        StrideApp.present(request, in: shell, presenting: true)
        XCTAssertNil(shell.request, "under a sheet or an alert: nothing left behind to swallow the next tap")
        StrideApp.present(request, in: shell, presenting: false)
        XCTAssertEqual(shell.request, request)

        let exporting = ShellState(launchArguments: [])
        exporting.request = .export(.json)
        StrideApp.present(request, in: exporting, presenting: false)
        XCTAssertEqual(exporting.request, .export(.json), "a menu Export in progress is left alone")

        let waiting = ShellState(launchArguments: [])
        waiting.request = .newHabit   // asked for, not on screen yet
        StrideApp.present(request, in: waiting, presenting: false)
        XCTAssertEqual(waiting.request, request, "the newer ask wins")
    }

    /// A login link is the sign-in path's, never a history request; a malformed history link is
    /// nobody's.
    func testALoginLinkIsNeverAHistoryRequest() throws {
        let habit = try habit()
        let login = try XCTUnwrap(URL(string: "https://stride-api.colorarchive.me/login?token=3f2b8c1e9a7d4c05b6e1f0a2d3c4b5a69788f1e2d3c4b5a6978801a2b3c4d5e6"))
        XCTAssertNil(request(login))
        XCTAssertEqual(AppURLRoute.of(login, calendar: calendar), .signIn)
        let malformed = try XCTUnwrap(URL(string: "stride://history?habit=\(habit.id.uuidString)&day=2026-02-30"))
        XCTAssertNil(request(malformed))
        XCTAssertEqual(AppURLRoute.of(malformed, calendar: calendar), .other)
    }

    #if DEBUG
    // MARK: - The a11y sweep's launch argument (DEBUG)

    /// `-openHistory <habit> [-historyDay <days>]` (`StrideApp.launchHistoryRequest`), which
    /// scripts/a11y_sweep.sh launches with to capture History: a habit by its exact name, or else by
    /// its place in Stats' list, archived habits not counted; days from today in the device's zone,
    /// never a future day; no habit, or no argument, asks for nothing.
    func testTheSweepsLaunchArgumentAsksForThatHabitsHistory() throws {
        var listed: [Habit] = []
        for (order, name) in ["Morning Run", "Read 30 min", "0"].enumerated() {
            let habit = Habit(name: name)
            habit.sortOrder = Double(order)
            context.insert(habit)
            listed.append(habit)
        }
        let archived = Habit(name: "Old")
        archived.sortOrder = -1
        archived.isArchived = true
        context.insert(archived)
        try context.save()

        func asked(_ arguments: [String]) -> (habitID: UUID, dayKey: Date)? {
            guard case .history(let id, let day)? = StrideApp.launchHistoryRequest(
                arguments: ["Stride", "-demo", "-tab", "1"] + arguments, in: context, now: now, calendar: calendar)
            else { return nil }
            return (id, HabitCalendar.dayKey(forInstant: day, calendar: calendar))
        }
        XCTAssertEqual(asked(["-openHistory", "Read 30 min"])?.habitID, listed[1].id, "by name")
        XCTAssertEqual(asked(["-openHistory", "Read 30 min"])?.dayKey, key(2026, 9, 16),
                       "today in Los Angeles, though UTC is on the 17th")
        XCTAssertEqual(asked(["-openHistory", "1"])?.habitID, listed[1].id, "by index; the archived habit is not counted")
        XCTAssertEqual(asked(["-openHistory", "0"])?.habitID, listed[2].id, "a name before an index")
        XCTAssertEqual(asked(["-openHistory", "Read 30 min", "-historyDay", "-20"])?.dayKey, key(2026, 8, 27))
        XCTAssertEqual(asked(["-historyDay", "3", "-openHistory", "Morning Run"])?.dayKey, key(2026, 9, 16),
                       "a day after today opens on today")
        XCTAssertNil(asked(["-openHistory", "Old"]), "archived")
        XCTAssertNil(asked(["-openHistory", "7"]))
        XCTAssertNil(asked(["-openHistory"]))
        XCTAssertNil(asked(["-historyDay", "-20"]))
    }
    #endif
}

/// The window half of "W2-URL-1": a history link that arrives while the window already shows a
/// presentation sets nothing, and once that is gone the next link opens History — in a real window
/// on the host app's scene, through SwiftUI's own presentations. `WindowPresentation` reads the
/// window's root view controller; these hold that a SwiftUI sheet a view in the window put up
/// counts there, and that the reader finds its window.
@MainActor
final class HistoryLinkPresentationTests: XCTestCase {

    @Observable
    fileprivate final class SheetSwitch {
        var shown = false
    }

    /// A view that, like one inside the app's window, puts up a sheet of its own.
    fileprivate struct SheetHost: View {
        let presentation: WindowPresentation
        @Bindable var sheet: SheetSwitch

        var body: some View {
            Color.clear
                .background(WindowPresentation.Reader(presentation: presentation))
                .sheet(isPresented: $sheet.shown) { Text(verbatim: "a sheet") }
        }
    }

    private var window: UIWindow?
    private var container: ModelContainer?
    /// As ShellTests: a hosted view's task can outlive its window, and a context whose container
    /// was released traps.
    private static var retiredContainers: [ModelContainer] = []

    override func tearDown() async throws {
        if let window {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene?.windows.first { $0 !== window }?.makeKey()
        }
        window = nil
        if let container { Self.retiredContainers.append(container) }
        container = nil
        try await super.tearDown()
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AnyView(view))
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting: \(what)")
                throw XCTSkip("timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testASheetAViewPresentedCountsAndTheReaderFindsItsWindow() async throws {
        let presentation = WindowPresentation()
        let sheet = SheetSwitch()
        let window = try host(SheetHost(presentation: presentation, sheet: sheet))
        try await waitUntil("the reader finds its window") { presentation.window === window }
        XCTAssertFalse(presentation.isPresenting)

        sheet.shown = true
        try await waitUntil("the view's sheet is up") { presentation.isPresenting }
        let shell = ShellState(launchArguments: [])
        let request = ShellRequest.history(habitID: UUID(), day: Date())
        StrideApp.present(request, in: shell, presenting: presentation.isPresenting)
        XCTAssertNil(shell.request)

        sheet.shown = false
        try await waitUntil("the view's sheet is gone") { !presentation.isPresenting }
        StrideApp.present(request, in: shell, presenting: presentation.isPresenting)
        XCTAssertEqual(shell.request, request)
    }

    /// The shell's own window, over SwiftUI's own presentation: a link under a sheet a view in it
    /// put up (Today's Add Habit, a row's Edit sheet, the Note alert) leaves nothing behind — so
    /// when that sheet closes, History does not pop up over Today on its own, as it did when the
    /// route set the request regardless (SwiftUI presents a sheet it could not present once the
    /// blocking one is gone; measured on the iOS 26.5 simulator) — and the next link opens History.
    func testUnderAnotherSheetALinkSetsNothingAndTheNextOneOpensHistory() async throws {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        self.container = container
        let habit = Habit(name: "Read")
        container.mainContext.insert(habit)
        try container.mainContext.save()
        let shell = ShellState(launchArguments: [])
        let window = try host(ContentView(shell: shell).modelContainer(container))
        let presentation = WindowPresentation()
        presentation.window = window
        let root = try XCTUnwrap(window.rootViewController)
        try await Task.sleep(for: .milliseconds(200))

        let other = UIViewController()
        root.present(other, animated: false)
        try await waitUntil("another sheet is up") { presentation.isPresenting }
        let request = ShellRequest.history(habitID: habit.id, day: Date())
        StrideApp.present(request, in: shell, presenting: presentation.isPresenting)
        XCTAssertNil(shell.request, "nothing left behind")

        other.dismiss(animated: false)
        try await waitUntil("the other sheet is gone") { root.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(root.presentedViewController, "no History popping up on its own")
        XCTAssertNil(shell.request)

        StrideApp.present(request, in: shell, presenting: presentation.isPresenting)
        try await waitUntil("History is presented") { presentation.isPresenting && shell.request == request }
    }
}
