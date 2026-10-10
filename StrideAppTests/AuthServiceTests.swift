import XCTest
@testable import Stride

/// AuthService with an APIClient over a stubbed server. Both get the same in-memory token store,
/// as both share the one Keychain item in the app.
@MainActor
final class AuthServiceTests: XCTestCase {

    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var local: ScratchDefaults!
    private var signOuts = 0

    override func setUp() {
        super.setUp()
        server = StubServer()
        tokens = InMemoryTokenStore()
        local = ScratchDefaults("auth.local")
        signOuts = 0
    }

    override func tearDown() {
        server.stop()
        local.remove()
        server = nil
        tokens = nil
        local = nil
        super.tearDown()
    }

    private func makeAuth() -> AuthService {
        AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens, defaults: local.defaults,
                    onSignOut: { [unowned self] in self.signOuts += 1 }, onSignIn: {})
    }

    /// The magic-link verify response is the only place the app ever receives a session token;
    /// if it is not stored, the user is signed in until the next launch and then silently not.
    func testVerifyTokenStoresTheSessionTokenAndSignsIn() async throws {
        server.on("POST", "/v1/auth/verify", respond: .ok(#"""
        {"ok":true,"user":{"id":7,"email":"a@example.com","tier":"free","created_at":"2026-09-01 10:00:00"},
         "sessionToken":"sess-abc"}
        """#))
        let auth = makeAuth()
        XCTAssertTrue(auth.isSessionRestored, "no stored token: nothing to restore")

        let ok = await auth.verifyToken("magic-123")

        XCTAssertTrue(ok)
        XCTAssertNil(auth.error)
        XCTAssertEqual(tokens.read(), "sess-abc")
        XCTAssertEqual(auth.userEmail, "a@example.com")
        XCTAssertTrue(auth.isLoggedIn)
        XCTAssertEqual(server.requests.first?.json?["token"] as? String, "magic-123")
    }

    /// Logout clears the token and ends the sync session even when the server cannot be reached
    /// — otherwise an offline logout leaves the old token in the Keychain and a sync in flight
    /// writing for an account that is gone. (Since 1.3.1 it no longer resets the cursor: the
    /// owner gate keeps the next account off this device's data, and the same account resumes.)
    func testLogoutClearsTokenAndEndsTheSyncSessionEvenWhenTheServerFails() async {
        tokens.save("sess-abc")
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/auth/logout") { _ in throw URLError(.notConnectedToInternet) }
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isLoggedIn, "precondition: the stored token restored a session")

        await auth.logout()

        XCTAssertNil(tokens.read())
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertEqual(signOuts, 1)
        XCTAssertNil(auth.currentSyncSession())
        XCTAssertNil(local.defaults.dictionary(forKey: AuthService.sessionAccountKey), "the account is forgotten with the token")
    }

    // MARK: - The sync session

    /// The session's account outlives a launch whose session check fails offline: the token is
    /// still that account's, and a sync must know whose it is (it runs only as the store's
    /// owner). Without this, Erase Local Data's pre-erase sync could not run until a check
    /// succeeded.
    func testTheSessionsAccountIsKnownAfterAnOfflineLaunch() async {
        server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
        let first = makeAuth()
        _ = await first.verifyToken("magic-123")
        XCTAssertEqual(first.currentSyncSession(),
                       SyncSession(token: "sess-from-link", account: SyncAccount(id: "7", email: "a@example.com")))

        // Relaunch, offline.
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = makeAuth()
        let session = await relaunched.resolveSyncSession()

        XCTAssertFalse(relaunched.isLoggedIn, "no user loaded")
        XCTAssertEqual(session?.account.id, "7")
        XCTAssertEqual(session?.token, "sess-from-link")
    }

    /// A stored token whose account was never named here (a 1.3.0 session, first 1.3.1 launch,
    /// check failed): resolving asks the server once more, and an error leaves it unknown — no
    /// session, so no sync, rather than a guess.
    func testAnUnnamedTokenIsResolvedByTheServerOrNotAtAll() async {
        tokens.save("sess-130")
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.timedOut) }
        let auth = makeAuth()
        await auth.waitForSessionRestore()

        let offline = await auth.resolveSyncSession()
        XCTAssertNil(offline)

        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":{"id":9,"email":"c@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        let online = await auth.resolveSyncSession()
        XCTAssertEqual(online, SyncSession(token: "sess-130", account: SyncAccount(id: "9", email: "c@example.com")))
    }

    // MARK: - The launch check and its recheck (1.4.0, RELEASE-1.4.0.md D5)

    private nonisolated static let userSeven = #"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#

    /// A waiter that gives up — on its deadline, or because its task was cancelled (an expired
    /// background task) — leaves `isSessionRestored` as it was: only the check writes it. Before
    /// 1.4.0 a timed-out waiter set it with the check still in flight, so every later waiter
    /// returned at once and a check that then failed was never waited for; and a cancelled one
    /// spun on the main actor until its deadline (a cancelled `Task.sleep` throws at once). The
    /// check, when it answers, still settles it.
    func testAWaiterThatGivesUpLeavesTheCheckPending() async {
        tokens.save("sess-abc")
        let answer = DispatchSemaphore(value: 0)
        server.on("GET", "/v1/auth/session") { _ in
            answer.wait()   // the launch check stays in flight until the test lets it answer
            return .ok(Self.userSeven)
        }
        let auth = makeAuth()
        defer { answer.signal() }   // never leave the loading thread blocked, whatever fails

        await auth.waitForSessionRestore(timeout: .milliseconds(200))
        XCTAssertFalse(auth.isSessionRestored, "a deadline is not an answer")

        let start = ContinuousClock.now
        let waiter = Task { await auth.waitForSessionRestore() }
        waiter.cancel()
        await waiter.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "a cancelled waiter returns at once, not at its deadline")
        XCTAssertFalse(auth.isSessionRestored)

        answer.signal()
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isSessionRestored, "the check settles it")
        XCTAssertTrue(auth.isLoggedIn)
    }

    /// The foreground's recheck signs a device back in whose launch check failed offline — the
    /// state a background launch can leave a process in for the user's next open. It goes around
    /// `checkSession`, which would show an open login sheet's spinner (`isLoading`) and clear its
    /// message (`error`): neither changes, even while the request is in flight. Signed in, it asks
    /// nothing more.
    func testTheRecheckSignsBackInWithoutTouchingTheLoginSheetsState() async throws {
        tokens.save("sess-abc")
        let calls = Counter()
        let answer = DispatchSemaphore(value: 0)
        server.on("GET", "/v1/auth/session") { _ in
            if calls.next() == 1 { throw URLError(.notConnectedToInternet) }
            answer.wait()
            return .ok(Self.userSeven)
        }
        server.on("POST", "/v1/auth/request-link", respond: .init(status: 500, body: #"{"error":"Mail is down"}"#))
        let auth = makeAuth()
        defer { answer.signal() }
        await auth.waitForSessionRestore()
        XCTAssertFalse(auth.isLoggedIn, "precondition: the launch check failed offline")
        _ = await auth.requestMagicLink(email: "a@example.com")
        let shown = try XCTUnwrap(auth.error, "precondition: the login sheet shows a message")

        let recheck = Task { await auth.recheckStoredSessionIfNeeded() }
        let deadline = ContinuousClock.now + .seconds(5)
        while server.paths.filter({ $0 == "/v1/auth/session" }).count < 2 {
            guard ContinuousClock.now < deadline else { return XCTFail("no recheck was sent") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(auth.isLoading, "no spinner on the login sheet while the recheck is in flight")
        XCTAssertEqual(auth.error, shown)
        answer.signal()
        await recheck.value

        XCTAssertTrue(auth.isLoggedIn)
        XCTAssertEqual(auth.error, shown, "the sheet's message stays")
        XCTAssertFalse(auth.isLoading)

        await auth.recheckStoredSessionIfNeeded()
        XCTAssertEqual(server.paths.filter { $0 == "/v1/auth/session" }.count, 2, "signed in: nothing to recheck")
    }

    /// `{user: null}` on the recheck is the session found gone, as at launch: the dead token goes,
    /// and Today's "Sign in again" row goes up.
    func testARecheckThatFindsTheSessionGoneSignsOutForGood() async {
        tokens.save("sess-abc")
        let calls = Counter()
        server.on("GET", "/v1/auth/session") { _ in
            if calls.next() == 1 { throw URLError(.notConnectedToInternet) }
            return .ok(#"{"user":null}"#)
        }
        let auth = makeAuth()
        await auth.waitForSessionRestore()

        await auth.recheckStoredSessionIfNeeded()

        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read())
        XCTAssertTrue(auth.sessionExpired)
    }

    // MARK: - One-tap sign-in (the universal link)

    private static let linkToken = "3f2b8c1e9a7d4c05b6e1f0a2d3c4b5a69788f1e2d3c4b5a6978801a2b3c4d5e6"
    private static let loginLink = URL(string: "https://stride-api.colorarchive.me/login?token=\(linkToken)")!
    private static let verifyOK = #"""
    {"ok":true,"user":{"id":7,"email":"a@example.com","tier":"free","created_at":"2026-09-01 10:00:00"},
     "sessionToken":"sess-from-link"}
    """#

    /// Signed out: the link's token is verified and the device is signed in — no paste.
    func testLoginLinkSignsInWhenSignedOut() async {
        server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
        let auth = makeAuth()

        let outcome = await auth.handleLoginLink(Self.loginLink)

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertTrue(auth.isLoggedIn)
        XCTAssertEqual(tokens.read(), "sess-from-link")
        XCTAssertEqual(server.paths, ["/v1/auth/verify"])
        XCTAssertEqual(server.requests.first?.json?["token"] as? String, Self.linkToken)
    }

    /// Signed in: the link is NOT used. Verifying it would switch this device to the link's
    /// account and push this device's habits into it on the next sync (M2 builds the choice).
    func testLoginLinkIsIgnoredWhenAlreadySignedIn() async {
        tokens.save("sess-current")
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":{"id":1,"email":"me@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
        let auth = makeAuth()

        // No waitForSessionRestore() first, on purpose: a link that launched the app arrives
        // while the stored session is still being checked, and must wait for that check rather
        // than read the not-yet-loaded user as "signed out".
        let outcome = await auth.handleLoginLink(Self.loginLink)

        XCTAssertEqual(outcome, .ignoredAlreadySignedIn)
        XCTAssertEqual(tokens.read(), "sess-current")
        XCTAssertEqual(auth.userEmail, "me@example.com")
        XCTAssertFalse(server.paths.contains("/v1/auth/verify"), "the link's token must never be spent")
    }

    /// A session check that failed offline leaves `currentUser` nil but the token stored — that
    /// device is still signed in, and the link must not replace its session.
    func testLoginLinkIsIgnoredWhenTheSessionCheckFailedOffline() async {
        tokens.save("sess-current")
        server.on("GET", "/v1/auth/session") { _ in throw URLError(.notConnectedToInternet) }
        server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        XCTAssertFalse(auth.isLoggedIn, "precondition: no user loaded")

        let outcome = await auth.handleLoginLink(Self.loginLink)

        XCTAssertEqual(outcome, .ignoredAlreadySignedIn)
        XCTAssertEqual(tokens.read(), "sess-current")
        XCTAssertFalse(server.paths.contains("/v1/auth/verify"))
        XCTAssertNotNil(auth.error, "an open login sheet says why the tap did nothing")
    }

    /// `/v1/auth/session` answers 200 `{user: null}` for an expired, signed-out or deleted
    /// session — never 401 — so APIClient's 401 path never cleared the token. The device showed
    /// "Log In" and then ignored every login link as "already signed in": one-tap sign-in failed
    /// for exactly the people returning after 30 days. The dead token goes at the launch check.
    func testADeadSessionAtLaunchDeletesTheTokenAndALoginLinkSignsIn() async {
        tokens.save("sess-expired")
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read(), "the server said this session is gone")
        XCTAssertFalse(auth.hasStoredSession)

        let outcome = await auth.handleLoginLink(Self.loginLink)

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(tokens.read(), "sess-from-link")
        XCTAssertEqual(server.paths, ["/v1/auth/session", "/v1/auth/verify"])
    }

    /// The launch check failed offline; by the time the user taps a link the network is back.
    /// The link asks again rather than trusting the old failure: a live session means signed
    /// in (the link is not spent), a dead one means the link signs in.
    func testALoginLinkRechecksASessionCheckThatFailedAtLaunch() async {
        for (answer, expected) in [(#"{"user":{"id":1,"email":"me@example.com","created_at":"2026-09-01 10:00:00"}}"#,
                                    AuthService.LoginLinkOutcome.ignoredAlreadySignedIn),
                                   (#"{"user":null}"#, .signedIn)] {
            server.stop()
            server = StubServer()
            tokens = InMemoryTokenStore("sess-current")
            let calls = Counter()
            server.on("GET", "/v1/auth/session") { _ in
                if calls.next() == 1 { throw URLError(.notConnectedToInternet) }
                return .ok(answer)
            }
            server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
            let auth = makeAuth()
            await auth.waitForSessionRestore()
            XCTAssertFalse(auth.isLoggedIn, "precondition: the launch check failed")

            let outcome = await auth.handleLoginLink(Self.loginLink)

            XCTAssertEqual(outcome, expected, answer)
            XCTAssertTrue(auth.isLoggedIn, answer)
            XCTAssertNil(auth.error, answer)
            if expected == .signedIn {
                XCTAssertEqual(tokens.read(), "sess-from-link")
            } else {
                XCTAssertEqual(tokens.read(), "sess-current")
                XCTAssertFalse(server.paths.contains("/v1/auth/verify"), "the link's token must never be spent")
            }
        }
    }

    /// An answer about the old token must not delete a new one: a pasted token verified while
    /// the launch check was in flight replaced it.
    func testADeadSessionAnswerDoesNotDeleteATokenThatReplacedIt() async {
        tokens.save("sess-expired")
        server.on("GET", "/v1/auth/session") { request in
            // Like the server: only the old token's session is gone.
            guard request.header("Authorization") == "Bearer sess-expired" else {
                return .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#)
            }
            Thread.sleep(forTimeInterval: 0.3)   // the launch check is still in flight…
            return .ok(#"{"user":null}"#)
        }
        server.on("POST", "/v1/auth/verify", respond: .ok(Self.verifyOK))
        let auth = makeAuth()

        let verified = await auth.verifyToken("magic-123")   // …when a pasted token signs in
        await auth.waitForSessionRestore()

        XCTAssertTrue(verified)
        XCTAssertEqual(tokens.read(), "sess-from-link")
        XCTAssertTrue(auth.isLoggedIn, "the stale answer must not sign the new session out")
    }

    /// Only an exact login link reaches the server; any other URL the app is handed does nothing.
    func testNonLoginURLsDoNothing() async {
        let auth = makeAuth()
        for string in ["https://evil.example/login?token=\(Self.linkToken)",
                       "stride://login?token=\(Self.linkToken)",
                       "https://stride-api.colorarchive.me/privacy",
                       "https://stride-api.colorarchive.me/login?token=<script>"] {
            let outcome = await auth.handleLoginLink(URL(string: string)!)
            XCTAssertEqual(outcome, .notALoginLink, string)
        }
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertNil(tokens.read())
    }

    /// One tap can arrive through both `.onOpenURL` and `.onContinueUserActivity`. The token is
    /// single-use, so a second verify would fail and show "Invalid or expired login link" under
    /// a sign-in that worked.
    func testASecondDeliveryOfTheSameLinkIsNotVerifiedAgain() async {
        server.on("POST", "/v1/auth/verify") { _ in
            Thread.sleep(forTimeInterval: 0.2)   // keep the first verify in flight
            return .ok(Self.verifyOK)
        }
        let auth = makeAuth()

        async let first = auth.handleLoginLink(Self.loginLink)
        async let second = auth.handleLoginLink(Self.loginLink)
        let outcomes = await [first, second]

        XCTAssertEqual(Set(outcomes), [.signedIn, .ignoredInProgress])
        XCTAssertEqual(server.paths, ["/v1/auth/verify"])
        XCTAssertNil(auth.error)

        let third = await auth.handleLoginLink(Self.loginLink)
        XCTAssertEqual(third, .ignoredAlreadySignedIn)
        XCTAssertEqual(server.paths.count, 1)
    }

    /// A used or expired link fails visibly (the login sheet shows `error`) and stores nothing.
    func testAnExpiredLinkFailsWithTheServersSentence() async {
        server.on("POST", "/v1/auth/verify", respond: .init(status: 400, body: #"{"error":"Invalid or expired login link"}"#))
        let auth = makeAuth()

        let outcome = await auth.handleLoginLink(Self.loginLink)

        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(tokens.read())
        XCTAssertEqual(auth.error, "Invalid or expired login link")
    }
}

/// Counts calls to a stub handler, which runs on the URL loading system's thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
