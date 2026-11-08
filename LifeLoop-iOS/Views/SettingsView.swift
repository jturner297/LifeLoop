import SwiftUI
import UserNotifications

struct ProfileView: View {
    @Environment(UserProfile.self) private var profile

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
                    NavigationLink { SettingsView() } label: { profileRow("Settings", icon: "slider.horizontal.3") }
                }.padding(.horizontal, 18).background(.white, in: RoundedRectangle(cornerRadius: 24))
            }.padding(24).frame(maxWidth: 650)
        }.loopPage().navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
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
                TextField("Phone number", text: $profile.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                TextField("Email address", text: $profile.email).keyboardType(.emailAddress)
                    .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Agree to share contact information with my groups", isOn: $profile.contactConsent)
                Text("This profile draft stays on this phone. To save a number for emergency calls, open a family’s Emergency call contacts page and explicitly add it.")
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
