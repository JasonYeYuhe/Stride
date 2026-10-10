import Foundation
import SwiftData

// Lossless backup (JSON, schema v2), the spreadsheet export (CSV), and the restore core.
//
// Up to 1.2.3 "Export Data" was a one-way dump: the JSON carried name/emoji/color/createdAt/
// isArchived and a list of dates, the CSV the same, and neither had a check-in's value, a count
// habit's target or unit, a schedule, a group or a reminder (AUDIT-2026-09-09, "Data export is
// lossy"). A day where the user logged 2 of 8 glasses and a day they logged 8 were the same
// row, and there was no import at all. 1.3.1 changes the sync engine underneath every user
// (DEV-PLAN-1.3.md M2), so 1.3.0 has to give everyone a file that can put their data back.
//
// Everything here is pure or works on a `ModelContext` handed in, and lives in Shared/ so
// StrideTests exercises the code that ships (see README, "The Shared/ rule"). The share sheet
// wrappers and the user-facing error text are in Stride/Sources/Services/DataExportService.swift.

// MARK: - The document

/// The v2 backup file. Field names are the model's own (and the sync wire's), so a reader of
/// the file can map it to `Habit` without a table.
///
/// Timestamps are ISO 8601 in UTC with milliseconds; a check-in's `date` is its day-key as
/// `yyyy-MM-dd` (see `HabitCalendar`). Optionals that are nil are left out of the file, and are
/// restored as nil — a nil `updatedAt` means "never edited since the v2 migration", which is not
/// the same thing as "edited at createdAt" for sync, so it is not filled in.
///
/// `accountId` / `accountEmail` (1.3.1) name the account whose data the store held — its sync
/// owner — when the file was made; both are left out when it had none. They decide whether a
/// restore may keep the file's ids (`DataBackup.restoreDecision`): a 1.3.0 restore always kept
/// them, so a backup made under account A, restored and signed into B, was skipped `not_owned`
/// and then removed from the device by the first full pull (RELEASE-1.3.0.md). Optional fields
/// with `schemaVersion` still 2: a 1.3.0 restorer decodes the file and ignores them, and every
/// 1.3.0 backup, which lacks them, is still a v2 file here.
struct BackupDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var groups: [BackupGroup]
    var habits: [BackupHabit]
    /// `SyncOwner.id`: the server user id, as a string.
    var accountId: String? = nil
    /// For the restore screen ("made with a@example.com"); never compared.
    var accountEmail: String? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, groups, habits, accountId, accountEmail
    }

    /// The account the file was made under, or nil: none recorded (every 1.3.0 backup, a store
    /// that never synced), or an id that is empty.
    var account: BackupAccount? {
        guard let id = accountId, !id.isEmpty else { return nil }
        return BackupAccount(id: id, email: accountEmail ?? "")
    }
}

extension BackupDocument {
    /// The synthesised decoding, except that the two account fields never fail the file.
    ///
    /// Nothing in them is data the user would lose, and they only ever narrow what a restore
    /// offers: an account that cannot be read is treated as "none recorded", which offers new
    /// copies — the choice that is safe whatever account the file came from. Refusing a whole
    /// backup over a hand-edited `accountId` would cost the user every habit in it. A number is
    /// read as its digits (`APIUser.id` is an integer on the server).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        groups = try c.decode([BackupGroup].self, forKey: .groups)
        habits = try c.decode([BackupHabit].self, forKey: .habits)
        func lenient(_ key: CodingKeys) -> String? {
            let text = (try? c.decodeIfPresent(String.self, forKey: key))
                ?? (try? c.decodeIfPresent(Int64.self, forKey: key)).flatMap { $0.map(String.init) }
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
            else { return nil }
            return trimmed
        }
        accountId = lenient(.accountId)
        accountEmail = lenient(.accountEmail)
    }
}

/// A server account as a backup records it: `SyncOwner`'s id and email. Its own type because
/// `SyncOwner` lives in the app target, and this file compiles into StrideTests, the widget and
/// the rehearsal tool too.
struct BackupAccount: Equatable, Sendable {
    var id: String
    var email: String
}

/// How a restore identifies the rows it inserts (`DataBackup.restoreDecision`).
enum RestoreIdentity: Equatable, Sendable {
    /// The file's own ids; every row carries `restoredAt`.
    case keepIDs
    /// Fresh ids for every habit, check-in and group ("Restore as new copies").
    case newCopies
}

/// One way to restore: the identity, and the owner the store gets once the restore has saved.
struct RestorePlan: Equatable, Sendable {
    var identity: RestoreIdentity
    /// nil leaves the store without an owner: the next account signed into adopts it.
    var owner: BackupAccount?
}

/// Where the restore happens.
enum RestoreDevice: Equatable, Sendable {
    case signedIn(BackupAccount)
    /// `next` is the account the user says this device will use next (the restore screen asks
    /// when the file names one), or nil when they did not say.
    case signedOut(next: BackupAccount?)
}

/// What the restore screen offers.
struct RestoreDecision: Equatable, Sendable {
    /// The restore the screen performs on confirm.
    var plan: RestorePlan
    /// Keeping the ids instead, when the user may choose it: only for a file with no account
    /// (a 1.3.0 backup), which may well be this same account's.
    var keepIDsInstead: RestorePlan?

    /// The screen says "Restore as new copies" rather than "Restore".
    var offersCopies: Bool { plan.identity == .newCopies }
}

struct BackupGroup: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Double
    var createdAt: Date
    var updatedAt: Date?
}

struct BackupHabit: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var emoji: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date?
    var isArchived: Bool
    /// Double, as stored. The sync wire sends `Int(sortOrder)`; a backup keeps the fraction.
    var sortOrder: Double
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var note: String?
    var kind: String
    var targetValue: Double
    var unit: String?
    var scheduleKind: String
    var timesPerWeek: Int
    var activeDaysMask: Int
    var groupId: UUID?
    var records: [BackupRecord]
}

/// A check-in. `HabitRecord` has no creation time of its own (sync sends the day as
/// `createdAt`), so the file has none either rather than inventing one.
struct BackupRecord: Codable, Equatable, Sendable {
    var id: UUID
    /// The day-key, `yyyy-MM-dd`.
    var date: String
    var value: Double
    var note: String?
    var updatedAt: Date?
}

/// What a restore would bring back, for the confirmation ("6 habits, 133 check-ins").
struct BackupPreview: Equatable, Sendable {
    var habits: Int
    var archivedHabits: Int
    var checkIns: Int
    var groups: Int
    /// First and last check-in, as UTC day-keys. Format them with a UTC time zone (or
    /// `HabitCalendar.dayStringFormatter`): in a local zone west of UTC a day-key reads as the
    /// evening before.
    var firstDay: Date?
    var lastDay: Date?
    var exportedAt: Date
}

// MARK: - Errors

enum DataBackupError: Error, Equatable {
    enum Row: String, Sendable { case habit, record, group }

    /// Bigger than `Limits.maxBytes`; checked before anything is parsed.
    case fileTooLarge(bytes: Int, limit: Int)
    /// Not JSON, not an object, or an object with neither `schemaVersion` nor the v1 shape.
    case notABackup
    /// The 1.2.3-and-earlier export (`exportDate` + `completions`). It has no ids, values,
    /// targets, schedules, groups or reminders, so restoring it would silently lose all of that.
    case version1Export
    /// From a later app with a format this build cannot read.
    case newerVersion(Int)
    /// A v2 file with a missing or mistyped field. The detail is for logs, not for the user.
    case malformed(String)
    case tooManyHabits(count: Int, limit: Int)
    case tooManyGroups(count: Int, limit: Int)
    case tooManyRecords(count: Int, limit: Int)
    case duplicateID(Row, UUID)
    /// Two check-ins for one habit on one day. The app shows one of them and ignores the other.
    case duplicateDay(habit: UUID, day: String)
    /// A timestamp that does not parse, or a day that is not a canonical `yyyy-MM-dd` in range.
    case invalidDate(String)
    /// `restore` refuses a store that holds any habit, check-in or group.
    case storeNotEmpty
}

// MARK: - Export, decode, validate, restore, erase

enum DataBackup {
    static let schemaVersion = 2

    /// Bounds a file must fit before it is restored. Far above any real account — a hundred
    /// habits checked in daily for ten years is 365,000 check-ins, about 60 MB of this JSON — and
    /// they are there so a wrong file (a photo library export, a log) fails with a clear error
    /// instead of being read into memory and inserted row by row. `snapshot` never produces a
    /// file past them for a store that fits them.
    struct Limits: Equatable, Sendable {
        var maxBytes = 100 * 1024 * 1024
        var maxHabits = 5_000
        var maxGroups = 1_000
        var maxRecords = 500_000

        static let `default` = Limits()
    }

    // MARK: Snapshot

    /// The store as a document, in a deterministic order: groups and habits by `sortOrder`, then
    /// `createdAt`, then id; check-ins by day, then id. Exporting the same store twice gives the
    /// same bytes (apart from `exportedAt`).
    ///
    /// Rows that share an id are folded into one, because a file carrying them could never be
    /// restored (`decode` rejects duplicate ids) and the user would find that out only on the day
    /// they need the backup. Such rows exist: before 1.2.3 the reconciler inserted a second
    /// habit with the same UUID whenever the server sent a lowercase id (SyncReconciler, bug 1),
    /// and nothing ever removed them. The server keys every row by id, so it already holds only
    /// one of each; folding matches it. Per id the most recently edited copy wins, and a
    /// duplicate habit's check-ins are pooled into the one kept. Within a habit a second
    /// check-in on the same day is dropped the same way (newest edit, then larger value) — the
    /// app only ever shows one per day. A check-in id that also appears under an earlier habit
    /// is dropped: on the server it is one row, belonging to one habit.
    ///
    /// `account` is the store's sync owner, passed in by the caller rather than read here: the
    /// owner lives in the app's defaults, and a file must record the account whose ids the rows
    /// carry — the owner, signed in or not — not whoever happens to be signed in.
    static func snapshot(habits: [Habit], groups: [HabitGroup], exportedAt: Date = Date(),
                         account: BackupAccount? = nil) -> BackupDocument {
        let backupGroups = newestPerID(groups.map(backupGroup), id: \.id, edited: { $0.updatedAt ?? $0.createdAt })
            .sorted(by: groupOrder)

        // Fold same-id habits: keep the newest copy's fields, pool every copy's check-ins.
        var pooled: [UUID: [BackupRecord]] = [:]
        for habit in habits {
            pooled[habit.id, default: []].append(contentsOf: habit.records.map(backupRecord))
        }
        var backupHabits = newestPerID(habits.map { backupHabit($0, records: []) },
                                       id: \.id, edited: { $0.updatedAt ?? $0.createdAt })
            .sorted(by: habitOrder)

        var seenRecordIDs = Set<UUID>()
        for index in backupHabits.indices {
            let records = dedupedRecords(pooled[backupHabits[index].id] ?? [])
                .filter { seenRecordIDs.insert($0.id).inserted }
            backupHabits[index].records = records
        }

        // An empty id or email is left out, as nil is: the decoder reads "" as "none" anyway.
        let account = account.flatMap { $0.id.isEmpty ? nil : $0 }
        return BackupDocument(schemaVersion: schemaVersion, exportedAt: exportedAt,
                              groups: backupGroups, habits: backupHabits,
                              accountId: account?.id,
                              accountEmail: account.flatMap { $0.email.isEmpty ? nil : $0.email })
    }

    /// Everything in `context`, as `snapshot` describes.
    @MainActor
    static func snapshot(of context: ModelContext, exportedAt: Date = Date(),
                         account: BackupAccount? = nil) throws -> BackupDocument {
        snapshot(habits: try context.fetch(FetchDescriptor<Habit>()),
                 groups: try context.fetch(FetchDescriptor<HabitGroup>()),
                 exportedAt: exportedAt, account: account)
    }

    // MARK: Encode / decode

    /// Pretty-printed with sorted keys: a backup is also something a person may open and read,
    /// and sorted keys keep the bytes deterministic.
    static func encode(_ document: BackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return try encoder.encode(document)
    }

    /// Reads and validates a v2 backup. Every way a file can be wrong is a `DataBackupError`;
    /// nothing here traps, whatever the bytes are.
    static func decode(_ data: Data, limits: Limits = .default) throws -> BackupDocument {
        guard data.count <= limits.maxBytes else {
            throw DataBackupError.fileTooLarge(bytes: data.count, limit: limits.maxBytes)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = SyncTimestamp.parse(raw) else {
                throw DataBackupError.invalidDate("\(path(decoder.codingPath)): \(raw)")
            }
            return date
        }

        let document: BackupDocument
        do {
            document = try decoder.decode(BackupDocument.self, from: data)
        } catch let error as DataBackupError {
            throw error
        } catch let error as DecodingError {
            // Say what the file IS before saying what is wrong with it: a v1 export or a file
            // from a newer app fails the v2 decode too, and "damaged" would be the wrong answer.
            throw classify(data) ?? DataBackupError.malformed(describe(error))
        } catch {
            throw classify(data) ?? DataBackupError.malformed(String(describing: error))
        }

        switch document.schemaVersion {
        case schemaVersion: break
        case 1: throw DataBackupError.version1Export
        case let v where v > schemaVersion: throw DataBackupError.newerVersion(v)
        default: throw DataBackupError.notABackup
        }

        try validate(document, limits: limits)
        return document
    }

    /// The checks `decode` runs after parsing; `restore` runs them again, since a document can
    /// also be built in code. Throws the first problem found, in a fixed order.
    static func validate(_ document: BackupDocument, limits: Limits = .default) throws {
        guard document.habits.count <= limits.maxHabits else {
            throw DataBackupError.tooManyHabits(count: document.habits.count, limit: limits.maxHabits)
        }
        guard document.groups.count <= limits.maxGroups else {
            throw DataBackupError.tooManyGroups(count: document.groups.count, limit: limits.maxGroups)
        }
        let recordCount = document.habits.reduce(0) { $0 + $1.records.count }
        guard recordCount <= limits.maxRecords else {
            throw DataBackupError.tooManyRecords(count: recordCount, limit: limits.maxRecords)
        }

        var groupIDs = Set<UUID>()
        for group in document.groups {
            guard groupIDs.insert(group.id).inserted else {
                throw DataBackupError.duplicateID(.group, group.id)
            }
            try checkSortOrder(group.sortOrder, "group \(group.id.uuidString)")
        }
        var habitIDs = Set<UUID>()
        var recordIDs = Set<UUID>()
        for habit in document.habits {
            guard habitIDs.insert(habit.id).inserted else {
                throw DataBackupError.duplicateID(.habit, habit.id)
            }
            try checkFields(of: habit)
            var days = Set<String>()
            for record in habit.records {
                guard recordIDs.insert(record.id).inserted else {
                    throw DataBackupError.duplicateID(.record, record.id)
                }
                try checkAmount(record.value, "habit \(habit.id.uuidString) record \(record.id.uuidString) value")
                guard dayKey(record.date) != nil else {
                    throw DataBackupError.invalidDate("habit \(habit.id.uuidString) record \(record.id.uuidString): \(record.date)")
                }
                guard days.insert(record.date).inserted else {
                    throw DataBackupError.duplicateDay(habit: habit.id, day: record.date)
                }
            }
        }
        // A habit whose groupId names no group in the file is NOT an error. Deleting a group on
        // one device clears groupId only on the habits that device has; another device can keep
        // pointing at the deleted group, and the app already shows such a habit as ungrouped
        // (TodayView). Real backups contain it, so it is restored as it was.
        // "A check-in pointing at no habit" cannot occur: check-ins are nested in their habit.
    }

    // MARK: Field bounds

    /// A value or target past this is not something the app can produce (the target stepper
    /// stops at 1,000; a tap adds 1), and it keeps every `Int(value)` in the app far from
    /// `Int.max`. Those conversions trap: TodayView and the Siri reply format a whole-number
    /// value with `String(Int(value))`, and the habit sheet reads the target with
    /// `Int(targetValue)`. A backup holding `1e19` passed decode — JSONDecoder accepts it — and
    /// once restored, Today, the first tab, trapped on every launch; the only way out was
    /// deleting the app. Restore is a new way in for numbers nothing else bounds, so it bounds them.
    static let maxAmount = 1e9
    /// `sortOrder` defaults to the creation time in epoch seconds (~1.8e9), and sync pushes
    /// `Int(sortOrder)` — which traps past `Int.max`, on the first sync after the restore.
    static let maxSortOrder = 1e15

    /// Every field whose value the app relies on staying in range. The reminder, schedule and
    /// kind fields do not trap when wrong, but a restore brings back only states the app itself
    /// writes (DatePicker hours and minutes, the 1…7 stepper, a weekday mask, a known kind):
    /// an unknown `kind` would be shown as done/not-done and silently rewritten on the next edit.
    /// A later format that adds a kind is a new `schemaVersion`.
    private static func checkFields(of habit: BackupHabit) throws {
        let label = "habit \(habit.id.uuidString)"
        try checkSortOrder(habit.sortOrder, label)
        try checkAmount(habit.targetValue, "\(label) targetValue")
        func require(_ ok: Bool, _ field: String) throws {
            guard ok else { throw DataBackupError.malformed("\(label) \(field) out of range") }
        }
        try require(HabitKind(rawValue: habit.kind) != nil, "kind")
        try require(HabitSchedule(rawValue: habit.scheduleKind) != nil, "scheduleKind")
        try require((0...23).contains(habit.reminderHour), "reminderHour")
        try require((0...59).contains(habit.reminderMinute), "reminderMinute")
        try require((1...7).contains(habit.timesPerWeek), "timesPerWeek")
        try require((0...127).contains(habit.activeDaysMask), "activeDaysMask")
    }

    /// Finite and within ±`maxAmount`. Negative is allowed: it cannot trap, and refusing a whole
    /// backup over one odd check-in would cost the user everything else in it.
    private static func checkAmount(_ value: Double, _ label: String) throws {
        guard value.isFinite, abs(value) <= maxAmount else {
            throw DataBackupError.malformed("\(label) out of range")
        }
    }

    private static func checkSortOrder(_ value: Double, _ label: String) throws {
        guard value.isFinite, abs(value) <= maxSortOrder else {
            throw DataBackupError.malformed("\(label) sortOrder out of range")
        }
    }

    /// The day-key for a canonical `yyyy-MM-dd` between 1970 and 2100, or nil. Canonical means it
    /// formats back to the same string, so "2026-9-5" and "2026-02-30" (which DateFormatter
    /// would read leniently or roll over) are both refused.
    static func dayKey(_ string: String) -> Date? {
        guard let date = HabitCalendar.dayStringFormatter.date(from: string),
              HabitCalendar.dayStringFormatter.string(from: date) == string else { return nil }
        let year = HabitCalendar.utc.component(.year, from: date)
        guard (1970...2100).contains(year) else { return nil }
        return date
    }

    // MARK: Preview

    static func preview(of document: BackupDocument) -> BackupPreview {
        let days = document.habits.flatMap { $0.records.compactMap { dayKey($0.date) } }
        return BackupPreview(
            habits: document.habits.count,
            archivedHabits: document.habits.filter(\.isArchived).count,
            checkIns: document.habits.reduce(0) { $0 + $1.records.count },
            groups: document.groups.count,
            firstDay: days.min(),
            lastDay: days.max(),
            exportedAt: document.exportedAt
        )
    }

    // MARK: Restore — which identity the rows come back with

    /// Whether a restore keeps the file's ids or makes new copies, and which account then owns
    /// the store (DEV-PLAN-1.3.md M2, "Restore into another account, and restores the server
    /// has tombstoned"; review 2). Pure: the restore screen (phase C) asks it, shows the choice,
    /// restores with `plan.identity`, and sets the store's owner (`SyncOwnerStore`, in the app)
    /// to `plan.owner` once the restore has saved.
    ///
    /// - The file's account is the signed-in account — or, signed out, the account the user
    ///   says this device will use next → **keep the ids**, and that account owns the store. The
    ///   rows are this account's own; new ids would duplicate every habit the account still holds.
    /// - Anything else — another account, or a file with no account (every 1.3.0 backup) → **new
    ///   copies**. Kept ids would be answered `not_owned` by another account's server rows, held,
    ///   and resolvable only by converting them later; copies are that conversion done up front.
    ///   Signed in, the signed-in account owns the store: the user confirmed the copies into it,
    ///   and with no owner the gate would block every sync until a sign-in that never comes (the
    ///   first draft's mistake). Signed out, the store is left without an owner, for the next
    ///   sign-in to adopt.
    /// - A file with no account may still be this account's own 1.3.0 backup, so keeping the ids
    ///   stays available for it (`keepIDsInstead`). If it was in fact another account's, the push
    ///   answers `not_owned` and the rows are held with the same "Restore as new copies" action
    ///   (`SyncCopies.reidentify`); held, no full pull deletes them.
    ///
    /// Ids compare exactly; the email is only for display and is never compared (an account can
    /// change its email).
    static func restoreDecision(for document: BackupDocument, device: RestoreDevice) -> RestoreDecision {
        restoreDecision(backupAccount: document.account, device: device)
    }

    static func restoreDecision(backupAccount: BackupAccount?, device: RestoreDevice) -> RestoreDecision {
        let owner: BackupAccount?     // who owns the store after a restore of either kind
        let sameAccount: Bool
        switch device {
        case .signedIn(let account):
            owner = account
            sameAccount = backupAccount?.id == account.id
        case .signedOut(let next):
            sameAccount = backupAccount != nil && backupAccount?.id == next?.id
            // Signed out, only keeping the ids names an owner: the account the user said.
            owner = next
        }
        if sameAccount {
            return RestoreDecision(plan: RestorePlan(identity: .keepIDs, owner: owner), keepIDsInstead: nil)
        }
        let copiesOwner: BackupAccount?
        if case .signedIn = device { copiesOwner = owner } else { copiesOwner = nil }
        let copies = RestorePlan(identity: .newCopies, owner: copiesOwner)
        guard backupAccount == nil else { return RestoreDecision(plan: copies, keepIDsInstead: nil) }
        return RestoreDecision(plan: copies, keepIDsInstead: RestorePlan(identity: .keepIDs, owner: owner))
    }

    /// The document with every habit, check-in and group given a fresh id: "Restore as new
    /// copies". Pure; `restore(_:into:identity:…)` inserts it.
    ///
    /// - `habit.groupId` follows its group to the group's new id. A `groupId` naming no group in
    ///   the file (a group deleted on another device — `validate` restores it as it was) is kept
    ///   as it is: it names no row the copy could collide with, and the app shows the habit as
    ///   ungrouped either way.
    /// - Every check-in stays nested under its own habit, so the record → habit linkage is the
    ///   file's, one for one.
    /// - `createdAt` and `updatedAt` are kept: the copy is the same history, and a fresh stamp
    ///   would let a stale file beat newer edits under last-write-wins.
    /// - The account fields are dropped: the copies belong to no account until the store's
    ///   owner uploads them.
    static func newCopies(of document: BackupDocument) -> BackupDocument {
        var groupIDs: [UUID: UUID] = [:]
        var copy = document
        copy.accountId = nil
        copy.accountEmail = nil
        copy.groups = document.groups.map { group in
            var g = group
            g.id = UUID()
            groupIDs[group.id] = g.id
            return g
        }
        copy.habits = document.habits.map { habit in
            var h = habit
            h.id = UUID()
            if let old = habit.groupId, let new = groupIDs[old] { h.groupId = new }
            h.records = habit.records.map { record in
                var r = record
                r.id = UUID()
                return r
            }
            return h
        }
        return copy
    }

    // MARK: Restore

    /// Inserts the document into `context` — groups, habits, and each habit's check-ins through
    /// its `records` relationship — and saves. Refuses (`storeNotEmpty`, nothing changed) unless
    /// the store has no habit, check-in or group at all: merging into live data has to obey the
    /// sync rules 1.3.1 introduces, and is M6+ work. Held rows in a store that is not empty are
    /// converted by their own operation, `SyncCopies.reidentify`.
    ///
    /// `createdAt` and `updatedAt` are the backup's own; nothing is `touch()`ed —
    /// `updatedAt = now` would make a stale backup beat newer edits other devices made since:
    /// the server resolves conflicts last-write-wins on the client's edit time. Nothing needs a
    /// fresh stamp to be uploaded: 1.3.1 treats rows the server never acknowledged
    /// (`syncedAt == nil`, as every inserted row is) as pending.
    ///
    /// **`.keepIDs`** — the file's own ids, for a backup of the account this device syncs as
    /// (`restoreDecision`); new ids would duplicate every habit that account still holds.
    /// - Every row gets `restoredAt`. While it is set no pull deletes the row: a full pull that
    ///   lacks it, a `deleted*Ids` or a cascade holds it `tombstoned` instead, exactly as a push
    ///   answered `tombstoned` does (`SyncLocalRemoval`, `SyncAnswers`). An id whose deletion
    ///   already reached the server — the "I deleted it by mistake" restore — is therefore not
    ///   removed again silently, as 1.3.0's restore was by the first full pull: the sync section
    ///   offers "Restore as new copies" or "Discard". The first acknowledgement clears it.
    /// - Queued deletions of the restored ids are withdrawn from `deletionQueue` once the save
    ///   succeeds. That deletion is still queued — erase leaves the queue alone, and a signed-out
    ///   device, or the widget's un-check, queues all the same — and the first sync after signing
    ///   in would push the tombstone ahead of the restored row. An explicit restore overrides an
    ///   older queued deletion. Pass nil only where no queue exists (tests).
    ///
    /// **`.newCopies`** — `newCopies(of:)`: fresh ids, for a backup of another account, or one
    /// with no account. `restoredAt` is NOT set — they are new rows no tombstone can name, and
    /// `restoredAt` would let them outlive a real deletion made later on another device. The
    /// deletion queue is left alone: a queued deletion names an OLD id, and it still means what it
    /// meant (withdrawn, the original would survive on the server beside its copy).
    ///
    /// The caller owns what follows: setting the store's owner (`RestoreDecision.plan.owner`),
    /// rescheduling reminders for `reminderEnabled` habits and reloading widgets — and not
    /// restoring under a sync that is still in flight (`DataExportService.restore` waits).
    @MainActor
    @discardableResult
    static func restore(_ document: BackupDocument, into context: ModelContext,
                        identity: RestoreIdentity = .keepIDs,
                        withdrawingDeletionsFrom deletionQueue: SyncDeletionQueue?,
                        limits: Limits = .default,
                        now: Date = Date()) throws -> BackupPreview {
        guard document.schemaVersion == schemaVersion else {
            throw document.schemaVersion > schemaVersion
                ? DataBackupError.newerVersion(document.schemaVersion)
                : DataBackupError.version1Export
        }
        try validate(document, limits: limits)
        guard try context.fetchCount(FetchDescriptor<Habit>()) == 0,
              try context.fetchCount(FetchDescriptor<HabitRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<HabitGroup>()) == 0 else {
            throw DataBackupError.storeNotEmpty
        }

        let rows = identity == .newCopies ? newCopies(of: document) : document
        let restoredAt: Date? = identity == .keepIDs ? now : nil

        for item in rows.groups {
            let group = HabitGroup(name: item.name, colorHex: item.colorHex, sortOrder: item.sortOrder)
            group.id = item.id
            group.createdAt = item.createdAt
            group.updatedAt = item.updatedAt
            group.restoredAt = restoredAt
            context.insert(group)
        }

        for item in rows.habits {
            let habit = Habit(name: item.name, emoji: item.emoji, colorHex: item.colorHex)
            habit.id = item.id
            habit.createdAt = item.createdAt
            habit.updatedAt = item.updatedAt
            habit.isArchived = item.isArchived
            habit.sortOrder = item.sortOrder
            habit.reminderEnabled = item.reminderEnabled
            habit.reminderHour = item.reminderHour
            habit.reminderMinute = item.reminderMinute
            habit.note = item.note
            habit.kind = item.kind
            habit.targetValue = item.targetValue
            habit.unit = item.unit
            habit.scheduleKind = item.scheduleKind
            habit.timesPerWeek = item.timesPerWeek
            habit.activeDaysMask = item.activeDaysMask
            habit.groupId = item.groupId
            habit.restoredAt = restoredAt
            context.insert(habit)

            habit.records = item.records.compactMap { entry in
                guard let day = dayKey(entry.date) else { return nil } // validated above
                let record = HabitRecord(date: day, note: entry.note, value: entry.value)
                record.id = entry.id
                // Verbatim, like the reconciler: re-deriving it through the local calendar would
                // move it a day in any zone west of UTC.
                record.date = day
                record.updatedAt = entry.updatedAt
                record.restoredAt = restoredAt
                return record
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        guard identity == .keepIDs else { return preview(of: rows) }
        // After the save: a restore that failed must not have cancelled a deletion.
        // `acknowledge` removes exactly the ids given, from the app's queues and the widget's.
        deletionQueue?.acknowledge(SyncDeletionQueue.Batch(
            habits: rows.habits.map(\.id.uuidString),
            entries: rows.habits.flatMap { $0.records.map(\.id.uuidString) },
            groups: rows.groups.map(\.id.uuidString)
        ))
        return preview(of: rows)
    }

    // MARK: Erase

    /// Deletes every habit, check-in and group in `context` and saves, WITHOUT queueing sync
    /// deletions. The point is to clear this device, not the account: a tombstone for each row
    /// would delete the user's data on every other device and on the server at the next sync.
    /// (Deletion is queued only by `SyncService.trackDeleted*`, which this never calls.)
    ///
    /// The caller owns the flow around it — signing out first, so the next sync does not pull
    /// everything straight back, cancelling reminders, reloading widgets.
    @MainActor
    static func eraseLocalData(in context: ModelContext) throws {
        // Fetch-and-delete rather than `delete(model:)`: the batch delete skips the habit →
        // records cascade in some SwiftData versions. Check-ins are fetched on their own so a
        // record orphaned by an old bug goes too.
        for record in try context.fetch(FetchDescriptor<HabitRecord>()) { context.delete(record) }
        for habit in try context.fetch(FetchDescriptor<Habit>()) { context.delete(habit) }
        for group in try context.fetch(FetchDescriptor<HabitGroup>()) { context.delete(group) }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: CSV

    /// One row per check-in, for spreadsheets — not a backup (a habit with no check-ins has no
    /// row, and nothing reads this back). The first five columns are the 1.2.3 export's, in the
    /// same order, so a sheet built on the old file still lines up; the rest are new:
    ///
    /// - `value`: the amount logged (1 for a done/not-done habit).
    /// - `target`, `unit`: a count habit's daily goal and unit; empty for done/not-done habits.
    /// - `schedule`: `daily`, `3/week`, or the days, e.g. `Mon Wed Fri`.
    ///
    /// Numbers are written with a `.` decimal point whatever the locale, and fields are quoted
    /// per RFC 4180 when they hold a comma, quote, CR or LF.
    ///
    /// Text is written as the user typed it, including a leading `=`, `+`, `-` or `@`. Excel
    /// reads such a cell as a formula: "=…" is evaluated, and a note like "- felt good" shows
    /// `#NAME?`. The usual CSV-injection guard (a leading `'` or tab) was weighed and not taken:
    /// this file only ever holds the user's own words, so there is no one to inject, and the
    /// prefix is a visible stray character in Numbers and Google Sheets — it would change every
    /// such note in those apps to spare its display in one other. Pinned by
    /// `testCSVWritesFormulaLookingCellsAsTyped`.
    static func csv(_ document: BackupDocument) -> String {
        var lines = ["habit_name,emoji,date,note,created_at,value,target,unit,schedule"]

        let habits = document.habits.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
        for habit in habits {
            let isCount = habit.kind == HabitKind.count.rawValue
            let createdAt = localDayFormatter.string(from: habit.createdAt)
            let target = isCount ? number(habit.targetValue) : ""
            let unit = isCount ? (habit.unit ?? "") : ""
            let schedule = scheduleDescription(habit)
            for record in habit.records.sorted(by: recordOrder) {
                lines.append([
                    csvField(habit.name), csvField(habit.emoji), record.date, csvField(record.note ?? ""),
                    createdAt, number(record.value), target, csvField(unit), csvField(schedule),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `csv` as UTF-8 with a byte-order mark. Without the BOM, Excel opens a UTF-8 CSV in the
    /// system's legacy code page, and every emoji and every Japanese, Korean or Chinese habit
    /// name — five of the app's six languages — turns into mojibake. Numbers and Google Sheets
    /// accept the BOM.
    static func csvData(_ document: BackupDocument) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv(document).utf8)
    }

    static func csvField(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Helpers

    /// `2026-09-27T10:00:00.123Z`. Milliseconds are rounded, not truncated, so a timestamp read
    /// back from a file formats to the same string again (a truncating formatter can turn .123
    /// into .122 through the binary fraction).
    static func timestamp(_ date: Date) -> String {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (millis / 1000).rounded(.down)
        let fraction = Int(millis - seconds * 1000)
        let whole = SyncTimestamp.string(from: Date(timeIntervalSince1970: seconds)) // …:00Z
        return whole.dropLast() + String(format: ".%03dZ", fraction)
    }

    /// `createdAt` in the CSV is the wall-clock day it was created, as the 1.2.3 export had it.
    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static func number(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func scheduleDescription(_ habit: BackupHabit) -> String {
        switch HabitSchedule(rawValue: habit.scheduleKind) {
        case .daily: return "daily"
        case .timesPerWeek: return "\(habit.timesPerWeek)/week"
        case .specificDays:
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] // bit 0 = Sunday
            return names.indices.filter { habit.activeDaysMask & (1 << $0) != 0 }
                .map { names[$0] }.joined(separator: " ")
        case nil: return habit.scheduleKind
        }
    }

    private static func backupGroup(_ group: HabitGroup) -> BackupGroup {
        BackupGroup(id: group.id, name: group.name, colorHex: group.colorHex, sortOrder: group.sortOrder,
                    createdAt: group.createdAt, updatedAt: group.updatedAt)
    }

    private static func backupHabit(_ habit: Habit, records: [BackupRecord]) -> BackupHabit {
        BackupHabit(id: habit.id, name: habit.name, emoji: habit.emoji, colorHex: habit.colorHex,
                    createdAt: habit.createdAt, updatedAt: habit.updatedAt, isArchived: habit.isArchived,
                    sortOrder: habit.sortOrder, reminderEnabled: habit.reminderEnabled,
                    reminderHour: habit.reminderHour, reminderMinute: habit.reminderMinute, note: habit.note,
                    kind: habit.kind, targetValue: habit.targetValue, unit: habit.unit,
                    scheduleKind: habit.scheduleKind, timesPerWeek: habit.timesPerWeek,
                    activeDaysMask: habit.activeDaysMask, groupId: habit.groupId, records: records)
    }

    private static func backupRecord(_ record: HabitRecord) -> BackupRecord {
        BackupRecord(id: record.id,
                     date: HabitCalendar.dayStringFormatter.string(from: HabitCalendar.startOfKey(record.date)),
                     value: record.value, note: record.note, updatedAt: record.updatedAt)
    }

    /// One row per id: the most recently edited; on a tie, the one that came first.
    private static func newestPerID<T>(_ rows: [T], id: (T) -> UUID, edited: (T) -> Date) -> [T] {
        var kept: [UUID: (index: Int, row: T)] = [:]
        for (index, row) in rows.enumerated() {
            if let current = kept[id(row)], edited(current.row) >= edited(row) { continue }
            kept[id(row)] = (kept[id(row)]?.index ?? index, row)
        }
        return kept.values.sorted { $0.index < $1.index }.map(\.row)
    }

    /// One check-in per id, then one per day: newest edit first, then the larger value.
    private static func dedupedRecords(_ records: [BackupRecord]) -> [BackupRecord] {
        func beats(_ a: BackupRecord, _ b: BackupRecord) -> Bool {
            let ea = a.updatedAt ?? .distantPast, eb = b.updatedAt ?? .distantPast
            if ea != eb { return ea > eb }
            return a.value > b.value
        }
        var byID: [UUID: BackupRecord] = [:]
        for record in records {
            if let current = byID[record.id], !beats(record, current) { continue }
            byID[record.id] = record
        }
        var byDay: [String: BackupRecord] = [:]
        for record in byID.values.sorted(by: recordOrder) {
            if let current = byDay[record.date], !beats(record, current) { continue }
            byDay[record.date] = record
        }
        return byDay.values.sorted(by: recordOrder)
    }

    private static func groupOrder(_ a: BackupGroup, _ b: BackupGroup) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    private static func habitOrder(_ a: BackupHabit, _ b: BackupHabit) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    private static func recordOrder(_ a: BackupRecord, _ b: BackupRecord) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return a.id.uuidString < b.id.uuidString
    }

    /// What a file that failed the v2 decode is, if it is recognisably something: nil means
    /// "a v2 file with something wrong in it".
    private static func classify(_ data: Data) -> DataBackupError? {
        struct Probe: Decodable {
            var schemaVersion: Int?
            var exportDate: String?
            var habits: [LegacyHabit]?
            struct LegacyHabit: Decodable { var completions: [LegacyCompletion]? }
            struct LegacyCompletion: Decodable {}
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            // Not JSON, not an object, or schemaVersion is not a number.
            return .notABackup
        }
        switch probe.schemaVersion {
        case let v? where v > schemaVersion: return .newerVersion(v)
        case 1?: return .version1Export
        case schemaVersion?: return nil
        case _?: return .notABackup
        case nil:
            let looksV1 = probe.exportDate != nil
                || (probe.habits?.contains { $0.completions != nil } ?? false)
            return looksV1 ? .version1Export : .notABackup
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(path(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
