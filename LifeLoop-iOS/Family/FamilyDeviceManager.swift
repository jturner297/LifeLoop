import Foundation
import CoreLocation
import Amplify

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
    @Published private(set) var activeCheckIns: [String: CloudCheckIn] = [:]
    @Published private(set) var incomingPing: CloudCheckIn?

    private let apiClient: FamilyAPIClient
    private let linkedKey: String
    private var lastRefresh: Date?
    private var lastUploads: [String: Date] = [:]
    private var lastUploadedStates: [String: Int] = [:]
    private var lastUploadedBPMs: [String: Float] = [:]
    private var uploading: Set<String> = []
    private var geocodingIDs: Set<String> = []
    private var lastLocations: [String: CLLocation] = [:]
    private var pendingInput: StartEmergencyInput?
    private var checkInSubscriptionTask: Task<Void, Never>?
    private var activeCheckInSequence: AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<CloudCheckIn>>?
    private var handledCheckInIDs: Set<String> = []

    init(apiClient: FamilyAPIClient = .shared, groupCode: String? = nil) {
        self.apiClient = apiClient
        let code = groupCode ?? ""
        self.groupCode = code
        linkedKey = "com.lifeloop.family.linkedDeviceIDs." + code
        linkedDeviceIDs = Set(UserDefaults.standard.stringArray(forKey: linkedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: "emergency.active." + code) {
            activeAlert = try? JSONDecoder().decode(CloudAlert.self, from: data)
        }
        NotificationCenter.default.addObserver(
            forName: .lifeLoopPingAcknowledged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let deviceID = notification.userInfo?["deviceID"] as? String else { return }
            Task { @MainActor in
                await self.acknowledgeCheckInIfNeeded(for: deviceID)
            }
        }
        ensureCheckInSubscription()
    }

    var hasGroup: Bool { !groupCode.isEmpty }
    private var sharesInformation: Bool { UserDefaults.standard.object(forKey: "profile.shareDeviceInformation") as? Bool ?? true }
    private var sharesLocation: Bool { UserDefaults.standard.object(forKey: "com.lifeloop.family.locationSharingEnabled") as? Bool ?? true }

    func stopSharing() {
        activeCheckInSequence?.cancel()
        activeCheckInSequence = nil
        checkInSubscriptionTask?.cancel()
        checkInSubscriptionTask = nil
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
            let status = statuses[device.id]
            let currentState = status?.lifeLoopState.state ?? 0
            let currentBPM = status?.lifeLoopState.bpm ?? 0
            let stateChanged = lastUploadedStates[device.id] != currentState
            let bpmChanged = currentBPM > 0 && abs(currentBPM - (lastUploadedBPMs[device.id] ?? 0)) >= 1.0
            guard !uploading.contains(device.id),
                  stateChanged || bpmChanged || Date().timeIntervalSince(lastUploads[device.id] ?? .distantPast) > 10 else { continue }
            uploading.insert(device.id)
            let code = groupCode
            let existingSnapshot = familyDevices.first(where: { $0.id == device.id })
            Task {
                defer { uploading.remove(device.id); lastUploads[device.id] = Date() }
                do {
                    try await apiClient.linkDevice(LinkDevicePayload(groupCode: code, deviceID: device.id, displayName: device.name))
                    guard hasGroup, sharesInformation, linkedDeviceIDs.contains(device.id) else { return }
                    let latestStatus = statuses[device.id]
                    let state = latestStatus?.lifeLoopState
                    let hasDeviceLocation = state.map { $0.latitude != 0 || $0.longitude != 0 } ?? false
                    let online = latestStatus?.isConnected == true
                    let rawLatitude = hasDeviceLocation ? state?.latitude ?? 0 : fallbackLatitude
                    let rawLongitude = hasDeviceLocation ? state?.longitude ?? 0 : fallbackLongitude
                    let latitude = rawLatitude != 0 ? rawLatitude : (existingSnapshot?.latitude ?? 0)
                    let longitude = rawLongitude != 0 ? rawLongitude : (existingSnapshot?.longitude ?? 0)
                    let hasValidLocation = sharesLocation && (latitude != 0 || longitude != 0)
                    let currentDeviceState = state?.state ?? 0
                    let liveBPM = state?.bpm ?? 0
                    let bpmToUpload = liveBPM > 0 ? liveBPM : (existingSnapshot?.bpm ?? 0)
                    let payload = FamilyTelemetryPayload(
                        groupCode: code,
                        deviceID: device.id,
                        displayName: device.name,
                        bpm: bpmToUpload,
                        state: currentDeviceState,
                        latitude: hasValidLocation ? latitude : 0,
                        longitude: hasValidLocation ? longitude : 0,
                        isLocationShared: hasValidLocation,
                        isOnline: online,
                        lastUpdated: latestStatus?.lastUpdated ?? existingSnapshot?.lastUpdated ?? Date()
                    )
                    try await apiClient.uploadTelemetry(payload)
                    lastUploadedStates[device.id] = currentDeviceState
                    if bpmToUpload > 0 {
                        lastUploadedBPMs[device.id] = bpmToUpload
                    }
                } catch { syncStatus = error.localizedDescription }
            }
        }
    }

    func refreshFamilyDevices(force: Bool = true) async {
        ensureCheckInSubscription()
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
        if let previous = lastLocations[device.id],
           let cached = addressCache[device.id],
           !cached.isEmpty,
           location.distance(from: previous) < 50 {
            return
        }
        guard !geocodingIDs.contains(device.id) else { return }
        geocodingIDs.insert(device.id)
        Task {
            defer { geocodingIDs.remove(device.id) }
            let geocoder = CLGeocoder()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
            let streetParts = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.filter { !$0.isEmpty }
            let streetLine = streetParts.isEmpty ? (placemark.name ?? "") : streetParts.joined(separator: " ")
            let cityState = [placemark.locality, placemark.administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            let cityStateZip = [cityState, placemark.postalCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let formatted = [streetLine, cityStateZip].filter { !$0.isEmpty }.joined(separator: ", ")
            if !formatted.isEmpty {
                addressCache[device.id] = formatted
                lastLocations[device.id] = location
            }
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

    func ensureCheckInSubscription() {
        guard hasGroup, checkInSubscriptionTask == nil else { return }
        let code = groupCode
        checkInSubscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hasGroup else { break }
                let sequence = self.apiClient.subscribeToCheckIns(code: code)
                self.activeCheckInSequence = sequence
                do {
                    for try await event in sequence {
                        if Task.isCancelled { break }
                        switch event {
                        case .connection(let state):
                            if state == .disconnected {
                                break
                            }
                        case .data(let result):
                            if case .success(let checkIn) = result {
                                self.handleCheckInUpdate(checkIn)
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                }
                sequence.cancel()
                self.activeCheckInSequence = nil
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run { [weak self] in
                self?.activeCheckInSequence?.cancel()
                self?.activeCheckInSequence = nil
                self?.checkInSubscriptionTask = nil
            }
        }
    }

    private func handleCheckInUpdate(_ checkIn: CloudCheckIn) {
        activeCheckIns[checkIn.targetDeviceID] = checkIn
        if checkIn.status == "PENDING" {
            syncStatus = "Check-in requested by \(checkIn.initiatorName)"
            if !handledCheckInIDs.contains(checkIn.checkInID) {
                handledCheckInIDs.insert(checkIn.checkInID)
                incomingPing = checkIn
                NotificationCenter.default.post(
                    name: .lifeLoopIncomingPing,
                    object: nil,
                    userInfo: ["targetDeviceID": checkIn.targetDeviceID]
                )
            }
        } else if checkIn.status == "SAFE" {
            syncStatus = "Check-in confirmed SAFE!"
        }
    }

    func requestCheckIn(for deviceID: String) async {
        ensureCheckInSubscription()
        syncStatus = "Sending check-in request..."
        do {
            let checkIn = try await apiClient.sendPing(code: groupCode, targetDeviceID: deviceID)
            activeCheckIns[deviceID] = checkIn
            syncStatus = "Check-in ping sent! Waiting for response..."
            if !handledCheckInIDs.contains(checkIn.checkInID) {
                handledCheckInIDs.insert(checkIn.checkInID)
                incomingPing = checkIn
                NotificationCenter.default.post(
                    name: .lifeLoopIncomingPing,
                    object: nil,
                    userInfo: ["targetDeviceID": checkIn.targetDeviceID]
                )
            }
        } catch {
            syncStatus = "Ping failed: \(error.localizedDescription)"
        }
    }

    func acknowledgeCheckInIfNeeded(for deviceID: String) async {
        guard let checkIn = activeCheckIns[deviceID], checkIn.status == "PENDING" else { return }
        do {
            let updated = try await apiClient.acknowledgePing(checkInID: checkIn.checkInID)
            activeCheckIns[deviceID] = updated
            lastUploads[deviceID] = .distantPast
            syncStatus = "Check-in confirmed SAFE!"
        } catch {
            syncStatus = "Acknowledge failed: \(error.localizedDescription)"
        }
    }
}
