import SwiftUI
import UserNotifications
import Amplify

struct ProfileView: View {
    @Environment(UserProfile.self) private var profile
    @State private var showQuickStart = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProfileAvatar(name: profile.name, size: 100).padding(.top, 32)
                Text(profile.name).font(.title.bold())
                Text("Stay In The Loop.").foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(profile.groups.count)").font(.title2.bold())
                        Text("Groups").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "person.2").foregroundStyle(LoopStyle.green)
                }.loopCard()
                VStack(spacing: 0) {
                    NavigationLink { GroupsView() } label: { profileRow("My groups", icon: "person.2") }
                    Divider()
                    NavigationLink { NotificationsView() } label: { profileRow("Notifications", icon: "bell") }
                    Divider()
                    Button { showQuickStart = true } label: { profileRow("Quick Start Guide", icon: "sparkles") }
                    Divider()
                    NavigationLink { SettingsView() } label: { profileRow("Settings", icon: "slider.horizontal.3") }
                }.padding(.horizontal, 18).background(LoopStyle.card, in: RoundedRectangle(cornerRadius: 24))
            }.padding(24).frame(maxWidth: 650)
        }.loopPage().navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showQuickStart) {
                QuickStartGuideSheet()
            }
    }

    private func profileRow(_ title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 28).foregroundStyle(LoopStyle.green)
            Text(title).foregroundStyle(LoopStyle.ink)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(.vertical, 22)
    }
}

struct SettingsView: View {
    @Environment(UserProfile.self) private var profile
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.light.rawValue
    @AppStorage("com.lifeloop.family.locationSharingEnabled") private var shareLocation = true
    @AppStorage("profile.shareDeviceInformation") private var shareDeviceInformation = true
    @State private var name = ""
    @State private var showAccountSetup = false
    @AppStorage("account.skipped") private var accountSkipped = false

    var body: some View {
        @Bindable var profile = profile
        Form {
            Section("Account") {
                Button(profile.isSignedIn ? "Manage account" : "Sign in or create an account") { showAccountSetup = true }
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Personal information") {
                TextField("Name", text: $name).textContentType(.name)
                Button("Save name") { profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == profile.name)
                Toggle("Add birthday", isOn: Binding(get: { profile.birthday != nil }, set: { profile.birthday = $0 ? Calendar.current.date(byAdding: .year, value: -18, to: Date()) : nil }))
                if profile.birthday != nil {
                    DatePicker("Birthday", selection: Binding(get: { profile.birthday ?? Date() }, set: { profile.birthday = $0 }), in: ...Date(), displayedComponents: .date)
                }
                Text("This name is used when you create or join a family. Existing family names cannot be updated by the current service.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Share location", isOn: $shareLocation)
                Toggle("Share device information", isOn: $shareDeviceInformation)
                Text("These controls apply to future uploads to all your groups. Previously shared information may remain visible until the service updates it.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(profile.groups) { group in
                    if let manager = profile.managers[group.id] {
                        NavigationLink(group.name) { GroupSharingView(manager: manager) }
                    }
                }
            } header: { Text("Privacy & sharing") }
            Section("Contact information") {
                NavigationLink("Account phone number") { AccountPhoneView().id(profile.currentUserID) }
                    .disabled(!profile.isSignedIn)
                TextField("Email address", text: $profile.email).keyboardType(.emailAddress)
                    .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Agree to share contact information with my groups", isOn: $profile.contactConsent)
                Text("Save your own number in Account phone number to link it to your account online. Family emergency call contacts are managed separately.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(profile.groups) { group in
                    LabeledContent(group.name, value: profile.contactConsent ? "Local draft" : "Consent not given")
                }
            }
            Section("Notifications") {
                NavigationLink("Phone notifications") { NotificationsView() }
            }
        }.loopPage().navigationTitle("Settings")
            .onAppear { name = profile.name }
            .sheet(isPresented: $showAccountSetup) {
                AccountSetupView { showAccountSetup = false }
            }
    }
}


/// The account ID comes from the existing sign-in session, never from typed input.
private struct AccountPhoneView: View {
    @State private var phone = ""
    @State private var record: AccountPhoneRecord?
    @State private var accountID: String?
    @State private var cloudPhone: String?
    @State private var busy = true
    @State private var message: String?
    @State private var errorMessage: String?
    private let store = AccountPhoneStore()

    private var normalizedPhone: String { PhoneNumberText.compact(phone) }

    var body: some View {
        Form {
            Section("Your account number") {
                if let record {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(cloudPhone == record.phoneNumber ? "Saved to your account" : "Saved on this device only", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline).foregroundStyle(LoopStyle.green)
                        Text(PhoneNumberText.display(record.phoneNumber))
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No number linked to this account on this device.")
                }
                PhoneNumberField(phone: $phone)
                Button("Save number") { Task { await saveNumber() } }
                    .disabled(accountID == nil || !PhoneNumberText.isValid(normalizedPhone) || normalizedPhone == cloudPhone)
                Text("Use your own number. Save links it to your signed-in account online and keeps a copy on this device. No verification text is sent.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Saving your account number does not add you to a family’s call contacts. Emergency call filtering must also be configured in the calling service.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
                Button("Reload account number") { Task { await loadAccount() } }
            }
            if busy { ProgressView() }
        }
        .disabled(busy)
        .navigationTitle("Account phone number")
        .task { await loadAccount() }
    }

    private func loadAccount() async {
        busy = true
        errorMessage = nil
        cloudPhone = nil
        message = nil
        record = nil
        phone = ""
        accountID = nil
        defer { busy = false }
        do {
            let user = try await Amplify.Auth.getCurrentUser()
            let saved = try store.load(userID: user.userId)
            accountID = user.userId
            record = saved
            phone = saved?.phoneNumber ?? ""
            let remote = try await FamilyAPIClient.shared.myPhoneNumber()
            try await checkAccount(user.userId)
            if let remote {
                guard remote.userID == user.userId else { throw phoneAccountError() }
                record = remote
                phone = remote.phoneNumber
                cloudPhone = remote.phoneNumber
                _ = try store.save(phoneNumber: remote.phoneNumber, userID: user.userId)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveNumber() async {
        guard PhoneNumberText.isValid(normalizedPhone) else { return }
        busy = true
        errorMessage = nil
        message = nil
        let number = normalizedPhone
        defer { busy = false }
        do {
            let user = try await Amplify.Auth.getCurrentUser()
            guard user.userId == accountID else {
                // Never write an old screen's draft into a newly signed-in account.
                record = nil
                phone = ""
                accountID = nil
                errorMessage = "Your account changed. Reload this page before saving."
                return
            }
            record = try store.save(phoneNumber: number, userID: user.userId)
            let remote = try await FamilyAPIClient.shared.saveMyPhoneNumber(number)
            try await checkAccount(user.userId)
            guard remote.userID == user.userId, remote.phoneNumber == number else {
                throw phoneAccountError()
            }
            record = remote
            cloudPhone = remote.phoneNumber
            message = "Number saved to your account online."
        } catch {
            errorMessage = "Online save could not be confirmed. Your local number is kept; tap Save number to retry. " + error.localizedDescription
        }
    }

    private func checkAccount(_ expectedID: String) async throws {
        let current = try await Amplify.Auth.getCurrentUser()
        guard current.userId == expectedID else {
            record = nil
            phone = ""
            cloudPhone = nil
            accountID = nil
            throw phoneAccountError()
        }
    }

    private func phoneAccountError() -> NSError {
        NSError(domain: "LifeLoop", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The account or returned phone record changed. Reload this page."
        ])
    }
}

struct NotificationsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("profile.notifications") private var enabled = false
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var errorMessage: String?
    @State private var requesting = false
    @AppStorage("notifications.statusUpdates") private var statusUpdates = true
    @AppStorage("notifications.sound") private var sound = true

    var body: some View {
        Form {
            Section {
                Toggle("Emergency notifications", isOn: Binding(get: { enabled }, set: { desired in
                    if desired {
                        Task { await enableNotifications() }
                    } else {
                        enabled = false
                        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                    }
                })).disabled(requesting)
                Toggle("Cancellation and call-workflow updates", isOn: $statusUpdates).disabled(!enabled)
                Toggle("Notification sound", isOn: $sound).disabled(!enabled)
                LabeledContent("Phone permission", value: status)
                Text("Receive family emergency alerts and status changes while LifeLoop is open and syncing. Tap a notification to open the family. Alerts when the app is closed require a push service that is not configured yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                if authorization != .notDetermined {
                    Button("Open iPhone notification settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("Send a test notification") {
                    Task {
                        let content = UNMutableNotificationContent()
                        content.title = "LifeLoop notifications are ready"
                        content.body = "Family alerts will appear here while LifeLoop is syncing."
                        if sound { content.sound = .default }
                        do {
                            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lifeloop.notification-check", content: content, trigger: nil))
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }
                }.disabled(!enabled || authorization == .denied)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            } header: { Text("Stay informed") }
        }.loopPage().navigationTitle("Notifications")
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
    }

    private var status: String {
        switch authorization {
        case .authorized: "Allowed"
        case .provisional, .ephemeral: "Quiet delivery"
        case .denied: "Disabled in iPhone settings"
        default: "Not requested"
        }
    }

    private func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization == .denied { enabled = false }
    }

    private func enableNotifications() async {
        requesting = true
        defer { requesting = false }
        do {
            enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            errorMessage = nil
            await refresh()
        } catch {
            enabled = false
            errorMessage = error.localizedDescription
        }
    }
}
