import SwiftUI

struct ContentView: View {
    @Environment(UserProfile.self) private var profile
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @StateObject private var gps = LocationManager()
    @StateObject private var timer = EMSTimerManager.shared
    @State private var notifications = LoopNotifications.shared
    @State private var notificationGroup: LoopGroup?
    @State private var cancellationMessage = ""
    @State private var showCancellationMessage = false
    @State private var tab = 0
    @State private var search = ""
    @State private var filter = 0
    @State private var addDevice = false
    @State private var selectedDevice: KnownDevice?
    @State private var emergencyDeliveryMessage = "Sending an alert to your connected family…"
    @State private var emergencyDeliveryTitle = "Sending alert"
    @State private var emergencyTask: Task<Void, Never>?
    @State private var emergencyRecipients: [FamilyDeviceManager] = []
    @State private var emergencyDeviceID: String?
    @State private var emergencySessionID = UUID()
    @State private var isClosingEmergency = false

    private var matchingDevices: [KnownDevice] {
        bleMonitor.knownDevices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { home }
                .tabItem { Label { Text("Home") } icon: { Image(uiImage: LifeLoopBrand.tabIcon).renderingMode(.original) } }.tag(0)
            NavigationStack { devices }
                .tabItem { Label("Devices", systemImage: "wave.3.right") }.tag(1)
            NavigationStack { GroupsView() }
                .tabItem { Label("Groups", systemImage: "person.2") }.tag(2)
            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person") }.tag(3)
        }
        .tint(LoopStyle.green)
        .sheet(isPresented: $addDevice) {
            AddDeviceSheet(bleMonitor: bleMonitor, background: LoopStyle.background, surface: .white, primaryText: LoopStyle.ink, secondaryText: .secondary, teal: LoopStyle.green)
        }
        .sheet(item: $selectedDevice) { device in
            DeviceProfileSheet(device: device, bleMonitor: bleMonitor, background: LoopStyle.background, surface: .white, primaryText: LoopStyle.ink, secondaryText: .secondary, teal: LoopStyle.green, warning: .orange)
        }
        .fullScreenCover(isPresented: Binding(
            get: { timer.isActive || timer.isAlertTriggered },
            set: { _ in }
        )) {
            if timer.isAlertTriggered {
                SOSAlertStatusView(title: emergencyDeliveryTitle, message: emergencyDeliveryMessage, onClose: closeEmergency)
                    .interactiveDismissDisabled()
            } else {
                EMSCountdown(timerManager: timer, onCancel: closeEmergency).interactiveDismissDisabled()
            }
        }
        .onChange(of: timer.isCountingDown) { _, counting in
            if counting { sendEmergency() }
        }
        .onChange(of: notifications.selectedGroupCode) { _, code in
            guard let code else { return }
            tab = 2
            notificationGroup = profile.groups.first { $0.id == code }
            notifications.selectedGroupCode = nil
        }
        .sheet(item: $notificationGroup) { group in
            if let manager = profile.managers[group.id] {
                NavigationStack { GroupDetailView(group: group, manager: manager) }
            }
        }
        .alert("Cancellation status", isPresented: $showCancellationMessage) {
            Button("OK", role: .cancel) {}
        } message: { Text(cancellationMessage) }
        .task {
            while !Task.isCancelled {
                await profile.refreshFamilies(force: false)
                if let code = notifications.selectedGroupCode, let group = profile.groups.first(where: { $0.id == code }) {
                    tab = 2
                    notificationGroup = group
                    notifications.selectedGroupCode = nil
                }
                bleMonitor.checkOfflineDevices()
                for manager in profile.managers.values {
                    manager.uploadLocalDevices(bleMonitor.knownDevices, statuses: bleMonitor.deviceStatuses, fallbackLatitude: gps.latitude, fallbackLongitude: gps.longitude)
                    await manager.refreshFamilyDevices(force: false)
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image("LifeLoopLogo").resizable().scaledToFit().frame(width: 52, height: 52).accessibilityLabel("LifeLoop")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(greeting).font(.subheadline).foregroundStyle(.secondary)
                        Text(profile.name).font(.title2.bold())
                    }
                    Spacer()
                    Button { tab = 3 } label: { ProfileAvatar(name: profile.name) }
                        .accessibilityLabel("Open profile")
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search member or device", text: $search)
                }.loopCard()
                if !profile.isSignedIn {
                    Text("Sign in from Profile to connect with your family. Your Bluetooth devices still work here.").font(.footnote).foregroundStyle(.secondary)
                }
                Picker("Show", selection: $filter) {
                    Text("Home").tag(0)
                    Text("Family").tag(1)
                    Text("Map").tag(2)
                }.pickerStyle(.segmented)
                if filter == 2 {
                    ForEach(profile.groups) { group in
                        if let manager = profile.managers[group.id] {
                            GroupMapSection(manager: manager, title: group.name)
                        }
                    }
                    if profile.groups.isEmpty {
                        ContentUnavailableView("No shared locations yet", systemImage: "map", description: Text("Join a group to see your people on the map."))
                    }
                } else {
                    if filter == 0 {
                        HStack {
                            Text("Devices").font(.title3.bold())
                            Spacer()
                            Button("See all") { tab = 1 }
                        }
                        emergencyButton
                        localDeviceCards
                    }
                    ForEach(profile.groups) { group in
                        if let manager = profile.managers[group.id] {
                            MemberListSection(manager: manager, title: group.name, search: search)
                        }
                    }
                    if filter == 1 && profile.groups.isEmpty {
                        Button { tab = 2 } label: {
                            Label("Join your first group", systemImage: "person.2.badge.plus").loopCard()
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 720)
        }
        .loopPage().toolbar(.hidden, for: .navigationBar)
    }

    private var devices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Your LifeLoop devices, connected to this phone.").foregroundStyle(.secondary)
                Text(bleMonitor.bluetoothStateText).font(.footnote).foregroundStyle(LoopStyle.green)
                localDeviceCards
                Button { addDevice = true } label: {
                    Label("Connect a device", systemImage: "plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(24).frame(maxWidth: 720)
        }.loopPage().navigationTitle("Devices")
    }

    @ViewBuilder private var localDeviceCards: some View {
        if matchingDevices.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No devices connected yet" : "No matching devices", systemImage: "wave.3.right", description: Text("Connect a LifeLoop device to see heart rate, battery, and connection details."))
        }
        ForEach(matchingDevices) { device in
            let status = bleMonitor.deviceStatuses[device.id]
            Button { selectedDevice = device } label: {
                HStack(spacing: 16) {
                    Image(systemName: "wave.3.right")
                        .font(.title2).foregroundStyle(LoopStyle.green)
                        .frame(width: 64, height: 72)
                        .background(LoopStyle.mint, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status?.name ?? device.name).font(.headline)
                        Text(status?.isConnected == true ? "\(Int(status?.lifeLoopState.bpm ?? 0)) bpm" : "—").font(.subheadline)
                        Text(status?.isConnected == true ? "Connected" : status?.isConnecting == true ? "Connecting…" : "Offline")
                            .font(.caption).foregroundStyle(.secondary)
                        if let status, status.isConnected, status.lifeLoopState.battery <= 10 {
                            Label("Battery low · \(status.lifeLoopState.battery)%", systemImage: "battery.0").font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.loopCard()
            }.buttonStyle(.plain)
        }
    }

    private var emergencyButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if timer.isAlertTriggered {
                    closeEmergency()
                } else {
                    timer.startCountdown(reason: "MANUAL SOS")
                    bleMonitor.sendSOSCommand()
                }
            } label: {
                Label(timer.isAlertTriggered ? "Cancel emergency alert" : "Call Help", systemImage: timer.isAlertTriggered ? "xmark.circle" : "phone")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).tint(timer.isAlertTriggered ? .red : LoopStyle.green)
                .disabled(isClosingEmergency)
            if isClosingEmergency { ProgressView("Sending cancellation…") }
            if timer.isAlertTriggered {
                Text(profile.groups.isEmpty ? "No group is available to notify." : "Check your group’s sync status for alert delivery.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
    }

    private func sendEmergency() {
        let sessionID = UUID()
        emergencySessionID = sessionID
        let recipients = Array(profile.managers.values)
        let deviceID = bleMonitor.knownDevices.first?.id
        let ownerName = profile.name
        let latitude = gps.latitude
        let longitude = gps.longitude
        let reason = timer.triggerReason
        emergencyRecipients = recipients
        emergencyDeviceID = deviceID
        emergencyDeliveryTitle = recipients.isEmpty ? "No family group connected" : "Sending alert"
        emergencyDeliveryMessage = recipients.isEmpty
            ? "No alert was sent. Add a family group from the Groups tab."
            : "Sending an alert to your connected family…"
        for manager in recipients { manager.beginEmergencySession() }
        emergencyTask = Task {
            var sent = 0
            for manager in recipients {
                if await manager.sendMyEmergencyAlert(deviceID: deviceID, displayName: ownerName, latitude: latitude, longitude: longitude, reason: reason) {
                    sent += 1
                }
            }
            guard emergencySessionID == sessionID, timer.isActive || timer.isAlertTriggered, !recipients.isEmpty else { return }
            if let deadline = recipients.compactMap({ $0.activeAlert?.callDate }).min(), timer.isActive {
                timer.synchronizeCallDeadline(deadline)
            }
            if sent == recipients.count {
                emergencyDeliveryTitle = "Alert sent"
                emergencyDeliveryMessage = "Your family alerts were accepted. The service will call saved contacts after its grace period. Calls already started cannot be canceled."
            } else if sent > 0 {
                emergencyDeliveryTitle = "Alert partially sent"
                emergencyDeliveryMessage = "Some family groups received the alert. Delivery to other groups could not be confirmed. Check their recent alerts."
            } else {
                emergencyDeliveryTitle = "Delivery unconfirmed"
                emergencyDeliveryMessage = "We could not confirm delivery. Check your connection and family alerts. No delayed SOS will be replayed automatically."
            }
        }
    }

    private func closeEmergency() {
        emergencySessionID = UUID()
        isClosingEmergency = true
        let delivery = emergencyTask
        let recipients = emergencyRecipients
        let deviceID = emergencyDeviceID
        let ownerName = profile.name
        bleMonitor.sendCancelCommand()
        timer.cancelCountdown()
        tab = 0
        filter = 0
        search = ""
        // Send cancellation after the in-flight alert to preserve ordering.
        Task {
            await delivery?.value
            for manager in recipients {
                await manager.cancelMyOwnEmergency(deviceID: deviceID, displayName: ownerName)
            }
            let failures = recipients.compactMap { $0.emergencyError }
            if !failures.isEmpty {
                cancellationMessage = failures.joined(separator: "\n")
                showCancellationMessage = true
            }
            isClosingEmergency = false
        }
    }
}
struct DeviceProfileSheet: View {
    let device: KnownDevice
    @ObservedObject var bleMonitor: BLEMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var deviceName: String
    @State private var isLogExpanded = false
    @State private var removeDevice = false

    let background: Color
    let surface: Color
    let primaryText: Color
    let secondaryText: Color
    let teal: Color
    let warning: Color

    init(
        device: KnownDevice,
        bleMonitor: BLEMonitor,
        background: Color,
        surface: Color,
        primaryText: Color,
        secondaryText: Color,
        teal: Color,
        warning: Color
    ) {
        self.device = device
        self.bleMonitor = bleMonitor
        self.background = background
        self.surface = surface
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.teal = teal
        self.warning = warning
        _deviceName = State(initialValue: device.name)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    TextField("Device name", text: $deviceName)
                        .textInputAutocapitalization(.words)
                        .listRowBackground(surface)

                    Button("Save Name") {
                        bleMonitor.renameKnownDevice(device, name: deviceName)
                    }
                    .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .listRowBackground(surface)
                }

                Section("Connection") {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(statusText)
                            .foregroundStyle(primaryText)
                        Spacer()
                    }
                    .listRowBackground(surface)

                    Button(action: toggleConnection) {
                        Label(connectionButtonTitle, systemImage: connectionButtonImage)
                    }
                    .disabled(status.isConnecting)
                    .listRowBackground(surface)
                }

                Section("Location") {
                    MemberMap(name: status.name, latitude: status.lifeLoopState.latitude, longitude: status.lifeLoopState.longitude, shared: true)
                        .listRowInsets(EdgeInsets())
                }

                Section("Device information") {
                    telemetryRow(title: "Battery", value: status.lastUpdated == nil ? "—" : "\(status.lifeLoopState.battery)%")
                    telemetryRow(title: "BPM", value: bpmText)
                    telemetryRow(title: "State", value: "\(status.lifeLoopState.state)")
                    telemetryRow(title: "Latitude", value: coordinateText(status.lifeLoopState.latitude))
                    telemetryRow(title: "Longitude", value: coordinateText(status.lifeLoopState.longitude))
                    telemetryRow(title: "Last Update", value: lastUpdatedText)
                }

                Section {
                    Button("Remove device", role: .destructive) { removeDevice = true }
                }
                Section("Raw Payload") {
                    Text(status.lastPayload.isEmpty ? "No BLE data received yet" : status.lastPayload)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(status.lastPayload.isEmpty ? secondaryText : primaryText)
                        .textSelection(.enabled)
                        .listRowBackground(surface)
                }

                Section {
                    DisclosureGroup(isExpanded: $isLogExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            if bleMonitor.connectionLog.isEmpty {
                                Text("No connection events yet")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(secondaryText)
                            } else {
                                ForEach(bleMonitor.connectionLog, id: \.self) { entry in
                                    Text(entry)
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundStyle(secondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Connection Log")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(primaryText)
                    }
                    .tint(teal)
                    .listRowBackground(surface)
                }
            }
            .confirmationDialog("Remove this device from your phone?", isPresented: $removeDevice, titleVisibility: .visible) {
                Button("Remove device", role: .destructive) {
                    bleMonitor.removeKnownDevice(device)
                    dismiss()
                }
            }
            .navigationTitle(currentDevice?.name ?? device.name)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var currentDevice: KnownDevice? {
        bleMonitor.knownDevices.first(where: { $0.id == device.id })
    }

    private var status: DeviceStatus {
        bleMonitor.deviceStatuses[device.id] ?? DeviceStatus(deviceID: device.id, name: currentDevice?.name ?? device.name)
    }

    private var statusText: String {
        if status.isConnecting { return "Connecting" }
        if status.isConnected { return "Connected" }
        return "Offline"
    }

    private var statusColor: Color {
        if status.isConnected { return teal }
        if status.isConnecting { return warning }
        return secondaryText
    }

    private var connectionButtonTitle: String {
        status.isConnected ? "Disconnect" : "Reconnect"
    }

    private var connectionButtonImage: String {
        status.isConnected ? "xmark.circle" : "dot.radiowaves.left.and.right"
    }

    private var bpmText: String {
        let bpm = status.lifeLoopState.bpm
        return bpm > 0 ? String(format: "%.1f", bpm) : "--"
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = status.lastUpdated else { return "Never" }
        return DateFormatter.localizedString(from: lastUpdated, dateStyle: .none, timeStyle: .medium)
    }

    private func coordinateText(_ coordinate: Double) -> String {
        coordinate == 0 ? "--" : String(format: "%.6f", coordinate)
    }

    private func telemetryRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(primaryText)
        }
        .listRowBackground(surface)
    }

    private func toggleConnection() {
        if status.isConnected {
            bleMonitor.disconnect(deviceID: device.id)
        } else {
            bleMonitor.connect(toKnown: currentDevice ?? device)
        }
    }
}

struct AddDeviceSheet: View {
    @ObservedObject var bleMonitor: BLEMonitor
    @Environment(\.dismiss) private var dismiss

    let background: Color
    let surface: Color
    let primaryText: Color
    let secondaryText: Color
    let teal: Color

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(bleMonitor.isScanning ? teal : secondaryText)
                            .frame(width: 10, height: 10)

                        Text(bleMonitor.bluetoothStateText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(secondaryText)

                        Spacer()

                        Button(bleMonitor.isScanning ? "Stop" : "Scan") {
                            if bleMonitor.isScanning {
                                bleMonitor.stopScanning()
                            } else {
                                bleMonitor.startScanning()
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    .listRowBackground(surface)
                }

                Section {
                    if bleMonitor.discoveredPeripherals.isEmpty {
                        Text("Scanning for nearby LifeLoop devices")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(secondaryText)
                            .listRowBackground(surface)
                    } else {
                        ForEach(bleMonitor.discoveredPeripherals) { peripheral in
                            Button {
                                bleMonitor.addKnownDevice(peripheral)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(peripheral.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(primaryText)

                                        Text(peripheral.id.uuidString)
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundStyle(secondaryText)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text("\(peripheral.rssi) dBm")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(teal)
                                        .monospacedDigit()
                                }
                            }
                            .listRowBackground(surface)
                        }
                    }
                } header: {
                    Text("Nearby")
                        .foregroundStyle(secondaryText)
                }
            }
            .navigationTitle("Add a Device")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.light)
        .onDisappear { bleMonitor.stopScanning() }
        .onAppear {
            if !bleMonitor.isScanning {
                bleMonitor.startScanning()
            }
        }
    }
}

