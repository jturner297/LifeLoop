import SwiftUI

private enum AppTab {
    case devices
    case family
    case map
}

struct ContentView: View {
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @State private var isShowingAddDeviceSheet = false
    @State private var selectedDevice: KnownDevice?
    @State private var selectedTab: AppTab = .devices

    // GPS Logic & Data Managers
    @StateObject private var GPS = LocationManager()
    @StateObject private var familyManager = FamilyDeviceManager()
    
    // EMS Manager
    @StateObject private var timerManager = EMSTimerManager.shared

    private let background = Color(red: 5/255, green: 15/255, blue: 29/255)
    private let surface = Color(red: 13/255, green: 27/255, blue: 43/255)
    private let primaryText = Color(red: 235/255, green: 241/255, blue: 246/255)
    private let secondaryText = Color(red: 119/255, green: 135/255, blue: 151/255)
    private let teal = Color(red: 0/255, green: 210/255, blue: 174/255)
    private let blue = Color(red: 24/255, green: 126/255, blue: 255/255)
    private let warning = Color(red: 255/255, green: 194/255, blue: 86/255)

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .devices:
                    dashboardView
                case .family:
                    FamilyDevicesView(
                        familyManager: familyManager,
                        localDevices: bleMonitor.knownDevices,
                        deviceStatuses: bleMonitor.deviceStatuses,
                        background: background,
                        surface: surface,
                        primaryText: primaryText,
                        secondaryText: secondaryText,
                        teal: teal,
                        warning: warning
                    )
                case .map:
                    MapScreen(
                        targetLat: GPS.latitude,
                        targetLon: GPS.longitude,
                        statusText: GPS.statusText,
                        familyDevices: familyManager.familyDevices
                    )
                }
            }
            .sheet(isPresented: $isShowingAddDeviceSheet) {
                AddDeviceSheet(
                    bleMonitor: bleMonitor,
                    background: background,
                    surface: surface,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    teal: teal
                )
            }
            .sheet(item: $selectedDevice) { device in
                DeviceProfileSheet(
                    device: device,
                    bleMonitor: bleMonitor,
                    background: background,
                    surface: surface,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    teal: teal,
                    warning: warning
                )
            }

            tabBar
        }
        .onChange(of: timerManager.isActive) { isEmergency in
            if isEmergency {
                isShowingAddDeviceSheet = false
                selectedDevice = nil
            }
        }
        .fullScreenCover(isPresented: $timerManager.isActive){
            EMSCountdown(timerManager: timerManager)
        }
        .preferredColorScheme(.dark)
        .onReceive(timer) { _ in
            bleMonitor.checkOfflineDevices()
            familyManager.uploadLocalDevices(
                bleMonitor.knownDevices,
                statuses: bleMonitor.deviceStatuses,
                fallbackLatitude: GPS.latitude,
                fallbackLongitude: GPS.longitude
            )
            Task {
                await familyManager.refreshFamilyDevices(force: false)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            tabButton(title: "Devices", systemImage: "wave.3.right", tab: .devices)
            tabButton(title: "Family", systemImage: "person.2", tab: .family)
            tabButton(title: "Map", systemImage: "map", tab: .map)
        }
        .padding(8)
        .background(surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func tabButton(title: String, systemImage: String, tab: AppTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(selectedTab == tab ? background : primaryText)
                .background(selectedTab == tab ? teal : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var dashboardView: some View {
        ZStack(alignment: .bottomTrailing) {
            background.ignoresSafeArea()

            List {
                headerSection
                devicesSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(background)

            Button(action: showAddDeviceSheet) {
                Image(systemName: bleMonitor.isScanning ? "wave.3.right" : "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(background)
                    .frame(width: 56, height: 56)
                    .background(teal)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 86)
            .accessibilityLabel("Add LifeLoop device")
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 28)

                ECGWaveform(color: teal)
                    .frame(height: 86)
                    .padding(.top, 22)
            }
            .listRowBackground(background)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
    }

    private var devicesSection: some View {
        Section {
            if bleMonitor.knownDevices.isEmpty {
                emptyDeviceRow
                    .listRowBackground(background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            } else {
                ForEach(bleMonitor.knownDevices) { device in
                    deviceRow(for: device)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                bleMonitor.removeKnownDevice(device)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .listRowBackground(background)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
            }
        } header: {
            Text("Devices")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(primaryText)
                .textCase(nil)
                .padding(.top, 8)
                .padding(.leading, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)

            Text(attentionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
            
            // Current GPS coordinates displayed in header
            Text(GPS.currentAddress)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(teal)
                .padding(.top, 2)
        }
    }

    private var emptyDeviceRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(secondaryText.opacity(0.55))
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text("No saved LifeLoop devices")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryText)

                Text("Tap + to scan and add one")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(secondaryText)
            }

            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good Morning" }
        if hour < 17 { return "Good Afternoon" }
        return "Good Evening"
    }

    private func coordinateText(_ coordinate: Double?) -> String {
        guard let coordinate else { return "Waiting" }
        return String(format: "%.4f", coordinate)
    }

    private var attentionText: String {
        let connectedCount = bleMonitor.deviceStatuses.values.filter { $0.isConnected }.count
        let totalCount = bleMonitor.knownDevices.count
        if totalCount == 0 { return "No devices added" }
        return "\(connectedCount) of \(totalCount) devices connected"
    }

    private var connectionColor: Color {
        if bleMonitor.isConnected { return teal }
        if bleMonitor.isScanning { return warning }
        return secondaryText
    }

    private func deviceRow(for device: KnownDevice) -> some View {
        let status = bleMonitor.deviceStatuses[device.id] ?? DeviceStatus(deviceID: device.id, name: device.name)
        let accent = status.isConnected ? teal : (status.isConnecting ? warning : secondaryText)

        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text(status.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if status.isConnecting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(teal)
                    }

                    Text(statusText(for: status))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(metricText(for: status))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status.isConnected ? teal : secondaryText)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 12)
        .onTapGesture {
            selectedDevice = device
        }
    }

    private func statusText(for status: DeviceStatus) -> String {
        if status.isConnecting { return "Connecting" }
        if status.isConnected { return "Connected" }
        return "Offline"
    }

    private func metricText(for status: DeviceStatus) -> String {
        guard status.isConnected else { return "--" }
        let bpm = Int(status.lifeLoopState.bpm.rounded())
        return bpm > 0 ? "\(bpm) bpm" : "Connected"
    }

    private func showAddDeviceSheet() {
        isShowingAddDeviceSheet = true
        bleMonitor.startScanning()
    }

}

private struct DeviceProfileSheet: View {
    let device: KnownDevice
    @ObservedObject var bleMonitor: BLEMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var deviceName: String
    @State private var isLogExpanded = false

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

                Section("BLE Data") {
                    telemetryRow(title: "BPM", value: bpmText)
                    telemetryRow(title: "State", value: "\(status.lifeLoopState.state)")
                    telemetryRow(title: "Latitude", value: coordinateText(status.lifeLoopState.latitude))
                    telemetryRow(title: "Longitude", value: coordinateText(status.lifeLoopState.longitude))
                    telemetryRow(title: "Last Update", value: lastUpdatedText)
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
        .preferredColorScheme(.dark)
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

private struct AddDeviceSheet: View {
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
        .preferredColorScheme(.dark)
        .onAppear {
            if !bleMonitor.isScanning {
                bleMonitor.startScanning()
            }
        }
    }
}

private struct ECGWaveform: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let mid = height * 0.52

            Path { path in
                let points: [(CGFloat, CGFloat)] = [
                    (0.00, 0.52), (0.11, 0.52), (0.13, 0.50), (0.15, 0.50),
                    (0.17, 0.23), (0.185, 0.75), (0.205, 0.47), (0.24, 0.52),
                    (0.40, 0.52), (0.42, 0.50), (0.44, 0.50), (0.46, 0.23),
                    (0.475, 0.75), (0.495, 0.47), (0.53, 0.52), (0.70, 0.52),
                    (0.72, 0.50), (0.74, 0.50), (0.76, 0.23), (0.775, 0.75),
                    (0.795, 0.47), (0.83, 0.52), (1.00, 0.52)
                ]

                guard let first = points.first else { return }
                path.move(to: CGPoint(x: first.0 * width, y: first.1 * height))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.0 * width, y: point.1 * height))
                }
            }
            .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .position(x: width * 0.28, y: mid)
                .shadow(color: color.opacity(0.5), radius: 4)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEMonitor())
}
