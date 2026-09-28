import XCTest
import SwiftData
import Foundation

/// The incremental push planner and its per-chunk acknowledgement (DEV-PLAN-1.3.md M2, Tests →
/// *Plan* and *Chunks*), against the real `SyncPushPlanner` / `SyncPushResolver` in Shared/ and
/// an in-memory store — the SyncReconcileTests pattern. The answers table has its own file
/// (SyncAnswersTests).
///
/// What these pin, and why each matters: a second sync with no edits must push nothing (1.3.0
/// pushed the whole store every time); an acknowledgement must record the stamp that was SENT,
/// or a row edited in flight is either lost (marked delivered at its new value) or left "never
/// delivered" (resurrected by a full pull once tombstones are swept); and no request may pass
/// 1 MB, because the server caps neither notes nor deletion lists.
@MainActor
final class SyncPushPlannerTests: XCTestCase {

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
        suiteName = "SyncPushPlannerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private let day0 = HabitCalendar.utc.date(from: DateComponents(year: 2024, month: 1, day: 1))!

    @discardableResult
    private func habit(_ name: String = "Read", records: Int = 0, note: String? = nil,
                       recordNote: String? = nil, in group: HabitGroup? = nil) -> Habit {
        let h = Habit(name: name)
        h.note = note
        h.groupId = group?.id
        context.insert(h)
        // Assigned once: appending to a managed relationship one record at a time is quadratic.
        h.records = (0..<records).map { i in
            HabitRecord(date: day0.addingTimeInterval(Double(i) * 86_400), note: recordNote)
        }
        return h
    }

    private func plan(_ bounds: SyncPushBounds = .standard) throws -> SyncPushPlan {
        try SyncPushPlanner.plan(in: context, deletions: queue.pending(), bounds: bounds)
    }

    private func ok(skipped: SyncPushResponse.Skipped? = nil,
                    reasons: SyncPushResponse.SkippedReasons? = nil,
                    applied: SyncPushResponse.Applied? = nil) -> SyncPushResponse {
        SyncPushResponse(ok: true, applied: applied, skipped: skipped ?? .init(), skippedReasons: reasons ?? .init())
    }

    @discardableResult
    private func resolve(_ chunk: SyncPushChunk, _ response: SyncPushResponse? = nil) throws -> SyncChunkOutcome {
        let outcome = try SyncPushResolver.resolve(chunk, response: response ?? ok(), in: context,
                                                   deletionQueue: queue, strikes: strikes)
        try context.save()
        return outcome
    }

    /// One whole push: every chunk answered 200 with nothing skipped.
    private func pushAll() throws {
        let p = try plan()
        try SyncPushResolver.apply(p.holds, in: context)
        for chunk in p.chunks { try resolve(chunk) }
    }

    private func ids(_ chunk: SyncPushChunk) -> (groups: [String], habits: [String], entries: [String]) {
        (chunk.payload.groups.map(\.id), chunk.payload.habits.map(\.id), chunk.payload.entries.map(\.id))
    }

    private func json(_ chunk: SyncPushChunk) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: chunk.body) as? [String: Any])
    }

    // MARK: - Plan

    /// A fresh store: one chunk, deletions first, then groups, habits, entries — the body order
    /// the server needs (a habit lands before its entries).
    func testFreshStorePlansDeletionsGroupsHabitsAndEntries() throws {
        let group = HabitGroup(name: "Health")
        context.insert(group)
        let h = habit(records: 3, in: group)
        queue.trackHabit("DEAD-HABIT")
        queue.trackEntry("DEAD-ENTRY")
        queue.trackGroup("DEAD-GROUP")

        let p = try plan()
        XCTAssertEqual(p.chunks.count, 1)
        let chunk = p.chunks[0]
        XCTAssertEqual(chunk.payload.groups.map(\.id), [group.id.uuidString])
        XCTAssertEqual(chunk.payload.habits.map(\.id), [h.id.uuidString])
        XCTAssertEqual(chunk.payload.entries.count, 3)
        XCTAssertTrue(chunk.payload.entries.allSatisfy { $0.habitId == h.id.uuidString })
        XCTAssertEqual(chunk.deletions, SyncDeletionQueue.Batch(habits: ["DEAD-HABIT"], entries: ["DEAD-ENTRY"], groups: ["DEAD-GROUP"]))

        // Item order: the three deletions, then group, habit, entries.
        let order = chunk.items.map { item -> String in
            switch item.body {
            case .deletedHabit, .deletedEntry, .deletedGroup: return "d"
            case .group: return "g"
            case .habit: return "h"
            case .entry: return "e"
            }
        }
        XCTAssertEqual(order, ["d", "d", "d", "g", "h", "e", "e", "e"])
    }

    /// The acceptance line "a second sync with no edits pushes 0/0/0".
    func testAfterAcknowledgementThePlanIsEmpty() throws {
        context.insert(HabitGroup(name: "Health"))
        habit(records: 5)
        queue.trackHabit("GONE")
        try pushAll()

        let again = try plan()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.rowCount, 0)
        XCTAssertTrue(queue.pending().isEmpty, "the delivered deletion id left the queue")
    }

    /// "One tap → next push carries exactly 1 entry and 0 habits."
    func testOneTouchedRecordPlansExactlyThatEntry() throws {
        let h = habit(records: 10)
        try pushAll()

        let record = h.records.sorted { $0.date < $1.date }[4]
        record.value = 3
        record.touch()

        let p = try plan()
        XCTAssertEqual(p.chunks.count, 1)
        XCTAssertEqual(ids(p.chunks[0]).habits, [])
        XCTAssertEqual(ids(p.chunks[0]).groups, [])
        XCTAssertEqual(ids(p.chunks[0]).entries, [record.id.uuidString])
    }

    /// Review 2: `syncedAt` records the stamp that was SENT, even when the row was edited while
    /// its chunk was in flight — including a first upload, which the first draft left at
    /// `syncedAt == nil` ("never delivered"), a row the full-pull rule would keep and re-push.
    func testAnEditDuringTheInFlightPushStaysPendingWithTheSentStamp() throws {
        let h = habit(records: 1)
        let record = h.records[0]
        let p = try plan()
        let sentHabitStamp = h.stamp
        let sentRecordStamp = record.stamp

        // The user edits both while the chunk is in flight.
        h.name = "Read more"; h.touch()
        record.note = "later"; record.touch()
        XCTAssertNotEqual(h.stamp, sentHabitStamp)

        try resolve(p.chunks[0])

        XCTAssertEqual(h.syncedAt, sentHabitStamp, "first upload: delivered, at the sent stamp")
        XCTAssertEqual(record.syncedAt, sentRecordStamp)
        XCTAssertTrue(h.hasBeenDelivered)
        XCTAssertTrue(h.isPending, "the edit is still to be sent")
        XCTAssertTrue(record.isPending)

        let next = try plan()
        XCTAssertEqual(ids(next.chunks[0]).habits, [h.id.uuidString])
        XCTAssertEqual(next.chunks[0].payload.habits[0].name, "Read more")
        XCTAssertEqual(ids(next.chunks[0]).entries, [record.id.uuidString])
    }

    /// The acknowledged set is the submitted ids minus `skipped`, compared canonically (the
    /// server echoes ids as it received them), whatever `applied` counts say — `applied` holds
    /// counts, not ids.
    func testAcknowledgedIsSubmittedMinusSkippedWhateverAppliedSays() throws {
        let a = habit("A"), b = habit("B"), c = habit("C")
        let p = try plan()
        let chunk = p.chunks[0]

        // `applied` claims zero, and the skipped id comes back lowercase.
        let response = ok(skipped: .init(habits: [b.id.uuidString.lowercased()]),
                          reasons: .init(habits: [b.id.uuidString.lowercased(): "row_error"]),
                          applied: .init(habits: 0))
        let acked = SyncPushResolver.acknowledged(chunk, response: response)
        XCTAssertEqual(Set(acked.keys.map(\.id)), [a.id.uuidString, c.id.uuidString])

        try resolve(chunk, response)
        XCTAssertTrue(a.hasBeenDelivered)
        XCTAssertFalse(b.hasBeenDelivered)
        XCTAssertEqual(b.activeHold, .rowError)
        XCTAssertTrue(c.hasBeenDelivered)

        // A skip reported only in `skippedReasons` still counts as skipped.
        let d = habit("D")
        let p2 = try plan()
        XCTAssertEqual(ids(p2.chunks[0]).habits, [d.id.uuidString])
        let onlyReasons = SyncPushResponse(ok: true, skipped: nil,
                                           skippedReasons: .init(habits: [d.id.uuidString: "unknown_reason_from_the_future"]))
        XCTAssertTrue(SyncPushResolver.acknowledged(p2.chunks[0], response: onlyReasons).isEmpty)
        let outcome = try resolve(p2.chunks[0], onlyReasons)
        XCTAssertFalse(d.hasBeenDelivered)
        XCTAssertTrue(d.isPending)
        XCTAssertEqual(outcome.unrecognisedReasons[SyncRowRef(kind: .habit, id: d.id.uuidString)],
                       "unknown_reason_from_the_future")
    }

    /// Inequality, not ordering: a clock that stepped backwards between two edits strands nothing.
    func testAClockStepBackwardsStaysPending() throws {
        let h = habit(records: 1)
        try pushAll()
        let delivered = h.stamp

        h.updatedAt = delivered.addingTimeInterval(-3_600)   // the clock went back an hour
        h.records[0].updatedAt = h.records[0].stamp.addingTimeInterval(-3_600)

        XCTAssertTrue(h.isPending)
        let p = try plan()
        XCTAssertEqual(ids(p.chunks[0]).habits, [h.id.uuidString])
        XCTAssertEqual(ids(p.chunks[0]).entries, [h.records[0].id.uuidString])
    }

    /// A chunk of one entry still carries all six arrays, empty ones included.
    func testAPartialPayloadStillEncodesAllSixArrays() throws {
        let h = habit(records: 1)
        try pushAll()
        h.records[0].touch()

        let body = try json(try plan().chunks[0])
        for key in ["habits", "entries", "groups", "deletedHabitIds", "deletedEntryIds", "deletedGroupIds"] {
            XCTAssertNotNil(body[key] as? [Any], "\(key) missing from a partial payload")
        }
        XCTAssertEqual((body["entries"] as? [Any])?.count, 1)
        XCTAssertEqual((body["habits"] as? [Any])?.count, 0)
    }

    /// A record has no `createdAt`; a record never edited (no `updatedAt`, as 1.2.x wrote them)
    /// stamps as its `date` — both on the wire and in the acknowledgement.
    func testARecordWithNoUpdatedAtStampsAsItsDate() throws {
        let h = habit(records: 1)
        let record = h.records[0]
        record.updatedAt = nil

        let chunk = try plan().chunks[0]
        let entry = try XCTUnwrap(chunk.payload.entries.first)
        XCTAssertEqual(entry.createdAt, SyncTimestamp.millisecondString(from: record.date))
        XCTAssertEqual(entry.updatedAt, SyncTimestamp.millisecondString(from: record.date))
        XCTAssertEqual(entry.date, "2024-01-01")

        try resolve(chunk)
        XCTAssertEqual(record.syncedAt, record.date)
        XCTAssertFalse(record.isPending)
    }

    /// The wire keys are camelCase (the backend reads `habitId`, `deletedHabitIds`, …; the
    /// `.convertToSnakeCase` encoder silently broke every push once), and stamps carry exactly
    /// three fractional digits that parse back to the stored `Date`.
    func testTheWireIsCamelCaseWithMillisecondStamps() throws {
        let group = HabitGroup(name: "G")
        context.insert(group)
        let h = habit(records: 1, in: group)
        queue.trackHabit("X")

        let body = try json(try plan().chunks[0])
        let habitJSON = try XCTUnwrap((body["habits"] as? [[String: Any]])?.first)
        let entryJSON = try XCTUnwrap((body["entries"] as? [[String: Any]])?.first)
        let groupJSON = try XCTUnwrap((body["groups"] as? [[String: Any]])?.first)
        XCTAssertNotNil(habitJSON["colorHex"])
        XCTAssertNotNil(habitJSON["isArchived"])
        XCTAssertEqual(habitJSON["groupId"] as? String, group.id.uuidString)
        XCTAssertEqual(entryJSON["habitId"] as? String, h.id.uuidString)
        XCTAssertNotNil(groupJSON["sortOrder"])
        XCTAssertNotNil(body["deletedHabitIds"])
        XCTAssertNil(habitJSON["color_hex"])
        XCTAssertNil(body["deleted_habit_ids"])

        let updatedAt = try XCTUnwrap(habitJSON["updatedAt"] as? String)
        XCTAssertNotNil(updatedAt.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"#, options: .regularExpression), updatedAt)
        XCTAssertEqual(SyncTimestamp.parse(updatedAt), h.stamp)
    }

    /// The byte bound is only as good as the measurement: the planner's running sum must equal
    /// the encoded body exactly, including escapes (`/`, quotes, newlines) and non-ASCII notes,
    /// and odd deletion ids that are not UUIDs.
    func testThePlannedSizeIsExactlyTheEncodedBody() throws {
        let group = HabitGroup(name: "Hé/\"llo\"")
        context.insert(group)
        habit("Ünïcödé 🚰", records: 7, note: "a/b\\c\n\"quoted\"\t🙂", recordNote: "日本語 / emoji 👍🏽 \u{0001}", in: group)
        habit("Plain", records: 3)
        queue.trackEntry("not-a-uuid/with \"odd\" chars")
        queue.trackHabit(UUID().uuidString.lowercased())

        let encoder = SyncPushPlanner.makeEncoder()
        for bounds in [SyncPushBounds.standard, SyncPushBounds(bytes: 700)] {
            let p = try plan(bounds)
            XCTAssertFalse(p.chunks.isEmpty)
            for chunk in p.chunks {
                let predicted = try predictedSize(chunk.items, encoder)
                XCTAssertEqual(predicted, chunk.body.count)
                // Same JSON as encoding the payload (key order inside an object is the
                // encoder's business, so compare parsed, not bytes).
                let again = try JSONSerialization.jsonObject(with: try encoder.encode(chunk.payload)) as? NSDictionary
                let sent = try JSONSerialization.jsonObject(with: chunk.body) as? NSDictionary
                XCTAssertEqual(again, sent)
            }
        }
    }

    /// Recomputes what the planner's `Builder` sums, from the items.
    private func predictedSize(_ items: [SyncPushItem], _ encoder: JSONEncoder) throws -> Int {
        let empty = try encoder.encode(SyncPushPayload(habits: [], entries: [], groups: [], deletedHabitIds: [],
                                                       deletedEntryIds: [], deletedGroupIds: [])).count
        var perArray: [String: Int] = [:]
        var total = empty
        for item in items {
            let key: String
            switch item.body {
            case .deletedHabit: key = "dh"
            case .deletedEntry: key = "de"
            case .deletedGroup: key = "dg"
            case .group: key = "g"
            case .habit: key = "h"
            case .entry: key = "e"
            }
            total += item.encodedSize + ((perArray[key] ?? 0) > 0 ? 1 : 0)
            perArray[key, default: 0] += 1
        }
        return total
    }

    /// Forced resend (`409 snapshot_required`, Full resync): a delivered row is planned again,
    /// its `syncedAt` stays until the resend is acknowledged, and a held row is still not sent.
    func testNeedsResendPlansADeliveredRowAndKeepsItsSyncedAt() throws {
        let h = habit(records: 2)
        let held = habit("Held")
        try pushAll()
        held.hold(.rowError)
        let delivered = h.syncedAt

        for row in [h as any SyncDeliverable, h.records[0], h.records[1], held] { row.markNeedsResend() }
        XCTAssertTrue(try SyncPushPlanner.hasForcedResend(in: context))

        let p = try plan()
        XCTAssertEqual(ids(p.chunks[0]).habits, [h.id.uuidString], "the held habit is not resent")
        XCTAssertEqual(ids(p.chunks[0]).entries.count, 2)
        XCTAssertEqual(h.syncedAt, delivered, "planning touches nothing")

        try resolve(p.chunks[0])
        XCTAssertFalse(h.needsResend)
        XCTAssertEqual(h.syncedAt, delivered)
        XCTAssertTrue(try plan().isEmpty)
        XCTAssertFalse(try SyncPushPlanner.hasForcedResend(in: context), "only a held row still carries the flag")
    }

    /// The row's first acknowledgement clears `restoredAt` (and `needsResend`).
    func testAcknowledgementClearsRestoredAtAndNeedsResend() throws {
        let h = habit(records: 1)
        h.restoredAt = Date()
        h.records[0].restoredAt = Date()
        h.needsResend = true

        try pushAll()
        XCTAssertNil(h.restoredAt)
        XCTAssertNil(h.records[0].restoredAt)
        XCTAssertFalse(h.needsResend)
    }

    /// A number JSON cannot carry (NaN, infinity) makes the encoder throw — 1.3.0 lost the whole
    /// push to one such row. Now the row is held `invalid_value` (the server's own answer for it)
    /// and everything else goes; a habit held that way keeps its entries back.
    func testAnUnencodableRowIsHeldInvalidValueAndTheRestGoes() throws {
        let fine = habit("Fine", records: 2)
        let fineRecords = fine.records.sorted { $0.date < $1.date }
        fineRecords[1].value = .nan
        let broken = habit("Broken", records: 2)
        broken.targetValue = .infinity

        let p = try plan()
        let chunk = p.chunks[0]
        XCTAssertEqual(ids(chunk).habits, [fine.id.uuidString])
        XCTAssertEqual(ids(chunk).entries, [fineRecords[0].id.uuidString])
        XCTAssertEqual(Set(p.holds.map(\.ref.id)), [fineRecords[1].id.uuidString, broken.id.uuidString])
        XCTAssertTrue(p.holds.allSatisfy { $0.reason == .invalidValue })

        try SyncPushResolver.apply(p.holds, in: context)
        try resolve(chunk)
        XCTAssertEqual(broken.activeHold, .invalidValue)
        XCTAssertEqual(fineRecords[1].activeHold, .invalidValue)
        XCTAssertTrue(try plan().isEmpty, "held rows and the held habit's entries are not planned")

        // Fixing the value is an edit, and the edit lifts the hold.
        broken.targetValue = 8
        broken.touch()
        let after = try plan()
        XCTAssertEqual(ids(after.chunks[0]).habits, [broken.id.uuidString])
        XCTAssertEqual(ids(after.chunks[0]).entries.count, 2)
    }

    // MARK: - Chunks

    /// 600 pending habits → two habit chunks (the 500-habit bound).
    func testSixHundredHabitsMakeTwoHabitChunks() throws {
        for i in 0..<600 { habit("H\(i)") }
        let p = try plan()
        XCTAssertEqual(p.chunks.map { $0.payload.habits.count }, [500, 100])
        XCTAssertTrue(p.chunks.allSatisfy { $0.body.count <= 1_000_000 })
    }

    /// "A 2,500-entry first upload completes in 2 requests" — later chunks entries only.
    func testTwentyFiveHundredEntriesMakeTwoChunksTheLaterEntriesOnly() throws {
        let h = habit(records: 2_500)
        let p = try plan()
        XCTAssertEqual(p.chunks.count, 2)
        XCTAssertEqual(ids(p.chunks[0]).habits, [h.id.uuidString])
        XCTAssertEqual(p.chunks[0].payload.entries.count, 2_000)
        XCTAssertEqual(p.chunks[1].payload.habits.count, 0)
        XCTAssertEqual(p.chunks[1].payload.entries.count, 500)
        XCTAssertTrue(p.chunks[1].deletions.isEmpty)
    }

    /// "2,000 entries with 2 KB notes upload with no request over 1 MB."
    func testTwoThousandEntriesWithTwoKilobyteNotesStayUnderOneMegabyte() throws {
        habit(records: 2_000, recordNote: String(repeating: "n", count: 2_048))
        let p = try plan()
        XCTAssertGreaterThan(p.chunks.count, 1)
        XCTAssertTrue(p.chunks.allSatisfy { $0.body.count <= 1_000_000 }, "\(p.chunks.map(\.body.count))")
        XCTAssertEqual(p.chunks.reduce(0) { $0 + $1.payload.entries.count }, 2_000)
        XCTAssertEqual(Set(p.chunks.flatMap { $0.payload.entries.map(\.id) }).count, 2_000)
    }

    /// 30,000 queued deletion ids are spread over chunks by bytes, and only the ids of chunks
    /// answered 200 leave the queue.
    func testThirtyThousandDeletionIdsSpreadAndOnlyDeliveredOnesAreAcknowledged() throws {
        let queued = (0..<30_000).map { _ in UUID().uuidString }
        defaults.set(queued, forKey: SyncDeletionQueue.entriesKey)

        let p = try plan()
        XCTAssertGreaterThan(p.chunks.count, 1)
        XCTAssertTrue(p.chunks.allSatisfy { $0.body.count <= 1_000_000 })
        XCTAssertEqual(p.chunks.flatMap(\.deletions.entries), queued, "all of them, in queue order")

        // Chunk 0 lands; chunk 1 fails.
        let outcome = try resolve(p.chunks[0])
        XCTAssertEqual(outcome.deliveredDeletions, p.chunks[0].deletions)
        let left = queue.pending().entries
        XCTAssertEqual(left, Array(queued.dropFirst(p.chunks[0].deletions.entries.count)))
        XCTAssertEqual(Set(left), Set(p.chunks.dropFirst().flatMap(\.deletions.entries)))
    }

    /// An item alone over the byte bound (but under the body limit) travels in a chunk by itself.
    func testATwoMegabyteRowTravelsAlone() throws {
        habit("Before", records: 3)
        let big = habit("Big", note: String(repeating: "x", count: 2_000_000))
        habit("After", records: 3)

        let p = try plan()
        let alone = try XCTUnwrap(p.chunks.first { $0.payload.habits.contains { $0.id == big.id.uuidString } })
        XCTAssertEqual(alone.items.count, 1)
        XCTAssertGreaterThan(alone.body.count, 1_000_000)
        XCTAssertLessThan(alone.body.count, 4_500_000)
        XCTAssertTrue(p.chunks.filter { $0.items.count > 1 }.allSatisfy { $0.body.count <= 1_000_000 })
        XCTAssertEqual(p.rowCount, 9, "every row planned once: 3 habits + 6 entries")
        XCTAssertTrue(p.holds.isEmpty)
    }

    /// One whose encoding exceeds 4.5 MB is never sent: held `too_large`, and its entries stay
    /// back with it. An edit that shrinks it lifts the hold.
    func testASixMegabyteRowIsHeldTooLargeAndNeverPlanned() throws {
        let huge = habit("Huge", records: 2, note: String(repeating: "x", count: 6_000_000))
        let other = habit("Other", records: 1)
        let bigEntryHabit = habit("Notes", records: 1)
        bigEntryHabit.records[0].note = String(repeating: "y", count: 5_000_000)

        let p = try plan()
        XCTAssertEqual(Set(p.holds.map(\.ref)), [SyncRowRef(kind: .habit, id: huge.id.uuidString),
                                                 SyncRowRef(kind: .entry, id: bigEntryHabit.records[0].id.uuidString)])
        XCTAssertTrue(p.holds.allSatisfy { $0.reason == .tooLarge })
        let planned = Set(p.chunks.flatMap { $0.submitted.map(\.ref.id) })
        XCTAssertFalse(planned.contains(huge.id.uuidString))
        XCTAssertTrue(huge.records.allSatisfy { !planned.contains($0.id.uuidString) }, "entries of a held habit")
        XCTAssertTrue(planned.contains(other.id.uuidString))
        XCTAssertTrue(p.chunks.allSatisfy { $0.body.count <= 1_000_000 })

        try SyncPushResolver.apply(p.holds, in: context)
        for chunk in p.chunks { try resolve(chunk) }
        XCTAssertEqual(huge.activeHold, .tooLarge)
        XCTAssertTrue(try plan().isEmpty)

        huge.note = "short now"
        huge.touch()
        let after = try plan()
        XCTAssertEqual(ids(after.chunks[0]).habits, [huge.id.uuidString])
        XCTAssertEqual(ids(after.chunks[0]).entries.count, 2)
    }

    /// "A failure injected at chunk 2 leaves chunk 1 acknowledged and the retry sends only
    /// chunk 2": failure at chunk k → < k acknowledged, ≥ k pending, the retry resumes at k.
    func testAFailureAtChunkKResumesAtK() throws {
        for i in 0..<1_200 { habit("H\(i)") }
        let first = try plan()
        XCTAssertEqual(first.chunks.count, 3)

        try resolve(first.chunks[0])
        try resolve(first.chunks[1])
        // chunk 2 failed (5xx): nothing resolved for it.

        let acked = Set(first.chunks[0...1].flatMap { $0.submitted.map(\.ref.id) })
        let all = try context.fetch(FetchDescriptor<Habit>())
        XCTAssertEqual(all.filter(\.hasBeenDelivered).count, 1_000)
        XCTAssertTrue(all.filter { !acked.contains($0.id.uuidString) }.allSatisfy(\.isPending))

        let retry = try plan()
        XCTAssertEqual(retry.chunks.count, 1)
        XCTAssertEqual(ids(retry.chunks[0]).habits, ids(first.chunks[2]).habits)
    }

    /// Re-chunking (after `too_many_rows` or a 413) keeps order and the stamps as first sent.
    func testRepackKeepsOrderAndSentStamps() throws {
        let h = habit(records: 900)
        let p = try plan()
        XCTAssertEqual(p.chunks.count, 1)
        let stamps = p.chunks[0].submitted.map(\.sentStamp)

        h.touch()   // edited after planning: the repack must not pick up the new stamp
        let limited = try SyncPushPlanner.repack(p.chunks, bounds: SyncPushBounds.standard.clamped(
            to: SyncRowLimits(habits: 500, entries: 400, groups: 200)))
        XCTAssertEqual(limited.chunks.map { $0.payload.entries.count }, [400, 400, 100])
        XCTAssertEqual(limited.chunks.flatMap { $0.submitted.map(\.sentStamp) }, stamps)

        let halved = try SyncPushPlanner.repack(p.chunks, bounds: SyncPushBounds.standard.halvingBytes().halvingBytes()
            .halvingBytes().halvingBytes().halvingBytes())   // 31,250 bytes
        XCTAssertGreaterThan(halved.chunks.count, 1)
        XCTAssertTrue(halved.chunks.allSatisfy { $0.body.count <= 31_250 })
        XCTAssertEqual(halved.chunks.flatMap { $0.submitted.map(\.ref) }, p.chunks[0].submitted.map(\.ref))
    }

    /// Two local rows with one canonical id (old id-case bugs made them) are sent once; the
    /// acknowledgement reaches both, since the server holds one row for that id.
    func testDuplicateIdsAreSentOnceAndAcknowledgedTogether() throws {
        let a = habit("A")
        let b = habit("A copy")
        b.id = a.id
        b.updatedAt = a.updatedAt

        let p = try plan()
        XCTAssertEqual(ids(p.chunks[0]).habits, [a.id.uuidString])
        try resolve(p.chunks[0])
        XCTAssertTrue(a.hasBeenDelivered)
        XCTAssertTrue(b.hasBeenDelivered)
    }
}
