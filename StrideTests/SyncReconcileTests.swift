import XCTest
import SwiftData
import Foundation

/// Tests for the full-pull reconciliation logic used by SyncService.pullRemote().
/// These replicate the algorithm directly against an in-memory SwiftData context
/// to verify correctness without requiring network calls.
@MainActor
final class SyncReconcileTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self])
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

    /// Simulate the entry upsert + reconcile logic from SyncService.pullRemote (full pull path).
    private func simulateFullPullEntryReconcile(
        habits: [Habit],
        remoteEntries: [(id: String, habitId: String, date: String, note: String?)]
    ) throws {
        let remoteEntryIds = Set(remoteEntries.map { $0.id })
        let habitMap = Dictionary(uniqueKeysWithValues: habits.map { ($0.id.uuidString, $0) })

        // Phase 1: upsert remote entries (same logic as SyncService)
        for remote in remoteEntries {
            guard let habit = habitMap[remote.habitId] else { continue }
            guard let entryUUID = UUID(uuidString: remote.id) else { continue }
            guard let entryDate = Self.dateOnly.date(from: remote.date) else { continue }

            if let existingRecord = habit.records.first(where: { Calendar.current.isDate($0.date, inSameDayAs: entryDate) }) {
                // Align local ID to server ID
                existingRecord.id = entryUUID
                existingRecord.note = remote.note
            } else {
                let record = HabitRecord(date: entryDate, note: remote.note)
                record.id = entryUUID
                habit.records.append(record)
            }
        }

        // Phase 2: full-pull reconcile — delete local entries not on server
        for habit in habits {
            for record in habit.records {
                if !remoteEntryIds.contains(record.id.uuidString) {
                    context.delete(record)
                }
            }
        }

        try context.save()
    }

    // MARK: - Tests

    /// Regression: local entry with different ID than server entry for same date
    /// must survive full-pull reconciliation (not be deleted).
    func testFullPullKeepsEntryWhenLocalAndServerIdsDifferForSameDate() throws {
        let habit = Habit(name: "Exercise")
        context.insert(habit)

        let localRecord = HabitRecord(date: Self.dateOnly.date(from: "2025-07-15")!)
        // localRecord gets its own random UUID — different from what server will send
        habit.records.append(localRecord)
        try context.save()

        let serverEntryId = UUID().uuidString
        XCTAssertNotEqual(localRecord.id.uuidString, serverEntryId, "precondition: IDs should differ")

        // Simulate full pull with one entry for same date but different ID
        try simulateFullPullEntryReconcile(
            habits: [habit],
            remoteEntries: [
                (id: serverEntryId, habitId: habit.id.uuidString, date: "2025-07-15", note: "server note")
            ]
        )

        // The entry should survive — not be deleted
        XCTAssertEqual(habit.records.count, 1, "entry should still exist after full-pull reconcile")
        XCTAssertEqual(habit.records.first?.id.uuidString, serverEntryId, "local ID should be aligned to server ID")
        XCTAssertEqual(habit.records.first?.note, "server note", "note should be updated from server")
    }

    /// Full pull should delete local entries that the server doesn't have.
    func testFullPullDeletesOrphanedLocalEntry() throws {
        let habit = Habit(name: "Read")
        context.insert(habit)

        let orphanRecord = HabitRecord(date: Self.dateOnly.date(from: "2025-08-01")!)
        habit.records.append(orphanRecord)
        try context.save()

        // Simulate full pull with NO entries — the local one is orphaned
        try simulateFullPullEntryReconcile(
            habits: [habit],
            remoteEntries: []
        )

        // Re-fetch to get accurate state after delete
        let fetched = try context.fetch(FetchDescriptor<Habit>())
        let fetchedHabit = fetched.first { $0.id == habit.id }!
        XCTAssertEqual(fetchedHabit.records.count, 0, "orphaned entry should be deleted")
    }

    /// Full pull with matching entries should preserve all of them.
    func testFullPullPreservesAllMatchingEntries() throws {
        let habit = Habit(name: "Meditate")
        context.insert(habit)

        // Two local records
        let r1 = HabitRecord(date: Self.dateOnly.date(from: "2025-09-01")!)
        let r2 = HabitRecord(date: Self.dateOnly.date(from: "2025-09-02")!)
        habit.records.append(r1)
        habit.records.append(r2)
        try context.save()

        let serverId1 = UUID().uuidString
        let serverId2 = UUID().uuidString

        try simulateFullPullEntryReconcile(
            habits: [habit],
            remoteEntries: [
                (id: serverId1, habitId: habit.id.uuidString, date: "2025-09-01", note: nil),
                (id: serverId2, habitId: habit.id.uuidString, date: "2025-09-02", note: nil),
            ]
        )

        XCTAssertEqual(habit.records.count, 2, "both entries should survive")
        let ids = Set(habit.records.map { $0.id.uuidString })
        XCTAssertTrue(ids.contains(serverId1))
        XCTAssertTrue(ids.contains(serverId2))
    }

    /// Mixed scenario: one matching entry, one orphan, one new from server.
    func testFullPullMixedScenario() throws {
        let habit = Habit(name: "Journal")
        context.insert(habit)

        // Local: has Sep 1 and Sep 3
        let local1 = HabitRecord(date: Self.dateOnly.date(from: "2025-09-01")!)
        let local3 = HabitRecord(date: Self.dateOnly.date(from: "2025-09-03")!)
        habit.records.append(local1)
        habit.records.append(local3)
        try context.save()

        let serverId1 = UUID().uuidString
        let serverId2 = UUID().uuidString

        // Server: has Sep 1 and Sep 2 (Sep 3 is orphaned, Sep 2 is new)
        try simulateFullPullEntryReconcile(
            habits: [habit],
            remoteEntries: [
                (id: serverId1, habitId: habit.id.uuidString, date: "2025-09-01", note: nil),
                (id: serverId2, habitId: habit.id.uuidString, date: "2025-09-02", note: "new"),
            ]
        )

        // Re-fetch
        let fetched = try context.fetch(FetchDescriptor<Habit>())
        let h = fetched.first { $0.id == habit.id }!

        XCTAssertEqual(h.records.count, 2, "should have Sep 1 (kept) + Sep 2 (new), Sep 3 deleted")

        let dates = Set(h.records.compactMap { Self.dateOnly.string(from: $0.date) })
        XCTAssertTrue(dates.contains("2025-09-01"), "Sep 1 should survive")
        XCTAssertTrue(dates.contains("2025-09-02"), "Sep 2 should be added")
        XCTAssertFalse(dates.contains("2025-09-03"), "Sep 3 should be deleted")
    }
}
