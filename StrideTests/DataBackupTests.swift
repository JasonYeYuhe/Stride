import XCTest
import SwiftData
import Foundation

/// Backup v2, restore, the CSV export and erase — `Shared/DataBackup.swift`, the code that ships.
///
/// The round trip is checked field by field and row by row, not by "the JSON decodes": the 1.2.3
/// export decoded fine and could not tell a day with 2 of 8 glasses from a day with 8.
@MainActor
final class DataBackupTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    /// Containers behind `freshContext()`. A ModelContext must not outlive its container, and
    /// `freshContext()` would release the container at the end of the line.
    private var others: [ModelContainer] = []

    override func setUp() {
        super.setUp()
        container = Self.makeContainer()
        context = container.mainContext
    }

    override func tearDown() {
        container = nil
        context = nil
        others = []
        super.tearDown()
    }

    // MARK: - Helpers

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [config])
    }

    private func freshContext() -> ModelContext {
        let other = Self.makeContainer()
        others.append(other)
        return other.mainContext
    }

    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> Date {
        HabitCalendar.utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// An instant with a sub-millisecond fraction, so the millisecond rounding is exercised.
    private func instant(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds + 0.123_456)
    }

    private func counts(_ context: ModelContext) throws -> (habits: Int, records: Int, groups: Int) {
        (try context.fetchCount(FetchDescriptor<Habit>()),
         try context.fetchCount(FetchDescriptor<HabitRecord>()),
         try context.fetchCount(FetchDescriptor<HabitGroup>()))
    }

    /// A store with every field set to something other than its default, one of each kind and
    /// schedule, a group left empty, and a habit pointing at a group that no longer exists.
    @discardableResult
    private func populate(_ context: ModelContext) throws -> [Habit] {
        let health = HabitGroup(name: "Health, \"body\"", colorHex: "#FF3B30", sortOrder: 1.5)
        health.createdAt = instant(1_750_000_000)
        health.updatedAt = instant(1_750_000_500)
        let empty = HabitGroup(name: "Empty", colorHex: "#007AFF", sortOrder: 2)
        empty.createdAt = instant(1_750_001_000)
        empty.updatedAt = nil
        context.insert(health)
        context.insert(empty)

        let water = Habit(name: "Drink water", emoji: "💧", colorHex: "#5AC8FA")
        water.createdAt = instant(1_750_100_000)
        water.updatedAt = instant(1_760_000_000)
        water.sortOrder = 1_750_100_000.987_654
        water.kind = HabitKind.count.rawValue
        water.targetValue = 8
        water.unit = "glasses"
        water.scheduleKind = HabitSchedule.timesPerWeek.rawValue
        water.timesPerWeek = 5
        water.reminderEnabled = true
        water.reminderHour = 7
        water.reminderMinute = 45
        water.note = "Line one\nline two, with a comma"
        water.groupId = health.id

        let gym = Habit(name: "Gym", emoji: "🏋️", colorHex: "#34C759")
        gym.createdAt = instant(1_750_200_000)
        gym.updatedAt = nil
        gym.sortOrder = 3
        gym.scheduleKind = HabitSchedule.specificDays.rawValue
        gym.activeDaysMask = 0b0101010 // Mon, Wed, Fri
        gym.isArchived = true
        gym.groupId = UUID() // the group was deleted on another device

        let read = Habit(name: "Read", emoji: "📚", colorHex: "#AF52DE")
        read.createdAt = instant(1_750_300_000)
        read.updatedAt = instant(1_750_300_100)
        read.sortOrder = 2
        read.note = ""

        for habit in [water, gym, read] { context.insert(habit) }

        let partial = HabitRecord(date: dayKey(2026, 9, 1), note: "only 2, \"tired\"", value: 2)
        partial.updatedAt = instant(1_756_700_000)
        let full = HabitRecord(date: dayKey(2026, 9, 2), note: nil, value: 8)
        full.updatedAt = nil
        let over = HabitRecord(date: dayKey(2026, 9, 3), note: "", value: 9.5)
        water.records.append(contentsOf: [partial, full, over])

        let monday = HabitRecord(date: dayKey(2026, 9, 7), note: "leg day\r\nsquats")
        monday.updatedAt = instant(1_757_200_000)
        gym.records.append(monday)

        // Read has no check-ins at all: it must still come back.
        try context.save()
        return [water, gym, read]
    }

    private func export(_ context: ModelContext, at date: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws -> Data {
        try DataBackup.encode(DataBackup.snapshot(of: context, exportedAt: date))
    }

    private func assertSameInstant(_ a: Date?, _ b: Date?, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (nil, nil): return
        case let (a?, b?):
            XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.000_5, what, file: file, line: line)
        default:
            XCTFail("\(what): \(String(describing: a)) vs \(String(describing: b))", file: file, line: line)
        }
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func assertDecodeFails(_ data: Data, with expected: DataBackupError,
                                   limits: DataBackup.Limits = .default,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DataBackup.decode(data, limits: limits), file: file, line: line) { error in
            XCTAssertEqual(error as? DataBackupError, expected, "\(error)", file: file, line: line)
        }
    }

    /// A valid v2 document as a JSON object, for tests that corrupt one field.
    private func validObject() throws -> [String: Any] {
        try populate(context)
        return try JSONSerialization.jsonObject(with: export(context)) as! [String: Any]
    }

    // MARK: - Round trip

    func testExportThenRestoreIntoEmptyStoreReproducesEverything() throws {
        let originals = try populate(context)
        let groupsBefore = try context.fetch(FetchDescriptor<HabitGroup>())
        let data = try export(context)

        let document = try DataBackup.decode(data)
        let restored = freshContext()
        try DataBackup.restore(document, into: restored, withdrawingDeletionsFrom: nil)

        let before = try counts(context)
        let after = try counts(restored)
        XCTAssertEqual(after.habits, before.habits)
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(after.groups, before.groups)
        XCTAssertEqual(after.habits, 3)
        XCTAssertEqual(after.records, 4)
        XCTAssertEqual(after.groups, 2)

        let restoredGroups = Dictionary(uniqueKeysWithValues: try restored.fetch(FetchDescriptor<HabitGroup>()).map { ($0.id, $0) })
        for group in groupsBefore {
            let copy = try XCTUnwrap(restoredGroups[group.id], group.name)
            XCTAssertEqual(copy.name, group.name)
            XCTAssertEqual(copy.colorHex, group.colorHex)
            XCTAssertEqual(copy.sortOrder, group.sortOrder)
            assertSameInstant(copy.createdAt, group.createdAt, "group createdAt")
            assertSameInstant(copy.updatedAt, group.updatedAt, "group updatedAt")
        }

        let restoredHabits = Dictionary(uniqueKeysWithValues: try restored.fetch(FetchDescriptor<Habit>()).map { ($0.id, $0) })
        for habit in originals {
            let copy = try XCTUnwrap(restoredHabits[habit.id], habit.name)
            XCTAssertEqual(copy.name, habit.name)
            XCTAssertEqual(copy.emoji, habit.emoji)
            XCTAssertEqual(copy.colorHex, habit.colorHex)
            assertSameInstant(copy.createdAt, habit.createdAt, "\(habit.name) createdAt")
            // Not touch()ed: a restored backup must not look like a fresh edit to sync.
            assertSameInstant(copy.updatedAt, habit.updatedAt, "\(habit.name) updatedAt")
            XCTAssertEqual(copy.isArchived, habit.isArchived)
            XCTAssertEqual(copy.sortOrder, habit.sortOrder, "sortOrder keeps its fraction")
            XCTAssertEqual(copy.reminderEnabled, habit.reminderEnabled)
            XCTAssertEqual(copy.reminderHour, habit.reminderHour)
            XCTAssertEqual(copy.reminderMinute, habit.reminderMinute)
            XCTAssertEqual(copy.note, habit.note)
            XCTAssertEqual(copy.kind, habit.kind)
            XCTAssertEqual(copy.targetValue, habit.targetValue)
            XCTAssertEqual(copy.unit, habit.unit)
            XCTAssertEqual(copy.scheduleKind, habit.scheduleKind)
            XCTAssertEqual(copy.timesPerWeek, habit.timesPerWeek)
            XCTAssertEqual(copy.activeDaysMask, habit.activeDaysMask)
            XCTAssertEqual(copy.groupId, habit.groupId)

            // Linkage: each check-in comes back under the same habit, with the same fields.
            XCTAssertEqual(copy.records.count, habit.records.count, "\(habit.name) check-in count")
            let copies = Dictionary(uniqueKeysWithValues: copy.records.map { ($0.id, $0) })
            for record in habit.records {
                let r = try XCTUnwrap(copies[record.id], "\(habit.name) \(record.date)")
                XCTAssertEqual(r.date, record.date)
                XCTAssertTrue(HabitCalendar.isDayKey(r.date))
                XCTAssertEqual(r.value, record.value)
                XCTAssertEqual(r.note, record.note)
                assertSameInstant(r.updatedAt, record.updatedAt, "record updatedAt")
            }
            // And what the user sees is the same.
            XCTAssertEqual(copy.currentStreak(from: dayKey(2026, 9, 8)), habit.currentStreak(from: dayKey(2026, 9, 8)))
            XCTAssertEqual(copy.loggedValue(on: dayKey(2026, 9, 1)), habit.loggedValue(on: dayKey(2026, 9, 1)))
        }

        // The strongest form of "lossless": exporting the restored store gives the same bytes.
        XCTAssertEqual(try export(restored), data)
    }

    func testExportIsDeterministicWhateverTheInsertionOrder() throws {
        try populate(context)
        let first = try export(context)
        XCTAssertEqual(try export(context), first)

        // The same rows inserted in reverse order into another store.
        let document = try DataBackup.decode(first)
        var reversed = document
        reversed.habits = document.habits.reversed().map { habit in
            var h = habit
            h.records = habit.records.reversed()
            return h
        }
        reversed.groups = document.groups.reversed()
        let other = freshContext()
        try DataBackup.restore(reversed, into: other, withdrawingDeletionsFrom: nil)
        XCTAssertEqual(try export(other), first)
    }

    func testDocumentShapeAndOrdering() throws {
        try populate(context)
        let object = try JSONSerialization.jsonObject(with: export(context)) as! [String: Any]
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["exportedAt"] as? String, "2026-09-21T14:13:20.000Z")

        let habits = try XCTUnwrap(object["habits"] as? [[String: Any]])
        // sortOrder order: Read (2), Gym (3), Drink water (1.75e9).
        XCTAssertEqual(habits.map { $0["name"] as? String }, ["Read", "Gym", "Drink water"])
        let water = habits[2]
        for key in ["id", "createdAt", "updatedAt", "kind", "targetValue", "unit", "scheduleKind", "timesPerWeek",
                    "activeDaysMask", "groupId", "reminderEnabled", "reminderHour", "reminderMinute",
                    "isArchived", "sortOrder", "note", "records", "emoji", "colorHex"] {
            XCTAssertNotNil(water[key], "missing \(key)")
        }
        let records = try XCTUnwrap(water["records"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["date"] as? String }, ["2026-09-01", "2026-09-02", "2026-09-03"])
        XCTAssertEqual(records.map { $0["value"] as? Double }, [2, 8, 9.5])
    }

    func testDayKeysSurviveAZoneWestOfUTC() throws {
        // The day-key is written from UTC, not the local calendar: exported in New York, a
        // 2026-09-01 check-in must not read "2026-08-31". (Invisible from UTC+9, where the
        // project is developed — the class of bug the Specific-days streak shipped with.)
        let savedZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = savedZone }
        let habit = Habit(name: "Walk")
        context.insert(habit)
        habit.records.append(HabitRecord(date: dayKey(2026, 9, 1)))
        try context.save()
        let document = DataBackup.snapshot(habits: [habit], groups: [])
        XCTAssertEqual(document.habits[0].records[0].date, "2026-09-01")
    }

    // MARK: - Restore refuses a populated store

    func testRestoreIntoNonEmptyStoreThrowsAndChangesNothing() throws {
        try populate(context)
        let document = try DataBackup.decode(try export(context))

        // One variant per model: any single row makes the store "not empty".
        let variants: [(String, (ModelContext) -> Void)] = [
            ("a habit", { $0.insert(Habit(name: "Existing")) }),
            ("an orphan check-in", { $0.insert(HabitRecord(date: self.dayKey(2026, 1, 1))) }),
            ("a group", { $0.insert(HabitGroup(name: "Existing")) }),
        ]
        for (label, seed) in variants {
            let target = freshContext()
            seed(target)
            try target.save()
            let before = try counts(target)

            XCTAssertThrowsError(try DataBackup.restore(document, into: target, withdrawingDeletionsFrom: nil), label) { error in
                XCTAssertEqual(error as? DataBackupError, .storeNotEmpty, label)
            }
            let after = try counts(target)
            XCTAssertEqual(after.habits, before.habits, label)
            XCTAssertEqual(after.records, before.records, label)
            XCTAssertEqual(after.groups, before.groups, label)
        }
    }

    // MARK: - Files that are not a v2 backup

    func testVersion1ExportIsRecognisedAndRefused() {
        // Exactly what 1.2.3's exportJSON wrote.
        let v1 = json([
            "exportDate": "2026-09-20",
            "habits": [[
                "name": "Gym", "emoji": "🏋️", "color": "#34C759", "createdAt": "2026-01-01",
                "isArchived": false,
                "completions": [["date": "2026-09-01"], ["date": "2026-09-02", "note": "x"]],
            ]],
        ])
        assertDecodeFails(v1, with: .version1Export)
        // A v1 file with no habits at all is still a v1 file.
        assertDecodeFails(json(["exportDate": "2026-09-20", "habits": []]), with: .version1Export)
    }

    func testGarbageIsNotABackup() {
        assertDecodeFails(Data("hello, world".utf8), with: .notABackup)
        assertDecodeFails(Data(), with: .notABackup)
        assertDecodeFails(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]), with: .notABackup) // a JPEG header
        assertDecodeFails(Data("[]".utf8), with: .notABackup)
        assertDecodeFails(Data("{}".utf8), with: .notABackup)
        assertDecodeFails(json(["schemaVersion": "2"]), with: .notABackup)
        assertDecodeFails(json(["schemaVersion": 0, "habits": []]), with: .notABackup)
    }

    func testNewerVersionAsksForAnUpdate() throws {
        var object = try validObject()
        object["schemaVersion"] = 3
        assertDecodeFails(json(object), with: .newerVersion(3))
        // A v3 file whose shape changed so it no longer decodes as v2 is still "newer".
        assertDecodeFails(json(["schemaVersion": 3, "items": []]), with: .newerVersion(3))
    }

    func testMissingFieldIsMalformed() throws {
        var object = try validObject()
        var habits = object["habits"] as! [[String: Any]]
        habits[0].removeValue(forKey: "scheduleKind")
        object["habits"] = habits
        XCTAssertThrowsError(try DataBackup.decode(json(object))) { error in
            guard case .malformed(let detail)? = error as? DataBackupError else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(detail.contains("scheduleKind"), detail)
        }
    }

    // MARK: - Bounds

    /// Numbers the app converts with `Int(…)` — a check-in's value and a count habit's target in
    /// TodayView and the Siri reply, `sortOrder` on every sync push — trap past `Int.max`, and
    /// JSONDecoder accepts `1e19`. Restored, Today (the first tab) trapped on every launch. The
    /// other fields hold only what the app itself writes, so nothing unknown is restored.
    func testOutOfRangeFieldsAreMalformed() throws {
        let object = try validObject()
        let habits = object["habits"] as! [[String: Any]]
        let withRecords = try XCTUnwrap(habits.firstIndex { !($0["records"] as! [Any]).isEmpty })

        func assertMalformed(_ label: String, _ mutate: (inout [String: Any]) -> Void,
                             line: UInt = #line) {
            var copy = object
            mutate(&copy)
            XCTAssertThrowsError(try DataBackup.decode(json(copy)), label, line: line) { error in
                guard case .malformed? = error as? DataBackupError else {
                    return XCTFail("\(label): expected malformed, got \(error)", line: line)
                }
            }
        }
        func habitField(_ key: String, _ value: Any) -> (inout [String: Any]) -> Void {
            { object in
                var list = object["habits"] as! [[String: Any]]
                list[withRecords][key] = value
                object["habits"] = list
            }
        }

        assertMalformed("record value 1e19") { object in
            var list = object["habits"] as! [[String: Any]]
            var records = list[withRecords]["records"] as! [[String: Any]]
            records[0]["value"] = 1e19
            list[withRecords]["records"] = records
            object["habits"] = list
        }
        assertMalformed("group sortOrder 1e19") { object in
            var groups = object["groups"] as! [[String: Any]]
            groups[0]["sortOrder"] = 1e19
            object["groups"] = groups
        }
        let cases: [(String, Any)] = [
            ("targetValue", 1e19), ("targetValue", -1e19), ("sortOrder", 1e19),
            ("reminderHour", 24), ("reminderHour", -1), ("reminderMinute", 60),
            ("timesPerWeek", 0), ("timesPerWeek", 8), ("activeDaysMask", 128),
            ("kind", "timer"), ("scheduleKind", "hourly"),
        ]
        for (key, value) in cases {
            assertMalformed("\(key) = \(value)", habitField(key, value))
        }

        // The edges the app itself can write still restore.
        var edges = object
        habitField("reminderHour", 23)(&edges)
        habitField("reminderMinute", 59)(&edges)
        habitField("timesPerWeek", 7)(&edges)
        habitField("activeDaysMask", 0)(&edges)
        habitField("targetValue", 1_000)(&edges)
        habitField("sortOrder", 1_790_000_000.5)(&edges)
        XCTAssertNoThrow(try DataBackup.decode(json(edges)))
    }

    func testOversizedFileIsRefusedBeforeParsing() throws {
        try populate(context)
        let data = try export(context)
        var limits = DataBackup.Limits()
        limits.maxBytes = data.count - 1
        assertDecodeFails(data, with: .fileTooLarge(bytes: data.count, limit: data.count - 1), limits: limits)
        // Even bytes that are not JSON at all: the size check comes first.
        assertDecodeFails(Data(repeating: 0x41, count: 101), with: .fileTooLarge(bytes: 101, limit: 100),
                          limits: DataBackup.Limits(maxBytes: 100))
    }

    func testCountLimits() throws {
        try populate(context)
        let data = try export(context)
        assertDecodeFails(data, with: .tooManyHabits(count: 3, limit: 2), limits: DataBackup.Limits(maxHabits: 2))
        assertDecodeFails(data, with: .tooManyGroups(count: 2, limit: 1), limits: DataBackup.Limits(maxGroups: 1))
        assertDecodeFails(data, with: .tooManyRecords(count: 4, limit: 3), limits: DataBackup.Limits(maxRecords: 3))
        XCTAssertNoThrow(try DataBackup.decode(data, limits: DataBackup.Limits(maxHabits: 3, maxGroups: 2, maxRecords: 4)))
    }

    // MARK: - Duplicates and dates

    func testDuplicateIdsAreRefused() throws {
        let base = try validObject()
        var habits = base["habits"] as! [[String: Any]]
        let groups = base["groups"] as! [[String: Any]]

        // Two habits, one id — in different case, which is still the same UUID.
        var dupHabit = base
        var h = habits
        h[1]["id"] = (h[0]["id"] as! String).lowercased()
        dupHabit["habits"] = h
        assertDecodeFails(json(dupHabit), with: .duplicateID(.habit, UUID(uuidString: habits[0]["id"] as! String)!))

        // One check-in id under two different habits.
        var dupRecord = base
        let waterRecords = habits[2]["records"] as! [[String: Any]]
        var gymRecords = habits[1]["records"] as! [[String: Any]]
        gymRecords[0]["id"] = waterRecords[0]["id"]
        habits[1]["records"] = gymRecords
        dupRecord["habits"] = habits
        // Gym (index 1) comes before Drink water (index 2), so the repeat is found under water.
        assertDecodeFails(json(dupRecord), with: .duplicateID(.record, UUID(uuidString: waterRecords[0]["id"] as! String)!))

        var dupGroup = base
        var g = groups
        g[1]["id"] = g[0]["id"]
        dupGroup["groups"] = g
        assertDecodeFails(json(dupGroup), with: .duplicateID(.group, UUID(uuidString: groups[0]["id"] as! String)!))
    }

    func testTwoCheckInsOnOneDayAreRefused() throws {
        var object = try validObject()
        var habits = object["habits"] as! [[String: Any]]
        var records = habits[2]["records"] as! [[String: Any]]
        records[1]["date"] = records[0]["date"]
        habits[2]["records"] = records
        object["habits"] = habits
        assertDecodeFails(json(object), with: .duplicateDay(habit: UUID(uuidString: habits[2]["id"] as! String)!,
                                                            day: "2026-09-01"))
    }

    func testBadDatesAreRefused() throws {
        let base = try validObject()
        for bad in ["2026-13-01", "2026-02-30", "2026-9-5", "09/01/2026", "", "1900-01-01", "2026-09-01T00:00:00Z"] {
            var object = base
            var habits = object["habits"] as! [[String: Any]]
            var records = habits[2]["records"] as! [[String: Any]]
            records[0]["date"] = bad
            habits[2]["records"] = records
            object["habits"] = habits
            XCTAssertThrowsError(try DataBackup.decode(json(object)), bad) { error in
                guard case .invalidDate? = error as? DataBackupError else {
                    return XCTFail("\(bad): expected invalidDate, got \(error)")
                }
            }
        }

        var object = base
        var habits = object["habits"] as! [[String: Any]]
        habits[0]["createdAt"] = "yesterday"
        object["habits"] = habits
        XCTAssertThrowsError(try DataBackup.decode(json(object))) { error in
            guard case .invalidDate(let detail)? = error as? DataBackupError else {
                return XCTFail("expected invalidDate, got \(error)")
            }
            XCTAssertTrue(detail.contains("createdAt"), detail)
        }
    }

    func testTimestampsWithoutMillisecondsAreAccepted() throws {
        // A hand-edited file, or one another tool wrote, may drop the fraction.
        var object = try validObject()
        object["exportedAt"] = "2026-09-21T14:13:20Z"
        let document = try DataBackup.decode(json(object))
        XCTAssertEqual(document.exportedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    // MARK: - A store the old reconciler left duplicates in

    func testStoreWithDuplicateIdsStillExportsARestorableBackup() throws {
        // Before 1.2.3 a lowercase server id inserted a second habit with the same UUID, and
        // nothing removed it. A backup of such a store must still restore.
        let shared = UUID()
        let stale = Habit(name: "Run (old copy)")
        stale.id = shared
        stale.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let current = Habit(name: "Run")
        current.id = shared
        current.updatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        context.insert(stale)
        context.insert(current)
        stale.records.append(HabitRecord(date: dayKey(2026, 9, 1), value: 1))
        let older = HabitRecord(date: dayKey(2026, 9, 2), note: "older", value: 1)
        older.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = HabitRecord(date: dayKey(2026, 9, 2), note: "newer", value: 1)
        newer.updatedAt = Date(timeIntervalSince1970: 1_760_000_000)
        current.records.append(contentsOf: [older, newer])
        try context.save()

        let document = try DataBackup.decode(try export(context))
        XCTAssertEqual(document.habits.count, 1)
        XCTAssertEqual(document.habits[0].name, "Run", "the most recently edited copy wins")
        XCTAssertEqual(document.habits[0].records.map(\.date), ["2026-09-01", "2026-09-02"],
                       "check-ins of both copies are kept, one per day")
        XCTAssertEqual(document.habits[0].records[1].note, "newer")

        let target = freshContext()
        try DataBackup.restore(document, into: target, withdrawingDeletionsFrom: nil)
        XCTAssertEqual(try counts(target).habits, 1)
        XCTAssertEqual(try counts(target).records, 2)
    }

    // MARK: - Preview

    func testPreviewCountsAndDateRange() throws {
        try populate(context)
        let preview = DataBackup.preview(of: try DataBackup.decode(try export(context)))
        XCTAssertEqual(preview.habits, 3)
        XCTAssertEqual(preview.archivedHabits, 1)
        XCTAssertEqual(preview.checkIns, 4)
        XCTAssertEqual(preview.groups, 2)
        XCTAssertEqual(preview.firstDay, dayKey(2026, 9, 1))
        XCTAssertEqual(preview.lastDay, dayKey(2026, 9, 7))
        XCTAssertEqual(preview.exportedAt, Date(timeIntervalSince1970: 1_790_000_000))

        let empty = DataBackup.preview(of: DataBackup.snapshot(habits: [], groups: [], exportedAt: .distantPast))
        XCTAssertEqual(empty.checkIns, 0)
        XCTAssertNil(empty.firstDay)
        XCTAssertNil(empty.lastDay)
    }

    // MARK: - CSV

    /// RFC 4180, enough to read back what `csv` writes.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.unicodeScalars.append(c) }
        }
        row.append(field); rows.append(row)
        return rows
    }

    func testCSVHasTheNewColumnsAndEscapesNamesAndNotes() throws {
        try populate(context)
        let tricky = Habit(name: "Say \"hi\", then\nleave", emoji: "👋")
        context.insert(tricky)
        tricky.records.append(HabitRecord(date: dayKey(2026, 9, 5), note: "a,b \"c\"\nd"))
        try context.save()

        let data = DataBackup.csvData(try DataBackup.snapshot(of: context))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 BOM, so Excel reads emoji and CJK")
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let rows = parseCSV(text)

        XCTAssertEqual(rows[0], ["habit_name", "emoji", "date", "note", "created_at",
                                 "value", "target", "unit", "schedule"])
        XCTAssertEqual(rows.count, 1 + 5, "one row per check-in")
        XCTAssertTrue(rows.allSatisfy { $0.count == 9 }, "\(rows)")

        let byKey = Dictionary(uniqueKeysWithValues: rows.dropFirst().map { ("\($0[0])|\($0[2])", $0) })
        let partial = try XCTUnwrap(byKey["Drink water|2026-09-01"])
        XCTAssertEqual(partial[3], "only 2, \"tired\"")
        XCTAssertEqual(Array(partial[5...8]), ["2", "8", "glasses", "5/week"])
        XCTAssertEqual(try XCTUnwrap(byKey["Drink water|2026-09-03"])[5], "9.5")

        let gym = try XCTUnwrap(byKey["Gym|2026-09-07"])
        XCTAssertEqual(gym[3], "leg day\r\nsquats")
        XCTAssertEqual(Array(gym[5...8]), ["1", "", "", "Mon Wed Fri"], "no target or unit for done/not-done")

        let hi = try XCTUnwrap(byKey["Say \"hi\", then\nleave|2026-09-05"])
        XCTAssertEqual(hi[1], "👋")
        XCTAssertEqual(hi[3], "a,b \"c\"\nd")
        XCTAssertEqual(hi[8], "daily")
    }

    /// Deliberate, see `DataBackup.csv`: cells that a spreadsheet may read as a formula are
    /// written as the user typed them, not prefixed. The file holds only the user's own words,
    /// and every prefix shows up as a stray character in some spreadsheet app.
    func testCSVWritesFormulaLookingCellsAsTyped() {
        XCTAssertEqual(DataBackup.csvField("- felt good"), "- felt good")
        XCTAssertEqual(DataBackup.csvField("+1 glass"), "+1 glass")
        XCTAssertEqual(DataBackup.csvField("@gym"), "@gym")
        XCTAssertEqual(DataBackup.csvField("=SUM(A1)"), "=SUM(A1)")
    }

    func testCSVFieldQuoting() {
        XCTAssertEqual(DataBackup.csvField("plain"), "plain")
        XCTAssertEqual(DataBackup.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(DataBackup.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(DataBackup.csvField("a\nb"), "\"a\nb\"")
        XCTAssertEqual(DataBackup.csvField("a\r\nb"), "\"a\r\nb\"", "CRLF is one Character in Swift")
        XCTAssertEqual(DataBackup.csvField("a\rb"), "\"a\rb\"")
    }

    /// "I deleted it by mistake: erase, restore yesterday's backup." The deletion is still
    /// queued (erase leaves the queues alone; the widget queues un-checks in the app group), and
    /// the first sync after signing in would push the tombstone ahead of the restored row — the
    /// server keeps the deletion and the full pull removes the restored copy. Restore withdraws
    /// exactly the ids it brought back, and only once the save succeeded.
    func testRestoreWithdrawsQueuedDeletionsOfTheRestoredIdsOnly() throws {
        let source = freshContext()
        let habits = try populate(source)
        let document = try DataBackup.decode(try export(source))
        let restoredHabit = try XCTUnwrap(document.habits.first { !$0.records.isEmpty })
        let restoredRecord = try XCTUnwrap(restoredHabit.records.first)
        let restoredGroup = try XCTUnwrap(document.groups.first)
        XCTAssertFalse(habits.isEmpty)

        // Fixed names, emptied first: UUID-named suites leave a plist each behind for good.
        let localSuite = "stride.tests.backup.withdraw.local"
        let sharedSuite = "stride.tests.backup.withdraw.shared"
        let local = UserDefaults(suiteName: localSuite)!
        let shared = UserDefaults(suiteName: sharedSuite)!
        local.removePersistentDomain(forName: localSuite)
        shared.removePersistentDomain(forName: sharedSuite)
        defer {
            local.removePersistentDomain(forName: localSuite)
            shared.removePersistentDomain(forName: sharedSuite)
        }
        let queue = SyncDeletionQueue(local: local, shared: shared)
        queue.trackHabit(restoredHabit.id.uuidString)
        queue.trackHabit("H-UNRELATED")
        queue.trackEntry(restoredRecord.id.uuidString)
        queue.trackSharedEntry(restoredRecord.id.uuidString)   // un-checked in the widget
        queue.trackSharedEntry("E-UNRELATED")
        queue.trackGroup(restoredGroup.id.uuidString)

        // A restore that is refused withdraws nothing.
        let occupied = freshContext()
        occupied.insert(Habit(name: "Existing"))
        try occupied.save()
        let queuedBefore = queue.pending()
        XCTAssertThrowsError(try DataBackup.restore(document, into: occupied, withdrawingDeletionsFrom: queue))
        XCTAssertEqual(queue.pending(), queuedBefore)

        try DataBackup.restore(document, into: context, withdrawingDeletionsFrom: queue)

        XCTAssertEqual(queue.pending(), SyncDeletionQueue.Batch(
            habits: ["H-UNRELATED"], entries: ["E-UNRELATED"], groups: []))
    }

    // MARK: - The account a backup was made under (1.3.1)

    private let accountA = BackupAccount(id: "41", email: "a@example.com")
    private let accountB = BackupAccount(id: "42", email: "b@example.com")

    /// The file records the store's owner, from the caller; a store with none records nothing,
    /// and the keys are left out rather than written as null, so a 1.3.0 restorer (which ignores
    /// unknown keys) and a 1.3.1 one read the same file.
    func testBackupRecordsTheOwnerAccountAndOmitsItWithoutOne() throws {
        try populate(context)
        let with = try DataBackup.encode(DataBackup.snapshot(of: context, exportedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                                             account: accountA))
        let object = try JSONSerialization.jsonObject(with: with) as! [String: Any]
        XCTAssertEqual(object["accountId"] as? String, "41")
        XCTAssertEqual(object["accountEmail"] as? String, "a@example.com")
        XCTAssertEqual(object["schemaVersion"] as? Int, 2, "optional fields: still v2")
        XCTAssertEqual(try DataBackup.decode(with).account, accountA)

        let without = try JSONSerialization.jsonObject(with: export(context)) as! [String: Any]
        XCTAssertNil(without["accountId"])
        XCTAssertNil(without["accountEmail"])

        // Apart from the two keys, the same file.
        var stripped = object
        stripped.removeValue(forKey: "accountId")
        stripped.removeValue(forKey: "accountEmail")
        XCTAssertEqual(NSDictionary(dictionary: stripped), NSDictionary(dictionary: without))
    }

    /// A 1.3.0 backup has no account. It still decodes as v2, and the restore offers new copies
    /// — with keeping the ids still available, since it may be this same account's.
    func testA130BackupWithoutAnAccountOffersCopies() throws {
        let document = try DataBackup.decode(json(try validObject()))
        XCTAssertNil(document.accountId)
        XCTAssertNil(document.account)

        let signedIn = DataBackup.restoreDecision(for: document, device: .signedIn(accountB))
        XCTAssertTrue(signedIn.offersCopies)
        XCTAssertEqual(signedIn.plan, RestorePlan(identity: .newCopies, owner: accountB))
        XCTAssertEqual(signedIn.keepIDsInstead, RestorePlan(identity: .keepIDs, owner: accountB))

        let signedOut = DataBackup.restoreDecision(for: document, device: .signedOut(next: nil))
        XCTAssertEqual(signedOut.plan, RestorePlan(identity: .newCopies, owner: nil))
        XCTAssertEqual(signedOut.keepIDsInstead, RestorePlan(identity: .keepIDs, owner: nil))
    }

    /// Neither field is data the user could lose, so one that cannot be read never costs the
    /// whole backup: it reads as "no account", which offers copies — safe whatever the file is.
    func testAccountFieldsThatCannotBeReadCountAsNone() throws {
        var object = try validObject()
        object["accountId"] = 41
        XCTAssertEqual(try DataBackup.decode(json(object)).accountId, "41", "APIUser.id is a number on the server")

        object["accountId"] = ["nested": true]
        object["accountEmail"] = 7.5
        let odd = try DataBackup.decode(json(object))
        XCTAssertNil(odd.account)
        XCTAssertNil(odd.accountEmail)
        XCTAssertEqual(odd.habits.count, 3)

        object["accountId"] = "  "
        XCTAssertNil(try DataBackup.decode(json(object)).account)
    }

    /// DEV-PLAN-1.3.md M2, "Restore into another account": keep the ids only for the account
    /// this device syncs as; otherwise copies, owned by the signed-in account, or by nobody when
    /// signed out (review 2).
    func testRestoreDecisionTable() {
        typealias Case = (String, BackupAccount?, RestoreDevice, RestorePlan, RestorePlan?)
        let cases: [Case] = [
            ("same account, signed in", accountA, .signedIn(accountA),
             RestorePlan(identity: .keepIDs, owner: accountA), nil),
            ("same id, the email changed since", BackupAccount(id: "41", email: "old@example.com"), .signedIn(accountA),
             RestorePlan(identity: .keepIDs, owner: accountA), nil),
            ("another account, signed in", accountA, .signedIn(accountB),
             RestorePlan(identity: .newCopies, owner: accountB), nil),
            ("no account, signed in", nil, .signedIn(accountB),
             RestorePlan(identity: .newCopies, owner: accountB), RestorePlan(identity: .keepIDs, owner: accountB)),
            ("signed out, the user will sign into the backup's account", accountA, .signedOut(next: accountA),
             RestorePlan(identity: .keepIDs, owner: accountA), nil),
            ("signed out, another account next", accountA, .signedOut(next: accountB),
             RestorePlan(identity: .newCopies, owner: nil), nil),
            ("signed out, the user did not say", accountA, .signedOut(next: nil),
             RestorePlan(identity: .newCopies, owner: nil), nil),
            ("signed out, no account, an account next", nil, .signedOut(next: accountB),
             RestorePlan(identity: .newCopies, owner: nil), RestorePlan(identity: .keepIDs, owner: accountB)),
        ]
        for (label, backup, device, plan, alternative) in cases {
            let decision = DataBackup.restoreDecision(backupAccount: backup, device: device)
            XCTAssertEqual(decision.plan, plan, label)
            XCTAssertEqual(decision.keepIDsInstead, alternative, label)
        }
    }

    /// "Restore as new copies": every habit, check-in and group gets a fresh id; each check-in is
    /// on its own habit and each habit in its own group, as many as in the file; the history and
    /// its edit stamps are the file's; nothing is delivered or restored-with-ids, and a deletion
    /// queued for an OLD id stays queued.
    func testRestoreAsNewCopiesGivesFreshIdsWithTheFilesLinkage() throws {
        let source = freshContext()
        try populate(source)
        let document = try DataBackup.decode(try DataBackup.encode(DataBackup.snapshot(of: source, account: accountA)))
        let fileIDs = Set(document.groups.map(\.id) + document.habits.map(\.id)
                          + document.habits.flatMap { $0.records.map(\.id) })

        let localSuite = "stride.tests.backup.copies.local"
        let local = UserDefaults(suiteName: localSuite)!
        local.removePersistentDomain(forName: localSuite)
        defer { local.removePersistentDomain(forName: localSuite) }
        let queue = SyncDeletionQueue(local: local, shared: nil)
        let queuedHabit = try XCTUnwrap(document.habits.first).id.uuidString
        queue.trackHabit(queuedHabit)

        let preview = try DataBackup.restore(document, into: context, identity: .newCopies,
                                             withdrawingDeletionsFrom: queue)
        XCTAssertEqual(preview.habits, 3)
        XCTAssertEqual(preview.checkIns, 4)
        XCTAssertEqual(queue.pending().habits, [queuedHabit], "the old id's deletion still means what it meant")

        let groups = try context.fetch(FetchDescriptor<HabitGroup>())
        let habits = try context.fetch(FetchDescriptor<Habit>())
        let records = try context.fetch(FetchDescriptor<HabitRecord>())
        XCTAssertEqual(groups.count, document.groups.count)
        XCTAssertEqual(habits.count, document.habits.count)
        XCTAssertEqual(records.count, document.habits.reduce(0) { $0 + $1.records.count })
        let storeIDs = Set(groups.map(\.id) + habits.map(\.id) + records.map(\.id))
        XCTAssertEqual(storeIDs.count, fileIDs.count, "every id is distinct")
        XCTAssertTrue(storeIDs.isDisjoint(with: fileIDs), "no id of the file survives")

        // Linkage, counted the same way on both sides: record → habit, habit → group.
        let fileGroupNames = Dictionary(uniqueKeysWithValues: document.groups.map { ($0.id, $0.name) })
        let storeGroupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        for item in document.habits {
            let copy = try XCTUnwrap(habits.first { $0.name == item.name }, item.name)
            XCTAssertEqual(copy.records.count, item.records.count, "\(item.name) check-ins")
            XCTAssertEqual(Set(copy.records.map(\.date)), Set(item.records.compactMap { DataBackup.dayKey($0.date) }))
            assertSameInstant(copy.createdAt, item.createdAt, "\(item.name) createdAt kept")
            assertSameInstant(copy.updatedAt, item.updatedAt, "\(item.name) updatedAt kept")
            if let old = item.groupId, let name = fileGroupNames[old] {
                XCTAssertEqual(copy.groupId.flatMap { storeGroupNames[$0] }, name, "\(item.name) follows its group")
            } else {
                XCTAssertEqual(copy.groupId, item.groupId, "a group not in the file is kept as it was")
            }
        }
        XCTAssertEqual(habits.filter { $0.groupId.map(storeGroupNames.keys.contains) ?? false }.count,
                       document.habits.filter { $0.groupId.map(fileGroupNames.keys.contains) ?? false }.count)

        // New rows: never delivered, not restored-with-ids, not held — all pending.
        let rows: [any SyncDeliverable] = groups + habits + records
        for row in rows {
            XCTAssertNil(row.syncedAt)
            XCTAssertNil(row.restoredAt, "new copies are not restored rows")
            XCTAssertNil(row.syncHoldReason)
            XCTAssertTrue(row.isPending)
        }
    }

    /// Keeping the ids marks every row `restoredAt`, so no pull deletes it and a `tombstoned`
    /// answer holds it for the user's choice instead of dropping it.
    func testKeepingIDsMarksEveryRowRestored() throws {
        let source = freshContext()
        try populate(source)
        let document = try DataBackup.decode(try export(source))
        let now = Date(timeIntervalSince1970: 1_790_000_123)

        try DataBackup.restore(document, into: context, identity: .keepIDs, withdrawingDeletionsFrom: nil, now: now)

        let rows: [any SyncDeliverable] = try context.fetch(FetchDescriptor<HabitGroup>())
            + context.fetch(FetchDescriptor<Habit>()) + context.fetch(FetchDescriptor<HabitRecord>())
        XCTAssertEqual(rows.count, 2 + 3 + 4)
        for row in rows {
            XCTAssertEqual(row.restoredAt, now)
            XCTAssertNil(row.syncedAt, "never delivered from this device")
            XCTAssertTrue(row.isPending)
        }
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Habit>()).map(\.id)), Set(document.habits.map(\.id)))
        // The default is keeping the ids, as 1.3.0's restore did.
        let other = freshContext()
        try DataBackup.restore(document, into: other, withdrawingDeletionsFrom: nil)
        XCTAssertTrue(try other.fetch(FetchDescriptor<Habit>()).allSatisfy { $0.restoredAt != nil })
    }

    // MARK: - Erase

    func testEraseDeletesEverythingAndQueuesNoSyncDeletions() throws {
        try populate(context)
        context.insert(HabitRecord(date: dayKey(2026, 1, 1))) // an orphan, from some old bug
        try context.save()

        // Fixed names, emptied first: UUID-named suites leave a plist each behind for good.
        let localSuite = "stride.tests.backup.local"
        let sharedSuite = "stride.tests.backup.shared"
        let local = UserDefaults(suiteName: localSuite)!
        let shared = UserDefaults(suiteName: sharedSuite)!
        local.removePersistentDomain(forName: localSuite)
        shared.removePersistentDomain(forName: sharedSuite)
        defer {
            local.removePersistentDomain(forName: localSuite)
            shared.removePersistentDomain(forName: sharedSuite)
        }
        let queue = SyncDeletionQueue(local: local, shared: shared)
        queue.trackHabit("H-already-queued")
        queue.trackSharedEntry("E-from-widget")
        let queuedBefore = queue.pending()
        // The process's standard defaults are where the app's own queue lives.
        let keys = [SyncDeletionQueue.habitsKey, SyncDeletionQueue.entriesKey, SyncDeletionQueue.groupsKey]
        let standardBefore = keys.map { UserDefaults.standard.stringArray(forKey: $0) }

        try DataBackup.eraseLocalData(in: context)

        let after = try counts(context)
        XCTAssertEqual(after.habits, 0)
        XCTAssertEqual(after.records, 0)
        XCTAssertEqual(after.groups, 0)
        XCTAssertEqual(queue.pending(), queuedBefore)
        XCTAssertEqual(keys.map { UserDefaults.standard.stringArray(forKey: $0) }, standardBefore)

        // And a backup restores into what erase leaves.
        let source = freshContext()
        try populate(source)
        let document = try DataBackup.decode(try export(source))
        XCTAssertNoThrow(try DataBackup.restore(document, into: context, withdrawingDeletionsFrom: nil))
        XCTAssertEqual(try counts(context).habits, 3)
    }
}
