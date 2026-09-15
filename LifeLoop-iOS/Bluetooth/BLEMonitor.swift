import CoreBluetooth
import Foundation

/// iOS does not use an Android-style foreground Service or persistent
/// notification. Background BLE work is enabled with the `bluetooth-central`
/// background mode in Info.plist and is controlled by iOS.
///
/// This version supports connecting to several devices at once (e.g. one
/// band per family member), keeps a human-readable connection log for
/// debugging, and persists added devices so they reappear on next launch.

final class BLEMonitor: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    
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

    // MARK: Scanning

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            bluetoothStateText = "Bluetooth is not ready"
            log("Scan blocked — Bluetooth is not powered on")
            return
        }

        discoveredPeripherals.removeAll()
        isScanning = true
        bluetoothStateText = "Scanning for LifeLoop devices…"
        log("Started scanning")
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("Stopped scanning")
        if connectedPeripherals.isEmpty {
            bluetoothStateText = "Scan stopped"
        }
    }

    // MARK: Connecting

    /// Adds a scanned peripheral to the saved device list and immediately
    /// attempts to connect to it.
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
        log("Added \(displayName) to devices")
        connect(peripheral: discovered.peripheral, name: displayName)
    }

    /// Reconnects to a previously-added device. Only works if it's
    /// currently advertising / in range — CoreBluetooth can't dial a
    /// peripheral it hasn't seen recently.
    
    func connect(toKnown device: KnownDevice) {
        guard let uuid = UUID(uuidString: device.id) else { return }
        if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(peripheral: peripheral, name: device.name)
        } else {
            log("\(device.name) not nearby — start a scan to reconnect")
            bluetoothStateText = "\(device.name) not found nearby"
        }
    }

    func disconnect(deviceID: String) {
        guard let peripheral = connectedPeripherals[deviceID] else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func disconnect() {
        for peripheral in connectedPeripherals.values {
            centralManager.cancelPeripheralConnection(peripheral)
        }
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

                if let lastUpdated = status.lastUpdated {
                    let timeString = lastUpdated.formatted(date: .omitted, time: .shortened)
                    log("\(status.name) is offline since \(timeString)")
                } else {
                    log("\(status.name) went offline")
                }
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
        log("Renamed device to \(trimmedName)")
    }

    func removeKnownDevice(_ device: KnownDevice) {
        knownDevices.removeAll { $0.id == device.id }
        deviceStore.save(knownDevices)
        deviceStatuses.removeValue(forKey: device.id)
        if let peripheral = connectedPeripherals[device.id] {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        log("Removed \(device.name)")
    }

    private func connect(peripheral: CBPeripheral, name: String) {
        let id = peripheral.identifier.uuidString
        peripheral.delegate = self
        connectedPeripherals[id] = peripheral
        updateStatus(for: id) { status in
            status.name = name
            status.isConnecting = true
        }
        log("Connecting to \(name)…")
        centralManager.connect(peripheral)
    }

    // MARK: Telemetry parsing

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
            }
        }
    }

    /// Flexible parser for common prototype formats.
    /// Supported examples:
    ///   {"bpm":72,"state":1,"latitude":40.1,"longitude":-73.2}
    ///   bpm:72,state:1,latitude:40.1,longitude:-73.2
    ///   BPM: 72.0|state:1|Lat:40.1|Lon:-73.2
    ///   72,1,40.1,-73.2
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

        let values = pairs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.count >= 4 else { return nil }
        return LifeLoopState(
            bpm: Float(values[0]) ?? fallback.bpm,
            state: Int(values[1]) ?? fallback.state,
            latitude: Double(values[2]) ?? fallback.latitude,
            longitude: Double(values[3]) ?? fallback.longitude
        )
    }

    private func apply(dictionary: [String: Any], fallback: LifeLoopState) -> LifeLoopState {
        func doubleValue(_ keys: [String]) -> Double? {
            for key in keys {
                if let raw = dictionary[key], let value = parseDouble(raw) {
                    return value
                }
                if let match = dictionary.first(where: { $0.key.lowercased() == key }),
                   let value = parseDouble(match.value) {
                    return value
                }
            }
            return nil
        }

        let bpm = doubleValue(["bpm"]).map(Float.init) ?? fallback.bpm
        let state = doubleValue(["state"]).map(Int.init) ?? fallback.state
        let latitude = doubleValue(["latitude", "lat"]) ?? fallback.latitude
        let longitude = doubleValue(["longitude", "lon", "lng"]) ?? fallback.longitude

        return LifeLoopState(bpm: bpm, state: state, latitude: latitude, longitude: longitude)
    }

    private func parseDouble(_ raw: Any) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        guard let string = raw as? String else { return nil }
        if let value = Double(string) { return value }

        let allowedCharacters = CharacterSet(charactersIn: "-0123456789.")
        let numericString = string.unicodeScalars
            .filter { allowedCharacters.contains($0) }
            .map(String.init)
            .joined()
        return Double(numericString)
    }

    // MARK: Helpers

    private func updateStatus(for id: String, _ mutate: (inout DeviceStatus) -> Void) {
        var status = deviceStatuses[id] ?? DeviceStatus(deviceID: id, name: "Unknown device")
        mutate(&status)
        deviceStatuses[id] = status
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        connectionLog.insert("\(timestamp) — \(message)", at: 0)
        if connectionLog.count > 25 {
            connectionLog.removeLast()
        }
    }
}

extension BLEMonitor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStateText = "Bluetooth ready"
        case .poweredOff:
            bluetoothStateText = "Bluetooth is off"
            isScanning = false
            for id in deviceStatuses.keys {
                deviceStatuses[id]?.isConnected = false
                deviceStatuses[id]?.isConnecting = false
            }
        case .unauthorized:
            bluetoothStateText = "Bluetooth permission denied"
        case .unsupported:
            bluetoothStateText = "Bluetooth LE is unsupported"
        case .resetting:
            bluetoothStateText = "Bluetooth is resetting"
        case .unknown:
            bluetoothStateText = "Bluetooth state unknown"
        @unknown default:
            bluetoothStateText = "Bluetooth unavailable"
        }
        log(bluetoothStateText)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Unknown LifeLoop device"
        let discovered = DiscoveredPeripheral(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue
        )

        if let index = discoveredPeripherals.firstIndex(where: { $0.id == discovered.id }) {
            discoveredPeripherals[index] = discovered
        } else {
            discoveredPeripherals.append(discovered)
            log("Found \(name) (\(RSSI.intValue) dBm)")
        }

        // Auto-reconnect devices the user has already added when they
        // come back into range, without needing the Add Device sheet.
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
        log("Connected to \(displayName)")
        bluetoothStateText = "Connected"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier.uuidString
        updateStatus(for: id) { status in
            status.isConnected = false
            status.isConnecting = false
        }
        connectedPeripherals.removeValue(forKey: id)
        log("Failed to connect to \(peripheral.name ?? "device"): \(error?.localizedDescription ?? "unknown error")")
        bluetoothStateText = "Connection failed"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier.uuidString
        updateStatus(for: id) { status in
            status.isConnected = false
            status.isConnecting = false
        }
        connectedPeripherals.removeValue(forKey: id)
        txCharacteristics.removeValue(forKey: id)
        log(error == nil
            ? "Disconnected from \(peripheral.name ?? "device")"
            : "Connection lost to \(peripheral.name ?? "device"): \(error!.localizedDescription)")
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
        log("Restored \(peripherals.count) device(s) from background state")
    }
}

extension BLEMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            log("Service discovery failed for \(peripheral.name ?? "device"): \(error?.localizedDescription ?? "unknown error")")
            return
        }
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.txCharacteristicUUID], for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            log("Characteristic discovery failed for \(peripheral.name ?? "device"): \(error?.localizedDescription ?? "unknown error")")
            return
        }

        guard let characteristic = service.characteristics?.first(where: {
            $0.uuid == Self.txCharacteristicUUID
        }) else {
            log("Telemetry characteristic not found on \(peripheral.name ?? "device")")
            return
        }

        let id = peripheral.identifier.uuidString
        txCharacteristics[id] = characteristic
        log("Telemetry characteristic found on \(peripheral.name ?? "device")")
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
            log("Monitoring telemetry from \(peripheral.name ?? "device")")
        } else if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
            log("Reading telemetry from \(peripheral.name ?? "device")")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == Self.txCharacteristicUUID,
              let data = characteristic.value else { return }
        handleTelemetry(data, deviceID: peripheral.identifier.uuidString)
    }
}
