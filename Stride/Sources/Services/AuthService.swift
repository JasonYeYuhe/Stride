import Foundation
import SwiftUI

/// Manages user authentication state across the app.
@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()

    private(set) var currentUser: APIUser?
    private(set) var isLoading = false
    private(set) var error: String?

    /// True once the initial session check from Keychain has completed (success or failure).
    private(set) var isSessionRestored = false

    var isLoggedIn: Bool { currentUser != nil }
    var userEmail: String? { currentUser?.email }

    private let api: APIClient
    private let tokenStore: SessionTokenStore
    /// A closure rather than a SyncService so that creating `shared` still does not create
    /// `SyncService.shared` as a side effect; it is reached only on logout, as before.
    private let resetSyncState: @MainActor () -> Void

    /// The defaults are what `shared` has always used. StrideAppTests passes an APIClient over a
    /// stubbed URLSession and the same in-memory token store it gave that client — the two must
    /// share one store, exactly as both share the Keychain item in the app.
    init(
        api: APIClient = .shared,
        tokenStore: SessionTokenStore = KeychainSessionTokenStore(),
        resetSyncState: @escaping @MainActor () -> Void = { SyncService.shared.resetSyncState() }
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.resetSyncState = resetSyncState
        // Check session on init if we have a stored token
        if tokenStore.read() != nil {
            Task { await checkSession() }
        } else {
            isSessionRestored = true
        }
    }

    /// Wait until the initial session restoration has completed (up to 10 seconds).
    /// Call this before checking `isLoggedIn` on cold start to avoid races.
    func waitForSessionRestore() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !isSessionRestored && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // If we timed out, mark as restored so the app can proceed
        if !isSessionRestored {
            isSessionRestored = true
        }
    }

    func checkSession() async {
        isLoading = true
        error = nil
        do {
            let response = try await api.getSession()
            currentUser = response.user
        } catch {
            currentUser = nil
        }
        isLoading = false
        isSessionRestored = true
    }

    func requestMagicLink(email: String) async -> Bool {
        isLoading = true
        error = nil
        do {
            try await api.requestMagicLink(email: email)
            isLoading = false
            return true
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return false
        }
    }

    func verifyToken(_ token: String) async -> Bool {
        isLoading = true
        error = nil
        do {
            let response = try await api.verifyToken(token)
            currentUser = response.user
            isLoading = false
            return true
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return false
        }
    }

    /// Called from deep link handler when web login page redirects back with session token
    func loginWithSessionToken(_ token: String) {
        // Basic format validation: must be non-empty alphanumeric/hex token
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 512,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return }

        tokenStore.save(trimmed)
        Task {
            await checkSession()
            // Clear invalid token if session check failed
            if currentUser == nil {
                tokenStore.delete()
            }
        }
    }

    func logout() async {
        do {
            try await api.logout()
        } catch {
            // Clear locally even if server call fails
        }
        currentUser = nil
        tokenStore.delete()
        resetSyncState()
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        currentUser = nil
        tokenStore.delete()
        resetSyncState()
    }
}
