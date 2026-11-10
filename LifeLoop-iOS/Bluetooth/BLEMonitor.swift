import CoreBluetooth
import Foundation
import UserNotifications

extension Notification.Name {
    static let lifeLoopIncomingPing = Notification.Name("com.lifeloop.incomingPing")
    static let lifeLoopPingAcknowledged = Notification.Name("com.lifeloop.pingAcknowledged")
}

struct DeviceCancellationRequest: Equatable {
    let id = UUID()
    let deviceID: String
}

final class BLEMonitor: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    
    private var rxCharacteristics: [String: CBCharacteristic] = [:]
    
    @Published private(set) var bluetoothStateText = "Starting Bluetooth…"
    @Published private(set) var isScanning = false
    @Published private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published private(set) var knownDevices: [KnownDevice] = []
    @Published private(set) var deviceStatuses: [String: DeviceStatus] = [:]
    @Published private(set) var connectionLog: [String] = []
    @Published private(set) var lastAcknowledgedPingDeviceID: String?
    @Published private(set) var pingAckSequence: Int = 0
    @Published private(set) var cancellationRequest: DeviceCancellationRequest?
    
    private var centralManager: CBCentralManager!
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var txCharacteristics: [String: CBCharacteristic] = [:]
    private var warningDevices: Set<String> = []
    private var reportedStates: [String: Int] = [:]
    private var awaitingAppCancellation: Set<String> = []
    private var manuallyDisconnected: Set<String> = []
    private var discoveryRequested = false
    private var pingActiveDevices: Set<String> = []
    private var pingSentAt: [String: Date] = [:]
    private var pendingPings: [String: Date] = [:]
    private var pendingCancels: [String: Date] = [:]
    private var pendingSOS: [String: Date] = [:]
    private let deviceStore = DeviceStore()
    
    // TIMING FIX: Prevents stale telemetry from overriding manual commands
    private var lastCommandSentAt: Date = Date.distantPast
    private var lastImmediateAlertAt: Date?
    
    var isConnected: Bool {
        deviceStatuses.values.contains { $0.isConnected }
    }
    
    var connectedDeviceName: String? {
        deviceStatuses.values.first(where: { $0.isConnected })?.name
    }
    
    private func savedName(for deviceID: String, fallback: String) -> String {
        knownDevices.first(where: { $0.id == deviceID })?.name ?? fallback
    }
    
    override init() {
        super.init()
        knownDevices = deviceStore.load()
        for device in knownDevices {
            deviceStatuses[device.id] = DeviceStatus(deviceID: device.id, name: device.name)
        }
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "LifeLoopCentralManager"]
        )
        NotificationCenter.default.addObserver(
            forName: .lifeLoopIncomingPing,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let targetDeviceID = notification.userInfo?["targetDeviceID"] as? String else { return }
            self.sendPingCommand(deviceID: targetDeviceID)
        }
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            bluetoothStateText = "Bluetooth is not ready"
            return
        }
        discoveryRequested = true
        discoveredPeripherals.removeAll()
        isScanning = true
        bluetoothStateText = "Scanning for LifeLoop devices…"
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    func stopScanning() {
        discoveryRequested = false
        maintainConnections()
    }

    /// Keep a pending connection and a service-filtered scan for missing saved devices.
    private func maintainConnections() {
        guard centralManager.state == .poweredOn else { return }
        let wanted = knownDevices.filter { !manuallyDisconnected.contains($0.id) }
        for device in wanted where connectedPeripherals[device.id] == nil {
            guard let uuid = UUID(uuidString: device.id),
                  let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else { continue }
            connect(peripheral: peripheral, name: device.name)
        }
        let missing = wanted.contains { deviceStatuses[$0.id]?.isConnected != true }
        if discoveryRequested || missing {
            if !centralManager.isScanning {
                centralManager.scanForPeripherals(withServices: [Self.serviceUUID])
            }
            isScanning = true
            if missing { bluetoothStateText = "Looking for saved LifeLoop devices…" }
        } else {
            centralManager.stopScan()
            isScanning = false
        }
    }
    
    func addKnownDevice(_ discovered: DiscoveredPeripheral) {
        let device = KnownDevice(id: discovered.id.uuidString, name: discovered.name)
        if !knownDevices.contains(where: { $0.id == device.id }) {
            knownDevices.append(device)
            deviceStore.save(knownDevices)
        }
        manuallyDisconnected.remove(device.id)
        let displayName = savedName(for: device.id, fallback: device.name)
        if deviceStatuses[device.id] == nil {
            deviceStatuses[device.id] = DeviceStatus(deviceID: device.id, name: displayName)
        }
        connect(peripheral: discovered.peripheral, name: displayName)
    }
    
    func connect(toKnown device: KnownDevice) {
        manuallyDisconnected.remove(device.id)
        guard centralManager.state == .poweredOn, let uuid = UUID(uuidString: device.id) else { return }
        if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(peripheral: peripheral, name: device.name)
        } else {
            maintainConnections()
        }
    }
    
    func disconnect(deviceID: String) {
        manuallyDisconnected.insert(deviceID)
        guard centralManager.state == .poweredOn,
              let peripheral = connectedPeripherals[deviceID] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    func checkOfflineDevices(timeout: TimeInterval = 15) {
        let now = Date()
        for (id, status) in deviceStatuses where status.isConnected {
            let peripheralDisconnected = connectedPeripherals[id]?.state != .connected
            let telemetryTimedOut = status.lastUpdated.map { now.timeIntervalSince($0) > timeout } ?? false
            
            if peripheralDisconnected || telemetryTimedOut {
                if centralManager.state == .poweredOn,
                   let peripheral = connectedPeripherals[id], peripheral.state == .connected {
                    centralManager.cancelPeripheralConnection(peripheral)
                }
                updateStatus(for: id) { updatedStatus in
                    updatedStatus.isConnected = false
                    updatedStatus.isConnecting = false
                    updatedStatus.lifeLoopState.bpm = 0
                }
                reportedStates.removeValue(forKey: id)
                awaitingAppCancellation.remove(id)
                connectedPeripherals.removeValue(forKey: id)
                txCharacteristics.removeValue(forKey: id)
                rxCharacteristics.removeValue(forKey: id)
            }
        }
        maintainConnections()
    }
    
    func renameKnownDevice(_ device: KnownDevice, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = knownDevices.firstIndex(where: { $0.id == device.id }) else { return }
        
        knownDevices[index].name = trimmedName
        deviceStore.save(knownDevices)
        updateStatus(for: device.id) { status in
            status.name = trimmedName
        }
    }
    
    func removeKnownDevice(_ device: KnownDevice) {
        knownDevices.removeAll { $0.id == device.id }
        deviceStore.save(knownDevices)
        deviceStatuses.removeValue(forKey: device.id)
        warningDevices.remove(device.id)
        pendingPings.removeValue(forKey: device.id)
        pendingCancels.removeValue(forKey: device.id)
        pendingSOS.removeValue(forKey: device.id)
        manuallyDisconnected.insert(device.id)
        if let peripheral = connectedPeripherals.removeValue(forKey: device.id),
           centralManager.state == .poweredOn {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        txCharacteristics.removeValue(forKey: device.id)
        rxCharacteristics.removeValue(forKey: device.id)
        maintainConnections()
    }
    
    private func connect(peripheral: CBPeripheral, name: String) {
        let id = peripheral.identifier.uuidString
        guard centralManager.state == .poweredOn, peripheral.state == .disconnected else { return }
        peripheral.delegate = self
        connectedPeripherals[id] = peripheral
        updateStatus(for: id) { status in
            status.name = name
            status.isConnecting = true
        }
        centralManager.connect(peripheral)
    }
    
    private func handleTelemetry(_ data: Data, deviceID: String) {
        let nonNullData = data.prefix { $0 != 0 }
        guard let payload = String(data: nonNullData, encoding: .utf8) ?? String(data: data, encoding: .utf8) else { return }
        let cleaned = payload.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !cleaned.isEmpty else { return }
        let fallback = deviceStatuses[deviceID]?.lifeLoopState ?? LifeLoopState()
        let newState = parse(cleaned, fallback: fallback)
        let previousReportedState = reportedStates[deviceID]
        let appCancellationPending = awaitingAppCancellation.contains(deviceID)
        if let newState, previousReportedState != newState.state {
            log("Device \(deviceID) state \(previousReportedState.map(String.init) ?? "unknown") → \(newState.state)")
        } else if newState == nil, pingSentAt[deviceID] != nil {
            log("Unrecognized response during PING: \(cleaned.prefix(80))")
        }
        let deviceCanceled = newState.map {
            Self.isDeviceCancellation(previousState: reportedStates[deviceID], state: $0.state,
                                      awaitingAppCancellation: awaitingAppCancellation.contains(deviceID))
        } ?? false
        if let newState {
            reportedStates[deviceID] = newState.state
            if newState.state == 0 { awaitingAppCancellation.remove(deviceID) }
        }
        
        updateStatus(for: deviceID) { status in
            let previousState = status.lifeLoopState.state
            let previousBPM = status.lifeLoopState.bpm
            status.lastPayload = cleaned
            status.lastUpdated = Date()
            if let newState {
                status.lifeLoopState = newState
                if abs(newState.bpm - previousBPM) >= 1.0 || newState.state != previousState {
                    DispatchQueue.main.async {
                        self.pingAckSequence += 1
                    }
                }
                let warningReason = Self.emergencyReason(for: newState)
                let pingAcknowledged = Self.isPingAcknowledgment(
                    previousState: previousReportedState,
                    state: newState.state,
                    pingPending: self.pingSentAt[deviceID] != nil,
                    appCancellationPending: appCancellationPending
                )

                if pingAcknowledged {
                    self.pingActiveDevices.remove(deviceID)
                    self.pingSentAt.removeValue(forKey: deviceID)
                    DispatchQueue.main.async {
                        self.lastAcknowledgedPingDeviceID = deviceID
                        self.pingAckSequence += 1
                        self.log("Check-in PING acknowledged on device")
                        NotificationCenter.default.post(
                            name: .lifeLoopPingAcknowledged,
                            object: nil,
                            userInfo: ["deviceID": deviceID]
                        )
                    }
                } else if self.pingSentAt[deviceID] != nil,
                          Self.interruptsPing(state: newState.state, appCancellationPending: appCancellationPending) {
                    self.pingSentAt.removeValue(forKey: deviceID)
                    self.pingActiveDevices.remove(deviceID)
                    self.log("PING interrupted; wearer safety has not been confirmed")
                }
                
                if deviceCanceled {
                    // Honor the deliberate fall cancellation even if this packet
                    // also contains an abnormal heart-rate reading.
                    self.warningDevices.insert(deviceID)
                } else if let warningReason, !appCancellationPending, self.warningDevices.insert(deviceID).inserted {
                    DispatchQueue.main.async {
                        EMSTimerManager.shared.startCountdown(reason: warningReason, deviceID: deviceID)
                    }
                    self.sendSOSCommand(deviceID: deviceID)
                } else if warningReason == nil {
                    // A new episode can warn again after recovery; repeated samples cannot
                    // immediately undo the person's explicit cancellation.
                    self.warningDevices.remove(deviceID)
                }
                // Normal or zero telemetry is not an explicit cancellation.
                // Once triggered, the emergency stays latched until a person cancels.
            }
        }
        if deviceCanceled {
            cancellationRequest = DeviceCancellationRequest(deviceID: deviceID)
            log("Device fall cancellation detected")
        }
    }

    static func isPingAcknowledgment(previousState: Int?, state: Int, pingPending: Bool,
                                     appCancellationPending: Bool) -> Bool {
        // Heart rate is independent of the device's check-in response. An abnormal
        // BPM must neither erase a pending ping nor reject its button response.
        // Acknowledging a check-in does not cancel the separate emergency alert.
        pingPending && previousState == 5 && state == 0 && !appCancellationPending
    }

    static func interruptsPing(state: Int, appCancellationPending: Bool) -> Bool {
        appCancellationPending || (state != 5 && state != 0)
    }

    static func isDeviceCancellation(previousState: Int?, state: Int, awaitingAppCancellation: Bool) -> Bool {
        // In the supplied XIAO firmware, Recovering/Emergency only return to
        // Normal through the held button or an app CANCEL command.
        !awaitingAppCancellation && state == 0 && (previousState == 3 || previousState == 4)
    }

    static func emergencyReason(for state: LifeLoopState) -> String? {
        if state.bpm > 0 && state.bpm <= 40 { return "CARDIAC ABNORMALITY DETECTED" }
        if state.state == 4 { return "SEVERE FALL DETECTED" }
        // Zero BPM alone does not trigger an emergency.
        return nil
    }

    func sendCancelCommand() {
        let now = Date()
        guard now.timeIntervalSince(lastCommandSentAt) >= 0.25 else { return }
        lastCommandSentAt = now // Stamps the time the button was pressed
        let targets = Set(knownDevices.map(\.id)).union(connectedPeripherals.keys)
        for id in targets {
            awaitingAppCancellation.insert(id)
            pingSentAt.removeValue(forKey: id)
            pendingPings.removeValue(forKey: id)
            pendingSOS.removeValue(forKey: id)
            pingActiveDevices.remove(id)
            pendingCancels[id] = now.addingTimeInterval(15)
            flushPendingCancel(deviceID: id)
        }
        maintainConnections()
    }

    private func flushPendingCancel(deviceID: String) {
        guard let deadline = pendingCancels[deviceID] else { return }
        guard deadline > Date() else {
            pendingCancels.removeValue(forKey: deviceID)
            return
        }
        guard let peripheral = connectedPeripherals[deviceID],
              peripheral.state == .connected else {
            return
        }
        let discoveredRx = peripheral.services?
            .first(where: { $0.uuid == Self.serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid == Self.rxCharacteristicUUID })
        if let discoveredRx, rxCharacteristics[deviceID] == nil {
            rxCharacteristics[deviceID] = discoveredRx
        }
        guard let rxChar = rxCharacteristics[deviceID] else {
            return
        }
        pendingCancels.removeValue(forKey: deviceID)
        let payload = Data("CANCEL".utf8)
        peripheral.writeValue(payload, for: rxChar, type: .withResponse)
        updateStatus(for: deviceID) { status in
            if status.lifeLoopState.state != 0 {
                status.lifeLoopState.state = 0
                DispatchQueue.main.async {
                    self.pingAckSequence += 1
                }
            }
        }
        log("Sent CANCEL command to device")
    }

    func sendSOSCommand(deviceID: String? = nil) {
        lastCommandSentAt = Date()
        let targets: [String]
        if let deviceID {
            targets = [deviceID]
        } else if !connectedPeripherals.isEmpty {
            targets = Array(connectedPeripherals.keys)
        } else {
            targets = knownDevices.map(\.id)
        }
        for id in targets {
            pendingSOS[id] = Date().addingTimeInterval(15)
            flushPendingSOS(deviceID: id)
        }
        maintainConnections()
    }

    private func flushPendingSOS(deviceID: String) {
        guard let deadline = pendingSOS[deviceID] else { return }
        guard deadline > Date() else {
            pendingSOS.removeValue(forKey: deviceID)
            log("SOS command expired before device was ready.")
            return
        }
        guard let peripheral = connectedPeripherals[deviceID],
              peripheral.state == .connected else {
            return
        }
        let discoveredRx = peripheral.services?
            .first(where: { $0.uuid == Self.serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid == Self.rxCharacteristicUUID })
        if let discoveredRx, rxCharacteristics[deviceID] == nil {
            rxCharacteristics[deviceID] = discoveredRx
        }
        guard let rxChar = rxCharacteristics[deviceID] else {
            return
        }
        pendingSOS.removeValue(forKey: deviceID)
        pingSentAt.removeValue(forKey: deviceID)
        pendingPings.removeValue(forKey: deviceID)
        pingActiveDevices.remove(deviceID)
        let payload = Data("SOS".utf8)
        peripheral.writeValue(payload, for: rxChar, type: .withResponse)
        log("Sent SOS command to device")
    }
    
    func sendPingCommand(deviceID: String? = nil) {
        let targets: [String]
        if let deviceID {
            // A remote device belongs to another phone; never fall back to
            // pinging every local device when its identifier doesn't match.
            guard let saved = knownDevices.first(where: {
                $0.id.caseInsensitiveCompare(deviceID) == .orderedSame
            }) else { return }
            targets = [saved.id]
        } else {
            targets = knownDevices.map(\.id)
        }
        for id in targets {
            pendingPings[id] = Date().addingTimeInterval(15)
            flushPendingPing(deviceID: id)
        }
        maintainConnections()
    }

    private func flushPendingPing(deviceID: String) {
        guard let deadline = pendingPings[deviceID] else { return }
        guard deadline > Date() else {
            pendingPings.removeValue(forKey: deviceID)
            log("PING expired before the device was ready. Send it again.")
            return
        }
        guard let peripheral = connectedPeripherals[deviceID],
              peripheral.state == .connected,
              let rxChar = rxCharacteristics[deviceID] else {
            log("PING waiting for the device command connection")
            return
        }
        guard rxChar.properties.contains(.write) else {
            pendingPings.removeValue(forKey: deviceID)
            log("PING failed: device does not support writes with response")
            return
        }
        pendingPings.removeValue(forKey: deviceID)
        pingActiveDevices.remove(deviceID)
        pingSentAt[deviceID] = Date()
        peripheral.writeValue(Data("PING".utf8), for: rxChar, type: .withResponse)
        log("PING written to device \(deviceID); waiting for its check-in state")
    }

    private func parse(_ cleaned: String, fallback: LifeLoopState) -> LifeLoopState? {
        if let jsonData = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return apply(dictionary: object, fallback: fallback)
        }

        let pairs = cleaned.split(whereSeparator: { $0 == "," || $0 == "|" })
        var dictionary: [String: Any] = [:]
        for pair in pairs {
            let pieces = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if pieces.count == 2 {
                dictionary[pieces[0].lowercased()] = pieces[1]
            }
        }
        if !dictionary.isEmpty {
            return apply(dictionary: dictionary, fallback: fallback)
        }

        let values = pairs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.count >= 4 else { return nil }
        return LifeLoopState(
            bpm: Float(values[0]) ?? fallback.bpm,
            state: Int(values[1]) ?? fallback.state,
            battery: fallback.battery,
            latitude: Double(values[2]) ?? fallback.latitude,
            longitude: Double(values[3]) ?? fallback.longitude
        )
    }

    private func apply(dictionary: [String: Any], fallback: LifeLoopState) -> LifeLoopState {
        func doubleValue(_ keys: [String]) -> Double? {
            for key in keys {
                if let raw = dictionary[key], let value = parseDouble(raw) { return value }
                if let match = dictionary.first(where: { $0.key.lowercased() == key }),
                   let value = parseDouble(match.value) { return value }
            }
            return nil
        }
        let bpm = doubleValue(["bpm", "heartrate", "hr"]).map(Float.init) ?? fallback.bpm
        let state = doubleValue(["state"]).map(Int.init) ?? fallback.state
        let latitude = doubleValue(["latitude", "lat"]) ?? fallback.latitude
        let longitude = doubleValue(["longitude", "lon", "lng"]) ?? fallback.longitude
        let battery = doubleValue(["battery", "bat"]).map(Int.init) ?? fallback.battery

        return LifeLoopState(bpm: bpm, state: state, battery: battery, latitude: latitude, longitude: longitude)
    }

    private func parseDouble(_ raw: Any) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        guard let string = raw as? String else { return nil }
        if let value = Double(string) { return value }
        let allowedCharacters = CharacterSet(charactersIn: "-0123456789.")
        let numericString = string.unicodeScalars.filter { allowedCharacters.contains($0) }.map(String.init).joined()
        return Double(numericString)
    }

    private func updateStatus(for id: String, _ mutate: (inout DeviceStatus) -> Void) {
        var status = deviceStatuses[id] ?? DeviceStatus(deviceID: id, name: "Unknown device")
        mutate(&status)
        deviceStatuses[id] = status
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionLog.insert("\(timestamp) — \(message)", at: 0)
        if connectionLog.count > 25 { connectionLog.removeLast() }
    }
}

extension BLEMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            pingSentAt.removeAll()
            pingActiveDevices.removeAll()
            reportedStates.removeAll()
            awaitingAppCancellation.removeAll()
            connectedPeripherals.removeAll()
            txCharacteristics.removeAll()
            rxCharacteristics.removeAll()
            isScanning = false
            for id in Array(deviceStatuses.keys) {
                deviceStatuses[id]?.isConnected = false
                deviceStatuses[id]?.isConnecting = false
            }
        }
        switch central.state {
        case .poweredOn:
            bluetoothStateText = "Bluetooth ready"
            maintainConnections()
        case .poweredOff:
            bluetoothStateText = "Bluetooth is off"
            isScanning = false
        default: bluetoothStateText = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown LifeLoop device"
        let discovered = DiscoveredPeripheral(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue)

        if let index = discoveredPeripherals.firstIndex(where: { $0.id == discovered.id }) {
            discoveredPeripherals[index] = discovered
        } else {
            discoveredPeripherals.append(discovered)
        }

        let id = peripheral.identifier.uuidString
        if knownDevices.contains(where: { $0.id == id }) && !manuallyDisconnected.contains(id) && connectedPeripherals[id] == nil {
            connect(peripheral: peripheral, name: savedName(for: id, fallback: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        guard knownDevices.contains(where: { $0.id == id }), !manuallyDisconnected.contains(id) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectedPeripherals[id] = peripheral
        peripheral.delegate = self
        let displayName = savedName(for: id, fallback: peripheral.name ?? "device")
        updateStatus(for: id) { status in
            status.isConnected = true
            status.isConnecting = false
            status.name = displayName
        }
        bluetoothStateText = "Connected"
        peripheral.discoverServices([Self.serviceUUID])
        maintainConnections()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        updateStatus(for: id) { status in
            status.isConnected = false
            status.isConnecting = false
        }
        connectedPeripherals.removeValue(forKey: id)
        bluetoothStateText = "Connection failed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.maintainConnections()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        reportedStates.removeValue(forKey: id)
        awaitingAppCancellation.remove(id)
        pingSentAt.removeValue(forKey: id)
        pingActiveDevices.remove(id)
        updateStatus(for: id) { status in
            status.isConnected = false
            status.isConnecting = false
            status.lifeLoopState.bpm = 0
        }
        connectedPeripherals.removeValue(forKey: id)
        txCharacteristics.removeValue(forKey: id)
        rxCharacteristics.removeValue(forKey: id)
        if !knownDevices.contains(where: { $0.id == id }) { deviceStatuses.removeValue(forKey: id) }
        maintainConnections()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for peripheral in peripherals {
            let id = peripheral.identifier.uuidString
            guard knownDevices.contains(where: { $0.id == id }) else {
                if central.state == .poweredOn {
                    central.cancelPeripheralConnection(peripheral)
                }
                continue
            }
            guard peripheral.state == .connected || peripheral.state == .connecting else { continue }
            peripheral.delegate = self
            connectedPeripherals[id] = peripheral
            updateStatus(for: id) { status in
                status.name = savedName(for: id, fallback: peripheral.name ?? status.name)
                status.isConnected = peripheral.state == .connected
                status.isConnecting = peripheral.state == .connecting
            }
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.serviceUUID])
            }
        }
    }
}

extension BLEMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.txCharacteristicUUID, Self.rxCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        let id = peripheral.identifier.uuidString

        if let txChar = service.characteristics?.first(where: { $0.uuid == Self.txCharacteristicUUID }) {
            txCharacteristics[id] = txChar
            if txChar.properties.contains(.notify) || txChar.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: txChar)
            }
            if txChar.properties.contains(.read) {
                peripheral.readValue(for: txChar)
            }
        }

        if let rxChar = service.characteristics?.first(where: { $0.uuid == Self.rxCharacteristicUUID }) {
            rxCharacteristics[id] = rxChar
            flushPendingCancel(deviceID: id)
            flushPendingPing(deviceID: id)
            flushPendingSOS(deviceID: id)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxCharacteristicUUID else { return }
        if let error {
            log("Bluetooth command write failed: \(error.localizedDescription)")
        } else {
            // This confirms the BLE write, not that firmware sounded the buzzer.
            log("Device accepted Bluetooth command write")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.txCharacteristicUUID,
              let data = characteristic.value else { return }
        handleTelemetry(data, deviceID: peripheral.identifier.uuidString)
    }
}
