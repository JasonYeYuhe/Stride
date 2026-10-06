import SwiftData
import Foundation
import os.log

/// The one store the app, its widget and its intents share, and the rules for opening it.
///
/// **No process but the app ever creates or migrates the store (upgrade race, E2E U123).** The
/// first 1.3.1 launch after an in-place upgrade migrates the 1.3.0 store (the five delivery
/// fields). chronod launched StrideWidgetExtension at the same moment, and the widget's `init()`
/// opened the same App Group file, so two processes migrated it at once. The app's open then
/// failed (NSCocoaErrorDomain 134110, underlying 134100: "the store version hashes didn't
/// migrate"), and this file's catch fell back to `ModelContainer(for: schema)` — a NEW, EMPTY
/// default.store. The user saw "Start Your Journey" with every habit hidden; the delivery
/// migration spent its done flag on the empty store; the next launch opened the real, by then
/// migrated, store with every row undelivered and pushed all of it, filling Recovered Edits with
/// rows deleted elsewhere. 4 of 4 simulator upgrades failed with the widget installed, 0 of 2
/// without. So:
/// - The app opens with `openForApp`, the only open that may create or migrate the store. Once
///   it has opened the real store it writes `storeSchemaVersion` to the App Group
///   (`StoreSchemaGate`) and reloads the widget.
/// - Every other process — the widget extension, its check-in intent — opens with
///   `openForExtension`, which opens only a store the app has already opened at exactly this
///   schema: never a missing one (the app has not created it), an older one (the app has not
///   migrated it yet) or a newer one (a downgraded app has not migrated it back yet).
/// - A failed open never falls back to another store. An empty store hides the data and spends
///   the one-time migrations on itself; the app shows `StoreUnavailableView` instead.
enum SharedModelContainer {
    static let appGroupIdentifier = "group.yyh.stride.habittracker"

    /// The models the store holds; every open of the real store uses this one list.
    static var schema: Schema { Schema([Habit.self, HabitRecord.self, HabitGroup.self]) }

    /// The store's schema generation. The app writes it to the App Group once its own open of the
    /// real store succeeded, and every other process requires it — exactly — before it opens the
    /// store (`StoreSchemaGate`).
    ///
    /// BUMP IT WHENEVER THE MODELS CHANGE: a stored property of `Habit`, `HabitRecord` or
    /// `HabitGroup` added, removed, renamed or retyped — anything that makes SwiftData migrate.
    /// A missed bump is the U123 race again: the new widget would read the old number as current
    /// and migrate the old store alongside the app. `StoreSchemaVersionTests` pins the models'
    /// version hashes under this number and fails until both are updated.
    ///
    /// 1 — 1.3.1 (the five delivery fields). Builds before 1.3.1 wrote no marker, and a missing
    /// marker reads as "not opened at this schema yet".
    static let storeSchemaVersion = 1

    // MARK: - Where the store lives

    /// The real store's location. The App Group container is what lets the widget read it. Only
    /// when this process has no App Group container at all — no entitlement, a misconfigured
    /// build, never a shipped one — does the store live in the app's own Documents, as it always
    /// has. That is the one fallback kept: another LOCATION for such a build's only store, not a
    /// second store beside a real one that failed to open. Nothing else can read it, so nothing
    /// is gated or marked there.
    enum Location: Equatable {
        case appGroup(URL)
        case noAppGroup(URL)

        var url: URL {
            switch self {
            case .appGroup(let url), .noAppGroup(let url): return url
            }
        }
    }

    static func location(appGroupContainer: URL?, documents: URL) -> Location {
        if let appGroupContainer { return .appGroup(appGroupContainer.appendingPathComponent("Stride.store")) }
        return .noAppGroup(documents.appendingPathComponent("Stride.store"))
    }

    static var location: Location {
        location(appGroupContainer: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
                 documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
    }

    static var storeURL: URL { location.url }

    /// The App Group's defaults: the schema marker, and the day-key migration's flag.
    static var appGroupDefaults: UserDefaults? { UserDefaults(suiteName: appGroupIdentifier) }

    /// The configuration every open of the real store uses — the app's and the widget's alike.
    static func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = self.schema
        let config = ModelConfiguration("Stride", schema: schema, url: url, allowsSave: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - The process-wide container

    /// ONE container per process, once opened, never a new one per caller. A computed property
    /// used to hand every caller a BRAND-NEW ModelContainer over the same store file: the app and
    /// widget each stashed it and were fine, but `StrideShortcuts` built one per Siri invocation
    /// (x4) and the widget's toggle path built another — so several live containers could hold
    /// the same store with independent caches, and a write through one was not guaranteed to be
    /// visible through another. It is no longer a `static let` because the open can now fail
    /// without crashing or falling back, and the app must be able to try again.
    private static var openedContainer: ModelContainer?
    private static let lock = NSLock()

    /// The container this process has opened over the real store, or nil if it has not (yet).
    /// What every caller other than the two opens reads — the app's intents and its account
    /// deletion, which run only after the app's launch opened (or failed to open) the store, and
    /// must never open a second one.
    static var opened: ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        return openedContainer
    }

    /// The app's open, at launch and on the error screen's Try Again: the only one that may
    /// create or migrate the store. Retries a store that exists (`StoreOpenRetry`), never falls
    /// back to another store, and on success marks the store opened at this schema and calls
    /// `reloadWidgets`, so a widget that was waiting draws the habits. Once it succeeded every
    /// later call returns the same container. Blocks for up to `StoreOpenRetry.budget`.
    static func openForApp(reloadWidgets: @escaping () -> Void) -> Result<ModelContainer, StoreOpenFailure> {
        lock.lock(); defer { lock.unlock() }
        if let openedContainer { return .success(openedContainer) }
        let result = AppStoreOpen(location: location, defaults: appGroupDefaults, reloadWidgets: reloadWidgets).run()
        if case .success(let container) = result { openedContainer = container }
        return result
    }

    /// The widget extension's open (its timeline and its check-in intent): the store only once
    /// the app has opened it at exactly this schema (`StoreSchemaGate`). Never creates, never
    /// migrates, never retries, never falls back; nil means "draw the waiting state, write
    /// nothing". Once opened, the same container for the life of the extension process — an app
    /// update ends that process, so a newer schema never meets it.
    static func openForExtension() -> ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        if let openedContainer { return openedContainer }
        guard case .appGroup(let url) = location, let defaults = appGroupDefaults else { return nil }
        let gate = StoreSchemaGate.decide(marker: StoreSchemaGate.marker(in: defaults),
                                          storeExists: FileManager.default.fileExists(atPath: url.path))
        guard gate == .open else {
            logger.notice("Store not opened in the extension: \(String(describing: gate), privacy: .public)")
            return nil
        }
        do {
            let container = try makeContainer(at: url)
            openedContainer = container
            return container
        } catch {
            logger.error("Extension could not open the store: \(StoreOpenFailure(error, attempts: 1).summary, privacy: .public)")
            return nil
        }
    }

    /// Whether `container` is this process's real store: on disk at `realStoreURL` (the App
    /// Group's Stride.store, or the no-entitlement location). A one-time migration keeps its done
    /// flag per INSTALL, so it must only ever run on the install's store — U123's fallback spent
    /// the delivery migration on an empty default.store. In-memory stores are not the real store
    /// either: a future "in-memory so it doesn't crash" fallback must not spend them.
    static func isRealStore(_ container: ModelContainer, realStoreURL: URL = storeURL) -> Bool {
        let real = realStoreURL.resolvingSymlinksInPath().path
        return container.configurations.contains {
            !$0.isStoredInMemoryOnly && $0.url.resolvingSymlinksInPath().path == real
        }
    }

    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "ModelContainer")

    // MARK: - One-time migrations

    private static let dayKeyMigrationFlag = "stride_daykey_migration_v2_done"

    /// One-time migration: re-anchor legacy records (stored as *local* midnight)
    /// to UTC-anchored day-keys (see `HabitCalendar`). Idempotent — records that
    /// are already a UTC midnight day-key are skipped, so re-running (or a
    /// UTC-zone user, whose local midnight already equals the key) is safe.
    /// Assumes the device's current time zone matches the record's creation zone,
    /// which holds for any user who hasn't traveled between logging and upgrading.
    ///
    /// Only on the real store (`isRealStore`, upgrade race U123): its flag is per install. A
    /// refusal, not an assertion, so the tests (Debug builds) can prove it.
    static func migrateRecordDayKeysIfNeeded(_ container: ModelContainer) {
        guard isRealStore(container) else {
            Logger(subsystem: "yyh.stride.habittracker", category: "Migration")
                .error("Day-key migration refused: not the real store")
            return
        }
        let defaults = appGroupDefaults ?? .standard
        guard !defaults.bool(forKey: dayKeyMigrationFlag) else { return }

        let context = ModelContext(container)
        do {
            let records = try context.fetch(FetchDescriptor<HabitRecord>())
            var changed = 0
            for record in records where !HabitCalendar.isDayKey(record.date) {
                record.date = HabitCalendar.dayKey(for: record.date)
                changed += 1
            }
            if changed > 0 { try context.save() }
            defaults.set(true, forKey: dayKeyMigrationFlag)
        } catch {
            // Leave the flag unset to retry next launch; the idempotent guard
            // above keeps a partial run safe.
            Logger(subsystem: "yyh.stride.habittracker", category: "Migration")
                .error("Day-key migration failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - The app's open

/// What `SharedModelContainer.openForApp` does, with the location, the defaults and the widget
/// reload injected so the rules can be tested without the process-wide container:
/// - the store at `location` and nowhere else — a failure is a failure, not another store;
/// - retried while a store file is there to wait for (`StoreOpenRetry`);
/// - on success at the App Group, the marker first, then `reloadWidgets`: a widget that reloads
///   must find the marker it waits for.
struct AppStoreOpen {
    var location: SharedModelContainer.Location
    /// The App Group's defaults, where the marker goes. Nil: nowhere to write it.
    var defaults: UserDefaults?
    var reloadWidgets: () -> Void
    var retry = StoreOpenRetry()
    var storeExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    var makeContainer: (URL) throws -> ModelContainer = SharedModelContainer.makeContainer(at:)

    func run() -> Result<ModelContainer, StoreOpenFailure> {
        let url = location.url
        let result = retry.run(storeExists: { storeExists(url) }) { try makeContainer(url) }
        guard case .success = result else {
            if case .failure(let failure) = result {
                Logger(subsystem: "yyh.stride.habittracker", category: "ModelContainer")
                    .error("Could not open the store: \(failure.summary, privacy: .public). Not falling back: the app shows the error screen.")
            }
            return result
        }
        // A store outside the App Group has no widget to wait for it.
        if case .appGroup = location, let defaults {
            StoreSchemaGate.markOpenedByApp(in: defaults)
            reloadWidgets()
        }
        return result
    }
}

/// How the app's open waits for a store another process may be finishing with (upgrade race,
/// E2E U123): only when the store file exists — no file means nothing to wait for, and a create
/// that failed will fail again — and for at most `budget` seconds, measured on `now` from the
/// first attempt, `pause` apart. The attempts' own time counts against the budget.
struct StoreOpenRetry {
    var budget: TimeInterval = 3
    var pause: TimeInterval = 0.5
    /// Monotonic seconds.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func run<T>(storeExists: () -> Bool, _ attempt: () throws -> T) -> Result<T, StoreOpenFailure> {
        let start = now()
        var attempts = 0
        while true {
            attempts += 1
            do {
                return .success(try attempt())
            } catch {
                guard storeExists(), now() - start + pause <= budget else {
                    return .failure(StoreOpenFailure(error, attempts: attempts))
                }
                sleep(pause)
            }
        }
    }
}

/// A failed open, as the app reports it (Sentry, the log): the error's domain and code and its
/// underlying error's, never a message, a path or anything else from `userInfo` — Core Data's
/// errors carry the store's path and its metadata.
struct StoreOpenFailure: Error, Equatable {
    let domain: String
    let code: Int
    let underlyingDomain: String?
    let underlyingCode: Int?
    let attempts: Int

    init(domain: String, code: Int, underlyingDomain: String? = nil, underlyingCode: Int? = nil, attempts: Int) {
        self.domain = domain
        self.code = code
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.attempts = attempts
    }

    init(_ error: Error, attempts: Int) {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        self.init(domain: ns.domain, code: ns.code, underlyingDomain: underlying?.domain,
                  underlyingCode: underlying?.code, attempts: attempts)
    }

    var summary: String {
        let under = underlyingDomain.map { ", underlying \($0) \(underlyingCode ?? 0)" } ?? ""
        return "\(domain) \(code)\(under), \(attempts) attempt(s)"
    }
}

// MARK: - The widget's gate

/// Whether a process other than the app may open the store now (upgrade race, E2E U123). The
/// marker is `SharedModelContainer.storeSchemaVersion` as the app last wrote it, right after its
/// own open of the real store succeeded; the widget opens only when it equals the widget's own.
/// The widget ships inside the app, so the two always have the same number once the app has
/// launched; until then:
/// - no marker: a fresh install (no store yet) or an upgrade from a build before 1.3.1;
/// - older: the app has a migration to run (the next schema bump);
/// - newer: the app was downgraded and has not opened (and so migrated) the store back yet.
/// In each the widget opening the store could create or migrate it alongside the app — the race.
///
/// What the marker cannot see: a downgrade to a build that predates it (1.3.0 or earlier, which
/// never writes it) followed by a re-upgrade to the same schema — the marker still says current
/// while the store was taken back. App Store users cannot downgrade; only a developer or
/// TestFlight install can do that, and the widget then races as 1.3.0's did.
enum StoreSchemaGate: Equatable {
    case open
    case waitForApp(Reason)

    enum Reason: Equatable {
        case noMarker, olderMarker, newerMarker, noStore
    }

    static let markerKey = "stride_store_schema_version"

    static func decide(marker: Int?, current: Int = SharedModelContainer.storeSchemaVersion,
                       storeExists: Bool) -> StoreSchemaGate {
        guard let marker else { return .waitForApp(.noMarker) }
        if marker < current { return .waitForApp(.olderMarker) }
        if marker > current { return .waitForApp(.newerMarker) }
        // Marked but missing: never create it from here either.
        return storeExists ? .open : .waitForApp(.noStore)
    }

    static func marker(in defaults: UserDefaults) -> Int? {
        defaults.object(forKey: markerKey) as? Int
    }

    /// The app's own number, always — also over a newer one, after a downgrade: it is the schema
    /// the app just opened (and migrated) the store at.
    static func markOpenedByApp(in defaults: UserDefaults, version: Int = SharedModelContainer.storeSchemaVersion) {
        defaults.set(version, forKey: markerKey)
    }
}
