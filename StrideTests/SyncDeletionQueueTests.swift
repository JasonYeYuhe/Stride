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

    /// The key older widget and watch builds wrote as a literal. It must stay the same, or ids they
    /// queued before an upgrade are never read and those un-checks never reach the server.
    func testSharedKeyIsUnchangedFromEarlierBuilds() {
        XCTAssertEqual(SyncDeletionQueue.sharedEntriesKey, "stride_deleted_entry_ids_widget")
    }

    /// What the widget and watch now call from their own processes.
    func testEntriesQueuedByAnExtensionAreSentByTheApp() {
        queue.trackSharedEntry("W1")
        XCTAssertEqual(queue.pending().entries, ["W1"])
        XCTAssertNil(local.object(forKey: SyncDeletionQueue.entriesKey), "must not land in the app-only queue")
    }

    // MARK: - The cross-process lock (1.4.0, RELEASE-1.4.0.md D5)

    /// Two queues over the same App Group suite and the same lock file — the app and the widget,
    /// as far as one test process can stand in for two (each `open` of the file is its own lock
    /// owner, exactly as another process's would be).
    private func lockedPair() -> (lock: URL, app: SyncDeletionQueue, widget: SyncDeletionQueue) {
        let lock = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDeletionQueueTests-\(UUID().uuidString).lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: lock) }
        // A second UserDefaults object on the suite, as the widget's own process has. (The widget
        // never writes its local queue; the test's is reused.)
        let widgetShared = UserDefaults(suiteName: sharedSuite)!
        return (lock,
                SyncDeletionQueue(local: local, shared: shared, sharedLock: lock),
                SyncDeletionQueue(local: local, shared: widgetShared, sharedLock: lock))
    }

    /// Many un-checks queued at once from both sides: every one is still there. Unlocked, each
    /// read-modify-write could write back a list read before the other's append.
    func testConcurrentAppendsFromTwoQueuesLoseNothing() {
        let (_, app, widget) = lockedPair()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            (i.isMultiple(of: 2) ? app : widget).trackSharedEntry("W\(i)")
        }
        XCTAssertEqual(Set(app.pending().entries), Set((0..<200).map { "W\($0)" }))
        XCTAssertEqual(app.pending().entries.count, 200, "no duplicates either")
        XCTAssertEqual(Set(widget.pending().entries), Set(app.pending().entries))
    }

    /// The app acknowledging a push while the widget keeps queueing: exactly what was sent goes,
    /// and every id queued meanwhile survives — the race the 1.3.x comment said was only narrowed.
    func testAcknowledgeWhileTheOtherQueueAppendsKeepsEveryNewID() {
        let (_, app, widget) = lockedPair()
        for i in 0..<100 { widget.trackSharedEntry("old\(i)") }
        let sent = app.pending()
        XCTAssertEqual(sent.entries.count, 100)

        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for i in 0..<100 { widget.trackSharedEntry("new\(i)") }
        }
        DispatchQueue.global().async(group: group) {
            app.acknowledge(sent)
        }
        group.wait()

        XCTAssertEqual(Set(app.pending().entries), Set((0..<100).map { "new\($0)" }))
    }

    /// The lock is held only inside the call: afterwards anyone can take it at once.
    func testTheLockIsReleasedAfterEachCall() throws {
        let (lock, app, _) = lockedPair()
        app.trackSharedEntry("W1")
        app.acknowledge(app.pending())
        app.clearAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "the lock file is created on first use")

        let fd = open(lock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "nobody still holds it")
        flock(fd, LOCK_UN)
    }

    /// A queue waits while another holder has the lock, and goes as soon as it is released.
    func testAWriteWaitsForTheHolder() throws {
        let (lock, app, _) = lockedPair()
        let fd = open(lock.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)

        let done = expectation(description: "the append finished")
        DispatchQueue.global().async {
            app.trackSharedEntry("W1")
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNil(shared.stringArray(forKey: SyncDeletionQueue.sharedEntriesKey), "still waiting for the lock")
        flock(fd, LOCK_UN)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(app.pending().entries, ["W1"])
    }

    /// If the lock file cannot be opened the write still happens, unlocked, as before 1.4.0: a
    /// tombstone is never dropped because of a lock.
    func testAnUnusableLockFailsOpen() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/queue.lock")
        let q = SyncDeletionQueue(local: local, shared: shared, sharedLock: nowhere)
        q.trackSharedEntry("W1")
        q.trackSharedEntry("W2")
        q.acknowledge(SyncDeletionQueue.Batch(entries: ["W1"]))
        XCTAssertEqual(q.pending().entries, ["W2"])
    }

    /// The lock file's name is a cross-process contract too: an app and a widget of different builds
    /// must lock the same file. (Not read off `sharedLockURL` here: on a Mac that resolves the real
    /// App Group container, which no test touches.)
    func testTheLockFileNameIsPinned() {
        XCTAssertEqual(SyncDeletionQueue.sharedLockFileName, "stride_deleted_entry_ids_widget.lock")
    }
}
