import Foundation

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
    @Published private(set) var syncStatus = "AppSync not configured"
    @Published private(set) var isSyncing = false

    private let apiClient: FamilyAPIClient
    private let groupCodeKey = "com.lifeloop.family.groupCode"
    private let linkedDeviceIDsKey = "com.lifeloop.family.linkedDeviceIDs"
    private let locationSharingEnabledKey = "com.lifeloop.family.locationSharingEnabled"
    private var uploadTasks: Set<String> = []
    private var lastRefreshDate: Date?

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
            familyDevices = try await apiClient.fetchFamilyDevices(groupCode: normalizedGroupCode)
            lastRefreshDate = Date()
            syncStatus = "Family devices updated"
        } catch {
            syncStatus = "AppSync fetch failed: \(error.localizedDescription)"
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
            syncStatus = "Link saved locally; AppSync failed: \(error.localizedDescription)"
        }
    }

    private func uploadTelemetry(_ payload: FamilyTelemetryPayload, uploadKey: String) async {
        do {
            try await apiClient.uploadTelemetry(payload)
            syncStatus = "Uploaded \(payload.displayName)"
        } catch {
            syncStatus = "Telemetry queued locally; AppSync failed: \(error.localizedDescription)"
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
}
