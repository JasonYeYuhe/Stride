import XCTest
import SwiftData
import Foundation

/// The per-answer rules (DEV-PLAN-1.3.md M2, "One rule per push answer"; Tests → *Answers*),
/// table-driven over the real `SyncAnswers` in Shared/, and then through `SyncPushResolver`
/// against an in-memory store, so "held", "dropped" and "pending" are checked on actual rows.
///
/// The rule that replaced bisection: the server answers a bad row with 200 and a reason, so a
/// 400 is never about a row — splitting it down to single rows would only quarantine good data.
@MainActor
final class SyncAnswersTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    var defaults: UserDefaults!
    private var suiteName = ""

    var queue: SyncDeletionQueue { SyncDeletionQueue(local: defaults, shared: nil) }
    var strikes: SyncUnknownHabitStrikes { SyncUnknownHabitStrikes(defaults: defaults) }

    override func setUp() {
        super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        suiteName = "SyncAnswersTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Row level, pure

    func testEverySkipReasonMapsAsTheTableSays() {
        struct Row { let reason: String?; let skipped: Bool; let restored: Bool; let expected: SyncRowAction; let line: UInt }
        let table: [Row] = [
            Row(reason: nil, skipped: false, restored: false, expected: .acknowledge, line: #line),
            Row(reason: nil, skipped: false, restored: true, expected: .acknowledge, line: #line),
            Row(reason: "tombstoned", skipped: true, restored: false, expected: .drop, line: #line),
            Row(reason: "tombstoned_habit", skipped: true, restored: false, expected: .drop, line: #line),
            Row(reason: "tombstoned", skipped: true, restored: true, expected: .hold(.tombstoned), line: #line),
            Row(reason: "tombstoned_habit", skipped: true, restored: true, expected: .hold(.tombstoned), line: #line),
            Row(reason: "missing_field", skipped: true, restored: false, expected: .hold(.missingField), line: #line),
            Row(reason: "row_error", skipped: true, restored: false, expected: .hold(.rowError), line: #line),
            Row(reason: "invalid_value", skipped: true, restored: false, expected: .hold(.invalidValue), line: #line),
            Row(reason: "invalid_value", skipped: true, restored: true, expected: .hold(.invalidValue), line: #line),
            Row(reason: "unknown_habit", skipped: true, restored: false, expected: .keepPending, line: #line),
            Row(reason: "skipped_habit", skipped: true, restored: false, expected: .keepPending, line: #line),
            Row(reason: "not_owned", skipped: true, restored: false, expected: .hold(.notOwned), line: #line),
            Row(reason: "not_owned_habit", skipped: true, restored: false, expected: .hold(.notOwned), line: #line),
            Row(reason: "not_owned", skipped: true, restored: true, expected: .hold(.notOwned), line: #line),
            // Skipped with no reason, or a code this build does not know: never acknowledged,
            // never held on a guess — sent again.
            Row(reason: nil, skipped: true, restored: false, expected: .keepPending, line: #line),
            Row(reason: "some_future_code", skipped: true, restored: false, expected: .keepPending, line: #line),
        ]
        for row in table {
            XCTAssertEqual(SyncAnswers.rowAction(skipped: row.skipped, reason: row.reason,
                                                 facts: SyncRowFacts(isRestored: row.restored)),
                           row.expected, "\(row.reason ?? "nil")", line: row.line)
        }
        // Every server reason is in the table.
        let covered = Set(table.compactMap(\.reason))
        for reason in SyncSkipReason.allCases { XCTAssertTrue(covered.contains(reason.rawValue), reason.rawValue) }
    }

    /// Review delivery-1: a check-in made after a restore has no `restoredAt` of its own, but its
    /// habit is kept for the restore-as-copies choice. `tombstoned_habit` keeps it pending (it
    /// moves with the habit, or goes with it on Discard) instead of dropping it. Its own
    /// `tombstoned` still drops it: the check-in itself was deleted elsewhere.
    func testATombstonedHabitsAnswerKeepsACheckInWhoseHabitIsKeptForRestore() {
        let kept = SyncRowFacts(habitKeptForRestore: true)
        XCTAssertEqual(SyncAnswers.rowAction(skipped: true, reason: "tombstoned_habit", facts: kept), .keepPending)
        XCTAssertEqual(SyncAnswers.rowAction(skipped: true, reason: "tombstoned", facts: kept), .drop)
        XCTAssertEqual(SyncAnswers.rowAction(skipped: true, reason: "tombstoned_habit",
                                             facts: SyncRowFacts(isRestored: true, habitKeptForRestore: true)),
                       .hold(.tombstoned), "a restored check-in is still held")
        XCTAssertEqual(SyncAnswers.rowAction(skipped: true, reason: "tombstoned_habit", facts: SyncRowFacts()), .drop,
                       "a habit nobody restored: delete wins")
    }

    /// "An entry still `unknown_habit` three syncs after its habit was acknowledged is held."
    /// Before the habit is acknowledged, no strike counts: the habit's chunk may not have landed.
    func testUnknownHabitIsHeldOnTheThirdStrikeAfterItsHabitWasAcknowledged() {
        func action(ack: Bool, prior: Int) -> SyncRowAction {
            SyncAnswers.rowAction(skipped: true, reason: "unknown_habit",
                                  facts: SyncRowFacts(habitAcknowledged: ack, priorUnknownHabitStrikes: prior))
        }
        XCTAssertEqual(action(ack: true, prior: 0), .keepPending)
        XCTAssertEqual(action(ack: true, prior: 1), .keepPending)
        XCTAssertEqual(action(ack: true, prior: 2), .hold(.unknownHabit))
        XCTAssertEqual(action(ack: false, prior: 5), .keepPending)
        XCTAssertTrue(SyncAnswers.countsUnknownHabitStrike(reason: "unknown_habit", facts: SyncRowFacts(habitAcknowledged: true)))
        XCTAssertFalse(SyncAnswers.countsUnknownHabitStrike(reason: "unknown_habit", facts: SyncRowFacts(habitAcknowledged: false)))
        XCTAssertFalse(SyncAnswers.countsUnknownHabitStrike(reason: "skipped_habit", facts: SyncRowFacts(habitAcknowledged: true)))
    }

    // MARK: - Request level, pure

    func testTheRequestLevelTable() {
        let limits = SyncRowLimits(habits: 500, entries: 5_000, groups: 200)
        let multi = SyncChunkShape(items: 40, rows: 38)
        let single = SyncChunkShape(items: 1, rows: 1)
        let loneDeletion = SyncChunkShape(items: 1, rows: 0)
        let spent = SyncRunAttempts(rechunkedForRows: true, halvedBytes: true)

        struct Case {
            let answer: SyncHTTPAnswer
            var endpoint: SyncEndpoint = .push
            var chunk: SyncChunkShape? = nil
            var attempts = SyncRunAttempts()
            let expected: SyncAnswerAction
            let line: UInt
        }
        let table: [Case] = [
            Case(answer: .init(status: 200, ok: true), chunk: multi, expected: .proceed, line: #line),
            Case(answer: .init(status: 200), chunk: multi, expected: .proceed, line: #line),
            Case(answer: .init(status: 200, ok: false), chunk: multi, expected: .backOff(.transient), line: #line),
            Case(answer: .init(status: 200), endpoint: .pull, expected: .proceed, line: #line),
            // 400s are envelope errors, never a row's.
            Case(answer: .init(status: 400, code: "too_many_rows", limits: limits), chunk: multi,
                 expected: .rechunk(limits), line: #line),
            Case(answer: .init(status: 400, code: "too_many_rows", limits: limits), chunk: multi,
                 attempts: spent, expected: .backOff(.clientBug), line: #line),
            Case(answer: .init(status: 400, code: "invalid_payload"), chunk: multi, expected: .backOff(.clientBug), line: #line),
            Case(answer: .init(status: 400, code: "invalid_payload"), endpoint: .pull, expected: .fullPull, line: #line),
            Case(answer: .init(status: 400), chunk: multi, expected: .backOff(.clientBug), line: #line),
            // 413.
            Case(answer: .init(status: 413), chunk: multi, expected: .rechunkAtHalfBytes, line: #line),
            Case(answer: .init(status: 413), chunk: multi, attempts: spent, expected: .backOff(.clientBug), line: #line),
            Case(answer: .init(status: 413), chunk: single, expected: .holdTooLarge, line: #line),
            Case(answer: .init(status: 413), chunk: single, attempts: spent, expected: .holdTooLarge, line: #line),
            Case(answer: .init(status: 413), chunk: loneDeletion, expected: .backOff(.clientBug), line: #line),
            // Session and repair.
            Case(answer: .init(status: 401), chunk: multi, expected: .reauth, line: #line),
            Case(answer: .init(status: 401), endpoint: .pull, expected: .reauth, line: #line),
            Case(answer: .init(status: 409, code: "snapshot_required"), chunk: multi, expected: .forcedResend, line: #line),
            Case(answer: .init(status: 409, code: "snapshot_required"), endpoint: .pull, expected: .forcedResend, line: #line),
            Case(answer: .init(status: 409, code: "cursor_expired"), endpoint: .pull, expected: .fullPull, line: #line),
            Case(answer: .init(status: 409), endpoint: .pull, expected: .backOff(.transient), line: #line),
            Case(answer: .init(status: 426, code: "upgrade_required"), chunk: multi, expected: .upgradeRequired, line: #line),
            // The server says when.
            Case(answer: .init(status: 429, code: "rate_limited", retryAfterSeconds: 42), chunk: multi,
                 expected: .backOff(.serverAsked(seconds: 42, paused: false)), line: #line),
            Case(answer: .init(status: 503, code: "sync_paused", retryAfterSeconds: 300), endpoint: .pull,
                 expected: .backOff(.serverAsked(seconds: 300, paused: true)), line: #line),
            Case(answer: .init(status: 503), chunk: multi, expected: .backOff(.transient), line: #line),
            Case(answer: .init(status: 500), chunk: multi, expected: .backOff(.transient), line: #line),
            Case(answer: .init(status: 502), endpoint: .pull, expected: .backOff(.transient), line: #line),
            Case(answer: .noAnswer, chunk: multi, expected: .backOff(.transient), line: #line),
            Case(answer: .init(status: 404), chunk: multi, expected: .backOff(.clientBug), line: #line),
        ]
        for c in table {
            XCTAssertEqual(SyncAnswers.action(for: c.answer, endpoint: c.endpoint, chunk: c.chunk, attempts: c.attempts),
                           c.expected, "status \(c.answer.status.map(String.init) ?? "none") \(c.answer.code ?? "")", line: c.line)
        }
    }

    /// Rate limits and pauses are never shown as sync errors; reports go only where the app is
    /// what is wrong.
    func testWhatIsReportedAndWhatIsShown() {
        XCTAssertTrue(SyncAnswerAction.backOff(.clientBug).reportsToSentry)
        XCTAssertFalse(SyncAnswerAction.backOff(.transient).reportsToSentry)
        XCTAssertFalse(SyncAnswerAction.backOff(.serverAsked(seconds: 5, paused: true)).setsSyncError)
        XCTAssertFalse(SyncAnswerAction.backOff(.serverAsked(seconds: nil, paused: false)).setsSyncError)
        XCTAssertFalse(SyncAnswerAction.reauth.setsSyncError, "401 has its own row")
        XCTAssertFalse(SyncAnswerAction.rechunk(nil).setsSyncError)
        XCTAssertTrue(SyncAnswerAction.backOff(.clientBug).setsSyncError)
        XCTAssertTrue(SyncHoldReason.rowError.reportsToSentry)
        XCTAssertFalse(SyncHoldReason.notOwned.reportsToSentry)
        XCTAssertFalse(SyncHoldReason.tombstoned.reportsToSentry)
    }

    /// Decoding what the server actually sends (server/lib/clientVersion.js `errorBody`, the
    /// pause guard, the rate limiter), and what a proxy might.
    func testDecodingAnswers() {
        let tooMany = #"{"error":"too_many_rows","code":"too_many_rows","message":"Too many rows","limits":{"habits":500,"entries":5000,"groups":200}}"#
        let a = SyncHTTPAnswer.decode(status: 400, body: Data(tooMany.utf8))
        XCTAssertEqual(a.code, "too_many_rows")
        XCTAssertEqual(a.limits, SyncRowLimits(habits: 500, entries: 5_000, groups: 200))

        let paused = #"{"error":"sync_paused","code":"sync_paused","message":"…","retryAfterSeconds":120}"#
        let b = SyncHTTPAnswer.decode(status: 503, body: Data(paused.utf8), retryAfterHeader: "999")
        XCTAssertEqual(b.code, "sync_paused")
        XCTAssertEqual(b.retryAfterSeconds, 120, "the body wins over the header")

        // A header-less client's shape: a sentence in `error`, the code in `code`.
        let legacy = #"{"error":"Too many sync requests, please try again later","code":"rate_limited"}"#
        XCTAssertEqual(SyncHTTPAnswer.decode(status: 429, body: Data(legacy.utf8), retryAfterHeader: " 30 ").code, "rate_limited")
        XCTAssertEqual(SyncHTTPAnswer.decode(status: 429, body: Data(legacy.utf8), retryAfterHeader: " 30 ").retryAfterSeconds, 30)
        // `error` alone: used only when it reads as a code.
        XCTAssertEqual(SyncHTTPAnswer.decode(status: 400, body: Data(#"{"error":"invalid_payload"}"#.utf8)).code, "invalid_payload")
        XCTAssertNil(SyncHTTPAnswer.decode(status: 400, body: Data(#"{"error":"Something broke"}"#.utf8)).code)

        let html = SyncHTTPAnswer.decode(status: 502, body: Data("<html>Bad Gateway</html>".utf8))
        XCTAssertEqual(html, SyncHTTPAnswer(status: 502))
        XCTAssertEqual(SyncHTTPAnswer.decode(status: 413, body: nil), SyncHTTPAnswer(status: 413))
        XCTAssertEqual(SyncHTTPAnswer.decode(status: 200, body: Data(#"{"ok":true,"applied":{}}"#.utf8)).ok, true)
    }

    /// "Doubling 1 min → 6 h, jittered"; the server's own Retry-After is used as given.
    func testTheBackoffCurve() {
        func d(_ n: Int, _ r: Double = 0.5, _ kind: SyncBackoffKind = .transient) -> TimeInterval {
            SyncBackoffPolicy.delay(for: kind, consecutiveFailures: n, unitRandom: r)
        }
        XCTAssertEqual(d(1), 60)
        XCTAssertEqual(d(2), 120)
        XCTAssertEqual(d(3), 240)
        XCTAssertEqual(d(9), 15_360)
        XCTAssertEqual(d(10), 6 * 3_600, "capped")
        XCTAssertEqual(d(500), 6 * 3_600)
        XCTAssertEqual(d(1, 0), 48, accuracy: 0.001)
        XCTAssertEqual(d(1, 1), 72, accuracy: 0.001)
        XCTAssertLessThanOrEqual(d(40, 1), 6 * 3_600)
        XCTAssertEqual(d(1, 0.5, .clientBug), 60)
        XCTAssertEqual(d(7, 0.5, .serverAsked(seconds: 42, paused: false)), 42)
        XCTAssertEqual(d(1, 0.5, .serverAsked(seconds: nil, paused: true)), 60, "no Retry-After: the curve")
    }

    // MARK: - Through the resolver, on a store

    @discardableResult
    private func habit(_ name: String = "Read", records: Int = 0) -> Habit {
        let h = Habit(name: name)
        context.insert(h)
        let day0 = HabitCalendar.utc.date(from: DateComponents(year: 2024, month: 3, day: 1))!
        h.records = (0..<records).map { HabitRecord(date: day0.addingTimeInterval(Double($0) * 86_400)) }
        return h
    }

    private func plan() throws -> SyncPushPlan {
        try SyncPushPlanner.plan(in: context, deletions: queue.pending())
    }

    @discardableResult
    private func resolve(_ chunk: SyncPushChunk, habits: [String: String] = [:], entries: [String: String] = [:],
                         groups: [String: String] = [:]) throws -> SyncChunkOutcome {
        let response = SyncPushResponse(
            ok: true,
            skipped: .init(habits: Array(habits.keys), entries: Array(entries.keys), groups: Array(groups.keys)),
            skippedReasons: .init(habits: habits, entries: entries, groups: groups))
        let outcome = try SyncPushResolver.resolve(chunk, response: response, in: context, deletionQueue: queue, strikes: strikes)
        try context.save()
        return outcome
    }

    /// Every skip reason ends dropped, held or pending on the actual rows, as the table says —
    /// and the rest of the chunk lands ("a `row_error` row is held, the rest of its chunk lands").
    func testEverySkipReasonThroughTheResolver() throws {
        let reasons = ["tombstoned", "missing_field", "row_error", "invalid_value", "not_owned", "future_code"]
        var byReason: [String: Habit] = [:]
        for reason in reasons { byReason[reason] = habit(reason) }
        let fine = habit("fine")
        let restored = habit("restored")
        restored.restoredAt = Date()
        let parent = habit("parent", records: 4)
        let entries = parent.records.sorted { $0.date < $1.date }

        let p = try plan()
        XCTAssertEqual(p.chunks.count, 1)
        var skippedHabits = Dictionary(uniqueKeysWithValues: reasons.map { (byReason[$0]!.id.uuidString, $0) })
        skippedHabits[restored.id.uuidString] = "tombstoned"
        let outcome = try resolve(p.chunks[0], habits: skippedHabits, entries: [
            entries[0].id.uuidString.lowercased(): "tombstoned_habit",
            entries[1].id.uuidString: "unknown_habit",
            entries[2].id.uuidString: "not_owned_habit",
        ])

        XCTAssertTrue(fine.hasBeenDelivered && !fine.isPending)
        XCTAssertTrue(parent.hasBeenDelivered)
        XCTAssertTrue(entries[3].hasBeenDelivered)

        XCTAssertEqual(Set(outcome.drops), [SyncRowRef(kind: .habit, id: byReason["tombstoned"]!.id.uuidString),
                                            SyncRowRef(kind: .entry, id: entries[0].id.uuidString)])
        XCTAssertEqual(byReason["missing_field"]!.activeHold, .missingField)
        XCTAssertEqual(byReason["row_error"]!.activeHold, .rowError)
        XCTAssertEqual(byReason["invalid_value"]!.activeHold, .invalidValue)
        XCTAssertEqual(byReason["not_owned"]!.activeHold, .notOwned)
        XCTAssertEqual(entries[2].activeHold, .notOwned)
        XCTAssertEqual(restored.activeHold, .tombstoned, "a restored row is held for the copies choice, not dropped")
        XCTAssertNotNil(restored.restoredAt)

        for held in [byReason["missing_field"]!, byReason["not_owned"]!, restored] {
            XCTAssertFalse(held.hasBeenDelivered, "held rows are never acknowledged")
            XCTAssertFalse(held.isPending, "…and never re-sent until edited")
        }
        XCTAssertTrue(byReason["future_code"]!.isPending)
        XCTAssertTrue(entries[1].isPending, "unknown_habit stays pending")
        XCTAssertEqual(Set(outcome.keptPending.map(\.id)), [byReason["future_code"]!.id.uuidString, entries[1].id.uuidString])

        // What comes back next sync: the pending ones only (and the dropped ones, until the
        // engine deletes them — deletion is its job, after the recovery log).
        let next = try plan()
        let planned = Set(next.chunks.flatMap { $0.submitted.map(\.ref.id) })
        XCTAssertTrue(planned.contains(byReason["future_code"]!.id.uuidString))
        XCTAssertTrue(planned.contains(entries[1].id.uuidString))
        for held in [byReason["missing_field"]!, byReason["row_error"]!, byReason["invalid_value"]!, byReason["not_owned"]!, restored] {
            XCTAssertFalse(planned.contains(held.id.uuidString))
        }
        XCTAssertFalse(planned.contains(entries[2].id.uuidString))
    }

    /// A held row is not planned until edited, the edit lifts the hold, and the entries of a
    /// held habit are not planned.
    func testAHeldRowIsNotPlannedUntilEditedAndItsEntriesStayBack() throws {
        let h = habit("Held", records: 3)
        let p = try plan()
        try resolve(p.chunks[0], habits: [h.id.uuidString: "row_error"],
                    entries: Dictionary(uniqueKeysWithValues: h.records.map { ($0.id.uuidString, "skipped_habit") }))
        XCTAssertEqual(h.activeHold, .rowError)
        XCTAssertTrue(h.records.allSatisfy(\.isPending), "skipped_habit: pending")
        XCTAssertTrue(try plan().isEmpty, "neither the held habit nor its entries")

        h.name = "Fixed"
        h.touch()
        XCTAssertFalse(h.isHeld)
        let after = try plan()
        XCTAssertEqual(after.chunks[0].payload.habits.map(\.id), [h.id.uuidString])
        XCTAssertEqual(after.chunks[0].payload.entries.count, 3)
    }

    /// A hold is at the SENT stamp: an edit made while the chunk was in flight is a new value
    /// and is not held.
    func testAHoldIsAtTheSentStampSoAnInFlightEditIsNotHeld() throws {
        let h = habit("Row")
        let p = try plan()
        h.name = "Row, edited in flight"
        h.touch()
        let outcome = try resolve(p.chunks[0], habits: [h.id.uuidString: "invalid_value"])
        XCTAssertEqual(outcome.holds.map(\.reason), [.invalidValue])
        XCTAssertFalse(h.isHeld)
        XCTAssertTrue(h.isPending)
        XCTAssertEqual(try plan().chunks[0].payload.habits.first?.name, "Row, edited in flight")
    }

    /// Three syncs of `unknown_habit` after the habit was acknowledged hold the entry; before the
    /// habit is acknowledged the answer is expected and counts for nothing.
    func testUnknownHabitStrikesThroughTheResolver() throws {
        let h = habit("Parent", records: 1)
        let entry = h.records[0]

        // Sync 1: the habit's chunk is this chunk too; the server says unknown_habit anyway (the
        // habit was skipped as row_error): no strike.
        var p = try plan()
        try resolve(p.chunks[0], habits: [h.id.uuidString: "missing_field"], entries: [entry.id.uuidString: "unknown_habit"])
        XCTAssertEqual(strikes.strikes(for: entry.id.uuidString), 0)

        // The habit is fixed and lands; its entry keeps coming back unknown_habit.
        h.name = "Parent fixed"; h.touch()
        p = try plan()
        try resolve(p.chunks[0], entries: [entry.id.uuidString: "unknown_habit"])
        XCTAssertTrue(h.hasBeenDelivered)
        XCTAssertEqual(strikes.strikes(for: entry.id.uuidString), 1)
        XCTAssertTrue(entry.isPending)

        p = try plan()
        try resolve(p.chunks[0], entries: [entry.id.uuidString: "unknown_habit"])
        XCTAssertEqual(strikes.strikes(for: entry.id.uuidString), 2)
        XCTAssertTrue(entry.isPending)

        p = try plan()
        let outcome = try resolve(p.chunks[0], entries: [entry.id.uuidString: "unknown_habit"])
        XCTAssertEqual(entry.activeHold, .unknownHabit)
        XCTAssertEqual(outcome.holds.map(\.reason), [.unknownHabit])
        XCTAssertEqual(strikes.strikes(for: entry.id.uuidString), 0, "cleared once decided")
        XCTAssertTrue(try plan().isEmpty)
    }

    /// `too_many_rows` re-chunks against `limits` in the same sync — once; a second is handled as
    /// `invalid_payload`.
    func testTooManyRowsRechunksAgainstTheLimitsOnce() throws {
        habit(records: 1_500)
        let p = try plan()
        XCTAssertEqual(p.chunks.count, 1)

        var attempts = SyncRunAttempts()
        let answer = SyncHTTPAnswer.decode(status: 400, body: Data(
            #"{"error":"too_many_rows","code":"too_many_rows","limits":{"habits":500,"entries":1000,"groups":200}}"#.utf8))
        guard case let .rechunk(limits) = SyncAnswers.action(for: answer, endpoint: .push, chunk: p.chunks[0].shape, attempts: attempts) else {
            return XCTFail("expected a re-chunk")
        }
        attempts.rechunkedForRows = true
        let again = try SyncPushPlanner.repack(p.chunks, bounds: SyncPushBounds.standard.clamped(to: limits))
        XCTAssertEqual(again.chunks.map { $0.payload.entries.count }, [1_000, 500])
        XCTAssertEqual(SyncAnswers.action(for: answer, endpoint: .push, chunk: again.chunks[0].shape, attempts: attempts),
                       .backOff(.clientBug))
    }

    /// `invalid_payload`: nothing is held, every row stays pending, the backoff is the client-bug
    /// curve, and the Sentry report carries counts — no names, notes or values.
    func testInvalidPayloadHoldsNothingAndReportsCountsOnly() throws {
        let h = habit("Secret habit name", records: 2)
        h.note = "private note"
        h.records[0].note = "private check-in note"
        let p = try plan()
        let chunk = p.chunks[0]

        let answer = SyncHTTPAnswer.decode(status: 400, body: Data(#"{"error":"invalid_payload","code":"invalid_payload"}"#.utf8))
        let action = SyncAnswers.action(for: answer, endpoint: .push, chunk: chunk.shape)
        XCTAssertEqual(action, .backOff(.clientBug))
        XCTAssertTrue(action.reportsToSentry)
        XCTAssertEqual(SyncBackoffPolicy.delay(for: .clientBug, consecutiveFailures: 1, unitRandom: 0.5), 60)

        // The engine does not resolve a non-200 chunk: the rows are exactly as they were.
        XCTAssertTrue(h.isPending && !h.isHeld)
        XCTAssertTrue(h.records.allSatisfy { $0.isPending && !$0.isHeld })
        XCTAssertEqual(try plan().rowCount, 3)

        let report = chunk.diagnostic(for: answer)
        XCTAssertEqual(report.code, "invalid_payload")
        XCTAssertEqual(report.counts, ["groups": 0, "habits": 1, "entries": 2, "deletions": 0])
        let text = String(describing: report)
        for secret in ["Secret", "private", h.id.uuidString] {
            XCTAssertFalse(text.contains(secret), "report carries \(secret)")
        }
    }

    /// 413 on a one-row chunk → that row is held `too_large` at the stamp that was sent.
    func testA413OnAOneRowChunkHoldsTheRowTooLarge() throws {
        let h = habit("Big")
        let p = try plan()
        let chunk = p.chunks[0]
        XCTAssertTrue(chunk.shape.isSingleRow)
        XCTAssertEqual(SyncAnswers.action(for: SyncHTTPAnswer(status: 413), endpoint: .push, chunk: chunk.shape), .holdTooLarge)

        let holds = try SyncPushResolver.holdTooLarge(chunk, in: context)
        XCTAssertEqual(holds.map(\.reason), [.tooLarge])
        XCTAssertEqual(h.activeHold, .tooLarge)
        XCTAssertFalse(h.hasBeenDelivered)
        XCTAssertTrue(try plan().isEmpty)

        // A held row's reports: id and reason only.
        let report = SyncDiagnosticReport.held(holds.map { ($0.ref.id, $0.reason) })
        XCTAssertEqual(report.reasons, [h.id.uuidString: "too_large"])
        XCTAssertFalse(String(describing: report).contains("Big"))
    }

    // MARK: - Local state beside the queue

    func testStrikesAndTheDeletionQueueClear() {
        strikes.record("A"); strikes.record("A"); strikes.record("B")
        XCTAssertEqual(strikes.strikes(for: "A"), 2)
        strikes.clear(["A"])
        XCTAssertEqual(strikes.strikes(for: "A"), 0)
        XCTAssertEqual(strikes.strikes(for: "B"), 1)
        strikes.clearAll()
        XCTAssertEqual(strikes.strikes(for: "B"), 0)

        let sharedSuite = "SyncAnswersTests-shared-\(UUID().uuidString)"
        let shared = UserDefaults(suiteName: sharedSuite)!
        defer { shared.removePersistentDomain(forName: sharedSuite) }
        let q = SyncDeletionQueue(local: defaults, shared: shared)
        q.trackHabit("H"); q.trackEntry("E"); q.trackGroup("G"); q.trackSharedEntry("W")
        XCTAssertEqual(q.pending().count, 4)
        q.clearAll()
        XCTAssertTrue(q.pending().isEmpty)
    }
}
