import Foundation
import SwiftData

// X2 (RELEASE-1.4.1.md W10; docs/X2-non-gregorian-day-keys.md): a device whose builds before 1.4.1
// wrote day-keys in a non-Gregorian calendar, repaired by the shipping `DayKeyRepair` (Shared/),
// against the real local server. The harness has no calendar to inject into a device, so the old
// build's records are made directly with 1.4.0's formula (`DayKeyDecoder.oldKeyDay`, which
// StrideTests pins against that formula), on days relative to today: the repair's window is.

@MainActor
extension Scenarios {
    /// A device's live entries, through the store (`habit.records` keeps a deleted record):
    /// habit id | yyyy-MM-dd → id | value | note.
    private func liveEntries(_ device: StoreDevice) throws -> [String: String] {
        let live = Set(try device.context.fetch(FetchDescriptor<HabitRecord>()).map(\.persistentModelID))
        var out: [String: String] = [:]
        for habit in try device.habits() {
            for record in habit.records where live.contains(record.persistentModelID) {
                out["\(habit.id.uuidString)|\(HabitCalendar.dayStringFormatter.string(from: record.date))"] =
                    "\(record.id.uuidString)|\(record.value)|\(record.note ?? "")"
            }
        }
        return out
    }

    private func serverEntries(_ account: Account) async throws -> [String: String] {
        var out: [String: String] = [:]
        for e in try await serverSnapshot(account).entries {
            out["\(SyncReconciler.canonicalID(e.habitId))|\(e.date)"] =
                "\(SyncReconciler.canonicalID(e.id))|\(e.value ?? 1)|\(e.note ?? "")"
        }
        return out
    }

    private func dayString(_ day: Int) -> String {
        HabitCalendar.dayStringFormatter.string(from: HabitStats.key(ofDay: day))
    }

    private func calendar(_ identifier: Calendar.Identifier, _ zone: String = "Asia/Tokyo") -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    /// 1.4.0's key for real day `day` on a device set to `identifier`.
    private func oldKey(_ day: Int, _ identifier: Calendar.Identifier) -> Date {
        HabitStats.key(ofDay: DayKeyDecoder.oldKeyDay(ofRealDay: day, in: calendar(identifier, "UTC")))
    }

    private func isStray(_ dayString: String, today: Int) -> Bool {
        guard let date = HabitCalendar.dayStringFormatter.date(from: dayString) else { return true }
        return HabitCalendar.realDayNumbers(todayNumber: today)?.contains(HabitStats.dayNumber(ofKey: date)) != true
    }

    // K1 — A ran 1.4.0 on a Japanese-calendar phone: three check-ins went up at Reiwa keys
    // (0008-…), and B, a Gregorian device on 1.4.1, pulled them — and checked one of those real days
    // itself, so the server holds that day twice (one row per key). A writes a fourth check-in
    // offline, then updates: the launch's pass gives the three delivered ones new ids at their real
    // days and tombstones the old ids after the save, re-keys the offline one in place, and sets
    // its flag. A's sync deletes exactly the wrong-day rows and puts the four real days up; the
    // shared day lands on B's row with A's note. B's next sync ends with exactly A's and the
    // server's check-ins, nothing at a Reiwa key anywhere, nothing pending or queued.
    func oldBuildKeysRepairedAndFollowedByB() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let now = Date()
        let japanese = calendar(.japanese)
        let today = HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: now, calendar: japanese))
        let synced = [today - 6, today - 5, today - 4], offline = today - 2, shared = today - 5

        let read = a.habit("Read")
        read.records = synced.map { d in
            let r = HabitRecord(date: oldKey(d, .japanese), note: d == shared ? "from A's old build" : nil)
            r.date = oldKey(d, .japanese)
            r.updatedAt = SyncTimestamp.floorToMillisecond(now.addingTimeInterval(Double(d - today) * 86_400))
            return r
        }
        try a.save()
        let oldIDs = Set(read.records.map(\.id.uuidString))
        guard isSynced(await a.sync()), isSynced(await b.sync()) else { throw Missing(description: "the first syncs") }
        let bRead = try unwrap(b.habit(id: read.id), "B has Read")
        _ = HabitCheckIn.setChecked(true, on: HabitStats.key(ofDay: shared), of: bRead, in: b.context)
        try b.save()
        guard isSynced(await b.sync()) else { throw Missing(description: "B's own check-in") }
        let before = try await serverEntries(account)
        let reiwa = before.keys.filter { isStray(String($0.split(separator: "|")[1]), today: today) }
        report.check("setup: the server holds A's three check-ins at Reiwa keys (0008-…) beside B's own row of one of those days",
                     before.count == 4 && reiwa.count == 3 && reiwa.allSatisfy { $0.contains("|0008-") || $0.contains("|0007-") }
                        && before["\(read.id.uuidString)|\(dayString(shared))"] != nil,
                     before.keys.sorted().joined(separator: ", "))

        let written = HabitRecord(date: oldKey(offline, .japanese), note: "offline")
        written.date = oldKey(offline, .japanese)
        read.records.append(written)
        try a.save()

        let pass = DayKeyRepair.launchPass(in: a.context, flags: a.defaults, syncDefaults: a.defaults,
                                           deletionQueue: a.queue, now: now, calendar: japanese)
        var outcome = DayKeyRepair.Outcome()
        if case .repaired(let o) = pass.result { outcome = o }
        let aDays = try liveEntries(a)
        let expectedDays = Set((synced + [offline]).map { "\(read.id.uuidString)|\(dayString($0))" })
        report.check("A's launch pass: three delivered check-ins under new ids at their real days, the offline one re-keyed in place, the three old ids tombstoned after the save, the flag set",
                     pass.flagSet && outcome.found == 4 && outcome.replaced == 3 && outcome.rekeyed == 1
                        && Set(outcome.tombstones) == oldIDs && Set(a.queue.pending().entries) == oldIDs
                        && Set(aDays.keys) == expectedDays
                        && aDays["\(read.id.uuidString)|\(dayString(offline))"]?.hasPrefix(written.id.uuidString) == true
                        && !aDays.values.contains { oldIDs.contains(String($0.prefix(36))) },
                     "\(pass.result); A: \(aDays.keys.sorted().joined(separator: ", "))")

        let mark = a.transport.mark()
        let aSynced = await a.sync()
        let sent = totalPushed(a.transport.since(mark))
        let server = try await serverEntries(account)
        let sharedRow = server["\(read.id.uuidString)|\(dayString(shared))"]
        let bShared = try liveEntries(b)["\(read.id.uuidString)|\(dayString(shared))"]
        report.check("A's sync deletes exactly the three wrong-day rows and puts the four real days up; the shared day keeps B's row, with A's note",
                     isSynced(aSynced) && sent.deletions == 3 && sent.entries == 4
                        && Set(server.keys) == expectedDays
                        && sharedRow?.hasPrefix(String(bShared?.prefix(36) ?? "?")) == true
                        && sharedRow?.hasSuffix("|from A's old build") == true,
                     "\(describe(aSynced)); pushed \(sent); server \(server.keys.sorted().joined(separator: ", ")); shared day \(sharedRow ?? "missing")")

        let bSynced = await b.sync()
        let aAgain = await a.sync()
        let finalServer = try await serverEntries(account)
        let finalA = try liveEntries(a), finalB = try liveEntries(b)
        let calm = try a.pendingCount() == 0 && b.pendingCount() == 0 && a.queue.pending().isEmpty && b.queue.pending().isEmpty
        let bPass = DayKeyRepair.launchPass(in: b.context, flags: b.defaults, syncDefaults: b.defaults,
                                            deletionQueue: b.queue, now: now, calendar: calendar(.gregorian))
        report.check("…and B's sync ends with exactly A's and the server's check-ins — ids, values, notes — nothing at a Reiwa key anywhere, nothing pending or queued; B's own pass finds nothing",
                     isSynced(bSynced) && isSynced(aAgain) && finalA == finalServer && finalB == finalServer
                        && Set(finalServer.keys) == expectedDays && calm && bPass.result == .nothingToRepair,
                     "server \(finalServer.count), A \(finalA.count), B \(finalB.count); A≠server: \(finalA != finalServer), B≠server: \(finalB != finalServer); calm \(calm); B's pass \(bPass.result)")
    }

    // K2 — rows a 1.4.0 Buddhist-calendar device (A) pushed, repaired on BOTH devices before either
    // syncs again: B (Gregorian, 1.4.1) took them in a pull and repairs them as delivered rows, then
    // A updates and repairs its own. Each makes its own new ids and the same tombstones. B's sync
    // deletes the wrong-day rows and puts the real days up; A's lands on B's rows (one row a day:
    // the server keeps one per habit and day, and A takes B's ids). Every day ends one record
    // everywhere, under one id, with its note, and nothing is pending or queued.
    func bothDevicesRepairTheSamePulledKeys() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let now = Date()
        let today = HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: now, calendar: calendar(.gregorian)))
        let days = [today - 9, today - 8, today - 3]

        let water = a.habit("Water")
        water.habitKind = .count
        water.targetValue = 8
        water.records = days.enumerated().map { n, d in
            let r = HabitRecord(date: oldKey(d, .buddhist), note: n == 1 ? "eight, finally" : nil, value: Double(5 + n))
            r.date = oldKey(d, .buddhist)
            r.updatedAt = SyncTimestamp.floorToMillisecond(now.addingTimeInterval(Double(d - today) * 86_400))
            return r
        }
        try a.save()
        guard isSynced(await a.sync()), isSynced(await b.sync()) else { throw Missing(description: "the first syncs") }
        let pulled = try liveEntries(b)
        report.check("setup: B pulled A's three Buddhist-year rows (2569-…, 2568-…) as they are",
                     pulled.count == 3 && pulled.keys.allSatisfy { isStray(String($0.split(separator: "|")[1]), today: today) },
                     pulled.keys.sorted().joined(separator: ", "))

        let bPass = DayKeyRepair.launchPass(in: b.context, flags: b.defaults, syncDefaults: b.defaults,
                                            deletionQueue: b.queue, now: now, calendar: calendar(.gregorian))
        let aPass = DayKeyRepair.launchPass(in: a.context, flags: a.defaults, syncDefaults: a.defaults,
                                            deletionQueue: a.queue, now: now, calendar: calendar(.buddhist, "Asia/Bangkok"))
        let expected = Set(days.map { "\(water.id.uuidString)|\(dayString($0))" })
        let both = [bPass, aPass].allSatisfy {
            if case .repaired(let o) = $0.result { return o.replaced == 3 && o.tombstones.count == 3 }
            return false
        }
        let aKeys = Set(try liveEntries(a).keys), bKeys = Set(try liveEntries(b).keys)
        report.check("each device's pass gives the three delivered rows new ids at their real days and queues the same three tombstones",
                     both && aKeys == expected && bKeys == expected
                        && Set(a.queue.pending().entries) == Set(b.queue.pending().entries),
                     "B \(bPass.result); A \(aPass.result)")

        let bSynced = await b.sync()
        let aSynced = await a.sync()
        let bAgain = await b.sync()
        let server = try await serverEntries(account)
        let finalA = try liveEntries(a), finalB = try liveEntries(b)
        let calm = try a.pendingCount() == 0 && b.pendingCount() == 0 && a.queue.pending().isEmpty && b.queue.pending().isEmpty
        let note = server["\(water.id.uuidString)|\(dayString(days[1]))"]
        report.check("…and after B's, A's and B's syncs the server, A and B each hold one row of each real day, under one id, values and note kept; nothing pending or queued",
                     isSynced(bSynced) && isSynced(aSynced) && isSynced(bAgain)
                        && Set(server.keys) == expected && finalA == server && finalB == server
                        && note?.hasSuffix("|6.0|eight, finally") == true && calm,
                     "\(describe(bSynced)), \(describe(aSynced)); server \(server.values.sorted()); A≠server: \(finalA != server), B≠server: \(finalB != server); calm \(calm)")
    }

    // K3 — A ran 1.4.0 on a phone set to Islamic (civil): 300 days of check-ins went up at civil
    // keys (1446–1448), a day apart from Umm al-Qura's in about half the months, a third of them
    // stamped the next day (yesterday's, checked from the strip). B, a Gregorian iPad on 1.4.1,
    // pulls them and repairs first; A updates later. The variant is settled by the whole batch's
    // stamps (W10-DECODE-1), so B puts every row on the day A meant — before, B tried Umm al-Qura
    // first and moved the rows of those months a day under new ids, tombstoning the right ones —
    // and B, A and the server end with the same rows, nothing pending or queued.
    func islamicCivilKeysRepairedOnAGregorianDevice() async throws {
        let account = try Account.create()
        let a = Device131("A", account: account), b = Device131("B", account: account)
        defer { a.remove(); b.remove() }
        let now = Date()
        let gregorian = calendar(.gregorian)
        let today = HabitStats.dayNumber(ofKey: HabitCalendar.dayKey(forInstant: now, calendar: gregorian))
        let days = Array((today - 300)...(today - 1))
        // A late stamp only where the key is the day's alone: where two days share a key, a stamp
        // a day late names the later one on every device alike, which says nothing about the vote.
        var writers: [Int: Int] = [:]
        for d in (today - 400)...(today + 2) { writers[HabitStats.dayNumber(ofKey: oldKey(d, .islamicCivil)), default: 0] += 1 }
        func stamp(_ d: Int) -> Date {
            let late = d % 3 == 0 && writers[HabitStats.dayNumber(ofKey: oldKey(d, .islamicCivil))] == 1 ? 1 : 0
            return SyncTimestamp.floorToMillisecond(now.addingTimeInterval(Double(d - today + late) * 86_400))
        }

        let walk = a.habit("Walk")
        walk.records = days.map { d in
            let r = HabitRecord(date: oldKey(d, .islamicCivil))
            r.date = oldKey(d, .islamicCivil)
            r.updatedAt = stamp(d)
            return r
        }
        try a.save()
        let oldIDs = Set(walk.records.map(\.id.uuidString))
        guard isSynced(await a.sync()), isSynced(await b.sync()) else { throw Missing(description: "the first syncs") }
        let pulled = try liveEntries(b)
        let unsettled = DayKeyDecoder(today: now, calendar: gregorian)
        let offByOne = days.filter { unsettled.realDay(ofKeyDay: HabitStats.dayNumber(ofKey: oldKey($0, .islamicCivil)), stamp: stamp($0)) != $0 }
        report.check("setup: B pulled A's 300 Islamic (civil) rows as they are; Umm al-Qura first would have read some of them a day off",
                     pulled.count == 300 && pulled.keys.allSatisfy { isStray(String($0.split(separator: "|")[1]), today: today) }
                        && !offByOne.isEmpty,
                     "\(pulled.count) pulled; \(offByOne.count) a day off by the old rule")

        let bPass = DayKeyRepair.launchPass(in: b.context, flags: b.defaults, syncDefaults: b.defaults,
                                            deletionQueue: b.queue, now: now, calendar: gregorian)
        var bOutcome = DayKeyRepair.Outcome()
        if case .repaired(let o) = bPass.result { bOutcome = o }
        let expected = Set(days.map { "\(walk.id.uuidString)|\(dayString($0))" })
        let bDays = try liveEntries(b)
        report.check("B's pass puts all 300 on their real days under new ids — no day twice, none merged — and queues the 300 old ids",
                     bOutcome.replaced == 300 && bOutcome.mergedDays == 0 && Set(bDays.keys) == expected
                        && Set(b.queue.pending().entries) == oldIDs,
                     "\(bPass.result); \(bDays.count) days, \(bDays.keys.filter { !expected.contains($0) }.count) not expected")

        let bSynced = await b.sync()
        let aPass = DayKeyRepair.launchPass(in: a.context, flags: a.defaults, syncDefaults: a.defaults,
                                            deletionQueue: a.queue, now: now, calendar: calendar(.islamicCivil))
        let aSynced = await a.sync()
        let bAgain = await b.sync()
        let server = try await serverEntries(account)
        let finalA = try liveEntries(a), finalB = try liveEntries(b)
        let calm = try a.pendingCount() == 0 && b.pendingCount() == 0 && a.queue.pending().isEmpty && b.queue.pending().isEmpty
        var aOutcome = DayKeyRepair.Outcome()
        if case .repaired(let o) = aPass.result { aOutcome = o }
        report.check("…and after B's sync, A's own repair and A's and B's syncs, the server, A and B each hold exactly the 300 real days, under one id each; nothing pending or queued",
                     isSynced(bSynced) && isSynced(aSynced) && isSynced(bAgain) && aOutcome.replaced == 300
                        && Set(server.keys) == expected && finalA == server && finalB == server && calm,
                     "\(describe(bSynced)), \(describe(aSynced)), \(describe(bAgain)); server \(server.count), A≠server: \(finalA != server), B≠server: \(finalB != server); calm \(calm)")
    }
}
