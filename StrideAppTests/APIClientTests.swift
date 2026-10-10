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
    /// outage. Both bodies server/lib/clientVersion.js `errorBody` can send surface as
    /// `APIError.server` with the code and the SENTENCE, never the code as the message:
    /// - with X-Stride-Client, which this build sends: `{error: code, code, message}`. 1.3.0
    ///   briefly showed `error`, i.e. "rate_limited", in the Settings footer — `message` first;
    /// - without it (a header the server could not parse): the sentence in `error`.
    func testServerErrorsKeepTheTokenAndSurfaceTheSentenceNotTheCode() async {
        let sentence = "Sync is paused for maintenance. Your data is safe on this device; it will sync when the pause ends."
        server.on("GET", "/v1/auth/session", respond: .init(
            status: 503, body: #"{"error":"\#(sentence)","code":"sync_paused","retryAfterSeconds":60}"#))
        server.on("POST", "/v1/auth/request-link", respond: .init(
            status: 429, body: #"""
            {"error":"rate_limited","code":"rate_limited",
             "message":"Too many sync requests, please try again later","retryAfterSeconds":30}
            """#))

        do {
            _ = try await api.getSession()
            XCTFail("a 503 must throw")
        } catch APIError.server(let status, let code, let message) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(code, "sync_paused")
            XCTAssertEqual(message, sentence, "legacy shape: the sentence is `error`")
        } catch {
            XCTFail("expected APIError.server, got \(error)")
        }

        do {
            try await api.requestMagicLink(email: "a@example.com")
            XCTFail("a 429 must throw")
        } catch let error as APIError {
            guard case .server(let status, let code, let message) = error else {
                return XCTFail("expected APIError.server, got \(error)")
            }
            XCTAssertEqual(status, 429)
            XCTAssertEqual(code, "rate_limited")
            XCTAssertEqual(message, "Too many sync requests, please try again later", "code-first shape: `message`, not `error`")
            XCTAssertEqual(error.localizedDescription, "Too many sync requests, please try again later")
        } catch {
            XCTFail("expected APIError, got \(error)")
        }

        XCTAssertEqual(tokens.read(), "tok-123")
    }

    /// The routes that predate codes (`{error: "Invalid or expired login link"}`) still show their
    /// sentence, and a body that is not JSON (nginx's 502 page mid-deploy) is still an
    /// `APIError.server`, with no message rather than a decode error.
    func testLegacyAndNonJSONErrorBodies() async {
        server.on("POST", "/v1/auth/verify", respond: .init(status: 400, body: #"{"error":"Invalid or expired login link"}"#))
        server.on("GET", "/v1/auth/session", respond: .init(status: 502, body: "<html><body>502 Bad Gateway</body></html>"))

        do {
            _ = try await api.verifyToken("used-token-0123456789")
            XCTFail("a 400 must throw")
        } catch APIError.server(let status, let code, let message) {
            XCTAssertEqual(status, 400)
            XCTAssertNil(code)
            XCTAssertEqual(message, "Invalid or expired login link")
        } catch {
            XCTFail("expected APIError.server, got \(error)")
        }

        do {
            _ = try await api.getSession()
            XCTFail("a 502 must throw")
        } catch APIError.server(let status, let code, let message) {
            XCTAssertEqual(status, 502)
            XCTAssertNil(code)
            XCTAssertNil(message)
        } catch {
            XCTFail("expected APIError.server, got \(error)")
        }
    }

    /// What the Settings footer and the login sheet show (`APIError.displayMessage`). Codes this
    /// build knows get its own, translated sentence — never the code, whichever body shape it
    /// came in; unknown codes get the server's sentence.
    @MainActor
    func testDisplayMessageIsNeverARawCode() {
        let rateLimited = APIError.server(statusCode: 429, code: "rate_limited", message: "Too many sync requests, please try again later")
        XCTAssertEqual(APIError.displayMessage(for: rateLimited),
                       appLocalized("Too many sync requests. Please try again in a few minutes."))
        // A client whose header the server could not parse gets the sentence in `error`; the
        // code still decides.
        let paused = APIError.server(statusCode: 503, code: "sync_paused", message: "Sync is paused for maintenance.")
        XCTAssertEqual(APIError.displayMessage(for: paused),
                       appLocalized("Sync is paused for maintenance. Your data is safe on this device and will sync when the pause ends."))
        let unknown = APIError.server(statusCode: 400, code: "invalid_payload", message: "Sync data was malformed.")
        XCTAssertEqual(APIError.displayMessage(for: unknown), "Sync data was malformed.")
        XCTAssertEqual(APIError.displayMessage(for: APIError.server(statusCode: 502, code: nil, message: nil)),
                       appLocalized("Request failed"))
        XCTAssertEqual(APIError.displayMessage(for: APIError.unauthorized), appLocalized("Please log in again"))

        for error in [rateLimited, paused, unknown] {
            XCTAssertFalse(APIError.displayMessage(for: error).contains("_"), "\(error) displayed as a code")
        }
    }

    // MARK: - Nothing on disk but the Keychain item (E2E S9)

    /// `URLSession.shared` kept the /v1/auth/verify answer — the live session token — and every
    /// pull in Library/Caches/<bundle>/Cache.db, and the `stride_session` cookie the verify answer
    /// sets in the cookie store. The app's client stores neither, and sends no cookie.
    func testTheAppsSessionHasNoURLCacheAndNoCookies() throws {
        XCTAssertTrue(APIClient.shared.session === APIClient.defaultSession, "shared goes through it")
        let configuration = APIClient.defaultSession.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        // What the launch purge cleans: the production API whatever the build, and this build's.
        XCTAssertTrue(APIClient.apiHosts.contains("stride-api.colorarchive.me"))
        XCTAssertTrue(APIClient.apiHosts.contains(try XCTUnwrap(APIClient.defaultBaseURL.host)))
    }

    /// What earlier builds left: the launch purge empties the URL cache and deletes the cookies a
    /// request to an API host would carry — the verify answer's host-only cookie, a domain cookie
    /// above it — and leaves other hosts' alone. Over a cache and a cookie store of the test's own.
    func testThePurgeEmptiesTheCacheAndTakesOnlyTheAPIsCookies() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrideAppTests-url-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A memory tier as well: on the simulator a response stored in a disk-only cache was not
        // readable back within seconds, and the test needs it there before the purge.
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 5_000_000, directory: directory)
        let verify = URLRequest(url: URL(string: "https://\(LoginLink.host)/v1/auth/verify")!)
        let answer = HTTPURLResponse(url: verify.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": "application/json", "Cache-Control": "max-age=600"])!
        cache.storeCachedResponse(CachedURLResponse(response: answer, data: Data(#"{"sessionToken":"tok-123"}"#.utf8)), for: verify)
        try await waitUntil("the answer is cached") { cache.cachedResponse(for: verify) != nil }

        let cookies = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage, "an in-memory store")
        cookies.cookieAcceptPolicy = .always
        func cookie(_ domain: String, _ name: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v",
                                    .expires: Date().addingTimeInterval(3_600)])!
        }
        for c in [cookie(LoginLink.host, "stride_session"), cookie(".colorarchive.me", "wide"),
                  cookie("localhost", "stride_session"), cookie("example.com", "other"),
                  cookie("stride.colorarchive.me", "sibling")] {
            cookies.setCookie(c)
        }
        XCTAssertEqual(cookies.cookies?.count, 5, "precondition")

        APIClient.purgeStoredHTTPState(cache: cache, cookies: cookies, hosts: [LoginLink.host, "localhost"])

        try await waitUntil("the cache is empty") { cache.cachedResponse(for: verify) == nil }
        XCTAssertEqual(Set(cookies.cookies?.map { "\($0.domain) \($0.name)" } ?? []),
                       ["example.com other", "stride.colorarchive.me sibling"],
                       "a sibling host's host-only cookie never went to the API")
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - X-Stride-Client

    /// The header decides which contract the server speaks to this app (server/lib/clientVersion.js).
    /// Its regex, verbatim: a value it rejects makes the server treat this build as <= 1.2.3.
    private static let serverClientRegex = #"^(ios|macos)/(\d{1,4})\.(\d{1,4})(?:\.(\d{1,4}))?\((\d{1,9})\)$"#

    func testEveryRequestSendsTheClientHeaderTheServerParses() async throws {
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.emptyPull))
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        server.on("POST", "/v1/auth/request-link", respond: .ok(#"{"ok":true}"#))

        _ = await api.syncPull(since: nil, token: "tok-123")
        _ = await api.syncPush(body: Data("{}".utf8), token: "tok-123")
        tokens.delete()
        try await api.requestMagicLink(email: "a@example.com")   // unauthenticated requests too

        let info = Bundle.main.infoDictionary ?? [:]
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        let expected = "ios/\(version)(\(build))"
        XCTAssertNotNil(expected.range(of: Self.serverClientRegex, options: .regularExpression),
                        "\(expected) would not parse on the server — check the host app's versions")

        let requests = server.requests
        guard requests.count == 3 else { return XCTFail("expected 3 requests, got \(requests.count)") }
        for request in requests {
            XCTAssertEqual(request.header("X-Stride-Client"), expected, request.path)
        }
    }

    /// Values the server's regex would reject are not sent at all, rather than sent and silently
    /// read as a legacy client.
    func testClientHeaderFormatMatchesTheServerRegex() {
        let accepted = [
            APIClient.clientHeader(platform: "ios", version: "1.3.0", build: "18"),
            APIClient.clientHeader(platform: "macos", version: "1.3", build: "18"),
        ]
        XCTAssertEqual(accepted, ["ios/1.3.0(18)", "macos/1.3(18)"])
        for value in accepted.compactMap({ $0 }) {
            XCTAssertNotNil(value.range(of: Self.serverClientRegex, options: .regularExpression), value)
        }
        let rejected: [(String?, String?)] = [
            (nil, "18"), ("1.3.0", nil), ("1", "18"), ("1.3.0.1", "18"), ("1.3.0-beta", "18"),
            ("1..0", "18"), ("12345.0", "18"), ("1.3.0", "1.0"), ("1.3.0", "1234567890"), ("1.3.0", ""), ("", "18"),
        ]
        for (version, build) in rejected {
            XCTAssertNil(APIClient.clientHeader(platform: "ios", version: version, build: build),
                         "\(version ?? "nil") (\(build ?? "nil"))")
        }
    }

    func testRequestsCarryTheStoredTokenAsBearerAndNoneWithoutOne() async throws {
        server.on("GET", "/v1/auth/session", respond: .ok(#"{"user":null}"#))
        server.on("POST", "/v1/auth/request-link", respond: .ok(#"{"ok":true}"#))

        _ = try await api.getSession()
        tokens.delete()
        try await api.requestMagicLink(email: "a@example.com")

        let requests = server.requests
        // Guarded, not just asserted: an out-of-range index crashes the HOST app, not the test.
        guard requests.count == 2 else { return XCTFail("expected 2 requests, got \(requests.count)") }
        XCTAssertEqual(requests[0].authorization, "Bearer tok-123")
        XCTAssertNil(requests[1].authorization, "no token, no header — not \"Bearer \" or a stale value")
    }

    // MARK: - The sync transport (SyncEngine's requests)

    /// Every request of a sync run carries the token the run captured, never the keychain's
    /// current one: a run that started under account A must not send a later chunk on B's
    /// session after a switch mid-run (DEV-PLAN-1.3.md M2, review 2).
    func testSyncRequestsCarryTheRunsTokenNotTheStoredOne() async throws {
        server.on("GET", "/v1/sync/pull", respond: .ok(Self.emptyPull))
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        tokens.save("tok-now-stored")

        _ = await api.syncPull(since: "2026-09-26T09:59:00.000Z", token: "tok-of-the-run")
        _ = await api.syncPush(body: Data("{}".utf8), token: "tok-of-the-run")

        let requests = server.requests
        guard requests.count == 2 else { return XCTFail("expected 2 requests, got \(requests.count)") }
        XCTAssertEqual(requests.map(\.authorization), ["Bearer tok-of-the-run", "Bearer tok-of-the-run"])
        XCTAssertEqual(requests[0].query["since"], "2026-09-26T09:59:00.000Z", "a query item, not a path component")
    }

    /// The push sends exactly the bytes it is given — the planner measured the 1 MB bound on
    /// them (`SyncPushChunk.body`) — and those bytes are the camelCase the server reads
    /// (`e.habitId`, `req.body.deletedHabitIds`). A snake_case encoder shipped once and silently
    /// dropped every entry and every deletion (3829085).
    func testSyncPushSendsTheChunkBytesVerbatim() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(#"{"ok":true}"#))
        let payload = SyncPushPayload(
            habits: [],
            entries: [SyncEntry(id: "e-1", habitId: "h-1", date: "2026-09-26", note: nil, value: 1,
                                createdAt: "2026-09-26T00:00:00.000Z", updatedAt: "2026-09-26T00:00:00.000Z")],
            groups: [],
            deletedHabitIds: ["h-gone"], deletedEntryIds: [], deletedGroupIds: []
        )
        let body = try SyncPushPlanner.makeEncoder().encode(payload)

        let exchange = await api.syncPush(body: body, token: "tok-123")

        XCTAssertEqual(exchange.response.status, 200)
        XCTAssertEqual(server.requests.first?.body, body)
        XCTAssertEqual(server.requests.first?.header("Content-Type"), "application/json")
        let json = try XCTUnwrap(server.requests.first?.json)
        XCTAssertEqual(json["deletedHabitIds"] as? [String], ["h-gone"])
        XCTAssertNil(json["deleted_habit_ids"])
        let entry = try XCTUnwrap((json["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["habitId"] as? String, "h-1")
        XCTAssertNil(entry["habit_id"])
    }

    /// The engine decides from the status, the code, the limits and `Retry-After`, so the sync
    /// requests never throw and hand all of it back. A 401 does NOT delete the stored token here
    /// (the engine's `needsReauth` resets nothing), unlike every other request.
    func testSyncAnswersComeBackWholeAndA401KeepsTheToken() async throws {
        server.on("POST", "/v1/sync/push", respond: .init(
            status: 400, body: #"{"error":"too_many_rows","code":"too_many_rows","limits":{"habits":500,"entries":2000,"groups":200}}"#))
        server.on("GET", "/v1/sync/pull", respond: .init(
            status: 503, body: #"{"error":"sync_paused","code":"sync_paused"}"#, headers: ["Retry-After": "120"]))

        let push = await api.syncPush(body: Data("{}".utf8), token: "tok-123")
        let pull = await api.syncPull(since: nil, token: "tok-123")

        XCTAssertNil(push.failure)
        XCTAssertEqual(push.response.status, 400)
        let pushAnswer = SyncHTTPAnswer.decode(status: 400, body: push.response.body, retryAfterHeader: push.response.retryAfter)
        XCTAssertEqual(pushAnswer.code, "too_many_rows")
        XCTAssertEqual(pushAnswer.limits, SyncRowLimits(habits: 500, entries: 2000, groups: 200))
        XCTAssertEqual(pull.response.status, 503)
        XCTAssertEqual(pull.response.retryAfter, "120")

        server.on("GET", "/v1/sync/pull", respond: .init(status: 401, body: #"{"error":"Unauthorized"}"#))
        let unauthorized = await api.syncPull(since: nil, token: "tok-123")
        XCTAssertEqual(unauthorized.response.status, 401)
        XCTAssertEqual(tokens.read(), "tok-123")
    }

    /// No answer at all (offline, a timeout): status nil, and the system's description kept for
    /// the Settings footer.
    func testSyncRequestWithNoAnswerHasNoStatus() async {
        server.on("GET", "/v1/sync/pull") { _ in throw URLError(.notConnectedToInternet) }

        let exchange = await api.syncPull(since: nil, token: "tok-123")

        XCTAssertNil(exchange.response.status)
        guard case .transport(let description)? = exchange.failure else { return XCTFail("\(String(describing: exchange.failure))") }
        XCTAssertFalse(description.isEmpty)
    }

    /// M0's push answer (`applied`, `skipped`, `skippedReasons`) and the bare `{ok:true}` both
    /// arrive intact for the engine's decoder (`SyncPushResponse`, Shared/), and so does a pull
    /// carrying `totals` and millisecond stamps.
    func testSyncBodiesDecodeWithTheEnginesModels() async throws {
        server.on("POST", "/v1/sync/push", respond: .ok(#"""
        {"ok":true,"applied":{"habits":1,"entries":0,"groups":0},
         "skipped":{"habits":[],"entries":["3f2b8c1e-0000-4000-8000-000000000001"],"groups":[]},
         "skippedReasons":{"habits":{},"entries":{"3f2b8c1e-0000-4000-8000-000000000001":"unknown_habit"},"groups":{}}}
        """#))
        server.on("GET", "/v1/sync/pull", respond: .ok(#"""
        {"habits":[{"id":"h-1","name":"Read","emoji":"📚","colorHex":"#34C759","isArchived":false,
                    "sortOrder":0,"reminderEnabled":false,"reminderHour":20,"reminderMinute":0,
                    "note":null,"kind":"binary","targetValue":null,"unit":null,"scheduleKind":"daily",
                    "timesPerWeek":null,"activeDaysMask":null,"groupId":null,
                    "createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-02T00:00:00.700Z"}],
         "entries":[],"groups":[],"deletedHabitIds":[],"deletedEntryIds":[],"deletedGroupIds":[],
         "serverTime":"2026-09-26T10:00:00.123Z","totals":{"habits":1,"entries":0,"groups":0}}
        """#))

        let push = await api.syncPush(body: Data("{}".utf8), token: "tok-123")
        let pushed = try JSONDecoder().decode(SyncPushResponse.self, from: push.response.body)
        XCTAssertEqual(pushed.skippedReasons?.entries["3f2b8c1e-0000-4000-8000-000000000001"], "unknown_habit")

        let pull = await api.syncPull(since: nil, token: "tok-123")
        let pulled = try JSONDecoder().decode(SyncPullResponse.self, from: pull.response.body)
        XCTAssertEqual(pulled.habits.map(\.updatedAt), ["2026-09-02T00:00:00.700Z"])
        XCTAssertEqual(pulled.totals, SyncTotals(habits: 1, entries: 0, groups: 0))
        XCTAssertEqual(pulled.serverTime, "2026-09-26T10:00:00.123Z")
    }
}
