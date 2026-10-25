import SwiftUI
import Amplify

struct AccountSetupView: View {
    let onComplete: () -> Void
    @Environment(UserProfile.self) private var profile
    @AppStorage("account.setupComplete") private var setupComplete = false
    @AppStorage("account.skipped") private var skipped = false
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var creating = false
    @State private var step = "credentials"
    @State private var busy = false
    @State private var message: String?
    @State private var challengePrompt = "Enter your verification code"

    private var username: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image("LifeLoopLogo").resizable().scaledToFit().frame(height: 100).frame(maxWidth: .infinity)
                    Text("Your family, connected.").font(.title2.bold())
                }
                if profile.isSignedIn {
                    Section {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                        Button("Continue") { finish() }
                        Button("Sign out", role: .destructive) {
                            run {
                                _ = await Amplify.Auth.signOut()
                                await profile.refreshFamilies()
                                LoopNotifications.shared.resetForAccountChange()
                            }
                        }
                    }
                } else {
                    Section {
                        if step == "credentials" {
                            Picker("Account", selection: $creating) {
                                Text("Sign in").tag(false)
                                Text("Create account").tag(true)
                            }.pickerStyle(.segmented)
                            TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Password", text: $password).textContentType(creating ? .newPassword : .password)
                            Button(creating ? "Create account" : "Sign in") { run { try await submit() } }
                                .disabled(username.isEmpty || password.isEmpty)
                            Button("Verify an existing account") { step = "verify"; code = "" }.disabled(username.isEmpty)
                            Button("Forgot password?") {
                                run {
                                    _ = try await Amplify.Auth.resetPassword(for: username)
                                    step = "reset"
                                    message = "Enter the code sent to your email and a new password."
                                    password = ""
                                }
                            }.disabled(username.isEmpty)
                        } else {
                            Text(step == "challenge" ? challengePrompt : "Check your email for a verification code.")
                            TextField("Code", text: $code).textContentType(.oneTimeCode)
                            if step == "reset" { SecureField("New password", text: $password).textContentType(.newPassword) }
                            Button("Confirm") { run { try await confirm() } }.disabled(code.isEmpty)
                            if step == "verify" {
                                Button("Resend code") { run { _ = try await Amplify.Auth.resendSignUpCode(for: username); message = "New code sent." } }
                            }
                            Button("Back to sign in") { step = "credentials"; code = ""; message = nil }
                        }
                    }.disabled(busy)
                    Section {
                        Button("Continue without an account") { skipped = true; finish() }.disabled(busy)
                        Text("You can use Bluetooth features without an account. Family sharing requires sign-in to the configured family service.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if busy { ProgressView("Please wait…") }
                if let message { Section { Text(message).font(.callout) } }
            }.loopPage().navigationTitle("LifeLoop account")
                .task { await profile.refreshFamilies() }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }

    private func submit() async throws {
        if creating {
            let options = AuthSignUpRequest.Options(userAttributes: [AuthUserAttribute(.email, value: username)])
            let result = try await Amplify.Auth.signUp(username: username, password: password, options: options)
            if result.isSignUpComplete {
                creating = false
                message = "Account created. Sign in to continue."
            } else { step = "verify" }
        } else {
            let result = try await Amplify.Auth.signIn(username: username, password: password)
            try await handleSignIn(result)
        }
        password = ""
    }

    private func handleSignIn(_ result: AuthSignInResult) async throws {
        if result.isSignedIn {
            skipped = false
            await profile.refreshFamilies()
            finish()
            return
        }
        switch result.nextStep {
        case .confirmSignUp:
            step = "verify"
        case .confirmSignInWithSMSMFACode, .confirmSignInWithTOTPCode, .confirmSignInWithOTP:
            step = "challenge"
            challengePrompt = "Enter the code from your email, text message, or authenticator."
        default:
            message = "This account requires an additional sign-in setup step. Ask your account administrator to complete its MFA or password setup."
        }
    }

    private func confirm() async throws {
        switch step {
        case "verify":
            let result = try await Amplify.Auth.confirmSignUp(for: username, confirmationCode: code)
            if result.isSignUpComplete { step = "credentials"; creating = false; message = "Email verified. Sign in to continue." }
        case "reset":
            try await Amplify.Auth.confirmResetPassword(for: username, with: password, confirmationCode: code)
            password = ""
            step = "credentials"
            creating = false
            message = "Password changed. Sign in to continue."
        default:
            try await handleSignIn(Amplify.Auth.confirmSignIn(challengeResponse: code))
        }
    }

    private func finish() {
        password = ""
        code = ""
        setupComplete = true
        onComplete()
    }
}
