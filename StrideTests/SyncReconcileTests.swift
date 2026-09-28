import XCTest
import SwiftData
import Foundation

/// Tests `SyncReconciler.apply` — the code `SyncService.pullRemote` actually runs.
///
/// This file used to test a copy of the algorithm pasted into it, because the real code lived
/// in Stride/Sources, which this target cannot see. The copy had drifted (it matched dates in
/// `Calendar.current`; the app uses UTC day-keys), and it built every id with
/// `UUID().uuidString`, which is uppercase — so it could not notice that server-generated ids
/// are lowercase and that the real code lost every one of them. The four original scenarios are
/// kept, now against the real implementation; the rest pin the bugs the copy was hiding.
@MainActor
final class SyncReconcileTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func remoteHabit(_ id: String, name: String = "Habit") -> SyncHabit {
        SyncHabit(id: id, name: name, emoji: "⭐", colorHex: "#34C759", isArchived: false, sortOrder: 0,
                  reminderEnabled: nil, reminderHour: nil, reminderMinute: nil, note: nil,
                  kind: nil, targetValue: nil, unit: nil, scheduleKind: nil, timesPerWeek: nil,
                  activeDaysMask: nil, groupId: nil,
                  createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z")
    }

    private func remoteEntry(_ id: String, habit: String, date: String, note: String? = nil,
                             value: Double = 1, updatedAt: String? = nil) -> SyncEntry {
        SyncEntry(id: id, habitId: habit, date: date, note: note, value: value, createdAt: "\(date)T00:00:00Z",
                  updatedAt: updatedAt)
    }

    /// `totals` default to the arrays' lengths: what a whole snapshot from a server since M0
    /// says. Pass them explicitly to model a truncated body.
    private func pull(habits: [SyncHabit] = [], entries: [SyncEntry] = [], groups: [SyncGroup]? = nil,
                      deletedHabits: [String]? = nil, deletedEntries: [String]? = nil,
                      deletedGroups: [String]? = nil, totals: SyncTotals?? = nil) -> SyncPullResponse {
        SyncPullResponse(habits: habits, entries: entries, groups: groups,
                         deletedHabitIds: deletedHabits, deletedEntryIds: deletedEntries,
                         deletedGroupIds: deletedGroups, serverTime: "2025-01-01T00:00:00Z",
                         totals: totals ?? SyncTotals(habits: habits.count, entries: entries.count,
                                                      groups: groups?.count ?? 0))
    }

    /// Marks a row delivered at its current stamp — as an acknowledgement or a pull would have.
    /// From 1.3.1 a full pull deletes only rows that were delivered (`syncedAt != nil`): a row
    /// never delivered from this device is kept and pushed instead.
    private func delivered<Row: SyncDeliverable>(_ row: Row) {
        row.syncedAt = SyncTimestamp.floorToMillisecond(row.stamp)
    }

    private func habits() throws -> [Habit] { try context.fetch(FetchDescriptor<Habit>()) }

    // MARK: - Original scenarios, now against the real reconciler

    /// Local entry with a different id than the server's entry for the same date must survive
    /// full-pull reconciliation, re-keyed to the server id.
    func testFullPullKeepsEntryWhenLocalAndServerIdsDifferForSameDate() throws {
        let habit = Habit(name: "Exercise")
        context.insert(habit)
        let localRecord = HabitRecord(date: dayKey(2025, 7, 15))
        habit.records.append(localRecord)
        try context.save()

        let serverEntryId = UUID().uuidString
        XCTAssertNotEqual(localRecord.id.uuidString, serverEntryId, "precondition: IDs should differ")

        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Exercise")],
                 entries: [remoteEntry(serverEntryId, habit: habit.id.uuidString, date: "2025-07-15", note: "server note")]),
            to: context, isFullPull: true)

        let h = try XCTUnwrap(habits().first)
        XCTAssertEqual(h.records.count, 1, "entry should still exist after full-pull reconcile")
        XCTAssertEqual(h.records.first?.id.uuidString, serverEntryId, "local ID should be aligned to server ID")
        XCTAssertEqual(h.records.first?.note, "server note", "note should be updated from server")
    }

    /// Full pull deletes local entries the server doesn't have — once delivered: from 1.3.1 an
    /// absent row that was never delivered is kept and pushed (Full-pull deletion rule).
    func testFullPullDeletesOrphanedLocalEntry() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        let record = HabitRecord(date: dayKey(2025, 8, 1))
        habit.records.append(record)
        delivered(record)
        try context.save()

        try SyncReconciler.apply(pull(habits: [remoteHabit(habit.id.uuidString, name: "Read")]),
                                 to: context, isFullPull: true)

        XCTAssertEqual(try habits().first?.records.count, 0, "orphaned entry should be deleted")
    }

    /// Full pull with matching entries preserves all of them.
    func testFullPullPreservesAllMatchingEntries() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)
        habit.records.append(HabitRecord(date: dayKey(2025, 9, 1)))
        habit.records.append(HabitRecord(date: dayKey(2025, 9, 2)))
        try context.save()

        let serverId1 = UUID().uuidString
        let serverId2 = UUID().uuidString
        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Meditate")],
                 entries: [remoteEntry(serverId1, habit: habit.id.uuidString, date: "2025-09-01"),
                           remoteEntry(serverId2, habit: habit.id.uuidString, date: "2025-09-02")]),
            to: context, isFullPull: true)

        let h = try XCTUnwrap(habits().first)
        XCTAssertEqual(h.records.count, 2, "both entries should survive")
        XCTAssertEqual(Set(h.records.map { $0.id.uuidString }), [serverId1, serverId2])
    }

    /// One matching entry, one orphan, one new from the server.
    func testFullPullMixedScenario() throws {
        let habit = Habit(name: "Journal")
        context.insert(habit)
        habit.records.append(HabitRecord(date: dayKey(2025, 9, 1)))
        let sep3 = HabitRecord(date: dayKey(2025, 9, 3))
        habit.records.append(sep3)
        delivered(sep3)   // delivered, then deleted elsewhere
        try context.save()

        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Journal")],
                 entries: [remoteEntry(UUID().uuidString, habit: habit.id.uuidString, date: "2025-09-01"),
                           remoteEntry(UUID().uuidString, habit: habit.id.uuidString, date: "2025-09-02", note: "new")]),
            to: context, isFullPull: true)

        let h = try XCTUnwrap(habits().first)
        XCTAssertEqual(h.records.count, 2, "should have Sep 1 (kept) + Sep 2 (new), Sep 3 deleted")
        let dates = Set(h.records.map { HabitCalendar.dayStringFormatter.string(from: $0.date) })
        XCTAssertEqual(dates, ["2025-09-01", "2025-09-02"])
    }

    // MARK: - Server-generated (lowercase) ids

    func testCanonicalIDNormalisesCase() {
        let uuid = UUID()
        XCTAssertEqual(SyncReconciler.canonicalID(uuid.uuidString.lowercased()), uuid.uuidString)
        XCTAssertEqual(SyncReconciler.canonicalID(uuid.uuidString), uuid.uuidString)
        XCTAssertEqual(SyncReconciler.canonicalID("not-a-uuid"), "NOT-A-UUID")
    }

    /// The App Review demo account. seed-demo.js makes ids with Node's `crypto.randomUUID()`,
    /// which is lowercase; the device knows the habit by its uppercase `uuidString`. Before the
    /// fix every pulled entry missed the habit map, and the full pull then deleted the device's
    /// history because no local id appeared in the server's (lowercase) set.
    func testLowercaseServerIdsAttachHistoryToTheExistingHabit() throws {
        let habit = Habit(name: "Morning Run")
        context.insert(habit)
        habit.records.append(HabitRecord(date: dayKey(2025, 9, 1)))
        try context.save()

        let habitId = habit.id.uuidString.lowercased()
        let e1 = UUID().uuidString.lowercased()
        let e2 = UUID().uuidString.lowercased()
        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habitId, name: "Morning Run")],
                 entries: [remoteEntry(e1, habit: habitId, date: "2025-09-01"),
                           remoteEntry(e2, habit: habitId, date: "2025-09-02")]),
            to: context, isFullPull: true)

        let all = try habits()
        XCTAssertEqual(all.count, 1, "a lowercase id must update the existing habit, not insert another")
        let h = try XCTUnwrap(all.first)
        XCTAssertEqual(h.records.count, 2, "both check-ins must attach and neither may be deleted")
        XCTAssertEqual(Set(h.records.map { $0.id.uuidString }), [e1.uppercased(), e2.uppercased()])
    }

    /// A fresh device signing into a server-seeded account, then syncing again. Previously the
    /// first pull kept the habit but dropped its entries, and a later pull could insert a second
    /// habit with the same UUID, after which the habit dictionary trapped.
    func testRepeatedPullsOfLowercaseIdsKeepOneHabitWithItsHistory() throws {
        let habitId = UUID().uuidString.lowercased()
        let entries = (1...3).map { remoteEntry(UUID().uuidString.lowercased(), habit: habitId, date: "2025-09-0\($0)") }
        let response = pull(habits: [remoteHabit(habitId, name: "Meditate")], entries: entries)

        try SyncReconciler.apply(response, to: context, isFullPull: true)
        try SyncReconciler.apply(response, to: context, isFullPull: false)
        try SyncReconciler.apply(response, to: context, isFullPull: false)

        let all = try habits()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id.uuidString, habitId.uppercased())
        XCTAssertEqual(all.first?.records.count, 3)
    }

    /// The same habit twice in one response, in different case, is one habit.
    func testSameHabitTwiceInOneResponseInsertsOnce() throws {
        let id = UUID().uuidString
        try SyncReconciler.apply(pull(habits: [remoteHabit(id.lowercased()), remoteHabit(id)]),
                                 to: context, isFullPull: true)
        XCTAssertEqual(try habits().count, 1)
    }

    func testLowercaseRemoteHabitDeletionRemovesTheLocalHabit() throws {
        let habit = Habit(name: "Journal")
        context.insert(habit)
        try context.save()

        try SyncReconciler.apply(pull(deletedHabits: [habit.id.uuidString.lowercased()]),
                                 to: context, isFullPull: false)

        XCTAssertTrue(try habits().isEmpty)
    }

    func testLowercaseRemoteEntryDeletionRemovesTheLocalRecord() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        let record = HabitRecord(date: dayKey(2025, 9, 1))
        habit.records.append(record)
        try context.save()

        try SyncReconciler.apply(pull(habits: [remoteHabit(habit.id.uuidString, name: "Read")],
                                      deletedEntries: [record.id.uuidString.lowercased()]),
                                 to: context, isFullPull: false)

        XCTAssertEqual(try habits().first?.records.count, 0)
    }

    func testLowercaseGroupIdsUpdateThenDeleteTheExistingGroup() throws {
        let group = HabitGroup(name: "Old", colorHex: "#000000", sortOrder: 0)
        context.insert(group)
        try context.save()
        let lower = group.id.uuidString.lowercased()

        // Edited on the server after the local group was made (from 1.3.1 an older remote edit
        // loses to the local one — the local-newer guard covers groups too).
        let remote = SyncGroup(id: lower, name: "Health", colorHex: "#FF0000", sortOrder: 1,
                               createdAt: "2025-01-01T00:00:00Z", updatedAt: "2099-02-01T00:00:00Z")
        try SyncReconciler.apply(pull(groups: [remote]), to: context, isFullPull: false)
        var groups = try context.fetch(FetchDescriptor<HabitGroup>())
        XCTAssertEqual(groups.count, 1, "a lowercase id must update the group, not insert another")
        XCTAssertEqual(groups.first?.name, "Health")

        try SyncReconciler.apply(pull(deletedGroups: [lower]), to: context, isFullPull: false)
        groups = try context.fetch(FetchDescriptor<HabitGroup>())
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Crash backstop

    /// `Habit.id` has no uniqueness constraint, so two rows can share an id. The lookup was built
    /// with `Dictionary(uniqueKeysWithValues:)`, which traps on that — inside the launch sync.
    /// Reaching the assertion is most of the test.
    func testDuplicateLocalHabitIdsDoNotTrap() throws {
        let id = UUID()
        let a = Habit(name: "A"); a.id = id; context.insert(a)
        let b = Habit(name: "B"); b.id = id; context.insert(b)
        try context.save()

        try SyncReconciler.apply(
            pull(habits: [remoteHabit(id.uuidString, name: "A")],
                 entries: [remoteEntry(UUID().uuidString, habit: id.uuidString, date: "2025-09-01")]),
            to: context, isFullPull: false)

        XCTAssertEqual(try habits().reduce(0) { $0 + $1.records.count }, 1)
    }

    // MARK: - Timestamps and last write wins (1.2.3)

    private func date(_ iso: String) -> Date { SyncTimestamp.parse(iso)! }

    /// The App Review demo account is seeded server-side, so every timestamp in it has
    /// milliseconds. A default ISO8601DateFormatter returns nil for those, and the habit fell
    /// back to createdAt = now — a year-old habit whose rate and Weekly Review started today.
    func testServerStampedCreatedAtWithMillisecondsIsKept() throws {
        let id = UUID().uuidString
        var h = remoteHabit(id, name: "Read")
        h = SyncHabit(id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, isArchived: false, sortOrder: 0,
                      reminderEnabled: nil, reminderHour: nil, reminderMinute: nil, note: nil, kind: nil,
                      targetValue: nil, unit: nil, scheduleKind: nil, timesPerWeek: nil, activeDaysMask: nil,
                      groupId: nil, createdAt: "2026-04-23T08:27:17.494Z", updatedAt: "2026-04-23T08:27:17.494Z")

        try SyncReconciler.apply(pull(habits: [h]), to: context, isFullPull: true)

        let habit = try XCTUnwrap(habits().first)
        XCTAssertEqual(habit.createdAt.timeIntervalSince1970, date("2026-04-23T08:27:17.494Z").timeIntervalSince1970, accuracy: 0.001,
                       "was Date(): the habit looked created today")
        XCTAssertEqual(try XCTUnwrap(habit.updatedAt).timeIntervalSince1970, habit.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTimestampParsesBothWireForms() {
        XCTAssertEqual(SyncTimestamp.parse("2026-09-15T17:33:18Z")?.timeIntervalSince1970, 1_789_493_598)
        XCTAssertEqual(try XCTUnwrap(SyncTimestamp.parse("2026-09-15T17:33:18.500Z")).timeIntervalSince1970, 1_789_493_598.5, accuracy: 0.001)
        XCTAssertNil(SyncTimestamp.parse("yesterday"))
        XCTAssertNil(SyncTimestamp.parse(nil))
        XCTAssertEqual(SyncTimestamp.string(from: Date(timeIntervalSince1970: 1_789_493_598.9)), "2026-09-15T17:33:18Z")
    }

    /// The cursor comes from the server's clock, a minute early, in the server's own format.
    func testCursorIsTheServerTimeMinusTheOverlap() {
        XCTAssertEqual(SyncCursor.next(afterServerTime: "2026-09-15T17:33:18.123Z"), "2026-09-15T17:32:18.123Z")
        XCTAssertEqual(SyncCursor.next(afterServerTime: "2026-09-15T17:33:18Z"), "2026-09-15T17:32:18.000Z")
        XCTAssertNil(SyncCursor.next(afterServerTime: ""))
    }

    /// A downloaded check-in keeps the edit time it came with, instead of looking edited now —
    /// which would let it beat a genuinely newer edit still offline on another device.
    func testDownloadedEntryKeepsItsEditTime() throws {
        let habit = Habit(name: "Water")
        context.insert(habit)
        try context.save()

        try SyncReconciler.apply(
            pull(entries: [remoteEntry(UUID().uuidString, habit: habit.id.uuidString, date: "2026-09-10",
                                       value: 8, updatedAt: "2026-09-10T18:00:00Z")]),
            to: context, isFullPull: false)

        let record = try XCTUnwrap(habits().first?.records.first)
        XCTAssertEqual(record.value, 8)
        XCTAssertEqual(record.updatedAt, date("2026-09-10T18:00:00Z"))
    }

    /// The server's value is newer: it replaces the local one, edit time included.
    func testNewerRemoteValueReplacesTheLocalOne() throws {
        let habit = Habit(name: "Water")
        context.insert(habit)
        let local = HabitRecord(date: dayKey(2026, 9, 10), value: 2)
        local.updatedAt = date("2026-09-10T09:00:00Z")
        habit.records.append(local)
        try context.save()

        try SyncReconciler.apply(
            pull(entries: [remoteEntry(local.id.uuidString, habit: habit.id.uuidString, date: "2026-09-10",
                                       value: 8, updatedAt: "2026-09-10T18:00:00Z")]),
            to: context, isFullPull: false)

        XCTAssertEqual(local.value, 8)
        XCTAssertEqual(local.updatedAt, date("2026-09-10T18:00:00Z"))
    }

    /// Tapped again after this sync's push went out: the local value is newer than what the
    /// pull brings back, so it stays (and goes up with the next push). The id still aligns.
    func testLocalEditNewerThanThePulledValueIsKept() throws {
        let habit = Habit(name: "Water")
        context.insert(habit)
        let local = HabitRecord(date: dayKey(2026, 9, 10), value: 5)
        local.updatedAt = date("2026-09-10T20:00:00Z")
        habit.records.append(local)
        try context.save()
        let serverID = UUID().uuidString

        try SyncReconciler.apply(
            pull(entries: [remoteEntry(serverID, habit: habit.id.uuidString, date: "2026-09-10",
                                       value: 2, updatedAt: "2026-09-10T18:00:00Z")]),
            to: context, isFullPull: false)

        XCTAssertEqual(local.value, 5)
        XCTAssertEqual(local.updatedAt, date("2026-09-10T20:00:00Z"))
        XCTAssertEqual(local.id.uuidString, serverID)
    }

    /// The push carries the entry's edit time, so the server can keep the newer of two edits.
    func testPushedEntryCarriesItsEditTime() throws {
        let entry = SyncEntry(id: "A", habitId: "H", date: "2026-09-10", note: nil, value: 8,
                              createdAt: "2026-09-10T00:00:00Z", updatedAt: "2026-09-10T18:00:00Z")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(json["updatedAt"] as? String, "2026-09-10T18:00:00Z")

        let legacyServer = #"{"id":"A","habitId":"H","date":"2026-09-10","note":null,"value":1,"createdAt":"2026-09-10T00:00:00Z"}"#
        XCTAssertNil(try JSONDecoder().decode(SyncEntry.self, from: Data(legacyServer.utf8)).updatedAt,
                     "a pull from a server that doesn't send updatedAt still decodes")
    }

    // MARK: - 1.3.1: delivery state on the pull side (DEV-PLAN-1.3.md M2, "Reconciler")

    private func remoteHabit(_ id: String, name: String, updatedAt: String,
                             createdAt: String = "2026-01-01T00:00:00.000Z") -> SyncHabit {
        SyncHabit(id: id, name: name, emoji: "⭐", colorHex: "#34C759", isArchived: false, sortOrder: 0,
                  reminderEnabled: nil, reminderHour: nil, reminderMinute: nil, note: nil,
                  kind: nil, targetValue: nil, unit: nil, scheduleKind: nil, timesPerWeek: nil,
                  activeDaysMask: nil, groupId: nil, createdAt: createdAt, updatedAt: updatedAt)
    }

    private func remoteGroup(_ id: String, name: String, updatedAt: String) -> SyncGroup {
        SyncGroup(id: id, name: name, colorHex: "#000000", sortOrder: 0,
                  createdAt: "2026-01-01T00:00:00.000Z", updatedAt: updatedAt)
    }

    /// :18.300 and :18.700 of one second — the two edits whole seconds could not tell apart.
    private let early = "2026-09-15T17:33:18.300Z"
    private let late = "2026-09-15T17:33:18.700Z"

    /// A local edit at :18.700, made while this device's :18.300 push was in flight, survives the
    /// :18.300 echo — for habits, entries and groups (review 2). Up to 1.3.0 the entry guard
    /// floored the local side to :18 and lost to its own echo, and habits and groups had none.
    func testALocalEditSurvivesTheEchoOfItsOwnEarlierPushForEveryRowType() throws {
        let habit = Habit(name: "Local")
        habit.updatedAt = date(late)
        context.insert(habit)
        let record = HabitRecord(date: dayKey(2026, 9, 15), value: 5)
        record.updatedAt = date(late)
        habit.records.append(record)
        let group = HabitGroup(name: "Local")
        group.updatedAt = date(late)
        context.insert(group)
        try context.save()

        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Echo", updatedAt: early)],
                 entries: [remoteEntry(record.id.uuidString, habit: habit.id.uuidString, date: "2026-09-15",
                                       value: 2, updatedAt: early)],
                 groups: [remoteGroup(group.id.uuidString, name: "Echo", updatedAt: early)]),
            to: context, isFullPull: false)

        XCTAssertEqual(habit.name, "Local")
        XCTAssertEqual(record.value, 5)
        XCTAssertEqual(group.name, "Local")
        XCTAssertEqual(habit.updatedAt, date(late))
        // Kept, and still pending: the newer value goes up with the next push.
        XCTAssertTrue(habit.isPending)
        XCTAssertTrue(record.isPending)
        XCTAssertTrue(group.isPending)
    }

    /// A remote :18.700 beats a local :18.300, for every row type, and the row is then delivered
    /// at exactly the applied stamp.
    func testARemoteEditLaterInTheSameSecondWinsForEveryRowType() throws {
        let habit = Habit(name: "Local")
        habit.updatedAt = date(early)
        context.insert(habit)
        let record = HabitRecord(date: dayKey(2026, 9, 15), value: 5)
        record.updatedAt = date(early)
        habit.records.append(record)
        let group = HabitGroup(name: "Local")
        group.updatedAt = date(early)
        context.insert(group)
        try context.save()

        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Remote", updatedAt: late)],
                 entries: [remoteEntry(record.id.uuidString, habit: habit.id.uuidString, date: "2026-09-15",
                                       value: 2, updatedAt: late)],
                 groups: [remoteGroup(group.id.uuidString, name: "Remote", updatedAt: late)]),
            to: context, isFullPull: false)

        XCTAssertEqual(habit.name, "Remote")
        XCTAssertEqual(record.value, 2)
        XCTAssertEqual(group.name, "Remote")
        for row in [habit, record, group] as [any SyncDeliverable] {
            XCTAssertEqual(row.stamp, date(late))
            XCTAssertEqual(row.syncedAt, date(late))
            XCTAssertFalse(row.isPending, "applied remote state is delivered state")
        }
    }

    /// Pulled rows are not pending — otherwise this device's own push returns through the 60 s
    /// overlap, looks pending, and every row echoes forever. At milliseconds, at the whole
    /// seconds an older app wrote, on insert, and through the entry id-alignment path.
    func testPulledRowsAreNotPendingAtEveryPrecisionAndThroughIdAlignment() throws {
        // A local check-in under another id, older than the server's.
        let habit = Habit(name: "Water")
        habit.updatedAt = date("2026-09-01T00:00:00.000Z")
        context.insert(habit)
        let local = HabitRecord(date: dayKey(2026, 9, 10), value: 1)
        local.updatedAt = date("2026-09-10T08:00:00.000Z")
        habit.records.append(local)
        try context.save()
        let alignedID = UUID().uuidString.lowercased()

        try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Water", updatedAt: "2026-09-10T09:00:00Z")],   // whole seconds
                 entries: [remoteEntry(alignedID, habit: habit.id.uuidString, date: "2026-09-10", value: 3,
                                       updatedAt: "2026-09-10T09:00:00.123Z"),
                           remoteEntry(UUID().uuidString, habit: habit.id.uuidString, date: "2026-09-11",
                                       updatedAt: "2026-09-11T09:00:00Z")],
                 groups: [remoteGroup(UUID().uuidString, name: "New", updatedAt: "2026-09-11T09:00:00.999Z")]),
            to: context, isFullPull: false)

        XCTAssertEqual(local.id.uuidString, alignedID.uppercased(), "aligned to the server's id")
        XCTAssertEqual(local.value, 3)
        let records = try XCTUnwrap(habits().first?.records)
        XCTAssertEqual(records.count, 2)
        let groups = try context.fetch(FetchDescriptor<HabitGroup>())
        let rows: [any SyncDeliverable] = [habit] + records + groups
        for row in rows {
            XCTAssertFalse(row.isPending, "\(type(of: row)) pulled but still pending")
            XCTAssertTrue(row.hasBeenDelivered)
        }
    }

    /// The pull kept a newer local value: still pending, its evidence of delivery unchanged.
    func testAPullThatKeptANewerLocalValueLeavesItPending() throws {
        let habit = Habit(name: "Water")
        context.insert(habit)
        let record = HabitRecord(date: dayKey(2026, 9, 10), value: 5)
        record.updatedAt = date("2026-09-10T20:00:00.000Z")
        record.syncedAt = date("2026-09-10T10:00:00.000Z")   // an earlier value was delivered
        habit.records.append(record)
        try context.save()

        let report = try SyncReconciler.apply(
            pull(entries: [remoteEntry(record.id.uuidString, habit: habit.id.uuidString, date: "2026-09-10",
                                       value: 2, updatedAt: "2026-09-10T18:00:00.000Z")]),
            to: context, isFullPull: false)

        XCTAssertEqual(record.value, 5)
        XCTAssertTrue(record.isPending)
        XCTAssertEqual(record.syncedAt, date("2026-09-10T10:00:00.000Z"))
        XCTAssertEqual(report.keptLocalNewer, [SyncRowRef(kind: .entry, id: record.id.uuidString)])
    }

    /// Applying remote state clears `needsResend` and any hold (and `restoredAt`): the server
    /// holds the row live for this account.
    func testApplyingRemoteStateClearsNeedsResendHoldsAndRestoredAt() throws {
        let habit = Habit(name: "Held")
        habit.updatedAt = date(early)
        context.insert(habit)
        habit.hold(.rowError)
        habit.needsResend = true
        habit.restoredAt = date(early)
        try context.save()

        try SyncReconciler.apply(pull(habits: [remoteHabit(habit.id.uuidString, name: "Fixed", updatedAt: late)]),
                                 to: context, isFullPull: false)

        XCTAssertNil(habit.activeHold)
        XCTAssertNil(habit.syncHoldReason)
        XCTAssertFalse(habit.needsResend)
        XCTAssertNil(habit.restoredAt)
        XCTAssertFalse(habit.isPending)
    }

    // MARK: - 1.3.1: the full-pull deletion rule

    private func records(of habit: Habit) -> Set<String> { Set(habit.records.map { $0.id.uuidString }) }

    /// A truncated full pull — `totals` larger than the arrays — or one without `totals` deletes
    /// nothing, but its upserts still apply (sub-decision (d)).
    func testATruncatedOrUncountedFullPullAppliesUpsertsAndDeletesNothing() throws {
        for totals in [SyncTotals(habits: 3, entries: 0, groups: 0), nil] {
            try tearDownStore()
            let gone = Habit(name: "Delivered, absent")
            context.insert(gone)
            delivered(gone)
            let kept = Habit(name: "Old name")
            context.insert(kept)
            delivered(kept)
            try context.save()

            let report = try SyncReconciler.apply(
                pull(habits: [remoteHabit(kept.id.uuidString, name: "New name", updatedAt: "2099-01-01T00:00:00.000Z")],
                     totals: .some(totals)),
                to: context, isFullPull: true)

            XCTAssertEqual(try habits().count, 2, "totals \(String(describing: totals)): the pass must not run")
            XCTAssertEqual(kept.name, "New name", "the upsert still applies")
            XCTAssertFalse(report.deletionPassRan)
            XCTAssertTrue(report.deletionPassSkipped)
            XCTAssertEqual(report.issues.first?.reason, totals == nil ? .totalsMissing : .totalsMismatch)
            XCTAssertNotNil(report.diagnostic)
        }
    }

    /// Held and never-delivered rows survive a validated full pull that lacks them; delivered
    /// ones go, `needsResend` or not (review 2: after a sweep a resend is a new insert).
    func testAValidatedFullPullKeepsHeldAndNeverDeliveredRowsAndRemovesDeliveredOnes() throws {
        let held = Habit(name: "Held")
        context.insert(held)
        delivered(held)
        held.hold(.notOwned)
        let neverSent = Habit(name: "Never sent")
        context.insert(neverSent)
        let deliveredGone = Habit(name: "Delivered")
        context.insert(deliveredGone)
        delivered(deliveredGone)
        let resend = Habit(name: "Needs resend")
        context.insert(resend)
        delivered(resend)
        resend.needsResend = true
        let heldGroup = HabitGroup(name: "Held group")
        context.insert(heldGroup)
        heldGroup.hold(.rowError)
        let goneGroup = HabitGroup(name: "Gone group")
        context.insert(goneGroup)
        delivered(goneGroup)
        try context.save()
        let log = SyncMemoryRecoveryLog()

        let report = try SyncReconciler.apply(pull(), to: context, isFullPull: true, recoveryLog: log)

        XCTAssertTrue(report.deletionPassRan)
        XCTAssertEqual(Set(try habits().map(\.name)), ["Held", "Never sent"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<HabitGroup>()).map(\.name), ["Held group"])
        // The needsResend row was pending, so it is in the log; the clean delivered one is not.
        XCTAssertEqual(log.lines.map(\.item.ref.id), [resend.id.uuidString])
        XCTAssertEqual(log.lines.first?.item.reason, .deletedElsewhere)
    }

    /// Every pending or held row a deletion takes is in the recovery log before it goes: a
    /// deleted habit's pending and held records one by one (the habit itself untouched), and an
    /// edited group — by full-pull absence here.
    func testAFullPullArchivesPendingAndHeldRowsOneByOneBeforeDeleting() throws {
        let habit = Habit(name: "Run")
        context.insert(habit)
        let clean = HabitRecord(date: dayKey(2026, 9, 1))
        let edited = HabitRecord(date: dayKey(2026, 9, 2), note: "offline edit")
        let held = HabitRecord(date: dayKey(2026, 9, 3))
        habit.records = [clean, edited, held]
        for row in [habit, clean, edited, held] as [any SyncDeliverable] { delivered(row) }
        edited.touch()
        held.hold(.invalidValue)
        let group = HabitGroup(name: "Morning")
        context.insert(group)
        delivered(group)
        group.name = "Mornings"
        group.touch()
        try context.save()
        let log = SyncMemoryRecoveryLog()

        let report = try SyncReconciler.apply(pull(), to: context, isFullPull: true, recoveryLog: log, accountID: "42")

        XCTAssertTrue(try habits().isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HabitRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HabitGroup>()).isEmpty)
        XCTAssertEqual(Set(log.lines.map(\.item.ref)), [
            SyncRowRef(kind: .entry, id: edited.id.uuidString),
            SyncRowRef(kind: .entry, id: held.id.uuidString),
            SyncRowRef(kind: .group, id: group.id.uuidString),
        ])
        XCTAssertEqual(report.archived, 3)
        XCTAssertTrue(log.lines.allSatisfy { $0.accountID == "42" })
        let editedLine = try XCTUnwrap(log.lines.first { $0.item.ref.id == edited.id.uuidString })
        guard case let .record(backup, habitID, habitName) = editedLine.item.row else { return XCTFail() }
        XCTAssertEqual(backup.note, "offline edit")
        XCTAssertEqual(habitID, habit.id, "a record line names its habit")
        XCTAssertEqual(habitName, "Run")
    }

    /// The same for an incremental pull's `deleted*Ids`, and for the cascade from a deleted
    /// habit: the offline edit to a check-in of a habit nobody touched is archived.
    func testAnIncrementalPullArchivesPendingRowsItsTombstonesAndCascadeTake() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        let edited = HabitRecord(date: dayKey(2026, 9, 2), note: "offline edit")
        let clean = HabitRecord(date: dayKey(2026, 9, 3))
        habit.records = [edited, clean]
        let other = Habit(name: "Other")
        context.insert(other)
        let otherEdited = HabitRecord(date: dayKey(2026, 9, 2), value: 4)
        other.records = [otherEdited]
        let group = HabitGroup(name: "Evening")
        context.insert(group)
        for row in [habit, edited, clean, other, otherEdited, group] as [any SyncDeliverable] { delivered(row) }
        edited.touch()
        otherEdited.touch()
        group.touch()
        try context.save()
        let log = SyncMemoryRecoveryLog()

        let report = try SyncReconciler.apply(
            pull(deletedHabits: [habit.id.uuidString.lowercased()],
                 deletedEntries: [otherEdited.id.uuidString.lowercased()],
                 deletedGroups: [group.id.uuidString]),
            to: context, isFullPull: false, recoveryLog: log)

        XCTAssertEqual(try habits().map(\.name), ["Other"])
        XCTAssertTrue(other.records.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HabitGroup>()).isEmpty)
        XCTAssertEqual(Set(log.lines.map(\.item.ref)), [
            SyncRowRef(kind: .entry, id: edited.id.uuidString),
            SyncRowRef(kind: .entry, id: otherEdited.id.uuidString),
            SyncRowRef(kind: .group, id: group.id.uuidString),
        ], "the clean record and the untouched habit are not archived")
        XCTAssertEqual(report.deleted, SyncRowCounts(groups: 1, habits: 1, entries: 3))
    }

    /// Each malformed snapshot applies its upserts and deletes nothing: a non-UUID id, two case
    /// variants of one id, an entry whose habit is missing, an unparsable date, two entries on
    /// one habit-day.
    func testEachInvalidSnapshotAppliesUpsertsAndDeletesNothing() throws {
        let cases: [(String, (String) -> SyncPullResponse)] = [
            ("non-UUID id", { h in self.pull(habits: [self.remoteHabit(h, name: "Up", updatedAt: "2099-01-01T00:00:00Z"),
                                                    self.remoteHabit("not-a-uuid", name: "X", updatedAt: "2099-01-01T00:00:00Z")]) }),
            ("case variants", { h in
                let other = UUID().uuidString
                return self.pull(habits: [self.remoteHabit(h, name: "Up", updatedAt: "2099-01-01T00:00:00Z"),
                                          self.remoteHabit(other, name: "A", updatedAt: "2099-01-01T00:00:00Z"),
                                          self.remoteHabit(other.lowercased(), name: "B", updatedAt: "2099-01-01T00:00:00Z")]) }),
            ("missing habit", { h in self.pull(habits: [self.remoteHabit(h, name: "Up", updatedAt: "2099-01-01T00:00:00Z")],
                                               entries: [self.remoteEntry(UUID().uuidString, habit: UUID().uuidString, date: "2026-09-01")]) }),
            ("unparsable date", { h in self.pull(habits: [self.remoteHabit(h, name: "Up", updatedAt: "2099-01-01T00:00:00Z")],
                                                 entries: [self.remoteEntry(UUID().uuidString, habit: h, date: "2026-13-45")]) }),
            ("unparsable stamp", { h in self.pull(habits: [self.remoteHabit(h, name: "Up", updatedAt: "2099-01-01T00:00:00Z"),
                                                           self.remoteHabit(UUID().uuidString, name: "X", updatedAt: "yesterday")]) }),
            ("two entries on one day", { h in self.pull(habits: [self.remoteHabit(h, name: "Up", updatedAt: "2099-01-01T00:00:00Z")],
                                                        entries: [self.remoteEntry(UUID().uuidString, habit: h, date: "2026-09-01"),
                                                                  self.remoteEntry(UUID().uuidString, habit: h, date: "2026-09-01")]) }),
        ]
        for (name, make) in cases {
            try tearDownStore()
            let kept = Habit(name: "Old")
            context.insert(kept)
            delivered(kept)
            let gone = Habit(name: "Delivered, absent")
            context.insert(gone)
            delivered(gone)
            try context.save()

            let report = try SyncReconciler.apply(make(kept.id.uuidString), to: context, isFullPull: true)

            XCTAssertEqual(kept.name, "Up", "\(name): the upsert applies")
            XCTAssertTrue(try habits().contains { $0.id == gone.id }, "\(name): nothing may be deleted")
            XCTAssertFalse(report.deletionPassRan, name)
            XCTAssertFalse(report.issues.isEmpty, name)
            XCTAssertNotNil(report.diagnostic, name)
        }
    }

    /// A failed recovery-log append deletes nothing and saves nothing — not even the upserts: the
    /// context rolls back, the error reaches the caller, and the caller writes no cursor.
    func testAFailedRecoveryLogAppendDeletesAndSavesNothing() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        let edited = HabitRecord(date: dayKey(2026, 9, 2))
        habit.records = [edited]
        delivered(habit)
        delivered(edited)
        edited.touch()
        let renamed = Habit(name: "Before")
        context.insert(renamed)
        delivered(renamed)
        try context.save()
        let log = SyncMemoryRecoveryLog()
        log.failure = CocoaError(.fileWriteOutOfSpace)

        XCTAssertThrowsError(try SyncReconciler.apply(
            pull(habits: [remoteHabit(renamed.id.uuidString, name: "After", updatedAt: "2099-01-01T00:00:00Z")],
                 deletedHabits: [habit.id.uuidString]),
            to: context, isFullPull: false, recoveryLog: log)) { error in
            guard case SyncReconcileError.recoveryLogFailed = error else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(try habits().count, 2, "nothing deleted")
        XCTAssertEqual(habit.records.count, 1)
        XCTAssertEqual(renamed.name, "Before", "rolled back: nothing of this pull is saved")
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(log.lines.isEmpty)
    }

    /// The pull saves once, and edits made before it are saved on their own first — a rollback
    /// discards only the pull.
    func testAnUnsavedLocalEditSurvivesARolledBackPull() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        delivered(habit)
        try context.save()
        habit.name = "Edited, unsaved"
        habit.touch()
        let log = SyncMemoryRecoveryLog()
        log.failure = CocoaError(.fileWriteOutOfSpace)

        XCTAssertThrowsError(try SyncReconciler.apply(pull(deletedHabits: [habit.id.uuidString]),
                                                      to: context, isFullPull: false, recoveryLog: log))
        XCTAssertEqual(habit.name, "Edited, unsaved")
    }

    // MARK: - 1.3.1: restored rows (engine-level parts of "Restore")

    /// A row restored with its ids is never deleted by a pull: an incremental tombstone that
    /// arrives before the push holds it `tombstoned` — directly, and through its habit's
    /// cascade — so the restore-as-copies choice is the user's, not a race's.
    func testARestoredRowMetByATombstoneFirstIsHeldNotDeleted() throws {
        let restoredHabit = Habit(name: "Restored habit")
        context.insert(restoredHabit)
        let restoredUnderIt = HabitRecord(date: dayKey(2026, 9, 1))
        restoredHabit.records = [restoredUnderIt]
        let liveHabit = Habit(name: "Live")
        context.insert(liveHabit)
        delivered(liveHabit)
        let restoredRecord = HabitRecord(date: dayKey(2026, 9, 2))
        liveHabit.records = [restoredRecord]
        let restoredGroup = HabitGroup(name: "Restored group")
        context.insert(restoredGroup)
        for row in [restoredUnderIt, restoredRecord, restoredGroup] as [any SyncDeliverable] {
            row.restoredAt = date(early)
        }
        restoredHabit.restoredAt = nil   // only its record was restored: the cascade path
        try context.save()
        let log = SyncMemoryRecoveryLog()

        let report = try SyncReconciler.apply(
            pull(deletedHabits: [restoredHabit.id.uuidString],
                 deletedEntries: [restoredRecord.id.uuidString],
                 deletedGroups: [restoredGroup.id.uuidString]),
            to: context, isFullPull: false, recoveryLog: log)

        XCTAssertEqual(try habits().count, 2)
        XCTAssertEqual(liveHabit.records.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HabitGroup>()).count, 1)
        for row in [restoredHabit, restoredUnderIt, restoredRecord, restoredGroup] as [any SyncDeliverable] {
            XCTAssertEqual(row.activeHold, .tombstoned)
        }
        XCTAssertTrue(log.lines.isEmpty, "nothing was deleted, so nothing is archived")
        XCTAssertEqual(report.heldTombstoned.count, 4)
    }

    /// A restored row the server answered `not_owned` is held, so a full pull that lacks it (it
    /// is another account's) keeps it.
    func testAHeldNotOwnedRestoredRowSurvivesAFullPull() throws {
        let habit = Habit(name: "Another account's")
        context.insert(habit)
        habit.restoredAt = date(early)
        habit.hold(.notOwned)
        try context.save()

        let report = try SyncReconciler.apply(pull(), to: context, isFullPull: true)

        XCTAssertTrue(report.deletionPassRan)
        XCTAssertEqual(try habits().count, 1)
        XCTAssertEqual(habit.activeHold, .notOwned)
    }

    // MARK: - Deletions against day matching (M2 slice review)

    /// Another device untapped a day and tapped it again: one incremental pull carries the
    /// deleted id X AND the new entry Y for the same habit-day. Y used to be matched by day onto
    /// X — the object the deletion then removed — so the device ended with no record for the day
    /// while the server held Y, and nothing pending to repair it before a full pull. Y is
    /// inserted; X goes, archived first because it held an offline edit.
    func testAnIncrementalPullDeletingADayAndAddingItAgainEndsWithTheNewEntry() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        let x = HabitRecord(date: dayKey(2026, 9, 15))
        habit.records.append(x)
        delivered(habit)
        x.note = "offline edit"
        x.touch()   // pending: displaced by the deletion, so it goes to the log
        try context.save()
        let xID = x.id.uuidString
        let yID = UUID().uuidString
        let log = SyncMemoryRecoveryLog()

        let report = try SyncReconciler.apply(
            pull(entries: [remoteEntry(yID, habit: habit.id.uuidString, date: "2026-09-15", note: "again",
                                       updatedAt: late)],
                 deletedEntries: [xID]),
            to: context, isFullPull: false, recoveryLog: log)

        let records = try XCTUnwrap(habits().first).records
        XCTAssertEqual(records.map(\.id.uuidString), [yID])
        XCTAssertEqual(records.first?.note, "again")
        XCTAssertFalse(try XCTUnwrap(records.first).isPending, "applied remote state")
        XCTAssertEqual(report.deleted.entries, 1)
        XCTAssertEqual(log.lines.map(\.item.ref.id), [xID])
    }

    /// Deletions queued here and not yet delivered are authoritative: a pull that runs before the
    /// push carrying them (no cursor, Full resync, snapshot_required) applies no row they name.
    /// Before, the user's re-tap Y of an untapped day was renamed to the deleted X by the day
    /// match, and the push then sent `deletedEntryIds: [X]` with an upsert of X — answered
    /// `tombstoned`, which dropped the re-tap everywhere. A queued habit and group do not come
    /// back either, and none of it counts as an issue that would skip the deletion pass.
    func testAPullAppliesNoRowWhoseDeletionIsQueuedHere() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        let retap = HabitRecord(date: dayKey(2026, 9, 15))
        habit.records.append(retap)
        delivered(habit)
        let stale = Habit(name: "Delivered, then deleted elsewhere")
        context.insert(stale)
        delivered(stale)
        try context.save()
        let retapID = retap.id.uuidString
        let untapped = UUID().uuidString, deletedHabit = UUID().uuidString, deletedGroup = UUID().uuidString

        let report = try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Read"), remoteHabit(deletedHabit, name: "Gone")],
                 entries: [remoteEntry(untapped.lowercased(), habit: habit.id.uuidString, date: "2026-09-15"),
                           remoteEntry(UUID().uuidString, habit: deletedHabit, date: "2026-09-15")],
                 groups: [remoteGroup(deletedGroup, name: "Gone too", updatedAt: late)]),
            to: context, isFullPull: true,
            queuedDeletions: SyncDeletionQueue.Batch(habits: [deletedHabit], entries: [untapped], groups: [deletedGroup]))

        XCTAssertEqual(try habits().map(\.name), ["Read"], "the queued habit is not re-inserted")
        let record = try XCTUnwrap(habits().first?.records.first)
        XCTAssertEqual(record.id.uuidString, retapID, "the re-tap keeps its own id")
        XCTAssertTrue(record.isPending, "and still goes up with the push that deletes the old one")
        XCTAssertTrue(try context.fetch(FetchDescriptor<HabitGroup>()).isEmpty)
        XCTAssertEqual(report.skippedQueuedDeletion, SyncRowCounts(groups: 1, habits: 1, entries: 2))
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.deletionPassRan, "a queued deletion is no reason to skip the pass")
        XCTAssertEqual(report.deleted.habits, 1, "the pass still removed the delivered-but-absent habit")
    }

    private func tearDownStore() throws {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }
}
