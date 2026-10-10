import XCTest
import SwiftData
import Foundation

/// Per-owner backoff (`SyncBackoffStore`, Shared/SyncBackoff.swift; DEV-PLAN-1.3.md M2, the
/// answers table: `invalid_payload` → doubling 1 min → 6 h jittered, "Sync Now" retries at once;
/// 429 / 503 → `Retry-After`; other 5xx and no answer → jittered backoff).
///
/// What these pin: the window survives a relaunch (the slice kept it in memory, so a paused
/// server was asked again by every device the user opened); it belongs to one owner, so a
/// sign-in to another account never inherits it; a manual sync always goes; success resets;
/// and a clock set backwards cannot strand automatic syncs. The clock and the random draw are
/// injected, so every number is exact.
@MainActor
final class SyncBackoffTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var draw = 0.5

    /// A store over the test's clock and draw. A fresh value per call, as the app makes one per
    /// use — which is also what a relaunch looks like: nothing survives but the defaults.
    private var store: SyncBackoffStore {
        SyncBackoffStore(defaults: defaults, now: { [unowned self] in self.clock }, unitRandom: { [unowned self] in self.draw })
    }

    override func setUp() {
        super.setUp()
        suiteName = "SyncBackoffTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    private static let invalidPayload = SyncHTTPAnswer(status: 400, code: "invalid_payload")
    private static let serverDown = SyncHTTPAnswer(status: 502)

    // MARK: - The curve, per reason

    /// `invalid_payload`: 1, 2, 4 … minutes, capped at 6 h — the answers table's own words.
    func testInvalidPayloadDoublesFromOneMinuteToSixHours() {
        var delays: [TimeInterval] = []
        for _ in 1...11 {
            delays.append(store.recordFailure(.clientBug, answer: Self.invalidPayload, for: "A").delay)
        }
        XCTAssertEqual(delays, [60, 120, 240, 480, 960, 1_920, 3_840, 7_680, 15_360, 21_600, 21_600])
        let state = store.state(for: "A")
        XCTAssertEqual(state?.consecutiveFailures, 11)
        XCTAssertEqual(state?.reason, .clientBug)
        XCTAssertEqual(state?.retryAt, clock.addingTimeInterval(21_600))
    }

    /// ±20 % jitter from the injected draw, so a fleet that failed on one server restart does
    /// not come back in the same second; never past the 6 h cap.
    func testJitterComesFromTheInjectedDraw() {
        draw = 0
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "lo").delay, 48, accuracy: 1e-9)
        draw = 1
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "hi").delay, 72, accuracy: 1e-9)
        for _ in 1...20 { store.recordFailure(.transient, answer: Self.serverDown, for: "hi") }
        XCTAssertEqual(store.state(for: "hi")?.delay, SyncBackoffPolicy.maximum, "capped even at the top of the jitter")
    }

    /// 429 / 503: the server's `Retry-After` / `retryAfterSeconds` is the window, as given (no
    /// jitter: earlier is refused again), capped at 6 h; without one, the curve.
    func testServerAskedWindowsUseRetryAfter() {
        draw = 0
        let limited = store.recordFailure(.serverAsked(seconds: 42, paused: false),
                                          answer: SyncHTTPAnswer(status: 429, code: "rate_limited", retryAfterSeconds: 42), for: "A")
        XCTAssertEqual(limited.delay, 42)
        XCTAssertEqual(limited.reason, .rateLimited)
        XCTAssertTrue(limited.reason.showsSyncPaused)

        let paused = store.recordFailure(.serverAsked(seconds: 900, paused: true), for: "B")
        XCTAssertEqual(paused.delay, 900)
        XCTAssertEqual(paused.reason, .paused)
        XCTAssertTrue(paused.reason.showsSyncPaused)

        XCTAssertEqual(store.recordFailure(.serverAsked(seconds: 86_400, paused: true), for: "C").delay,
                       SyncBackoffPolicy.maximum, "a day's Retry-After waits at most 6 h")
        draw = 0.5
        XCTAssertEqual(store.recordFailure(.serverAsked(seconds: nil, paused: true), for: "D").delay, 60,
                       "no Retry-After: the curve")
    }

    /// Other 5xx and no HTTP answer both back off; the reason tells the status line ("offline"
    /// vs a count) and the window apart (`testNoAnswerWaitsAboutAMinuteAndNeverDoubles`).
    func testTransientSplitsOfflineFromServerErrors() {
        XCTAssertEqual(store.recordFailure(.transient, answer: .noAnswer, for: "A").reason, .offline)
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "B").reason, .serverError)
        XCTAssertEqual(store.recordFailure(.transient, answer: nil, for: "C").reason, .offline)
        XCTAssertFalse(SyncBackoffReason.offline.showsSyncPaused)
        XCTAssertFalse(SyncBackoffReason.serverError.showsSyncPaused)
        XCTAssertFalse(SyncBackoffReason.clientBug.showsSyncPaused)
    }

    /// Review critic-2: no HTTP answer reached the server, so the window it sets spares nothing.
    /// It is the curve's first step, about a minute, however many launches met no network —
    /// after a day without signal the next launch past that minute syncs (it waited up to 6 h
    /// before). It does not advance the count either, so the first server answer after the
    /// offline stretch starts near the bottom of the curve, not at the 6 h cap.
    func testNoAnswerWaitsAboutAMinuteAndNeverDoubles() {
        for n in 1...10 {
            let state = store.recordFailure(.transient, answer: .noAnswer, for: "A")
            XCTAssertEqual(state.reason, .offline)
            XCTAssertEqual(state.delay, 60, "failure \(n)")
            XCTAssertEqual(state.consecutiveFailures, 1, "failure \(n)")
            XCTAssertFalse(store.mayRun(.automatic, ownerID: "A"))
            advance(state.delay)
            XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"), "the next launch after a minute runs")
        }
        draw = 1
        XCTAssertEqual(store.recordFailure(.transient, answer: .noAnswer, for: "A").delay, 72, accuracy: 1e-9,
                       "jittered like the curve's first step, never past it")

        draw = 0.5
        let serverDown = store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        XCTAssertEqual(serverDown.consecutiveFailures, 2)
        XCTAssertEqual(serverDown.delay, 120, "a real server answer doubles from where the server's episode was")

        // An outage the device also lost its signal in: the server's count is carried through,
        // so its next answer keeps doubling.
        store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        let offline = store.recordFailure(.transient, answer: .noAnswer, for: "A")
        XCTAssertEqual(offline.consecutiveFailures, 3)
        XCTAssertEqual(offline.delay, 60)
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "A").delay, 480)
    }

    /// One failing episode keeps doubling across reasons: a rate limit then an outage does not
    /// restart at a minute, and a server-given window still counts as a failure.
    func testTheCountCarriesAcrossReasons() {
        store.recordFailure(.serverAsked(seconds: 30, paused: false), for: "A")
        store.recordFailure(.serverAsked(seconds: 30, paused: false), for: "A")
        let third = store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        XCTAssertEqual(third.consecutiveFailures, 3)
        XCTAssertEqual(third.delay, 240)
        XCTAssertEqual(third.reason, .serverError)
    }

    // MARK: - Who may run

    /// Automatic waits out the window; manual ("Sync Now") goes at once, whatever the reason.
    func testAutomaticWaitsAndManualAlwaysGoes() {
        let state = store.recordFailure(.clientBug, answer: Self.invalidPayload, for: "A")

        XCTAssertEqual(store.decision(for: .automatic, ownerID: "A"), .wait(state))
        XCTAssertTrue(store.mayRun(.manual, ownerID: "A"))

        advance(59)
        XCTAssertFalse(store.mayRun(.automatic, ownerID: "A"))
        XCTAssertEqual(store.state(for: "A")?.remaining(at: clock) ?? -1, 1, accuracy: 1e-9)
        advance(1)
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"), "the window is half-open: at retryAt it runs")
        XCTAssertEqual(store.state(for: "A")?.remaining(at: clock), 0)

        store.recordFailure(.serverAsked(seconds: 3_600, paused: true), for: "A")
        XCTAssertFalse(store.mayRun(.automatic, ownerID: "A"))
        XCTAssertTrue(store.mayRun(.manual, ownerID: "A"), "even a pause: the user asked")
    }

    /// An owner that never failed has no entry and nothing waits.
    func testNoStateMeansGo() {
        XCTAssertNil(store.state(for: "A"))
        XCTAssertEqual(store.decision(for: .automatic, ownerID: "A"), .go)
        XCTAssertNil(defaults.object(forKey: SyncBackoffStore.key))
    }

    /// A manual run that fails again still counts: the window moves on from its failure.
    func testAFailedManualRunExtendsTheWindow() {
        store.recordFailure(.clientBug, answer: Self.invalidPayload, for: "A")
        advance(10)
        XCTAssertTrue(store.mayRun(.manual, ownerID: "A"))
        let again = store.recordFailure(.clientBug, answer: Self.invalidPayload, for: "A")
        XCTAssertEqual(again.consecutiveFailures, 2)
        XCTAssertEqual(again.retryAt, clock.addingTimeInterval(120))
    }

    // MARK: - Success, persistence, owners

    /// "Success resets": the next failure starts at a minute again, and the key goes away.
    func testSuccessResets() {
        for _ in 1...5 { store.recordFailure(.transient, answer: Self.serverDown, for: "A") }
        store.recordSuccess(for: "A")
        XCTAssertNil(store.state(for: "A"))
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"))
        XCTAssertNil(defaults.object(forKey: SyncBackoffStore.key))
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "A").delay, 60)
    }

    /// The slice's in-memory window was forgotten by a relaunch. A new store over the same
    /// defaults (what a relaunch is) still waits, with the same state.
    func testTheWindowSurvivesARelaunch() {
        let written = store.recordFailure(.serverAsked(seconds: 600, paused: true), for: "A")
        let relaunched = SyncBackoffStore(defaults: UserDefaults(suiteName: suiteName)!, now: { [unowned self] in self.clock })
        XCTAssertEqual(relaunched.state(for: "A"), written)
        XCTAssertFalse(relaunched.mayRun(.automatic, ownerID: "A"))
    }

    /// Account isolation: A's window and count are A's. B, signed in on the same device, runs at
    /// once and starts its own curve at a minute; A's state is untouched by B's success.
    func testAnotherOwnerNeverInheritsIt() {
        for _ in 1...6 { store.recordFailure(.clientBug, answer: Self.invalidPayload, for: "A") }
        let a = store.state(for: "A")

        XCTAssertNil(store.state(for: "B"))
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "B"))
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "B").consecutiveFailures, 1)
        store.recordSuccess(for: "B")
        XCTAssertEqual(store.state(for: "A"), a)

        store.clear(for: "A")
        XCTAssertNil(store.state(for: "A"))
        store.recordFailure(.transient, for: "A")
        store.recordFailure(.transient, for: "B")
        store.clearAll()
        XCTAssertNil(store.state(for: "A"))
        XCTAssertNil(store.state(for: "B"))
        XCTAssertNil(defaults.object(forKey: SyncBackoffStore.key))
    }

    // MARK: - Clocks and bad values

    /// A clock set backwards after a failure must not strand automatic syncs until it catches
    /// up: a `now` before the failure means the clock moved, and the window is over.
    func testAClockSetBackwardsDoesNotStrandSyncs() {
        store.recordFailure(.serverAsked(seconds: 3_600, paused: true), for: "A")
        advance(-86_400)
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"))
        XCTAssertEqual(store.state(for: "A")?.remaining(at: clock), 0)
        // The count is still there: the next failure keeps doubling.
        XCTAssertEqual(store.recordFailure(.transient, answer: Self.serverDown, for: "A").consecutiveFailures, 2)
    }

    /// A clock set forwards just ends the window early — never later than 6 h after the failure.
    func testNoWindowOutlastsSixHoursAfterItsFailure() {
        for _ in 1...40 { store.recordFailure(.clientBug, for: "A") }
        advance(SyncBackoffPolicy.maximum)
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"))
    }

    /// Fail-open: an entry this build cannot read is no backoff, and a stored delay past the cap
    /// (a corrupt value, a future build's policy) waits at most 6 h.
    func testUnreadableOrOutOfRangeEntriesFailOpen() {
        defaults.set(["A": "garbage",
                      "B": ["failures": 2, "reason": "from_the_future", "failedAt": clock.timeIntervalSince1970, "delay": 60.0],
                      "C": ["failures": 3, "reason": "sync_paused", "failedAt": clock.timeIntervalSince1970, "delay": 1e12],
                      "D": ["failures": 0, "reason": "offline", "failedAt": clock.timeIntervalSince1970, "delay": 60.0],
                      "E": ["failures": 1, "reason": "offline", "failedAt": clock.timeIntervalSince1970, "delay": -5.0]],
                     forKey: SyncBackoffStore.key)
        XCTAssertNil(store.state(for: "A"))
        XCTAssertNil(store.state(for: "B"))
        XCTAssertNil(store.state(for: "D"))
        XCTAssertEqual(store.state(for: "C")?.delay, SyncBackoffPolicy.maximum)
        XCTAssertEqual(store.state(for: "E")?.delay, 0)
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"))
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "E"))
        advance(SyncBackoffPolicy.maximum)
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "C"))

        // A write over a corrupt entry replaces it and leaves the others alone.
        XCTAssertEqual(store.recordFailure(.transient, answer: .noAnswer, for: "A").consecutiveFailures, 1)
        XCTAssertEqual(store.state(for: "C")?.reason, .paused)
    }

    /// The stored count stays bounded on a device failing for years.
    func testTheCountIsBounded() {
        defaults.set(["A": ["failures": Int.max, "reason": "offline", "failedAt": clock.timeIntervalSince1970, "delay": 60.0]],
                     forKey: SyncBackoffStore.key)
        XCTAssertEqual(store.state(for: "A")?.consecutiveFailures, SyncBackoffState.countCap)
        let next = store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        XCTAssertEqual(next.consecutiveFailures, SyncBackoffState.countCap)
        XCTAssertEqual(next.delay, SyncBackoffPolicy.maximum)
        let offline = store.recordFailure(.transient, answer: .noAnswer, for: "A")
        XCTAssertEqual(offline.consecutiveFailures, SyncBackoffState.countCap)
        XCTAssertEqual(offline.delay, 60, "no answer waits a minute even at the top of the count")
    }

    // MARK: - Recording run outcomes

    /// `record(_:for:trigger:)` over each outcome: synced resets, a backOff stop counts, and every other
    /// stop — reauth, upgrade, a local failure, a run ended by a sign-out — leaves the state as
    /// it was (none of them is the server asking for less traffic).
    func testRecordingOutcomes() {
        let summary = SyncRunSummary()
        let first = store.record(.stopped(.backOff(.clientBug, answer: Self.invalidPayload), summary),
                                 for: "A", trigger: .automatic)
        XCTAssertEqual(first?.consecutiveFailures, 1)
        XCTAssertEqual(first?.reason, .clientBug)

        for other: SyncRunOutcome in [
            .stopped(.bindingChanged, summary), .stopped(.needsReauth, summary),
            .stopped(.upgradeRequired, summary), .stopped(.recoveryLogFailed, summary),
            .stopped(.localFailure("save"), summary), .blocked(.ownerUnsettled), .blocked(.alreadyRunning),
        ] {
            advance(1)
            XCTAssertEqual(store.record(other, for: "A", trigger: .automatic), first, "\(other)")
        }

        let paused = store.record(.stopped(.backOff(.serverAsked(seconds: 300, paused: true),
                                                    answer: SyncHTTPAnswer(status: 503, code: "sync_paused", retryAfterSeconds: 300)), summary),
                                  for: "A", trigger: .automatic)
        XCTAssertEqual(paused?.consecutiveFailures, 2)
        XCTAssertEqual(paused?.reason, .paused)
        XCTAssertEqual(paused?.delay, 300)

        XCTAssertNil(store.record(.synced(summary), for: "A", trigger: .automatic))
        XCTAssertNil(store.state(for: "A"))
    }

    // MARK: - The background trigger (1.4.0, RELEASE-1.4.0.md D5)

    /// The whole table, so a fourth trigger has to be placed in it on purpose. Before 1.4.0 every
    /// check was `== .automatic`, under which `.background` would have been Sync Now.
    func testTheTriggerTable() {
        XCTAssertTrue(SyncBackoffTrigger.automatic.waitsOutWindow)
        XCTAssertTrue(SyncBackoffTrigger.background.waitsOutWindow)
        XCTAssertFalse(SyncBackoffTrigger.manual.waitsOutWindow)
        XCTAssertTrue(SyncBackoffTrigger.automatic.recordsNoAnswer)
        XCTAssertTrue(SyncBackoffTrigger.manual.recordsNoAnswer)
        XCTAssertFalse(SyncBackoffTrigger.background.recordsNoAnswer)
    }

    /// A background run waits out an open window exactly like a launch — a paused server's above
    /// all, or every refresh and every lock-screen action would ask it again.
    func testBackgroundWaitsOutTheWindowLikeAutomatic() {
        let state = store.recordFailure(.serverAsked(seconds: 600, paused: true), for: "A")

        XCTAssertEqual(store.decision(for: .background, ownerID: "A"), .wait(state))
        XCTAssertFalse(store.mayRun(.background, ownerID: "A"))
        XCTAssertTrue(store.mayRun(.manual, ownerID: "A"))
        advance(600)
        XCTAssertTrue(store.mayRun(.background, ownerID: "A"))
        XCTAssertEqual(store.decision(for: .background, ownerID: "B"), .go, "an owner with no window")
    }

    /// No HTTP answer on a background run — offline, a timeout, or iOS cancelling the refresh as
    /// its time ran out, which APIClient reports the same way — leaves the state exactly as it
    /// was: none stays none, and an earlier window is neither extended nor counted. Recorded, it
    /// would open a minute's window that turns away the foreground sync the user starts next.
    func testABackgroundRunWithNoAnswerLeavesTheStateAsItWas() {
        let summary = SyncRunSummary()
        let offline = SyncRunOutcome.stopped(.backOff(.transient, answer: .noAnswer), summary)

        XCTAssertNil(store.record(offline, for: "A", trigger: .background))
        XCTAssertNil(store.state(for: "A"))
        XCTAssertNil(defaults.object(forKey: SyncBackoffStore.key), "nothing written at all")
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"), "the foreground sync that follows goes")

        // A prior server episode, three failures deep: untouched — not a fourth, not re-timed.
        store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        let prior = store.recordFailure(.transient, answer: Self.serverDown, for: "A")
        XCTAssertEqual(prior.consecutiveFailures, 3)
        advance(30)
        XCTAssertEqual(store.record(offline, for: "A", trigger: .background), prior)
        XCTAssertEqual(store.state(for: "A"), prior)
    }

    /// The same no-answer on a launch or a Sync Now is still recorded (about a minute, uncounted):
    /// only the background trigger skips it.
    func testANoAnswerIsStillRecordedForAutomaticAndManual() {
        let offline = SyncRunOutcome.stopped(.backOff(.transient, answer: .noAnswer), SyncRunSummary())
        for trigger: SyncBackoffTrigger in [.automatic, .manual] {
            store.clearAll()
            let state = store.record(offline, for: "A", trigger: trigger)
            XCTAssertEqual(state?.reason, .offline, "\(trigger)")
            XCTAssertEqual(state?.delay, 60, "\(trigger)")
        }
    }

    /// What the server actually answered still counts on a background run: a 5xx, a 429, the
    /// pause switch and a client bug are recorded and respected (D5), and a success resets.
    func testABackgroundRunStillRecordsEveryRealAnswer() {
        let summary = SyncRunSummary()
        let server = store.record(.stopped(.backOff(.transient, answer: Self.serverDown), summary),
                                  for: "A", trigger: .background)
        XCTAssertEqual(server?.reason, .serverError)
        XCTAssertEqual(server?.consecutiveFailures, 1)

        let limited = store.record(.stopped(.backOff(.serverAsked(seconds: 30, paused: false),
                                                     answer: SyncHTTPAnswer(status: 429, code: "rate_limited")), summary),
                                   for: "A", trigger: .background)
        XCTAssertEqual(limited?.reason, .rateLimited)
        XCTAssertEqual(limited?.consecutiveFailures, 2)
        XCTAssertEqual(limited?.delay, 30)

        let paused = store.record(.stopped(.backOff(.serverAsked(seconds: 300, paused: true),
                                                    answer: SyncHTTPAnswer(status: 503, code: "sync_paused")), summary),
                                  for: "A", trigger: .background)
        XCTAssertEqual(paused?.reason, .paused)
        XCTAssertEqual(paused?.consecutiveFailures, 3)
        XCTAssertFalse(store.mayRun(.background, ownerID: "A"))

        let bug = store.record(.stopped(.backOff(.clientBug, answer: Self.invalidPayload), summary),
                               for: "A", trigger: .background)
        XCTAssertEqual(bug?.reason, .clientBug)
        XCTAssertEqual(bug?.consecutiveFailures, 4)

        XCTAssertNil(store.record(.synced(summary), for: "A", trigger: .background), "success resets")
        XCTAssertNil(store.state(for: "A"))
    }

    // MARK: - Through the real engine

    /// The engine's own stop reasons, from a fake server, land as the table says: 503
    /// `sync_paused` with `retryAfterSeconds` → that window, "sync paused"; a lost network →
    /// offline, about a minute, the count unchanged (review critic-2); `invalid_payload` → client
    /// bug, doubling; the next clean run clears it. Rows stay pending throughout (the engine's
    /// rule; backing off holds nothing).
    func testEngineOutcomesDriveTheState() async throws {
        let server = FakeSyncServer()
        server.validTokens = ["token-A"]
        let device = TestDevice(server: server, owner: "A", token: "token-A", bounds: .standard)
        defer { device.remove() }
        device.habit("Read", records: [Date(timeIntervalSince1970: 1_788_000_000)])
        try device.save()

        let paused = try JSONSerialization.data(withJSONObject: ["error": "sync_paused", "code": "sync_paused", "retryAfterSeconds": 900])
        server.scriptPull(at: 1, SyncTransportResponse(status: 503, body: paused))
        let o1 = await device.sync()
        let s1 = try XCTUnwrap(store.record(o1, for: "A", trigger: .automatic))
        XCTAssertEqual(s1.reason, .paused)
        XCTAssertEqual(s1.delay, 900)
        XCTAssertFalse(store.mayRun(.automatic, ownerID: "A"))

        server.scriptPull(at: 1, .noAnswer)
        let o2 = await device.sync()
        let s2 = try XCTUnwrap(store.record(o2, for: "A", trigger: .automatic))
        XCTAssertEqual(s2.reason, .offline)
        XCTAssertEqual(s2.consecutiveFailures, 1)
        XCTAssertEqual(s2.delay, 60)

        let invalid = try JSONSerialization.data(withJSONObject: ["error": "invalid_payload", "code": "invalid_payload"])
        server.scriptPush(at: 1, SyncTransportResponse(status: 400, body: invalid))
        let o3 = await device.sync()
        let s3 = try XCTUnwrap(store.record(o3, for: "A", trigger: .automatic))
        XCTAssertEqual(s3.reason, .clientBug)
        XCTAssertEqual(s3.consecutiveFailures, 2)
        XCTAssertEqual(s3.delay, 120)
        XCTAssertEqual(try device.pendingCount(), 2, "nothing held, nothing acknowledged")

        let o4 = await device.sync()
        XCTAssertNil(store.record(o4, for: "A", trigger: .automatic))
        XCTAssertTrue(store.mayRun(.automatic, ownerID: "A"))
        XCTAssertEqual(try device.pendingCount(), 0)
    }
}
