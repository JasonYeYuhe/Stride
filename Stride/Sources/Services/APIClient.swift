import Foundation

/// Lightweight HTTP client for the Stride backend API.
actor APIClient {
    static let shared = APIClient()

    #if DEBUG
    private let baseURL = URL(string: "http://localhost:3002")!
    #else
    private let baseURL = URL(string: "https://stride-api.colorarchive.me")!
    #endif

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private var sessionToken: String? {
        get { KeychainHelper.read(key: "stride_session_token") }
        set {
            if let newValue {
                KeychainHelper.save(key: "stride_session_token", value: newValue)
            } else {
                KeychainHelper.delete(key: "stride_session_token")
            }
        }
    }

    var isLoggedIn: Bool { sessionToken != nil }

    // MARK: - Auth

    func requestMagicLink(email: String) async throws {
        let _: OKResponse = try await post("/auth/request-link", body: ["email": email])
    }

    func verifyToken(_ token: String) async throws -> AuthResponse {
        let response: AuthResponse = try await post("/auth/verify", body: ["token": token])
        sessionToken = response.sessionToken
        return response
    }

    func getSession() async throws -> SessionResponse {
        try await get("/auth/session")
    }

    func logout() async throws {
        let _: OKResponse = try await post("/auth/logout", body: EmptyBody())
        sessionToken = nil
    }

    // MARK: - Sync

    func pushChanges(_ payload: SyncPushPayload) async throws {
        let _: OKResponse = try await post("/sync/push", body: payload)
    }

    func pullChanges(since: String? = nil) async throws -> SyncPullResponse {
        var path = "/sync/pull"
        if let since { path += "?since=\(since)" }
        return try await get(path)
    }

    // MARK: - HTTP Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
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
        let (data, response) = try await URLSession.shared.data(for: request)
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

// MARK: - Sync Models

struct SyncPushPayload: Encodable {
    let habits: [SyncHabit]
    let entries: [SyncEntry]
    let deletedHabitIds: [String]
    let deletedEntryIds: [String]
}

struct SyncHabit: Codable {
    let id: String
    let name: String
    let emoji: String
    let colorHex: String
    let isArchived: Bool
    let sortOrder: Int
    let createdAt: String
    let updatedAt: String
}

struct SyncEntry: Codable {
    let id: String
    let habitId: String
    let date: String
    let createdAt: String
}

struct SyncPullResponse: Decodable {
    let habits: [SyncHabit]
    let entries: [SyncEntry]
    let serverTime: String
}
