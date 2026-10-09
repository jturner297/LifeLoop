import CoreBluetooth
import Foundation
import UserNotifications

final class BLEMonitor: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    
    private var rxCharacteristics: [String: CBCharacteristic] = [:]
    private let locationManager = LocationManager()
    
    @Published private(set) var bluetoothStateText = "Starting Bluetooth…"
    @Published private(set) var isScanning = false
    @Published private(set) var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published private(set) var knownDevices: [KnownDevice] = []
    @Published private(set) var deviceStatuses: [String: DeviceStatus] = [:]
    @Published private(set) var connectionLog: [String] = []
    
    private var centralManager: CBCentralManager!
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var txCharacteristics: [String: CBCharacteristic] = [:]
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
    }
    
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            bluetoothStateText = "Bluetooth is not ready"
            return
        }
        discoveredPeripherals.removeAll()
        isScanning = true
        bluetoothStateText = "Scanning for LifeLoop devices…"
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }
    
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        if connectedPeripherals.isEmpty {
            bluetoothStateText = "Scan stopped"
        }
    }
    
    func addKnownDevice(_ discovered: DiscoveredPeripheral) {
        let device = KnownDevice(id: discovered.id.uuidString, name: discovered.name)
        if !knownDevices.contains(where: { $0.id == device.id }) {
            knownDevices.append(device)
            deviceStore.save(knownDevices)
        }
        let displayName = savedName(for: device.id, fallback: device.name)
        if deviceStatuses[device.id] == nil {
            deviceStatuses[device.id] = DeviceStatus(deviceID: device.id, name: displayName)
        }
        connect(peripheral: discovered.peripheral, name: displayName)
    }
    
    func connect(toKnown device: KnownDevice) {
        guard let uuid = UUID(uuidString: device.id) else { return }
        if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(peripheral: peripheral, name: device.name)
        } else {
            bluetoothStateText = "\(device.name) not found nearby"
        }
    }
    
    func disconnect(deviceID: String) {
        guard let peripheral = connectedPeripherals[deviceID] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    func checkOfflineDevices(timeout: TimeInterval = 60) {
        let now = Date()
        for (id, status) in deviceStatuses where status.isConnected {
            let peripheralDisconnected = connectedPeripherals[id]?.state != .connected
            let telemetryTimedOut = status.lastUpdated.map { now.timeIntervalSince($0) > timeout } ?? false
            
            if peripheralDisconnected || telemetryTimedOut {
                updateStatus(for: id) { updatedStatus in
                    updatedStatus.isConnected = false
                    updatedStatus.isConnecting = false
                }
                connectedPeripherals.removeValue(forKey: id)
                txCharacteristics.removeValue(forKey: id)
                rxCharacteristics.removeValue(forKey: id)
            }
        }
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
        if let peripheral = connectedPeripherals[device.id] {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    private func connect(peripheral: CBPeripheral, name: String) {
        let id = peripheral.identifier.uuidString
        peripheral.delegate = self
        connectedPeripherals[id] = peripheral
        updateStatus(for: id) { status in
            status.name = name
            status.isConnecting = true
        }
        centralManager.connect(peripheral)
    }
    
    private func handleTelemetry(_ data: Data, deviceID: String) {
        guard let payload = String(data: data, encoding: .utf8) else { return }
        let cleaned = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = deviceStatuses[deviceID]?.lifeLoopState ?? LifeLoopState()
        let newState = parse(cleaned, fallback: fallback)
        
        updateStatus(for: deviceID) { status in
            status.lastPayload = cleaned
            status.lastUpdated = Date()
            if let newState {
                status.lifeLoopState = newState
                let hasFallen = newState.state == 4
                let isNormal = newState.state == 0
                let hasCardiacEvent = newState.bpm > 0 && newState.bpm <= 40
                
                if hasCardiacEvent {
                    DispatchQueue.main.async {
                        // Prevent resetting the 30 seconds back to 30 over and over
                        if !EMSTimerManager.shared.isActive && !EMSTimerManager.shared.isAlertTriggered {
                            EMSTimerManager.shared.startCountdown(reason: "CARDIAC \nABNORMALITY \nDETECTED")
                        }
                    }
                } else if hasFallen {
                    DispatchQueue.main.async {
                        if !EMSTimerManager.shared.isActive && !EMSTimerManager.shared.isAlertTriggered {
                            EMSTimerManager.shared.startCountdown(reason: "SEVERE FALL \nDETECTED")
                        }
                    }
                } else if isNormal { // check for hardware cancellation
                    DispatchQueue.main.async {
                        // cannot override a manual SOS trigger.
                        if Date().timeIntervalSince(self.lastCommandSentAt) > 35.0 {
                            if EMSTimerManager.shared.isActive {
                                EMSTimerManager.shared.cancelCountdown()
                            }
                        }
                    }
                }
            }
        }
    }

    func sendCancelCommand() {
        lastCommandSentAt = Date() // Stamps the time the button was pressed
        let payload = Data("CANCEL".utf8)
        for (id, peripheral) in connectedPeripherals {
            if let rxChar = rxCharacteristics[id] {
                // FIXED: .withResponse guarantees the nRF receives it
                peripheral.writeValue(payload, for: rxChar, type: .withResponse)
                log("Sent CANCEL command to device")
            }
        }
    }

    func sendSOSCommand() {
        lastCommandSentAt = Date()
        let payload = Data("SOS".utf8)
        for (id, peripheral) in connectedPeripherals {
            if let rxChar = rxCharacteristics[id] {
                // FIXED: .withResponse guarantees the nRF receives it
                peripheral.writeValue(payload, for: rxChar, type: .withResponse)
                log("Sent SOS command to device")
            }
        }
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
        let bpm = doubleValue(["bpm"]).map(Float.init) ?? fallback.bpm
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
        switch central.state {
        case .poweredOn: bluetoothStateText = "Bluetooth ready"
        case .poweredOff:
            bluetoothStateText = "Bluetooth is off"
            isScanning = false
            for id in deviceStatuses.keys {
                deviceStatuses[id]?.isConnected = false
                deviceStatuses[id]?.isConnecting = false
            }
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
        if knownDevices.contains(where: { $0.id == id }) && connectedPeripherals[id] == nil {
            connect(peripheral: peripheral, name: savedName(for: id, fallback: name))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        let displayName = savedName(for: id, fallback: peripheral.name ?? "device")
        updateStatus(for: id) { status in
            status.isConnected = true
            status.isConnecting = false
            status.name = displayName
        }
        bluetoothStateText = "Connected"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        updateStatus(for: id) { status in
            status.isConnected = false
            status.isConnecting = false
        }
        connectedPeripherals.removeValue(forKey: id)
        bluetoothStateText = "Connection failed"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        updateStatus(for: id) { status in
            status.isConnected = false
            status.isConnecting = false
        }
        connectedPeripherals.removeValue(forKey: id)
        txCharacteristics.removeValue(forKey: id)
        rxCharacteristics.removeValue(forKey: id)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for peripheral in peripherals {
            let id = peripheral.identifier.uuidString
            peripheral.delegate = self
            connectedPeripherals[id] = peripheral
            updateStatus(for: id) { status in
                status.name = savedName(for: id, fallback: peripheral.name ?? status.name)
                status.isConnected = peripheral.state == .connected
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
            } else if txChar.properties.contains(.read) {
                peripheral.readValue(for: txChar)
            }
        }

        if let rxChar = service.characteristics?.first(where: { $0.uuid == Self.rxCharacteristicUUID }) {
            rxCharacteristics[id] = rxChar
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil,
              characteristic.uuid == Self.txCharacteristicUUID,
              let data = characteristic.value else { return }
        handleTelemetry(data, deviceID: peripheral.identifier.uuidString)
    }
}
