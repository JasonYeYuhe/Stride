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

    private func pull(habits: [SyncHabit] = [], entries: [SyncEntry] = [], groups: [SyncGroup]? = nil,
                      deletedHabits: [String]? = nil, deletedEntries: [String]? = nil,
                      deletedGroups: [String]? = nil) -> SyncPullResponse {
        SyncPullResponse(habits: habits, entries: entries, groups: groups,
                         deletedHabitIds: deletedHabits, deletedEntryIds: deletedEntries,
                         deletedGroupIds: deletedGroups, serverTime: "2025-01-01T00:00:00Z")
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

    /// Full pull deletes local entries the server doesn't have.
    func testFullPullDeletesOrphanedLocalEntry() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)
        habit.records.append(HabitRecord(date: dayKey(2025, 8, 1)))
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
        habit.records.append(HabitRecord(date: dayKey(2025, 9, 3)))
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

        let remote = SyncGroup(id: lower, name: "Health", colorHex: "#FF0000", sortOrder: 1,
                               createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-02-01T00:00:00Z")
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
}
