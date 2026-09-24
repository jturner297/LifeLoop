import Foundation
import UserNotifications
import CoreLocation
import Amplify

@MainActor
final class FamilyDeviceManager: ObservableObject {
    @Published var groupCode: String
    @Published private(set) var linkedDeviceIDs: Set<String>
    @Published var isLocationSharingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLocationSharingEnabled, forKey: locationSharingEnabledKey)
            syncStatus = isLocationSharingEnabled ? "Map location sharing is on" : "Map location sharing is off"
        }
    }
    @Published private(set) var familyDevices: [FamilyDeviceSnapshot] = []
    @Published private(set) var addressCache: [String: String] = [:] // deviceID -> address
    @Published private(set) var syncStatus = "AppSync not configured"
    @Published private(set) var isSyncing = false

    private let apiClient: FamilyAPIClient
    private let groupCodeKey = "com.lifeloop.family.groupCode"
    private let linkedDeviceIDsKey = "com.lifeloop.family.linkedDeviceIDs"
    private let locationSharingEnabledKey = "com.lifeloop.family.locationSharingEnabled"
    private var uploadTasks: Set<String> = []
    private var lastRefreshDate: Date?
    private let geocoder = CLGeocoder()
    private var lastGeocode: [String: Date] = [:]

    init(apiClient: FamilyAPIClient = .shared) {
        self.apiClient = apiClient
        groupCode = UserDefaults.standard.string(forKey: groupCodeKey) ?? ""
        linkedDeviceIDs = Set(UserDefaults.standard.stringArray(forKey: linkedDeviceIDsKey) ?? [])
        if UserDefaults.standard.object(forKey: locationSharingEnabledKey) == nil {
            isLocationSharingEnabled = true
        } else {
            isLocationSharingEnabled = UserDefaults.standard.bool(forKey: locationSharingEnabledKey)
        }
    }

    var hasGroup: Bool {
        !normalizedGroupCode.isEmpty
    }

    func saveGroupCode() {
        UserDefaults.standard.set(normalizedGroupCode, forKey: groupCodeKey)
        groupCode = normalizedGroupCode
        syncStatus = hasGroup ? "Family group saved" : "Enter a family group code"
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func toggleLink(for device: KnownDevice) {
        if linkedDeviceIDs.contains(device.id) {
            linkedDeviceIDs.remove(device.id)
            saveLinkedDeviceIDs()
            syncStatus = "Stopped sharing \(device.name)"
        } else {
            linkedDeviceIDs.insert(device.id)
            saveLinkedDeviceIDs()
            syncStatus = "Sharing \(device.name) with family"
            Task {
                await linkDevice(device)
            }
        }
    }

    func uploadLocalDevices(
        _ devices: [KnownDevice],
        statuses: [String: DeviceStatus],
        fallbackLatitude: Double,
        fallbackLongitude: Double
    ) {
        guard hasGroup else { return }

        for device in devices where linkedDeviceIDs.contains(device.id) {
            guard let status = statuses[device.id], status.isConnected else { continue }
            let sharedCoordinate = coordinateForSharing(
                status: status,
                fallbackLatitude: fallbackLatitude,
                fallbackLongitude: fallbackLongitude
            )
            let payload = FamilyTelemetryPayload(
                groupCode: normalizedGroupCode,
                deviceID: device.id,
                displayName: status.name,
                bpm: status.lifeLoopState.bpm,
                state: status.lifeLoopState.state,
                latitude: sharedCoordinate.latitude,
                longitude: sharedCoordinate.longitude,
                isLocationShared: isLocationSharingEnabled,
                isOnline: status.isConnected,
                lastUpdated: status.lastUpdated
            )
            let uploadKey = "\(device.id)-\(Int(status.lastUpdated?.timeIntervalSince1970 ?? 0))"
            guard !uploadTasks.contains(uploadKey) else { continue }
            uploadTasks.insert(uploadKey)

            Task {
                await uploadTelemetry(payload, uploadKey: uploadKey)
            }
        }
    }

    func refreshFamilyDevices(force: Bool = true) async {
        guard hasGroup else {
            syncStatus = "Enter a family group code"
            return
        }
        if !force,
           let lastRefreshDate,
           Date().timeIntervalSince(lastRefreshDate) < 15 {
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let previous = familyDevices
            let fetched = try await apiClient.fetchFamilyDevices(groupCode: normalizedGroupCode)
            familyDevices = fetched
            lastRefreshDate = Date()
            syncStatus = "Family devices updated"
            // Emergency detection and address resolution
            notifyIfEmergencyDetected(previous: previous, current: fetched)
            fetched.forEach { resolveAddress(for: $0) }
        } catch {
            syncStatus = "AppSync fetch failed: \(Self.describe(error))"
        }
    }

    private func notifyIfEmergencyDetected(previous: [FamilyDeviceSnapshot], current: [FamilyDeviceSnapshot]) {
        // Simple heuristic: state == 2 (fall) or bpm in critical low range (0 < bpm <= 40)
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for device in current {
            let was = previousByID[device.id]
            let hadEmergencyBefore = (was?.state == 2) || ((was?.bpm ?? 0) > 0 && (was?.bpm ?? 0) <= 40)
            let hasEmergencyNow = (device.state == 2) || (device.bpm > 0 && device.bpm <= 40)
            if hasEmergencyNow && !hadEmergencyBefore {
                postLocalNotification(title: "Emergency: \(device.displayName)", body: "\(device.ownerName) may need help.")
            }
        }
    }

    func resolveAddress(for device: FamilyDeviceSnapshot) {
        guard device.isLocationShared, (device.latitude != 0 || device.longitude != 0) else { return }
        let key = device.id
        if let _ = addressCache[key] { return }
        let now = Date()
        if let last = lastGeocode[key], now.timeIntervalSince(last) < 60 { return }
        lastGeocode[key] = now
        let location = CLLocation(latitude: device.latitude, longitude: device.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self else { return }
            if let placemark = placemarks?.first, error == nil {
                let streetNum = placemark.subThoroughfare ?? ""
                let streetName = placemark.thoroughfare ?? ""
                let city = placemark.locality ?? ""
                let state = placemark.administrativeArea ?? ""
                let address = "\(streetNum) \(streetName), \(city) \(state)".trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.addressCache[key] = address.isEmpty ? String(format: "%.5f, %.5f", device.latitude, device.longitude) : address
                }
            }
        }
    }

    private func linkDevice(_ device: KnownDevice) async {
        guard hasGroup else { return }

        do {
            try await apiClient.linkDevice(LinkDevicePayload(
                groupCode: normalizedGroupCode,
                deviceID: device.id,
                displayName: device.name
            ))
            syncStatus = "Linked \(device.name)"
        } catch {
            syncStatus = "Link saved locally; AppSync failed: \(Self.describe(error))"
        }
    }

    func sendMyEmergencyAlert(deviceID: String?, displayName: String, latitude: Double, longitude: Double, reason: String) async {
        guard hasGroup else { return }
        let payload = EmergencyAlertPayload(
            groupCode: normalizedGroupCode,
            deviceID: deviceID,
            displayName: displayName,
            latitude: latitude,
            longitude: longitude,
            reason: reason,
            timestamp: Date()
        )
        do {
            try await apiClient.sendEmergencyAlert(payload)
            syncStatus = "Emergency alert sent"
        } catch {
            syncStatus = "Failed to send emergency: \(Self.describe(error))"
        }
    }

    private func uploadTelemetry(_ payload: FamilyTelemetryPayload, uploadKey: String) async {
        do {
            try await apiClient.uploadTelemetry(payload)
            syncStatus = "Uploaded \(payload.displayName)"
        } catch {
            syncStatus = "Telemetry queued locally; AppSync failed: \(Self.describe(error))"
        }
        uploadTasks.remove(uploadKey)
    }

    private func coordinateForSharing(
        status: DeviceStatus,
        fallbackLatitude: Double,
        fallbackLongitude: Double
    ) -> (latitude: Double, longitude: Double) {
        guard isLocationSharingEnabled else { return (0, 0) }

        if status.lifeLoopState.latitude != 0 || status.lifeLoopState.longitude != 0 {
            return (status.lifeLoopState.latitude, status.lifeLoopState.longitude)
        }
        return (fallbackLatitude, fallbackLongitude)
    }

    private var normalizedGroupCode: String {
        groupCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func saveLinkedDeviceIDs() {
        UserDefaults.standard.set(Array(linkedDeviceIDs), forKey: linkedDeviceIDsKey)
    }

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Unwraps Amplify's APIError (and any underlying error it wraps) to produce
    /// a real, readable description instead of Swift's generic "error 3" fallback.
    /// Also prints full detail to the console for debugging.
    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            print("🔴 Full APIError: \(apiError)")
            if let underlying = apiError.underlyingError {
                print("🔴 Underlying error: \(underlying)")
            }
            return apiError.errorDescription
        } else {
            print("🔴 Non-APIError: \(error)")
            return error.localizedDescription
        }
    }
}
