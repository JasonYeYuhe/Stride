import Foundation
@testable import Stride

/// A fake Stride server behind a real URLSession, so tests exercise APIClient's actual request
/// building, status handling and JSON decoding — only the socket is replaced.
///
/// Each instance answers for its own random `.invalid` host and registers itself under it, so
/// servers from different tests cannot answer each other's requests, and nothing the host app
/// itself sends (its launch sync, the session check) is ever intercepted: only sessions built
/// by `makeClient` carry the protocol class at all.
final class StubServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let authorization: String?
        /// Every header as the app set it; look up with `header(_:)`.
        let headers: [String: String]
        let body: Data?

        /// Header names are case-insensitive on the wire; so is this lookup.
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The body as a JSON object, for asserting on wire keys.
        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    struct Response {
        var status: Int
        var body: String
        /// Beside `Content-Type: application/json` — e.g. `Retry-After`, which the sync engine
        /// reads when the body carries no `retryAfterSeconds`.
        var headers: [String: String] = [:]

        static func ok(_ json: String) -> Response { Response(status: 200, body: json) }
    }

    /// Runs on URLSession's loading thread. Return a response, or throw a URLError to fail the
    /// request at the transport (offline, timeout).
    typealias Handler = @Sendable (Request) throws -> Response

    let host = "\(UUID().uuidString.lowercased()).stride-tests.invalid"
    var baseURL: URL { URL(string: "https://\(host)")! }

    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var recorded: [Request] = []

    init() { StubURLProtocol.register(self) }

    /// Call from tearDown.
    func stop() { StubURLProtocol.unregister(self) }

    /// Every request received so far, in arrival order.
    var requests: [Request] { lock.withLock { recorded } }
    var paths: [String] { requests.map(\.path) }

    func on(_ method: String, _ path: String, _ handler: @escaping Handler) {
        lock.withLock { routes["\(method) \(path)"] = handler }
    }

    func on(_ method: String, _ path: String, respond response: Response) {
        on(method, path) { _ in response }
    }

    /// An APIClient that talks only to this server and keeps its token in `tokenStore`.
    func makeClient(tokenStore: SessionTokenStore) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: baseURL, session: URLSession(configuration: config), tokenStore: tokenStore)
    }

    fileprivate func handle(_ urlRequest: URLRequest) throws -> Response {
        let url = urlRequest.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let request = Request(
            method: urlRequest.httpMethod ?? "GET",
            path: url.path,
            query: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }),
            authorization: urlRequest.value(forHTTPHeaderField: "Authorization"),
            headers: urlRequest.allHTTPHeaderFields ?? [:],
            body: Self.body(of: urlRequest)
        )
        let handler: Handler? = lock.withLock {
            recorded.append(request)
            return routes["\(request.method) \(request.path)"]
        }
        guard let handler else {
            return Response(status: 404, body: #"{"error":"no stub for \#(request.method) \#(request.path)"}"#)
        }
        return try handler(request)
    }

    /// URLSession moves `httpBody` into `httpBodyStream` before a URLProtocol sees the request.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Routes a request to the StubServer registered for its host.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }
    static func unregister(_ server: StubServer) { lock.withLock { _ = servers.removeValue(forKey: server.host) } }
    private static func server(for host: String?) -> StubServer? {
        guard let host else { return nil }
        return lock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request.url?.host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let response = try server.handle(request)
            let http = HTTPURLResponse(
                url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(response.headers) { _, set in set }
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// The token store tests hand to both APIClient and AuthService — never the real Keychain item,
/// which belongs to the host app (see `SessionTokenStore`).
final class InMemoryTokenStore: SessionTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ token: String? = nil) { self.token = token }

    func read() -> String? { lock.withLock { token } }
    func save(_ token: String) { lock.withLock { self.token = token } }
    func delete() { lock.withLock { token = nil } }
}

/// A UserDefaults suite of its own, so a test never reads or writes the host app's defaults (the
/// sync cursor, the deletion queues, the reminder settings). Emptied when created and again by
/// `remove()`, so every test starts from nothing even after a crashed run.
///
/// One FIXED suite per role, not one per test. `removePersistentDomain` empties a domain but
/// leaves its `<suite>.plist` behind in the host app's Library/Preferences, so UUID-named suites
/// piled up in Stride's container on the shared "iPhone 17 Pro" simulator — 77 empty files after
/// one afternoon of runs (2026-09-27), more with every ship.sh. Fixed names leave at most one file
/// per role. Safe because the hosted tests run serially (the scheme sets parallelizable = NO).
struct ScratchDefaults {
    let name: String
    let defaults: UserDefaults

    /// `role` names the suite ("sync.local", "sync.appGroup", "notifications"); two
    /// ScratchDefaults alive in one test need different roles.
    init(_ role: String) {
        name = "StrideAppTests.\(role)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func remove() { defaults.removePersistentDomain(forName: name) }
}
