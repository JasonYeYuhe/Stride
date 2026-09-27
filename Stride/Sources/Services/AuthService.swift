import Foundation
import SwiftUI
import os.log

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

    /// A session token is in the Keychain, whether or not its user is loaded. The two differ
    /// after a launch whose session check failed (offline, a timeout): `currentUser` is nil,
    /// the token and the sync cursor are still there, and the next launch with a network is
    /// signed in again. Anything that must not treat that device as signed out — the login
    /// link, Erase Local Data — asks this as well as `isLoggedIn`. A Keychain read; not for
    /// hot paths.
    var hasStoredSession: Bool { tokenStore.read() != nil }
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
            try await restoreStoredSession()
        } catch {
            currentUser = nil
        }
        isLoading = false
        isSessionRestored = true
    }

    /// Asks the server who the stored token belongs to. A thrown error (offline, a timeout, a
    /// 5xx) says nothing about the session, so the token stays.
    ///
    /// `{user: null}` is the server's answer for a session that is gone — expired after 30 days
    /// unused, signed out or deleted elsewhere. `/v1/auth/session` is public and never answers
    /// 401, so APIClient's 401 path never clears this token, and no sync runs to hit a 401
    /// either (they need a loaded user). Kept, it left the device showing "Log In" while every
    /// login link was ignored as "already signed in" — for exactly the people coming back to
    /// sign in again. So it is deleted here, the same as a 401 would.
    private func restoreStoredSession() async throws {
        let sentToken = tokenStore.read()
        let response = try await api.getSession()
        // An answer about a token that has since been replaced — a pasted token verified while
        // this request was in flight — says nothing about the new one: its user stays, and it
        // is not deleted.
        guard tokenStore.read() == sentToken else { return }
        currentUser = response.user
        if response.user == nil, sentToken != nil {
            tokenStore.delete()
        }
    }

    func requestMagicLink(email: String) async -> Bool {
        isLoading = true
        error = nil
        do {
            try await api.requestMagicLink(email: email)
            isLoading = false
            return true
        } catch {
            self.error = APIError.displayMessage(for: error)
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
            self.error = APIError.displayMessage(for: error)
            isLoading = false
            return false
        }
    }

    // MARK: - One-tap sign-in

    enum LoginLinkOutcome: Equatable {
        /// Not a login link (`LoginLink.token(from:)` is nil) — nothing was done.
        case notALoginLink
        /// This device already has an account; the link was not used.
        case ignoredAlreadySignedIn
        /// Another link is being verified right now; this one was not used.
        case ignoredInProgress
        case signedIn
        /// The server refused the token (used, expired) or could not be reached. `error` says
        /// which, and the login sheet shows it if it is open.
        case failed
    }

    /// The universal link from the magic-link email (StrideApp's `.onOpenURL` and
    /// `.onContinueUserActivity`). Signs in only when this device is signed out; the caller runs
    /// the post-login sync on `.signedIn`.
    ///
    /// Signed in already, the link is ignored rather than switching accounts. Switching now would
    /// keep this device's habits and push them into the other account on the next sync — M2
    /// builds the choice (keep, merge, discard) that makes a switch safe. A link opened by
    /// accident, or a second person's link forwarded to this device, must not do that.
    ///
    /// The token never reaches a log, analytics or Sentry: it is sent in the verify request's
    /// body, which Sentry's request stripping and network breadcrumbs (URL only) never carry,
    /// and nothing here logs the URL.
    func handleLoginLink(_ url: URL) async -> LoginLinkOutcome {
        guard let token = LoginLink.token(from: url) else { return .notALoginLink }
        guard !isHandlingLoginLink else {
            // iOS can deliver one tap through both handlers, and the token is single-use: a
            // second verify would fail and put "Invalid or expired login link" under a sign-in
            // that worked.
            Self.logger.info("Login link ignored: another one is being verified")
            return .ignoredInProgress
        }
        isHandlingLoginLink = true
        defer { isHandlingLoginLink = false }

        // A link can be what launched the app, while the stored session is still being checked;
        // `currentUser` is nil until that finishes.
        await waitForSessionRestore()
        // A token with no user: the launch check failed or timed out, and was never retried.
        // Ask again now — the user is tapping a link, so the network is likely back. A user
        // means signed in (ignored below); `{user: null}` deletes the dead token, and the link
        // signs in; an error leaves it undecided.
        var recheckError: Error?
        if !isLoggedIn, hasStoredSession {
            do { try await restoreStoredSession() } catch { recheckError = error }
        }
        // The stored token, not only `currentUser`: a session check that failed offline leaves
        // `currentUser` nil with the token still stored, and that device may well be signed
        // in — verifying would replace its session with another account's.
        if isLoggedIn || hasStoredSession {
            if !isLoggedIn, let recheckError {
                // Otherwise nothing happens at all on the tap; an open login sheet says why.
                error = APIError.displayMessage(for: recheckError)
            }
            Self.logger.notice("Login link ignored: this device is already signed in")
            return .ignoredAlreadySignedIn
        }
        if await verifyToken(token) {
            Self.logger.notice("Signed in from a login link")
            return .signedIn
        }
        Self.logger.notice("Login link sign-in failed")
        return .failed
    }

    @ObservationIgnored private var isHandlingLoginLink = false
    private static let logger = Logger(subsystem: "yyh.stride.habittracker", category: "Auth")

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
