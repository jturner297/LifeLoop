import SwiftUI

struct AppRootView: View {
    @AppStorage("profile.onboarded") private var onboarded = false
    @AppStorage("account.setupComplete") private var accountSetupComplete = false
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.light.rawValue
    @State private var profile = UserProfile()

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .light
    }

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
        .preferredColorScheme(appearance.colorScheme)
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
                    QuickStartCardsSection()
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Contact information · Optional").font(.headline)
                        PhoneNumberField(phone: $profile.phone)
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

struct QuickStartCardsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Quick Start Guide", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(LoopStyle.green)

            quickStartStep(
                number: "1",
                title: "Setting up a LifeLoop Watch (Wearer)",
                icon: "applewatch.radiowaves.left.and.right",
                bullets: [
                    "Open the Devices tab and tap Connect a device to pair your LifeLoop watch over Bluetooth.",
                    "Tap any connected device card to check battery %, view live heart rate, or put the watch into Sleep Mode / Wake it up.",
                    "If a fall is detected, a 30-second countdown begins. Cancel anytime from the app or by holding the watch button for 2 seconds."
                ]
            )

            Divider()

            quickStartStep(
                number: "2",
                title: "Connecting with Family (Caregivers)",
                icon: "person.2.fill",
                bullets: [
                    "Open the Groups tab to Create a Family (generates a 6-character code) or Join a Family using a code.",
                    "Inside your family group, open Shared devices to link the wearer's watch so family members can see live status, location, and send Check-In Pings.",
                    "Open Call contacts to add family or caregiver numbers, including people without the app. Save your own number in Settings to link it to your account online. Emergency call routing is configured separately."
                ]
            )
        }
        .loopCard()
    }

    private func quickStartStep(number: String, title: String, icon: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LoopStyle.green)
                    .frame(width: 28, height: 28)
                    .background(LoopStyle.mint, in: Circle())
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(LoopStyle.ink)
            }
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.caption.bold())
                        .foregroundStyle(LoopStyle.green)
                    Text(bullet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct QuickStartGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onConnectDevice: (() -> Void)? = nil
    var onOpenGroups: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Whether you are setting up a LifeLoop watch or monitoring a loved one in a family group, here is how to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    QuickStartCardsSection()

                    if onConnectDevice != nil || onOpenGroups != nil {
                        VStack(spacing: 12) {
                            if let onConnectDevice {
                                Button {
                                    dismiss()
                                    onConnectDevice()
                                } label: {
                                    Label("Pair a LifeLoop Device", systemImage: "wave.3.right")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(LoopStyle.green)
                                .foregroundStyle(LoopStyle.darkInk)
                                .controlSize(.large)
                            }
                            if let onOpenGroups {
                                Button {
                                    dismiss()
                                    onOpenGroups()
                                } label: {
                                    Label("Create or Join a Family Group", systemImage: "person.2.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(LoopStyle.green)
                                .controlSize(.large)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 650)
            }
            .loopPage()
            .navigationTitle("Quick Start Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
