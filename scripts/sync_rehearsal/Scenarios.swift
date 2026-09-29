import Foundation
import SwiftData

// M2's rehearsal scenarios — DEV-PLAN-1.3.md M2, Acceptance (1), (6) and the non-UI half of (9)
// — each on fresh accounts against the local server, each asserted, none relaxed. The account
// screen of Acceptance (5) is driven at the engine level (S21/S22, AccountScenarios.swift: its
// buttons' operations are Shared/ code). What needs the phase C UI itself (Today's reauth row
// and "sync paused" line) is reported SKIPPED with the reason, never as PASS. Since phase B the devices keep the
// app's recovery-log FILE and per-owner backoff, and the server runs with its test hooks (the
// swept-tombstone switch).

// MARK: - Report

enum Verdict: String {
    case pass = "PASS", fail = "FAIL", skipped = "SKIPPED"
}

struct Check {
    var scenario: String
    var name: String
    var verdict: Verdict
    var detail: String
}

@MainActor
final class Report {
    private(set) var checks: [Check] = []
    var current = ""

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        let c = Check(scenario: current, name: name, verdict: ok ? .pass : .fail, detail: detail())
        checks.append(c)
        print("  \(c.verdict.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(name) — \(c.detail)")
    }

    func skip(_ name: String, _ why: String) {
        checks.append(Check(scenario: current, name: name, verdict: .skipped, detail: why))
    }

    var failed: Bool { checks.contains { $0.verdict == .fail } }
}

// MARK: - Helpers

enum Scenario {
    /// Noon UTC, so `HabitCalendar.dayKey` lands on the same calendar day in every time zone
    /// from UTC−11 to UTC+11 (UTC+9 hides date bugs — feedback on Stride's blind spots).
    static let day0 = HabitCalendar.utc.date(from: DateComponents(year: 2023, month: 1, day: 1, hour: 12))!
    static func day(_ n: Int) -> Date { day0.addingTimeInterval(Double(n) * 86_400) }
}

func describe(_ outcome: SyncRunOutcome) -> String {
    switch outcome {
    case .synced: return "synced"
    case .blocked(let r): return "blocked(\(r))"
    case .stopped(let r, _): return "stopped(\(r))"
    }
}

func isSynced(_ outcome: SyncRunOutcome) -> Bool {
    if case .synced = outcome { return true }
    return false
}

func describe(_ exchanges: [Exchange]) -> String {
    exchanges.map { e in
        let s = e.injected ? "injected" : e.answerLost ? "\(e.status.map(String.init) ?? "-")/lost" : (e.status.map(String.init) ?? "none")
        switch e.endpoint {
        case .push: return "push[\(e.pushed) \(e.requestBytes)B → \(s)]"
        case .pull: return "pull[\(e.since == nil ? "full" : "since") → \(s)]"
        }
    }.joined(separator: " ")
}

func describe(_ marks: SyncMarksVerdict?) -> String {
    switch marks {
    case nil: return "not asked"
    case .proven(let ref)?: return "proven by \(ref.kind) \(ref.id.prefix(8))"
    case .forgotten(let c)?: return "forgotten (\(c.groups)g/\(c.habits)h/\(c.records)e)"
    case .undecided?: return "undecided"
    }
}

func pushes(_ exchanges: [Exchange]) -> [Exchange] { exchanges.filter { $0.endpoint == .push } }

func totalPushed(_ exchanges: [Exchange]) -> WireCounts {
    pushes(exchanges).reduce(into: WireCounts()) { acc, e in
        acc.habits += e.pushed.habits; acc.entries += e.pushed.entries
        acc.groups += e.pushed.groups; acc.deletions += e.pushed.deletions
        acc.wholeSecondStamps += e.pushed.wholeSecondStamps
    }
}

/// Waits until the wall clock is 50–300 ms into a second, so two edits 300 ms apart share one
/// whole second: the case a whole-second wire resolves by push order instead of by time.
func waitUntilEarlyInASecond() async {
    while true {
        let ms = Int(SyncTimestamp.milliseconds(Date()) % 1000)
        if ms >= 50 && ms < 300 { return }
        let wait = (1050 - ms) % 1000
        try? await Task.sleep(nanoseconds: UInt64(max(wait, 5)) * 1_000_000)
    }
}

/// Waits past the next whole-second boundary: an edit after it is later than every earlier
/// edit even at a snapshot device's whole-second precision.
func waitForNextWholeSecond() async {
    let ms = Int(SyncTimestamp.milliseconds(Date()) % 1000)
    try? await Task.sleep(nanoseconds: UInt64(1_000 - ms + 20) * 1_000_000)
}

// MARK: - Scenarios

@MainActor
struct Scenarios {
    let report: Report

    // S1 — delivery state: a second sync pushes nothing; a device that only pulled pushes nothing.
    func deliveryState() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        a.habit("Read", days: [0, 1, 2])
        a.habit("Run", days: [0])
        a.habit("Stretch")
        try a.save()

        let first = await a.sync()
        let ex1 = a.transport.exchanges
        let order = ex1.map { $0.endpoint == .push ? "push" : ($0.since == nil ? "full-pull" : "pull") }
        report.check("first sync: full pull → one push of every row (ms stamps) → pull",
                     isSynced(first) && order == ["full-pull", "push", "pull"]
                        && ex1.allSatisfy { $0.status == 200 }
                        && pushes(ex1).first?.pushed == { var w = WireCounts(); w.habits = 3; w.entries = 4; return w }(),
                     describe(ex1))

        let mark = a.transport.mark()
        let second = await a.sync()
        let ex2 = a.transport.since(mark)
        report.check("second sync with no edits pushes 0/0/0",
                     isSynced(second) && pushes(ex2).isEmpty && second.summary?.pushedRows.total == 0,
                     "\(describe(second)); requests: \(describe(ex2))")

        let bFirst = await b.sync()
        let bMark = b.transport.mark()
        let bSecond = await b.sync()
        let same = try a.digest().difference(from: b.digest())
        report.check("a device that only pulled pushes 0/0/0 (first and second sync) and holds A's rows",
                     isSynced(bFirst) && isSynced(bSecond) && pushes(b.transport.exchanges).isEmpty && same == nil,
                     "B first: \(describe(b.transport.exchanges.prefix(bMark).map { $0 })); B second: \(describe(b.transport.since(bMark))); stores \(same ?? "equal")")

        // S2 — one tap.
        report.current = "S2 one tap"
        let bRead = try unwrap(b.habits().first { $0.name == "Read" }, "B has Read")
        try b.tapAndSave(bRead, day: 3)
        let tapMark = b.transport.mark()
        let tap = await b.sync()
        let tapPushes = pushes(b.transport.since(tapMark))
        let one = tapPushes.first
        report.check("one tap → the next push carries exactly 1 entry and 0 habits",
                     isSynced(tap) && tapPushes.count == 1 && one?.pushed.entries == 1 && one?.pushed.habits == 0
                        && one?.pushed.groups == 0 && one?.pushed.deletions == 0 && one?.status == 200,
                     describe(b.transport.since(tapMark)))
        report.check("…and that request is small (bytes counted on the wire)",
                     (one?.requestBytes ?? .max) < 1_024,
                     "\(one?.requestBytes ?? -1) bytes (A's 1.3.0-style snapshot of the same store would carry every row)")

        try b.tapAndSave(bRead, day: 3)   // untap: deletes the record, queues its tombstone
        let untapMark = b.transport.mark()
        let untap = await b.sync()
        let untapPushes = pushes(b.transport.since(untapMark))
        report.check("untap → the next push carries 0 rows and exactly 1 deletion id",
                     isSynced(untap) && untapPushes.count == 1 && untapPushes.first?.pushed.rows == 0
                        && untapPushes.first?.pushed.deletions == 1 && b.queue.pending().isEmpty,
                     describe(b.transport.since(untapMark)))

        try b.tapAndSave(bRead, day: 4)
        _ = await b.sync()
        _ = await a.sync()
        let converged = try a.digest().difference(from: b.digest())
        let server = StoreDigest(pull: try await serverSnapshot(account))
        report.check("A and B converge on the server's rows after the taps",
                     try converged == nil && (try a.digest()).difference(from: server) == nil,
                     converged ?? "A = B = server (\(server.summary))")
    }

    // S3 — a 2,500-entry first upload.
    func firstUpload2500() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account)
        defer { a.remove() }
        for i in 0..<5 { a.habit("Habit \(i)", days: Array(0..<500)) }
        try a.save()

        let started = Date()
        let outcome = await a.sync()
        let seconds = Date().timeIntervalSince(started)
        let ex = a.transport.exchanges
        let p = pushes(ex)
        let total = totalPushed(ex)
        report.check("2,500-entry first upload completes in 2 push requests",
                     isSynced(outcome) && p.count == 2 && p.allSatisfy { $0.status == 200 }
                        && total.entries == 2_500 && total.habits == 5,
                     "\(describe(ex)); \(String(format: "%.1f", seconds)) s")
        report.check("…with no 429 (server at the production limit, 60 sync requests / min / account)",
                     !ex.contains { $0.status == 429 }, "statuses \(ex.map { $0.status.map(String.init) ?? "none" })")
        let server = try await serverSnapshot(account)
        report.check("…and the server holds all of it, nothing left pending",
                     try server.totals == SyncTotals(habits: 5, entries: 2_500, groups: 0) && (try a.pendingCount()) == 0,
                     "server totals \(server.totals.map { "\($0.habits)h/\($0.entries)e" } ?? "none"), pending \((try? a.pendingCount()) ?? -1)")
    }

    // S4 — 2,000 entries with 2 KB notes: bounded by bytes, not only rows.
    func notes2KB() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account)
        defer { a.remove() }
        // ~2 KB of UTF-8 per note, multi-byte characters included: the bound is on encoded
        // bytes, and "日記 ✓" is 3 bytes a character.
        let unit = "Stride 日記 ✓ — a long note about the day. "
        func note(_ day: Int) -> String {
            var s = "day \(day): "
            while s.utf8.count < 2_048 { s += unit }
            return s
        }
        for i in 0..<4 { a.habit("Journal \(i)", days: Array(0..<500), note: note) }
        try a.save()

        let outcome = await a.sync()
        let ex = a.transport.exchanges
        let p = pushes(ex)
        let largest = p.map(\.requestBytes).max() ?? 0
        let total = totalPushed(ex)
        report.check("2,000 entries with 2 KB notes → no request over 1 MB",
                     isSynced(outcome) && largest <= 1_000_000 && p.allSatisfy { $0.status == 200 }
                        && total.entries == 2_000 && total.habits == 4,
                     "\(p.count) pushes, largest \(largest) bytes; \(describe(ex))")
        let server = try await serverSnapshot(account)
        let intact = server.entries.allSatisfy { ($0.note?.utf8.count ?? 0) >= 2_048 }
        report.check("…and every note arrived whole",
                     server.totals?.entries == 2_000 && intact,
                     "server totals entries \(server.totals?.entries ?? -1), notes intact: \(intact)")
    }

    // S5 — a failure at chunk 2.
    func failureAtChunk2() async throws {
        for fault in [HTTPTransport.PushFault.failBeforeSending, .loseAnswer] {
            let label = fault == .failBeforeSending ? "chunk 2 never reaches the server" : "chunk 2's answer is lost"
            let account = try Account.create()
            let a = Device131("A", account: account)
            defer { a.remove() }
            for i in 0..<3 { a.habit("Habit \(i)", days: Array(0..<1_000)) }   // 3 habits + 3,000 entries
            try a.save()

            a.transport.pushFault = { $0 == 2 ? fault : nil }
            let failed = await a.sync()
            let ex1 = a.transport.exchanges
            let pendingAfter = try a.pendingCount()
            var stoppedTransient = false
            if case .stopped(.backOff(.transient, _), _) = failed { stoppedTransient = true }
            report.check("\(label): the run stops, chunk 1 is acknowledged, chunk 2 stays pending",
                         stoppedTransient && pushes(ex1).count == 2 && pushes(ex1)[0].status == 200
                            && pendingAfter == pushes(ex1)[1].pushed.rows && pendingAfter > 0,
                         "\(describe(failed)); \(describe(ex1)); pending \(pendingAfter)")

            a.transport.pushFault = nil
            let mark = a.transport.mark()
            let retry = await a.sync()
            let ex2 = a.transport.since(mark)
            let resent = totalPushed(ex2)
            let server = try await serverSnapshot(account)
            report.check("\(label): the retry sends only chunk 2, and the server ends with every row once",
                         try isSynced(retry) && pushes(ex2).count == 1 && resent.rows == pendingAfter && resent.habits == 0
                            && server.totals == SyncTotals(habits: 3, entries: 3_000, groups: 0) && (try a.pendingCount()) == 0,
                         "\(describe(ex2)); server \(server.totals.map { "\($0.habits)h/\($0.entries)e" } ?? "none")")
        }
    }

    // S6 — a row_error row is held; the rest lands; the hold survives a full pull.
    func rowError() async throws {
        try Account.installRowErrorTrigger()
        let account = try Account.create()
        let a = Device131("A", account: account)
        defer { a.remove() }
        let habit = a.habit("Journal", days: [0, 1, 2, 3, 4], note: { $0 == 2 ? "REHEARSAL_ROW_ERROR" : nil })
        try a.save()

        let first = await a.sync()
        let held = try unwrap(a.record(of: habit.id, day: 2), "the marked record")
        var server = try await serverSnapshot(account)
        report.check("a row_error row is held; the rest of its chunk lands",
                     try isSynced(first) && held.activeHold == .rowError && (try a.pendingCount()) == 0
                        && server.totals == SyncTotals(habits: 1, entries: 4, groups: 0),
                     "\(describe(first)); hold \(held.activeHold?.rawValue ?? "none"); server \(server.totals.map { "\($0.habits)h/\($0.entries)e" } ?? "none"); \(describe(a.transport.exchanges))")

        a.cursor = nil
        let fullMark = a.transport.mark()
        let full = await a.sync()
        let exFull = a.transport.since(fullMark)
        let survived = try a.record(of: habit.id, day: 2)
        report.check("the held row survives the next full pull and is not sent again",
                     isSynced(full) && exFull.first?.since == nil && exFull.first?.endpoint == .pull
                        && survived?.activeHold == .rowError && pushes(exFull).isEmpty,
                     "\(describe(exFull)); held row \(survived == nil ? "GONE" : "kept, \(survived?.activeHold?.rawValue ?? "not held")")")

        try a.tapAndSave(habit, day: 5)
        let tapMark = a.transport.mark()
        _ = await a.sync()
        let exTap = a.transport.since(tapMark)
        report.check("an unrelated edit's push carries that edit only, not the held row",
                     pushes(exTap).count == 1 && pushes(exTap)[0].pushed.entries == 1,
                     describe(exTap))

        held.note = "fixed by hand"
        held.touch()
        try a.save()
        let editMark = a.transport.mark()
        let edited = await a.sync()
        let exEdit = a.transport.since(editMark)
        server = try await serverSnapshot(account)
        report.check("editing the held row lifts the hold; it is sent once and lands",
                     try isSynced(edited) && pushes(exEdit).count == 1 && pushes(exEdit)[0].pushed.entries == 1
                        && held.activeHold == nil && (try a.pendingCount()) == 0 && server.totals?.entries == 6,
                     "\(describe(exEdit)); server entries \(server.totals?.entries ?? -1)")
    }

    // S7 — two 1.3.1 devices + a 1.2.3- and a 1.3.0-shaped snapshot device, interleaved.
    func mixedFleet() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        let l = SnapshotDevice("L(1.2.3)", shape: .v123, account: account)
        let m = SnapshotDevice("M(1.3.0)", shape: .v130, account: account)
        defer { a.remove(); b.remove(); l.remove(); m.remove() }

        func named(_ d: StoreDevice, _ name: String) throws -> Habit {
            try unwrap(d.habits().first { $0.name == name }, "\(d.name) has \(name)")
        }
        var statuses: [String] = []
        func snap(_ d: SnapshotDevice) async throws {
            let r = try await d.sync()
            statuses.append("\(d.name):\(r.push.map(String.init) ?? "-")/\(r.pull.map(String.init) ?? "-")")
        }

        // 1. A starts the account.
        let aRun = a.habit("Run", days: [0, 1])
        a.habit("Read", days: [0, 1])
        try a.save()
        _ = await a.sync()
        // 2. Everyone else joins.
        try await snap(l); try await snap(m); _ = await b.sync()
        // 3. 1.2.3: a new habit, a tap, an untap (a deleted entry).
        l.habit("Legacy", days: [2])
        try l.tapAndSave(try named(l, "Read"), day: 2)
        try l.tapAndSave(try named(l, "Run"), day: 0)
        try await snap(l)
        // 4. 1.3.0: a rename, a tap, a group — in a later whole second than A's creation of
        //    Read, so the rename is newer even at 1.3.0's whole-second precision (the
        //    same-second case is the documented limit, checked on its own below).
        await waitForNextWholeSecond()
        let mRead = try named(m, "Read")
        let group = HabitGroup(name: "Health")
        m.context.insert(group)
        mRead.name = "Read books"
        mRead.groupId = group.id
        mRead.touch()
        try m.tapAndSave(try named(m, "Run"), day: 3)
        try await snap(m)
        // 5. B deletes Run, taps Read.
        try b.deleteHabit(try named(b, "Run"))
        try b.tapAndSave(try named(b, "Read"), day: 3)
        _ = await b.sync()
        // 6. A, offline since step 1: checks Run in (a habit B deleted meanwhile) and Read.
        let offline = try a.tapAndSave(aRun, day: 5)
        let offlineID = try unwrap(aRun.record(on: Scenario.day(5))?.id, "A's offline record")
        _ = offline
        try a.tapAndSave(try named(a, "Read"), day: 4)
        _ = await a.sync()
        // 7. Two rounds for everyone.
        var finalMarks: [String: Int] = [:]
        var lastL = 0, lastM = 0
        for round in 0..<2 {
            if round == 1 {
                finalMarks = ["A": a.transport.mark(), "B": b.transport.mark()]
                lastL = l.transport.mark(); lastM = m.transport.mark()
            }
            _ = await a.sync(); _ = await b.sync()
            try await snap(l); try await snap(m)
        }

        let server = StoreDigest(pull: try await serverSnapshot(account))
        var diffs: [String] = []
        for d in [a, b, l, m] as [StoreDevice] {
            if let diff = try d.digest().difference(from: server) { diffs.append("\(d.name): \(diff)") }
        }
        report.check("two 1.3.1 devices + 1.2.3- and 1.3.0-shaped snapshot devices converge after interleaved edits/deletes",
                     diffs.isEmpty && server.habits.count == 2 && server.groups.count == 1,
                     diffs.isEmpty ? "all four = server (\(server.summary)); snapshot syncs \(statuses.joined(separator: " "))" : diffs.joined(separator: "; "))

        let names = try [a, b, l, m].map { try $0.habits().map(\.name).sorted() }
        report.check("the 1.3.0 device's rename survived the 1.2.3 device's stale snapshot echo (LWW + re-feed)",
                     names.allSatisfy { $0 == ["Legacy", "Read books"] },
                     "habit names per device: \(names)")

        let archived = a.logItems().contains { $0.ref == SyncRowRef(kind: .entry, id: offlineID.uuidString) }
        report.check("a habit deleted on B while checked in offline on A is gone from A, and A's recovery log holds the check-in",
                     (try a.habits()).allSatisfy { $0.name != "Run" } && archived,
                     "A's log: \(a.logItems().map { "\($0.reason.rawValue) \($0.ref.kind)" })")

        let finalA = pushes(a.transport.since(finalMarks["A"] ?? 0)), finalB = pushes(b.transport.since(finalMarks["B"] ?? 0))
        let lFinal = pushes(l.transport.since(lastL)).last, mFinal = pushes(m.transport.since(lastM)).last
        let lRows = try l.digest(), mRows = try m.digest()
        report.check("once converged the 1.3.1 devices push nothing; the snapshot devices still push their whole store",
                     finalA.isEmpty && finalB.isEmpty
                        && lFinal?.pushed.entries == lRows.entries.count && lFinal?.pushed.habits == lRows.habits.count
                        && mFinal?.pushed.entries == mRows.entries.count && mFinal?.pushed.habits == mRows.habits.count,
                     "A \(finalA.count) pushes, B \(finalB.count); L pushed \(lFinal?.pushed.description ?? "-"), M pushed \(mFinal?.pushed.description ?? "-")")

        // The documented limit (M2, "Millisecond edit stamps"): an older app's edit is only as
        // precise as its string. A 1.3.0 edit made 300 ms AFTER a 1.3.1 edit in the same second
        // is sent as :x.000 and loses. What must hold is that the fleet still ends on ONE value.
        let aRead = try named(a, "Read books"), mRead2 = try named(m, "Read books")
        await waitUntilEarlyInASecond()
        aRead.note = "note from A (1.3.1)"
        aRead.touch()
        try a.save()
        try await Task.sleep(nanoseconds: 300_000_000)
        mRead2.note = "note from M (1.3.0), 300 ms later"
        mRead2.touch()
        try m.save()
        let sameSecond = floor(aRead.stamp.timeIntervalSince1970) == floor(mRead2.stamp.timeIntervalSince1970)
        _ = await a.sync(); try await snap(m); _ = await b.sync(); try await snap(l); _ = await a.sync(); try await snap(m)
        let serverNote = try await serverSnapshot(account).habits.first { $0.name == "Read books" }?.note
        let notes = try [a, b, l, m].map { try named($0, "Read books").note ?? "" }
        report.check("documented limit: a 1.3.0 edit 300 ms after a 1.3.1 edit in the same second loses, and all four still end on one value",
                     sameSecond && serverNote == "note from A (1.3.1)" && notes.allSatisfy { $0 == serverNote },
                     "same second: \(sameSecond); server \"\(serverNote ?? "-")\"; devices \(notes)")

        let aStamps = totalPushed(a.transport.exchanges).wholeSecondStamps + totalPushed(b.transport.exchanges).wholeSecondStamps
        let lStamps = pushes(l.transport.exchanges).allSatisfy { $0.pushed.wholeSecondStamps == 2 * $0.pushed.rows }
        report.check("stamps on the wire: 1.3.1 sends milliseconds, the snapshot devices whole seconds",
                     aStamps == 0 && lStamps, "1.3.1 whole-second stamps: \(aStamps); snapshot pushes all whole seconds: \(lStamps)")
    }

    // S8 — two edits of one entry 300 ms apart on two devices.
    func editsThreeHundredMsApart() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let habit = a.habit("Water", days: [0, 1])
        try a.save()
        _ = await a.sync(); _ = await b.sync()

        // The pull format first: without milliseconds on the pull, the rest cannot pass.
        let pulled131 = try await rawPull(account, clientHeader: Rehearsal.client131)
        let pulled130 = try await rawPull(account, clientHeader: Rehearsal.client130)
        let pulledNone = try await rawPull(account, clientHeader: nil)
        func stamps(_ json: [String: Any]) -> [String] {
            ((json["entries"] as? [[String: Any]]) ?? []).compactMap { $0["updatedAt"] as? String }
                + ((json["habits"] as? [[String: Any]]) ?? []).compactMap { $0["updatedAt"] as? String }
        }
        let ms131 = stamps(pulled131), ms130 = stamps(pulled130), msNone = stamps(pulledNone)
        report.check("pull stamps: ios/1.3.1(19) gets milliseconds; ios/1.3.0(18) and no header get whole seconds",
                     !ms131.isEmpty && ms131.allSatisfy(WireCounts.hasMilliseconds)
                        && !ms130.isEmpty && ms130.allSatisfy { !$0.contains(".") }
                        && !msNone.isEmpty && msNone.allSatisfy { !$0.contains(".") },
                     "1.3.1: \(ms131.first ?? "-"), 1.3.0: \(ms130.first ?? "-"), none: \(msNone.first ?? "-")")

        for (day, laterPushesFirst) in [(0, true), (1, false)] {
            let label = laterPushesFirst ? "the later edit pushes first" : "the earlier edit pushes first"
            let aRecord = try unwrap(a.record(of: habit.id, day: day), "A's record")
            let bRecord = try unwrap(b.record(of: habit.id, day: day), "B's record")
            await waitUntilEarlyInASecond()
            aRecord.note = "earlier edit (A)"
            aRecord.touch()
            try a.save()
            try await Task.sleep(nanoseconds: 300_000_000)
            bRecord.note = "later edit (B)"
            bRecord.touch()
            try b.save()
            let aStamp = aRecord.stamp, bStamp = bRecord.stamp
            let sameSecond = floor(aStamp.timeIntervalSince1970) == floor(bStamp.timeIntervalSince1970)

            let order: [Device131] = laterPushesFirst ? [b, a, b, a] : [a, b, a, b]
            for d in order { _ = await d.sync() }
            let server = try await serverSnapshot(account)
            let serverNote = server.entries.first { $0.date == HabitCalendar.dayStringFormatter.string(from: Scenario.day(day)) }?.note
            report.check("two edits of one entry 300 ms apart (same second) end as the later edit — \(label)",
                         try sameSecond && aRecord.note == "later edit (B)" && bRecord.note == "later edit (B)"
                            && serverNote == "later edit (B)" && (try a.pendingCount()) == 0 && (try b.pendingCount()) == 0,
                         "stamps \(SyncTimestamp.millisecondString(from: aStamp)) / \(SyncTimestamp.millisecondString(from: bStamp)); A \"\(aRecord.note ?? "")\", B \"\(bRecord.note ?? "")\", server \"\(serverNote ?? "")\"; A pending \((try? a.pendingCount()) ?? -1)")
        }
    }

    // S9 — a device whose clock runs 10 min slow loses an edit and ends with the winner's value.
    func skewedClock() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), s = Device131("S(-10 min)", account: account)
        defer { a.remove(); s.remove() }
        let habit = a.habit("Plan")
        try a.save()
        _ = await a.sync(); _ = await s.sync()

        habit.name = "Winner"
        habit.touch()
        try a.save()
        _ = await a.sync()
        _ = await s.sync()
        // The case the re-feed exists for: S's cursor is already PAST the winner's server
        // `updated_at`. In a run this fast the 60 s cursor overlap would bring the winner back by
        // itself and hide a missing re-feed (a scratch server without it passed this check). One
        // machine, one clock: a cursor of "now" is what S stores after any sync a minute or more
        // after A's edit.
        try await Task.sleep(nanoseconds: 20_000_000)
        s.cursor = SyncTimestamp.millisecondString(from: Date())
        let sHabit = try unwrap(s.habit(id: habit.id), "S has the habit")
        // S's clock is 10 minutes slow: its edit is stamped before A's, though made after it.
        sHabit.name = "Loser"
        sHabit.updatedAt = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-600))
        try s.save()
        let mark = s.transport.mark()
        let outcome = await s.sync()
        _ = await a.sync()
        let server = try await serverSnapshot(account)
        report.check("a device whose clock runs 10 min slow and loses an edit ends with the winner's value (LWW re-feed)",
                     try isSynced(outcome) && sHabit.name == "Winner" && habit.name == "Winner"
                        && server.habits.first?.name == "Winner" && (try s.pendingCount()) == 0,
                     "S shows \"\(sHabit.name)\", A \"\(habit.name)\", server \"\(server.habits.first?.name ?? "-")\"; S: \(describe(s.transport.since(mark)))")
    }

    // S10 — a truncated full pull deletes nothing.
    func truncatedFullPull() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let habit = a.habit("Piano", days: Array(0..<6))
        try a.save()
        _ = await a.sync(); _ = await b.sync()
        habit.name = "Piano (renamed)"
        habit.touch()
        try a.save()
        _ = await a.sync()

        // A body cut short (a proxy, a timed-out query): three entries missing, `totals` intact.
        b.cursor = nil
        b.transport.transformPull = { since, response in
            guard since == nil, response.status == 200,
                  var json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  var entries = json["entries"] as? [Any] else { return response }
            entries.removeLast(min(3, entries.count))
            json["entries"] = entries
            var cut = response
            cut.body = (try? JSONSerialization.data(withJSONObject: json)) ?? response.body
            return cut
        }
        let outcome = await b.sync()
        b.transport.transformPull = nil
        let bHabit = try b.habit(id: habit.id)
        let issues = outcome.summary?.pullIssues.map(\.reason.rawValue) ?? []
        report.check("a truncated full pull (totals ≠ arrays) deletes nothing, and its upserts still apply",
                     bHabit?.records.count == 6 && bHabit?.name == "Piano (renamed)"
                        && outcome.summary?.deletionPassSkipped == true && issues.contains("totals_mismatch"),
                     "\(describe(outcome)); B keeps \(bHabit?.records.count ?? 0) records, name \"\(bHabit?.name ?? "-")\"; issues \(issues)")

        // Control: the same full pull, whole, does delete a row another device deleted — so the
        // check above is the validation at work, not a deletion pass that never runs.
        try a.tapAndSave(habit, day: 0)   // untap on A: delete + tombstone
        _ = await a.sync()
        b.cursor = nil
        let control = await b.sync()
        report.check("control: an intact full pull removes the row another device deleted",
                     try isSynced(control) && (try b.habit(id: habit.id))?.records.count == 5
                        && control.summary?.deletionPassSkipped == false,
                     "B has \((try? b.habit(id: habit.id))??.records.count ?? -1) records")
    }

    // S11 — a sign-in to another account between two chunks.
    func runBinding() async throws {
        let x = try Account.create(), y = try Account.create()
        let a = Device131("A", account: x)
        defer { a.remove() }
        for i in 0..<3 { a.habit("Habit \(i)", days: Array(0..<1_000)) }
        try a.save()
        let queued = UUID().uuidString
        a.queue.trackEntry(queued)
        let rows = try a.pendingCount()

        var cursorAtSwitch: String?? = .none
        a.transport.afterPush = { [a] n in
            guard n == 1 else { return }
            cursorAtSwitch = .some(a.cursor)
            // Signed out of X and into Y while chunk 1 was in flight.
            a.gate.state = .ready(SyncRunBinding(ownerID: y.owner, token: y.token, generation: 1))
        }
        let outcome = await a.sync()
        let ex = a.transport.exchanges
        let yServer = try await serverSnapshot(y)
        report.check("a sign-in to another account between two chunks sends no further chunk and acknowledges nothing",
                     try outcome == .stopped(.bindingChanged, outcome.summary ?? SyncRunSummary())
                        && pushes(ex).count == 1 && !ex.contains { $0.token == y.token }
                        && (try a.pendingCount()) == rows && a.queue.pending().entries.contains(queued)
                        && cursorAtSwitch == .some(a.cursor)
                        && yServer.totals == SyncTotals(habits: 0, entries: 0, groups: 0),
                     "\(describe(outcome)); \(describe(ex)); pending \((try? a.pendingCount()) ?? -1)/\(rows); Y's account \(yServer.totals.map { "\($0.habits)h/\($0.entries)e" } ?? "none")")
    }

    // S12 (STRIDE_REHEARSAL_LARGE=1) — a 20,000-entry account, timed. Not a default gate: it
    // measures, and fails only if a sync itself does. The time between requests is the device's
    // own work on the main actor (plan, resolve, reconcile, save). The M2 slice measured 28.5 s
    // for the upload, 3.4 s for a sync with no edits and 51.4 s for the join: the planner read
    // every record, the resolver fetched every record per chunk, the reconciler matched each
    // pulled entry by walking its habit's history. StrideTests/SyncPerformanceTests pins the fixed
    // shape on bigger stores; this is the same engine against the real server, -O.
    func largeAccount() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        for i in 0..<40 { a.habit("Habit \(i)", days: Array(0..<500)) }
        try a.save()

        func timed(_ d: Device131, _ body: () async -> SyncRunOutcome) async -> (SyncRunOutcome, String, [Exchange]) {
            let mark = d.transport.mark()
            let started = Date()
            let outcome = await body()
            let total = Date().timeIntervalSince(started)
            let ex = d.transport.since(mark)
            let network = ex.reduce(0) { $0 + $1.finished.timeIntervalSince($1.started) }
            let steps = ex.map { e in
                String(format: "%@ %.1fs", e.endpoint == .push ? "push" : (e.since == nil ? "full-pull" : "pull"),
                       e.finished.timeIntervalSince(e.started))
            }.joined(separator: ", ")
            return (outcome, String(format: "%.2f s total, %.2f s on the device (requests: %@)", total, total - network, steps), ex)
        }

        let (upload, uploadTime, uploadEx) = await timed(a) { await a.sync() }
        report.check("20,000-entry first upload completes in 10 pushes (timed)",
                     isSynced(upload) && pushes(uploadEx).count == 10, uploadTime)

        // A minute later: the cursor past the upload, so the pull is empty and what is left is
        // the planner's walk over every row.
        a.cursor = SyncTimestamp.millisecondString(from: Date())
        let (idle, idleTime, idleEx) = await timed(a) { await a.sync() }
        report.check("a sync with no edits on a 20,000-entry store pushes nothing (timed)",
                     isSynced(idle) && pushes(idleEx).isEmpty, idleTime)

        let (join, joinTime, _) = await timed(b) { await b.sync() }
        let bCounts = try b.counts()
        report.check("a second device joining a 20,000-entry account: one full pull (timed)",
                     isSynced(join) && bCounts.records == 20_000, joinTime)

        // The same device again: a full pull onto a store that already holds every row (Full
        // resync's cleared cursor, a cursor_expired, the migrated marks' proof), then a sync
        // with nothing new either way.
        b.cursor = nil
        let (again, againTime, againEx) = await timed(b) { await b.sync() }
        let afterAgain = (records: try b.counts().records, pending: try b.pendingCount())
        report.check("a full pull onto a synced 20,000-entry store changes nothing and pushes nothing (timed)",
                     isSynced(again) && pushes(againEx).isEmpty && afterAgain.records == 20_000
                        && afterAgain.pending == 0, againTime)
        b.cursor = SyncTimestamp.millisecondString(from: Date())
        let (quiet, quietTime, quietEx) = await timed(b) { await b.sync() }
        report.check("then a sync with no edits on the joined device pushes nothing (timed)",
                     isSynced(quiet) && pushes(quietEx).isEmpty, quietTime)
    }

    // S13 — untap and re-tap one day (M2 slice review). The deletion of X is queued and the
    // re-tap Y pending when a sync pulls before it pushes: the pull brings X back, and before the
    // fix the day match renamed Y to X, the push carried `deletedEntryIds: [X]` with an upsert of
    // X, the server (deletions first) answered `tombstoned`, and the check-in was gone everywhere.
    // Then the same edit made on B, reaching A as X deleted plus Y in ONE incremental pull.
    func untapAndReTap() async throws {
        let dayString = HabitCalendar.dayStringFormatter.string(from: HabitCalendar.startOfKey(Scenario.day(0)))
        func serverDay(_ account: Account, habit: UUID) async throws -> [SyncEntry] {
            try await serverSnapshot(account).entries.filter {
                SyncReconciler.canonicalID($0.habitId) == habit.uuidString && $0.date == dayString
            }
        }
        /// Untap, save (queues X), re-tap, save — TodayView's two taps. `HabitCheckIn.tap` right
        /// after the untap's save may still see the deleted record through `habit.records`; if
        /// so the re-tap is made as the app's list does after re-rendering: a new record.
        func untapThenReTap(_ d: Device131, _ habit: Habit) throws -> String {
            let untap = try d.tapAndSave(habit, day: 0)
            let retap = try d.tapAndSave(habit, day: 0)
            if !retap.isCompleted {
                habit.records.append(HabitRecord(date: Scenario.day(0)))
                try d.save()
            }
            return untap.deletedRecordID ?? "none"
        }

        for mode in ["first 1.3.1 sync (no cursor)", "Full resync"] {
            let account = try Account.create()
            let a = Device131("A", account: account)
            defer { a.remove() }
            let read = a.habit("Read", days: [0])
            try a.save()
            _ = await a.sync()
            let untapped = try untapThenReTap(a, read)
            if mode.hasPrefix("first") { a.cursor = nil }

            let mark = a.transport.mark()
            let outcome = await a.sync(options: mode == "Full resync" ? .fullResync : [])
            let ex = a.transport.since(mark)
            let onServer = try await serverDay(account, habit: read.id)
            let local = try a.context.fetch(FetchDescriptor<HabitRecord>())
            let pending = try a.pendingCount()
            report.check("untap + re-tap offline, then a pull-first sync (\(mode)): the day stays checked here and on the server",
                         isSynced(outcome) && ex.first?.endpoint == .pull && local.count == 1
                            && local.first?.id.uuidString != untapped && onServer.count == 1
                            && a.logItems().isEmpty && a.queue.pending().isEmpty && pending == 0,
                         "\(describe(outcome)); \(describe(ex)); local \(local.count), server \(onServer.count), log \(a.logItems().count)")
        }

        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let read = a.habit("Read", days: [0])
        try a.save()
        _ = await a.sync()
        _ = await b.sync()
        let bRead = try unwrap(b.habits().first, "B has Read")
        _ = try untapThenReTap(b, bRead)
        _ = await b.sync()
        let mark = a.transport.mark()
        let outcome = await a.sync()
        let ex = a.transport.since(mark)
        let onServer = try await serverDay(account, habit: read.id)
        let local = try a.context.fetch(FetchDescriptor<HabitRecord>())
        report.check("B's untap + re-tap reaches A in one incremental pull (X deleted + Y): A ends with Y",
                     isSynced(outcome) && ex.allSatisfy { $0.since != nil || $0.endpoint == .push }
                        && local.count == 1 && onServer.count == 1
                        && local.first?.id.uuidString == SyncReconciler.canonicalID(onServer.first?.id ?? ""),
                     "\(describe(ex)); local \(local.count), server \(onServer.count)")
    }

    // S14 — the first full pull proves the account (owner decision 2026-09-28; slice review R1).
    // Device D ran 1.3.0 on account A, synced, and went dormant; its session expired, which
    // deletes the token and keeps `stride_last_sync_time`, so nothing says which account its
    // rows were delivered to. Meanwhile A's phone deleted a habit. D updates: the real migration
    // marks its rows delivered, provisionally, and D signs in — to A again, or to B. Proven, the
    // marks are still unverified for that first pass (review data-safety-1: a mark says 1.3.0
    // pushed the row, not that the server took it), so the habit A deleted is resent once and
    // A's tombstone drops it, archived first, instead of the pass deleting it unrecorded.
    func migratedMarksProof() async throws {
        let accountA = try Account.create(), accountB = try Account.create()
        let old = SnapshotDevice("D on 1.3.0", shape: .v130, account: accountA)
        let phone = Device131("A's phone", account: accountA)
        defer { old.remove(); phone.remove() }
        let group = HabitGroup(name: "Morning")
        old.context.insert(group)
        let read = old.habit("Read", days: [0, 1, 2])
        read.groupId = group.id
        old.age(read, group: group)
        old.age(old.habit("Run", days: [0]))
        old.age(old.habit("Stretch"))
        try old.save()
        let synced = try await old.sync()
        guard synced.push == 200, synced.pull == 200 else { throw Missing(description: "1.3.0 sync: \(synced)") }
        let lastSync130 = SyncTimestamp.string(from: Date())    // what 1.3.0 wrote after that sync
        old.habit("Made after the last 1.3.0 sync", days: [3])  // an offline edit, never pushed
        try old.save()
        _ = await phone.sync()
        try phone.deleteHabit(try unwrap(phone.habits().first { $0.name == "Stretch" }, "phone has Stretch"))
        _ = await phone.sync()
        let aIDs = Set(try await serverSnapshot(accountA).habits.map { SyncReconciler.canonicalID($0.id) })

        for (label, account) in [("same account", accountA), ("another account", accountB)] {
            let d = Device131("D on 1.3.1 (\(label))", account: account)
            defer { d.remove() }
            try d.open130Store(from: old)
            d.defaults.set(lastSync130, forKey: SyncDeliveryMigration.lastSyncTimeKey)
            let migrated = SyncDeliveryMigration.runOnceIfNeeded(in: d.context, defaults: d.defaults)
            let before = try d.digest()

            let first = await d.sync()
            let ex1 = d.transport.exchanges
            let mark = d.transport.mark()
            let second = await d.sync()
            let ex2 = d.transport.since(mark)
            let after = try d.digest()
            let fullFirst = ex1.first?.endpoint == .pull && ex1.first?.since == nil
            let names = Set(try d.habits().map(\.name))
            let quiet = isSynced(second) && pushes(ex2).isEmpty && ex2.allSatisfy { $0.since != nil }

            if account.userId == accountA.userId {
                let onServer = try await serverSnapshot(accountA)
                report.check("SAME account: the first sync is a full pull before any push, and it proves the marks",
                             migrated != .failed && isSynced(first) && fullFirst && { if case .proven = first.summary?.marks { return true }; return false }()
                                && !d.marks.isAwaited && !d.marks.isUnverified,
                             "\(describe(first)); marks \(describe(first.summary?.marks)); \(describe(ex1))")
                let logged = d.logItems()
                let stretchLogged: Bool = {
                    guard logged.count == 1, let line = logged.first, line.reason == .tombstoned,
                          case .habit(let habit) = line.row else { return false }
                    return habit.name == "Stretch"
                }()
                report.check("SAME account: nothing deleted but the habit A's phone deleted while D slept — resent once, dropped by A's tombstone, archived",
                             names == ["Read", "Run", "Made after the last 1.3.0 sync"] && stretchLogged
                                && !onServer.habits.contains { $0.name == "Stretch" }
                                && after.difference(from: StoreDigest(pull: onServer)) == nil,
                             "D \(after.summary) \(names.sorted()); server \(StoreDigest(pull: onServer).summary); log \(logged.count)")
                report.check("SAME account: only the row made after the last 1.3.0 sync and Stretch's resend go up; the next sync pushes 0/0/0",
                             totalPushed(ex1).rows == 3 && totalPushed(ex1).habits == 2 && quiet,
                             "first pushed \(totalPushed(ex1)); second: \(describe(ex2))")
            } else {
                // What A holds now — the same-account run above uploaded D's newest row there,
                // exactly as one device's first choice would have.
                let onA = try await serverSnapshot(accountA), onB = try await serverSnapshot(accountB)
                let inA = Set((onA.habits.map(\.id) + onA.entries.map(\.id) + (onA.groups ?? []).map(\.id))
                    .map(SyncReconciler.canonicalID))
                let habits = try d.habits()
                let rows: [any SyncDeliverable] = habits + habits.flatMap(\.records).map { $0 }
                    + (try d.context.fetch(FetchDescriptor<HabitGroup>())).map { $0 }
                let heldIDs = Set(rows.filter { $0.activeHold == .notOwned }.map(\.id.uuidString))
                let ownedByA = Set(rows.map(\.id.uuidString)).intersection(inA)
                let uploaded = Set(habits.filter { !inA.contains($0.id.uuidString) }.map(\.name))
                report.check("ANOTHER account: the first sync is a full pull before any push, and it forgets the marks",
                             migrated != .failed && isSynced(first) && fullFirst && { if case .forgotten = first.summary?.marks { return true }; return false }()
                                && !d.marks.isAwaited && !d.marks.isUnverified,
                             "\(describe(first)); marks \(describe(first.summary?.marks)); \(describe(ex1))")
                report.check("ANOTHER account: nothing deleted — every row D held is still there",
                             after == before && d.logItems().isEmpty,
                             "before \(before.summary), after \(after.summary); log \(d.logItems().count)")
                report.check("ANOTHER account: every row A holds comes back not_owned and is held; the rest are uploaded to B",
                             !ownedByA.isEmpty && heldIDs == ownedByA
                                && Set(onB.habits.map(\.name)) == uploaded && uploaded.contains("Stretch")
                                && Set(onB.habits.map { SyncReconciler.canonicalID($0.id) }).isDisjoint(with: aIDs),
                             "held \(heldIDs.count) of \(ownedByA.count) rows A holds; B holds \(onB.habits.map(\.name).sorted()) (Stretch: deleted on A, so nobody's)")
                report.check("ANOTHER account: the next sync pushes 0/0/0 (held rows wait for an edit)",
                             quiet, describe(ex2))
            }
        }
    }

    // MARK: - Phase B: the file recovery log, the swept tombstone, restore as copies, backoff

    // S15 — a tombstone swept on the test server (review 2). A's cursor is over a year old: a
    // tombstone is swept only past retention (after the ≥ 1.3.1 floor, M0), so a device that
    // still holds the row it names has a cursor at least that old. Full resync, and support's
    // snapshot_required, must then full-pull BEFORE the resend: the row is gone from the
    // snapshot, so it is deleted here and archived to the file — not re-sent, which the server,
    // with no tombstone left to answer `tombstoned`, would accept as a new insert.
    func sweptTombstone() async throws {
        for mode in ["Full resync", "snapshot_required"] {
            let account = try Account.create()
            let a = Device131("A", account: account), b = Device131("B", account: account)
            defer { a.remove(); b.remove() }
            let doomed = a.habit("Deleted on B", days: [0, 1])
            a.habit("Kept", days: [0])
            try a.save()
            _ = await a.sync()
            _ = await b.sync()
            try b.deleteHabit(try unwrap(b.habit(id: doomed.id), "B has the habit"))
            _ = await b.sync()
            try await Task.sleep(nanoseconds: 20_000_000)   // the tombstones strictly before "now"
            let swept = try await sweepTombstones(olderThanDays: 0)
            a.cursor = SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-400 * 86_400))

            if mode == "snapshot_required" { try account.requestSnapshot() }
            let mark = a.transport.mark()
            let outcome = await a.sync(options: mode == "Full resync" ? .fullResync : [])
            let ex = a.transport.since(mark)
            let server = try await serverSnapshot(account)
            let doomedID = doomed.id.uuidString
            let serverHas = server.habits.contains { SyncReconciler.canonicalID($0.id) == doomedID }
            let logged = a.logItems().filter { $0.reason == .deletedElsewhere }
            let firstPush = ex.firstIndex { $0.endpoint == .push }
            let firstFullPull = ex.firstIndex { $0.endpoint == .pull && $0.since == nil && $0.status == 200 }
            let answered409 = mode == "Full resync" || ex.contains { $0.status == 409 }
            report.check("swept tombstone (\(mode)): the row B deleted stays deleted on the server, and A full-pulls before any push",
                         isSynced(outcome) && swept >= 3 && !serverHas && answered409
                            && firstFullPull != nil && (firstPush.map { $0 > firstFullPull! } ?? true),
                         "\(describe(outcome)); swept \(swept) tombstones; \(describe(ex)); server \(StoreDigest(pull: server).summary)")
            report.check("swept tombstone (\(mode)): A no longer has it, and its recovery-log FILE holds the habit and both check-ins",
                         try (try a.habit(id: doomed.id)) == nil
                            && logged.filter { $0.ref.kind == .habit }.map(\.ref.id) == [doomedID]
                            && logged.filter { $0.ref.kind == .entry }.count == 2
                            && (try a.exportedLog()).items.count == logged.count,
                         "A's log: \(a.logItems().map { "\($0.reason.rawValue) \($0.ref.kind)" })")
            // The full pull applied the server's copy of "Kept", which settles its forced resend
            // (remote state clears `needsResend`): a row the server holds is not sent again, and
            // the row it no longer holds is gone before any push could carry it.
            report.check("swept tombstone (\(mode)): the full pull settled every row, so the resend re-sent nothing; nothing left pending",
                         try totalPushed(ex).rows == 0 && server.habits.map(\.name) == ["Kept"]
                            && server.totals == SyncTotals(habits: 1, entries: 1, groups: 0) && (try a.pendingCount()) == 0,
                         "pushed \(totalPushed(ex)); server habits \(server.habits.map(\.name))")
        }
    }

    // S16 — a habit deleted on device B while edited offline on A: gone from A after its sync,
    // and A's recovery-log EXPORT — built from the file on disk, as Settings will export it —
    // holds the edit.
    func recoveryLogExport() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let journal = a.habit("Journal", days: [0])
        try a.save()
        _ = await a.sync()
        _ = await b.sync()
        try b.deleteHabit(try unwrap(b.habit(id: journal.id), "B has Journal"))
        _ = await b.sync()

        let record = try unwrap(journal.records.first, "A's check-in")
        let recordID = record.id.uuidString
        record.note = "written offline on A"
        record.touch()
        try a.save()
        let outcome = await a.sync()

        let export = try a.exportedLog()
        let line = export.items.first { $0.record?.id.uuidString == recordID }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: a.log.directory.path)) ?? []
        report.check("a habit deleted on B while edited offline on A is gone from A after its sync",
                     try isSynced(outcome) && (try a.habits()).isEmpty,
                     "\(describe(outcome)); A has \((try? a.habits().count) ?? -1) habits")
        report.check("A's recovery-log EXPORT (from the file on disk) holds the edit, with its habit's name",
                     line?.record?.note == "written offline on A" && line?.habitName == "Journal"
                        && export.accountId == account.owner && files.contains("account-\(account.owner).jsonl"),
                     "export: \(export.items.count) items, \(line.map { "\($0.reason.rawValue), note \"\($0.record?.note ?? "")\"" } ?? "no line for the check-in"); files \(files.sorted())")
        var notABackup = false
        do { _ = try DataBackup.decode(try a.log.exportData(accountID: account.owner)) } catch DataBackupError.notABackup { notABackup = true } catch {}
        report.check("…and picked in Restore by mistake, that export reads as \"not a backup\"", notABackup,
                     "DataBackup.decode → notABackup: \(notABackup)")
    }

    // S17 — Acceptance (6): a backup exported on account X, restored as new copies on a device
    // signed into Y, is in Y after a sync and still there after a full pull; X is untouched.
    func restoreAsCopiesIntoAnotherAccount() async throws {
        let x = try Account.create(), y = try Account.create()
        let a = Device131("A on X", account: x)
        let d = Device131("D on Y", account: y), e = Device131("E on Y", account: y)
        defer { a.remove(); d.remove(); e.remove() }
        let group = HabitGroup(name: "Morning")
        a.context.insert(group)
        a.habit("Read", days: [0, 1, 2, 3, 4]).groupId = group.id
        a.habit("Run", days: [0, 1])
        try a.save()
        _ = await a.sync()
        let file = try DataBackup.encode(DataBackup.snapshot(of: a.context, account: BackupAccount(id: x.owner, email: x.email)))
        let document = try DataBackup.decode(file)

        let decision = DataBackup.restoreDecision(for: document, device: .signedIn(BackupAccount(id: y.owner, email: y.email)))
        report.check("a backup naming account X, restored on a device signed into Y, is offered as new copies owned by Y",
                     document.accountId == x.owner && decision.plan == RestorePlan(identity: .newCopies, owner: BackupAccount(id: y.owner, email: y.email))
                        && decision.keepIDsInstead == nil,
                     "file account \(document.accountId ?? "none"); plan \(decision.plan.identity) → owner \(decision.plan.owner?.id ?? "none")")
        try DataBackup.restore(document, into: d.context, identity: decision.plan.identity, withdrawingDeletionsFrom: d.queue)
        let first = await d.sync()
        let onY = try await serverSnapshot(y), onX = try await serverSnapshot(x)
        let xIDs = Set(onX.habits.map { SyncReconciler.canonicalID($0.id) } + onX.entries.map { SyncReconciler.canonicalID($0.id) }
            + (onX.groups ?? []).map { SyncReconciler.canonicalID($0.id) })
        let yIDs = Set(onY.habits.map { SyncReconciler.canonicalID($0.id) } + onY.entries.map { SyncReconciler.canonicalID($0.id) }
            + (onY.groups ?? []).map { SyncReconciler.canonicalID($0.id) })
        let yGroup = onY.groups?.first.map { SyncReconciler.canonicalID($0.id) }
        let yRead = onY.habits.first { $0.name == "Read" }
        report.check("the copies sync into Y: 1 group, 2 habits, 7 check-ins, fresh ids, Read still in its group; X unchanged",
                     try isSynced(first) && onY.totals == SyncTotals(habits: 2, entries: 7, groups: 1)
                        && xIDs.isDisjoint(with: yIDs) && yRead?.groupId.map(SyncReconciler.canonicalID) == yGroup
                        && onX.totals == SyncTotals(habits: 2, entries: 7, groups: 1) && (try d.pendingCount()) == 0,
                     "\(describe(first)); Y \(StoreDigest(pull: onY).summary), X \(StoreDigest(pull: onX).summary), shared ids \(xIDs.intersection(yIDs).count)")

        d.cursor = nil
        let mark = d.transport.mark()
        let full = await d.sync()
        let exFull = d.transport.since(mark)
        let held = try SyncCopies.heldRows(in: d.context, reasons: Set(SyncHoldReason.allCases))
        _ = await e.sync()
        report.check("…and they survive a full pull on D (nothing deleted, nothing held, nothing re-sent), and a second Y device gets them",
                     try isSynced(full) && exFull.first?.since == nil && pushes(exFull).isEmpty && held.isEmpty
                        && (try d.digest()).difference(from: StoreDigest(pull: onY)) == nil
                        && (try e.digest()).difference(from: StoreDigest(pull: onY)) == nil,
                     "\(describe(exFull)); D \((try? d.digest().summary) ?? "-"), E \((try? e.digest().summary) ?? "-")")
    }

    // S18 — Acceptance (6), second half: a habit restored with its ids that another device had
    // deleted is HELD tombstoned (not deleted, not resurrected), and "Restore as new copies"
    // (SyncCopies.reidentify) brings it back to the account under new ids.
    func restoredHabitDeletedElsewhere() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        let d = Device131("D (restored)", account: account)
        defer { a.remove(); b.remove(); d.remove() }
        let journal = a.habit("Journal", days: [0, 1, 2])
        a.habit("Other", days: [0])
        try a.save()
        _ = await a.sync()
        let document = DataBackup.snapshot(habits: try a.habits(), groups: [],
                                           account: BackupAccount(id: account.owner, email: account.email))
        _ = await b.sync()
        try b.deleteHabit(try unwrap(b.habit(id: journal.id), "B has Journal"))
        _ = await b.sync()

        let decision = DataBackup.restoreDecision(for: document, device: .signedIn(BackupAccount(id: account.owner, email: account.email)))
        try DataBackup.restore(document, into: d.context, identity: decision.plan.identity, withdrawingDeletionsFrom: d.queue)
        let first = await d.sync()
        let dJournal = try d.habit(id: journal.id)
        let held = try SyncCopies.heldRows(in: d.context, reasons: [.tombstoned])
        var server = try await serverSnapshot(account)
        report.check("the same account's backup keeps its ids; the restored habit B deleted is held `tombstoned`, with its check-ins, not deleted",
                     isSynced(first) && decision.plan.identity == .keepIDs && dJournal?.activeHold == .tombstoned
                        && dJournal?.records.count == 3 && held.habits.map(\.id) == [journal.id]
                        && !server.habits.contains { $0.name == "Journal" } && d.logItems().isEmpty,
                     "\(describe(first)); Journal on D \(dJournal.map { "held \($0.activeHold?.rawValue ?? "no")" } ?? "GONE"); server \(server.habits.map(\.name))")

        let converted = try SyncCopies.reidentify(held, in: d.context)
        let mark = d.transport.mark()
        let pushedCopy = await d.sync()
        server = try await serverSnapshot(account)
        let back = server.habits.first { $0.name == "Journal" }
        let newID = converted.habitIDs[journal.id]?.uuidString
        report.check("\"Restore as new copies\" brings it back to the account under a new id, check-ins included",
                     isSynced(pushedCopy) && back.map { SyncReconciler.canonicalID($0.id) } == newID && newID != nil
                        && server.entries.filter { SyncReconciler.canonicalID($0.habitId) == newID }.count == 3
                        && totalPushed(d.transport.since(mark)).habits == 1,
                     "converted \(converted.rows.habits)h/\(converted.rows.entries)e; \(describe(d.transport.since(mark))); server \(server.habits.map(\.name))")

        _ = await b.sync()
        d.cursor = nil
        let full = await d.sync()
        let finalServer = StoreDigest(pull: try await serverSnapshot(account))
        report.check("…B gets it back, and it survives D's next full pull",
                     try isSynced(full) && (try b.habits()).contains { $0.name == "Journal" }
                        && (try d.habit(id: converted.habitIDs[journal.id] ?? UUID()))?.activeHold == nil
                        && (try d.digest()).difference(from: finalServer) == nil,
                     "B \((try? b.habits().map(\.name).sorted()) ?? []); \(describe(full))")
    }

    // S19 — 400 invalid_payload (a client bug, answered by the real server): nothing held, rows
    // pending, and the owner's backoff starts at about a minute. Automatic triggers (launch,
    // foreground) honour it and send nothing; Sync Now bypasses it; success resets it.
    func invalidPayloadBackoff() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account)
        defer { a.remove() }
        let habit = a.habit("Read", days: [0])
        try a.save()
        a.transport.transformPushBody = { body in
            guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
            json["habits"] = ["not": "an array"]
            return (try? JSONSerialization.data(withJSONObject: json)) ?? body
        }

        let failed = await a.sync(trigger: .automatic)
        let state = a.backoff.state(for: account.owner)
        var clientBug = false
        if case .stopped(.backOff(.clientBug, let answer), _) = failed, answer.code == "invalid_payload" { clientBug = true }
        report.check("invalid_payload: the run stops as a client bug, nothing is held, the rows stay pending, backoff ≈ 1 min",
                     try clientBug && habit.activeHold == nil && (try a.pendingCount()) == 2
                        && state?.reason == .clientBug && (48.0...72.0).contains(state?.delay ?? 0),
                     "\(describe(failed)); backoff \(state.map { "\($0.reason.rawValue) \(Int($0.delay)) s" } ?? "none"); pending \((try? a.pendingCount()) ?? -1)")

        a.transport.transformPushBody = nil
        var mark = a.transport.mark()
        let automatic = await a.sync(trigger: .automatic)
        var blocked = false
        if case .blocked(.backingOff) = automatic { blocked = true }
        report.check("…an automatic sync inside the window sends nothing",
                     blocked && a.transport.since(mark).isEmpty,
                     "\(describe(automatic)); \(describe(a.transport.since(mark)))")

        mark = a.transport.mark()
        let manual = await a.sync(trigger: .manual)
        let server = try await serverSnapshot(account)
        report.check("…Sync Now goes at once, lands the rows, and its success resets the backoff",
                     try isSynced(manual) && !a.transport.since(mark).isEmpty && a.backoff.state(for: account.owner) == nil
                        && server.totals == SyncTotals(habits: 1, entries: 1, groups: 0) && (try a.pendingCount()) == 0,
                     "\(describe(manual)); \(describe(a.transport.since(mark)))")
        let after = await a.sync(trigger: .automatic)
        report.check("…and the next automatic sync goes again", isSynced(after), describe(after))
    }

    // S20 — the non-UI half of Acceptance (9): flipping the server's pause switch backs off as
    // the server asked ("sync paused", never an error) and automatic syncs wait it out; a session
    // revoked server-side stops the run as needsReauth and resets nothing. The Today row and the
    // "sync paused" line that show these are phase C.
    func pauseAndRevokedSession() async throws {
        guard let pauseFile = Rehearsal.pauseFile else { throw Missing(description: "STRIDE_REHEARSAL_PAUSE_FILE") }
        let account = try Account.create()
        let a = Device131("A", account: account)
        defer { a.remove(); try? FileManager.default.removeItem(at: pauseFile) }
        let habit = a.habit("Read", days: [0])
        try a.save()
        _ = await a.sync()

        try Data("120".utf8).write(to: pauseFile)
        habit.note = "edited during the pause"
        habit.touch()
        try a.save()
        let paused = await a.sync(trigger: .automatic)
        let state = a.backoff.state(for: account.owner)
        var serverAsked = false
        if case .stopped(.backOff(.serverAsked(seconds: 120, paused: true), _), _) = paused { serverAsked = true }
        let mark = a.transport.mark()
        let waiting = await a.sync(trigger: .automatic)
        var blocked = false
        if case .blocked(.backingOff) = waiting { blocked = true }
        report.check("pause switch: 503 sync_paused backs off for the server's 120 s as \"sync paused\" (not an error); automatic syncs wait",
                     serverAsked && state?.reason == .paused && state?.reason.showsSyncPaused == true && state?.delay == 120
                        && blocked && a.transport.since(mark).isEmpty && habit.isPending,
                     "\(describe(paused)); backoff \(state.map { "\($0.reason.rawValue) \(Int($0.delay)) s" } ?? "none"); then \(describe(waiting))")

        try FileManager.default.removeItem(at: pauseFile)
        let resumed = await a.sync(trigger: .manual)
        report.check("…the pause lifted, Sync Now lands the edit and clears the window",
                     isSynced(resumed) && !habit.isPending && a.backoff.state(for: account.owner) == nil, describe(resumed))

        habit.note = "edited after the session was revoked"
        habit.touch()
        try a.save()
        a.queue.trackEntry(UUID().uuidString)
        let cursor = a.cursor
        try account.revokeSession()
        let revoked = await a.sync()
        var reauth = false
        if case .stopped(.needsReauth, _) = revoked { reauth = true }
        report.check("revoked session: the run stops as needsReauth, and nothing is reset (cursor, queue, pending edit, no backoff)",
                     reauth && a.cursor == cursor && !a.queue.pending().isEmpty && habit.isPending && habit.syncedAt != nil
                        && a.backoff.state(for: account.owner) == nil,
                     "\(describe(revoked)); \(describe(Array(a.transport.exchanges.suffix(1))))")
    }

    func skipped() {
        report.current = "phase C (UI)"
        report.skip("revoked session → Today's reauth row; pause switch → the \"sync paused\" line",
                    "the rows themselves are phase C UI; S20 checks what they read (needsReauth, the paused backoff)")
    }
}

struct Missing: Error, CustomStringConvertible {
    var description: String
}

func unwrap<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw Missing(description: "missing: \(what)") }
    return value
}
