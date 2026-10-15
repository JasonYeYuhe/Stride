import XCTest
import SwiftData
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
