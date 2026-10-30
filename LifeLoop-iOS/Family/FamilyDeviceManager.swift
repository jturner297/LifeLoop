import Foundation
import CoreLocation

struct MemberEvent: Identifiable, Codable {
    let id: UUID
    let deviceID: String
    let title: String
    let date: Date
}

@MainActor
final class FamilyDeviceManager: ObservableObject {
    @Published var groupCode: String
    @Published private(set) var linkedDeviceIDs: Set<String>
    @Published private(set) var familyDevices: [FamilyDeviceSnapshot] = []
    @Published private(set) var recentEvents: [MemberEvent] = []
    @Published private(set) var alerts: [CloudAlert] = []
    @Published private(set) var addressCache: [String: String] = [:]
    @Published private(set) var syncStatus = "Ready to sync"
    @Published private(set) var isSyncing = false
    @Published private(set) var activeAlert: CloudAlert?
    @Published private(set) var emergencyError: String?

    private let apiClient: FamilyAPIClient
    private let linkedKey: String
    private var lastRefresh: Date?
    private var lastUploads: [String: Date] = [:]
    private var uploading: Set<String> = []
    private let geocoder = CLGeocoder()
    private var lastLocations: [String: CLLocation] = [:]
    private var pendingInput: StartEmergencyInput?

    init(apiClient: FamilyAPIClient = .shared, groupCode: String? = nil) {
        self.apiClient = apiClient
        let code = groupCode ?? ""
        self.groupCode = code
        linkedKey = "com.lifeloop.family.linkedDeviceIDs." + code
        linkedDeviceIDs = Set(UserDefaults.standard.stringArray(forKey: linkedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: "emergency.active." + code) {
            activeAlert = try? JSONDecoder().decode(CloudAlert.self, from: data)
        }
    }

    var hasGroup: Bool { !groupCode.isEmpty }
    private var sharesInformation: Bool { UserDefaults.standard.object(forKey: "profile.shareDeviceInformation") as? Bool ?? true }
    private var sharesLocation: Bool { UserDefaults.standard.object(forKey: "com.lifeloop.family.locationSharingEnabled") as? Bool ?? true }

    func stopSharing() {
        linkedDeviceIDs = []
        UserDefaults.standard.set([], forKey: linkedKey)
        groupCode = ""
    }

    func toggleLink(for device: KnownDevice) {
        if linkedDeviceIDs.contains(device.id) {
            linkedDeviceIDs.remove(device.id)
        } else {
            linkedDeviceIDs.insert(device.id)
        }
        UserDefaults.standard.set(Array(linkedDeviceIDs), forKey: linkedKey)
    }

    func uploadLocalDevices(_ devices: [KnownDevice], statuses: [String: DeviceStatus], fallbackLatitude: Double, fallbackLongitude: Double) {
        guard hasGroup, sharesInformation else { return }
        for device in devices where linkedDeviceIDs.contains(device.id) {
            guard !uploading.contains(device.id), Date().timeIntervalSince(lastUploads[device.id] ?? .distantPast) > 15 else { continue }
            uploading.insert(device.id)
            let code = groupCode
            Task {
                defer { uploading.remove(device.id); lastUploads[device.id] = Date() }
                do {
                    try await apiClient.linkDevice(LinkDevicePayload(groupCode: code, deviceID: device.id, displayName: device.name))
                    guard hasGroup, sharesInformation, linkedDeviceIDs.contains(device.id) else { return }
                    let status = statuses[device.id]
                    let state = status?.lifeLoopState
                    let hasDeviceLocation = state.map { $0.latitude != 0 || $0.longitude != 0 } ?? false
                    let online = status?.isConnected == true
                    let latitude = hasDeviceLocation ? state?.latitude ?? 0 : fallbackLatitude
                    let longitude = hasDeviceLocation ? state?.longitude ?? 0 : fallbackLongitude
                    let payload = FamilyTelemetryPayload(groupCode: code, deviceID: device.id, displayName: device.name,
                        bpm: online ? state?.bpm ?? 0 : 0, state: state?.state ?? 0,
                        latitude: sharesLocation && online ? latitude : 0,
                        longitude: sharesLocation && online ? longitude : 0,
                        isLocationShared: sharesLocation && online, isOnline: online, lastUpdated: status?.lastUpdated)
                    try await apiClient.uploadTelemetry(payload)
                } catch { syncStatus = error.localizedDescription }
            }
        }
    }

    func refreshFamilyDevices(force: Bool = true) async {
        guard hasGroup, !isSyncing else { return }
        if !force && Date().timeIntervalSince(lastRefresh ?? .distantPast) < 10 { return }
        isSyncing = true
        defer { isSyncing = false; lastRefresh = Date() }
        do {
            familyDevices = try await apiClient.fetchFamilyDevices(groupCode: groupCode)
            alerts = try await apiClient.alerts(code: groupCode)
            if let current = activeAlert, let updated = alerts.first(where: { $0.id == current.id }) {
                activeAlert = updated
                persistActiveAlert()
            }
            LoopNotifications.shared.receive(alerts)
            syncStatus = "Updated " + Date().formatted(date: .omitted, time: .shortened)
            for device in familyDevices { resolveAddress(for: device) }
        } catch { syncStatus = error.localizedDescription }
    }

    func resolveAddress(for device: FamilyDeviceSnapshot) {
        guard device.isLocationShared, device.latitude != 0 || device.longitude != 0 else {
            addressCache.removeValue(forKey: device.id)
            return
        }
        let location = CLLocation(latitude: device.latitude, longitude: device.longitude)
        if let previous = lastLocations[device.id], location.distance(from: previous) < 100 { return }
        lastLocations[device.id] = location
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            let address = placemarks?.first.map { [$0.locality, $0.administrativeArea].compactMap { $0 }.joined(separator: ", ") }
            Task { @MainActor in self?.addressCache[device.id] = address }
        }
    }

    /// Called at countdown start. AWS owns the grace period, and alertID stays stable on retry.
    @discardableResult
    func sendMyEmergencyAlert(deviceID: String?, displayName: String, latitude: Double, longitude: Double, reason: String) async -> Bool {
        guard hasGroup else { return false }
        emergencyError = nil
        let input = pendingInput ?? StartEmergencyInput(alertID: UUID().uuidString, groupCode: groupCode, deviceID: deviceID, displayName: displayName, latitude: sharesLocation ? latitude : 0, longitude: sharesLocation ? longitude : 0, reason: reason)
        pendingInput = input
        do {
            activeAlert = try await apiClient.startEmergency(input)
            persistActiveAlert()
            syncStatus = "Family alert created"
            return true
        } catch {
            emergencyError = error.localizedDescription
            syncStatus = "Alert delivery unconfirmed: " + error.localizedDescription
            // Do not replay a stale SOS automatically later.
            return false
        }
    }

    func beginEmergencySession() {
        pendingInput = nil
        emergencyError = nil
    }

    func cancelMyOwnEmergency(deviceID: String?, displayName: String) async {
        guard let id = pendingInput?.alertID ?? activeAlert?.alertID else { return }
        do {
            activeAlert = try await apiClient.cancelEmergency(alertID: id)
            persistActiveAlert()
            pendingInput = nil
            emergencyError = nil
            syncStatus = "Alert canceled before calls"
        } catch {
            emergencyError = error.localizedDescription
            syncStatus = "Cancellation not confirmed: " + error.localizedDescription
        }
    }

    func cancelAlert(_ alert: CloudAlert) async {
        do {
            let updated = try await apiClient.cancelEmergency(alertID: alert.id)
            alerts = alerts.map { $0.id == updated.id ? updated : $0 }
            if activeAlert?.id == updated.id { activeAlert = updated; persistActiveAlert() }
            syncStatus = "Alert canceled"
            LoopNotifications.shared.receive([updated])
        } catch { syncStatus = "Cancellation not confirmed: " + error.localizedDescription }
    }

    func cancelEmergency(for device: FamilyDeviceSnapshot) async {
        for alert in alerts where alert.deviceID == device.id && alert.status == "PENDING" {
            await cancelAlert(alert)
        }
    }

    private func persistActiveAlert() {
        UserDefaults.standard.set(try? JSONEncoder().encode(activeAlert), forKey: "emergency.active." + groupCode)
    }
    
    func requestCheckIn(for deviceID: String) async {
        syncStatus = "Sending check-in request..."
        do {
            _ = try await apiClient.sendPing(code: groupCode, targetDeviceID: deviceID)
            syncStatus = "Check-in ping sent!"
        } catch {
            syncStatus = "Ping failed: \(error.localizedDescription)"
        }
    }
}
