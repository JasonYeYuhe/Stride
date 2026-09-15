import XCTest
import Foundation

/// Tests for `SyncDeletionQueue`. The bug these pin: deletion ids were removed before the push,
/// so any push that failed lost them permanently and the deleted habit reappeared everywhere.
final class SyncDeletionQueueTests: XCTestCase {

    private var localSuite = ""
    private var sharedSuite = ""
    private var local: UserDefaults!
    private var shared: UserDefaults!

    private var queue: SyncDeletionQueue { SyncDeletionQueue(local: local, shared: shared) }

    override func setUp() {
        super.setUp()
        localSuite = "stride.tests.deletions.local.\(UUID().uuidString)"
        sharedSuite = "stride.tests.deletions.shared.\(UUID().uuidString)"
        local = UserDefaults(suiteName: localSuite)
        shared = UserDefaults(suiteName: sharedSuite)
    }

    override func tearDown() {
        local.removePersistentDomain(forName: localSuite)
        shared.removePersistentDomain(forName: sharedSuite)
        local = nil
        shared = nil
        super.tearDown()
    }

    /// Reading must not remove: a push that throws has to find the same ids on the retry.
    func testPendingDoesNotConsume() {
        queue.trackHabit("H1")
        queue.trackEntry("E1")
        queue.trackGroup("G1")

        let firstAttempt = queue.pending()
        let retry = queue.pending()

        XCTAssertEqual(firstAttempt, retry)
        XCTAssertEqual(retry, SyncDeletionQueue.Batch(habits: ["H1"], entries: ["E1"], groups: ["G1"]))
    }

    /// Acknowledging removes what was sent and keeps anything queued while the push was in flight.
    func testAcknowledgeRemovesExactlyWhatWasSent() {
        queue.trackHabit("H1")
        queue.trackEntry("E1")
        let sent = queue.pending()

        queue.trackHabit("H2")
        queue.trackEntry("E2")
        queue.trackGroup("G2")
        queue.acknowledge(sent)

        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch(habits: ["H2"], entries: ["E2"], groups: ["G2"]))
    }

    /// Entries un-checked from the widget or watch are sent too, and trimmed the same careful way.
    func testWidgetEntriesAreSentAndTrimmed() {
        shared.set(["W1", "W2"], forKey: SyncDeletionQueue.sharedEntriesKey)
        queue.trackEntry("E1")

        let sent = queue.pending()
        XCTAssertEqual(Set(sent.entries), ["E1", "W1", "W2"])

        // The widget writes again while the push is in flight.
        shared.set(["W1", "W2", "W3"], forKey: SyncDeletionQueue.sharedEntriesKey)
        queue.acknowledge(sent)

        XCTAssertEqual(queue.pending().entries, ["W3"])
    }

    func testFullyAcknowledgedQueueIsEmpty() {
        queue.trackHabit("H1")
        queue.trackEntry("E1")
        queue.trackGroup("G1")
        shared.set(["W1"], forKey: SyncDeletionQueue.sharedEntriesKey)

        queue.acknowledge(queue.pending())

        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch())
        XCTAssertNil(local.object(forKey: SyncDeletionQueue.habitsKey))
        XCTAssertNil(shared.object(forKey: SyncDeletionQueue.sharedEntriesKey))
    }

    /// The widget and watch still write this key as a string literal in their own processes.
    /// If the two drift apart, un-checking from the widget silently stops reaching the server.
    func testSharedKeyMatchesTheLiteralTheWidgetAndWatchWrite() {
        XCTAssertEqual(SyncDeletionQueue.sharedEntriesKey, "stride_deleted_entry_ids_widget")
    }
}
