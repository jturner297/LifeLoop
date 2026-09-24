import SwiftUI
import MapKit

struct FamilyDevicesView: View {
    @ObservedObject var familyManager: FamilyDeviceManager
    let localDevices: [KnownDevice]
    let deviceStatuses: [String: DeviceStatus]
    let background: Color
    let surface: Color
    let primaryText: Color
    let secondaryText: Color
    let teal: Color
    let warning: Color

    var body: some View {
        NavigationStack {
            List {
                groupSection
                locationSharingSection
                linkedDevicesSection
                remoteDevicesSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(background)
            .task {
                await familyManager.refreshFamilyDevices()
            }
            .refreshable {
                await familyManager.refreshFamilyDevices()
            }
            .navigationTitle("Family")
        }
    }

    private var groupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Family Group")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primaryText)

                HStack(spacing: 8) {
                    TextField("Group code", text: $familyManager.groupCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(primaryText)
                        .padding(10)
                        .background(background)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Button("Save") {
                        familyManager.saveGroupCode()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(teal)
                }

                Text(familyManager.syncStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryText)
            }
            .padding(.vertical, 8)
            .listRowBackground(surface)
            .listRowSeparator(.hidden)
        }
    }

    private var locationSharingSection: some View {
        Section {
            Toggle(isOn: $familyManager.isLocationSharingEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share Map Location")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primaryText)

                    Text("Uses LifeLoop GPS first, then this phone's location")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(secondaryText)
                }
            }
            .tint(teal)
            .listRowBackground(surface)
        } header: {
            Text("Find My Family")
                .foregroundStyle(secondaryText)
        }
    }

    private var linkedDevicesSection: some View {
        Section {
            if localDevices.isEmpty {
                Text("Add a LifeLoop device before sharing with family")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .listRowBackground(surface)
            } else {
                ForEach(localDevices) { device in
                    let status = deviceStatuses[device.id]
                    Toggle(isOn: binding(for: device)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status?.name ?? device.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(primaryText)

                            Text(statusLine(for: status))
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(secondaryText)
                        }
                    }
                    .tint(teal)
                    .listRowBackground(surface)
                }
            }
        } header: {
            Text("Share My Devices")
                .foregroundStyle(secondaryText)
        }
    }

    private var remoteDevicesSection: some View {
        Section {
            if familyManager.familyDevices.isEmpty {
                Text(familyManager.hasGroup ? "No family devices found yet" : "Save a group code to view family devices")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .listRowBackground(surface)
            } else {
                ForEach(familyManager.familyDevices) { device in
                    NavigationLink(destination: FamilyMemberDetailView(device: device, address: familyManager.addressCache[device.id] ?? locationText(for: device), primaryText: primaryText, secondaryText: secondaryText, teal: teal, surface: surface, background: background)) {
                        familyDeviceRow(device)
                    }
                    .onAppear { familyManager.resolveAddress(for: device) }
                }
            }
        } header: {
            HStack {
                Text("Family Devices")
                    .foregroundStyle(secondaryText)
                Spacer()
                if familyManager.isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    private func familyDeviceRow(_ device: FamilyDeviceSnapshot) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(device.isOnline ? teal : warning)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryText)

                Text("\(device.ownerName) • \(lastUpdatedText(device.lastUpdated))")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(secondaryText)

                Text(locationText(for: device))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(device.isLocationShared ? teal : secondaryText)
            }

            Spacer()

            Text(device.bpm > 0 ? "\(Int(device.bpm.rounded())) bpm" : "--")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(device.isOnline ? teal : secondaryText)
        }
        .padding(.vertical, 6)
    }

    private func binding(for device: KnownDevice) -> Binding<Bool> {
        Binding(
            get: { familyManager.linkedDeviceIDs.contains(device.id) },
            set: { _ in familyManager.toggleLink(for: device) }
        )
    }

    private func statusLine(for status: DeviceStatus?) -> String {
        guard let status else { return "Offline" }
        if status.isConnecting { return "Connecting" }
        if status.isConnected { return "Connected" }
        return "Offline"
    }

    private func lastUpdatedText(_ date: Date?) -> String {
        guard let date else { return "Never updated" }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    private func locationText(for device: FamilyDeviceSnapshot) -> String {
        if let cached = familyManager.addressCache[device.id], !cached.isEmpty {
            return cached
        }
        guard device.isLocationShared,
              device.latitude != 0 || device.longitude != 0 else {
            return "Location hidden"
        }
        return String(format: "%.5f, %.5f", device.latitude, device.longitude)
    }
}

struct FamilyMemberDetailView: View {
    let device: FamilyDeviceSnapshot
    let address: String
    let primaryText: Color
    let secondaryText: Color
    let teal: Color
    let surface: Color
    let background: Color

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.displayName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Text("Owner: \(device.ownerName)")
                            .font(.system(size: 13))
                            .foregroundStyle(secondaryText)
                        Text("Last updated: \(lastUpdatedText(device.lastUpdated))")
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(device.bpm > 0 ? "\(Int(device.bpm.rounded())) bpm" : "--")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(teal)
                        Text(statusText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(device.isOnline ? teal : secondaryText)
                    }
                }
            }
            .listRowBackground(surface)

            Section("Location") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(address)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(String(format: "%.5f, %.5f", device.latitude, device.longitude))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(secondaryText)
                }
            }
            .listRowBackground(surface)
        }
        .navigationTitle(device.ownerName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(background)
    }

    private var statusText: String {
        device.isOnline ? "Online" : "Offline"
    }

    private func lastUpdatedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
