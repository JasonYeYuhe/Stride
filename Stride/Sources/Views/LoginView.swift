import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    private var auth = AuthService.shared
    private var sync = SyncService.shared

    @State private var email = ""
    @State private var verificationToken = ""
    @State private var step: LoginStep = .email
    @State private var showSuccess = false

    /// `prefilledEmail`: what the email field starts with — the account a "Sign in again" row
    /// asks for (`SignInAgainFlow.loginEmail`), where the field used to start empty (E2E S9
    /// suggestion). nil leaves it empty, as for a first sign-in.
    init(prefilledEmail: String? = nil) {
        _email = State(initialValue: prefilledEmail ?? "")
    }

    enum LoginStep: Equatable {
        case email
        case checkInbox
        case enterCode
        /// Signed in, into an account that does not own this device's habits: the sign-in
        /// continues with the account screen (M2 account isolation), in this same sheet.
        case accountChoice(SyncOwnerConflict)
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .accountChoice(let conflict) = step {
                    AccountSwitchView(conflict: conflict) { dismiss() }
                        #if os(macOS)
                        // The screen is a bare ScrollView with no ideal height, and this sheet
                        // was sized for the sign-in panel: the size AccountChoiceSheet gives it.
                        .frame(minWidth: 460, minHeight: 520)
                        #endif
                } else {
                    signInPanel
                }
            }
            // Each step replaces the whole panel, which destroys the subtree holding
            // VoiceOver focus: without these the user hears nothing at all.
            .onChange(of: step) { _, newStep in
                AccessibilityNotification.Announcement(Self.announcement(for: newStep)).post()
            }
            .onChange(of: auth.error) { _, newError in
                guard let newError else { return }
                AccessibilityNotification.Announcement(appLocalized("Error: \(newError)")).post()
            }
            // The one place a sign-in continues, for both ways in: a pasted token, and the login
            // link tapped in Mail while this waits on "Check your email" (StrideApp signs in from
            // the link; nothing here knows that happened except this).
            .onChange(of: auth.isLoggedIn) { _, loggedIn in
                if loggedIn { continueSignIn() }
            }
        }
        // StrideApp leaves a link's account screen to this sheet while it is open.
        .onAppear { AccountChoiceRouter.shared.loginFlowsOpen += 1 }
        .onDisappear { AccountChoiceRouter.shared.loginFlowsOpen -= 1 }
    }

    private var signInPanel: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: step == .checkInbox ? "envelope.open.fill" : "person.crop.circle.fill")
                .scaledSystemFont(size: 56, relativeTo: .largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
                // Decoration: past .accessibility2 it only pushes the email field and its
                // button further down a panel that does not scroll.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)

            switch step {
            case .email:
                emailStep
            case .checkInbox:
                checkInboxStep
            case .enterCode:
                enterCodeStep
            case .accountChoice:
                // Shown instead of this panel (body).
                EmptyView()
            }

            if let error = auth.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    // Red text is the only cue that this is an error, and VoiceOver
                    // does not convey color.
                    .accessibilityLabel(Text("Error: \(error)"))
            }

            Spacer()
            Spacer()
        }
        .padding(24)
        .navigationTitle("Log In")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private var emailStep: some View {
        VStack(spacing: 16) {
            Text("Sign in to sync your habits across devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Email address", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif

            Button {
                Task {
                    let sent = await auth.requestMagicLink(email: email)
                    if sent { step = .checkInbox }
                }
            } label: {
                if auth.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 20)
                } else {
                    Text("Send Login Link")
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(email.isEmpty || auth.isLoading)
            // While loading, the label is a bare ProgressView, so this is the button's
            // only name rather than a restatement of a visible one.
            .accessibilityLabel(Text("Send Login Link"))
            .accessibilityValue(auth.isLoading ? Text("In progress") : Text(verbatim: ""))

            Button("I have a login token") {
                step = .enterCode
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var checkInboxStep: some View {
        VStack(spacing: 16) {
            Text("Check your email")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            Text("We sent a login link to **\(email)**.\n\nClick the link in the email, or paste the token below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Paste token here", text: $verificationToken)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Button {
                Task { await verify() }
            } label: {
                if auth.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 20)
                } else {
                    Text("Verify")
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(verificationToken.isEmpty || auth.isLoading)
            .accessibilityLabel(Text("Verify"))
            .accessibilityValue(auth.isLoading ? Text("In progress") : Text(verbatim: ""))

            Button("Use a different email") {
                step = .email
                verificationToken = ""
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var enterCodeStep: some View {
        VStack(spacing: 16) {
            Text("Enter Login Token")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Paste the token from your login email.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Token", text: $verificationToken)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Button {
                Task { await verify() }
            } label: {
                if auth.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 20)
                } else {
                    Text("Log In")
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(verificationToken.isEmpty || auth.isLoading)
            .accessibilityLabel(Text("Log In"))
            .accessibilityValue(auth.isLoading ? Text("In progress") : Text(verbatim: ""))

            Button("Send me a login link instead") {
                step = .email
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// `Announcement` takes a verbatim String, so each phrase is localized here as a
    /// whole key rather than interpolated at the call site.
    private static func announcement(for step: LoginStep) -> String {
        switch step {
        case .email: appLocalized("Log In")
        case .checkInbox: appLocalized("Check your email")
        case .enterCode: appLocalized("Enter Login Token")
        case .accountChoice: appLocalized("This Device's Habits")
        }
    }

    /// Signed in: the owner is settled before anything syncs (`SyncService.settleSignIn`). The
    /// owner itself, a store with no owner, or one with nothing to lose → the sheet closes and
    /// the usual post-sign-in sync runs (Settings). Another account's habits — or habits no
    /// account was recorded for — are here → the account screen, as the next step of this sheet;
    /// until its choice, every sync entry point is blocked.
    private func continueSignIn() {
        switch sync.settleSignIn(in: modelContext) {
        case .chooseAccountData(let conflict):
            step = .accountChoice(conflict)
        case .ready, .signedOut:
            dismiss()
        }
    }

    /// What follows a sign-in is the `isLoggedIn` onChange above, not here, so there is one path
    /// however the sign-in happened.
    private func verify() async {
        let pasted = verificationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        verificationToken = "" // Clear token from memory
        // Someone who copied the whole link from the email (a Gmail user, whose link never opens
        // the app) can paste it as it is.
        let token = URL(string: pasted).flatMap(LoginLink.token(from:)) ?? pasted
        _ = await auth.verifyToken(token)
    }
}
