import XCTest
import SwiftData
@testable import Stride

/// Today's sync line from the live services (`SyncStatusLine.today`, Stride/Sources/Views/
/// SyncStatusRow.swift) after real sync runs against a stubbed server: the real AuthService as
/// the session source, the real SyncService, engine and APIClient, an in-memory store.
///
/// StrideTests pins the mapping itself (SyncStatusLineTests); what only this file can prove is
/// that the answers reach it — a 401 becomes the reauth row (acceptance 9: "revoking the session
/// server-side shows the Today row"), the pause switch and a rate limit become "Sync paused"
/// (acceptance 9: "shows 'sync paused' and no error"), no answer becomes "Offline — N changes
/// waiting" — and that the reauth row's session re-check leaves the row up while it signs the
/// dead session out, so the sign-in it opens is a normal one.
@MainActor
final class TodaySyncStatusTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var authDefaults: ScratchDefaults!
    private var local: ScratchDefaults!
    private var appGroup: ScratchDefaults!
    private var recovery: ScratchRecoveryLog!
    private var auth: AuthService!
    private var sync: SyncService!

    private static let userA = #"{"user":{"id":7,"email":"a@example.com","tier":"free","created_at":"2026-09-01 10:00:00"}}"#
    private static let pausedBody = #"{"error":"sync_paused","code":"sync_paused","message":"Sync is paused."}"#

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Habit.self, HabitRecord.self, HabitGroup.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        context = container.mainContext
        server = StubServer()
        tokens = InMemoryTokenStore(SyncSession.accountA.token)
        authDefaults = ScratchDefaults("today.auth")
        local = ScratchDefaults("today.local")
        appGroup = ScratchDefaults("today.appGroup")
        recovery = ScratchRecoveryLog()
        server.on("GET", "/v1/auth/session", respond: .ok(Self.userA))

        let api = server.makeClient(tokenStore: tokens)
        auth = AuthService(api: api, tokenStore: tokens, defaults: authDefaults.defaults, onSignOut: {}, onSignIn: {})
        sync = SyncService(api: api, defaults: local.defaults,
                           deletionQueue: SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults),
                           sessions: auth, recoveryLog: recovery.log)
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isLoggedIn, "signed in as A through the stored session")

        // A store A owns with a live cursor, and one habit waiting: the next sync pushes first.
        SyncOwnerStore(defaults: local.defaults).set(SyncOwner(SyncSession.accountA.account))
        SyncDefaultsCursorStore(defaults: local.defaults)
            .setCursor(SyncTimestamp.millisecondString(from: Date().addingTimeInterval(-86_400)), for: "7")
        context.insert(Habit(name: "Read"))
        try context.save()
    }

    override func tearDown() async throws {
        server.stop()
        authDefaults.remove()
        local.remove()
        appGroup.remove()
        recovery.remove()
        auth = nil
        sync = nil
        server = nil
        tokens = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    /// What Today would draw at `now`, with the counts it would read.
    private func line(at now: Date = Date()) throws -> SyncStatusLine? {
        let queue = SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults)
        let counts = try SyncStatusCounts.read(in: context, deletions: queue.pending())
        return SyncStatusLine.today(auth: auth, sync: sync, counts: counts, now: now)
    }

    // MARK: - Tests

    func testASuccessfulSyncReadsSynced() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))

        let ran = await sync.sync(context: context)

        XCTAssertTrue(ran)
        guard case .synced(let date)? = try line() else { return XCTFail("\(String(describing: try line()))") }
        XCTAssertEqual(date.timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// Acceptance 9: a session revoked server-side answers the next sync 401, and Today shows the
    /// row. The tap's re-check (`checkSession`, `{user: null}`) then deletes the dead token — the
    /// device is signed out, so a login link is not ignored as "already signed in" — and the row
    /// stays, because it is the way back in.
    func testA401ShowsTheReauthRowAndItOutlivesTheDeadSession() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))

        await sync.sync(context: context)
        XCTAssertEqual(try line(), .signInAgain)

        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        await auth.checkSession()

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read(), "the dead token is gone: the sign-in the row opens is a normal one")
        XCTAssertEqual(try line(), .signInAgain)
    }

    /// Acceptance 9 on a COLD launch: after the revocation the app is relaunched, so no sync meets
    /// the 401 — the launch session check meets `{user: null}` first, deletes the token and leaves
    /// the device signed out. The row must be there anyway (`AuthService.sessionExpired`,
    /// persisted), not the bare "Sign In" of 1.3.0; the sign-in it opens ends it.
    func testAColdLaunchAfterARevocationShowsTheReauthRow() async throws {
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        let api = server.makeClient(tokenStore: tokens)
        auth = AuthService(api: api, tokenStore: tokens, defaults: authDefaults.defaults, onSignOut: {}, onSignIn: {})
        sync = SyncService(api: api, defaults: local.defaults,
                           deletionQueue: SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults),
                           sessions: auth, recoveryLog: recovery.log)
        await auth.waitForSessionRestore()

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertFalse(sync.needsReauth, "no sync ran to see a 401")
        XCTAssertEqual(try line(), .signInAgain)

        // And the next launch still shows it: the dead token is gone, the fact is not.
        auth = AuthService(api: api, tokenStore: tokens, defaults: authDefaults.defaults, onSignOut: {}, onSignIn: {})
        XCTAssertTrue(auth.sessionExpired)

        server.on("POST", "/v1/auth/verify", respond: .ok(
            #"{"ok":true,"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"},"sessionToken":"tok-A2"}"#))
        let signedIn = await auth.verifyToken("magic-A")
        XCTAssertTrue(signedIn)
        XCTAssertFalse(auth.sessionExpired)
        XCTAssertFalse(authDefaults.defaults.bool(forKey: AuthService.sessionExpiredKey))
    }

    // MARK: - Settings' Account section (E2E S9)

    /// What Settings' Account section would show now.
    private func account() -> SettingsAccountState { SettingsAccountState.current(auth: auth, sync: sync) }

    /// After a revoke, Settings said "Signed in" in green over a red "Please log in again", with
    /// only Log Out and Delete Account; after the row's session check and a cancelled sheet,
    /// "Sign In" over the same red line. It now shows Today's row, with the account to sign back
    /// into and no red line, before the check (still signed in) and after it (signed out), and the
    /// sheet the row opens starts with that address. Signing back in ends it, as on Today.
    func testSettingsShowsTheReauthRowWithNoErrorBeforeAndAfterTheSessionCheck() async throws {
        XCTAssertEqual(account(), SettingsAccountState(header: .signedIn(email: "a@example.com"),
                                                       showsAccountActions: true, footerError: nil))
        server.on("POST", "/v1/sync/push", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))

        await sync.sync(context: context)

        XCTAssertNil(sync.syncError)
        XCTAssertEqual(account(), SettingsAccountState(header: .signInAgain(email: "a@example.com"),
                                                       showsAccountActions: true, footerError: nil))

        // The row's tap: the check finds the session gone and signs the device out.
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        let flow = SignInAgainFlow(auth: auth, sync: sync)
        await flow.start(context: context)

        XCTAssertTrue(flow.showingLogin)
        XCTAssertEqual(flow.loginEmail, "a@example.com", "the login sheet's email, taken before the check forgot it")
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertEqual(account(), SettingsAccountState(header: .signInAgain(email: "a@example.com"),
                                                       showsAccountActions: false, footerError: nil),
                       "the store's owner, once the session's account is forgotten")

        server.on("POST", "/v1/auth/verify", respond: .ok(
            #"{"ok":true,"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"},"sessionToken":"tok-A2"}"#))
        server.on("POST", "/v1/sync/push", respond: .ok(SyncStubBodies.pushOK))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))
        let signedIn = await auth.verifyToken("magic-A")
        XCTAssertTrue(signedIn)
        let ran = await sync.sync(context: context)   // Settings' post-sign-in sync
        XCTAssertTrue(ran)
        XCTAssertEqual(account().header, .signedIn(email: "a@example.com"))
    }

    /// The cold-launch variant: no sync met the 401, the launch check deleted the dead token, and
    /// Settings shows the row — for the store's owner — where it showed a bare "Sign In".
    func testSettingsShowsTheReauthRowAfterAColdLaunchFoundTheSessionGone() async throws {
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        auth = AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                           defaults: authDefaults.defaults, onSignOut: {}, onSignIn: {})
        sync = SyncService(api: server.makeClient(tokenStore: tokens), defaults: local.defaults,
                           deletionQueue: SyncDeletionQueue(local: local.defaults, shared: appGroup.defaults),
                           sessions: auth, recoveryLog: recovery.log)
        await auth.waitForSessionRestore()

        XCTAssertEqual(account(), SettingsAccountState(header: .signInAgain(email: "a@example.com"),
                                                       showsAccountActions: false, footerError: nil))
        let flow = SignInAgainFlow(auth: auth, sync: sync)
        await flow.start(context: context)
        XCTAssertTrue(flow.showingLogin, "no token left: the sheet at once")
        XCTAssertEqual(flow.loginEmail, "a@example.com")
    }

    /// The red footer is for a signed-in account's sync. A failure's sentence used to stay under
    /// "Sign In" after a sign-out (`signedOut()` keeps `syncError`); signed out it is not shown.
    func testSettingsShowsASyncErrorOnlyWhileSignedIn() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(status: 500, body: #"{"error":"Internal error"}"#))
        await sync.sync(context: context)
        XCTAssertEqual(account().footerError, "Internal error")

        sync.signedOut()
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        await auth.logout()

        XCTAssertEqual(account(), SettingsAccountState(header: .signIn, showsAccountActions: false, footerError: nil))
    }

    /// A deliberate sign-out is not a lost session: the row does not follow the user out.
    func testSigningOutRemovesTheReauthRow() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))
        await sync.sync(context: context)
        XCTAssertEqual(try line(), .signInAgain)

        sync.signedOut()   // what AuthService.logout calls (`onSignOut`)
        server.on("POST", "/v1/auth/logout", respond: .ok(#"{"ok":true}"#))
        await auth.logout()

        XCTAssertNil(try line())
    }

    /// Acceptance 9: the pause switch reads "Sync paused" — with a habit waiting, not a count.
    func testThePauseSwitchReadsSyncPaused() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(status: 503, body: Self.pausedBody, headers: ["Retry-After": "600"]))

        await sync.sync(context: context)

        XCTAssertTrue(sync.isPaused)
        XCTAssertEqual(try line(), .paused)
    }

    func testARateLimitReadsSyncPaused() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(
            status: 429, body: #"{"error":"rate_limited","code":"rate_limited","retryAfterSeconds":60}"#))

        await sync.sync(context: context)

        XCTAssertFalse(sync.isPaused, "a rate limit is not the pause switch")
        XCTAssertEqual(try line(), .paused)
    }

    /// No answer at all, with the habit still waiting: "Offline — 1 change waiting" — while the
    /// window that failure set is open. Once it lapses a launch or foreground may run again, and
    /// the line says only what is known then: a change waiting (review critic-2).
    func testNoAnswerWithAChangeWaitingReadsOfflineUntilItsWindowLapses() async throws {
        server.on("POST", "/v1/sync/push") { _ in throw URLError(.notConnectedToInternet) }

        await sync.sync(context: context)

        let backoff = try XCTUnwrap(sync.backoff)
        XCTAssertEqual(backoff.reason, .offline)
        XCTAssertEqual(try line(), .offline(waiting: 1, until: backoff.retryAt))
        XCTAssertEqual(try line(at: backoff.retryAt), .waiting(1))
        XCTAssertEqual(sync.backoff?.reason, .offline, "the reason itself stays until a run succeeds")
    }

    /// Review critic-2: launch after launch with no network must not push the next automatic
    /// sync hours out. No request reached the server, so each failure waits about a minute —
    /// the fourth used to wait 8 min, the tenth 6 h, after the network was back.
    func testRepeatedNoAnswerFailuresKeepTheAutomaticWindowAboutAMinute() async throws {
        server.on("POST", "/v1/sync/push") { _ in throw URLError(.notConnectedToInternet) }

        for _ in 1...4 { await sync.sync(context: context) }

        let backoff = try XCTUnwrap(sync.backoff)
        XCTAssertEqual(backoff.reason, .offline)
        XCTAssertLessThanOrEqual(backoff.delay, 72, "the curve's first step, jitter included")
        XCTAssertLessThanOrEqual(try XCTUnwrap(sync.nextAutomaticSync), Date().addingTimeInterval(72))
    }

    /// A 5xx is a count too, never an error on Today.
    func testAServerErrorWithAChangeWaitingIsACount() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(status: 500, body: #"{"error":"Internal error"}"#))

        await sync.sync(context: context)

        XCTAssertEqual(try line(), .waiting(1))
    }

    /// A row the server refused (`row_error`) is held: once the rest has synced, Today points at
    /// Settings.
    func testAHeldRowPointsAtSettings() async throws {
        let habit = try XCTUnwrap(context.fetch(FetchDescriptor<Habit>()).first)
        server.on("POST", "/v1/sync/push", respond: .ok(#"""
        {"ok":true,"skipped":{"habits":["\#(habit.id.uuidString)"]},
         "skippedReasons":{"habits":{"\#(habit.id.uuidString)":"row_error"}}}
        """#))
        server.on("GET", "/v1/sync/pull", respond: .ok(SyncStubBodies.pull()))

        await sync.sync(context: context)

        XCTAssertEqual(habit.activeHold, .rowError)
        XCTAssertEqual(try line(), .held(1))
    }
}
