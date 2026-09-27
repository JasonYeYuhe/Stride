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
        addAuth(&request)
        return try await perform(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        addAuth(&request)
        return try await perform(request)
    }

    private func addAuth(_ request: inout URLRequest) {
        if let token = sessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            let message = (try? decoder.decode(ErrorResponse.self, from: data))?.error ?? "Request failed"
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Models

struct OKResponse: Decodable {
    let ok: Bool
}

struct ErrorResponse: Decodable {
    let error: String
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
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Please log in again"
        case .server(_, let message): return message
        }
    }
}

// Sync request/response models live in Shared/SyncModels.swift so the reconciliation
// logic that consumes them (Shared/SyncReconciler.swift) is visible to StrideTests.

