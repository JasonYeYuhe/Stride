import Foundation
import SwiftData

// The rehearsal's plumbing: the local server's address and accounts, an HTTP transport the
// REAL engine (Shared/SyncEngine.swift) talks through, the 1.3.1 devices built on it, and the
// two snapshot devices that stand in for the ≤ 1.3.0 fleet.
//
// Nothing here re-implements sync. A 1.3.1 device is `SyncEngine` + planner + resolver +
// reconciler compiled from Shared/ exactly as the app ships them; only the network is
// URLSession against `NODE_ENV=test node index.js` on a throwaway database. The snapshot
// devices are the one emulated part, and only their PUSH is emulated: 1.2.3 and 1.3.0 send
// the whole store on every sync, with whole-second stamps (1.3.0's `pushLocal`), which is the
// shape the server has to keep handling for months (DEV-PLAN-1.3.md M2, "a fleet that will
// contain ≤1.3.0 snapshot clients").

// MARK: - Environment

enum Rehearsal {
    static let env = ProcessInfo.processInfo.environment
    /// http://127.0.0.1:<port> — the local test server the shell script started.
    static let base = URL(string: env["STRIDE_REHEARSAL_BASE"] ?? "http://127.0.0.1:0")!
    static let serverDir = env["STRIDE_REHEARSAL_SERVER_DIR"] ?? ""
    static let helper = env["STRIDE_REHEARSAL_HELPER"] ?? ""
    static let node = env["STRIDE_REHEARSAL_NODE"] ?? "/usr/bin/env"

    /// What a 1.3.1 build sends (APIClient's X-Stride-Client). The server gates the
    /// millisecond pull, the row caps and cursor_expired on it.
    static let client131 = "ios/1.3.1(19)"
    static let client130 = "ios/1.3.0(18)"
}

enum RehearsalError: Error, CustomStringConvertible {
    case helper(String)
    case http(String)

    var description: String {
        switch self {
        case .helper(let s): return "accounts.js: \(s)"
        case .http(let s): return s
        }
    }
}

/// One server account, created directly in the throwaway database (accounts.js).
struct Account {
    var userId: Int
    var email: String
    var token: String
    var owner: String { String(userId) }

    /// Each scenario gets fresh accounts: independent server state, and its own per-account
    /// rate-limit bucket (the server runs with the production limit, 60 sync requests / min).
    static func create() throws -> Account {
        let out = try runHelper("create")
        guard let json = try JSONSerialization.jsonObject(with: out) as? [String: Any],
              let id = json["userId"] as? Int, let email = json["email"] as? String,
              let token = json["token"] as? String
        else { throw RehearsalError.helper("unexpected output \(String(decoding: out, as: UTF8.self))") }
        return Account(userId: id, email: email, token: token)
    }

    static func installRowErrorTrigger() throws { _ = try runHelper("row-error-trigger") }

    private static func runHelper(_ command: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Rehearsal.node)
        p.arguments = (Rehearsal.node.hasSuffix("/env") ? ["node"] : []) + [Rehearsal.helper, Rehearsal.serverDir, command]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RehearsalError.helper("\(command) exited \(p.terminationStatus): \(msg)")
        }
        return data
    }
}

// MARK: - Transport

/// Rows in a push body, counted from the BYTES that went out — not from the engine's own
/// summary, so the "only the changed rows" checks do not take the engine's word for it.
struct WireCounts: Equatable, CustomStringConvertible {
    var habits = 0, entries = 0, groups = 0, deletions = 0
    /// Row stamps (createdAt / updatedAt) without three fractional digits.
    var wholeSecondStamps = 0
    var rows: Int { habits + entries + groups }
    var description: String { "\(groups)g/\(habits)h/\(entries)e" + (deletions > 0 ? "+\(deletions)del" : "") }

    init() {}

    init(body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        func rows(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
        habits = rows("habits").count
        entries = rows("entries").count
        groups = rows("groups").count
        deletions = ["deletedHabitIds", "deletedEntryIds", "deletedGroupIds"]
            .reduce(0) { $0 + ((json[$1] as? [Any])?.count ?? 0) }
        for row in rows("habits") + rows("entries") + rows("groups") {
            for key in ["createdAt", "updatedAt"] {
                if let s = row[key] as? String, !Self.hasMilliseconds(s) { wholeSecondStamps += 1 }
            }
        }
    }

    static func hasMilliseconds(_ stamp: String) -> Bool {
        stamp.range(of: #"\.\d{3}Z$"#, options: .regularExpression) != nil
    }
}

/// One request as it went over the wire.
struct Exchange {
    var endpoint: SyncEndpoint
    var since: String?
    var token: String
    var status: Int?
    var requestBytes: Int
    var responseBytes: Int
    var pushed: WireCounts
    /// Answered by a fault hook, not by the server.
    var injected = false
    /// A fault hook swallowed the answer after the server had it.
    var answerLost = false
    /// When the request went out and when its answer was back: the gaps between one exchange's
    /// `finished` and the next one's `started` are the device's own work (plan, resolve,
    /// reconcile, save) — what the timing scenario reports.
    var started = Date()
    var finished = Date()
}

/// URLSession → the local server, with the header of the build it stands for, and seams to
/// inject the faults the acceptance list names: a failed chunk, a lost answer, a truncated pull,
/// a sign-in to another account while a chunk is in flight.
@MainActor
final class HTTPTransport: SyncTransport {
    enum PushFault {
        /// Never reaches the server (offline, DNS, a dropped connection before the body).
        case failBeforeSending
        /// The server applies it; the answer never arrives (timeout, app suspended).
        case loseAnswer
    }

    let clientHeader: String?
    private let session: URLSession
    private(set) var exchanges: [Exchange] = []

    /// Called with the 1-based index of each push this transport sends; a fault fails it.
    var pushFault: ((Int) -> PushFault?)?
    /// Called after a push was answered, before the engine sees the answer.
    var afterPush: ((Int) -> Void)?
    /// Rewrites a pull's answer before the engine sees it.
    var transformPull: ((String?, SyncTransportResponse) -> SyncTransportResponse)?

    private var pushCount = 0

    /// Every transport the run made, for the rehearsal-wide "no 429" check.
    static var all: [HTTPTransport] = []

    init(clientHeader: String?) {
        self.clientHeader = clientHeader
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config)
        Self.all.append(self)
    }

    var pushes: [Exchange] { exchanges.filter { $0.endpoint == .push } }
    func mark() -> Int { exchanges.count }
    func since(_ mark: Int) -> [Exchange] { Array(exchanges[mark...]) }

    func push(body: Data, token: String) async -> SyncTransportResponse {
        pushCount += 1
        let n = pushCount
        let started = Date()
        var record = Exchange(endpoint: .push, since: nil, token: token, status: nil, requestBytes: body.count,
                              responseBytes: 0, pushed: WireCounts(body: body), started: started)
        let fault = pushFault?(n)
        if fault == .failBeforeSending {
            record.injected = true
            exchanges.append(record)
            return .noAnswer
        }
        var request = URLRequest(url: Rehearsal.base.appendingPathComponent("v1/sync/push"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response = await send(request, token: token)
        record.finished = Date()
        record.status = response.status
        record.responseBytes = response.body.count
        if fault == .loseAnswer {
            record.answerLost = true
            exchanges.append(record)
            return .noAnswer
        }
        exchanges.append(record)
        afterPush?(n)
        return response
    }

    func pull(since: String?, token: String) async -> SyncTransportResponse {
        var components = URLComponents(url: Rehearsal.base.appendingPathComponent("v1/sync/pull"),
                                       resolvingAgainstBaseURL: false)!
        if let since { components.queryItems = [URLQueryItem(name: "since", value: since)] }
        let started = Date()
        var response = await send(URLRequest(url: components.url!), token: token)
        if let transformPull { response = transformPull(since, response) }
        exchanges.append(Exchange(endpoint: .pull, since: since, token: token, status: response.status,
                                  requestBytes: 0, responseBytes: response.body.count, pushed: WireCounts(),
                                  started: started, finished: Date()))
        return response
    }

    /// A raw push outside the engine (the snapshot devices).
    func rawPush(_ body: Data, token: String) async -> SyncTransportResponse {
        await push(body: body, token: token)
    }

    private func send(_ request: URLRequest, token: String) async -> SyncTransportResponse {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let clientHeader { request.setValue(clientHeader, forHTTPHeaderField: "X-Stride-Client") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .noAnswer }
            return SyncTransportResponse(status: http.statusCode, body: data,
                                         retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return .noAnswer
        }
    }
}

/// A full pull straight from the server, for comparing devices with what the server holds.
@MainActor
func serverSnapshot(_ account: Account, clientHeader: String? = Rehearsal.client131) async throws -> SyncPullResponse {
    let t = HTTPTransport(clientHeader: clientHeader)
    let r = await t.pull(since: nil, token: account.token)
    guard r.status == 200 else { throw RehearsalError.http("server snapshot: status \(r.status.map(String.init) ?? "none")") }
    return try JSONDecoder().decode(SyncPullResponse.self, from: r.body)
}

/// The raw JSON of a full pull, for the timestamp-format checks.
@MainActor
func rawPull(_ account: Account, clientHeader: String?) async throws -> [String: Any] {
    let t = HTTPTransport(clientHeader: clientHeader)
    let r = await t.pull(since: nil, token: account.token)
    guard r.status == 200, let json = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
        throw RehearsalError.http("raw pull: status \(r.status.map(String.init) ?? "none")")
    }
    return json
}

// MARK: - Stores

/// What a store holds, in a form two stores (or a store and the server) compare by: ids
/// canonical, entries keyed by habit and day (the server's `ON CONFLICT(habit_id, date)`).
struct StoreDigest: Equatable {
    var habits: [String: String] = [:]     // id → name|emoji|note|groupId|archived
    var entries: [String: String] = [:]    // habitId|day → value|note
    var groups: [String: String] = [:]     // id → name|sortOrder

    func difference(from other: StoreDigest) -> String? {
        var parts: [String] = []
        func diff(_ label: String, _ a: [String: String], _ b: [String: String]) {
            let keys = Set(a.keys).union(b.keys)
            let differing = keys.filter { a[$0] != b[$0] }
            if !differing.isEmpty { parts.append("\(label): \(differing.count) differ (\(a.count) vs \(b.count))") }
        }
        diff("habits", habits, other.habits)
        diff("entries", entries, other.entries)
        diff("groups", groups, other.groups)
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    var summary: String { "\(groups.count)g/\(habits.count)h/\(entries.count)e" }

    @MainActor
    init(context: ModelContext) throws {
        for habit in try context.fetch(FetchDescriptor<Habit>()) {
            let id = habit.id.uuidString
            habits[id] = [habit.name, habit.emoji, habit.note ?? "", habit.groupId?.uuidString ?? "",
                          habit.isArchived ? "1" : "0"].joined(separator: "|")
            for record in habit.records {
                entries["\(id)|\(HabitCalendar.dayStringFormatter.string(from: record.date))"] =
                    "\(record.value)|\(record.note ?? "")"
            }
        }
        for group in try context.fetch(FetchDescriptor<HabitGroup>()) {
            groups[group.id.uuidString] = "\(group.name)|\(group.sortOrder)"
        }
    }

    @MainActor
    init(pull: SyncPullResponse) {
        for h in pull.habits {
            habits[SyncReconciler.canonicalID(h.id)] = [h.name, h.emoji, h.note ?? "",
                                                         h.groupId.map(SyncReconciler.canonicalID) ?? "",
                                                         h.isArchived ? "1" : "0"].joined(separator: "|")
        }
        for e in pull.entries {
            entries["\(SyncReconciler.canonicalID(e.habitId))|\(e.date)"] = "\(e.value ?? 1)|\(e.note ?? "")"
        }
        for g in pull.groups ?? [] {
            groups[SyncReconciler.canonicalID(g.id)] = "\(g.name)|\(g.sortOrder)"
        }
    }
}

/// The parts every device has: an in-memory store and the app's own mutation paths.
@MainActor
class StoreDevice {
    let name: String
    let container: ModelContainer
    let context: ModelContext
    let suiteName: String
    let defaults: UserDefaults

    /// A device's own UserDefaults suite (its deletion queue, cursors, strikes), made before
    /// `init` so a subclass can build on it first. Removed with the device.
    nonisolated static func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "stride-sync-rehearsal-\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    init(name: String, suite: (name: String, defaults: UserDefaults) = StoreDevice.makeSuite()) {
        self.name = name
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        suiteName = suite.name
        defaults = suite.defaults
    }

    func remove() { defaults.removePersistentDomain(forName: suiteName) }

    /// A habit with records on `days` (0 = `Scenario.day0`). The records array is assigned
    /// once: appending one by one to a managed relationship is quadratic (2,500 appends took
    /// 41 s in the planner tests).
    @discardableResult
    func habit(_ name: String, days: [Int] = [], note: ((Int) -> String?)? = nil) -> Habit {
        let h = Habit(name: name)
        context.insert(h)
        h.records = days.map { HabitRecord(date: Scenario.day($0), note: note?($0)) }
        return h
    }

    /// The list row's tap (HabitCheckIn — the same code TodayView, the widget and Siri run).
    @discardableResult
    func tap(_ habit: Habit, day: Int) -> HabitCheckIn.Result {
        HabitCheckIn.tap(habit, on: Scenario.day(day), in: context)
    }

    func save() throws { try context.save() }
    func habits() throws -> [Habit] { try context.fetch(FetchDescriptor<Habit>()) }
    func habit(id: UUID) throws -> Habit? { try habits().first { $0.id == id } }
    func record(of habitID: UUID, day: Int) throws -> HabitRecord? {
        try habit(id: habitID)?.record(on: Scenario.day(day))
    }
    func digest() throws -> StoreDigest { try StoreDigest(context: context) }
    func counts() throws -> (habits: Int, records: Int) {
        (try context.fetchCount(FetchDescriptor<Habit>()), try context.fetchCount(FetchDescriptor<HabitRecord>()))
    }

    /// Stamps an hour old on `habit`, its records and `group`: rows a 1.3.0 snapshot carried
    /// well before its last sync, which the migrated-rows rule marks delivered (5 min margin).
    func age(_ habit: Habit, group: HabitGroup? = nil) {
        let t = SyncTimestamp.floorToMillisecond(Date().addingTimeInterval(-3_600))
        habit.createdAt = t
        habit.updatedAt = t
        habit.records.forEach { $0.updatedAt = t }
        group?.createdAt = t
        group?.updatedAt = t
    }

    /// Opens `other`'s store the way 1.3.1 opens one 1.3.0 wrote: every row with its id, values
    /// and stamps, and NO delivery state — 1.3.0 had none, and the new fields are optional, so
    /// they open nil (the lightweight migration SyncDeliveryTests checks on disk). This store
    /// must be empty.
    func open130Store(from other: StoreDevice) throws {
        for g in try other.context.fetch(FetchDescriptor<HabitGroup>()) {
            let copy = HabitGroup(name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder)
            copy.id = g.id
            copy.createdAt = g.createdAt
            copy.updatedAt = g.updatedAt
            context.insert(copy)
        }
        for h in try other.habits() {
            let copy = Habit(name: h.name, emoji: h.emoji, colorHex: h.colorHex)
            copy.id = h.id
            copy.createdAt = h.createdAt
            copy.updatedAt = h.updatedAt
            copy.isArchived = h.isArchived
            copy.sortOrder = h.sortOrder
            copy.note = h.note
            copy.groupId = h.groupId
            copy.kind = h.kind
            copy.targetValue = h.targetValue
            copy.unit = h.unit
            copy.scheduleKind = h.scheduleKind
            copy.timesPerWeek = h.timesPerWeek
            copy.activeDaysMask = h.activeDaysMask
            copy.reminderEnabled = h.reminderEnabled
            copy.reminderHour = h.reminderHour
            copy.reminderMinute = h.reminderMinute
            context.insert(copy)
            copy.records = h.records.map { r in
                let record = HabitRecord(date: r.date, note: r.note, value: r.value)
                record.id = r.id
                record.date = r.date
                record.updatedAt = r.updatedAt
                return record
            }
        }
        try save()
    }

    /// Queues deletions the way the app does; overridden per device kind.
    func queueDeletion(habit: String, entries: [String]) {}
    func queueEntryDeletion(_ id: String) {}

    /// A tap that may uncheck: TodayView saves, then queues the tombstone of the record the tap
    /// deleted — only after the save, so a failed save never deletes on the server.
    @discardableResult
    func tapAndSave(_ habit: Habit, day: Int) throws -> HabitCheckIn.Result {
        let result = tap(habit, day: day)
        try save()
        if let id = result.deletedRecordID { queueEntryDeletion(id) }
        return result
    }

    /// Settings → delete habit: the habit's id and every record's id are queued, then the
    /// habit goes (its records by cascade). SettingsView does exactly this.
    func deleteHabit(_ habit: Habit) throws {
        queueDeletion(habit: habit.id.uuidString, entries: habit.records.map(\.id.uuidString))
        context.delete(habit)
        try save()
    }
}

// MARK: - 1.3.1 device

/// A 1.3.1 device: its own store, deletion queue, cursor store, recovery log and gate, and the
/// real `SyncEngine` over an HTTP transport that sends `ios/1.3.1(19)`.
@MainActor
final class Device131: StoreDevice {
    final class Gate: SyncRunGate {
        var state: SyncGateState
        init(_ state: SyncGateState) { self.state = state }
        func current() -> SyncGateState { state }
    }

    let account: Account
    let transport = HTTPTransport(clientHeader: Rehearsal.client131)
    let queue: SyncDeletionQueue
    let cursors: SyncDefaultsCursorStore
    /// The in-memory sink the engine archives into. The JSON-lines file and its export are the
    /// next slice; this is the same protocol the file log will implement.
    let log = SyncMemoryRecoveryLog()
    let gate: Gate
    /// Whether this store's migrated delivery marks still wait for the first full pull.
    var marks: SyncMarksProof { SyncMarksProof(defaults: defaults) }
    private(set) var engine: SyncEngine!
    private(set) var reports: [SyncDiagnosticReport] = []

    init(_ name: String, account: Account, bounds: SyncPushBounds = .standard) {
        self.account = account
        gate = Gate(.ready(SyncRunBinding(ownerID: account.owner, token: account.token, generation: 0)))
        let suite = StoreDevice.makeSuite()
        queue = SyncDeletionQueue(local: suite.defaults, shared: nil)
        cursors = SyncDefaultsCursorStore(defaults: suite.defaults)
        super.init(name: name, suite: suite)
        engine = SyncEngine(transport: transport, gate: gate, cursorStore: cursors, deletionQueue: queue,
                            strikes: SyncUnknownHabitStrikes(defaults: suite.defaults),
                            marks: SyncMarksProof(defaults: suite.defaults), recoveryLog: log,
                            report: { [weak self] in self?.reports.append($0) }, bounds: bounds)
    }

    func sync(options: SyncRunOptions = []) async -> SyncRunOutcome {
        await engine.run(in: context, options: options)
    }

    override func queueDeletion(habit: String, entries: [String]) {
        queue.trackHabit(habit)
        entries.forEach(queue.trackEntry)
    }

    override func queueEntryDeletion(_ id: String) { queue.trackEntry(id) }

    var cursor: String? {
        get { cursors.cursor(for: account.owner) }
        set { cursors.setCursor(newValue, for: account.owner) }
    }

    func pendingCount() throws -> Int {
        try context.fetch(FetchDescriptor<Habit>()).filter(\.isPending).count
            + context.fetch(FetchDescriptor<HabitRecord>()).filter(\.isPending).count
            + context.fetch(FetchDescriptor<HabitGroup>()).filter(\.isPending).count
    }
}

// MARK: - Snapshot devices (the ≤ 1.3.0 fleet)

/// A 1.2.3- or 1.3.0-shaped device: every sync pushes the WHOLE store with whole-second
/// stamps (1.3.0's `pushLocal`, unchanged since 1.2.3), then pulls since its cursor
/// (serverTime − 60 s).
///
/// 1.2.3 sends no X-Stride-Client header; 1.3.0 sends `ios/1.3.0(18)`. Both get whole-second
/// pulls, no row caps and no cursor_expired from the server (every gate is ≥ 1.3.1).
///
/// Its pull side is a stand-in: 1.3.0's own reconciler is not in this tree, so it runs the
/// current one with no recovery log (1.3.0 deleted without archiving), on a store whose stamps
/// are first floored to the whole second. That flooring is what makes the stand-in compare the
/// way 1.3.0 did: its entry guard floored the local stamp to whole seconds against a
/// whole-second remote, and its habit and group branches had no guard at all. Without it, a
/// local millisecond stamp (touch() floors to the millisecond since 1.3.1) would look newer
/// than the same edit served back as :18.000, and the stand-in would keep a value a real 1.3.0
/// device adopts. What the rehearsal tests is what the SERVER does with a snapshot fleet, and
/// that is decided by the push shape, which is exact.
@MainActor
final class SnapshotDevice: StoreDevice {
    enum Shape: String {
        case v123 = "1.2.3"
        case v130 = "1.3.0"
        var header: String? { self == .v123 ? nil : Rehearsal.client130 }
    }

    let shape: Shape
    let account: Account
    let transport: HTTPTransport
    private(set) var cursor: String?
    private var deletedHabits: [String] = []
    private var deletedEntries: [String] = []

    init(_ name: String, shape: Shape, account: Account) {
        self.shape = shape
        self.account = account
        transport = HTTPTransport(clientHeader: shape.header)
        super.init(name: name)
    }

    override func queueDeletion(habit: String, entries: [String]) {
        deletedHabits.append(habit)
        deletedEntries += entries
    }

    override func queueEntryDeletion(_ id: String) { deletedEntries.append(id) }

    /// The ≤ 1.3.0 comparison precision (see the type's comment). Only the stamps: the values
    /// were just pushed, and the push already sent these stamps truncated.
    private func floorStampsToWholeSeconds() throws {
        func whole(_ d: Date?) -> Date? { d.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) } }
        for h in try context.fetch(FetchDescriptor<Habit>()) {
            h.updatedAt = whole(h.updatedAt)
            for r in h.records { r.updatedAt = whole(r.updatedAt) }
        }
        for g in try context.fetch(FetchDescriptor<HabitGroup>()) { g.updatedAt = whole(g.updatedAt) }
    }

    /// Push the snapshot, then pull. Returns the two statuses.
    @discardableResult
    func sync() async throws -> (push: Int?, pull: Int?) {
        let habits = try context.fetch(FetchDescriptor<Habit>())
        let whole = SyncTimestamp.string(from:)
        let payload = SyncPushPayload(
            habits: habits.map { h in
                SyncHabit(id: h.id.uuidString, name: h.name, emoji: h.emoji, colorHex: h.colorHex,
                          isArchived: h.isArchived, sortOrder: Int(h.sortOrder), reminderEnabled: h.reminderEnabled,
                          reminderHour: h.reminderHour, reminderMinute: h.reminderMinute, note: h.note,
                          kind: h.kind, targetValue: h.targetValue, unit: h.unit, scheduleKind: h.scheduleKind,
                          timesPerWeek: h.timesPerWeek, activeDaysMask: h.activeDaysMask,
                          groupId: h.groupId?.uuidString, createdAt: whole(h.createdAt),
                          updatedAt: whole(h.updatedAt ?? h.createdAt))
            },
            entries: habits.flatMap { h in
                h.records.map { r in
                    SyncEntry(id: r.id.uuidString, habitId: h.id.uuidString,
                              date: HabitCalendar.dayStringFormatter.string(from: r.date), note: r.note,
                              value: r.value, createdAt: whole(r.date), updatedAt: whole(r.updatedAt ?? r.date))
                }
            },
            groups: try context.fetch(FetchDescriptor<HabitGroup>()).map { g in
                SyncGroup(id: g.id.uuidString, name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder,
                          createdAt: whole(g.createdAt), updatedAt: whole(g.updatedAt ?? g.createdAt))
            },
            deletedHabitIds: deletedHabits, deletedEntryIds: deletedEntries, deletedGroupIds: [])
        let body = try JSONEncoder().encode(payload)
        let pushed = await transport.rawPush(body, token: account.token)
        guard pushed.status == 200 else { return (pushed.status, nil) }
        deletedHabits = []
        deletedEntries = []

        let pulled = await transport.pull(since: cursor, token: account.token)
        guard pulled.status == 200 else { return (200, pulled.status) }
        let response = try JSONDecoder().decode(SyncPullResponse.self, from: pulled.body)
        try floorStampsToWholeSeconds()
        try SyncReconciler.apply(response, to: context, isFullPull: cursor == nil)
        cursor = SyncCursor.next(afterServerTime: response.serverTime)
        return (200, 200)
    }
}
