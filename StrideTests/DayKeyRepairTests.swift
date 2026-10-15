import XCTest
import SwiftData
import Foundation

/// X2 section 5(b) (RELEASE-1.4.1.md W10): `DayKeyDecoder` reads the keys builds 1.2.0–1.4.0
/// wrote on a non-Gregorian device back to their real days, and `DayKeyRepair` puts them there —
/// in place when never delivered, under a new id with a tombstone for the old one (queued only
/// after the save) when the server may hold it, the `invalid_value` hold lifted, same-day
/// duplicates merged by decision 7 — once at the first launch and again at every launch for keys
/// pulled from older builds. Also the widget's wait for it, a restore of a backup with old keys,
/// and the strength walk's floor.
///
/// Every store here is built with the OLD formula (`oldKey`), as those builds wrote it.
@MainActor
final class DayKeyRepairTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: SharedModelContainer.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
    }

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func calendar(_ identifier: Calendar.Identifier, _ zone: TimeZone = tokyo) -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = zone
        return c
    }

    /// 2026-10-15 12:00 in Tokyo, the report's "today" (a Thursday).
    private let now = Date(timeIntervalSince1970: 1_792_033_200)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Int {
        HabitStats.dayNumber(ofKey: HabitCalendar.utc.date(from: DateComponents(year: y, month: m, day: d))!)
    }

    private var today: Int { day(2026, 10, 15) }

    private func key(_ day: Int) -> Date { HabitStats.key(ofDay: day) }

    /// The key 1.4.0 wrote for real day `day` on a device set to `identifier`, in `zone`: its
    /// `dayKey(forInstant:calendar:)` of an instant on that local day, written out here rather than
    /// through `DayKeyDecoder.oldKeyDay`, so the decoder is checked against the formula itself.
    private func oldKey(_ day: Int, _ identifier: Calendar.Identifier, zone: TimeZone = tokyo, hour: Int = 20) -> Date {
        let device = calendar(identifier, zone)
        let gregorian = calendar(.gregorian, zone)
        let c = HabitCalendar.utc.dateComponents([.year, .month, .day], from: key(day))
        let instant = gregorian.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: hour))!
        let local = device.dateComponents([.year, .month, .day], from: instant)
        return HabitCalendar.utc.date(from: DateComponents(year: local.year, month: local.month, day: local.day))
            ?? HabitCalendar.utc.startOfDay(for: instant)
    }

    /// An instant on real day `day` in Tokyo at `hour`.
    private func instant(_ day: Int, hour: Int = 20) -> Date {
        key(day).addingTimeInterval(Double(hour - 9) * 3_600)
    }

    private func defaults() -> UserDefaults {
        let name = "DayKeyRepairTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func queue() -> SyncDeletionQueue { SyncDeletionQueue(local: defaults(), shared: nil) }

    @discardableResult
    private func record(_ habit: Habit, at date: Date, value: Double = 1, note: String? = nil,
                        stamp: Date? = nil, delivered: Bool = false) -> HabitRecord {
        let r = HabitRecord(date: date, note: note, value: value)
        r.date = date
        r.updatedAt = stamp ?? SyncTimestamp.floorToMillisecond(now.addingTimeInterval(-86_400))
        if delivered { r.syncedAt = SyncTimestamp.floorToMillisecond(r.stamp) }
        habit.records.append(r)
        return r
    }

    private func habit(_ name: String = "Read", kind: HabitKind = .binary, target: Double = 1) -> Habit {
        let h = Habit(name: name)
        h.habitKind = kind
        h.targetValue = target
        h.createdAt = instant(day(2026, 3, 27), hour: 9)
        context.insert(h)
        return h
    }

    /// The store's live records of `habit`, by day number, read through a fresh context.
    private func stored(_ habit: Habit) throws -> [Int: [HabitRecord]] {
        let reader = ModelContext(container)
        let id = habit.id
        let h = try XCTUnwrap(reader.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first)
        let live = try Set(reader.fetch(FetchDescriptor<HabitRecord>()).map(\.persistentModelID))
        return Dictionary(grouping: h.records.filter { live.contains($0.persistentModelID) }) {
            HabitStats.dayNumber(ofKey: $0.date)
        }
    }

    // MARK: - The old formula and its inverse

    /// `DayKeyDecoder.oldKeyDay` is 1.4.0's formula: the device calendar's Y/M/D of any moment of
    /// the local day, whatever the zone and hour.
    func testTheOldFormulaIsWhatBuildsBefore1_4_1Wrote() {
        XCTAssertEqual(DayKeyDecoder.calendars, DayKeyCalendarTests.calendars, "every calendar a device can be set to")
        for identifier in DayKeyDecoder.calendars {
            var utcCalendar = Calendar(identifier: identifier)
            utcCalendar.timeZone = HabitCalendar.utc.timeZone
            for zone in ["Asia/Tokyo", "America/Los_Angeles", "UTC", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
                for d in stride(from: day(2025, 1, 1), through: today, by: 17) {
                    for hour in [0, 12, 23] {
                        XCTAssertEqual(key(DayKeyDecoder.oldKeyDay(ofRealDay: d, in: utcCalendar)),
                                       oldKey(d, identifier, zone: TimeZone(identifier: zone)!, hour: hour),
                                       "\(identifier) \(zone) \(d) \(hour):00")
                    }
                }
            }
        }
        // The report's table (2026-10-15 in Tokyo).
        let expected: [Calendar.Identifier: String] = [
            .japanese: "0008-10-15", .buddhist: "2569-10-15", .republicOfChina: "0115-10-15",
            .islamicCivil: "1448-05-03", .islamicUmmAlQura: "1448-05-04", .islamic: "1448-05-05",
            .hebrew: "5787-02-04", .persian: "1405-07-23", .indian: "1948-07-23", .coptic: "1743-02-05",
            .ethiopicAmeteMihret: "2019-02-05", .ethiopicAmeteAlem: "7519-02-05", .chinese: "0043-09-06",
        ]
        for (identifier, string) in expected {
            XCTAssertEqual(HabitCalendar.dayStringFormatter.string(from: oldKey(today, identifier)), string, "\(identifier)")
        }
    }

    /// Every key of the app's lifetime and of the whole window, in every calendar, with a stamp on
    /// its own day — the device's own calendar tried first — reads back to its day: 100 %, the
    /// report's measurement. Without a stamp, every day whose key no other day shares does too.
    func testEveryKeyReadsBackToItsDayOnItsOwnDevice() {
        for identifier in DayKeyDecoder.calendars {
            let decoder = DayKeyDecoder(today: now, calendar: calendar(identifier))
            var shared = 0
            for d in day(2025, 1, 1)...today {
                let k = oldKey(d, identifier)
                XCTAssertFalse(decoder.isRealDay(HabitStats.dayNumber(ofKey: k)), "\(identifier): \(k) looks real")
                XCTAssertEqual(decoder.realDay(ofKey: k, stamp: instant(d, hour: 21)), key(d), "\(identifier) \(d)")
                if decoder.realDay(ofKey: k, stamp: nil) != key(d) { shared += 1 }
            }
            // Only days that share their key with a later one (Hebrew's Elul and Tishri, Chinese
            // leap months, the rolled-over month ends) need the stamp.
            XCTAssertLessThan(shared, 130, "\(identifier)")
            if [.japanese, .buddhist, .republicOfChina].contains(identifier) {
                XCTAssertEqual(shared, 0, "\(identifier): unique keys until 2028-02-29")
            }
        }
    }

    private static let islamic: [Calendar.Identifier] = [.islamicUmmAlQura, .islamicCivil, .islamic, .islamicTabular]

    /// The batch `settleIslamicVariant(by:)` takes, for the keys `identifier` wrote on `days`,
    /// stamped by `stamp`.
    private func batch(_ days: [Int], _ identifier: Calendar.Identifier,
                       stamp: (Int) -> Date?) -> [(keyDay: Int, stamp: Date?)] {
        days.map { (HabitStats.dayNumber(ofKey: oldKey($0, identifier)), stamp($0)) }
    }

    /// A Gregorian device reads back keys pulled from a device on any calendar — the four Islamic
    /// variants too, which write the same keys a day apart: the batch's stamps settle which wrote
    /// them (W10-DECODE-1; before, Umm al-Qura was tried first and 295, 301 and 415 of 654 civil,
    /// astronomical and tabular days landed a day off).
    func testAnotherDevicesKeysReadBackOnAGregorianOne() {
        let days = Array(day(2026, 3, 27)...today)
        for identifier in DayKeyDecoder.calendars {
            let decoder = DayKeyDecoder(today: now, calendar: calendar(.gregorian))
            decoder.settleIslamicVariant(by: batch(days, identifier) { self.instant($0) })
            XCTAssertEqual(decoder.islamicVariant, Self.islamic.contains(identifier) ? identifier : nil, "\(identifier)")
            for d in days {
                XCTAssertEqual(decoder.realDay(ofKey: oldKey(d, identifier), stamp: instant(d)), key(d), "\(identifier) \(d)")
            }
        }
    }

    /// Check-ins made the next day (yesterday's, from the strip: a stamp a day late) do not flip the
    /// variant, as a record-by-record match would: with every fourth stamp a day late, a Gregorian
    /// device reads each Islamic variant's keys exactly as the device that wrote them does.
    func testLateStampsDoNotChangeWhichVariantReadsTheKeys() {
        let days = Array(day(2025, 1, 1)...today)
        let stamp: (Int) -> Date = { d in d % 4 == 0 ? self.instant(d + 1, hour: 9) : self.instant(d) }
        for identifier in Self.islamic {
            let gregorian = DayKeyDecoder(today: now, calendar: calendar(.gregorian))
            let writer = DayKeyDecoder(today: now, calendar: calendar(identifier))
            for decoder in [gregorian, writer] { decoder.settleIslamicVariant(by: batch(days, identifier, stamp: stamp)) }
            XCTAssertEqual(gregorian.islamicVariant, identifier)
            XCTAssertEqual(writer.islamicVariant, identifier)
            var wrong = 0
            for d in days {
                let k = oldKey(d, identifier)
                XCTAssertEqual(gregorian.realDay(ofKey: k, stamp: stamp(d)), writer.realDay(ofKey: k, stamp: stamp(d)), "\(identifier) \(d)")
                if gregorian.realDay(ofKey: k, stamp: stamp(d)) != key(d) { wrong += 1 }
            }
            // Only where two days share a key and the stamp names the later one.
            XCTAssertLessThan(wrong, 10, "\(identifier)")
        }
    }

    /// The device's own Islamic variant goes first only on a tie: a phone left at Umm al-Qura (ar_SA's
    /// default) reads the keys it pulled from, or wrote before switching from, Islamic (civil) as
    /// civil; with no stamps, or no Islamic key in the batch, nothing changes.
    func testTheDevicesOwnVariantDecidesOnlyATie() throws {
        let days = Array(day(2026, 3, 27)...today)
        let ummAlQura = DayKeyDecoder(today: now, calendar: calendar(.islamicUmmAlQura))
        ummAlQura.settleIslamicVariant(by: batch(days, .islamicCivil) { self.instant($0) })
        XCTAssertEqual(ummAlQura.islamicVariant, .islamicCivil)
        for d in days {
            XCTAssertEqual(ummAlQura.realDay(ofKey: oldKey(d, .islamicCivil), stamp: instant(d)), key(d), "\(d)")
        }

        let unstamped = DayKeyDecoder(today: now, calendar: calendar(.islamicCivil))
        unstamped.settleIslamicVariant(by: batch(days, .islamicUmmAlQura) { _ in nil })
        XCTAssertNil(unstamped.islamicVariant)
        XCTAssertEqual(unstamped.order.first, .islamicCivil, "no stamps: the device's own, as before")
        let japanese = DayKeyDecoder(today: now, calendar: calendar(.gregorian))
        japanese.settleIslamicVariant(by: batch(days, .japanese) { self.instant($0) })
        XCTAssertNil(japanese.islamicVariant)
        XCTAssertEqual(japanese.order, DayKeyDecoder.calendars)
        // A tie between the device's own variant and another: its own.
        let tie = DayKeyDecoder(today: now, calendar: calendar(.islamic))
        let shared = days.first { d in
            let k = HabitStats.dayNumber(ofKey: self.oldKey(d, .islamic))
            return HabitStats.dayNumber(ofKey: self.oldKey(d, .islamicUmmAlQura)) == k
        }
        let agreed = try XCTUnwrap(shared, "a day both variants key alike")
        tie.settleIslamicVariant(by: batch([agreed], .islamic) { self.instant($0) })
        XCTAssertEqual(tie.islamicVariant, .islamic)
    }

    /// Where two real days share a key: the stamp's day; else the latest on or before it; else the
    /// latest on or before today without a stamp.
    func testASharedKeyIsDecidedByTheStamp() throws {
        let decoder = DayKeyDecoder(today: now, calendar: calendar(.hebrew))
        var byKey: [Date: [Int]] = [:]
        for d in day(2025, 1, 1)...today { byKey[oldKey(d, .hebrew), default: []].append(d) }
        let (k, days) = try XCTUnwrap(byKey.first { $0.value.count == 2 && $0.value[1] - $0.value[0] > 2 })
        let (earlier, later) = (days[0], days[1])
        XCTAssertEqual(decoder.realDay(ofKey: k, stamp: instant(earlier)), key(earlier))
        XCTAssertEqual(decoder.realDay(ofKey: k, stamp: instant(later)), key(later))
        XCTAssertEqual(decoder.realDay(ofKey: k, stamp: instant(earlier + 1)), key(earlier), "the latest on or before the stamp")
        XCTAssertEqual(decoder.realDay(ofKey: k, stamp: instant(later + 3)), key(later))
        XCTAssertEqual(decoder.realDay(ofKey: k, stamp: nil), key(later), "no stamp: the latest before today")
        XCTAssertEqual(decoder.realDay(ofKey: k, stamp: instant(earlier - 5)), key(earlier), "before both: the earliest")
    }

    /// A real day is not read back, nor a key no calendar wrote; and a clock before 2025 reads
    /// nothing back at all.
    func testRealDaysAndUnknownKeysAreLeftAlone() {
        let decoder = DayKeyDecoder(today: now, calendar: calendar(.japanese))
        XCTAssertNil(decoder.realDay(ofKey: key(today), stamp: nil))
        XCTAssertNil(decoder.realDay(ofKey: key(day(2025, 1, 1)), stamp: nil))
        XCTAssertNil(decoder.realDay(ofKey: key(today + 2), stamp: nil))
        XCTAssertNil(decoder.realDay(ofKey: key(day(2030, 6, 1)), stamp: nil), "a clock set years ahead")
        XCTAssertNil(decoder.realDay(ofKey: key(day(1999, 1, 1)), stamp: nil))
        XCTAssertNil(decoder.realDay(ofKey: key(day(2024, 12, 31)), stamp: nil))
        XCTAssertTrue(decoder.isRealDay(today + 2))
        XCTAssertFalse(decoder.isRealDay(today + 3))
        XCTAssertFalse(decoder.isRealDay(day(2024, 12, 31)))

        let early = DayKeyDecoder(today: Date(timeIntervalSince1970: 1_700_000_000), calendar: calendar(.japanese))
        XCTAssertNil(early.realDays)
        XCTAssertNil(early.realDay(ofKey: oldKey(day(2023, 11, 14), .japanese), stamp: nil))
    }

    // MARK: - The repair

    /// One store with every case: never delivered, delivered, restored with its id, held
    /// `invalid_value` (both ways), held for another reason (both ways), a real Gregorian day and
    /// a key no calendar wrote.
    func testEachKindOfRecordIsRepairedByWhatTheServerMayHold() throws {
        let read = habit()
        let stamp = SyncTimestamp.floorToMillisecond(instant(today - 1, hour: 21))
        let d = (1...9).map { today - 2 * $0 }
        let fresh = record(read, at: oldKey(d[0], .japanese), note: "never sent")
        let delivered = record(read, at: oldKey(d[1], .japanese), note: "sent", stamp: stamp, delivered: true)
        let restored = record(read, at: oldKey(d[2], .japanese))
        restored.restoredAt = now
        let refused = record(read, at: oldKey(d[3], .japanese))
        refused.hold(.invalidValue)
        let refusedAfterDelivery = record(read, at: oldKey(d[4], .japanese), delivered: true)
        refusedAfterDelivery.touch()
        refusedAfterDelivery.hold(.invalidValue)
        let heldDelivered = record(read, at: oldKey(d[5], .japanese), delivered: true)
        heldDelivered.touch()
        heldDelivered.hold(.rowError)
        let heldFresh = record(read, at: oldKey(d[6], .japanese))
        heldFresh.updatedAt = nil   // never edited since before v2: it stamps as its (wrong) day
        heldFresh.hold(.notOwned)
        let gregorian = record(read, at: key(d[7]), delivered: true)
        let unknown = record(read, at: key(day(1999, 1, 1)), delivered: true)
        try context.save()
        let ids = [fresh, delivered, restored, refused, refusedAfterDelivery, heldDelivered, heldFresh, gregorian, unknown].map(\.id)
        let queue = queue()

        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue)

        XCTAssertEqual(outcome.found, 8)
        XCTAssertEqual(outcome.rekeyed, 3, "never delivered: fresh, refused, heldFresh")
        XCTAssertEqual(outcome.replaced, 3, "delivered, restored, refusedAfterDelivery")
        XCTAssertEqual(outcome.holdsLifted, 2)
        XCTAssertEqual(outcome.leftHeld, 1)
        XCTAssertEqual(outcome.undecodable, 1)
        XCTAssertEqual(outcome.mergedDays, 0)
        let tombstoned = [delivered, restored, refusedAfterDelivery].map(\.id.uuidString)
        XCTAssertEqual(Set(outcome.tombstones), Set(tombstoned))
        XCTAssertEqual(Set(queue.pending().entries), Set(tombstoned), "queued once each, after the save")
        XCTAssertEqual(queue.pending().entries.count, 3)

        let days = try stored(read)
        func one(_ n: Int) throws -> HabitRecord {
            let records = try XCTUnwrap(days[n], "day \(n)")
            XCTAssertEqual(records.count, 1, "day \(n)")
            return try XCTUnwrap(records.first)
        }
        // Never delivered: the same id, at its day, pending; nothing else moved.
        let a = try one(d[0])
        XCTAssertEqual(a.id, ids[0])
        XCTAssertEqual(a.note, "never sent")
        XCTAssertTrue(a.isPending)
        // Delivered: a new id at its day, the same value, note and stamp; never delivered itself.
        let b = try one(d[1])
        XCTAssertNotEqual(b.id, ids[1])
        XCTAssertEqual(b.note, "sent")
        XCTAssertEqual(b.updatedAt, stamp, "its own edit time, never now")
        XCTAssertNil(b.syncedAt)
        XCTAssertTrue(b.isPending)
        let c = try one(d[2])
        XCTAssertNotEqual(c.id, ids[2])
        XCTAssertNil(c.restoredAt, "a new row: no tombstone can name it")
        // invalid_value: re-keyed, the hold lifted, pending again.
        let e = try one(d[3])
        XCTAssertEqual(e.id, ids[3])
        XCTAssertNil(e.activeHold)
        XCTAssertNil(e.syncHoldReason)
        XCTAssertTrue(e.isPending)
        let f = try one(d[4])
        XCTAssertNotEqual(f.id, ids[4])
        XCTAssertNil(f.activeHold)
        // Delivered and held for another reason: left where it was, still held, for the user.
        XCTAssertNil(days[d[5]])
        let left = try XCTUnwrap(days[HabitStats.dayNumber(ofKey: oldKey(d[5], .japanese))]?.first)
        XCTAssertEqual(left.id, ids[5])
        XCTAssertEqual(left.activeHold, .rowError)
        // Never delivered and held: re-keyed, still held at the stamp it has now.
        let g = try one(d[6])
        XCTAssertEqual(g.id, ids[6])
        XCTAssertNil(g.updatedAt)
        XCTAssertEqual(g.activeHold, .notOwned)
        XCTAssertFalse(g.isPending)
        // A real day and a key no calendar wrote: untouched.
        XCTAssertEqual(try one(d[7]).id, ids[7])
        XCTAssertEqual(days[day(1999, 1, 1)]?.first?.id, ids[8])
    }

    /// The real day already holds a record (another device's check-in, or a UTC+0 strip pick that
    /// always keyed Gregorian): the day is merged as every write merges it (decision 7) — the
    /// record D2 reads is kept, a lone note moves onto it, the other goes with no tombstone, and
    /// the kept one is sent again. Only the stray's own old id is tombstoned (it was delivered).
    func testADayThatEndsWithTwoRecordsIsMergedWithNoTombstoneForTheDuplicate() throws {
        let water = habit("Water", kind: .count, target: 8)
        let d = today - 3
        let older = SyncTimestamp.floorToMillisecond(instant(d, hour: 10))
        let newer = SyncTimestamp.floorToMillisecond(instant(d, hour: 22))
        let existing = record(water, at: key(d), value: 3, stamp: newer, delivered: true)
        let stray = record(water, at: oldKey(d, .buddhist), value: 5, note: "felt good", stamp: older, delivered: true)
        try context.save()
        let queue = queue()

        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.buddhist), deletionQueue: queue)

        XCTAssertEqual(outcome.replaced, 1)
        XCTAssertEqual(outcome.mergedDays, 1)
        XCTAssertEqual(outcome.tombstones, [stray.id.uuidString])
        XCTAssertEqual(queue.pending().entries, [stray.id.uuidString], "never the merged duplicate's id")
        let day = try XCTUnwrap(try stored(water)[d])
        XCTAssertEqual(day.count, 1)
        let kept = try XCTUnwrap(day.first)
        XCTAssertEqual(kept.value, 5, "the larger value, as D2 reads the day")
        XCTAssertEqual(kept.note, "felt good")
        XCTAssertNotEqual(kept.id, existing.id)
        XCTAssertTrue(kept.isPending)
        XCTAssertEqual(try stored(water).count, 1, "nothing left at the Buddhist key")

        // The other way round: the existing record outranks (the newer stamp); it is kept and sent
        // again at its own stamp, marked for resend — a fresh stamp could beat a newer edit made
        // elsewhere.
        let read = habit("Journal")
        let kept2 = record(read, at: key(d), stamp: newer, delivered: true)
        let stray2 = record(read, at: oldKey(d, .buddhist), stamp: older, delivered: true)
        // And where the stray carries the day's only note, it moves onto the kept record: an edit
        // of that record (decision 7), so its stamp moves.
        let stretch = habit("Stretch")
        let kept3 = record(stretch, at: key(d), stamp: newer, delivered: true)
        let stray3 = record(stretch, at: oldKey(d, .buddhist), note: "from the old build", stamp: older, delivered: true)
        try context.save()
        let second = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.buddhist), deletionQueue: queue)
        XCTAssertEqual(second.mergedDays, 2)
        XCTAssertEqual(Set(second.tombstones), [stray2.id.uuidString, stray3.id.uuidString])
        let day2 = try XCTUnwrap(try stored(read)[d])
        XCTAssertEqual(day2.map(\.id), [kept2.id])
        XCTAssertEqual(day2.first?.updatedAt, newer)
        XCTAssertTrue(day2.first?.needsResend ?? false)
        XCTAssertTrue(day2.first?.isPending ?? false)
        let day3 = try XCTUnwrap(try stored(stretch)[d])
        XCTAssertEqual(day3.map(\.id), [kept3.id])
        XCTAssertEqual(day3.first?.note, "from the old build")
        XCTAssertGreaterThan(try XCTUnwrap(day3.first?.updatedAt), newer)
        XCTAssertTrue(day3.first?.isPending ?? false)
        XCTAssertEqual(Set(queue.pending().entries), [stray.id.uuidString, stray2.id.uuidString, stray3.id.uuidString])
    }

    /// Two different notes on the day that ends with two records are not combined without the
    /// user: the day keeps both until its next write, which asks (`.combineNotes`).
    func testTwoDifferentNotesAreLeftForTheNextWriteToAsk() throws {
        let read = habit()
        let d = today - 4
        // The newer stamp: the existing record is the one the day reads (and keeps).
        let existing = record(read, at: key(d), note: "mine", stamp: SyncTimestamp.floorToMillisecond(instant(d, hour: 23)),
                              delivered: true)
        let stray = record(read, at: oldKey(d, .japanese), note: "theirs", stamp: SyncTimestamp.floorToMillisecond(instant(d, hour: 8)))
        try context.save()

        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue())

        XCTAssertEqual(outcome.rekeyed, 1)
        XCTAssertEqual(outcome.daysAskingToCombineNotes, 1)
        XCTAssertEqual(outcome.mergedDays, 0)
        XCTAssertEqual(Set(try XCTUnwrap(try stored(read)[d]).map(\.id)), [existing.id, stray.id])
        XCTAssertEqual(HabitCheckIn.setNote("mine", on: key(d), of: read, in: context), .needsConfirmation(.combineNotes))
    }

    /// Running it again changes nothing: no record, no stamp, no tombstone.
    func testASecondPassChangesNothing() throws {
        let read = habit()
        for (n, identifier) in [Calendar.Identifier.japanese, .hebrew, .persian].enumerated() {
            record(read, at: oldKey(today - 1 - n, identifier), delivered: n.isMultiple(of: 2))
        }
        record(read, at: key(today - 9))
        try context.save()
        let queue = queue()
        _ = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue)
        let snapshot = try stored(read).mapValues { $0.map { "\($0.id) \($0.stamp) \($0.syncedAt as Any) \($0.needsResend)" } }
        let queued = queue.pending()

        let again = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue)

        XCTAssertEqual(again, DayKeyRepair.Outcome())
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try stored(read).mapValues { $0.map { "\($0.id) \($0.stamp) \($0.syncedAt as Any) \($0.needsResend)" } }, snapshot)
        XCTAssertEqual(queue.pending(), queued)
    }

    /// A save that fails queues no tombstone and leaves the store as it was: a tombstone queued
    /// first could delete on the server a row this store still holds at its wrong day.
    func testATombstoneIsQueuedOnlyAfterTheSave() throws {
        let read = habit()
        let delivered = record(read, at: oldKey(today - 2, .japanese), delivered: true)
        try context.save()
        let wrongDay = HabitStats.dayNumber(ofKey: delivered.date)
        let queue = queue()
        struct Refused: Error {}

        XCTAssertThrowsError(try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese),
                                                  deletionQueue: queue, save: { _ in throw Refused() }))

        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try stored(read).keys.sorted(), [wrongDay])
        XCTAssertEqual(try stored(read)[wrongDay]?.first?.id, delivered.id)

        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue)
        XCTAssertEqual(outcome.tombstones, [delivered.id.uuidString])
        XCTAssertEqual(queue.pending().entries, [delivered.id.uuidString])
    }

    /// Several habits and calendars in one store — a device that synced with a Japanese, a Hebrew
    /// and a Gregorian one — and the yes/no and count habits' stats afterwards: the real streak.
    func testAMixedStoreEndsOnTheRealDays() throws {
        let read = habit()
        let water = habit("Water", kind: .count, target: 2)
        for n in 0..<10 {
            let d = today - n
            switch n % 3 {
            case 0: record(read, at: oldKey(d, .japanese), delivered: true)
            case 1: record(read, at: oldKey(d, .hebrew))
            default: record(read, at: key(d), delivered: true)
            }
            record(water, at: oldKey(d, .islamicUmmAlQura), value: 2, stamp: instant(d, hour: 22), delivered: n < 5)
        }
        try context.save()
        _ = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.islamicUmmAlQura), deletionQueue: queue())

        XCTAssertEqual(try stored(read).keys.sorted(), Array((today - 9)...today))
        XCTAssertEqual(try stored(water).keys.sorted(), Array((today - 9)...today))
        for h in [read, water] {
            let stats = HabitStats(habit: h, live: HabitStats.liveRecords(of: h), calendar: calendar(.islamicUmmAlQura), today: now)
            XCTAssertEqual(stats.currentStreak(), 10, h.name)
            XCTAssertEqual(stats.startDay, key(day(2026, 3, 27)), h.name)
        }
    }

    /// A Gregorian iPad that pulled an Islamic (civil) phone's rows puts every one on its real day:
    /// the pass settles the variant over all of the store's stray keys before reading any back.
    func testAGregorianDeviceRepairsAnIslamicCivilPhonesRows() throws {
        let read = habit()
        let days = Array((today - 59)...today)
        for d in days { record(read, at: oldKey(d, .islamicCivil), stamp: SyncTimestamp.floorToMillisecond(instant(d)), delivered: true) }
        try context.save()

        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.gregorian), deletionQueue: queue())

        XCTAssertEqual(outcome.replaced, 60)
        XCTAssertEqual(outcome.mergedDays, 0, "no two records on one day: none read a day off")
        XCTAssertEqual(try stored(read).keys.sorted(), days)
    }

    /// The days left with two records are merged in a second save, after the moves are saved and
    /// their tombstones queued. If that save fails the moves stand, the tombstones stay queued,
    /// and the day keeps its two records — decision 7's ordinary state, merged by its next write.
    func testAFailedMergeSaveLeavesTheMovesAndTheirTombstones() throws {
        let read = habit()
        let d = today - 2
        let existing = record(read, at: key(d), stamp: SyncTimestamp.floorToMillisecond(instant(d, hour: 22)), delivered: true)
        let stray = record(read, at: oldKey(d, .japanese), note: "old build", stamp: SyncTimestamp.floorToMillisecond(instant(d, hour: 8)),
                           delivered: true)
        try context.save()
        let queue = queue()
        struct Refused: Error {}
        var saves = 0

        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue,
                                           save: { context in
                                               saves += 1
                                               if saves > 1 { throw Refused() }
                                               try context.save()
                                           })

        XCTAssertEqual(saves, 2)
        XCTAssertTrue(outcome.mergeSaveFailed)
        XCTAssertEqual(outcome.mergedDays, 0)
        XCTAssertEqual(outcome.replaced, 1)
        XCTAssertEqual(outcome.tombstones, [stray.id.uuidString])
        XCTAssertEqual(queue.pending().entries, [stray.id.uuidString])
        XCTAssertFalse(context.hasChanges)
        let day = try XCTUnwrap(try stored(read)[d])
        XCTAssertEqual(day.count, 2)
        XCTAssertTrue(day.contains { $0.id == existing.id })
        // Its next write merges it, as any duplicate day.
        guard case .changed = HabitCheckIn.setChecked(nil, on: key(d), of: read, in: context) else {
            return XCTFail("the next write did not merge the day")
        }
        try context.save()
        XCTAssertEqual(try stored(read)[d]?.map(\.id), [existing.id])
        XCTAssertEqual(try stored(read)[d]?.first?.note, "old build")
    }

    /// The first pass over a realistic store — 10 habits × 200 days of Japanese keys, delivered and
    /// not, a Gregorian record already on every tenth day (a merge), on disk and opened cold, as
    /// the launch opens it — is fast: 0.59 s in a Debug build on an M-series Mac, and 3.0 s for
    /// 40 × 250 (10,000 stray records), linear (W10-PERF-1: the first build asked the store once
    /// per day while holding every move pending, and took 45 s at -O for 5 × 200 and more than ten
    /// minutes for 20 × 200, past the launch watchdog). The bound leaves room for a slow CI runner.
    func testTheFirstPassOverARealisticStoreIsFast() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DayKeyRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Stride.store")
        let disk = try ModelContainer(for: SharedModelContainer.schema, configurations: [ModelConfiguration(url: url)])
        do {
            let writer = ModelContext(disk)
            for h in 0..<10 {
                let habit = Habit(name: "Habit \(h)")
                habit.habitKind = h.isMultiple(of: 3) ? .count : .binary
                habit.targetValue = h.isMultiple(of: 3) ? 4 : 1
                habit.createdAt = instant(day(2026, 3, 27), hour: 9)
                writer.insert(habit)
                var records: [HabitRecord] = []
                for n in 0..<200 {
                    let d = today - n
                    let r = HabitRecord(date: oldKey(d, .japanese), value: Double(1 + n % 3))
                    r.date = oldKey(d, .japanese)
                    r.updatedAt = SyncTimestamp.floorToMillisecond(instant(d))
                    if (n + h).isMultiple(of: 2) { r.syncedAt = r.updatedAt }
                    records.append(r)
                    if n.isMultiple(of: 10) {
                        let g = HabitRecord(date: key(d), value: 1)
                        g.date = key(d)
                        g.updatedAt = SyncTimestamp.floorToMillisecond(instant(d, hour: 22))
                        g.syncedAt = g.updatedAt
                        records.append(g)
                    }
                }
                habit.records = records
            }
            try writer.save()
        }
        let context = ModelContext(disk)
        let queue = queue()

        let started = Date()
        let outcome = try DayKeyRepair.run(in: context, now: now, calendar: calendar(.japanese), deletionQueue: queue)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome.found, 2_000)
        XCTAssertEqual(outcome.replaced + outcome.rekeyed, 2_000)
        XCTAssertEqual(outcome.mergedDays, 200)
        XCTAssertEqual(queue.pending().entries.count, outcome.replaced)
        XCTAssertLessThan(elapsed, 3, "the first pass took \(elapsed) s")
        let reader = ModelContext(disk)
        let records = try reader.fetch(FetchDescriptor<HabitRecord>())
        XCTAssertEqual(records.count, 2_000)
        XCTAssertTrue(records.allSatisfy { (day(2025, 1, 1)...today).contains(HabitStats.dayNumber(ofKey: $0.date)) })
        print("DayKeyRepair first pass, 10 × 200 on disk: \(String(format: "%.3f", elapsed)) s")
    }

    // MARK: - The launch's pass

    /// The flag is set by the first completed pass, whatever it found, and said so once; every
    /// later launch passes again and repairs a stray key pulled from an older build since.
    func testTheLaunchPassSetsItsFlagOnceAndRescansEveryLaunch() throws {
        let read = habit()
        record(read, at: key(today - 1), delivered: true)
        try context.save()
        let flags = defaults(), sync = defaults(), queue = queue()

        let first = DayKeyRepair.launchPass(in: context, flags: flags, syncDefaults: sync, deletionQueue: queue,
                                            now: now, calendar: calendar(.japanese))
        XCTAssertEqual(first.result, .nothingToRepair)
        XCTAssertTrue(first.flagSet)
        XCTAssertTrue(DayKeyRepair.isDone(in: flags))
        XCTAssertFalse(sync.bool(forKey: SyncDeliveryMigration.doneKey), "nothing to repair: the delivery rule is left to its own call")

        let second = DayKeyRepair.launchPass(in: context, flags: flags, syncDefaults: sync, deletionQueue: queue,
                                             now: now, calendar: calendar(.japanese))
        XCTAssertEqual(second.result, .nothingToRepair)
        XCTAssertFalse(second.flagSet)

        // A row a device still on 1.4.0 pushed, pulled here (pulled rows are delivered).
        let pulled = record(read, at: oldKey(today - 2, .buddhist), delivered: true)
        try context.save()
        let third = DayKeyRepair.launchPass(in: context, flags: flags, syncDefaults: sync, deletionQueue: queue,
                                            now: now, calendar: calendar(.gregorian))
        guard case .repaired(let outcome) = third.result else { return XCTFail("\(third.result)") }
        XCTAssertEqual(outcome.replaced, 1)
        XCTAssertFalse(third.flagSet)
        XCTAssertEqual(queue.pending().entries, [pulled.id.uuidString])
        XCTAssertEqual(try stored(read).keys.sorted(), [today - 2, today - 1])
    }

    /// A store from 1.3.0 opens with every row "never delivered" until the delivery rule marks
    /// what 1.3.0 had pushed. The pass runs that rule first, so a row 1.3.0 pushed gets a new id
    /// and a tombstone for the old one — re-keyed in place, it would have been marked delivered at
    /// a day the server does not hold — and one edited after the last sync is re-keyed in place.
    func testAStoreFrom1_3_0IsRepairedAfterTheDeliveryRule() throws {
        let read = habit()
        let lastSync = now.addingTimeInterval(-3_600)
        let pushed = record(read, at: oldKey(today - 3, .japanese), stamp: SyncTimestamp.floorToMillisecond(lastSync.addingTimeInterval(-7_200)))
        let later = record(read, at: oldKey(today - 1, .japanese), stamp: SyncTimestamp.floorToMillisecond(lastSync.addingTimeInterval(600)))
        try context.save()
        let flags = defaults(), sync = defaults(), queue = queue()
        sync.set(SyncTimestamp.string(from: lastSync), forKey: SyncDeliveryMigration.lastSyncTimeKey)

        let pass = DayKeyRepair.launchPass(in: context, flags: flags, syncDefaults: sync, deletionQueue: queue,
                                           now: now, calendar: calendar(.japanese))

        guard case .repaired(let outcome) = pass.result else { return XCTFail("\(pass.result)") }
        XCTAssertTrue(sync.bool(forKey: SyncDeliveryMigration.doneKey), "the delivery rule ran first")
        XCTAssertEqual(outcome.replaced, 1)
        XCTAssertEqual(outcome.rekeyed, 1)
        XCTAssertEqual(queue.pending().entries, [pushed.id.uuidString])
        let days = try stored(read)
        XCTAssertNotEqual(days[today - 3]?.first?.id, pushed.id)
        XCTAssertEqual(days[today - 1]?.first?.id, later.id)
        XCTAssertTrue(DayKeyRepair.isDone(in: flags))
    }

    // MARK: - The widget waits for it on a non-Gregorian device

    func testTheWidgetWaitsForTheRepairOnlyOnANonGregorianDevice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DayKeyRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Stride.store")
        for (identifier, waits) in [(Calendar.Identifier.japanese, true), (.buddhist, true), (.hebrew, true),
                                    (.islamicUmmAlQura, true), (.gregorian, false), (.iso8601, false)] {
            let flags = defaults()
            StoreSchemaGate.markOpenedByApp(in: flags)
            var opened = 0, checked = 0
            let open = ExtensionStoreOpen(location: .appGroup(url), defaults: flags, calendar: calendar(identifier),
                                          storeExists: { _ in true },
                                          storeMatchesModels: { _ in checked += 1; return true },
                                          makeContainer: { _ in
                                              opened += 1
                                              return try ModelContainer(for: SharedModelContainer.schema,
                                                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
                                          })
            if waits {
                guard case .failure(let refusal) = open.run() else { XCTFail("\(identifier): opened before the repair"); continue }
                XCTAssertEqual(refusal, .waitForApp(.dayKeyRepair), "\(identifier)")
                XCTAssertEqual(refusal.logDescription, "waitForApp(dayKeyRepair)")
                XCTAssertEqual(opened + checked, 0, "\(identifier): the file is not even read")
                flags.set(true, forKey: DayKeyRepair.doneKey)
            }
            guard case .success = open.run() else { XCTFail("\(identifier): did not open"); continue }
            XCTAssertEqual(opened, 1, "\(identifier)")
        }
    }

    // MARK: - Restore

    private func backupHabit(_ records: [BackupRecord]) -> BackupHabit {
        BackupHabit(id: UUID(), name: "Read", emoji: "📚", colorHex: "#AF52DE", createdAt: instant(day(2026, 3, 27)),
                    updatedAt: nil, isArchived: false, sortOrder: 1, reminderEnabled: false, reminderHour: 20,
                    reminderMinute: 0, note: nil, kind: "binary", targetValue: 1, unit: nil, scheduleKind: "daily",
                    timesPerWeek: 7, activeDaysMask: 127, groupId: nil, records: records)
    }

    private func backupRecord(_ key: Date, note: String? = nil, stamp: Date? = nil) -> BackupRecord {
        BackupRecord(id: UUID(), date: HabitCalendar.dayStringFormatter.string(from: key), value: 1, note: note, updatedAt: stamp)
    }

    /// A backup a non-Gregorian device made before 1.4.1 — 0008-10-12 from a Japanese one, 2569
    /// and 5787 years beside a real day — used to be refused whole (`invalidDate`). It restores
    /// now: each old key on its real day under a new id (the server may hold the old one at the
    /// wrong day), the real day under its own; the preview names the real days; and only the kept
    /// id's queued deletion is withdrawn.
    func testABackupWithOldKeysRestoresOnTheRealDays() throws {
        let japanese = backupRecord(oldKey(today - 3, .japanese), note: "Reiwa", stamp: instant(today - 3))
        let buddhist = backupRecord(oldKey(today - 2, .buddhist), stamp: instant(today - 2))
        let hebrew = backupRecord(oldKey(today - 1, .hebrew), stamp: instant(today - 1))
        let real = backupRecord(key(today - 5), stamp: instant(today - 5))
        let older = backupRecord(key(day(2024, 5, 1)))   // in the parser's old bounds, no calendar's key
        let document = BackupDocument(schemaVersion: DataBackup.schemaVersion, exportedAt: now, groups: [],
                                      habits: [backupHabit([japanese, buddhist, hebrew, real, older])])
        XCTAssertTrue(japanese.date.hasPrefix("0008-"))
        XCTAssertNoThrow(try DataBackup.decode(DataBackup.encode(document)))

        let preview = DataBackup.preview(of: document, days: DayKeyDecoder(today: now, calendar: calendar(.japanese)))
        XCTAssertEqual(preview.firstDay, key(day(2024, 5, 1)))
        XCTAssertEqual(preview.lastDay, key(today - 1))

        let queue = queue()
        for r in [japanese, buddhist, hebrew, real] { queue.trackEntry(r.id.uuidString) }
        try DataBackup.restore(document, into: context, identity: .keepIDs, withdrawingDeletionsFrom: queue,
                               now: now, calendar: calendar(.japanese))

        let restored = try context.fetch(FetchDescriptor<HabitRecord>())
        let byDay = Dictionary(grouping: restored) { HabitStats.dayNumber(ofKey: $0.date) }
        XCTAssertEqual(byDay.keys.sorted(), [day(2024, 5, 1), today - 5, today - 3, today - 2, today - 1])
        for (d, file) in [(today - 3, japanese), (today - 2, buddhist), (today - 1, hebrew)] {
            let r = try XCTUnwrap(byDay[d]?.first)
            XCTAssertNotEqual(r.id, file.id, "a new id")
            XCTAssertNil(r.restoredAt)
            XCTAssertEqual(r.updatedAt, file.updatedAt)
        }
        XCTAssertEqual(byDay[today - 3]?.first?.note, "Reiwa")
        XCTAssertEqual(byDay[today - 5]?.first?.id, real.id)
        XCTAssertNotNil(byDay[today - 5]?.first?.restoredAt)
        XCTAssertEqual(byDay[day(2024, 5, 1)]?.first?.id, older.id)
        XCTAssertEqual(Set(queue.pending().entries), Set([japanese, buddhist, hebrew].map(\.id.uuidString)),
                       "the old ids' deletions still mean what they meant")
    }

    private func backupHabit(_ name: String, kind: String = "binary", target: Double = 1,
                             _ records: [BackupRecord]) -> BackupHabit {
        var h = backupHabit(records)
        h.name = name
        h.kind = kind
        h.targetValue = target
        return h
    }

    /// A Japanese-calendar user in London in winter (UTC+0) on 1.4.0 checked a day from the strip's
    /// cell (a local midnight is a UTC one there, so it keyed Gregorian: 2026-12-15) and from the
    /// default Today (0008-12-15): their backup holds both for one day (X2's mixed keys). Restored,
    /// each day ends with one record, merged as decision 7 merges a day — the record D2 reads kept,
    /// a lone note moved onto it, no fresh stamp — except two different notes, which stay for the
    /// day's next write to ask about. The preview counts what is restored; only the kept records'
    /// queued deletions are withdrawn; and the next launch's repair has nothing left to do
    /// (W10-KEYS-1: before, both records were inserted, and no pass ever merged them).
    func testARestoreMergesAnOldKeyWithTheGregorianKeyOfTheSameDay() throws {
        let london = TimeZone(identifier: "Europe/London")!
        let device = calendar(.japanese, london)
        let winter = key(day(2026, 12, 16)).addingTimeInterval(12 * 3_600)
        let d = day(2026, 12, 15)
        func at(_ n: Int, _ hour: Int) -> Date { key(n).addingTimeInterval(Double(hour) * 3_600) }   // London = UTC
        func old(_ n: Int) -> Date { oldKey(n, .japanese, zone: london) }
        XCTAssertEqual(HabitCalendar.dayStringFormatter.string(from: old(d)), "0008-12-15")

        let strip = backupRecord(key(d), stamp: at(d, 20))
        let fromToday = backupRecord(old(d), note: "from Today", stamp: at(d, 8))
        var small = backupRecord(key(d - 1), stamp: at(d - 1, 21)); small.value = 3
        var large = backupRecord(old(d - 1), stamp: at(d - 1, 9)); large.value = 5
        let mine = backupRecord(key(d - 2), note: "mine", stamp: at(d - 2, 20))
        let theirs = backupRecord(old(d - 2), note: "theirs", stamp: at(d - 2, 8))
        let alone = backupRecord(old(d - 3), stamp: at(d - 3, 8))
        let document = BackupDocument(schemaVersion: DataBackup.schemaVersion, exportedAt: winter, groups: [],
                                      habits: [backupHabit("Read", [strip, fromToday]),
                                               backupHabit("Water", kind: "count", target: 8, [small, large]),
                                               backupHabit("Journal", [mine, theirs, alone])])
        XCTAssertNoThrow(try DataBackup.validate(document, days: DayKeyDecoder(today: winter, calendar: device)),
                         "two strings for one day are not a damaged file")
        let decoder = DataBackup.dayDecoder(for: document, now: winter, calendar: device)
        XCTAssertEqual(DataBackup.preview(of: document, days: decoder).checkIns, 5)

        let queue = queue()
        for r in [strip, fromToday, small, large, mine, theirs] { queue.trackEntry(r.id.uuidString) }
        let preview = try DataBackup.restore(document, into: context, identity: .keepIDs, withdrawingDeletionsFrom: queue,
                                             now: winter, calendar: device)
        XCTAssertEqual(preview.checkIns, 5)

        let habits = try context.fetch(FetchDescriptor<Habit>())
        func days(_ name: String) throws -> [Int: [HabitRecord]] {
            let h = try XCTUnwrap(habits.first { $0.name == name })
            return Dictionary(grouping: h.records) { HabitStats.dayNumber(ofKey: $0.date) }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HabitRecord>()), 5)
        // Read: the strip's record outranks (the newer stamp); the Today record's note moves onto
        // it, and its stamp stays the file's.
        let read = try XCTUnwrap(try days("Read")[d])
        XCTAssertEqual(read.map(\.id), [strip.id])
        XCTAssertEqual(read.first?.note, "from Today")
        XCTAssertEqual(read.first?.updatedAt, strip.updatedAt, "a restore never stamps")
        XCTAssertNotNil(read.first?.restoredAt)
        // Water: the larger value is the day (the old key's, under a new id).
        let water = try XCTUnwrap(try days("Water")[d - 1])
        XCTAssertEqual(water.count, 1)
        XCTAssertEqual(water.first?.value, 5)
        XCTAssertNotEqual(water.first?.id, large.id)
        XCTAssertNotEqual(water.first?.id, small.id)
        // Journal: two different notes stay, for the next write to ask; the lone old key restores.
        let journal = try days("Journal")
        XCTAssertEqual(Set(try XCTUnwrap(journal[d - 2]).compactMap(\.note)), ["mine", "theirs"])
        XCTAssertEqual(journal[d - 3]?.count, 1)
        // Withdrawn: only the ids a restored record goes by (strip, mine).
        XCTAssertEqual(Set(queue.pending().entries), Set([fromToday, small, large, theirs].map(\.id.uuidString)))

        let pass = DayKeyRepair.launchPass(in: context, flags: defaults(), syncDefaults: defaults(), deletionQueue: queue,
                                           now: winter, calendar: device)
        XCTAssertEqual(pass.result, .nothingToRepair)
    }

    /// A backup from a phone set to Islamic (civil), restored on a phone left at Umm al-Qura (ar_SA's
    /// default): every check-in on its real day, the variant settled by the whole file
    /// (W10-DECODE-1: Umm al-Qura first put about 45 % of them a day off).
    func testABackupFromAnotherIslamicVariantRestoresOnTheRealDays() throws {
        let days = Array((today - 89)...today)
        let records = days.map { backupRecord(oldKey($0, .islamicCivil), stamp: instant($0)) }
        let document = BackupDocument(schemaVersion: DataBackup.schemaVersion, exportedAt: now, groups: [],
                                      habits: [backupHabit(records)])
        let preview = try DataBackup.restore(document, into: context, identity: .newCopies, withdrawingDeletionsFrom: nil,
                                             now: now, calendar: calendar(.islamicUmmAlQura))
        XCTAssertEqual(preview.checkIns, 90)
        XCTAssertEqual(preview.firstDay, key(days[0]))
        XCTAssertEqual(preview.lastDay, key(today))
        let restored = try context.fetch(FetchDescriptor<HabitRecord>())
        XCTAssertEqual(restored.map { HabitStats.dayNumber(ofKey: $0.date) }.sorted(), days)
    }

    /// What no calendar wrote and the parser's old bounds refuse, or a date that is not canonical,
    /// is still a damaged file.
    func testAKeyNoCalendarWroteIsStillRefused() throws {
        for bad in ["0001-01-01", "1900-01-01", "2101-01-01", "9999-12-31", "2026-9-5", "2026-02-30"] {
            let r = BackupRecord(id: UUID(), date: bad, value: 1, note: nil, updatedAt: nil)
            let document = BackupDocument(schemaVersion: DataBackup.schemaVersion, exportedAt: now, groups: [],
                                          habits: [backupHabit([r])])
            XCTAssertThrowsError(try DataBackup.validate(document, days: DayKeyDecoder(today: now, calendar: calendar(.japanese))), bad) {
                guard case .invalidDate? = $0 as? DataBackupError else { return XCTFail("\(bad): \($0)") }
            }
        }
    }

    // MARK: - Statistics never walk from year 8

    /// A stray year-8 record (pulled before the next launch repairs it) is not where the habit
    /// starts: the rate and the strength walk start at the real start, not ~737,000 days back.
    func testAStrayKeyDoesNotMoveTheStartOrTheStrengthWalk() throws {
        let read = habit()
        for n in 0..<20 { record(read, at: key(today - n)) }
        record(read, at: oldKey(today - 30, .japanese))
        try context.save()
        let stats = HabitStats(habit: read, live: HabitStats.liveRecords(of: read), calendar: calendar(.japanese), today: now)
        XCTAssertEqual(stats.startDay, key(day(2026, 3, 27)))
        XCTAssertLessThan(stats.strengthSeries.scores.count, 300)
        XCTAssertGreaterThan(stats.strength, 0)

        let walk = HabitScore.series(completedDays: [today], valuesByDay: [today: 1], kind: .binary, targetValue: 1,
                                     schedule: .daily, timesPerWeek: 7, activeDaysMask: 127,
                                     startDay: HabitStats.dayNumber(ofKey: oldKey(today, .japanese)), today: today,
                                     todayIsComplete: true)
        XCTAssertEqual(walk.firstDayNumber, HabitCalendar.firstRealDayNumber)
        XCTAssertLessThan(walk.scores.count, 700)
    }

    /// A reminder's snooze carries a corrected key; one an older build carried on a non-Gregorian
    /// device is refused (the check-in falls back to the delivered day).
    func testASnoozesCarriedDayIsReadOnlyWhenItIsAKey() {
        XCTAssertEqual(NotificationRouter.day(from: [NotificationRouter.UserInfoKey.day: "2026-10-15"]), key(today))
        XCTAssertNil(NotificationRouter.day(from: [NotificationRouter.UserInfoKey.day: "0008-10-15"]))
        XCTAssertNil(NotificationRouter.day(from: [NotificationRouter.UserInfoKey.day: "2569-10-15"]))
    }
}
