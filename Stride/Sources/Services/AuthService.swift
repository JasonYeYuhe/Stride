import Foundation
import SwiftUI
import os.log

/// Manages user authentication state across the app.
@MainActor
@Observable
final class AuthService {
    #if DEBUG
    /// The app's instance — or, in StrideAppTests only, the test's own while a hosted test
    /// renders real views that read `shared` (TodayView, LoginView, AccountSwitchView), so a view
    /// under test signs in through the stub server, never the host app's Keychain item (the
    /// critic-1 presenter test). Release builds keep the plain `static let`.
    static var shared: AuthService { testOverride ?? live }
    static var testOverride: AuthService?
    private static let live = AuthService()
    #else
    static let shared = AuthService()
    #endif

    private(set) var currentUser: APIUser?
    private(set) var isLoading = false
    private(set) var error: String?

    /// True once the initial session check from Keychain has completed (success or failure).
    private(set) var isSessionRestored = false

    /// The stored session was found gone — `{user: null}` for the stored token: expired after 30
    /// days unused, revoked, or signed out elsewhere — rather than ended here by Log Out. Today's
    /// "Sign in again to keep syncing" row reads it with `SyncService.needsReauth` (M2, "Sign-in
    /// that stays"; acceptance (9)).
    ///
    /// Persisted, unlike `needsReauth`: a 401 flags the run in memory, but the next COLD launch's
    /// session check is what then meets the dead token, deletes it and leaves the device looking
    /// merely signed out — no row, only "Sign In" in Settings, the 1.3.0 state the row exists to
    /// end. Also set by a 401 from Delete Account (`sessionFoundGone`). Cleared by a sign-in, a Log
    /// Out, an account deletion and Erase Local Data (nothing is left to sync then —
    /// `localDataErased`); the account screen's Cancel puts back what its sign-in cleared
    /// (`cancelSignIn`).
    private(set) var sessionExpired = false
    static let sessionExpiredKey = "stride_session_expired"

    var isLoggedIn: Bool { currentUser != nil }

    /// How a user was last loaded: what turned `isLoggedIn` true, for what follows it
    /// (SettingsView's sync, `SettingsView.syncTrigger(afterUserLoadedBy:)`).
    enum UserLoad: Equatable {
        /// A sign-in the user just made: a code typed or a login link verified (`verifyToken`).
        case signIn
        /// The stored session, restored with no one asking: the launch check, the foreground's
        /// recheck (`recheckStoredSessionIfNeeded`), a login link's or a sync's recheck.
        case restore
    }

    /// nil until a user is first loaded; never cleared, since it is read only when `isLoggedIn`
    /// turns true, by which time the load that turned it is recorded. Since 1.4.0's foreground
    /// recheck a restore can flip `isLoggedIn` on an ordinary foreground, with Settings kept
    /// alive, and that is not a sign-in (verification, minor).
    @ObservationIgnored private(set) var userLoadedBy: UserLoad?

    /// A session token is in the Keychain, whether or not its user is loaded. The two differ
    /// after a launch whose session check failed (offline, a timeout): `currentUser` is nil,
    /// the token and the sync cursor are still there, and the next launch with a network — since
    /// 1.4.0 the next foreground (`recheckStoredSessionIfNeeded`) — is signed in again. Anything
    /// that must not treat that device as signed out — the login
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
    /// After a sign-in completes (a magic link verified, typed or tapped): `SyncService.signedIn`,
    /// which ends a 401's "Sign in again" (`needsReauth`) — the refused session is replaced, and
    /// the row must not wait for a sync that may not come or may fail offline. Called after
    /// `verifyToken` has taken its snapshot of the row for the account screen's Cancel. A closure
    /// for the same reason as `onSignOut`; tests pass their own.
    private let onSignIn: @MainActor () -> Void
    /// After `deleteAccount` has signed out: the deleted account's local traces go
    /// (`SyncService.accountDeleted` — its rows if it owned the store, its owner record, recovery
    /// log and backoff). A closure for the same reason as `onSignOut`; tests pass their own.
    private let onAccountDeleted: @MainActor (SyncAccount) -> Void
    /// `SyncService.needsReauth`: a sync this launch was answered 401 — the in-memory half of
    /// Today's "Sign in again" row. Read by `verifyToken` only, so creating `shared` still creates
    /// no SyncService; tests pass their own.
    private let reauthRequested: @MainActor () -> Bool

    /// The defaults are what `shared` has always used. StrideAppTests passes an APIClient over a
    /// stubbed URLSession and the same in-memory token store it gave that client — the two must
    /// share one store, exactly as both share the Keychain item in the app — and a scratch
    /// defaults suite, so a test never writes the host app's remembered account.
    init(
        api: APIClient = .shared,
        tokenStore: SessionTokenStore = KeychainSessionTokenStore(),
        defaults: UserDefaults = .standard,
        onSignOut: @escaping @MainActor () -> Void = { SyncService.shared.signedOut() },
        onSignIn: @escaping @MainActor () -> Void = { SyncService.shared.signedIn() },
        onAccountDeleted: @escaping @MainActor (SyncAccount) -> Void = { AuthService.eraseAfterAccountDeletion($0) },
        reauthRequested: @escaping @MainActor () -> Bool = { SyncService.shared.needsReauth }
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.onSignOut = onSignOut
        self.onSignIn = onSignIn
        self.onAccountDeleted = onAccountDeleted
        self.reauthRequested = reauthRequested
        self.sessionExpired = defaults.bool(forKey: Self.sessionExpiredKey)
        // Check session on init if we have a stored token
        if tokenStore.read() != nil {
            Task { await checkSession() }
        } else {
            isSessionRestored = true
        }
    }

    /// Wait until the initial session restoration has completed (up to `timeout`, 10 seconds).
    /// Call this before checking `isLoggedIn` on cold start to avoid races.
    ///
    /// It never writes `isSessionRestored`; only the check does (RELEASE-1.4.0.md D5). Until 1.4.0
    /// a waiter that timed out marked the session restored itself, with the check still in flight
    /// — so every later waiter returned at once, and a check that then failed was never waited
    /// for or retried. Harmless while the check always ran with the user opening the app; since
    /// background launches create `shared` (a refresh, a reminder's action), the check can be in
    /// flight when the process is suspended and fail on resume (design review,
    /// "bg-launch-leaves-currentUser-nil"). On the deadline, or when the waiting task is
    /// cancelled (a background task that expired), it just returns: a cancelled `Task.sleep`
    /// throws at once, and the old `try?` loop spun on the main actor until the deadline.
    func waitForSessionRestore(timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while !isSessionRestored && ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    /// The foreground's way back to a signed-in device after a session check that failed or never
    /// answered: asks the server about the stored token again when no user is known
    /// (`StrideApp.syncIfLoggedIn`, at launch and on every foreground).
    ///
    /// Needed since 1.4.0: a background launch's check can fail offline, and the user's next open
    /// is then a resume of that same process, not a launch — 1.3.x's "the next launch with a
    /// network is signed in again" (`hasStoredSession`) no longer came, and Today, Settings and
    /// every `isLoggedIn` gate treated the device as signed out until iOS evicted it.
    ///
    /// Through `restoreStoredSession`, never `checkSession`: that one sets `isLoading` and clears
    /// `error`, which an open login sheet shows as its spinner and its message. A user loaded
    /// signs in; `{user: null}` deletes the dead token and raises "Sign in again"; an error
    /// changes nothing.
    ///
    /// `launchCheckWait` is how long it first waits for the launch check (10 s); the tests shorten
    /// it. A check still in flight after that wait is not waited for again: the recheck goes out
    /// beside it, and if the check then fails, its failure no longer undoes the recheck's sign-in
    /// (`checkSession`).
    func recheckStoredSessionIfNeeded(launchCheckWait: Duration = .seconds(10)) async {
        await waitForSessionRestore(timeout: launchCheckWait)
        guard currentUser == nil, hasStoredSession else { return }
        do {
            try await restoreStoredSession()
            let answer = isLoggedIn ? "signed in" : "not signed in"
            Self.logger.notice("Stored session rechecked: \(answer, privacy: .public)")
        } catch {
            Self.logger.notice("Stored session recheck got no answer")
        }
    }

    func checkSession() async {
        isLoading = true
        error = nil
        let loadsBefore = usersLoaded
        do {
            try await restoreStoredSession()
        } catch {
            // A failed check forgets the user it started with — SyncStatusRow's tap relies on
            // that to open the login sheet offline — but not one loaded while it was in flight:
            // that answer is newer than this failure. Since 1.4.0 the foreground's recheck can
            // sign the device in beside a launch check that is still pending (a request from a
            // background launch whose connection went with the suspension can take URLSession's
            // 60 s to fail); clearing the user then flipped Today and Settings back to signed out
            // until the next foreground (W3 review). A one-tap sign-in (`verifyToken`) during the
            // check is kept the same way.
            if usersLoaded == loadsBefore {
                currentUser = nil
            }
        }
        isLoading = false
        isSessionRestored = true
    }

    /// How many times a user has been loaded (`setUser` with one), so a session check that fails
    /// can tell whether someone else signed the device in while it waited (`checkSession`).
    @ObservationIgnored private var usersLoaded = 0

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
        setUser(response.user, loadedBy: .restore)
        guard sentToken != nil else { return }
        if let user = response.user {
            // The first 1.3.1 launch left "signed in or not?" open for a store with rows and no
            // owner until this answer (SyncOwnerStore.noteFirstLaunch): signed in, so this account
            // owns the store from now — not from its first sync, which may never come before a
            // Log Out (a login link's recheck syncs nothing; review accounts-1). Same defaults as
            // SyncService's owner record: `.standard` in the app, the test's suite in tests.
            SyncOwnerStore(defaults: defaults).storedSessionConfirmed(account: SyncAccount(user))
        } else {
            sessionFoundGone()
        }
    }

    /// The server says the stored session is gone — `{user: null}` for it, or a 401 from Delete
    /// Account — rather than ended here by Log Out: the user, the token and its account are
    /// forgotten, a first-launch owner question still open is settled as signed out
    /// (`SyncOwnerStore.storedSessionEnded`), and Today's "Sign in again" row goes up and stays
    /// across launches (`sessionExpired`).
    private func sessionFoundGone() {
        currentUser = nil
        tokenStore.delete()
        rememberSessionAccount(nil)
        SyncOwnerStore(defaults: defaults).storedSessionEnded()
        setSessionExpired(true)
    }

    /// `currentUser`, and the account the stored session belongs to (`sessionAccountKey`), which
    /// outlives a launch whose session check fails. Clearing the user (a failed check) does not
    /// forget the account: the token is still that account's. A user loaded means signed in, so
    /// the "Sign in again" row's reason is gone. `load` is recorded before the user is set, so
    /// whatever observes `isLoggedIn` turning true reads how (`userLoadedBy`).
    private func setUser(_ user: APIUser?, loadedBy load: UserLoad) {
        if user != nil { userLoadedBy = load }
        currentUser = user
        if let user {
            usersLoaded += 1
            rememberSessionAccount(SyncAccount(user))
            setSessionExpired(false)
        }
    }

    private func setSessionExpired(_ expired: Bool) {
        sessionExpired = expired
        if expired {
            defaults.set(true, forKey: Self.sessionExpiredKey)
        } else {
            defaults.removeObject(forKey: Self.sessionExpiredKey)
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
            // A stored token the server never named a user for (the first 1.3.1 launch's check
            // failed offline, and a typed code replaced it) settles the owner question as signed
            // out: that token's account is unknown, so the store's rows are too.
            SyncOwnerStore(defaults: defaults).storedSessionEnded()
            // Before `setUser` ends it: the account screen's Cancel puts it back (`cancelSignIn`).
            // Either half of the row counts — the persisted `sessionExpired`, or a 401 this launch
            // (`reauthRequested`), which Log Out would end for good.
            setSignInAgainBeforeSignIn(sessionExpired || reauthRequested())
            setUser(response.user, loadedBy: .signIn)
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
    /// Signed in already, the link is ignored rather than switching accounts: a link opened by
    /// accident, or a second person's link forwarded to this device, must not sign the device out
    /// of its account. Signed out, a link into an account that does not own this device's habits
    /// continues with the same account screen as a typed code (StrideApp → `SyncService
    /// .settleSignIn` → AccountSwitchView), and nothing syncs until its choice.
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
        // Signed out on purpose: nothing to ask the user to sign back into.
        setSessionExpired(false)
        setSignInAgainBeforeSignIn(false)
        onSignOut()
    }

    /// Whether "Sign in again" was up when the last sign-in began (`verifyToken`), which ended it:
    /// what the account screen's Cancel puts back (`cancelSignIn`).
    ///
    /// Persisted, and from either half of the row (review accounts-2). Held in memory, it was lost
    /// by a relaunch between the sign-in and the Cancel — the account screen can wait across one:
    /// it cannot be swiped away, and after a relaunch Settings' owner-choice row opens it again —
    /// and it saw only `sessionExpired`, never a 401 of this launch (`SyncService.needsReauth`,
    /// which the Cancel's Log Out ends). Either way the Cancel signed out with no row, and the
    /// token it replaced had never been checked, so no later launch raised the row either.
    /// Cleared once the signed-in account owns the store (`signedInAccountOwnsTheStore`: the owner
    /// resumed or adopted, or Start / Upload settled it), by a deliberate Log Out, an account
    /// deletion and Erase Local Data.
    static let signInAgainBeforeSignInKey = "stride_session_expired_before_sign_in"

    private func setSignInAgainBeforeSignIn(_ shown: Bool) {
        if shown {
            defaults.set(true, forKey: Self.signInAgainBeforeSignInKey)
        } else {
            defaults.removeObject(forKey: Self.signInAgainBeforeSignInKey)
        }
    }

    /// The account screen's Cancel (AccountSwitchView): signs out of the account just signed into,
    /// as Log Out does, and leaves the device as it was before that sign-in — Today's "Sign in
    /// again" row included (review accounts-2). A sign-in ends the row whichever account it is
    /// into, and Log Out ends it again, so a sign-in started from the row, into the wrong account
    /// and cancelled, left the owner's unsynced edits behind a bare "Sign In": the 1.3.0 state
    /// the row exists to end. It comes back only while the store still holds what it is about —
    /// an owner, or rows whose owner is unknown; an erase meanwhile emptied the device, and
    /// "Sign in again" went with it (the owner's decision 2).
    func cancelSignIn() async {
        let restoresRow = defaults.bool(forKey: Self.signInAgainBeforeSignInKey)
        await logout()
        let owners = SyncOwnerStore(defaults: defaults)
        if restoresRow, owners.owner != nil || owners.ownerUnknown {
            setSessionExpired(true)
        }
    }

    /// Deletes the account on the server, signs out, and then clears what this device kept for
    /// it (M2: "`deleteAccount` erases local data and clears the owner"): its habits, check-ins
    /// and groups if it owned the store, the owner record, its recovery log (its lines hold that
    /// account's names and notes, and nobody can sign into it again to see them) and its backoff
    /// (`onAccountDeleted` → `SyncService.accountDeleted`). Settings' confirmation says the
    /// device's copy goes too.
    ///
    /// Why the erase and not only clearing the owner: the rows keep `syncedAt` from the deleted
    /// account, so the next account's first full pull would delete them as "delivered, then
    /// deleted elsewhere" — and they were that account's data, which the user just asked to have
    /// removed. A store owned by ANOTHER account (the deleted one was signed in while the account
    /// screen waited) is left alone.
    ///
    /// Throws when the server refused, and no data on this device is touched then. A 401 — the
    /// session was already gone: revoked, expired, or the account deleted on another device — also
    /// ends the session here, as the launch check's `{user: null}` does (`sessionFoundGone`: signed
    /// out, "Sign in again" on Today; review accounts-3). APIClient has deleted the token by then,
    /// and a device left "signed in" without one synced nothing, silently: every run found no
    /// session, Today kept its last "Synced" line, and no row offered the way back in. The store
    /// and its owner stay, so the owner signing in again resumes.
    func deleteAccount() async throws {
        // Before the sign-out forgets it: whose data to clear.
        let account = currentSyncSession()?.account ?? currentUser.map(SyncAccount.init)
        do {
            try await api.deleteAccount()
        } catch APIError.unauthorized {
            sessionFoundGone()
            setSignInAgainBeforeSignIn(false)
            onSignOut()
            throw APIError.unauthorized
        }
        currentUser = nil
        tokenStore.delete()
        rememberSessionAccount(nil)
        setSessionExpired(false)
        setSignInAgainBeforeSignIn(false)
        onSignOut()
        if let account { onAccountDeleted(account) }
    }

    /// The app's `onAccountDeleted`: the store and the sync state through SyncService, then what
    /// hangs off the store — reminders of habits that no longer exist, the badge, the widgets —
    /// as Erase Local Data does. An erase that cannot be saved leaves the rows under the deleted
    /// owner, and the next account signed into is shown the account screen for them (blocked,
    /// never merged); the account itself is already gone, so this is not reported as a failed
    /// deletion.
    static func eraseAfterAccountDeletion(_ account: SyncAccount) {
        // The container the launch opened. Delete Account is reached only from Settings, which
        // exists only over an opened store; never open one here (upgrade race, E2E U123: a
        // second open of a store the launch could not open is how an empty store got erased
        // instead of the real one).
        guard let container = SharedModelContainer.opened else {
            logger.error("Local erase after account deletion skipped: the store is not open")
            return
        }
        do {
            try SyncService.shared.accountDeleted(account, in: container.mainContext)
        } catch {
            logger.error("Local erase after account deletion failed: \(error.localizedDescription, privacy: .public)")
        }
        AccountDataRefresh.afterLocalChange(in: container)
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

    /// Erase Local Data (`SyncService.resetSyncState`): the store is empty and no account's sync
    /// state is left, so "Sign in again to keep syncing" has nothing to keep syncing. A signed-in
    /// erase has already cleared it through `logout()`; this is the signed-out erase after a
    /// session was found gone, which kept the row on an empty device (phase C leftovers, the
    /// owner's decision 2). The next sign-in is an ordinary one.
    func localDataErased() {
        setSessionExpired(false)
        setSignInAgainBeforeSignIn(false)
    }

    /// The signed-in account owns the store now (`SyncService.settleOwner`): the sign-in, if any,
    /// needed no account screen, or its Start / Upload settled it. Nothing is left for a Cancel to
    /// put back (review accounts-2).
    func signedInAccountOwnsTheStore() {
        setSignInAgainBeforeSignIn(false)
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
