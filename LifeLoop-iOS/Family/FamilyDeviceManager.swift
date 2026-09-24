import Foundation
import UserNotifications
import CoreLocation
import Amplify
import Network

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

    // Offline queue & reachability
    private let pendingTelemetryKey = "com.lifeloop.family.pendingTelemetry"
    private let pendingAlertsKey = "com.lifeloop.family.pendingAlerts"
    private let monitor = NWPathMonitor()
    private var isNetworkReachable = true
    private var pendingTelemetry: [FamilyTelemetryPayload] = []
    private var pendingAlerts: [EmergencyAlertPayload] = []
    private var lastEmergencySentAt: Date?

    init(apiClient: FamilyAPIClient = .shared) {
        self.apiClient = apiClient
        groupCode = UserDefaults.standard.string(forKey: groupCodeKey) ?? ""
        linkedDeviceIDs = Set(UserDefaults.standard.stringArray(forKey: linkedDeviceIDsKey) ?? [])
        if UserDefaults.standard.object(forKey: locationSharingEnabledKey) == nil {
            isLocationSharingEnabled = true
        } else {
            isLocationSharingEnabled = UserDefaults.standard.bool(forKey: locationSharingEnabledKey)
        }

        loadPendingQueues()

        // Start reachability monitoring to flush when network is back
        let queue = DispatchQueue(label: "com.lifeloop.reachability")
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = path.status == .satisfied
            Task { @MainActor in
                self.isNetworkReachable = reachable
                if reachable {
                    _ = await self.flushPendingQueues()
                }
            }
        }
        monitor.start(queue: queue)
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
            let status = statuses[device.id]
            if let status, status.isConnected {
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
            } else {
                // Device is offline – periodically update AWS so family sees offline state
                let minuteBucket = Int(Date().timeIntervalSince1970 / 60)
                let uploadKey = "offline-\(device.id)-\(minuteBucket)"
                guard !uploadTasks.contains(uploadKey) else { continue }
                uploadTasks.insert(uploadKey)

                let payload = FamilyTelemetryPayload(
                    groupCode: normalizedGroupCode,
                    deviceID: device.id,
                    displayName: status?.name ?? device.name,
                    bpm: 0,
                    state: status?.lifeLoopState.state ?? 0,
                    latitude: 0,
                    longitude: 0,
                    isLocationShared: false,
                    isOnline: false,
                    lastUpdated: nil
                )
                Task {
                    await uploadTelemetry(payload, uploadKey: uploadKey)
                }
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
        // Emergency triggers: state == 2 (fall), state == 4 (emergency), or bpm in critical low range (0 < bpm <= 40)
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for device in current {
            let was = previousByID[device.id]
            let hadEmergencyBefore = (was?.state == 2) || (was?.state == 4) || ((was?.bpm ?? 0) > 0 && (was?.bpm ?? 0) <= 40)
            let hasEmergencyNow = (device.state == 2) || (device.state == 4) || (device.bpm > 0 && device.bpm <= 40)
            if hasEmergencyNow && !hadEmergencyBefore {
                var reason = "may need help."
                if device.state == 4 {
                    reason = "is in an EMERGENCY state!"
                } else if device.state == 2 {
                    reason = "has experienced a fall."
                } else if device.bpm > 0 && device.bpm <= 40 {
                    reason = "has critical BPM: \(Int(device.bpm))."
                }
                postLocalNotificationPublic(title: "Emergency: \(device.displayName)", body: "\(device.ownerName) \(reason)")
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
                Task { @MainActor in
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
            postLocalNotificationPublic(title: "Emergency Sent", body: "\(displayName): \(reason)")
        } catch {
            queueAlert(payload)
            syncStatus = "Emergency queued; AppSync failed: \(Self.describe(error))"
        }
    }

    private func uploadTelemetry(_ payload: FamilyTelemetryPayload, uploadKey: String) async {
        do {
            try await apiClient.uploadTelemetry(payload)
            syncStatus = "Uploaded \(payload.displayName)"
        } catch {
            queueTelemetry(payload)
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

    private func postLocalNotificationPublic(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Offline queue helpers

    private func loadPendingQueues() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: pendingTelemetryKey),
           let items = try? decoder.decode([FamilyTelemetryPayload].self, from: data) {
            pendingTelemetry = items
        }
        if let data = UserDefaults.standard.data(forKey: pendingAlertsKey),
           let items = try? decoder.decode([EmergencyAlertPayload].self, from: data) {
            pendingAlerts = items
        }
    }

    private func savePendingQueues() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(pendingTelemetry) {
            UserDefaults.standard.set(data, forKey: pendingTelemetryKey)
        }
        if let data = try? encoder.encode(pendingAlerts) {
            UserDefaults.standard.set(data, forKey: pendingAlertsKey)
        }
    }

    private func queueTelemetry(_ payload: FamilyTelemetryPayload) {
        pendingTelemetry.append(payload)
        savePendingQueues()
    }

    private func queueAlert(_ payload: EmergencyAlertPayload) {
        pendingAlerts.append(payload)
        savePendingQueues()
    }

    private func canSendNow() -> Bool { isNetworkReachable }

    func sendImmediateEmergencyFromApp(deviceID: String?, displayName: String, latitude: Double, longitude: Double, reason: String) {
        // Throttle duplicate sends if multiple triggers happen in quick succession
        if let last = lastEmergencySentAt, Date().timeIntervalSince(last) < 10 { return }
        lastEmergencySentAt = Date()
        Task { [weak self] in
            await self?.sendMyEmergencyAlert(deviceID: deviceID, displayName: displayName, latitude: latitude, longitude: longitude, reason: reason)
        }
        postLocalNotificationPublic(title: "EMS Alert Sent", body: "Immediate alert for \(displayName): \(reason)")
    }

    func cancelEmergency(for device: FamilyDeviceSnapshot) async {
        guard hasGroup else { return }
        let payload = CancelEmergencyPayload(
            groupCode: normalizedGroupCode,
            targetDeviceID: device.id,
            reason: "Admin cancel request",
            timestamp: Date()
        )
        do {
            try await apiClient.cancelEmergencyAlert(payload)
            syncStatus = "Requested cancel for \(device.displayName)"
            postLocalNotificationPublic(title: "Requested EMS Cancel", body: "Sent cancel for \(device.ownerName)")
        } catch {
            queueCancelEmergency(payload)
            syncStatus = "Cancel queued; AppSync failed: \(Self.describe(error))"
        }
    }

    private func queueCancelEmergency(_ payload: CancelEmergencyPayload) {
        // Represent as an EmergencyAlertPayload with reason to reuse storage or keep a dedicated path?
        // Keep a dedicated path by piggybacking on alerts array via a special reason
        let adapted = EmergencyAlertPayload(
            groupCode: payload.groupCode,
            deviceID: payload.targetDeviceID,
            displayName: "[CANCEL]",
            latitude: 0,
            longitude: 0,
            reason: payload.reason,
            timestamp: payload.timestamp
        )
        pendingAlerts.append(adapted)
        savePendingQueues()
    }

    private func isCancelMarker(_ alert: EmergencyAlertPayload) -> Bool {
        alert.displayName == "[CANCEL]"
    }

    private func flushPendingCancel(_ alert: EmergencyAlertPayload) async throws {
        let payload = CancelEmergencyPayload(
            groupCode: alert.groupCode,
            targetDeviceID: alert.deviceID ?? "",
            reason: alert.reason,
            timestamp: alert.timestamp
        )
        try await apiClient.cancelEmergencyAlert(payload)
    }

    @discardableResult
    private func flushPendingQueues() async -> (sentTelemetry: Int, sentAlerts: Int) {
        guard canSendNow() else { return (0, 0) }
        var sentT = 0
        var sentA = 0

        // Flush telemetry
        if !pendingTelemetry.isEmpty {
            var remaining: [FamilyTelemetryPayload] = []
            for item in pendingTelemetry {
                do {
                    try await apiClient.uploadTelemetry(item)
                    sentT += 1
                } catch {
                    remaining.append(item)
                }
            }
            pendingTelemetry = remaining
        }

        // Flush alerts (support both normal and cancel markers)
        if !pendingAlerts.isEmpty {
            var remaining: [EmergencyAlertPayload] = []
            for item in pendingAlerts {
                do {
                    if isCancelMarker(item) {
                        try await flushPendingCancel(item)
                    } else {
                        try await apiClient.sendEmergencyAlert(item)
                    }
                    sentA += 1
                } catch {
                    remaining.append(item)
                }
            }
            pendingAlerts = remaining
        }

        savePendingQueues()
        return (sentT, sentA)
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
