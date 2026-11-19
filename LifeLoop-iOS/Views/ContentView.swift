import SwiftUI

struct ContentView: View {
    @Environment(UserProfile.self) private var profile
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @Environment(\.openURL) private var openURL
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.light.rawValue
    @ScaledMetric(relativeTo: .title) private var wearerMetricFontSize: CGFloat = 28
    @StateObject private var gps = LocationManager()
    @StateObject private var timer = EMSTimerManager.shared
    @State private var notifications = LoopNotifications.shared
    @State private var notificationGroup: LoopGroup?
    @State private var cancellationMessage = ""
    @State private var showCancellationAlert = false
    @State private var tab = 0
    @State private var search = ""
    @State private var filter = 0
    @State private var addDevice = false
    @State private var showQuickStart = false
    @State private var showWearerFamilySheet = false
    @State private var showWearerAccountSheet = false
    @State private var showWearerSettingsSheet = false
    @State private var openAddDeviceAfterWearerSettings = false
    @State private var devicePendingSleep: KnownDevice?
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
        Group {
            if profile.accountRole == .wearer {
                NavigationStack {
                    wearerDashboard
                }
            } else {
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
            }
        }
        .tint(LoopStyle.green)
        .sheet(isPresented: $addDevice) {
            AddDeviceSheet(bleMonitor: bleMonitor, background: LoopStyle.background, surface: LoopStyle.card, primaryText: LoopStyle.ink, secondaryText: .secondary, teal: LoopStyle.green)
        }
        .sheet(isPresented: $showQuickStart) {
            QuickStartGuideSheet(
                onConnectDevice: { addDevice = true },
                onOpenGroups: {
                    if profile.accountRole == .wearer {
                        showWearerFamilySheet = true
                    } else {
                        tab = 2
                    }
                }
            )
        }
        .sheet(isPresented: $showWearerFamilySheet) {
            NavigationStack {
                GroupsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showWearerFamilySheet = false }
                        }
                    }
            }
            .environment(profile)
            .environmentObject(bleMonitor)
        }
        .sheet(isPresented: $showWearerAccountSheet) {
            AccountSetupView { showWearerAccountSheet = false }
                .environment(profile)
        }
        .sheet(isPresented: $showWearerSettingsSheet, onDismiss: {
            if openAddDeviceAfterWearerSettings {
                openAddDeviceAfterWearerSettings = false
                addDevice = true
            }
        }) {
            WearerSettingsSheet {
                openAddDeviceAfterWearerSettings = true
            }
            .environment(profile)
            .environmentObject(bleMonitor)
        }
        .confirmationDialog(
            "Turn Watch Off (Sleep Mode)?",
            isPresented: Binding(
                get: { devicePendingSleep != nil },
                set: { if !$0 { devicePendingSleep = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Turn Watch Off", role: .destructive) {
                if let device = devicePendingSleep {
                    bleMonitor.sendSleepCommand(deviceID: device.id)
                }
                devicePendingSleep = nil
            }
            Button("Keep Watch On", role: .cancel) {
                devicePendingSleep = nil
            }
        } message: {
            Text("Fall detection and heart rate monitoring will pause until you turn the watch back on.")
        }
        .sheet(item: $selectedDevice) { device in
            DeviceProfileSheet(
                device: device,
                bleMonitor: bleMonitor,
                background: LoopStyle.background,
                surface: LoopStyle.card,
                primaryText: LoopStyle.ink,
                secondaryText: .secondary,
                teal: LoopStyle.green,
                warning: .orange,
                onRemove: { removeDevice(device) }
            )
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
        .onChange(of: bleMonitor.pingAckSequence) { _, _ in
            for manager in profile.managers.values {
                manager.uploadLocalDevices(bleMonitor.knownDevices, statuses: bleMonitor.deviceStatuses, fallbackLatitude: gps.latitude, fallbackLongitude: gps.longitude)
            }
        }
        .onChange(of: bleMonitor.cancellationRequest) { _, request in
            guard let request, timer.isActive || timer.isAlertTriggered else { return }
            // Only the originating device can cancel a device-triggered emergency.
            // Any connected saved device can cancel a manual app SOS.
            guard timer.triggerDeviceID == nil || timer.triggerDeviceID == request.deviceID else { return }
            closeEmergency()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lifeLoopCancelEmergencyFromNotification)) { _ in
            if timer.isActive || timer.isAlertTriggered {
                closeEmergency()
            }
        }
        .onChange(of: notifications.selectedGroupCode) { _, newValue in
            guard newValue != nil else { return }
            Task { @MainActor in
                routePendingNotification()
            }
        }
        .sheet(item: $notificationGroup) { group in
            NavigationStack {
                if let manager = profile.managers[group.id] {
                    GroupDetailView(group: group, manager: manager)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { notificationGroup = nil }
                            }
                        }
                } else {
                    ProgressView("Loading family…")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { notificationGroup = nil }
                            }
                        }
                }
            }
            .environment(profile)
            .environmentObject(bleMonitor)
        }
        .alert("Cancellation Unconfirmed", isPresented: $showCancellationAlert) {
            Button("Retry Cancellation") { closeEmergency() }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(cancellationMessage.isEmpty ? "The cloud service could not confirm cancellation. Saved contacts may still be notified." : cancellationMessage + "\n\nSaved contacts may still be notified if cancellation cannot be confirmed.")
        }
        .task {
            timer.onImmediateTrigger = { _ in
                sendEmergency()
            }
            if timer.isCountingDown && emergencyRecipients.isEmpty {
                sendEmergency()
            }
            while !Task.isCancelled {
                await profile.refreshFamilies(force: false)
                routePendingNotification()
                bleMonitor.checkOfflineDevices()
                for manager in profile.managers.values {
                    manager.uploadLocalDevices(bleMonitor.knownDevices, statuses: bleMonitor.deviceStatuses, fallbackLatitude: gps.latitude, fallbackLongitude: gps.longitude)
                    await manager.refreshFamilyDevices(force: false)
                }
                // A confirmed cancellation from every notified group ends the local warning.
                if !emergencyRecipients.isEmpty,
                   emergencyRecipients.allSatisfy({ $0.activeAlert?.status == "CANCELED" }),
                   timer.isActive || timer.isAlertTriggered {
                    emergencyTask = nil
                    bleMonitor.sendCancelCommand()
                    timer.cancelCountdown()
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func routePendingNotification() {
        // Keep cold-launch taps pending until membership loads and other presentations finish.
        guard let code = notifications.selectedGroupCode,
              !timer.isActive, !timer.isAlertTriggered,
              !addDevice, selectedDevice == nil,
              let group = profile.groups.first(where: { $0.id == code }),
              let manager = profile.managers[group.id] else { return }
        notifications.selectedGroupCode = nil
        tab = 2
        if notificationGroup?.id != group.id {
            notificationGroup = group
        }
        Task {
            await manager.refreshFamilyDevices(force: true)
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image("LifeLoopLogo").resizable().scaledToFit().frame(width: 52, height: 52).accessibilityLabel("LifeLoop").devModeLogoTrigger()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(greeting).font(.subheadline).foregroundStyle(.secondary)
                        Text(profile.name).font(.title2.bold())
                    }
                    Spacer()
                    Button { showQuickStart = true } label: {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LoopStyle.green)
                    }
                    .accessibilityLabel("Quick Start Guide")
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
                }.buttonStyle(.borderedProminent).tint(LoopStyle.green).foregroundStyle(LoopStyle.darkInk).controlSize(.large)
            }.padding(24).frame(maxWidth: 720)
        }.loopPage().navigationTitle("Devices")
    }

    @ViewBuilder private var localDeviceCards: some View {
        if matchingDevices.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No devices connected yet" : "No matching devices", systemImage: "wave.3.right", description: Text("Connect a LifeLoop device to see heart rate, battery, and connection details."))
        }
        ForEach(matchingDevices) { device in
            let status = bleMonitor.deviceStatuses[device.id]
            let isSleeping = status?.lifeLoopState.state == 6
            Button { selectedDevice = device } label: {
                HStack(spacing: 16) {
                    Image(systemName: isSleeping ? "moon.zzz.fill" : "wave.3.right")
                        .font(.title2).foregroundStyle(isSleeping ? .indigo : LoopStyle.green)
                        .frame(width: 64, height: 72)
                        .background(LoopStyle.mint, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status?.name ?? device.name).font(.headline)
                        Text(status?.isConnected == true ? (isSleeping ? "Sleeping" : "\(Int(status?.lifeLoopState.bpm ?? 0)) bpm") : "—").font(.subheadline)
                        Text(status?.isConnected == true ? (isSleeping ? "Connected · Sleep Mode" : "Connected") : status?.isConnecting == true ? "Connecting…" : "Offline")
                            .font(.caption).foregroundStyle(isSleeping ? .indigo : .secondary)
                        if let status, status.isConnected, status.lifeLoopState.battery <= 10 {
                            Label("Battery low · \(status.lifeLoopState.battery)%", systemImage: "battery.0").font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if status?.isConnected == true {
                        Button {
                            if isSleeping {
                                bleMonitor.sendWakeCommand(deviceID: device.id)
                            } else {
                                bleMonitor.sendSleepCommand(deviceID: device.id)
                            }
                        } label: {
                            Image(systemName: isSleeping ? "sun.max.fill" : "moon.zzz.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isSleeping ? LoopStyle.green : .indigo)
                                .padding(10)
                                .background((isSleeping ? LoopStyle.green : Color.indigo).opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSleeping ? "Wake Up Device" : "Put Device to Sleep")
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.loopCard()
            }
            .buttonStyle(.plain)
            .contextMenu {
                if status?.isConnected == true {
                    Button {
                        if isSleeping {
                            bleMonitor.sendWakeCommand(deviceID: device.id)
                        } else {
                            bleMonitor.sendSleepCommand(deviceID: device.id)
                        }
                    } label: {
                        Label(isSleeping ? "Wake Up Device" : "Put Device to Sleep", systemImage: isSleeping ? "sun.max.fill" : "moon.zzz.fill")
                    }
                }
                Button(role: .destructive) {
                    removeDevice(device)
                } label: {
                    Label("Remove device", systemImage: "trash")
                }
            }
        }
    }

    private var emergencyButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !cancellationMessage.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Cloud Cancellation Unconfirmed")
                            .font(.subheadline.bold())
                    }
                    Text(cancellationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        closeEmergency()
                    } label: {
                        Text("Retry Cloud Cancellation")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .loopCard()
            }
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
            }.buttonStyle(.borderedProminent)
                .tint(timer.isAlertTriggered ? .red : LoopStyle.green)
                .foregroundStyle(timer.isAlertTriggered ? .white : LoopStyle.darkInk)
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
        guard emergencyTask == nil else { return }
        let sessionID = UUID()
        emergencySessionID = sessionID
        let recipients = Array(profile.managers.values)
        let deviceID = timer.triggerDeviceID
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
        let delivery = emergencyTask
        emergencyTask = nil
        let recipients = emergencyRecipients
        let deviceID = emergencyDeviceID
        let ownerName = profile.name
        bleMonitor.sendCancelCommand()
        timer.cancelCountdown()
        tab = 0
        filter = 0
        search = ""
        guard !isClosingEmergency else { return }
        isClosingEmergency = true
        // Send cancellation after the in-flight alert to preserve ordering.
        Task {
            await delivery?.value
            for manager in recipients {
                await manager.cancelMyOwnEmergency(deviceID: deviceID, displayName: ownerName)
            }
            let failures = recipients.compactMap { $0.emergencyError }
            if !failures.isEmpty {
                cancellationMessage = failures.joined(separator: "\n")
                emergencyDeliveryTitle = "Cancellation unconfirmed"
                emergencyDeliveryMessage = cancellationMessage + "\nThe alert remains active. Try canceling again."
                showCancellationAlert = true
            } else {
                cancellationMessage = ""
                emergencyDeliveryTitle = ""
                emergencyDeliveryMessage = ""
            }
            isClosingEmergency = false
        }
    }

    private func removeDevice(_ device: KnownDevice) {
        bleMonitor.removeKnownDevice(device)
        for manager in profile.managers.values {
            manager.removeDevice(deviceID: device.id)
        }
        if selectedDevice?.id == device.id {
            selectedDevice = nil
        }
    }

    private func acknowledgeCheckInFromWearer(deviceID: String) {
        bleMonitor.acknowledgeCheckInFromApp(deviceID: deviceID)
        Task {
            for manager in profile.managers.values {
                if let matchingKey = manager.activeCheckIns.keys.first(where: { $0.caseInsensitiveCompare(deviceID) == .orderedSame }) {
                    await manager.acknowledgeCheckInIfNeeded(for: matchingKey)
                }
            }
            for manager in profile.managers.values {
                manager.uploadLocalDevices(
                    bleMonitor.knownDevices,
                    statuses: bleMonitor.deviceStatuses,
                    fallbackLatitude: gps.latitude,
                    fallbackLongitude: gps.longitude
                )
            }
        }
    }

    private var wearerDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image("LifeLoopLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .accessibilityLabel("LifeLoop")
                        .devModeLogoTrigger()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(profile.name.isEmpty ? "Watch Wearer" : profile.name)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer()
                    Button { showQuickStart = true } label: {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LoopStyle.accent)
                            .frame(width: 44, height: 44)
                            .background(LoopStyle.mint, in: Circle())
                    }
                    .accessibilityLabel("Quick Start Guide")
                    Button { showWearerSettingsSheet = true } label: {
                        ProfileAvatar(name: profile.name.isEmpty ? "W" : profile.name, size: 46)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(LoopStyle.ink)
                                    .padding(4)
                                    .background(LoopStyle.card, in: Circle())
                                    .offset(x: 3, y: 3)
                            }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Settings and account")
                }

                if bleMonitor.isBluetoothUnavailable {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            Text(bleMonitor.bluetoothState == .poweredOff ? "Bluetooth is Off" : "Bluetooth Unavailable")
                                .font(.headline)
                        }
                        Text("Turn on Bluetooth in iPhone Settings so LifeLoop can stay connected to your watch.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .foregroundStyle(.white)
                    }
                    .loopCard()
                }

                ForEach(profile.groups) { group in
                    if let manager = profile.managers[group.id] {
                        WearerGroupCheckInSection(
                            manager: manager,
                            knownDeviceIDs: Set(bleMonitor.knownDevices.map(\.id))
                        ) { deviceID in
                            acknowledgeCheckInFromWearer(deviceID: deviceID)
                        }
                    }
                }

                // Giant Emergency / Cancel Button
                VStack(alignment: .leading, spacing: 12) {
                    if !cancellationMessage.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text("Cloud Cancellation Unconfirmed")
                                    .font(.subheadline.bold())
                            }
                            Text(cancellationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                closeEmergency()
                            } label: {
                                Text("Retry Cloud Cancellation")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LoopStyle.emergencyRed)
                            .foregroundStyle(.white)
                        }
                        .loopCard()
                    }

                    Button {
                        if timer.isAlertTriggered {
                            closeEmergency()
                        } else {
                            timer.startCountdown(reason: "MANUAL SOS")
                            bleMonitor.sendSOSCommand()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: timer.isAlertTriggered ? "xmark.octagon.fill" : "phone.fill")
                                .font(.title.bold())
                            Text(timer.isAlertTriggered ? "Cancel Emergency Alert" : "Call Help (SOS)")
                                .font(.title2.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LoopStyle.emergencyRed)
                    .foregroundStyle(.white)
                    .disabled(isClosingEmergency)

                    if isClosingEmergency {
                        ProgressView("Sending cancellation…")
                    }

                    if profile.groups.isEmpty && !timer.isAlertTriggered {
                        Label("No family group connected yet. Connect a group below so SOS notifies your caregivers.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // My Watch Section (Battery, Sleep/Wake, Connection)
                Text("My Watch")
                    .font(.title2.bold())

                if bleMonitor.knownDevices.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                            .font(.system(size: 48))
                            .foregroundStyle(LoopStyle.accent)
                        Text("No LifeLoop Watch Connected")
                            .font(.title3.bold())
                        Text("Tap the button below to pair your LifeLoop watch over Bluetooth.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            addDevice = true
                        } label: {
                            Label("Connect My Watch", systemImage: "wave.3.right")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LoopStyle.green)
                        .foregroundStyle(LoopStyle.ink)
                    }
                    .padding(8)
                    .loopCard()
                } else {
                    ForEach(bleMonitor.knownDevices) { device in
                        wearerDeviceCard(for: device)
                    }
                }

                WearerFamilyStatusCard(
                    knownDeviceIDs: Set(bleMonitor.knownDevices.map(\.id)),
                    onOpenAccount: { showWearerAccountSheet = true },
                    onOpenFamily: { showWearerFamilySheet = true }
                )
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .loopPage()
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func wearerDeviceCard(for device: KnownDevice) -> some View {
        let status = bleMonitor.deviceStatuses[device.id]
        let isConnected = status?.isConnected == true
        let isConnecting = status?.isConnecting == true
        let deviceState = status?.lifeLoopState.state ?? 0
        let isSleeping = deviceState == 6
        let isCheckInPending = deviceState == 5
        let isEmergency = deviceState == 4
        let isRecovering = deviceState == 3
        let battery = status?.lifeLoopState.battery ?? 100
        let hasBattery = status?.lastUpdated != nil
        let isLowBattery = hasBattery && battery <= 20
        let bpm = Int(status?.lifeLoopState.bpm ?? 0)

        let dotColor: Color = {
            if isConnected {
                if isEmergency { return LoopStyle.emergencyRed }
                if isCheckInPending || isRecovering { return .orange }
                if isSleeping { return .indigo }
                return LoopStyle.accent
            }
            return isConnecting ? .orange : .secondary
        }()

        let statusSummary: String = {
            if isConnected {
                if isEmergency { return "Emergency Active" }
                if isCheckInPending { return "Check-In Ping Active" }
                if isRecovering { return "Recovering" }
                if isSleeping { return "Watch Off (Sleep Mode)" }
                return "Watch On · Connected"
            }
            return isConnecting ? "Connecting…" : "Offline"
        }()

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status?.name ?? device.name)
                        .font(.title3.bold())
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 10, height: 10)
                        Text(statusSummary)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isConnected && (isSleeping || isEmergency || isCheckInPending) ? dotColor : .secondary)
                    }
                }
                Spacer()
                Button {
                    selectedDevice = device
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Device settings")
            }

            if isConnected && isSleeping {
                Label("Fall detection is paused while Sleep Mode is on.", systemImage: "moon.zzz.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.indigo)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            if isLowBattery {
                Label("Watch battery is low (\(battery)%) — please charge soon.", systemImage: "battery.25")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LoopStyle.emergencyRed)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LoopStyle.emergencyRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            if isConnected && isCheckInPending {
                Button {
                    acknowledgeCheckInFromWearer(deviceID: device.id)
                } label: {
                    Label("I’m OK — Stop Check-In Beep", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LoopStyle.green)
                .foregroundStyle(LoopStyle.darkInk)
            }

            // Large Battery & Heart Rate Display
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Battery", systemImage: battery <= 10 ? "battery.0" : battery <= 25 ? "battery.25" : battery <= 75 ? "battery.75" : "battery.100")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isLowBattery ? LoopStyle.emergencyRed : LoopStyle.accent)
                    Text(hasBattery ? "\(battery)%" : "—")
                        .font(.system(size: wearerMetricFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(isLowBattery ? LoopStyle.emergencyRed : (isConnected ? LoopStyle.ink : .secondary))
                    if !isConnected && hasBattery {
                        Text("Last known")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(LoopStyle.background, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 6) {
                    Label("Heart Rate", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(isConnected ? (isSleeping ? "Sleeping" : (bpm > 0 ? "\(bpm) BPM" : "Reading…")) : "—")
                        .font(.system(size: wearerMetricFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(LoopStyle.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(LoopStyle.background, in: RoundedRectangle(cornerRadius: 16))
            }

            if let lastUpdated = status?.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Big Turn Watch On / Off (Sleep / Wake) Button
            if isConnected {
                Button {
                    if isSleeping {
                        bleMonitor.sendWakeCommand(deviceID: device.id)
                    } else {
                        devicePendingSleep = device
                    }
                } label: {
                    Label(
                        isSleeping ? "Turn Watch On (Wake Up)" : "Turn Watch Off (Sleep Mode)",
                        systemImage: isSleeping ? "sun.max.fill" : "moon.zzz.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(isSleeping ? LoopStyle.green : .indigo)
                .foregroundStyle(isSleeping ? LoopStyle.ink : .white)
            } else {
                Button {
                    bleMonitor.connect(toKnown: device)
                } label: {
                    Label(
                        bleMonitor.isBluetoothUnavailable ? "Bluetooth Off" : "Reconnect Watch",
                        systemImage: bleMonitor.isBluetoothUnavailable ? "bolt.horizontal.circle" : "dot.radiowaves.left.and.right"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(LoopStyle.accent)
                .disabled(isConnecting || bleMonitor.isBluetoothUnavailable)
            }
        }
        .loopCard()
    }
}
struct DeviceProfileSheet: View {
    let device: KnownDevice
    @ObservedObject var bleMonitor: BLEMonitor
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DevMode.storageKey) private var isDevModeEnabled = false
    @State private var deviceName: String
    @State private var isLogExpanded = false
    @State private var removeDevice = false

    let background: Color
    let surface: Color
    let primaryText: Color
    let secondaryText: Color
    let teal: Color
    let warning: Color
    let onRemove: () -> Void

    init(
        device: KnownDevice,
        bleMonitor: BLEMonitor,
        background: Color,
        surface: Color,
        primaryText: Color,
        secondaryText: Color,
        teal: Color,
        warning: Color,
        onRemove: @escaping () -> Void
    ) {
        self.device = device
        self.bleMonitor = bleMonitor
        self.background = background
        self.surface = surface
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.teal = teal
        self.warning = warning
        self.onRemove = onRemove
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

                    Button(action: toggleSleepWake) {
                        Label(
                            isSleeping ? "Wake Up Device" : "Put Device to Sleep",
                            systemImage: isSleeping ? "sun.max.fill" : "moon.zzz.fill"
                        )
                    }
                    .foregroundStyle(isSleeping ? teal : .indigo)
                    .disabled(!status.isConnected)
                    .listRowBackground(surface)
                }

                Section("Location") {
                    MemberMap(name: status.name, latitude: status.lifeLoopState.latitude, longitude: status.lifeLoopState.longitude, shared: true)
                        .listRowInsets(EdgeInsets())
                }

                Section("Device information") {
                    telemetryRow(title: "Battery", value: status.lastUpdated == nil ? "—" : "\(status.lifeLoopState.battery)%")
                    telemetryRow(title: "BPM", value: bpmText)
                    if isDevModeEnabled {
                        telemetryRow(title: "State", value: stateDescription)
                        telemetryRow(title: "Latitude", value: coordinateText(status.lifeLoopState.latitude))
                        telemetryRow(title: "Longitude", value: coordinateText(status.lifeLoopState.longitude))
                    }
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

                Section {
                    Button("Remove device", role: .destructive) { removeDevice = true }
                }
            }
            .alert("Remove this device from your phone?", isPresented: $removeDevice) {
                Button("Remove device", role: .destructive) {
                    onRemove()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will disconnect the device and remove it from your saved devices.")
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
    }

    private var currentDevice: KnownDevice? {
        bleMonitor.knownDevices.first(where: { $0.id == device.id })
    }

    private var status: DeviceStatus {
        bleMonitor.deviceStatuses[device.id] ?? DeviceStatus(deviceID: device.id, name: currentDevice?.name ?? device.name)
    }

    private var statusText: String {
        if status.isConnecting { return "Connecting" }
        if status.isConnected {
            return isSleeping ? "Connected · Sleep Mode" : "Connected"
        }
        return "Offline"
    }

    private var isSleeping: Bool {
        status.lifeLoopState.state == 6
    }

    private var stateDescription: String {
        switch status.lifeLoopState.state {
        case 0: return "0 (Normal)"
        case 3: return "3 (Recovering)"
        case 4: return "4 (Emergency)"
        case 5: return "5 (Check-In Ping)"
        case 6: return "6 (Sleep Mode)"
        default: return "\(status.lifeLoopState.state)"
        }
    }

    private var statusColor: Color {
        if status.isConnected { return isSleeping ? .indigo : teal }
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

    private func toggleSleepWake() {
        if isSleeping {
            bleMonitor.sendWakeCommand(deviceID: device.id)
        } else {
            bleMonitor.sendSleepCommand(deviceID: device.id)
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
        .onDisappear { bleMonitor.stopScanning() }
        .onAppear {
            if !bleMonitor.isScanning {
                bleMonitor.startScanning()
            }
        }
    }
}

private struct WearerGroupCheckInSection: View {
    @ObservedObject var manager: FamilyDeviceManager
    let knownDeviceIDs: Set<String>
    let onAcknowledge: (String) -> Void

    private var pendingCheckIns: [CloudCheckIn] {
        manager.activeCheckIns.values
            .filter { checkIn in
                checkIn.status == "PENDING" &&
                knownDeviceIDs.contains { $0.caseInsensitiveCompare(checkIn.targetDeviceID) == .orderedSame }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ForEach(pendingCheckIns) { checkIn in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text("Check-In Requested")
                        .font(.headline)
                }
                Text("\(checkIn.initiatorName) wants to make sure you’re OK. Press your watch button or tap below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    onAcknowledge(checkIn.targetDeviceID)
                } label: {
                    Label("I’m OK — Confirm Check-In", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LoopStyle.green)
                .foregroundStyle(LoopStyle.darkInk)
            }
            .loopCard()
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
            )
        }
    }
}

private struct WearerFamilyStatusCard: View {
    @Environment(UserProfile.self) private var profile
    let knownDeviceIDs: Set<String>
    let onOpenAccount: () -> Void
    let onOpenFamily: () -> Void

    var body: some View {
        Button {
            if profile.isSignedIn {
                onOpenFamily()
            } else {
                onOpenAccount()
            }
        } label: {
            if !profile.isSignedIn {
                simpleCard(
                    title: "Connect to Family Group",
                    subtitle: "Sign in to share your watch with family caregivers."
                )
            } else if profile.groups.isEmpty {
                simpleCard(
                    title: "Connect to Family Group",
                    subtitle: "Tap to join a family with an invitation code."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill")
                            .font(.title3)
                            .foregroundStyle(LoopStyle.accent)
                            .frame(width: 40, height: 40)
                            .background(LoopStyle.mint, in: Circle())
                        Text("Family Groups")
                            .font(.headline)
                            .foregroundStyle(LoopStyle.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profile.groups) { group in
                        if let manager = profile.managers[group.id] {
                            WearerGroupLinkRow(
                                group: group,
                                manager: manager,
                                knownDeviceIDs: knownDeviceIDs
                            )
                        }
                    }
                    Text("Tap to join a group or manage watch sharing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .loopCard()
            }
        }
        .buttonStyle(.plain)
    }

    private func simpleCard(title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.title3)
                .foregroundStyle(LoopStyle.accent)
                .frame(width: 44, height: 44)
                .background(LoopStyle.mint, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(LoopStyle.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .loopCard()
    }
}

private struct WearerGroupLinkRow: View {
    let group: LoopGroup
    @ObservedObject var manager: FamilyDeviceManager
    let knownDeviceIDs: Set<String>

    private var isWatchShared: Bool {
        manager.linkedDeviceIDs.contains { linkedID in
            knownDeviceIDs.contains { $0.caseInsensitiveCompare(linkedID) == .orderedSame }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LoopStyle.ink)
            Spacer()
            if knownDeviceIDs.isEmpty {
                Label("No watch paired yet", systemImage: "applewatch.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isWatchShared {
                Label("Watch shared", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LoopStyle.accent)
            } else {
                Label("Watch not shared yet — tap to link", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(LoopStyle.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
