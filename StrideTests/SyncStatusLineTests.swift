import XCTest
import SwiftData
import Foundation

/// Today's sync line — `Shared/SyncStatusLine.swift`, the code that ships (DEV-PLAN-1.3.md M2,
/// "Sign-in that stays" and "Sync status where the user works"; acceptance 9 and 10).
///
/// What must hold: nothing while signed out (the store screenshots); the reauth row whenever the
/// last sync was answered 401; a rate limit and the pause switch read "Sync paused" and never
/// anything that looks like an error; and the counts are what the next push would carry, read
/// without planning one.
@MainActor
final class SyncStatusLineTests: XCTestCase {

    private let lastSync = Date(timeIntervalSince1970: 1_790_000_000)

    private func input(
        signedIn: Bool = true, needsReauth: Bool = false, ownerConflict: Bool = false,
        backoff: SyncBackoffReason? = nil, lastSync: Date? = nil, pending: Int = 0, held: Int = 0
    ) -> SyncStatusInput {
        SyncStatusInput(signedIn: signedIn, needsReauth: needsReauth, ownerConflict: ownerConflict,
                        backoff: backoff, lastSync: lastSync, pending: pending, held: held)
    }

    // MARK: - The mapping

    func testSignedOutShowsNothingWhateverTheStoreHolds() {
        for backoff in [nil] + SyncBackoffReason.allCases {
            XCTAssertNil(SyncStatusLine.make(input(signedIn: false, backoff: backoff, lastSync: lastSync, pending: 5, held: 2)),
                         "signed out, backoff \(String(describing: backoff))")
        }
    }

    /// The reauth row is the way back in, so it shows when the session is gone too — and it
    /// outranks everything, a pause included.
    func testNeedsReauthIsTheRowSignedInOrNot() {
        XCTAssertEqual(SyncStatusLine.make(input(needsReauth: true, lastSync: lastSync)), .signInAgain)
        XCTAssertEqual(SyncStatusLine.make(input(signedIn: false, needsReauth: true)), .signInAgain)
        XCTAssertEqual(SyncStatusLine.make(input(needsReauth: true, backoff: .paused, held: 3)), .signInAgain)
    }

    /// Signed into another account with something to lose: the account screen of that sign-in
    /// settles it, and no sync has run, so Today says nothing about sync.
    func testAnOwnerConflictShowsNothing() {
        XCTAssertNil(SyncStatusLine.make(input(ownerConflict: true, backoff: .offline, lastSync: lastSync, pending: 3, held: 1)))
    }

    /// 429 and 503 `sync_paused` are the server asking this device to wait: "Sync paused", with
    /// changes waiting or not, held rows or not — never a count, never an error.
    func testRateLimitAndPauseReadSyncPaused() {
        for reason in SyncBackoffReason.allCases where reason.showsSyncPaused {
            for (pending, held) in [(0, 0), (4, 0), (0, 2), (4, 2)] {
                XCTAssertEqual(SyncStatusLine.make(input(backoff: reason, lastSync: lastSync, pending: pending, held: held)),
                               .paused, "\(reason) pending \(pending) held \(held)")
            }
        }
        XCTAssertEqual(Set(SyncBackoffReason.allCases.filter(\.showsSyncPaused)), [.rateLimited, .paused],
                       "the two answers the spec shows as 'sync paused'")
    }

    func testOfflineWithChangesWaitingCountsThem() {
        XCTAssertEqual(SyncStatusLine.make(input(backoff: .offline, lastSync: lastSync, pending: 3)), .offline(waiting: 3))
        XCTAssertEqual(SyncStatusLine.make(input(backoff: .offline, lastSync: lastSync, pending: 3, held: 2)), .offline(waiting: 3),
                       "the offline count is the more immediate news")
    }

    /// Offline with nothing to send is not news: every change is on the server, and the last
    /// synced time is still true.
    func testOfflineWithNothingWaitingFallsThrough() {
        XCTAssertEqual(SyncStatusLine.make(input(backoff: .offline, lastSync: lastSync)), .synced(lastSync))
        XCTAssertEqual(SyncStatusLine.make(input(backoff: .offline, lastSync: lastSync, held: 2)), .held(2))
        XCTAssertNil(SyncStatusLine.make(input(backoff: .offline)))
    }

    func testServerErrorsAndClientBugsAreACountNotAnError() {
        for reason in [SyncBackoffReason.serverError, .clientBug] {
            XCTAssertEqual(SyncStatusLine.make(input(backoff: reason, lastSync: lastSync, pending: 2)), .waiting(2), "\(reason)")
            XCTAssertEqual(SyncStatusLine.make(input(backoff: reason, lastSync: lastSync)), .synced(lastSync), "\(reason), nothing waiting")
        }
    }

    func testHeldRowsPointAtSettings() {
        XCTAssertEqual(SyncStatusLine.make(input(lastSync: lastSync, held: 2)), .held(2))
        XCTAssertEqual(SyncStatusLine.make(input(held: 1)), .held(1), "held before any sync finished")
    }

    /// Right after an edit rows are pending and no sync has failed: the line stays "Synced …"
    /// rather than flickering a count after every tap.
    func testPendingRowsWithoutAFailureStillReadSynced() {
        XCTAssertEqual(SyncStatusLine.make(input(lastSync: lastSync, pending: 1)), .synced(lastSync))
    }

    func testNeverSyncedShowsNothing() {
        XCTAssertNil(SyncStatusLine.make(input()))
        XCTAssertNil(SyncStatusLine.make(input(pending: 7)))
    }

    /// Every backoff reason maps to something calm: paused, a count, or what the state without
    /// the backoff would show. None of them is "sign in" (only a 401 is).
    func testEveryBackoffReasonHasAMapping() {
        for reason in SyncBackoffReason.allCases {
            let line = SyncStatusLine.make(input(backoff: reason, lastSync: lastSync, pending: 1))
            XCTAssertNotNil(line, "\(reason)")
            XCTAssertNotEqual(line, .signInAgain, "\(reason)")
        }
    }

    // MARK: - The counts

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

    private func dayKey(_ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: 2026, month: 9, day: d))!
    }

    private func habit(_ name: String, records days: [Int] = []) -> Habit {
        let habit = Habit(name: name)
        context.insert(habit)
        habit.records = days.map { HabitRecord(date: dayKey($0)) }
        return habit
    }

    private func acknowledgeEverything() throws {
        for row in try context.fetch(FetchDescriptor<HabitGroup>()) { row.acknowledge(sentStamp: row.stamp) }
        for row in try context.fetch(FetchDescriptor<Habit>()) { row.acknowledge(sentStamp: row.stamp) }
        for row in try context.fetch(FetchDescriptor<HabitRecord>()) { row.acknowledge(sentStamp: row.stamp) }
        try context.save()
    }

    /// What the planner would send, rows and deletions: the count must agree with it.
    private func planned(_ deletions: SyncDeletionQueue.Batch = .init()) throws -> Int {
        let plan = try SyncPushPlanner.plan(in: context, deletions: deletions)
        return plan.rowCount + plan.deletionCount
    }

    func testAFreshStoreCountsEveryRowAndAgreesWithThePlanner() throws {
        context.insert(HabitGroup(name: "Health"))
        _ = habit("Run", records: [1, 2])
        _ = habit("Read", records: [3])
        try context.save()

        let counts = try SyncStatusCounts.read(in: context, deletions: .init())
        XCTAssertEqual(counts, SyncStatusCounts.Counts(pending: 6, held: 0))
        XCTAssertEqual(counts.pending, try planned())
    }

    func testAnAcknowledgedStoreHasNothingPendingAndOneTapIsOne() throws {
        let run = habit("Run", records: [1, 2])
        try context.save()
        try acknowledgeEverything()
        XCTAssertEqual(try SyncStatusCounts.read(in: context, deletions: .init()), SyncStatusCounts.Counts())

        let first = try XCTUnwrap(run.records.first { $0.date == dayKey(1) })
        first.note = "felt good"
        first.touch()
        try context.save()
        XCTAssertEqual(try SyncStatusCounts.read(in: context, deletions: .init()).pending, 1)
        XCTAssertEqual(try planned(), 1)
    }

    func testQueuedDeletionsAreChangesWaiting() throws {
        _ = habit("Run")
        try context.save()
        try acknowledgeEverything()
        let deletions = SyncDeletionQueue.Batch(habits: ["h"], entries: ["e1", "e2"], groups: [])
        XCTAssertEqual(try SyncStatusCounts.read(in: context, deletions: deletions).pending, 3)
        XCTAssertEqual(try planned(deletions), 3)
    }

    /// A held habit counts once, for itself and its check-ins, and the check-ins the planner keeps
    /// back with it are not "waiting" either.
    func testAHeldHabitCountsOnceAndKeepsItsCheckInsOutOfPending() throws {
        let held = habit("Held", records: [1, 2, 3])
        _ = habit("Fine", records: [4])
        try context.save()
        held.hold(.notOwned)
        try context.save()

        let counts = try SyncStatusCounts.read(in: context, deletions: .init())
        XCTAssertEqual(counts, SyncStatusCounts.Counts(pending: 2, held: 1))
        XCTAssertEqual(counts.pending, try planned())
    }

    func testAHeldCheckInIsHeldNotPendingAndAnEditLiftsIt() throws {
        let run = habit("Run", records: [1, 2])
        try context.save()
        try acknowledgeEverything()
        let record = try XCTUnwrap(run.records.first { $0.date == dayKey(1) })
        record.note = "x"
        record.touch()
        record.hold(.rowError)
        try context.save()
        XCTAssertEqual(try SyncStatusCounts.read(in: context, deletions: .init()), SyncStatusCounts.Counts(pending: 0, held: 1))

        record.note = "y"
        record.touch()
        try context.save()
        XCTAssertEqual(try SyncStatusCounts.read(in: context, deletions: .init()), SyncStatusCounts.Counts(pending: 1, held: 0),
                       "an edit lifts the hold by itself: the row is waiting again")
    }

    func testEveryHoldReasonCounts() throws {
        for reason in SyncHoldReason.allCases {
            let group = HabitGroup(name: reason.rawValue)
            context.insert(group)
            group.hold(reason)
        }
        try context.save()
        XCTAssertEqual(try SyncStatusCounts.read(in: context, deletions: .init()).held, SyncHoldReason.allCases.count)
    }
}
