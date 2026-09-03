import CoreBluetooth
import Foundation

struct LifeLoopState: Equatable {
    var bpm: Float = 0
    var state: Int = 0
    var latitude: Double = 0
    var longitude: Double = 0
}

/// A device the user has explicitly added. LifeLoop remembers it across
/// launches and tries to reconnect automatically whenever it's nearby.
struct KnownDevice: Identifiable, Codable, Equatable {
    let id: String
    var name: String
}

/// Live connection + telemetry state for a single device, keyed by the
/// same identifier as `KnownDevice.id` (the peripheral's UUID string).
struct DeviceStatus {
    let deviceID: String
    var name: String
    var isConnected: Bool = false
    var isConnecting: Bool = false
    var lifeLoopState: LifeLoopState = LifeLoopState()
    var lastPayload: String = ""
    var lastUpdated: Date?
}

/// A peripheral seen during a scan, before the user decides to add it.
struct DiscoveredPeripheral: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int

    static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        lhs.id == rhs.id
    }
}

/// Persists the user's added devices across launches using UserDefaults.
/// Swap this out for a Core Data / file-based store later without
/// touching BLEMonitor if the device list grows more complex.
struct DeviceStore {
    private let key = "com.lifeloop.knownDevices"

    func load() -> [KnownDevice] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownDevice].self, from: data)) ?? []
    }

    func save(_ devices: [KnownDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
