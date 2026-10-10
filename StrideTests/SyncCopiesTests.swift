import XCTest
import SwiftData
import Foundation

/// Converting held rows in place — `Shared/SyncCopies.swift`, the code that ships
/// (DEV-PLAN-1.3.md M2, "Restore into another account, and restores the server has tombstoned").
///
/// What must hold: a converted row is a new row (fresh id, never delivered, not held, not
/// restored) with its linkage kept; no deletion is queued for an old id; a row that is not held
/// for an id reason is left exactly as it was; and one save.
@MainActor
final class SyncCopiesTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func dayKey(_ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: d))!
    }

    /// Acknowledged at its current stamp, as a push answered 200 leaves it.
    private func delivered<Row: SyncDeliverable>(_ row: Row) -> Row {
        row.acknowledge(sentStamp: row.stamp)
        return row
    }

    private func habit(_ name: String, records days: [Int] = [], group: HabitGroup? = nil) -> Habit {
        let habit = Habit(name: name)
        habit.groupId = group?.id
        context.insert(habit)
        habit.records = days.map { HabitRecord(date: dayKey($0)) }
        return habit
    }

    /// The row refs the next push would send.
    private func plannedRefs() throws -> (refs: Set<SyncRowRef>, deletions: Int) {
        let plan = try SyncPushPlanner.plan(in: context, deletions: SyncDeletionQueue.Batch())
        return (Set(plan.chunks.flatMap { $0.submitted.map(\.ref) }), plan.deletionCount)
    }

    private func ref(_ kind: SyncRowKind, _ id: UUID) -> SyncRowRef {
        SyncRowRef(kind: kind, id: id.uuidString)
    }

    /// `ModelContext.didSave` for `context` while `body` runs.
    private func countingSaves(_ body: () throws -> Void) rethrows -> Int {
        final class Count: @unchecked Sendable { var value = 0 }
        let saves = Count()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { _ in
            saves.value += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try body()
        return saves.value
    }

    /// The app's own deletion queue lives in the process's standard defaults; nothing here may
    /// write to it (there is no queue parameter, and this pins that nothing reaches around it).
    private let queueKeys = [SyncDeletionQueue.habitsKey, SyncDeletionQueue.entriesKey, SyncDeletionQueue.groupsKey]
    private func standardQueue() -> [[String]?] {
        queueKeys.map { UserDefaults.standard.stringArray(forKey: $0) }
    }

    // MARK: - Restore as new copies, in a store that is not empty

    func testReidentifyGivesHeldRowsFreshIdsKeepsLinkageAndQueuesNoDeletion() throws {
        // Live rows that sync normally, beside the held ones.
        let liveGroup = delivered(HabitGroup(name: "Work"))
        context.insert(liveGroup)
        let bystander = delivered(habit("Email", records: [1], group: liveGroup))
        bystander.records.forEach { _ = delivered($0) }

        // A restored group another device deleted.
        let heldGroup = HabitGroup(name: "Health")
        context.insert(heldGroup)
        heldGroup.restoredAt = Date()
        heldGroup.hold(.tombstoned)

        // A live habit in that group, with a restored check-in whose day was untapped elsewhere.
        let live = delivered(habit("Walk", records: [1, 2], group: heldGroup))
        live.records.forEach { _ = delivered($0) }
        let heldCheckIn = HabitRecord(date: dayKey(3))
        live.records.append(heldCheckIn)
        heldCheckIn.restoredAt = Date()
        heldCheckIn.hold(.tombstoned)

        // A habit another account owns, in the held group: its check-ins, one held with it, one
        // that the old id delivered before the habit was refused (syncedAt must not survive).
        let foreign = habit("Read", records: [1, 2, 3], group: heldGroup)
        foreign.hold(.notOwned)
        foreign.records[0].hold(.notOwned)
        _ = delivered(foreign.records[1])
        try context.save()

        let old = (group: heldGroup.id, foreign: foreign.id, foreignRecords: Set(foreign.records.map(\.id)),
                   heldCheckIn: heldCheckIn.id, liveRecords: Set(live.records.filter { $0 !== heldCheckIn }.map(\.id)),
                   live: live.id, liveStamp: live.stamp, bystander: bystander.id)
        let counts = (habits: try context.fetchCount(FetchDescriptor<Habit>()),
                      records: try context.fetchCount(FetchDescriptor<HabitRecord>()),
                      groups: try context.fetchCount(FetchDescriptor<HabitGroup>()))
        let queueBefore = standardQueue()

        let held = try SyncCopies.heldRows(in: context)
        XCTAssertEqual(held.groups.map(\.id), [old.group])
        XCTAssertEqual(held.habits.map(\.id), [old.foreign])
        XCTAssertEqual(held.records.map(\.id), [old.heldCheckIn], "the foreign habit's held check-in goes with it")
        XCTAssertEqual(try plannedRefs().refs.intersection([ref(.group, old.group), ref(.habit, old.foreign),
                                                            ref(.entry, old.heldCheckIn)]), [], "held: never planned")

        var outcome = SyncCopies.Outcome()
        let saves = try countingSaves { outcome = try SyncCopies.reidentify(held, in: context) }
        XCTAssertEqual(saves, 1, "one save")
        XCTAssertFalse(context.hasChanges)

        XCTAssertEqual(outcome.rows, SyncRowCounts(groups: 1, habits: 1, entries: 3 + 1))
        XCTAssertEqual(outcome.ignored, SyncRowCounts())
        XCTAssertEqual(outcome.regroupedHabits, 1, "the live habit in the converted group")

        // Fresh ids, recorded old → new.
        XCTAssertNotEqual(heldGroup.id, old.group)
        XCTAssertEqual(outcome.groupIDs, [old.group: heldGroup.id])
        XCTAssertNotEqual(foreign.id, old.foreign)
        XCTAssertEqual(outcome.habitIDs, [old.foreign: foreign.id])
        XCTAssertTrue(Set(foreign.records.map(\.id)).isDisjoint(with: old.foreignRecords))
        XCTAssertNotEqual(heldCheckIn.id, old.heldCheckIn)

        // Linkage kept: the same rows in the store, each check-in on its habit, each habit in its group.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Habit>()), counts.habits)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), counts.records)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitGroup>()), counts.groups)
        XCTAssertEqual(foreign.records.count, 3)
        XCTAssertEqual(foreign.groupId, heldGroup.id)
        XCTAssertEqual(live.groupId, heldGroup.id)
        XCTAssertTrue(live.records.contains { $0 === heldCheckIn })

        // Converted rows are new rows: never delivered, not held, not restored — pending.
        let converted: [any SyncDeliverable] = [heldGroup, foreign, heldCheckIn] + foreign.records
        for row in converted {
            XCTAssertNil(row.syncedAt, "\(row.id)")
            XCTAssertFalse(row.isHeld)
            XCTAssertNil(row.syncHoldReason)
            XCTAssertNil(row.restoredAt)
            XCTAssertTrue(row.isPending)
        }

        // The live habit changed group, so it goes up again — with its own id; its delivered
        // check-ins and the bystander's rows are untouched.
        XCTAssertEqual(live.id, old.live)
        XCTAssertTrue(SyncTimestamp.isNewer(live.stamp, than: old.liveStamp))
        XCTAssertTrue(live.isPending)
        XCTAssertEqual(Set(live.records.filter { $0 !== heldCheckIn }.map(\.id)), old.liveRecords)
        XCTAssertTrue(live.records.filter { $0 !== heldCheckIn }.allSatisfy { !$0.isPending })
        XCTAssertEqual(bystander.id, old.bystander)
        XCTAssertFalse(bystander.isPending)

        // The next push sends the new ids and no old one, and no deletion.
        let planned = try plannedRefs()
        XCTAssertEqual(planned.deletions, 0, "no deletion for an old id")
        let expected: Set<SyncRowRef> = Set([ref(.group, heldGroup.id), ref(.habit, foreign.id), ref(.habit, live.id),
                                             ref(.entry, heldCheckIn.id)] + foreign.records.map { ref(.entry, $0.id) })
        XCTAssertEqual(planned.refs, expected)
        XCTAssertEqual(standardQueue(), queueBefore)
    }

    /// "Restore as new copies" for a row restored with its ids and answered `tombstoned`: held
    /// by the per-answer rule, never planned, and planned as a new row once converted.
    func testARestoredRowAnsweredTombstonedIsHeldAndCopiesPlanItAsNew() throws {
        let document = BackupDocument(schemaVersion: 2, exportedAt: Date(), groups: [], habits: [
            BackupHabit(id: UUID(), name: "Stretch", emoji: "🤸", colorHex: "#34C759", createdAt: Date(timeIntervalSince1970: 1_750_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_750_000_100), isArchived: false, sortOrder: 1,
                        reminderEnabled: false, reminderHour: 20, reminderMinute: 0, note: nil, kind: "binary",
                        targetValue: 1, unit: nil, scheduleKind: "daily", timesPerWeek: 7, activeDaysMask: 127, groupId: nil,
                        records: [BackupRecord(id: UUID(), date: "2026-09-01", value: 1, note: nil, updatedAt: nil)]),
        ])
        try DataBackup.restore(document, into: context, identity: .keepIDs, withdrawingDeletionsFrom: nil)
        let habit = try XCTUnwrap(try context.fetch(FetchDescriptor<Habit>()).first)
        let record = try XCTUnwrap(habit.records.first)
        let oldHabit = habit.id, oldRecord = record.id

        // The server answers the push: tombstoned / tombstoned_habit.
        let answers: [(row: any SyncDeliverable, reason: String)] = [(habit, "tombstoned"), (record, "tombstoned_habit")]
        for (row, reason) in answers {
            let action = SyncAnswers.rowAction(skipped: true, reason: reason,
                                               facts: SyncRowFacts(isRestored: row.restoredAt != nil))
            XCTAssertEqual(action, .hold(.tombstoned))
            row.hold(.tombstoned)
        }
        try context.save()
        XCTAssertTrue(try plannedRefs().refs.isEmpty, "held, and so are the entries of a held habit")

        let held = try SyncCopies.heldRows(in: context, reasons: [.tombstoned])
        XCTAssertEqual(held.counts, SyncRowCounts(groups: 0, habits: 1, entries: 0), "\"1 restored habit was deleted on another device\"")
        XCTAssertTrue(try SyncCopies.heldRows(in: context, reasons: [.notOwned]).isEmpty)

        try SyncCopies.reidentify(held, in: context)
        XCTAssertNotEqual(habit.id, oldHabit)
        XCTAssertNotEqual(record.id, oldRecord)
        XCTAssertEqual(try plannedRefs().refs, [ref(.habit, habit.id), ref(.entry, record.id)])
        XCTAssertNil(habit.restoredAt, "a new row: a later real deletion elsewhere applies to it")
        XCTAssertNil(record.restoredAt)
    }

    /// Why `syncedAt` is written, not assumed nil: a check-in the old habit id delivered before
    /// the habit was refused keeps its mark through the hold. Converted but still marked, it
    /// would read as "delivered, then deleted elsewhere" to the next full pull — which the new
    /// ids are absent from until the push lands — and be deleted.
    func testConvertedRowsSurviveTheNextFullPull() throws {
        let foreign = habit("Foreign", records: [1, 2])
        _ = delivered(foreign.records[0])
        foreign.hold(.notOwned)
        let gone = delivered(habit("Deleted elsewhere"))   // the control: the pass does run
        try context.save()

        try SyncCopies.reidentify(try SyncCopies.heldRows(in: context), in: context)
        let snapshot = SyncPullResponse(habits: [], entries: [], groups: [], deletedHabitIds: nil, deletedEntryIds: nil,
                                        deletedGroupIds: nil, serverTime: "2026-09-29T00:00:00Z",
                                        totals: SyncTotals(habits: 0, entries: 0, groups: 0))
        let report = try SyncReconciler.apply(snapshot, to: context, isFullPull: true)

        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(gone.isDeleted || gone.modelContext == nil, "a delivered row the account lacks is deleted")
        let habits = try context.fetch(FetchDescriptor<Habit>())
        XCTAssertEqual(habits.map(\.name), ["Foreign"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 2, "both check-ins kept, the delivered one too")
    }

    /// Only rows held for an id reason are converted. The rest are ignored, not refused, and left
    /// exactly as they were: an edit since the list was drawn lifts a hold by itself.
    func testReidentifyIgnoresRowsThatAreNotHeldForAnIdReason() throws {
        let badValue = habit("Bad value", records: [1])
        badValue.hold(.invalidValue)
        let edited = habit("Edited since")
        edited.hold(.notOwned)
        let heldParent = habit("Held parent", records: [1])
        heldParent.hold(.notOwned)
        heldParent.records[0].hold(.notOwned)
        let plainGroup = delivered(HabitGroup(name: "Plain"))
        context.insert(plainGroup)
        try context.save()
        let rows = SyncHeldRows(groups: [plainGroup], habits: [badValue, edited],
                                records: [heldParent.records[0]])   // its habit is held and not in this call
        edited.touch()   // e.g. renamed in the app, or the widget's tap
        try context.save()
        let ids = [badValue.id, edited.id, heldParent.id, heldParent.records[0].id, plainGroup.id]

        var outcome = SyncCopies.Outcome()
        let saves = try countingSaves { outcome = try SyncCopies.reidentify(rows, in: context) }

        XCTAssertEqual(outcome.rows, SyncRowCounts())
        XCTAssertEqual(outcome.ignored, SyncRowCounts(groups: 1, habits: 2, entries: 1))
        XCTAssertEqual([badValue.id, edited.id, heldParent.id, heldParent.records[0].id, plainGroup.id], ids)
        XCTAssertEqual(badValue.activeHold, .invalidValue, "a content hold stays: a new id would be refused the same way")
        XCTAssertTrue(edited.isPending)
        XCTAssertEqual(saves, 0, "nothing changed, nothing saved")
    }

    // MARK: - Discard

    func testDiscardDeletesHeldRowsLocallyAndQueuesNothing() throws {
        let heldGroup = HabitGroup(name: "Old group")
        context.insert(heldGroup)
        heldGroup.hold(.notOwned)
        let foreign = habit("Foreign", records: [1, 2], group: heldGroup)
        foreign.hold(.notOwned)
        let live = delivered(habit("Live", records: [1, 2], group: heldGroup))
        live.records.forEach { _ = delivered($0) }
        let heldCheckIn = live.records[1]
        heldCheckIn.restoredAt = Date()
        heldCheckIn.hold(.tombstoned)
        let fine = habit("Fine")
        try context.save()
        let queueBefore = standardQueue()
        // By identity, not by position: a relationship array's order is not kept across a save,
        // and reading `records[0]` after it picked the held check-in (a flaky failure in phase B).
        let keptRecord = try XCTUnwrap(live.records.first { $0.persistentModelID != heldCheckIn.persistentModelID }).id

        let rows = try SyncCopies.heldRows(in: context)
        var outcome = SyncCopies.Outcome()
        let saves = try countingSaves {
            outcome = try SyncCopies.discard(SyncHeldRows(groups: rows.groups, habits: rows.habits + [fine],
                                                          records: rows.records), in: context)
        }

        XCTAssertEqual(saves, 1)
        XCTAssertEqual(outcome.rows, SyncRowCounts(groups: 1, habits: 1, entries: 2 + 1))
        XCTAssertEqual(outcome.ignored, SyncRowCounts(groups: 0, habits: 1, entries: 0), "\"Fine\" is not held")
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.name)), ["Live", "Fine"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<HabitRecord>()).map(\.id), [keptRecord])
        XCTAssertTrue(try context.fetch(FetchDescriptor<HabitGroup>()).isEmpty)
        // No ghost: the habit already loaded no longer lists the discarded check-in.
        XCTAssertEqual(live.records.map(\.id), [keptRecord])
        // A habit keeps its groupId: no edit to upload for a row the user did not touch.
        XCTAssertNotNil(live.groupId)
        XCTAssertFalse(live.isPending)

        XCTAssertEqual(try plannedRefs().deletions, 0, "nothing queued")
        XCTAssertEqual(standardQueue(), queueBefore)
    }
}
