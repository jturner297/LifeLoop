import SwiftUI

struct AppRootView: View {
    @AppStorage("profile.onboarded") private var onboarded = false
    @AppStorage("account.setupComplete") private var accountSetupComplete = false
    @State private var profile = UserProfile()

    var body: some View {
        Group {
            if !accountSetupComplete {
                AccountSetupView { accountSetupComplete = true }
            } else if onboarded {
                ContentView()
            } else {
                WelcomeView(onboarded: $onboarded)
            }
        }
        .environment(profile)
        .tint(LoopStyle.green)
        .preferredColorScheme(.light)
    }
}

struct WelcomeView: View {
    @Environment(UserProfile.self) private var profile
    @Binding var onboarded: Bool

    var body: some View {
        @Bindable var profile = profile
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LandscapeArt().frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 28))
                    Text("Welcome to LifeLoop").font(.largeTitle.bold())
                    Text("Stay connected to the people who matter. Start with your name, then connect a device or join your group.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("What should we call you?").font(.headline)
                        TextField("Your name", text: $profile.name)
                            .textContentType(.name).textFieldStyle(.roundedBorder)
                    }.loopCard()
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Contact information · Optional").font(.headline)
                        TextField("Phone number", text: $profile.phone)
                            .textContentType(.telephoneNumber).keyboardType(.phonePad)
                        TextField("Email address", text: $profile.email)
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("I agree to share my contact information with my groups when contact sharing is available.", isOn: $profile.contactConsent)
                        Text("Your contact details stay on this phone for now. You can skip this section and add them in Settings later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.loopCard()
                    Button("Get started") { onboarded = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(24).frame(maxWidth: 650)
            }.loopPage()
        }
    }
}
