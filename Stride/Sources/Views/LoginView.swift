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
                }

                Spacer()
                Spacer()
            }
            .padding(24)
            .navigationTitle("Log In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
                Task { await verifyAndDismiss() }
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
                Task { await verifyAndDismiss() }
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

            Button("Send me a login link instead") {
                step = .email
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func verifyAndDismiss() async {
        let success = await auth.verifyToken(verificationToken)
        verificationToken = "" // Clear token from memory
        if success { dismiss() }
    }
}
