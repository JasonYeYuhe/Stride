import Foundation
import SwiftData

// The incremental, chunked push (DEV-PLAN-1.3.md M2: "Shared/SyncPushPlanner.swift", "Chunks
// are bounded by rows and by bytes", "Acknowledge per chunk").
//
// Up to 1.3.0, `SyncService.pushLocal` serialised every row on every sync — a full snapshot,
// growing without bound, that 413'd the old 10 kb body limit within three weeks of daily use and
// killed both directions. From 1.3.1 the push carries only pending rows (`SyncDeliverable`), in
// chunks sent in sequence, and each chunk's answer acknowledges exactly the rows the server
// wrote.
//
// Network-free: the planner reads a store and returns chunks, the resolver applies an answer to
// a store. In Shared/ so the host-less StrideTests and scripts/sync_rehearsal.sh run the real
// code — the move that fixed the reconciler in 72ccb74. Testing a hand-copied replica is how the
// reconciler drifted before 1.2.3.

/// The three row types a push carries.
enum SyncRowKind: String, CaseIterable, Hashable {
    case group
    case habit
    case entry
}

/// One row, by type and canonical id (`SyncReconciler.canonicalID` — the uppercase
/// `uuidString`; the server echoes ids as it received them, and server-made ids are lowercase).
struct SyncRowRef: Hashable {
    let kind: SyncRowKind
    let id: String
}

/// A hold the planner decided without asking the server.
struct SyncPlannedHold: Equatable {
    let ref: SyncRowRef
    let reason: SyncHoldReason
    /// The stamp the row had when planned: the hold is at this stamp, so an edit since lifts it.
    let stamp: Date
}

/// One element of a push body: a row with the stamp it was sent at, or a queued deletion id.
struct SyncPushItem {
    enum Body {
        case deletedHabit(String)
        case deletedEntry(String)
        case deletedGroup(String)
        case group(SyncGroup)
        case habit(SyncHabit)
        case entry(SyncEntry)
    }

    let body: Body
    /// Bytes this element adds to its JSON array, measured with the encoder that sends it
    /// (separators excluded; `SyncPushPlanner.pack` adds those).
    let encodedSize: Int
    /// The row this is; nil for a deletion id.
    let ref: SyncRowRef?
    /// The stamp that was SENT (`updatedAt` on the wire), captured when the row was encoded — the
    /// value an acknowledgement writes to `syncedAt`, even if the row is edited while its chunk
    /// is in flight.
    let sentStamp: Date?

    var isRow: Bool { ref != nil }
}

/// Per-request bounds. The server's row caps (routes/sync.js `ROW_LIMITS`: 500 / 5,000 / 200)
/// are wider on purpose: these sit inside them. The server does not cap deletion lists or the
/// size of a note — only the 5 MB body does — so 2,000 entries with multi-KB notes, or a big
/// deletion queue (deleting a multi-year habit queues one id per check-in), would 413 without
/// the byte bound.
struct SyncPushBounds: Equatable {
    var groups = 200
    var habits = 500
    var entries = 2_000
    /// Encoded JSON per request, deletion ids included. Decimal megabytes, so "no request over
    /// 1 MB" holds whichever megabyte the reader means.
    var bytes = 1_000_000
    /// An item whose encoding alone exceeds this is never sent: held `too_large`. The 5 MB body
    /// limit (body-parser's `5mb`, 5 × 1,024²) less the envelope, in decimal — generous room.
    var maxItemBytes = 4_500_000

    static let standard = SyncPushBounds()

    /// After `400 too_many_rows`: never more rows per type than the server says it takes.
    func clamped(to limits: SyncRowLimits?) -> SyncPushBounds {
        guard let limits else { return self }
        var b = self
        b.groups = max(1, min(groups, limits.groups))
        b.habits = max(1, min(habits, limits.habits))
        b.entries = max(1, min(entries, limits.entries))
        return b
    }

    /// After a 413 on a multi-item chunk: half the byte bound, once.
    func halvingBytes() -> SyncPushBounds {
        var b = self
        b.bytes = max(1, bytes / 2)
        return b
    }

    fileprivate func rowLimit(_ kind: SyncRowKind) -> Int {
        switch kind {
        case .group: return groups
        case .habit: return habits
        case .entry: return entries
        }
    }
}

/// One request's worth of the push.
struct SyncPushChunk {
    let items: [SyncPushItem]
    let payload: SyncPushPayload
    /// The exact bytes to send — `payload` through `SyncPushPlanner.makeEncoder()`, the
    /// measurement the bounds were checked against. A transport that encodes `payload` itself
    /// must use that same encoder.
    let body: Data
    /// The deletion ids this chunk carries, exactly as queued: what `SyncDeletionQueue.acknowledge`
    /// removes once the chunk is answered 200.
    let deletions: SyncDeletionQueue.Batch

    var rowCount: Int { payload.groups.count + payload.habits.count + payload.entries.count }
    var deletionCount: Int { deletions.count }
    var shape: SyncChunkShape { SyncChunkShape(items: items.count, rows: rowCount) }

    /// Submitted rows and the stamps they were sent at, in body order.
    var submitted: [(ref: SyncRowRef, sentStamp: Date)] {
        items.compactMap { item in
            guard let ref = item.ref, let stamp = item.sentStamp else { return nil }
            return (ref, stamp)
        }
    }

    /// Counts only — what a Sentry report about this chunk may carry.
    func diagnostic(for answer: SyncHTTPAnswer) -> SyncDiagnosticReport {
        .answer(answer, groups: payload.groups.count, habits: payload.habits.count,
                entries: payload.entries.count, deletions: deletionCount)
    }
}

/// Everything one sync would push, in order.
struct SyncPushPlan {
    var chunks: [SyncPushChunk] = []
    /// Rows the planner holds without sending: `too_large` (alone over `maxItemBytes`) and
    /// `invalid_value` (a number JSON cannot carry — NaN or infinity — which the encoder refuses,
    /// and which the server would refuse as `invalid_value` anyway). Apply with
    /// `SyncPushResolver.apply(_:in:)` before or alongside the first chunk.
    var holds: [SyncPlannedHold] = []

    var isEmpty: Bool { chunks.isEmpty }
    var rowCount: Int { chunks.reduce(0) { $0 + $1.rowCount } }
    var deletionCount: Int { chunks.reduce(0) { $0 + $1.deletionCount } }
}

@MainActor
enum SyncPushPlanner {
    /// The encoder every push body goes through, and the one the bounds are measured with.
    ///
    /// It MUST stay the configuration `APIClient` uses: a plain `JSONEncoder` — no key strategy
    /// (the backend speaks camelCase in both directions; `.convertToSnakeCase` silently broke
    /// every push from 3829085 until 1.2.2), no output formatting (pretty-printing would change
    /// every measured size). `StrideTests/SyncPushPlannerTests` pins the keys.
    nonisolated static func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    // Day-only dates are UTC day-keys, matching the stored representation (HabitCalendar) —
    // never the device's current zone, which would shift check-ins across day boundaries.
    private static let dateOnly: DateFormatter = HabitCalendar.dayStringFormatter

    // MARK: Plan

    /// Plans the push: queued deletions, then pending groups, habits, entries — chunked.
    ///
    /// Never plans a held row, nor the entries of a held habit (including one this plan holds).
    /// Reads the store; mutates nothing.
    static func plan(
        in context: ModelContext,
        deletions: SyncDeletionQueue.Batch,
        bounds: SyncPushBounds = .standard
    ) throws -> SyncPushPlan {
        let encoder = makeEncoder()
        var holds: [SyncPlannedHold] = []
        var items: [SyncPushItem] = []

        items += deletionItems(deletions)

        // Groups.
        let groups = try context.fetch(FetchDescriptor<HabitGroup>())
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var seen = Set<SyncRowRef>()
        for group in groups where group.isPending {
            let ref = SyncRowRef(kind: .group, id: group.id.uuidString)
            guard seen.insert(ref).inserted else { continue }
            let stamp = SyncTimestamp.floorToMillisecond(group.stamp)
            let wire = wireGroup(group, stamp: stamp)
            guard let size = measure(wire, encoder) else {
                holds.append(SyncPlannedHold(ref: ref, reason: .invalidValue, stamp: stamp)); continue
            }
            items.append(SyncPushItem(body: .group(wire), encodedSize: size, ref: ref, sentStamp: stamp))
        }

        // Habits. A habit held now, or held by this plan, keeps its entries back too: the server
        // would skip them as unknown_habit (or not_owned_habit) and they would come back pending.
        let habits = try context.fetch(FetchDescriptor<Habit>())
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var blockedHabits = Set<String>()
        for habit in habits {
            let ref = SyncRowRef(kind: .habit, id: habit.id.uuidString)
            if habit.isHeld { blockedHabits.insert(ref.id); continue }
            guard habit.isPending, seen.insert(ref).inserted else { continue }
            let stamp = SyncTimestamp.floorToMillisecond(habit.stamp)
            let wire = wireHabit(habit, stamp: stamp)
            guard let size = measure(wire, encoder) else {
                holds.append(SyncPlannedHold(ref: ref, reason: .invalidValue, stamp: stamp))
                blockedHabits.insert(ref.id)
                continue
            }
            if size > bounds.maxItemBytes {
                holds.append(SyncPlannedHold(ref: ref, reason: .tooLarge, stamp: stamp))
                blockedHabits.insert(ref.id)
                continue
            }
            items.append(SyncPushItem(body: .habit(wire), encodedSize: size, ref: ref, sentStamp: stamp))
        }

        // Entries. The pending ones are found with one fetch (`SyncPendingRows`); only when there
        // are any does the planner go through the habits, because `HabitRecord` has no `habitId`
        // and `Habit.records` has no inverse, so a record's habit is known only from that side —
        // and it then compares identifiers, reading no record's fields but the pending ones'. Up
        // to the M2 slice it sorted and read every record of every habit on every sync: 3.4 s on
        // the main actor for a sync with nothing to send on a 20,000-entry store (rehearsal S12).
        let pendingRecords = try SyncPendingRows.records(in: context)
        for habit in habits where !pendingRecords.isEmpty && !blockedHabits.contains(habit.id.uuidString) {
            let records = habit.records
                .filter { pendingRecords.contains($0.persistentModelID) }
                .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            for record in records where record.isPending {
                let ref = SyncRowRef(kind: .entry, id: record.id.uuidString)
                guard seen.insert(ref).inserted else { continue }
                let stamp = SyncTimestamp.floorToMillisecond(record.stamp)
                let wire = wireEntry(record, habitID: habit.id.uuidString, stamp: stamp)
                guard let size = measure(wire, encoder) else {
                    holds.append(SyncPlannedHold(ref: ref, reason: .invalidValue, stamp: stamp)); continue
                }
                items.append(SyncPushItem(body: .entry(wire), encodedSize: size, ref: ref, sentStamp: stamp))
            }
        }

        let packed = try pack(items, bounds: bounds, encoder: encoder)
        return SyncPushPlan(chunks: packed.chunks, holds: holds + packed.holds)
    }

    /// Re-plans chunks that have not been answered yet under new bounds (`400 too_many_rows`'s
    /// `limits`, or half the bytes after a 413), keeping their order and their sent stamps: the
    /// rows are the same rows as planned, so the acknowledgement still records what was sent.
    static func repack(_ chunks: some Sequence<SyncPushChunk>, bounds: SyncPushBounds) throws -> SyncPushPlan {
        let packed = try pack(chunks.flatMap(\.items), bounds: bounds, encoder: makeEncoder())
        return SyncPushPlan(chunks: packed.chunks, holds: packed.holds)
    }

    /// Whether any row waits on a forced resend. A sync that finds one pulls before it pushes
    /// ("Forced resend waits until deletions are settled").
    ///
    /// Asks the store for the rows with `needsResend` set rather than reading every row: this
    /// runs at the start of every sync.
    ///
    /// Counts only a row the planner could send (review delivery-2). A Full resync marks every
    /// record, including the check-ins of a held habit and an orphan no habit owns; `plan` never
    /// sends either (it reaches records through habits and skips a held habit's), so nothing
    /// acknowledges them and their flag stays. Counted, they made every later sync pull before
    /// the push as well as after it, for as long as the hold lasted — for an orphan, for good.
    /// Their flag is kept, not cleared: once the hold is lifted the resend is still owed, and
    /// `SyncCopies.reidentify` clears it for rows that become new copies.
    static func hasForcedResend(in context: ModelContext) throws -> Bool {
        func any<Row: SyncDeliverable>(_ rows: [Row]) -> Bool { rows.contains { $0.needsResend && !$0.isHeld } }
        if any(try context.fetch(FetchDescriptor<HabitGroup>(predicate: #Predicate { $0.needsResend == true }))) {
            return true
        }
        if any(try context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.needsResend == true }))) {
            return true
        }
        let marked = Set(try context.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { $0.needsResend == true }))
            .map(\.persistentModelID))
        guard !marked.isEmpty else { return false }
        // The planner's walk: a record's habit is known only from the habit's side
        // (`Habit.records` has no inverse), and records are matched by identifier, so it stops at
        // the first sendable one — after a Full resync that is the first habit's. `SyncStatusCounts`
        // leaves the same rows out of its count.
        for habit in try context.fetch(FetchDescriptor<Habit>()) where !habit.isHeld {
            if habit.records.contains(where: { marked.contains($0.persistentModelID) && !$0.isHeld }) { return true }
        }
        return false
    }

    // MARK: Pack

    /// Packs items, in order, into chunks. A chunk closes when the next item would pass any
    /// bound, and the next chunk carries on from there. An item that alone exceeds the byte
    /// bound goes in a chunk by itself; one over `maxItemBytes` is never sent (held `too_large`,
    /// or left out and reported if it is a deletion id — no real id is megabytes long).
    ///
    /// Sizes add up exactly: a compact JSON array is `[` + elements joined by `,` + `]`, and an
    /// element encodes to the same bytes inside the array as on its own. Each finished chunk is
    /// still encoded for real (that is its `body`); should the sum and the encoding ever
    /// disagree past the bound, the chunk is split rather than sent over it.
    static func pack(
        _ items: [SyncPushItem],
        bounds: SyncPushBounds,
        encoder: JSONEncoder
    ) throws -> (chunks: [SyncPushChunk], holds: [SyncPlannedHold]) {
        let envelope = try emptyEnvelopeSize(encoder)
        var chunks: [SyncPushChunk] = []
        var holds: [SyncPlannedHold] = []
        var current = Builder(envelope: envelope)

        func close() throws {
            guard !current.items.isEmpty else { return }
            chunks += try finish(current.items, bounds: bounds, encoder: encoder)
            current = Builder(envelope: envelope)
        }

        for item in items {
            if item.encodedSize > bounds.maxItemBytes {
                if let ref = item.ref, let stamp = item.sentStamp {
                    holds.append(SyncPlannedHold(ref: ref, reason: .tooLarge, stamp: stamp))
                }
                continue
            }
            if !current.items.isEmpty, !current.fits(item, bounds: bounds) { try close() }
            current.add(item)
            // Over the byte bound on its own: it travels alone.
            if envelope + item.encodedSize > bounds.bytes { try close() }
        }
        try close()
        return (chunks, holds)
    }

    /// The bytes one chunk occupies, tracked as items are added.
    private struct Builder {
        let envelope: Int
        var items: [SyncPushItem] = []
        var bytes: Int
        var perArray: [Slot: Int] = [:]

        init(envelope: Int) {
            self.envelope = envelope
            self.bytes = envelope
        }

        enum Slot: Hashable { case deletedHabits, deletedEntries, deletedGroups, groups, habits, entries }

        static func slot(_ item: SyncPushItem) -> Slot {
            switch item.body {
            case .deletedHabit: return .deletedHabits
            case .deletedEntry: return .deletedEntries
            case .deletedGroup: return .deletedGroups
            case .group: return .groups
            case .habit: return .habits
            case .entry: return .entries
            }
        }

        func added(_ item: SyncPushItem) -> Int {
            let n = perArray[Self.slot(item)] ?? 0
            return bytes + item.encodedSize + (n > 0 ? 1 : 0)   // the comma before it
        }

        func fits(_ item: SyncPushItem, bounds: SyncPushBounds) -> Bool {
            if let kind = item.ref?.kind, (perArray[Self.slot(item)] ?? 0) + 1 > bounds.rowLimit(kind) {
                return false
            }
            return added(item) <= bounds.bytes
        }

        mutating func add(_ item: SyncPushItem) {
            bytes = added(item)
            perArray[Self.slot(item), default: 0] += 1
            items.append(item)
        }
    }

    private static func finish(_ items: [SyncPushItem], bounds: SyncPushBounds, encoder: JSONEncoder) throws -> [SyncPushChunk] {
        var groups: [SyncGroup] = [], habits: [SyncHabit] = [], entries: [SyncEntry] = []
        var deletions = SyncDeletionQueue.Batch()
        for item in items {
            switch item.body {
            case .deletedHabit(let id): deletions.habits.append(id)
            case .deletedEntry(let id): deletions.entries.append(id)
            case .deletedGroup(let id): deletions.groups.append(id)
            case .group(let g): groups.append(g)
            case .habit(let h): habits.append(h)
            case .entry(let e): entries.append(e)
            }
        }
        // Every one of the six arrays is present even when empty: the payload's fields are not
        // optional, so a chunk of one entry still says "no deletions", never "field missing".
        let payload = SyncPushPayload(
            habits: habits, entries: entries, groups: groups,
            deletedHabitIds: deletions.habits, deletedEntryIds: deletions.entries, deletedGroupIds: deletions.groups
        )
        let body = try encoder.encode(payload)
        if body.count > bounds.bytes, items.count > 1 {
            // The arithmetic in `Builder` said it fit. It should never be wrong — a test pins
            // the two equal — but a request over the bound is the failure this type exists to
            // prevent, so split rather than send it.
            let mid = items.count / 2
            let head = try finish(Array(items[..<mid]), bounds: bounds, encoder: encoder)
            let tail = try finish(Array(items[mid...]), bounds: bounds, encoder: encoder)
            return head + tail
        }
        return [SyncPushChunk(items: items, payload: payload, body: body, deletions: deletions)]
    }

    // MARK: Items

    private static func deletionItems(_ batch: SyncDeletionQueue.Batch) -> [SyncPushItem] {
        // Exact strings, de-duplicated: the widget's queue and the app's can both hold one id,
        // and `acknowledge` removes by exact string, so every copy goes with the one sent.
        func items(_ ids: [String], _ make: (String) -> SyncPushItem.Body) -> [SyncPushItem] {
            var seen = Set<String>()
            return ids.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return SyncPushItem(body: make(id), encodedSize: encodedStringSize(id), ref: nil, sentStamp: nil)
            }
        }
        return items(batch.habits, SyncPushItem.Body.deletedHabit)
            + items(batch.entries, SyncPushItem.Body.deletedEntry)
            + items(batch.groups, SyncPushItem.Body.deletedGroup)
    }

    /// JSON size of a string as `JSONEncoder` writes it. The queue holds `uuidString`s — hex and
    /// hyphens, which encode as themselves plus two quotes — so the encoder is asked only about
    /// anything else (30,000 queued ids should not mean 30,000 encoder round trips).
    private static func encodedStringSize(_ s: String) -> Int {
        let plain = s.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
        }
        if plain { return s.utf8.count + 2 }
        return (try? makeEncoder().encode([s]).count - 2) ?? s.utf8.count * 6 + 2
    }

    /// nil when the encoder refuses the row (a non-finite Double): it can never be sent.
    private static func measure<T: Encodable>(_ value: T, _ encoder: JSONEncoder) -> Int? {
        try? encoder.encode(value).count
    }

    private static func emptyEnvelopeSize(_ encoder: JSONEncoder) throws -> Int {
        try encoder.encode(SyncPushPayload(habits: [], entries: [], groups: [],
                                           deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [])).count
    }

    // MARK: Wire mapping
    //
    // What 1.3.0's `SyncService.pushLocal` sent, except the stamps: `createdAt` / `updatedAt`
    // go out with three fractional digits (`millisecondString`), exactly the stamp the store
    // holds, so an acknowledgement and this device's own echo compare equal to it. Written by
    // `SyncWireStamp`, the same strings without a date formatter: a first upload formats two per
    // entry.

    static func wireHabit(_ habit: Habit, stamp: Date) -> SyncHabit {
        SyncHabit(
            id: habit.id.uuidString,
            name: habit.name,
            emoji: habit.emoji,
            colorHex: habit.colorHex,
            isArchived: habit.isArchived,
            // `Int(sortOrder)` traps on NaN or ±infinity; the clamp keeps every finite value the
            // same as before and lets the server refuse the rest as `invalid_value`.
            sortOrder: SafeNumber.wholeNumber(habit.sortOrder, in: Int.min...Int.max),
            reminderEnabled: habit.reminderEnabled,
            reminderHour: habit.reminderHour,
            reminderMinute: habit.reminderMinute,
            note: habit.note,
            kind: habit.kind,
            targetValue: habit.targetValue,
            unit: habit.unit,
            scheduleKind: habit.scheduleKind,
            timesPerWeek: habit.timesPerWeek,
            activeDaysMask: habit.activeDaysMask,
            groupId: habit.groupId?.uuidString,
            createdAt: SyncWireStamp.string(from: habit.createdAt),
            updatedAt: SyncWireStamp.string(from: stamp)
        )
    }

    /// A record has no `createdAt`; the push has always sent its `date` in that place, and its
    /// stamp is `updatedAt ?? date`.
    static func wireEntry(_ record: HabitRecord, habitID: String, stamp: Date) -> SyncEntry {
        SyncEntry(
            id: record.id.uuidString,
            habitId: habitID,
            date: dateOnly.string(from: record.date),
            note: record.note,
            value: record.value,
            createdAt: SyncWireStamp.string(from: record.date),
            updatedAt: SyncWireStamp.string(from: stamp)
        )
    }

    static func wireGroup(_ group: HabitGroup, stamp: Date) -> SyncGroup {
        SyncGroup(
            id: group.id.uuidString,
            name: group.name,
            colorHex: group.colorHex,
            sortOrder: group.sortOrder,
            createdAt: SyncWireStamp.string(from: group.createdAt),
            updatedAt: SyncWireStamp.string(from: stamp)
        )
    }
}

// MARK: - Per-chunk acknowledgement

/// What one chunk's 200 did to the store, for the engine to finish and report.
struct SyncChunkOutcome: Equatable {
    var acknowledged: [SyncRowRef] = []
    /// Holds applied, at the sent stamp — for the Sentry report (`SyncHoldReason.reportsToSentry`)
    /// and the sync diagnostics count.
    var holds: [SyncPlannedHold] = []
    /// Rows the server tombstoned: the engine archives each one to the recovery log, then deletes
    /// it (delete wins). Not deleted here — the archive must be on disk first.
    var drops: [SyncRowRef] = []
    /// Neither acknowledged nor held; sent again next sync.
    var keptPending: [SyncRowRef] = []
    /// Skipped with a reason this build does not know (kept pending) — worth a report.
    var unrecognisedReasons: [SyncRowRef: String] = [:]
    /// The deletion ids this chunk delivered, now removed from the queue.
    var deliveredDeletions = SyncDeletionQueue.Batch()
    /// Acknowledged entries the server keeps under another id (its `aliases`), by sent ref: the
    /// stored id the local record now goes by — or, for one deleted here while the chunk was in
    /// flight, the id queued for deletion with it (review data-safety-4).
    var realigned: [SyncRowRef: String] = [:]
}

@MainActor
enum SyncPushResolver {
    /// The ids the server reported as not written, canonicalised, with the reason where it gave
    /// one. An id in `skippedReasons` but missing from `skipped` counts as skipped too: either
    /// list naming it is the server saying it did not write it.
    static func skippedIDs(in response: SyncPushResponse) -> [SyncRowRef: String?] {
        var out: [SyncRowRef: String?] = [:]
        func add(_ kind: SyncRowKind, _ ids: [String], _ reasons: [String: String]) {
            for id in ids { out[SyncRowRef(kind: kind, id: SyncReconciler.canonicalID(id))] = .some(nil) }
            for (id, reason) in reasons {
                let ref = SyncRowRef(kind: kind, id: SyncReconciler.canonicalID(id))
                // The first reason wins, as on the server, when two spellings of one id differ.
                if case .some(.some) = out[ref] { continue }
                out[ref] = .some(reason)
            }
        }
        let skipped = response.skipped ?? .init()
        let reasons = response.skippedReasons ?? .init()
        add(.group, skipped.groups, reasons.groups)
        add(.habit, skipped.habits, reasons.habits)
        add(.entry, skipped.entries, reasons.entries)
        return out
    }

    /// The server's `aliases`, by canonical sent id: the id kept by the row an applied entry landed
    /// on, the one the server already held for that habit and day (routes/sync.js, "The
    /// incremental-push contract"; review data-safety-4). Left out: an alias that is not a UUID,
    /// which no local record can carry, and one that only respells the sent id.
    static func entryAliases(in response: SyncPushResponse) -> [SyncRowRef: UUID] {
        var out: [SyncRowRef: UUID] = [:]
        for (sent, stored) in response.aliases?.entries ?? [:] {
            guard let storedID = UUID(uuidString: stored) else { continue }
            let ref = SyncRowRef(kind: .entry, id: SyncReconciler.canonicalID(sent))
            if ref.id != storedID.uuidString { out[ref] = storedID }
        }
        return out
    }

    /// The acknowledged rows: the chunk's submitted ids (canonical, de-duplicated) minus every id
    /// in `skipped`. Never derived from `applied`, which holds counts per type, not ids
    /// (routes/sync.js). With the stamp each was sent at.
    static func acknowledged(_ chunk: SyncPushChunk, response: SyncPushResponse) -> [SyncRowRef: Date] {
        let skipped = skippedIDs(in: response)
        var out: [SyncRowRef: Date] = [:]
        for (ref, stamp) in chunk.submitted where skipped[ref] == nil && out[ref] == nil {
            out[ref] = stamp
        }
        return out
    }

    /// Applies a chunk's 200 to the store: acknowledgements, holds, `unknown_habit` strikes, the
    /// deletion queue and the server's aliases. Returns the drops for the engine (recovery log,
    /// then delete).
    ///
    /// Call only for an answer `SyncAnswers.action` mapped to `.proceed`, and only after the run
    /// has re-checked that its owner, token and state generation are still current — an
    /// acknowledgement is true only for the account that gave it. Does not save: the engine saves
    /// once per chunk, so a failure at chunk k leaves chunks < k acknowledged.
    ///
    /// A row deleted locally while its chunk was in flight is simply not found; there is nothing
    /// to acknowledge. Rows sharing a canonical id (`Habit.id` has no uniqueness constraint, and
    /// old id-case bugs made duplicates) are all updated: the server holds one row for that id.
    ///
    /// An acknowledged entry the server keeps under another id (`entryAliases`) takes that id here,
    /// in the chunk's own save (review data-safety-4). Two devices that checked a day before either
    /// pulled the other's check-in hold one server row under two ids, and until the day match of a
    /// later pull renamed it, an uncheck queued an id the server does not hold: the push deleted
    /// nothing, and the next pull brought the day back as the server's row. That pull may never come
    /// first — it can fail, and the user can tap while it is in flight. A record deleted here while
    /// its chunk was in flight has nothing to rename; if its deletion is queued, the stored id is
    /// queued with it, so the uncheck still reaches the row. Neither is done onto an id a local
    /// record already goes by: that day is here twice already (an old duplicate), and following the
    /// alias would put one id on two records.
    static func resolve(
        _ chunk: SyncPushChunk,
        response: SyncPushResponse,
        in context: ModelContext,
        deletionQueue: SyncDeletionQueue,
        strikes: SyncUnknownHabitStrikes
    ) throws -> SyncChunkOutcome {
        let skipped = skippedIDs(in: response)
        let aliases = entryAliases(in: response)
        let aliasTargets = aliases.values.map { SyncRowRef(kind: .entry, id: $0.uuidString) }
        let index = try RowIndex(context, kinds: Set(chunk.submitted.map(\.ref.kind)).union(
            chunk.payload.entries.isEmpty ? [] : [.habit]),
            entries: chunk.submitted.map(\.ref).filter { $0.kind == .entry } + aliasTargets)
        var outcome = SyncChunkOutcome()
        var handled = Set<SyncRowRef>()
        var clearedStrikes: [String] = []
        // Ids a local record goes by, or has just been given: no alias gives one a second record.
        var takenIDs = Set(aliasTargets.filter { !index.rows($0).isEmpty })
        var queuedEntries: Set<String>?

        func followAlias(of ref: SyncRowRef, rows: [any SyncDeliverable]) {
            guard let stored = aliases[ref] else { return }
            let target = SyncRowRef(kind: .entry, id: stored.uuidString)
            guard !takenIDs.contains(target) else { return }
            let records = rows.compactMap { $0 as? HabitRecord }
            if records.isEmpty {
                // Read once, and only here: deleting a multi-year habit queues thousands of ids.
                let queued = queuedEntries ?? Set(deletionQueue.pending().entries.map(SyncReconciler.canonicalID))
                queuedEntries = queued
                guard queued.contains(ref.id) else { return }
                deletionQueue.trackEntry(stored.uuidString)
            } else {
                records.forEach { $0.id = stored }
            }
            takenIDs.insert(target)
            outcome.realigned[ref] = stored.uuidString
        }

        for item in chunk.items {
            guard let ref = item.ref, let sent = item.sentStamp, handled.insert(ref).inserted else { continue }
            let rows = index.rows(ref)
            let wasSkipped = skipped[ref] != nil
            let reason = skipped[ref] ?? nil

            var facts = SyncRowFacts(isRestored: rows.contains { $0.restoredAt != nil })
            if ref.kind == .entry, case let .entry(entry) = item.body {
                let habitRef = SyncRowRef(kind: .habit, id: SyncReconciler.canonicalID(entry.habitId))
                let habitRows = index.rows(habitRef)
                facts.habitAcknowledged = habitRows.contains { $0.hasBeenDelivered }
                // Read after the habit's own answer: habits come before entries in a chunk, as in
                // the plan, so a hold this loop has just applied is seen (`hold` leaves
                // `restoredAt`), as is one from an earlier sync (review delivery-1).
                facts.habitKeptForRestore = habitRows.contains { $0.restoredAt != nil || $0.activeHold == .tombstoned }
                facts.priorUnknownHabitStrikes = strikes.strikes(for: ref.id)
            }

            switch SyncAnswers.rowAction(skipped: wasSkipped, reason: reason, facts: facts) {
            case .acknowledge:
                rows.forEach { $0.acknowledge(sentStamp: sent) }
                outcome.acknowledged.append(ref)
                if ref.kind == .entry {
                    clearedStrikes.append(ref.id)
                    followAlias(of: ref, rows: rows)
                }
            case .hold(let holdReason):
                // At the SENT stamp: an edit made while the chunk was in flight is a new value
                // and gets its own chance.
                rows.forEach { $0.hold(holdReason, sentStamp: sent) }
                outcome.holds.append(SyncPlannedHold(ref: ref, reason: holdReason, stamp: sent))
                if ref.kind == .entry { clearedStrikes.append(ref.id) }
            case .drop:
                outcome.drops.append(ref)
                if ref.kind == .entry { clearedStrikes.append(ref.id) }
            case .keepPending:
                outcome.keptPending.append(ref)
                if ref.kind == .entry {
                    if SyncAnswers.countsUnknownHabitStrike(reason: reason, facts: facts) {
                        strikes.record(ref.id)
                    } else if reason != SyncSkipReason.unknownHabit.rawValue {
                        // The streak is "three syncs in a row"; any other answer ends it.
                        clearedStrikes.append(ref.id)
                    }
                }
                if let reason, SyncSkipReason(rawValue: reason) == nil {
                    outcome.unrecognisedReasons[ref] = reason
                } else if wasSkipped, reason == nil {
                    outcome.unrecognisedReasons[ref] = ""
                }
            }
        }

        strikes.clear(clearedStrikes)
        // Only the deletion ids this chunk carried, and only now that it was answered 200. A
        // deletion queued while it was in flight stays for the next sync.
        deletionQueue.acknowledge(chunk.deletions)
        outcome.deliveredDeletions = chunk.deletions
        return outcome
    }

    /// Applies holds the planner decided (`SyncPushPlan.holds`) or a one-row 413
    /// (`holdTooLarge(_:in:)`). Does not save.
    static func apply(_ holds: [SyncPlannedHold], in context: ModelContext) throws {
        guard !holds.isEmpty else { return }
        let index = try RowIndex(context, kinds: Set(holds.map(\.ref.kind)),
                                 entries: holds.map(\.ref).filter { $0.kind == .entry })
        for hold in holds {
            index.rows(hold.ref).forEach { $0.hold(hold.reason, sentStamp: hold.stamp) }
        }
    }

    /// `413` on a one-row chunk: hold that row `too_large` at the stamp that was sent. Returns
    /// the hold (empty if the chunk carried no row).
    @discardableResult
    static func holdTooLarge(_ chunk: SyncPushChunk, in context: ModelContext) throws -> [SyncPlannedHold] {
        let holds = chunk.submitted.map { SyncPlannedHold(ref: $0.ref, reason: .tooLarge, stamp: $0.sentStamp) }
        try apply(holds, in: context)
        return holds
    }

    /// The store's rows by canonical id, for the kinds a chunk touched: every group and habit
    /// (a few hundred at most), and of the records only those the chunk names — fetched by id.
    /// Up to the M2 slice every record was fetched for every chunk, so a first upload of n
    /// entries read n × n / 2,000 rows: 28.5 s on the main actor for 20,000 (rehearsal S12).
    private struct RowIndex {
        private var byRef: [SyncRowRef: [any SyncDeliverable]] = [:]

        init(_ context: ModelContext, kinds: Set<SyncRowKind>, entries: [SyncRowRef] = []) throws {
            if kinds.contains(.group) { add(.group, try context.fetch(FetchDescriptor<HabitGroup>())) }
            if kinds.contains(.habit) { add(.habit, try context.fetch(FetchDescriptor<Habit>())) }
            if kinds.contains(.entry) {
                // Refs are canonical `uuidString`s, so each parses back to the id it came from;
                // every record with that id comes back, duplicates included.
                let ids = entries.compactMap { UUID(uuidString: $0.id) }
                add(.entry, try context.fetch(FetchDescriptor<HabitRecord>(predicate: #Predicate { ids.contains($0.id) })))
            }
        }

        private mutating func add<Row: SyncDeliverable>(_ kind: SyncRowKind, _ rows: [Row]) {
            for row in rows { byRef[SyncRowRef(kind: kind, id: row.id.uuidString), default: []].append(row) }
        }

        func rows(_ ref: SyncRowRef) -> [any SyncDeliverable] { byRef[ref] ?? [] }
    }
}
