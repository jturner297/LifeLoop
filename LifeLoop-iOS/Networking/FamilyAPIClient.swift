import Foundation
import Amplify

struct FamilyDeviceSnapshot: Identifiable, Codable, Equatable {
    let id: String
    var displayName: String
    var ownerName: String
    var bpm: Float
    var state: Int
    var latitude: Double
    var longitude: Double
    var isLocationShared: Bool
    var isOnline: Bool
    var lastUpdated: Date?
}

struct FamilyTelemetryPayload: Codable {
    let groupCode: String
    let deviceID: String
    let displayName: String
    let bpm: Float
    let state: Int
    let latitude: Double
    let longitude: Double
    let isLocationShared: Bool
    let isOnline: Bool
    let lastUpdated: Date?
}

struct LinkDevicePayload: Codable {
    let groupCode: String
    let deviceID: String
    let displayName: String
    var ownerName: String = "Me"
}

struct EmergencyAlertPayload: Codable {
    let groupCode: String
    let deviceID: String?
    let displayName: String
    let latitude: Double
    let longitude: Double
    let reason: String
    let timestamp: Date
}

final class FamilyAPIClient {
    static let shared = FamilyAPIClient()

    private let isoFormatter: ISO8601DateFormatter
    private let isoFormatterFractional: ISO8601DateFormatter

    private init() {
        isoFormatter = ISO8601DateFormatter()
        isoFormatterFractional = ISO8601DateFormatter()
        isoFormatterFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // MARK: - Mutations

    func linkDevice(_ payload: LinkDevicePayload) async throws {
        let input = """
        {
          groupCode: \(gqlString(payload.groupCode)),
          deviceID: \(gqlString(payload.deviceID)),
          displayName: \(gqlString(payload.displayName)),
          ownerName: \(gqlString(payload.ownerName))
        }
        """
        let document = """
        mutation LinkDevice {
          linkDevice(input: \(input)) {
            id: deviceID
          }
        }
        """
        let request = GraphQLRequest<LinkDeviceMutationWire>(
            document: document,
            responseType: LinkDeviceMutationWire.self
        )
        _ = try await send(mutation: request)
    }

    func uploadTelemetry(_ payload: FamilyTelemetryPayload) async throws {
        let input = """
        {
          groupCode: \(gqlString(payload.groupCode)),
          deviceID: \(gqlString(payload.deviceID)),
          displayName: \(gqlString(payload.displayName)),
          bpm: \(payload.bpm),
          state: \(payload.state),
          latitude: \(payload.latitude),
          longitude: \(payload.longitude),
          isLocationShared: \(payload.isLocationShared),
          isOnline: \(payload.isOnline),
          lastUpdated: \(gqlDate(payload.lastUpdated))
        }
        """
        let document = """
        mutation UploadFamilyTelemetry {
          uploadFamilyTelemetry(input: \(input)) {
            id: deviceID
          }
        }
        """
        let request = GraphQLRequest<UploadTelemetryMutationWire>(
            document: document,
            responseType: UploadTelemetryMutationWire.self
        )
        _ = try await send(mutation: request)
    }

    func sendEmergencyAlert(_ payload: EmergencyAlertPayload) async throws {
        let input = """
        {
          groupCode: \(gqlString(payload.groupCode)),
          deviceID: \(gqlOptionalString(payload.deviceID)),
          displayName: \(gqlString(payload.displayName)),
          latitude: \(payload.latitude),
          longitude: \(payload.longitude),
          reason: \(gqlString(payload.reason)),
          timestamp: \(gqlString(isoFormatter.string(from: payload.timestamp)))
        }
        """
        let document = """
        mutation SendEmergencyAlert {
          sendEmergencyAlert(input: \(input)) {
            id
          }
        }
        """
        let request = GraphQLRequest<SendEmergencyAlertMutationWire>(
            document: document,
            responseType: SendEmergencyAlertMutationWire.self
        )
        _ = try await send(mutation: request)
    }

    // MARK: - Query

    func fetchFamilyDevices(groupCode: String) async throws -> [FamilyDeviceSnapshot] {
        let document = """
        query FamilyDevices {
          familyDevices(groupCode: \(gqlString(groupCode))) {
            id: deviceID
            displayName
            ownerName: displayName
            bpm
            state
            latitude
            longitude
            isLocationShared
            isOnline
            lastUpdated
          }
        }
        """
        let request = GraphQLRequest<FamilyDevicesQueryWire>(
            document: document,
            responseType: FamilyDevicesQueryWire.self
        )

        print("🔵 Sending query:\n\(document)")

        let result = try await Amplify.API.query(request: request)
        switch result {
        case .success(let wire):
            return wire.familyDevices.map { device in
                FamilyDeviceSnapshot(
                    id: device.id,
                    displayName: device.displayName,
                    ownerName: device.ownerName,
                    bpm: device.bpm,
                    state: device.state,
                    latitude: device.latitude,
                    longitude: device.longitude,
                    isLocationShared: device.isLocationShared,
                    isOnline: device.isOnline,
                    lastUpdated: parseDate(device.lastUpdated)
                )
            }
        case .failure(let error):
            print("🔴 Query failed: \(error)")
            throw error
        }
    }

    // MARK: - Helpers

    private func send<R: Decodable>(mutation request: GraphQLRequest<R>) async throws -> R {
        let result = try await Amplify.API.mutate(request: request)
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            print("🔴 Mutation failed: \(error)")
            throw error
        }
    }

    /// Safely inlines a String as a quoted, escaped GraphQL string literal.
    private func gqlString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func gqlOptionalString(_ value: String?) -> String {
        guard let value else { return "null" }
        return gqlString(value)
    }

    private func gqlDate(_ date: Date?) -> String {
        guard let date else { return "null" }
        return gqlString(isoFormatter.string(from: date))
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFormatterFractional.date(from: string) ?? isoFormatter.date(from: string)
    }
}

// MARK: - Wire types (raw decode shapes matching the GraphQL response)

private struct MutationIDWire: Decodable {
    let id: String
}

private struct LinkDeviceMutationWire: Decodable {
    let linkDevice: MutationIDWire
}

private struct UploadTelemetryMutationWire: Decodable {
    let uploadFamilyTelemetry: MutationIDWire
}

private struct SendEmergencyAlertMutationWire: Decodable {
    let sendEmergencyAlert: MutationIDWire
}

private struct FamilyDevicesQueryWire: Decodable {
    let familyDevices: [FamilyDeviceWire]
}

private struct FamilyDeviceWire: Decodable {
    let id: String
    let displayName: String
    let ownerName: String
    let bpm: Float
    let state: Int
    let latitude: Double
    let longitude: Double
    let isLocationShared: Bool
    let isOnline: Bool
    let lastUpdated: String?
}
