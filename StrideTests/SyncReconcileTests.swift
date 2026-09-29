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

    /// The day match through the per-habit index (large-account performance, M2): the same
    /// answers the record-by-record `isDate(_:inSameDayAs:)` walk gave. A local record stored off
    /// UTC midnight (written before the day-key migration) still matches its UTC day; each habit
    /// matches only its own records; a day with no local record inserts one, attached to its
    /// habit once the pull is applied; and a second entry for one day in the same pull
    /// (`duplicate_day`) lands on the record the first inserted, as it did when records were
    /// appended one at a time — one record for the day, carrying the later entry.
    func testTheDayMatchAlignsAndInsertsPerHabitAndDay() throws {
        let read = Habit(name: "Read"), run = Habit(name: "Run")
        context.insert(read); context.insert(run)
        let offMidnight = HabitRecord(date: dayKey(2026, 9, 15))
        offMidnight.date = dayKey(2026, 9, 15).addingTimeInterval(13 * 3600)   // 13:00 UTC, pre-migration shape
        read.records.append(offMidnight)
        let runDay = HabitRecord(date: dayKey(2026, 9, 15))
        run.records.append(runDay)
        // Edited before the pulled values, so the local-newer guard lets them in.
        for record in [offMidnight, runDay] { record.updatedAt = SyncTimestamp.parse("2025-01-01T00:00:00Z") }
        [read, run].forEach(delivered)
        [offMidnight, runDay].forEach(delivered)
        try context.save()

        let aligned = UUID().uuidString.lowercased(), runAligned = UUID().uuidString
        let fresh = UUID().uuidString, twiceA = UUID().uuidString, twiceB = UUID().uuidString
        let report = try SyncReconciler.apply(pull(entries: [
            remoteEntry(aligned, habit: read.id.uuidString.lowercased(), date: "2026-09-15", note: "read", updatedAt: late),
            remoteEntry(runAligned, habit: run.id.uuidString, date: "2026-09-15", note: "run", updatedAt: late),
            remoteEntry(fresh, habit: read.id.uuidString, date: "2026-09-16", updatedAt: late),
            remoteEntry(twiceA, habit: run.id.uuidString, date: "2026-09-17", note: "first", updatedAt: late),
            remoteEntry(twiceB, habit: run.id.uuidString, date: "2026-09-17", note: "second", updatedAt: late),
        ]), to: context, isFullPull: false)

        XCTAssertEqual(report.applied.entries, 5)
        XCTAssertEqual(report.issues.map(\.reason), [.duplicateDay])
        XCTAssertEqual(offMidnight.id.uuidString, SyncReconciler.canonicalID(aligned))
        XCTAssertEqual(offMidnight.note, "read")
        XCTAssertEqual(runDay.id.uuidString, runAligned)
        XCTAssertEqual(runDay.note, "run")

        let fetched = try habits()
        let readRecords = try XCTUnwrap(fetched.first { $0.id == read.id }).records
        let runRecords = try XCTUnwrap(fetched.first { $0.id == run.id }).records
        XCTAssertEqual(Set(readRecords.map(\.id.uuidString)), [offMidnight.id.uuidString, fresh])
        XCTAssertEqual(runRecords.count, 2, "one record for the 17th, not two")
        let seventeenth = try XCTUnwrap(runRecords.first { $0.id != runDay.id })
        XCTAssertEqual(seventeenth.id.uuidString, twiceB)
        XCTAssertEqual(seventeenth.note, "second")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 4)
        XCTAssertTrue((readRecords + runRecords).allSatisfy { !$0.isPending })
        XCTAssertFalse(context.hasChanges, "saved once")
    }

    /// Review data-safety-3 (the reviewer's S3). This device delivered X (5, edited at T3).
    /// Another device, offline since before T3, took the day to zero — deleting X — and added a
    /// unit back as Y (1, stamped T2 < T3). A full pull carries no tombstones, so the day match
    /// found X, renamed it Y and kept the "newer" 5: not pending, so never pushed, while the
    /// server and the other device held 1 until someone edited that day again. An incremental
    /// pull of the same history deletes X and inserts Y (delete wins), and the full pull now ends
    /// the same. A value edited here since it was delivered is still kept under Y: it is pending,
    /// goes up as Y, and wins by last write.
    func testAFullPullDayMatchGivesADeliveredRecordTheServersValueUnderItsNewID() throws {
        for (editedHere, isFullPull) in [(false, true), (false, false), (true, true)] {
            try tearDownStore()
            let habit = Habit(name: "Water")
            habit.updatedAt = date("2026-01-01T00:00:00.000Z")
            context.insert(habit)
            delivered(habit)
            let x = HabitRecord(date: dayKey(2026, 9, 15), value: 5)
            x.updatedAt = date(late)
            habit.records.append(x)
            delivered(x)
            if editedHere {
                x.value = 6
                x.touch()
            }
            try context.save()
            let xID = x.id.uuidString, yID = UUID().uuidString.lowercased()

            let report = try SyncReconciler.apply(
                pull(habits: [remoteHabit(habit.id.uuidString, name: "Water", updatedAt: "2026-01-01T00:00:00.000Z")],
                     entries: [remoteEntry(yID, habit: habit.id.uuidString, date: "2026-09-15", value: 1, updatedAt: early)],
                     deletedEntries: isFullPull ? nil : [xID]),
                to: context, isFullPull: isFullPull)

            let label = "edited here: \(editedHere), full pull: \(isFullPull)"
            let records = try XCTUnwrap(habits().first, label).records
            XCTAssertEqual(records.count, 1, label)
            let record = try XCTUnwrap(records.first, label)
            XCTAssertEqual(record.id.uuidString, SyncReconciler.canonicalID(yID), label)
            if editedHere {
                XCTAssertEqual(record.value, 6, label)
                XCTAssertTrue(record.isPending, "\(label): goes up as Y")
                XCTAssertEqual(report.keptLocalNewer, [SyncRowRef(kind: .entry, id: record.id.uuidString)], label)
            } else {
                XCTAssertEqual(record.value, 1, "\(label): the server's value, as delete-wins leaves it")
                XCTAssertEqual(record.updatedAt, date(early), label)
                XCTAssertFalse(record.isPending, label)
                XCTAssertTrue(report.keptLocalNewer.isEmpty, label)
            }
        }
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

    // MARK: - The first full pull proves the account (owner decision, 2026-09-28)

    /// A migrated store: two delivered habits with a delivered check-in each, a delivered group,
    /// and a pending habit made after the last 1.3.0 sync. Returns them for the assertions.
    private func seedMarkedStore() throws -> (read: Habit, run: Habit, group: HabitGroup, fresh: Habit) {
        let group = HabitGroup(name: "Morning")
        context.insert(group)
        delivered(group)
        let read = Habit(name: "Read"), run = Habit(name: "Run"), fresh = Habit(name: "Made after")
        for h in [read, run, fresh] { context.insert(h) }
        read.records.append(HabitRecord(date: dayKey(2026, 9, 1)))
        run.records.append(HabitRecord(date: dayKey(2026, 9, 2)))
        for h in [read, run] {
            delivered(h)
            h.records.forEach(delivered)
        }
        try context.save()
        return (read, run, group, fresh)
    }

    private func marksCount() throws -> Int {
        try habits().filter(\.hasBeenDelivered).count
            + context.fetch(FetchDescriptor<HabitRecord>()).filter(\.hasBeenDelivered).count
            + context.fetch(FetchDescriptor<HabitGroup>()).filter(\.hasBeenDelivered).count
    }

    /// The proving snapshot of the marks' own account: it holds Read and its check-in, and lacks
    /// Run, Run's check-in and the group, which this device holds as delivered.
    private func provingSnapshot(_ read: Habit) throws -> SyncPullResponse {
        let readRecord = try XCTUnwrap(read.records.first)
        return pull(habits: [remoteHabit(read.id.uuidString.lowercased(), name: "Read")],
                    entries: [remoteEntry(readRecord.id.uuidString, habit: read.id.uuidString, date: "2026-09-01")])
    }

    /// Review data-safety-1. The same account: its snapshot holds a habit this device delivered,
    /// so the marks stand, and the account listed what it deleted since the store's last 1.3.0
    /// pull: Run and the group (Run's check-in through its habit — the deleting device queued only
    /// the habit's id). They go by the normal rule, as an incremental pull from that cursor would
    /// have removed them: quietly, since nobody edited them here. A check-in of a habit this device
    /// keeps (edited after the last 1.3.0 sync, so never delivered) goes with its habit's listed
    /// id too; the habit itself waits for the push's `tombstoned`, which archives its edit.
    func testAnUnverifiedPassDeletesWhatTheAccountListsAsDeletedQuietly() throws {
        let (read, run, group, fresh) = try seedMarkedStore()
        let freshRecord = HabitRecord(date: dayKey(2026, 9, 3))
        fresh.records.append(freshRecord)
        delivered(freshRecord)
        try context.save()
        let log = SyncMemoryRecoveryLog()
        let listed = SyncDeletedIDs(habits: [run.id.uuidString, fresh.id.uuidString], groups: [group.id.uuidString])

        let report = try SyncReconciler.apply(try provingSnapshot(read), to: context, isFullPull: true, proveMarks: true,
                                              unverifiedPass: .deletionsListed(listed), recoveryLog: log)

        XCTAssertEqual(report.marks, .proven(SyncRowRef(kind: .habit, id: read.id.uuidString)))
        XCTAssertEqual(report.unverifiedPass, .deletionsListed)
        XCTAssertEqual(report.deleted, SyncRowCounts(groups: 1, habits: 1, entries: 2))
        XCTAssertEqual(report.markedForResend, SyncRowCounts())
        XCTAssertEqual(Set(try habits().map(\.name)), ["Read", "Made after"])
        XCTAssertTrue(fresh.records.isEmpty, "its delivered check-in went with the habit's listed id")
        XCTAssertTrue(fresh.isPending, "never delivered: the push's answer decides it")
        XCTAssertTrue(try context.fetch(FetchDescriptor<HabitGroup>()).isEmpty)
        XCTAssertTrue(log.lines.isEmpty, "nobody edited them here: nothing to recover")
        XCTAssertFalse(context.hasChanges, "saved")
    }

    /// Review data-safety-1. What the snapshot lacks and the account's complete list of deletions
    /// since the last 1.3.0 pull does not name was never the account's to delete: a row the 1.3.0
    /// server refused (another account's ids, or ids this account deleted before a restore). It is
    /// kept and resent as the restore it was — `needsResend` and `restoredAt`, a check-in and a
    /// group too — for the push's answer to decide. The mark stays. Should a full pull meet it
    /// before that push, it is held `tombstoned` as a restored row is, never deleted.
    func testAnUnverifiedPassResendsAsARestoreWhatACompleteListDoesNotName() throws {
        let (read, run, group, fresh) = try seedMarkedStore()
        let runRecord = try XCTUnwrap(run.records.first)
        let snapshot = try provingSnapshot(read)
        let log = SyncMemoryRecoveryLog()
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let report = try SyncReconciler.apply(snapshot, to: context, isFullPull: true, proveMarks: true,
                                              unverifiedPass: .deletionsListed(SyncDeletedIDs()),
                                              recoveryLog: log, now: now)

        XCTAssertEqual(report.unverifiedPass, .deletionsListed)
        XCTAssertTrue(report.deletionPassRan)
        XCTAssertEqual(report.deleted, SyncRowCounts())
        XCTAssertEqual(report.markedForResend, SyncRowCounts(groups: 1, habits: 1, entries: 1))
        XCTAssertEqual(Set(try habits().map(\.name)), ["Read", "Run", "Made after"])
        for row in [run, runRecord, group] as [any SyncDeliverable] {
            XCTAssertTrue(row.needsResend)
            XCTAssertEqual(row.restoredAt, now, "a restore: a tombstone holds it, it is never dropped")
            XCTAssertTrue(row.isPending)
            XCTAssertNotNil(row.syncedAt, "the mark stays: evidence of delivery, as far as this device knows")
        }
        XCTAssertFalse(read.isPending)
        XCTAssertTrue(fresh.isPending)
        XCTAssertTrue(log.lines.isEmpty, "nothing was deleted")
        XCTAssertFalse(context.hasChanges, "saved")

        // Verified (the engine clears the flag once that pass has run), a full pull before the
        // resend holds them `tombstoned`, as any restored row: the user's choice, not a deletion.
        let verified = try SyncReconciler.apply(snapshot, to: context, isFullPull: true, recoveryLog: log)
        XCTAssertNil(verified.unverifiedPass)
        XCTAssertEqual(verified.deleted, SyncRowCounts())
        XCTAssertEqual(Set(verified.heldTombstoned.map(\.id)), [run.id.uuidString, runRecord.id.uuidString, group.id.uuidString])
        XCTAssertEqual(run.activeHold, .tombstoned)
        XCTAssertTrue(log.lines.isEmpty)
    }

    /// Review data-safety-1. With no list — no pinned cursor, one past the server's horizon, or a
    /// server that does not answer — a deletion made elsewhere and a row the 1.3.0 server refused
    /// look the same. Each is deleted, as a verified pass would, but archived first whatever its
    /// state: the habit, its check-in and the group, none of them pending. Nothing is lost, and
    /// nothing is resent into an account that may have swept the tombstone that would answer it.
    func testAnUnverifiedPassWithNoListDeletesAndArchivesEveryRowItDeletes() throws {
        let (read, run, group, fresh) = try seedMarkedStore()
        let runRecord = try XCTUnwrap(run.records.first)
        let log = SyncMemoryRecoveryLog()

        let report = try SyncReconciler.apply(try provingSnapshot(read), to: context, isFullPull: true, proveMarks: true,
                                              unverifiedPass: .deletionsUnknown, recoveryLog: log)

        XCTAssertEqual(report.unverifiedPass, .deletionsUnknown)
        XCTAssertEqual(report.deleted, SyncRowCounts(groups: 1, habits: 1, entries: 1))
        XCTAssertEqual(report.markedForResend, SyncRowCounts())
        XCTAssertEqual(report.archived, 3)
        XCTAssertEqual(Set(try habits().map(\.name)), ["Read", "Made after"])
        XCTAssertTrue(fresh.isPending, "never delivered: kept")
        XCTAssertEqual(Set(log.lines.map(\.item.ref)), [SyncRowRef(kind: .habit, id: run.id.uuidString),
                                                        SyncRowRef(kind: .entry, id: runRecord.id.uuidString),
                                                        SyncRowRef(kind: .group, id: group.id.uuidString)])
        XCTAssertTrue(log.lines.allSatisfy { $0.item.reason == .deletedElsewhere })
    }

    /// The same absence with verified marks: deleted, and only what is pending or held archived.
    func testAVerifiedPassDeletesWhatTheAccountLacksArchivingOnlyEdits() throws {
        let (read, run, _, _) = try seedMarkedStore()
        let log = SyncMemoryRecoveryLog()
        let report = try SyncReconciler.apply(try provingSnapshot(read), to: context, isFullPull: true, recoveryLog: log)
        XCTAssertNil(report.unverifiedPass)
        XCTAssertEqual(report.deleted, SyncRowCounts(groups: 1, habits: 1, entries: 1))
        XCTAssertFalse(try habits().contains { $0.id == run.id })
        XCTAssertTrue(log.lines.isEmpty, "delivered and unedited")
    }

    /// An incremental pull runs no absence pass, so unverified marks change nothing there.
    func testUnverifiedMarksMarkNothingOnAnIncrementalPull() throws {
        let (_, run, _, _) = try seedMarkedStore()
        for pass in [SyncUnverifiedPass.deletionsListed(SyncDeletedIDs()), .deletionsUnknown] {
            let report = try SyncReconciler.apply(pull(), to: context, isFullPull: false, unverifiedPass: pass)
            XCTAssertEqual(report.markedForResend, SyncRowCounts())
            XCTAssertNil(report.unverifiedPass)
            XCTAssertEqual(report.deleted, SyncRowCounts())
            XCTAssertFalse(run.needsResend)
            XCTAssertFalse(run.isPending)
        }
    }

    /// Another account: its snapshot holds none of this device's rows. Every mark is forgotten
    /// BEFORE the deletion pass, so the pass deletes nothing and every row is pending — uploaded
    /// once, or answered `not_owned` (held) / `tombstoned` (dropped, archived). The account's
    /// own rows arrive as usual.
    func testAProvingFullPullWithNoneOfTheRowsForgetsEveryMarkAndDeletesNothing() throws {
        let (read, run, group, fresh) = try seedMarkedStore()
        let theirs = UUID().uuidString

        let report = try SyncReconciler.apply(pull(habits: [remoteHabit(theirs, name: "Theirs")]),
                                              to: context, isFullPull: true, proveMarks: true)

        XCTAssertEqual(report.marks, .forgotten(.init(habits: 2, records: 2, groups: 1)))
        XCTAssertTrue(report.deletionPassRan)
        XCTAssertEqual(report.deleted, SyncRowCounts())
        XCTAssertEqual(Set(try habits().map(\.name)), ["Read", "Run", "Made after", "Theirs"])
        let rows: [any SyncDeliverable] = [read, run, fresh, group] + (read.records + run.records).map { $0 }
        for row in rows {
            XCTAssertTrue(row.isPending)
            XCTAssertNil(row.syncedAt)
        }
        XCTAssertEqual(try marksCount(), 1, "only the pulled habit is delivered")
    }

    /// A store holding only groups (every habit deleted) is proven by a group; one whose every
    /// habit was edited after the last 1.3.0 sync (a reorder touches every active habit) but
    /// whose history was not, by a check-in. Ids of all three kinds are global on the server.
    func testAGroupOrACheckInProvesTheAccountWhenNoDeliveredHabitDoes() throws {
        let group = HabitGroup(name: "Only groups left")
        context.insert(group)
        delivered(group)
        try context.save()
        var report = try SyncReconciler.apply(
            pull(groups: [remoteGroup(group.id.uuidString, name: "Only groups left", updatedAt: late)]),
            to: context, isFullPull: true, proveMarks: true)
        XCTAssertEqual(report.marks, .proven(SyncRowRef(kind: .group, id: group.id.uuidString)))

        try tearDownStore()
        let habit = Habit(name: "Reordered")
        context.insert(habit)
        let record = HabitRecord(date: dayKey(2026, 9, 1))
        habit.records.append(record)
        delivered(record)
        let gone = Habit(name: "Deleted elsewhere")
        context.insert(gone)
        gone.records.append(HabitRecord(date: dayKey(2026, 9, 1)))
        delivered(gone)
        gone.records.forEach(delivered)
        try context.save()
        XCTAssertFalse(habit.hasBeenDelivered, "precondition: its edit came after the last sync")

        report = try SyncReconciler.apply(
            pull(habits: [remoteHabit(habit.id.uuidString, name: "Reordered")],
                 entries: [remoteEntry(record.id.uuidString, habit: habit.id.uuidString, date: "2026-09-01")]),
            to: context, isFullPull: true, proveMarks: true)
        XCTAssertEqual(report.marks, .proven(SyncRowRef(kind: .entry, id: record.id.uuidString)))
        XCTAssertEqual(try habits().map(\.name), ["Reordered"], "the marks stood, so the habit the account lacks goes")
    }

    /// A snapshot whose totals do not match its arrays cannot show an account lacks a row (a
    /// truncated body may have cut the one that proves it): undecided — no mark forgotten,
    /// nothing applied or deleted (review data-safety-2), and the next full pull decides. One
    /// that proves despite the mismatch still proves: the id is in the account whatever else is
    /// wrong.
    func testAnInvalidSnapshotDecidesOnlyIfItProves() throws {
        let (read, _, _, _) = try seedMarkedStore()
        let before = try marksCount()

        var report = try SyncReconciler.apply(pull(habits: [], totals: .some(SyncTotals(habits: 5, entries: 0, groups: 0))),
                                              to: context, isFullPull: true, proveMarks: true)
        XCTAssertEqual(report.marks, .undecided)
        XCTAssertFalse(report.deletionPassRan)
        XCTAssertEqual(try marksCount(), before)
        XCTAssertEqual(try habits().count, 3)

        report = try SyncReconciler.apply(
            pull(habits: [remoteHabit(read.id.uuidString, name: "Read")],
                 totals: .some(SyncTotals(habits: 5, entries: 0, groups: 0))),
            to: context, isFullPull: true, proveMarks: true)
        XCTAssertEqual(report.marks, .proven(SyncRowRef(kind: .habit, id: read.id.uuidString)))
        XCTAssertFalse(report.deletionPassRan)
        XCTAssertEqual(try habits().count, 3)
    }

    /// Review data-safety-2. A snapshot whose totals match its arrays holds every id the account
    /// has, whatever else is wrong with it, and every id this device delivered is a UUID: a
    /// row-level issue (here an id that is not a UUID) no longer leaves the proof undecided. It
    /// decides — forgotten here, as the account holds none of the rows — and the issue still skips
    /// the deletion pass.
    func testMatchingTotalsDecideTheProofDespiteARowLevelIssue() throws {
        let (read, run, group, fresh) = try seedMarkedStore()

        let report = try SyncReconciler.apply(
            pull(habits: [remoteHabit(UUID().uuidString, name: "Theirs"), remoteHabit("not-a-uuid", name: "Bad")]),
            to: context, isFullPull: true, proveMarks: true)

        XCTAssertEqual(report.marks, .forgotten(.init(habits: 2, records: 2, groups: 1)))
        XCTAssertEqual(report.issues.map(\.reason), [.invalidID])
        XCTAssertFalse(report.deletionPassRan)
        XCTAssertEqual(Set(try habits().map(\.name)), ["Read", "Run", "Made after", "Theirs"])
        let rows: [any SyncDeliverable] = [read, run, fresh, group] + (read.records + run.records).map { $0 }
        XCTAssertTrue(rows.allSatisfy { $0.syncedAt == nil && $0.isPending })
    }

    /// Review data-safety-2. A proving pull whose totals do not match its arrays (a truncated
    /// body) cannot decide — the rows it lacks may include the one that proves — and it now
    /// applies nothing either: its upserts marked what they inserted delivered, and the next
    /// proving pull found that and took it for proof.
    func testAnUndecidedProvingPullAppliesNothing() throws {
        _ = try seedMarkedStore()
        let before = try marksCount()

        let report = try SyncReconciler.apply(
            pull(habits: [remoteHabit(UUID().uuidString, name: "Theirs")],
                 totals: .some(SyncTotals(habits: 2, entries: 0, groups: 0))),
            to: context, isFullPull: true, proveMarks: true)

        XCTAssertEqual(report.marks, .undecided)
        XCTAssertEqual(report.issues.map(\.reason), [.totalsMismatch])
        XCTAssertEqual(report.applied, SyncRowCounts())
        XCTAssertTrue(report.deletionPassSkipped)
        XCTAssertNotNil(report.diagnostic)
        XCTAssertEqual(Set(try habits().map(\.name)), ["Read", "Run", "Made after"], "nothing inserted")
        XCTAssertEqual(try marksCount(), before)
        XCTAssertFalse(context.hasChanges)
    }

    /// Only a full pull asked to proves: an incremental pull shows what changed, not what the
    /// account lacks, and a store with proven marks is never asked.
    func testOnlyAFullPullAskedToProveDecidesTheMarks() throws {
        _ = try seedMarkedStore()
        let before = try marksCount()
        var report = try SyncReconciler.apply(pull(), to: context, isFullPull: false, proveMarks: true)
        XCTAssertNil(report.marks)
        XCTAssertEqual(try marksCount(), before)

        report = try SyncReconciler.apply(pull(habits: [remoteHabit(UUID().uuidString, name: "Theirs")]),
                                          to: context, isFullPull: true)
        XCTAssertNil(report.marks)
        XCTAssertEqual(report.deleted.habits, 2, "proven marks delete as ever")
    }

    private func tearDownStore() throws {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }
}
