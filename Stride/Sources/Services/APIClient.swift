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
    private let session: URLSession
    private let tokenStore: SessionTokenStore

    /// The defaults are what `shared` has always used. StrideAppTests passes a URLSession whose
    /// URLProtocol answers instead of a server, and an in-memory token store (see
    /// `SessionTokenStore` for why never the real Keychain item).
    init(
        baseURL: URL = APIClient.defaultBaseURL,
        session: URLSession = .shared,
        tokenStore: SessionTokenStore = KeychainSessionTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
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

    // MARK: - Sync

    func pushChanges(_ payload: SyncPushPayload) async throws {
        let _: OKResponse = try await post("/v1/sync/push", body: payload)
    }

    func pullChanges(since: String? = nil) async throws -> SyncPullResponse {
        // A query string must not go through appendingPathComponent — it
        // percent-encodes '?' into %3F, so every incremental pull 404'd and
        // sync became push-only after the first run.
        try await get("/v1/sync/pull", query: since.map { [URLQueryItem(name: "since", value: $0)] })
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        var url = baseURL.appendingPathComponent(path)
        if let query, !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
            if let built = components?.url { url = built }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addHeaders(&request)
        return try await perform(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        addHeaders(&request)
        return try await perform(request)
    }

    /// Every request goes through `get` or `post`, and both come here — so the client header
    /// is on every request, the auth routes included, without a list of call sites to keep.
    private func addHeaders(_ request: inout URLRequest) {
        if let clientHeader = Self.clientHeader {
            request.setValue(clientHeader, forHTTPHeaderField: Self.clientHeaderName)
        }
        if let token = sessionToken {
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
            let body = try? decoder.decode(ErrorResponse.self, from: data)
            throw APIError.server(statusCode: http.statusCode, code: body?.code,
                                  message: body?.message ?? body?.error)
        }
        return try decoder.decode(T.self, from: data)
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

