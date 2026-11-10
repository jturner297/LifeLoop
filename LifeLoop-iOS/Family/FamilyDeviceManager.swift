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
    @Published private(set) var removedDeviceIDs: Set<String>
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
    private let removedKey: String
    private let checkInsKey: String
    private var lastRefresh: Date?
    private var lastUploads: [String: Date] = [:]
    private var lastUploadedStates: [String: Int] = [:]
    private var lastUploadedBPMs: [String: Float] = [:]
    private var connectedInSession: Set<String> = []
    private var pendingCheckInSentAt: [String: Date] = [:]
    private var observedHardwarePingDevices: Set<String> = []
    private var uploading: Set<String> = []
    private var geocodingIDs: Set<String> = []
    private var lastLocations: [String: CLLocation] = [:]
    private var lastGeocodeAttempts: [String: Date] = [:]
    private var pendingInput: StartEmergencyInput?
    private var checkInSubscriptionTask: Task<Void, Never>?
    private var activeCheckInSequence: AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<CloudCheckIn>>?
    private var alertSubscriptionTask: Task<Void, Never>?
    private var activeAlertSequence: AmplifyAsyncThrowingSequence<GraphQLSubscriptionEvent<CloudAlert>>?
    private var handledCheckInIDs: Set<String> = []
    private var linkedDeviceKeys: Set<String> = []

    init(apiClient: FamilyAPIClient = .shared, groupCode: String? = nil) {
        self.apiClient = apiClient
        let code = groupCode ?? ""
        self.groupCode = code
        linkedKey = "com.lifeloop.family.linkedDeviceIDs." + code
        removedKey = "com.lifeloop.family.removedDeviceIDs." + code
        checkInsKey = "checkin.active." + code
        linkedDeviceIDs = Set(UserDefaults.standard.stringArray(forKey: linkedKey) ?? [])
        removedDeviceIDs = Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: "emergency.active." + code) {
            activeAlert = try? JSONDecoder().decode(CloudAlert.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: checkInsKey),
           let savedCheckIns = try? JSONDecoder().decode([String: CloudCheckIn].self, from: data) {
            activeCheckIns = savedCheckIns
            for checkIn in savedCheckIns.values {
                handledCheckInIDs.insert(checkIn.checkInID)
            }
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
        ensureAlertSubscription()
    }

    var hasGroup: Bool { !groupCode.isEmpty }
    private var sharesInformation: Bool { UserDefaults.standard.object(forKey: "profile.shareDeviceInformation") as? Bool ?? true }
    private var sharesLocation: Bool { UserDefaults.standard.object(forKey: "com.lifeloop.family.locationSharingEnabled") as? Bool ?? true }

    func stopSharing() {
        activeCheckInSequence?.cancel()
        activeCheckInSequence = nil
        checkInSubscriptionTask?.cancel()
        checkInSubscriptionTask = nil
        activeAlertSequence?.cancel()
        activeAlertSequence = nil
        alertSubscriptionTask?.cancel()
        alertSubscriptionTask = nil
        linkedDeviceIDs = []
        UserDefaults.standard.set([], forKey: linkedKey)
        groupCode = ""
    }

    func toggleLink(for device: KnownDevice) {
        if linkedDeviceIDs.contains(device.id) {
            removeDevice(deviceID: device.id)
        } else {
            removedDeviceIDs.remove(device.id)
            UserDefaults.standard.set(Array(removedDeviceIDs), forKey: removedKey)
            linkedDeviceIDs.insert(device.id)
            UserDefaults.standard.set(Array(linkedDeviceIDs), forKey: linkedKey)
            linkedDeviceKeys = linkedDeviceKeys.filter { !$0.contains(":\(device.id):") }
        }
    }

    func removeDevice(deviceID: String) {
        linkedDeviceIDs.remove(deviceID)
        UserDefaults.standard.set(Array(linkedDeviceIDs), forKey: linkedKey)
        removedDeviceIDs.insert(deviceID)
        UserDefaults.standard.set(Array(removedDeviceIDs), forKey: removedKey)
        connectedInSession.remove(deviceID)
        familyDevices.removeAll { $0.id == deviceID }
        addressCache.removeValue(forKey: deviceID)
        lastLocations.removeValue(forKey: deviceID)
        lastUploads.removeValue(forKey: deviceID)
        lastUploadedStates.removeValue(forKey: deviceID)
        lastUploadedBPMs.removeValue(forKey: deviceID)
        linkedDeviceKeys = linkedDeviceKeys.filter { !$0.contains(":\(deviceID):") }
        
        guard hasGroup else { return }
        let code = groupCode
        Task {
            do {
                let payload = FamilyTelemetryPayload(
                    groupCode: code,
                    deviceID: deviceID,
                    displayName: "[REMOVED]",
                    bpm: 0,
                    state: -1,
                    latitude: 0,
                    longitude: 0,
                    isLocationShared: false,
                    isOnline: false,
                    lastUpdated: Date()
                )
                try await apiClient.uploadTelemetry(payload)
            } catch {
                print("Failed to notify cloud of removed device: \(error)")
            }
        }
    }

    func uploadLocalDevices(_ devices: [KnownDevice], statuses: [String: DeviceStatus], fallbackLatitude: Double, fallbackLongitude: Double) {
        guard hasGroup, sharesInformation else { return }
        for device in devices where linkedDeviceIDs.contains(device.id) {
            let status = statuses[device.id]
            let online = status?.isConnected == true
            let existingSnapshot = familyDevices.first(where: { $0.id == device.id })
            if online {
                connectedInSession.insert(device.id)
            } else {
                let wasConnected = connectedInSession.remove(device.id) != nil
                let cloudThinksOnline = existingSnapshot?.isOnline == true
                guard wasConnected || cloudThinksOnline else { continue }
            }
            let rawState = online ? (status?.lifeLoopState.state ?? 0) : 0
            let pendingPingWindow = Date().timeIntervalSince(pendingCheckInSentAt[device.id] ?? .distantPast) < 8
            let currentState = (online && rawState == 0 && activeCheckIns[device.id]?.status == "PENDING" && pendingPingWindow) ? 5 : rawState
            let currentBPM: Float = online ? (status?.lifeLoopState.bpm ?? 0) : 0
            let stateChanged = lastUploadedStates[device.id] != currentState
            let bpmChanged = lastUploadedBPMs[device.id].map { abs(currentBPM - $0) >= 1.0 } ?? true
            let onlineChanged = existingSnapshot?.isOnline != online
            guard !uploading.contains(device.id),
                  stateChanged || bpmChanged || onlineChanged || Date().timeIntervalSince(lastUploads[device.id] ?? .distantPast) > 4 else { continue }
            uploading.insert(device.id)
            let code = groupCode
            Task {
                defer { uploading.remove(device.id); lastUploads[device.id] = Date() }
                do {
                    let linkKey = "\(code):\(device.id):\(device.name)"
                    if !linkedDeviceKeys.contains(linkKey) {
                        try await apiClient.linkDevice(LinkDevicePayload(groupCode: code, deviceID: device.id, displayName: device.name))
                        linkedDeviceKeys.insert(linkKey)
                    }
                    guard hasGroup, sharesInformation, linkedDeviceIDs.contains(device.id) else { return }
                    let latestStatus = statuses[device.id]
                    let state = latestStatus?.lifeLoopState
                    let hasDeviceLocation = state.map { $0.latitude != 0 || $0.longitude != 0 } ?? false
                    let isCurrentlyOnline = latestStatus?.isConnected == true
                    let rawLatitude = hasDeviceLocation ? state?.latitude ?? 0 : fallbackLatitude
                    let rawLongitude = hasDeviceLocation ? state?.longitude ?? 0 : fallbackLongitude
                    let latitude = rawLatitude != 0 ? rawLatitude : (existingSnapshot?.latitude ?? 0)
                    let longitude = rawLongitude != 0 ? rawLongitude : (existingSnapshot?.longitude ?? 0)
                    let hasValidLocation = sharesLocation && (latitude != 0 || longitude != 0)
                    let latestRawState = isCurrentlyOnline ? (state?.state ?? 0) : 0
                    let stillInPingWindow = Date().timeIntervalSince(pendingCheckInSentAt[device.id] ?? .distantPast) < 8
                    let currentDeviceState = (isCurrentlyOnline && latestRawState == 0 && activeCheckIns[device.id]?.status == "PENDING" && stillInPingWindow) ? 5 : latestRawState
                    let liveBPM: Float = isCurrentlyOnline ? (state?.bpm ?? 0) : 0
                    let payload = FamilyTelemetryPayload(
                        groupCode: code,
                        deviceID: device.id,
                        displayName: device.name,
                        bpm: liveBPM,
                        state: currentDeviceState,
                        latitude: hasValidLocation ? latitude : 0,
                        longitude: hasValidLocation ? longitude : 0,
                        isLocationShared: hasValidLocation,
                        isOnline: isCurrentlyOnline,
                        lastUpdated: latestStatus?.lastUpdated ?? Date()
                    )
                    try await apiClient.uploadTelemetry(payload)
                    lastUploadedStates[device.id] = currentDeviceState
                    lastUploadedBPMs[device.id] = liveBPM
                } catch { syncStatus = error.localizedDescription }
            }
        }
    }

    func refreshFamilyDevices(force: Bool = true) async {
        ensureCheckInSubscription()
        ensureAlertSubscription()
        guard hasGroup, !isSyncing else { return }
        if !force && Date().timeIntervalSince(lastRefresh ?? .distantPast) < 3 { return }
        isSyncing = true
        defer { isSyncing = false; lastRefresh = Date() }
        do {
            var fetchedDevices = try await apiClient.fetchFamilyDevices(groupCode: groupCode)
                .filter { !removedDeviceIDs.contains($0.id) && $0.state != -1 && $0.displayName != "[REMOVED]" }
            var checkInsChanged = false
            for index in fetchedDevices.indices {
                let device = fetchedDevices[index]
                if device.state == 5 {
                    observedHardwarePingDevices.insert(device.id)
                    if activeCheckIns[device.id]?.status != "PENDING" {
                        activeCheckIns[device.id] = CloudCheckIn(
                            checkInID: activeCheckIns[device.id]?.checkInID ?? UUID().uuidString,
                            groupCode: groupCode,
                            targetDeviceID: device.id,
                            initiatorName: activeCheckIns[device.id]?.initiatorName ?? "Family member",
                            status: "PENDING",
                            createdAt: activeCheckIns[device.id]?.createdAt ?? ISO8601DateFormatter().string(from: Date()),
                            resolvedAt: nil
                        )
                        checkInsChanged = true
                    }
                } else if let checkIn = activeCheckIns[device.id], checkIn.status == "PENDING" {
                    if observedHardwarePingDevices.contains(device.id) && device.state == 0 {
                        observedHardwarePingDevices.remove(device.id)
                        activeCheckIns[device.id] = CloudCheckIn(
                            checkInID: checkIn.checkInID,
                            groupCode: checkIn.groupCode,
                            targetDeviceID: checkIn.targetDeviceID,
                            initiatorName: checkIn.initiatorName,
                            status: "SAFE",
                            createdAt: checkIn.createdAt,
                            resolvedAt: ISO8601DateFormatter().string(from: Date())
                        )
                        checkInsChanged = true
                    } else if device.state == 0 {
                        // Keep state 5 reflected locally while the pending check-in awaits hardware/cloud sync
                        fetchedDevices[index].state = 5
                    }
                }
            }
            if checkInsChanged {
                persistActiveCheckIns()
            }
            familyDevices = fetchedDevices
            alerts = try await apiClient.alerts(code: groupCode)
            if let current = activeAlert, let updated = alerts.first(where: { $0.id == current.id }) {
                activeAlert = updated
                persistActiveAlert()
            }
            LoopNotifications.shared.receive(alerts)
            if let pending = activeCheckIns.values.first(where: { $0.status == "PENDING" }) {
                syncStatus = "Check-in pending (requested by \(pending.initiatorName)) — waiting for response..."
            } else {
                syncStatus = "Updated " + Date().formatted(date: .omitted, time: .shortened)
            }
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
        if let lastAttempt = lastGeocodeAttempts[device.id],
           Date().timeIntervalSince(lastAttempt) < 60 {
            return
        }
        guard !geocodingIDs.contains(device.id) else { return }
        geocodingIDs.insert(device.id)
        lastGeocodeAttempts[device.id] = Date()
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
            pendingInput = nil
            emergencyError = error.localizedDescription
            syncStatus = "Alert delivery unconfirmed: " + error.localizedDescription
            // Do not replay a stale SOS automatically later.
            return false
        }
    }

    func beginEmergencySession() {
        activeAlert = nil
        persistActiveAlert()
        pendingInput = nil
        emergencyError = nil
    }

    func cancelMyOwnEmergency(deviceID: String?, displayName: String) async {
        guard let id = pendingInput?.alertID ?? activeAlert?.alertID else { return }
        do {
            let canceled = try await apiClient.cancelEmergency(alertID: id)
            guard canceled.status == "CANCELED" else {
                emergencyError = "The service has not confirmed cancellation. Calls may already have started."
                return
            }
            activeAlert = canceled
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

    private func persistActiveCheckIns() {
        UserDefaults.standard.set(try? JSONEncoder().encode(activeCheckIns), forKey: checkInsKey)
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
        persistActiveCheckIns()
        if checkIn.status == "PENDING" {
            pendingCheckInSentAt[checkIn.targetDeviceID] = Date()
            if let index = familyDevices.firstIndex(where: { $0.id == checkIn.targetDeviceID }), familyDevices[index].state == 0 {
                familyDevices[index].state = 5
            }
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
            pendingCheckInSentAt.removeValue(forKey: checkIn.targetDeviceID)
            observedHardwarePingDevices.remove(checkIn.targetDeviceID)
            if let index = familyDevices.firstIndex(where: { $0.id == checkIn.targetDeviceID }), familyDevices[index].state == 5 {
                familyDevices[index].state = 0
            }
            syncStatus = "Check-in confirmed SAFE!"
        }
    }

    func ensureAlertSubscription() {
        guard hasGroup, alertSubscriptionTask == nil else { return }
        let code = groupCode
        alertSubscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hasGroup else { break }
                let sequence = self.apiClient.subscribeToAlerts(code: code)
                self.activeAlertSequence = sequence
                do {
                    for try await event in sequence {
                        if Task.isCancelled { break }
                        switch event {
                        case .connection:
                            break
                        case .data(let result):
                            if case .success(let alert) = result {
                                self.handleAlertUpdate(alert)
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                }
                sequence.cancel()
                self.activeAlertSequence = nil
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run { [weak self] in
                self?.activeAlertSequence?.cancel()
                self?.activeAlertSequence = nil
                self?.alertSubscriptionTask = nil
            }
        }
    }

    private func handleAlertUpdate(_ alert: CloudAlert) {
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[index] = alert
        } else {
            alerts.insert(alert, at: 0)
        }
        if activeAlert?.id == alert.id || (activeAlert == nil && alert.status == "PENDING") {
            activeAlert = alert
            persistActiveAlert()
        }
        LoopNotifications.shared.receive([alert])
    }

    func requestCheckIn(for deviceID: String) async {
        ensureCheckInSubscription()
        syncStatus = "Sending check-in request..."
        do {
            let checkIn = try await apiClient.sendPing(code: groupCode, targetDeviceID: deviceID)
            activeCheckIns[deviceID] = checkIn
            pendingCheckInSentAt[deviceID] = Date()
            persistActiveCheckIns()
            if let index = familyDevices.firstIndex(where: { $0.id == deviceID }), familyDevices[index].state == 0 {
                familyDevices[index].state = 5
            }
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
            pendingCheckInSentAt.removeValue(forKey: deviceID)
            observedHardwarePingDevices.remove(deviceID)
            persistActiveCheckIns()
            if let index = familyDevices.firstIndex(where: { $0.id == deviceID }), familyDevices[index].state == 5 {
                familyDevices[index].state = 0
            }
            lastUploads[deviceID] = .distantPast
            syncStatus = "Check-in confirmed SAFE!"
        } catch {
            syncStatus = "Acknowledge failed: \(error.localizedDescription)"
        }
    }
}
