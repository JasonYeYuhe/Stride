import XCTest
@testable import Stride

/// APIClient against a stubbed server: the real request building, status handling and decoding.
/// StrideTests cannot see this type at all (it has no TEST_HOST), which is why the encoder
/// comment in APIClient.swift could only point at a wire-format test of a copy.
final class APIClientTests: XCTestCase {

    private var server: StubServer!
    private var tokens: InMemoryTokenStore!
    private var api: APIClient!

    override func setUp() {
        super.setUp()
        server = StubServer()
        tokens = InMemoryTokenStore("tok-123")
        api = server.makeClient(tokenStore: tokens)
    }

    override func tearDown() {
        server.stop()
        server = nil
        tokens = nil
        api = nil
        super.tearDown()
    }

    private static let emptyPull = #"""
    {"habits":[],"entries":[],"groups":[],"deletedHabitIds":[],"deletedEntryIds":[],
     "deletedGroupIds":[],"serverTime":"2026-09-26T10:00:00.000Z",
     "totals":{"habits":0,"entries":0,"groups":0}}
    """#

    // MARK: - Session token

    /// A 401 means the server no longer accepts this session (expired, revoked, account
    /// deleted). The token has to go, or every later request re-sends it, `isLoggedIn` stays
    /// true, and Settings shows a signed-in account that can never sync.
    func testUnauthorizedClearsTheStoredToken() async {
        server.on("GET", "/v1/auth/session", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))

        do {
            _ = try await api.getSession()
            XCTFail("a 401 must throw")
        } catch APIError.unauthorized {
        } catch {
            XCTFail("expected APIError.unauthorized, got \(error)")
        }

        XCTAssertNil(tokens.read())
        let loggedIn = await api.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    /// Only 401 signs out. A 5xx or 429 — M0's pause switch and per-user limiter — is the
    /// server's problem, and clearing the token for it would sign every user out during an
    /// outage. Both bodies server/lib/clientVersion.js `errorBody` can send must still surface
    /// as `APIError.server` with a message, not "Request failed" or a decode error:
    /// - without X-Stride-Client (every build up to this one): the sentence in `error`, which
    ///   this build shows verbatim in the Settings footer;
    /// - with the header (from 1.3.0): `{error: code, code, message}`. This build shows `error`,
    ///   i.e. the code. M1 switches APIClient to prefer `message`; change the second assertion
    ///   then, deliberately — until then it pins that the extra keys do not break decoding.
    func testServerErrorsKeepTheTokenAndSurfaceTheirMessage() async {
        let sentence = "Sync is paused for maintenance. Your data is safe on this device; it will sync when the pause ends."
        server.on("GET", "/v1/sync/pull", respond: .init(
            status: 503, body: #"{"error":"\#(sentence)","code":"sync_paused","retryAfterSeconds":60}"#))
        server.on("POST", "/v1/sync/push", respond: .init(
            status: 429, body: #"""
            {"error":"rate_limited","code":"rate_limited",
             "message":"Too many sync requests, please try again later","retryAfterSeconds":30}
            """#))

        do {
            _ = try await api.pullChanges()
            XCTFail("a 503 must throw")
        } catch APIError.server(let status, let shown) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(shown, sentence)
        } catch {
            XCTFail("expected APIError.server, got \(error)")
        }

        do {
            try await api.pushChanges(SyncPushPayload(habits: [], entries: [], groups: [],
                                                      deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: []))
            XCTFail("a 429 must throw")
        } catch APIError.server(let status, let shown) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(shown, "rate_limited")
        } catch {
            XCTFail("expected APIError.server, got \(error)")
        }

        XCTAssertEqual(tokens.read(), "tok-123")
    }

    func testRequestsCarryTheStoredTokenAsBearerAndNoneWithoutOne() async throws {
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.emptyPull))
        server.on("POST", "/v1/auth/request-link", respond: .ok(#"{"ok":true}"#))

        _ = try await api.pullChanges()
        tokens.delete()
        try await api.requestMagicLink(email: "a@example.com")

        let requests = server.requests
        // Guarded, not just asserted: an out-of-range index crashes the HOST app, not the test.
        guard requests.count == 2 else { return XCTFail("expected 2 requests, got \(requests.count)") }
        XCTAssertEqual(requests[0].authorization, "Bearer tok-123")
        XCTAssertNil(requests[1].authorization, "no token, no header — not \"Bearer \" or a stale value")
    }

    // MARK: - Wire format

    /// The server reads camelCase (`e.habitId`, `req.body.deletedHabitIds`). A snake_case
    /// encoder shipped once and silently dropped every entry and every deletion (3829085).
    func testPushBodyIsCamelCase() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let payload = SyncPushPayload(
            habits: [],
            entries: [SyncEntry(id: "e-1", habitId: "h-1", date: "2026-09-26", note: nil, value: 1,
                                createdAt: "2026-09-26T00:00:00Z", updatedAt: "2026-09-26T00:00:00Z")],
            groups: [],
            deletedHabitIds: ["h-gone"], deletedEntryIds: [], deletedGroupIds: []
        )

        try await api.pushChanges(payload)

        let body = try XCTUnwrap(server.requests.first?.json)
        XCTAssertEqual(body["deletedHabitIds"] as? [String], ["h-gone"])
        XCTAssertNil(body["deleted_habit_ids"])
        let entry = try XCTUnwrap((body["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["habitId"] as? String, "h-1")
        XCTAssertNil(entry["habit_id"])
    }

    /// M0 changes the push response from `{ok:true}` to one that also lists what was applied
    /// and skipped, and the server sends it to every client, shipped ones included. A push that
    /// the server accepted must not throw for either shape — a decode failure here would leave
    /// every deletion queued and the cursor frozen on every installed app.
    func testPushAcceptsTheBareAndTheAppliedSkippedResponse() async throws {
        let payload = SyncPushPayload(habits: [], entries: [], groups: [],
                                      deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [])

        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        try await api.pushChanges(payload)

        // The shape server/routes/sync.js sends since M0, skippedReasons included.
        server.on("POST", "/v1/sync/push", respond: .ok(#"""
        {"ok":true,"applied":{"habits":1,"entries":0,"groups":0},
         "skipped":{"habits":[],"entries":["3f2b8c1e-0000-4000-8000-000000000001"],"groups":[]},
         "skippedReasons":{"habits":{},"entries":{"3f2b8c1e-0000-4000-8000-000000000001":"unknown_habit"},"groups":{}}}
        """#))
        try await api.pushChanges(payload)

        XCTAssertEqual(server.paths, ["/v1/sync/push", "/v1/sync/push"])
    }

    /// Pull responses gain `totals` in M0. Rows are camelCase as the server maps them.
    func testPullDecodesAResponseCarryingTotals() async throws {
        server.on("GET", "/v1/sync/pull", respond: .ok(#"""
        {"habits":[{"id":"h-1","name":"Read","emoji":"📚","colorHex":"#34C759","isArchived":false,
                    "sortOrder":0,"reminderEnabled":false,"reminderHour":20,"reminderMinute":0,
                    "note":null,"kind":"binary","targetValue":null,"unit":null,"scheduleKind":"daily",
                    "timesPerWeek":null,"activeDaysMask":null,"groupId":null,
                    "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z"}],
         "entries":[{"id":"e-1","habitId":"h-1","date":"2026-09-25","note":null,"value":1,
                     "createdAt":"2026-09-25T08:00:00Z","updatedAt":"2026-09-25T08:00:00Z"}],
         "groups":[],"deletedHabitIds":[],"deletedEntryIds":[],"deletedGroupIds":[],
         "serverTime":"2026-09-26T10:00:00.123Z","totals":{"habits":1,"entries":1,"groups":0}}
        """#))

        let response = try await api.pullChanges()

        XCTAssertEqual(response.habits.map(\.id), ["h-1"])
        XCTAssertEqual(response.habits.first?.colorHex, "#34C759")
        XCTAssertEqual(response.entries.map(\.habitId), ["h-1"])
        XCTAssertEqual(response.serverTime, "2026-09-26T10:00:00.123Z")
    }
}
