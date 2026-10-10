import Foundation

/// Lightweight HTTP client for the Stride backend API.
actor APIClient {
    static let shared = APIClient()

    #if DEBUG
    static let defaultBaseURL = URL(string: "http://localhost:3002")!
    #else
    static let defaultBaseURL = URL(string: "https://stride-api.colorarchive.me")!
    #endif

    private let baseURL: URL
    /// Not private: APIClientTests checks that `shared` goes through `defaultSession`.
    nonisolated let session: URLSession
    private let tokenStore: SessionTokenStore

    /// The defaults are what `shared` uses. StrideAppTests passes a URLSession whose URLProtocol
    /// answers instead of a server, and an in-memory token store (see `SessionTokenStore` for why
    /// never the real Keychain item).
    init(
        baseURL: URL = APIClient.defaultBaseURL,
        session: URLSession = APIClient.defaultSession,
        tokenStore: SessionTokenStore = KeychainSessionTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
    }

    // MARK: - Nothing on disk but the Keychain item

    /// The session `shared` talks through: no URL cache, no cookies (E2E S9).
    ///
    /// Until 1.3.1 it was `URLSession.shared`, whose disk cache (Library/Caches/<bundle>/Cache.db)
    /// kept the /v1/auth/verify answer — the live session token, in plain text — every session
    /// check's answer and every pull's habits, and whose cookie store kept the `stride_session`
    /// cookie the verify answer sets for the web login and sent it back on every request. The
    /// token belongs in the Keychain only (`KeychainSessionTokenStore`), and this app
    /// authenticates with the Bearer header alone: the server reads the header first on every
    /// route, and the app sends no request that needs the cookie (a stored token is the only way
    /// it is signed in). Ephemeral, so no credential store is written either.
    static let defaultSession = URLSession(configuration: sessionConfiguration())

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    /// The hosts earlier builds may have left answers and cookies for: this build's API, and the
    /// production API (a Debug build installed over a store build talks to localhost).
    static let apiHosts: Set<String> = Set([defaultBaseURL.host, LoginLink.host].compactMap { $0 })

    /// What earlier builds left through `URLSession.shared` (E2E S9): every cached answer, and the
    /// API's cookies. Run at every launch (StrideApp), off the main thread — cheap once there is
    /// nothing left, and it also clears what a reinstalled older build wrote since. Nothing else
    /// in the app uses the shared URL cache or cookie store (no web view, no other URLSession;
    /// Sentry sends through its own), so all of the cache goes; other hosts' cookies are left.
    /// CFNetwork vacuums Cache.db as it removes the rows, so the token's bytes do not stay behind
    /// in free pages.
    static func purgeStoredHTTPState(cache: URLCache = .shared, cookies: HTTPCookieStorage = .shared,
                                     hosts: Set<String> = apiHosts) {
        cache.removeAllCachedResponses()
        for cookie in cookies.cookies ?? [] where hosts.contains(where: { cookie.isSent(to: $0) }) {
            cookies.deleteCookie(cookie)
        }
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Do NOT set .convertToSnakeCase here. The backend speaks camelCase in
        // BOTH directions (server/routes/sync.js reads `e.habitId`,
        // `req.body.deletedHabitIds`, ... and its /sync/pull response emits
        // `colorHex`/`habitId`). Encoding snake_case silently broke every push:
        // entries were dropped by the `!e.habitId` guard, habit fields fell back
        // to server defaults, and deletions never propagated. Shipped broken
        // from 3829085 until now. Covered by StrideTests/SyncWireFormatTests.
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private var sessionToken: String? {
        get { tokenStore.read() }
        set {
            if let newValue {
                tokenStore.save(newValue)
            } else {
                tokenStore.delete()
            }
        }
    }

    var isLoggedIn: Bool { sessionToken != nil }

    // MARK: - Auth

    func requestMagicLink(email: String) async throws {
        let _: OKResponse = try await post("/v1/auth/request-link", body: ["email": email])
    }

    func verifyToken(_ token: String) async throws -> AuthResponse {
        let response: AuthResponse = try await post("/v1/auth/verify", body: ["token": token])
        sessionToken = response.sessionToken
        return response
    }

    func getSession() async throws -> SessionResponse {
        try await get("/v1/auth/session")
    }

    func logout() async throws {
        let _: OKResponse = try await post("/v1/auth/logout", body: EmptyBody())
        sessionToken = nil
    }

    func deleteAccount() async throws {
        let _: OKResponse = try await post("/v1/auth/delete-account", body: EmptyBody())
        sessionToken = nil
    }

    // MARK: - Sync (the transport of Shared/SyncEngine.swift)

    /// One sync request's answer, whatever it was. The engine decides from the status, the
    /// server's code and `Retry-After` (DEV-PLAN-1.3.md M2, "One rule per push answer"), so
    /// these requests never throw and never read the body into a type: until 1.3.0,
    /// `pushChanges` decoded `{ok}` and threw on any non-2xx, which lost exactly the status,
    /// code, limits and `Retry-After` the per-answer rules need.
    struct SyncExchange: Sendable {
        enum Failure: Sendable, Equatable {
            /// Not an HTTP response at all.
            case invalidResponse
            /// No answer: offline, a timeout, DNS, TLS. The system's description, for the
            /// Settings footer, as 1.3.0 showed it.
            case transport(String)
        }

        var response: SyncTransportResponse
        var failure: Failure?
    }

    /// POST /v1/sync/push with exactly `body` and the run's `token`.
    ///
    /// `body` is `SyncPushChunk.body`, the bytes the planner measured against the 1 MB bound, so
    /// it is sent as it is and never re-encoded here. `token` is the one the sync run captured
    /// when it started, never the keychain's current one: a later chunk of a run that started
    /// under account A must not go out on B's session after a switch mid-run (review 2 — until
    /// 1.3.0 every request read the keychain).
    func syncPush(body: Data, token: String) async -> SyncExchange {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/sync/push"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        addHeaders(&request, token: token)
        return await exchange(request)
    }

    /// GET /v1/sync/pull, `?since=` when `since` is non-nil, with the run's `token`; and
    /// `deletionsSince=` when that is (a full pull verifying migrated marks, SyncMarksProof).
    func syncPull(since: String?, deletionsSince: String? = nil, token: String) async -> SyncExchange {
        let query = [since.map { URLQueryItem(name: "since", value: $0) },
                     deletionsSince.map { URLQueryItem(name: "deletionsSince", value: $0) }].compactMap { $0 }
        var request = URLRequest(url: url("/v1/sync/pull", query: query))
        request.httpMethod = "GET"
        addHeaders(&request, token: token)
        return await exchange(request)
    }

    /// A 401 here does NOT delete the stored token, unlike `perform`: the engine answers it as
    /// `needsReauth` and "no state is reset" (M2). The token it carried may not even be the
    /// stored one any more (the run's captured token), so deleting the stored one could sign
    /// out a session that was never refused.
    private func exchange(_ request: URLRequest) async -> SyncExchange {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return SyncExchange(response: .noAnswer, failure: .invalidResponse)
            }
            return SyncExchange(response: SyncTransportResponse(
                status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        } catch {
            return SyncExchange(response: .noAnswer, failure: .transport(error.localizedDescription))
        }
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "GET"
        addHeaders(&request, token: sessionToken)
        return try await perform(request)
    }

    /// A query string must not go through appendingPathComponent — it percent-encodes '?' into
    /// %3F, so every incremental pull 404'd and sync became push-only after the first run.
    private func url(_ path: String, query: [URLQueryItem]?) -> URL {
        var url = baseURL.appendingPathComponent(path)
        if let query, !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            if let built = components?.url { url = built }
        }
        return url
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        addHeaders(&request, token: sessionToken)
        return try await perform(request)
    }

    /// Every request goes through `get`, `post` or the two sync requests, and all come here — so
    /// the client header is on every request, the auth routes included, without a list of call
    /// sites to keep. `token` is the stored session for `get` / `post`, and the sync run's
    /// captured token for the sync requests.
    private func addHeaders(_ request: inout URLRequest, token: String?) {
        if let clientHeader = Self.clientHeader {
            request.setValue(clientHeader, forHTTPHeaderField: Self.clientHeaderName)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - Client version header

    static let clientHeaderName = "X-Stride-Client"

    /// `ios/1.3.0(18)` / `macos/1.3.0(18)`, from this build's Info.plist; nil when the bundle's
    /// versions would not parse (see `clientHeader(platform:version:build:)`).
    static let clientHeader: String? = {
        #if os(macOS)
        let platform = "macos"
        #else
        // The iPhone app running on an Apple-silicon Mac is still this binary, and still speaks
        // this client's contract, so it reports as ios.
        let platform = "ios"
        #endif
        let info = Bundle.main.infoDictionary
        return clientHeader(platform: platform,
                            version: info?["CFBundleShortVersionString"] as? String,
                            build: info?["CFBundleVersion"] as? String)
    }()

    /// The header value, or nil when it would not match server/lib/clientVersion.js
    /// `CLIENT_HEADER` — `^(ios|macos)/(\d{1,4})\.(\d{1,4})(?:\.(\d{1,4}))?\((\d{1,9})\)$`.
    ///
    /// The server decides by this header which contract a client speaks. With it, error bodies
    /// put the machine code in `error` and the sentence in `message` (so `perform` must read
    /// `message` first); from 1.3.1 on it also unlocks `cursor_expired`, row caps and
    /// `snapshot_required`. A value it cannot parse makes it treat the app as a <= 1.2.3 client,
    /// silently. Sending nothing in that case says the same thing honestly, and keeps a stray
    /// build number out of the per-build usage counters that decide when the legacy paths go.
    static func clientHeader(platform: String, version: String?, build: String?) -> String? {
        guard let version, let build else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ Self.isDigits($0, maxLength: 4) }),
              Self.isDigits(Substring(build), maxLength: 9)
        else { return nil }
        return "\(platform)/\(version)(\(build))"
    }

    private static func isDigits(_ s: Substring, maxLength: Int) -> Bool {
        (1...maxLength).contains(s.count) && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 {
            sessionToken = nil
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            // Because this client sends X-Stride-Client, errors from 1.3 on arrive as
            // `{error: code, code, message}` — `error` is the machine code — while the older
            // routes still send `{error: sentence}`. `message ?? error` is the sentence in both;
            // showing `error` blindly put "rate_limited" in the Settings footer
            // (server/lib/clientVersion.js `errorBody`). A body that is not JSON at all (nginx's
            // 502 page during a deploy) has neither.
            throw Self.serverError(status: http.statusCode, body: data)
        }
        return try decoder.decode(T.self, from: data)
    }

    /// A non-2xx answer as `APIError.server`: the machine code, and `message ?? error` as the
    /// sentence (see `perform`). Also how SyncService words a sync the engine stopped, so the
    /// Settings footer reads the same whichever path failed.
    static func serverError(status: Int, body: Data) -> APIError {
        let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: body)
        return .server(statusCode: status, code: parsed?.code, message: parsed?.message ?? parsed?.error)
    }
}

// MARK: - Models

struct OKResponse: Decodable {
    let ok: Bool
}

/// `{error, code?, message?}`, every key optional: one missing key must not turn a readable
/// error into "Request failed".
struct ErrorResponse: Decodable {
    let error: String?
    let code: String?
    let message: String?
}

struct AuthResponse: Decodable {
    let ok: Bool
    let user: APIUser
    let sessionToken: String
}

struct SessionResponse: Decodable {
    let user: APIUser?
}

struct APIUser: Decodable {
    let id: Int
    let email: String
    let tier: String?
    let createdAt: String
}

struct EmptyBody: Encodable {}

enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    /// `code` is the server's machine-readable code (`sync_paused`, `rate_limited`, …), nil from
    /// routes that predate codes; behaviour matches on it, never on the text. `message` is the
    /// server's sentence (`message ?? error`), nil when the body carried none.
    case server(statusCode: Int, code: String?, message: String?)

    /// English, and the server's own sentence for `.server` — never a code. What the UI shows
    /// goes through `displayMessage(for:)`, which also follows the in-app language.
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Please log in again"
        case .server(_, _, let message): return message ?? "Request failed"
        }
    }

    /// The text for an error shown on screen (the Settings sync footer, the login sheet).
    ///
    /// Codes this build knows get a sentence of its own in the picked language; the server's
    /// sentences are English only. Any other server error shows the server's sentence — which
    /// is never the code, see `perform` — and anything else (offline, a timeout) the system's
    /// description. `appLocalized` because the picker does not reach `String(localized:)`
    /// (LanguageManager.swift), hence main-actor.
    @MainActor
    static func displayMessage(for error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        switch apiError {
        case .invalidResponse:
            return appLocalized("Invalid server response")
        case .unauthorized:
            return appLocalized("Please log in again")
        case .server(_, let code, let message):
            switch code {
            case "sync_paused":
                return appLocalized("Sync is paused for maintenance. Your data is safe on this device and will sync when the pause ends.")
            case "rate_limited":
                return appLocalized("Too many sync requests. Please try again in a few minutes.")
            default:
                return message ?? appLocalized("Request failed")
            }
        }
    }
}

// Sync request/response models live in Shared/SyncModels.swift so the reconciliation
// logic that consumes them (Shared/SyncReconciler.swift) is visible to StrideTests.

private extension HTTPCookie {
    /// Whether a request to `host` would carry this cookie (RFC 6265's domain match): a host-only
    /// cookie (`stride-api.colorarchive.me`, what the server's verify answer sets) goes to that
    /// host alone, a domain cookie (`.colorarchive.me`) to the domain and every host under it.
    func isSent(to host: String) -> Bool {
        let host = host.lowercased(), domain = domain.lowercased()
        guard domain.hasPrefix(".") else { return host == domain }
        return host == String(domain.dropFirst()) || host.hasSuffix(domain)
    }
}

