import SwiftUI
import MapKit

struct GroupsView: View {
    @Environment(UserProfile.self) private var profile
    @State private var creating = false
    @State private var joining = false
    @State private var account = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(profile.cloudStatus).font(.callout).foregroundStyle(.secondary)
                if profile.isSignedIn {
                    HStack {
                        Button("Create family", systemImage: "plus") { creating = true }.buttonStyle(.borderedProminent)
                        Button("Join family", systemImage: "person.badge.plus") { joining = true }.buttonStyle(.bordered)
                    }
                } else {
                    Button("Sign in to your family") { account = true }.buttonStyle(.borderedProminent)
                }
                if profile.groups.isEmpty {
                    ContentUnavailableView("Your family starts here", systemImage: "person.2", description: Text("Create a family or join with an invitation code."))
                }
                ForEach(profile.groups) { group in
                    if let manager = profile.managers[group.id] {
                        NavigationLink { GroupDetailView(group: group, manager: manager) } label: {
                            HStack {
                                Image(systemName: "person.2.fill").foregroundStyle(LoopStyle.green)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.name).font(.headline)
                                    Text(profile.role(in: group.id)?.rawValue.capitalized ?? "Member").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.loopCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(24).frame(maxWidth: 720)
        }.loopPage().navigationTitle("Groups")
            .task { await profile.refreshFamilies() }
            .refreshable { await profile.refreshFamilies() }
            .sheet(isPresented: $creating) { GroupEditor(isCreating: true) }
            .sheet(isPresented: $joining) { GroupEditor(isCreating: false) }
            .sheet(isPresented: $account) { AccountSetupView { account = false } }
    }
}

struct GroupEditor: View {
    @Environment(UserProfile.self) private var profile
    @Environment(\.dismiss) private var dismiss
    let isCreating: Bool
    @State private var name = ""
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Family nickname (only on this phone)", text: $name)
                    if !isCreating {
                        TextField("Invitation code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    Text("You’ll appear as \(profile.name) to this family.")
                    Text(isCreating ? "You’ll become the creator and receive an invitation code to share." : "Your invitation code is verified before you join.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    if busy { ProgressView() }
                }.disabled(busy)
            }.loopPage().navigationTitle(isCreating ? "Create family" : "Join family")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isCreating ? "Create" : "Join") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    if isCreating { try await profile.createGroup(nickname: name) }
                                    else { try await profile.joinGroup(nickname: name, code: code) }
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(busy || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!isCreating && code.isEmpty))
                    }
                }
        }.interactiveDismissDisabled(busy)
    }
}

struct GroupDetailView: View {
    @Environment(UserProfile.self) private var profile
    @Environment(\.dismiss) private var dismiss
    let group: LoopGroup
    @ObservedObject var manager: FamilyDeviceManager
    @State private var leave = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Invite your people").font(.headline)
                    Text(group.id).font(.title2.monospaced()).textSelection(.enabled)
                    ShareLink(item: group.id) { Label("Share invitation code", systemImage: "square.and.arrow.up") }
                }.loopCard()
                NavigationLink { FamilyMembersView(group: group) } label: { Label("Members & roles", systemImage: "person.2").loopCard() }
                NavigationLink { FamilyContactsView(group: group) } label: { Label("Emergency call contacts", systemImage: "phone").loopCard() }
                NavigationLink { GroupSharingView(manager: manager) } label: { Label("Shared devices", systemImage: "slider.horizontal.3").loopCard() }
                FamilyAlertsView(manager: manager)
                MemberListSection(manager: manager, title: "Shared devices", search: "")
                Text(manager.syncStatus).font(.footnote).foregroundStyle(.secondary)
                if profile.role(in: group.id) != .creator {
                    Button("Leave family", role: .destructive) { leave = true }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(24).frame(maxWidth: 720)
        }.loopPage().navigationTitle(group.name)
            .task { await manager.refreshFamilyDevices() }
            .refreshable { await manager.refreshFamilyDevices() }
            .confirmationDialog("Leave this family? Your shared contacts and devices will be removed from this family.", isPresented: $leave, titleVisibility: .visible) {
                Button("Leave family", role: .destructive) {
                    Task {
                        do { try await profile.leaveGroup(group); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
    }
}

struct GroupSharingView: View {
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @ObservedObject var manager: FamilyDeviceManager

    var body: some View {
        Form {
            Section {
                ForEach(bleMonitor.knownDevices) { device in
                    Toggle(device.name, isOn: Binding(get: { manager.linkedDeviceIDs.contains(device.id) }, set: { desired in
                        if desired != manager.linkedDeviceIDs.contains(device.id) { manager.toggleLink(for: device) }
                    }))
                }
                if bleMonitor.knownDevices.isEmpty { Text("Connect a device in the Devices tab first.") }
            } header: { Text("Devices shared with this group") } footer: {
                Text("Profile settings control location and device information for all groups. Turning sharing off stops future updates; it does not delete records already on the server.")
            }
        }.loopPage().navigationTitle("Device sharing")
    }
}

struct MemberListSection: View {
    @ObservedObject var manager: FamilyDeviceManager
    let title: String
    let search: String

    private var members: [FamilyDeviceSnapshot] {
        manager.familyDevices.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.ownerName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            if members.isEmpty {
                Text(manager.isSyncing ? "Updating members…" : "No shared devices to show.")
                    .foregroundStyle(.secondary).loopCard()
            }
            ForEach(members) { member in
                NavigationLink {
                    MemberInfoView(memberID: member.id, manager: manager)
                } label: {
                    HStack(spacing: 16) {
                        ProfileAvatar(name: member.ownerName.isEmpty ? member.displayName : member.ownerName, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(member.ownerName.isEmpty ? member.displayName : member.ownerName).font(.headline)
                            Text(member.displayName).font(.caption).foregroundStyle(.secondary)
                            Text(member.isOnline ? "\(Int(member.bpm)) bpm · \(member.state == 0 ? "Normal" : "Needs attention")" : "Offline")
                                .font(.subheadline).foregroundStyle(member.isOnline ? LoopStyle.green : .secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.loopCard()
                }.buttonStyle(.plain)
            }
        }
    }
}

struct GroupMapSection: View {
    @ObservedObject var manager: FamilyDeviceManager
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Map {
                ForEach(manager.familyDevices) { member in
                    if member.isLocationShared && (member.latitude != 0 || member.longitude != 0) {
                        Marker(member.displayName, coordinate: CLLocationCoordinate2D(latitude: member.latitude, longitude: member.longitude))
                    }
                }
            }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }
}

struct MemberInfoView: View {
    let memberID: String
    @ObservedObject var manager: FamilyDeviceManager
    @State private var cancel = false

    private var member: FamilyDeviceSnapshot? { manager.familyDevices.first { $0.id == memberID } }

    var body: some View {
        ScrollView {
            if let member {
                VStack(alignment: .leading, spacing: 24) {
                    ProfileAvatar(name: member.ownerName, size: 100)
                        .frame(maxWidth: .infinity).padding(30)
                        .background(LoopStyle.mint, in: RoundedRectangle(cornerRadius: 24))
                    Text(member.ownerName.isEmpty ? member.displayName : member.ownerName).font(.largeTitle.bold())
                    Text(member.displayName).foregroundStyle(.secondary)
                    Label(member.isLocationShared ? manager.addressCache[member.id] ?? "Waiting for address" : "Location not shared", systemImage: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    HStack {
                        metric(member.isOnline && member.bpm > 0 ? "\(Int(member.bpm)) bpm" : "—", title: "Heart rate")
                        metric(member.isOnline ? "Online" : "Offline", title: "Connection")
                    }
                    MemberMap(name: member.displayName, latitude: member.latitude, longitude: member.longitude, shared: member.isLocationShared)
                    Text("Latest update").font(.title3.bold())
                    VStack(alignment: .leading, spacing: 8) {
                        Text(member.state == 4 ? "EMERGENCY" : member.state == 2 ? "FALL DETECTED" : member.state == 0 ? "Normal" : "Device state \(member.state)").font(.headline)
                        if let updated = member.lastUpdated {
                            Text(updated, format: .dateTime.month().day().year().hour().minute()).foregroundStyle(.secondary)
                        } else { Text("No update received").foregroundStyle(.secondary) }
                    }.loopCard()
                    FamilyAlertsView(manager: manager, deviceID: member.id)
                    Text(manager.syncStatus).font(.footnote).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 720)
            } else {
                ContentUnavailableView("Member unavailable", systemImage: "person.crop.circle.badge.questionmark")
            }
        }.loopPage().navigationTitle("Member info").navigationBarTitleDisplayMode(.inline)
            .refreshable { await manager.refreshFamilyDevices() }
            .confirmationDialog("Request cancellation for this member?", isPresented: $cancel, titleVisibility: .visible) {
                Button("Request cancellation", role: .destructive) {
                    if let member { Task { await manager.cancelEmergency(for: member) } }
                }
            }
    }

    private func metric(_ value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title3.bold())
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }.loopCard()
    }
}
