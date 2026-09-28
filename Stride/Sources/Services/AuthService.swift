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
    /// Where the stored session's account is remembered (`sessionAccountKey`).
    private let defaults: UserDefaults
    /// A closure rather than a SyncService so that creating `shared` still does not create
    /// `SyncService.shared` as a side effect; it is reached only on logout, as before.
    ///
    /// Since 1.3.1 it ends the sync session and nothing more (`SyncService.signedOut`): a sync
    /// in flight stops, but the cursor, the deletion queue and every row's delivery state stay,
    /// so signing back into the same account resumes and uploads nothing again (M2, "Same
    /// account again"). 1.3.0 reset the cursor here; that was what let the next account on the
    /// device receive the previous one's never-pushed rows.
    private let onSignOut: @MainActor () -> Void
    /// After a sign-in completes (a magic link verified). Nothing in the app subscribes: the M2
    /// slice used it to end the launch session's claim on a store's migrated delivery marks, and
    /// the owner's rule that replaced that claim — the adopting account's first full pull proves
    /// the marks (`SyncMarksProof`) — needs no sign-in hook. TODO(M2): remove it together with
    /// the argument StrideAppTests/AuthServiceTests.swift passes.
    private let onSignIn: @MainActor () -> Void

    /// The defaults are what `shared` has always used. StrideAppTests passes an APIClient over a
    /// stubbed URLSession and the same in-memory token store it gave that client — the two must
    /// share one store, exactly as both share the Keychain item in the app — and a scratch
    /// defaults suite, so a test never writes the host app's remembered account.
    init(
        api: APIClient = .shared,
        tokenStore: SessionTokenStore = KeychainSessionTokenStore(),
        defaults: UserDefaults = .standard,
        onSignOut: @escaping @MainActor () -> Void = { SyncService.shared.signedOut() },
        onSignIn: @escaping @MainActor () -> Void = {}
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.onSignOut = onSignOut
        self.onSignIn = onSignIn
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
        setUser(response.user)
        if response.user == nil, sentToken != nil {
            tokenStore.delete()
            rememberSessionAccount(nil)
        }
    }

    /// `currentUser`, and the account the stored session belongs to (`sessionAccountKey`), which
    /// outlives a launch whose session check fails. Clearing the user (a failed check) does not
    /// forget the account: the token is still that account's.
    private func setUser(_ user: APIUser?) {
        currentUser = user
        if let user { rememberSessionAccount(SyncAccount(user)) }
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
            setUser(response.user)
            onSignIn()
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

    // `loginWithSessionToken(_:)` is gone (1.3.0). It stored a session token taken straight from
    // a URL — anything can open a URL — for a web-login redirect that was never built: no app
    // code in the git history ever called it, only a test. Sign-in from a link is
    // `handleLoginLink`, which verifies a one-time magic-link token with the server and stores
    // only the session the server returns, never what the URL carries.

    func logout() async {
        do {
            try await api.logout()
        } catch {
            // Clear locally even if server call fails
        }
        currentUser = nil
        tokenStore.delete()
        rememberSessionAccount(nil)
        onSignOut()
    }

    /// TODO(M2 account screen): the spec also erases local data and clears the store's owner
    /// here ("`deleteAccount` erases local data and clears the owner"), which needs the
    /// confirmation text to say so. Until then the owner stays the deleted account, so the next
    /// account signed into on this device finds rows it does not own and is not synced until
    /// that screen settles it — blocked, never merged. Clearing the owner alone would be worse:
    /// the rows keep `syncedAt` from the deleted account, and the next account's first full pull
    /// would delete them as "delivered, then deleted elsewhere".
    func deleteAccount() async throws {
        try await api.deleteAccount()
        currentUser = nil
        tokenStore.delete()
        rememberSessionAccount(nil)
        onSignOut()
    }

    // MARK: - The sync session (SyncService's run binding)

    /// The account the stored session token belongs to: `{id, email}` in UserDefaults, written
    /// whenever the server names the session's user and removed with the token.
    ///
    /// So a launch whose session check failed offline (`currentUser` nil, the token kept) still
    /// knows whose token it holds, and can sync once the network is back — Erase Local Data's
    /// pre-erase sync depends on that. A sync must know the account, not just hold a token: it
    /// runs only while the signed-in account is the store's owner (M2 account isolation), and
    /// guessing "the owner" for an unnamed token would push the owner's rows on whichever
    /// account that token is. Not a secret (a server user id and the email Settings shows);
    /// the token stays in the Keychain.
    static let sessionAccountKey = "stride_session_account"

    private var rememberedSessionAccount: SyncAccount? {
        guard let dict = defaults.dictionary(forKey: Self.sessionAccountKey),
              let id = dict["id"] as? String, let email = dict["email"] as? String else { return nil }
        return SyncAccount(id: id, email: email)
    }

    private func rememberSessionAccount(_ account: SyncAccount?) {
        if let account {
            defaults.set(["id": account.id, "email": account.email], forKey: Self.sessionAccountKey)
        } else {
            defaults.removeObject(forKey: Self.sessionAccountKey)
        }
    }
}

extension AuthService: SyncSessionSource {
    /// The stored token and its account, or nil: signed out, or a token whose account this
    /// device has never been told (a 1.3.0 session whose first 1.3.1 check has not succeeded
    /// yet). A Keychain read — SyncService's gate asks before and after every request of a
    /// run, a few dozen reads per sync, never per row.
    func currentSyncSession() -> SyncSession? {
        guard let token = tokenStore.read() else { return nil }
        guard let account = currentUser.map(SyncAccount.init) ?? rememberedSessionAccount else { return nil }
        return SyncSession(token: token, account: account)
    }

    /// Waits out the launch session check, and asks the server once more when a token is stored
    /// but its account is still unknown (that check failed offline, and no account was ever
    /// remembered for it). An error leaves it unknown: no sync, rather than a guess.
    func resolveSyncSession() async -> SyncSession? {
        await waitForSessionRestore()
        if currentSyncSession() == nil, currentUser == nil, hasStoredSession {
            try? await restoreStoredSession()
        }
        return currentSyncSession()
    }
}
