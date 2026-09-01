import CoreBluetooth
import Foundation

/// CoreBluetooth equivalent of the Android `BleMonitorService`.
///
/// iOS does not use an Android-style foreground Service or persistent
/// notification. Background BLE work is enabled with the `bluetooth-central`
/// background mode in Info.plist and is controlled by iOS.
/// 
final class BLEMonitor: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published private(set) var lifeLoopState = LifeLoopState()
    @Published private(set) var bluetoothStateText = "Starting Bluetooth…"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var lastPayload = ""

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?

    override init() {
        super.init()
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

        if let peripheral, peripheral.state == .connected {
            bluetoothStateText = "Already connected"
            return
        }

        isScanning = true
        bluetoothStateText = "Scanning for LifeLoop…"
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        if !isConnected {
            bluetoothStateText = "Scan stopped"
        }
    }

    func disconnect() {
        guard let peripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func connect(to discoveredPeripheral: CBPeripheral) {
        stopScanning()
        peripheral = discoveredPeripheral
        discoveredPeripheral.delegate = self
        connectedDeviceName = discoveredPeripheral.name
        bluetoothStateText = "Connecting…"
        centralManager.connect(discoveredPeripheral)
    }

    private func handleTelemetry(_ data: Data) {
        guard let payload = String(data: data, encoding: .utf8) else { return }
        let cleaned = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPayload = cleaned

        // Flexible parser for common prototype formats.
        // Supported examples:
        //   {"bpm":72,"state":1,"latitude":40.1,"longitude":-73.2}
        //   bpm:72,state:1,latitude:40.1,longitude:-73.2
        //   72,1,40.1,-73.2
        if let jsonData = cleaned.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            apply(dictionary: object)
            return
        }

        let pairs = cleaned.split(separator: ",")
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
            apply(dictionary: dictionary)
            return
        }

        let values = cleaned.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if values.count >= 4 {
            lifeLoopState = LifeLoopState(
                bpm: Float(values[0]) ?? lifeLoopState.bpm,
                state: Int(values[1]) ?? lifeLoopState.state,
                latitude: Double(values[2]) ?? lifeLoopState.latitude,
                longitude: Double(values[3]) ?? lifeLoopState.longitude
            )
        }
    }

    private func apply(dictionary: [String: Any]) {
        func doubleValue(_ keys: [String]) -> Double? {
            for key in keys {
                guard let raw = dictionary[key] ?? dictionary.first(where: { $0.key.lowercased() == key })?.value else { continue }
                if let number = raw as? NSNumber { return number.doubleValue }
                if let string = raw as? String, let value = Double(string) { return value }
            }
            return nil
        }

        let bpm = doubleValue(["bpm"]).map(Float.init) ?? lifeLoopState.bpm
        let state = doubleValue(["state"]).map(Int.init) ?? lifeLoopState.state
        let latitude = doubleValue(["latitude", "lat"]) ?? lifeLoopState.latitude
        let longitude = doubleValue(["longitude", "lon", "lng"]) ?? lifeLoopState.longitude

        lifeLoopState = LifeLoopState(
            bpm: bpm,
            state: state,
            latitude: latitude,
            longitude: longitude
        )
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
            isConnected = false
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
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedDeviceName = peripheral.name ?? "LifeLoop device"
        bluetoothStateText = "Connected"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        bluetoothStateText = "Connection failed"
        self.peripheral = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        connectedDeviceName = nil
        txCharacteristic = nil
        bluetoothStateText = error == nil ? "Disconnected" : "Connection lost"
        self.peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let restored = peripherals.first else { return }

        peripheral = restored
        restored.delegate = self
        connectedDeviceName = restored.name
        isConnected = restored.state == .connected
        bluetoothStateText = isConnected ? "Restored connection" : "Restored device"
    }
}

extension BLEMonitor: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            bluetoothStateText = "Service discovery failed"
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
            bluetoothStateText = "Characteristic discovery failed"
            return
        }

        guard let characteristic = service.characteristics?.first(where: {
            $0.uuid == Self.txCharacteristicUUID
        }) else {
            bluetoothStateText = "Telemetry characteristic not found"
            return
        }

        txCharacteristic = characteristic
        if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: characteristic)
            bluetoothStateText = "Monitoring telemetry"
        } else if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
            bluetoothStateText = "Reading telemetry"
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
        handleTelemetry(data)
    }
}
