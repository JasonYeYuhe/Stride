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

    var isLoggedIn: Bool { currentUser != nil }
    var userEmail: String? { currentUser?.email }

    init() {
        // Check session on init if we have a stored token
        if KeychainHelper.read(key: "stride_session_token") != nil {
            Task { await checkSession() }
        }
    }

    func checkSession() async {
        isLoading = true
        error = nil
        do {
            let response = try await APIClient.shared.getSession()
            currentUser = response.user
        } catch {
            currentUser = nil
        }
        isLoading = false
    }

    func requestMagicLink(email: String) async -> Bool {
        isLoading = true
        error = nil
        do {
            try await APIClient.shared.requestMagicLink(email: email)
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
            let response = try await APIClient.shared.verifyToken(token)
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

        KeychainHelper.save(key: "stride_session_token", value: trimmed)
        Task {
            await checkSession()
            // Clear invalid token if session check failed
            if currentUser == nil {
                KeychainHelper.delete(key: "stride_session_token")
            }
        }
    }

    func logout() async {
        do {
            try await APIClient.shared.logout()
        } catch {
            // Clear locally even if server call fails
        }
        currentUser = nil
        KeychainHelper.delete(key: "stride_session_token")
    }

    func deleteAccount() async throws {
        try await APIClient.shared.deleteAccount()
        currentUser = nil
        KeychainHelper.delete(key: "stride_session_token")
    }
}
