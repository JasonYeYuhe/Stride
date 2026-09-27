import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    private var auth = AuthService.shared

    @State private var email = ""
    @State private var verificationToken = ""
    @State private var step: LoginStep = .email
    @State private var showSuccess = false

    enum LoginStep {
        case email
        case checkInbox
        case enterCode
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Icon
                Image(systemName: step == .checkInbox ? "envelope.open.fill" : "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                switch step {
                case .email:
                    emailStep
                case .checkInbox:
                    checkInboxStep
                case .enterCode:
                    enterCodeStep
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
            // Each step replaces the whole panel, which destroys the subtree holding
            // VoiceOver focus: without these the user hears nothing at all.
            .onChange(of: step) { _, newStep in
                AccessibilityNotification.Announcement(Self.announcement(for: newStep)).post()
            }
            .onChange(of: auth.error) { _, newError in
                guard let newError else { return }
                AccessibilityNotification.Announcement(appLocalized("Error: \(newError)")).post()
            }
            // The one place this sheet closes on success, for both ways in: a pasted token, and
            // the login link tapped in Mail while this waits on "Check your email" (StrideApp
            // signs in from the link; nothing here knows that happened except this).
            .onChange(of: auth.isLoggedIn) { _, loggedIn in
                if loggedIn { dismiss() }
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
        }
    }

    /// Dismissal is the `isLoggedIn` onChange above, not here, so there is one dismissal
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
