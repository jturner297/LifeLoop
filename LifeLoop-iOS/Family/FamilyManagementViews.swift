import SwiftUI

struct FamilyMembersView: View {
    @Environment(UserProfile.self) private var profile
    let group: LoopGroup
    @State private var members: [CloudMember] = []
    @State private var blocked: [BlockedMember] = []
    @State private var removal: CloudMember?
    @State private var confirmRemoval = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            Section("Members") {
                ForEach(members) { member in
                    HStack {
                        ProfileAvatar(name: member.displayName, size: 40)
                        VStack(alignment: .leading) {
                            Text(member.displayName).font(.headline)
                            Text(member.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canRemove(member) {
                            Menu {
                                if profile.role(in: group.id) == .creator {
                                    Button(member.role == .admin ? "Make member" : "Make admin") {
                                        perform {
                                            _ = try await FamilyAPIClient.shared.setRole(code: group.id, userID: member.id, role: member.role == .admin ? .member : .admin)
                                        }
                                    }
                                }
                                Button("Remove & block", role: .destructive) { removal = member; confirmRemoval = true }
                            } label: { Image(systemName: "ellipsis.circle").padding(8) }
                        }
                    }
                }
            }
            if profile.role(in: group.id)?.canManage == true {
                Section("Blocked members") {
                    if blocked.isEmpty { Text("No blocked members").foregroundStyle(.secondary) }
                    ForEach(blocked) { member in
                        HStack {
                            Text(member.displayName)
                            Spacer()
                            Button("Unblock") { perform { try await FamilyAPIClient.shared.membershipAction("unblockMember", code: group.id, userID: member.id) } }
                        }
                    }
                }
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }.loopPage().navigationTitle("Members").disabled(busy)
            .task { await reload() }
            .refreshable { await reload() }
            .confirmationDialog("Remove and block this member? Their contacts and devices will also be removed.", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove & block", role: .destructive) {
                    if let removal { perform { try await FamilyAPIClient.shared.membershipAction("removeMember", code: group.id, userID: removal.id) } }
                }
            }
    }

    private func canRemove(_ member: CloudMember) -> Bool {
        guard member.id != profile.currentUserID, member.role != .creator else { return false }
        return profile.role(in: group.id) == .creator || (profile.role(in: group.id) == .admin && member.role == .member)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); await reload() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func reload() async {
        do {
            members = try await FamilyAPIClient.shared.members(code: group.id)
            if profile.role(in: group.id)?.canManage == true { blocked = try await FamilyAPIClient.shared.blockedMembers(code: group.id) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct FamilyContactsView: View {
    let group: LoopGroup
    @State private var contacts: [FamilyContact] = []
    @State private var adding = false
    @State private var editing: FamilyContact?
    @State private var deleting: FamilyContact?
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("These numbers receive a call after the emergency grace period. Only save numbers you have permission to contact.")
                    .font(.footnote).foregroundStyle(.secondary)
                if contacts.isEmpty { Text("No call contacts saved yet.") }
                ForEach(contacts) { contact in
                    Button { editing = contact } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contact.name).font(.headline)
                            Text(contact.phoneNumber).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = contact; confirmDelete = true }
                    }
                }
            } footer: { Text("Members see their own contacts. Admins can manage all contacts. A family can have up to 10.") }
            if let error { Text(error).foregroundStyle(.red) }
        }.loopPage().navigationTitle("Call contacts")
            .toolbar { Button("Add", systemImage: "plus") { adding = true } }
            .task { await reload() }.refreshable { await reload() }
            .sheet(isPresented: $adding, onDismiss: { Task { await reload() } }) { ContactEditor(group: group) }
            .sheet(item: $editing, onDismiss: { Task { await reload() } }) { ContactEditor(group: group, contact: $0) }
            .confirmationDialog("Delete this call contact?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let deleting else { return }
                    Task {
                        do { try await FamilyAPIClient.shared.deleteContact(code: group.id, contactID: deleting.id); await reload() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
    }

    private func reload() async {
        do { contacts = try await FamilyAPIClient.shared.contacts(code: group.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct ContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    let group: LoopGroup
    var contact: FamilyContact?
    @State private var name = ""
    @State private var phone = ""
    @State private var consent = false
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        phone.range(of: #"^\+[1-9]\d{7,14}$"#, options: .regularExpression) != nil && consent
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Contact name", text: $name)
                TextField("Phone, e.g. +15551234567", text: $phone).keyboardType(.phonePad)
                Toggle("I have permission to add this emergency contact", isOn: $consent)
                Text("Save sends this name and phone number to this family. Your profile contact draft is never sent automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }.loopPage().navigationTitle(contact == nil ? "Add call contact" : "Edit call contact")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    _ = try await FamilyAPIClient.shared.saveContact(code: group.id, contactID: contact?.id, name: name, phone: phone)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(!valid || busy)
                    }
                }
                .onAppear { name = contact?.name ?? ""; phone = contact?.phoneNumber ?? "" }
        }.interactiveDismissDisabled(busy)
    }
}

struct FamilyAlertsView: View {
    @ObservedObject var manager: FamilyDeviceManager
    var deviceID: String?
    @State private var cancelTarget: CloudAlert?
    @State private var confirmCancel = false

    private var displayed: [CloudAlert] { manager.alerts.filter { deviceID == nil || $0.deviceID == deviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent alerts").font(.title3.bold())
            if displayed.isEmpty { Text("No recent family alerts.").foregroundStyle(.secondary).loopCard() }
            ForEach(displayed) { alert in
                VStack(alignment: .leading, spacing: 10) {
                    Text(alert.displayName).font(.headline)
                    Text(alert.reason)
                    Text(alert.status == "PENDING" ? "Calls scheduled" : alert.status == "CANCELED" ? "Canceled" : "Call workflow started")
                        .font(.subheadline.bold()).foregroundStyle(alert.status == "PENDING" ? .red : LoopStyle.green)
                    if let date = alert.callDate { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                    if let by = alert.canceledByName { Text("Canceled by \(by)").font(.caption) }
                    if alert.status == "PENDING" {
                        Button("Request cancellation") { cancelTarget = alert; confirmCancel = true }
                        Text("Only the person who started the alert or a family admin can cancel.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.loopCard()
            }
        }
        .confirmationDialog("Cancel this alert before calls begin?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel alert", role: .destructive) {
                if let cancelTarget { Task { await manager.cancelAlert(cancelTarget) } }
            }
        }
    }
}
