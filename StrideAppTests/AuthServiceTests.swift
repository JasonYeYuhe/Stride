import XCTest
@testable import Stride

/// AuthService with an APIClient over a stubbed server. Both get the same in-memory token store,
/// as both share the one Keychain item in the app.
@MainActor
final class AuthServiceTests: XCTestCase {

    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var syncResets = 0

    override func setUp() {
        super.setUp()
        server = StubServer()
        tokens = InMemoryTokenStore()
        syncResets = 0
    }

    override func tearDown() {
        server.stop()
        server = nil
        tokens = nil
        super.tearDown()
    }

    private func makeAuth() -> AuthService {
        AuthService(api: server.makeClient(tokenStore: tokens), tokenStore: tokens,
                    resetSyncState: { [unowned self] in self.syncResets += 1 })
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

    /// Logout clears the token and the sync state even when the server cannot be reached —
    /// otherwise an offline logout leaves the next account on this device syncing against the
    /// previous account's cursor, and the old token still in the Keychain.
    func testLogoutClearsTokenAndSyncStateEvenWhenTheServerFails() async {
        tokens.save("sess-abc")
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":{"id":7,"email":"a@example.com","created_at":"2026-09-01 10:00:00"}}"#))
        server.on("POST", "/v1/auth/logout") { _ in throw URLError(.notConnectedToInternet) }
        let auth = makeAuth()
        await auth.waitForSessionRestore()
        XCTAssertTrue(auth.isLoggedIn, "precondition: the stored token restored a session")

        await auth.logout()

        XCTAssertNil(tokens.read())
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertEqual(syncResets, 1)
    }

    /// The deep-link path takes a token from a URL — anything can open a URL. Only a plausible
    /// token may reach the Keychain.
    func testMalformedDeepLinkTokenIsNeverStored() {
        let auth = makeAuth()

        auth.loginWithSessionToken("abc def")
        auth.loginWithSessionToken("<script>")
        auth.loginWithSessionToken(String(repeating: "a", count: 513))
        auth.loginWithSessionToken("   ")

        XCTAssertNil(tokens.read())
        XCTAssertTrue(server.requests.isEmpty, "nothing to check a session with")
    }
}
