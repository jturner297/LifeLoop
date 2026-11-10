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
    @State private var isErrorMessage = false
    @State private var challengePrompt = "Enter your verification code"

    private var username: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private struct PasswordRequirement: Identifiable {
        let id: String
        let label: String
        let missingDetail: String
        let isMet: Bool
    }

    private var passwordRequirements: [PasswordRequirement] {
        [
            PasswordRequirement(
                id: "length",
                label: "At least 8 characters",
                missingDetail: "At least 8 characters required",
                isMet: password.count >= 8
            ),
            PasswordRequirement(
                id: "uppercase",
                label: "At least 1 capital letter (A–Z)",
                missingDetail: "No capital letter detected",
                isMet: password.rangeOfCharacter(from: .uppercaseLetters) != nil
            ),
            PasswordRequirement(
                id: "lowercase",
                label: "At least 1 lowercase letter (a–z)",
                missingDetail: "No lowercase letter detected",
                isMet: password.rangeOfCharacter(from: .lowercaseLetters) != nil
            ),
            PasswordRequirement(
                id: "number",
                label: "At least 1 number (0–9)",
                missingDetail: "No number detected",
                isMet: password.rangeOfCharacter(from: .decimalDigits) != nil
            ),
            PasswordRequirement(
                id: "symbol",
                label: "At least 1 special character (!@#$%^&*)",
                missingDetail: "No special character detected",
                isMet: password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted.subtracting(.whitespacesAndNewlines)) != nil
            )
        ]
    }

    private var missingPasswordDetails: [String] {
        passwordRequirements.filter { !$0.isMet }.map(\.missingDetail)
    }

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
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: creating) { _, _ in
                                message = nil
                                isErrorMessage = false
                            }
                            TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Password", text: $password).textContentType(creating ? .newPassword : .password)
                            if creating {
                                passwordChecklistView
                            }
                            Button(creating ? "Create account" : "Sign in") { run { try await submit() } }
                                .disabled(username.isEmpty || password.isEmpty)
                            Button("Verify an existing account") { step = "verify"; code = "" }.disabled(username.isEmpty)
                            Button("Forgot password?") {
                                run {
                                    _ = try await Amplify.Auth.resetPassword(for: username)
                                    step = "reset"
                                    isErrorMessage = false
                                    message = "Enter the code sent to your email and a new password."
                                    password = ""
                                }
                            }.disabled(username.isEmpty)
                        } else {
                            Text(step == "challenge" ? challengePrompt : "Check your email for a verification code.")
                            TextField("Code", text: $code).textContentType(.oneTimeCode)
                            if step == "reset" {
                                SecureField("New password", text: $password).textContentType(.newPassword)
                                passwordChecklistView
                            }
                            Button("Confirm") { run { try await confirm() } }.disabled(code.isEmpty)
                            if step == "verify" {
                                Button("Resend code") {
                                    run {
                                        _ = try await Amplify.Auth.resendSignUpCode(for: username)
                                        isErrorMessage = false
                                        message = "New code sent."
                                    }
                                }
                            }
                            Button("Back to sign in") { step = "credentials"; code = ""; message = nil; isErrorMessage = false }
                        }
                    }.disabled(busy)
                    Section {
                        Button("Continue without an account") { skipped = true; finish() }.disabled(busy)
                        Text("You can use Bluetooth features without an account. Family sharing requires sign-in to the configured family service.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if busy { ProgressView("Please wait…") }
                if let message {
                    Section {
                        Label {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(isErrorMessage ? .red : .primary)
                        } icon: {
                            Image(systemName: isErrorMessage ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(isErrorMessage ? .red : LoopStyle.green)
                        }
                    }
                }
            }.loopPage().navigationTitle("LifeLoop account")
                .task { await profile.refreshFamilies() }
        }
    }

    private var passwordChecklistView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password requirements:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(passwordRequirements, id: \.id) { req in
                let isEmpty = password.isEmpty
                let iconName = req.isMet ? "checkmark.circle.fill" : (isEmpty ? "circle" : "xmark.circle.fill")
                let iconColor: Color = req.isMet ? .green : (isEmpty ? .secondary : .red)
                let textColor: Color = req.isMet ? .primary : (isEmpty ? .secondary : .red)
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                        .font(.caption)
                    Text(req.label)
                        .font(.caption)
                        .foregroundStyle(textColor)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private struct PasswordValidationError: LocalizedError {
        let errorDescription: String?
    }

    private func validatePasswordRequirements() throws {
        let missing = missingPasswordDetails
        guard !missing.isEmpty else { return }
        throw PasswordValidationError(
            errorDescription: "Password doesn't meet requirements: \(missing.joined(separator: ", "))."
        )
    }

    private func formatAuthError(_ error: Error) -> String {
        if let validationError = error as? PasswordValidationError,
           let desc = validationError.errorDescription {
            return desc
        }
        if let authError = error as? AuthError {
            let desc = authError.errorDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                return desc
            }
        }
        return error.localizedDescription
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        message = nil
        isErrorMessage = false
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                isErrorMessage = true
                message = formatAuthError(error)
            }
        }
    }

    private func submit() async throws {
        if creating {
            try validatePasswordRequirements()
            let options = AuthSignUpRequest.Options(userAttributes: [AuthUserAttribute(.email, value: username)])
            let result = try await Amplify.Auth.signUp(username: username, password: password, options: options)
            if result.isSignUpComplete {
                creating = false
                isErrorMessage = false
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
            isErrorMessage = true
            message = "This account requires an additional sign-in setup step. Ask your account administrator to complete its MFA or password setup."
        }
    }

    private func confirm() async throws {
        switch step {
        case "verify":
            let result = try await Amplify.Auth.confirmSignUp(for: username, confirmationCode: code)
            if result.isSignUpComplete {
                step = "credentials"
                creating = false
                isErrorMessage = false
                message = "Email verified. Sign in to continue."
            }
        case "reset":
            try validatePasswordRequirements()
            try await Amplify.Auth.confirmResetPassword(for: username, with: password, confirmationCode: code)
            password = ""
            step = "credentials"
            creating = false
            isErrorMessage = false
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
