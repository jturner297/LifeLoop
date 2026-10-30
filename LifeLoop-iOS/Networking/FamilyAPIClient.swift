import Foundation
import Amplify
import AWSPluginsCore

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

struct CloudCheckIn: Identifiable, Codable {
    var id: String { checkInID }
    let checkInID: String
    let groupCode: String
    let targetDeviceID: String
    let initiatorName: String
    let status: String
    let createdAt: String
    let resolvedAt: String?
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
}


enum FamilyRole: String, Codable {
    case creator = "CREATOR", admin = "ADMIN", member = "MEMBER"
    var canManage: Bool { self != .member }
}

struct JoinedFamily: Decodable {
    let groupCode: String
}

struct CloudFamily: Decodable {
    let groupCode: String
    let createdAt: String
}

struct CloudMember: Identifiable, Codable {
    var id: String { userID }
    let groupCode: String
    let userID: String
    let displayName: String
    let role: FamilyRole
    let joinedAt: String
}

struct BlockedMember: Identifiable, Decodable {
    var id: String { userID }
    let groupCode: String
    let userID: String
    let displayName: String
    let bannedAt: String
}

struct FamilyContact: Identifiable, Decodable {
    var id: String { contactID }
    let groupCode: String
    let contactID: String
    let ownerID: String
    let name: String
    let phoneNumber: String
}

struct CloudAlert: Identifiable, Codable, Equatable {
    var id: String { alertID }
    let alertID: String
    let groupCode: String
    let deviceID: String?
    let displayName: String
    let latitude: Double
    let longitude: Double
    let reason: String
    let status: String
    let callAt: String
    let createdAt: String
    let canceledBy: String?
    let canceledByName: String?
    let canceledAt: String?
    var callDate: Date? { FamilyAPIClient.parseDate(callAt) }
    var createdDate: Date? { FamilyAPIClient.parseDate(createdAt) }
}

struct StartEmergencyInput: Codable {
    let alertID: String
    let groupCode: String
    let deviceID: String?
    let displayName: String
    let latitude: Double
    let longitude: Double
    let reason: String
}

private struct MutationResult: Decodable {
    let success: Bool
    let message: String?
}

private struct FamilyRequestError: LocalizedError {
    let operation: String
    let message: String

    var errorDescription: String? { "\(operation): \(message)" }
}

final class FamilyAPIClient {
    static let shared = FamilyAPIClient()
    static let alertFields = "alertID groupCode deviceID displayName latitude longitude reason status callAt createdAt canceledBy canceledByName canceledAt"
    private let memberFields = "groupCode userID displayName role joinedAt"
    private let contactFields = "groupCode contactID ownerID name phoneNumber"
    private static let checkInFields = "checkInID groupCode targetDeviceID initiatorName status createdAt resolvedAt"

    private init() {}

    // Variables preserve quotes, newlines, and Unicode without interpolating user input into GraphQL.
    private func execute<T: Decodable>(_ field: String, declaration: String = "", arguments: String = "", variables: [String: Any] = [:], fields: String, mutation: Bool = false) async throws -> T {
        let document = "\(mutation ? "mutation" : "query") Operation\(declaration) { \(field)\(arguments) { \(fields) } }"
        let request = GraphQLRequest<T>(document: document, variables: variables, responseType: T.self, decodePath: field, authMode: AWSAuthorizationType.amazonCognitoUserPools)
        do {
            let result = mutation ? try await Amplify.API.mutate(request: request) : try await Amplify.API.query(request: request)
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                let message: String
                switch error {
                case .error(let errors), .partial(_, let errors):
                    message = errors.map(\.message).joined(separator: "\n")
                case .transformationError(_, let decodingError):
                    // Do not expose the raw response, which can contain family information.
                    message = "AWS returned data the app could not read. " + decodingError.errorDescription
                case .unknown(let description, _, _):
                    message = description
                }
                throw FamilyRequestError(operation: field, message: message)
            }
        } catch let error as FamilyRequestError {
            throw error
        } catch {
            let message = (error as? AmplifyError)?.errorDescription ?? error.localizedDescription
            throw FamilyRequestError(operation: field, message: message)
        }
    }

    private func input<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }
    
    func sendPing(code: String, targetDeviceID: String) async throws -> CloudCheckIn {
            try await execute(
                "sendPing",
                declaration: "($code: String!, $target: String!)",
                arguments: "(groupCode: $code, targetDeviceID: $target)",
                variables: ["code": code, "target": targetDeviceID],
                fields: Self.checkInFields,
                mutation: true
            )
        }

        func acknowledgePing(checkInID: String) async throws -> CloudCheckIn {
            try await execute(
                "acknowledgePing",
                declaration: "($id: ID!)",
                arguments: "(checkInID: $id)",
                variables: ["id": checkInID],
                fields: Self.checkInFields,
                mutation: true
            )
        }

    func myFamilies() async throws -> [CloudMember] {
        try await execute("myFamilies", fields: memberFields)
    }

    func createFamily(displayName: String) async throws -> CloudFamily {
        try await execute("createFamily", declaration: "($name: String!)", arguments: "(displayName: $name)", variables: ["name": displayName], fields: "groupCode createdAt", mutation: true)
    }

    func joinFamily(code: String, displayName: String) async throws -> JoinedFamily {
        try await execute("joinFamily", declaration: "($code: String!, $name: String!)", arguments: "(groupCode: $code, displayName: $name)", variables: ["code": code, "name": displayName], fields: "groupCode", mutation: true)
    }

    func members(code: String) async throws -> [CloudMember] {
        try await execute("familyMembers", declaration: "($code: String!)", arguments: "(groupCode: $code)", variables: ["code": code], fields: memberFields)
    }

    func blockedMembers(code: String) async throws -> [BlockedMember] {
        try await execute("blockedMembers", declaration: "($code: String!)", arguments: "(groupCode: $code)", variables: ["code": code], fields: "groupCode userID displayName bannedAt")
    }

    func membershipAction(_ field: String, code: String, userID: String? = nil) async throws {
        var variables: [String: Any] = ["code": code]
        if let userID { variables["user"] = userID }
        let result: MutationResult = try await execute(field, declaration: userID == nil ? "($code: String!)" : "($code: String!, $user: String!)", arguments: userID == nil ? "(groupCode: $code)" : "(groupCode: $code, userID: $user)", variables: variables, fields: "success message", mutation: true)
        if !result.success { throw NSError(domain: "LifeLoop", code: 1, userInfo: [NSLocalizedDescriptionKey: result.message ?? "The change could not be saved."]) }
    }

    func setRole(code: String, userID: String, role: FamilyRole) async throws -> CloudMember {
        try await execute("setMemberRole", declaration: "($code: String!, $user: String!, $role: Role!)", arguments: "(groupCode: $code, userID: $user, role: $role)", variables: ["code": code, "user": userID, "role": role.rawValue], fields: memberFields, mutation: true)
    }

    func contacts(code: String) async throws -> [FamilyContact] {
        try await execute("familyContacts", declaration: "($code: String!)", arguments: "(groupCode: $code)", variables: ["code": code], fields: contactFields)
    }

    func saveContact(code: String, contactID: String?, name: String, phone: String) async throws -> FamilyContact {
        var variables: [String: Any] = ["code": code, "name": name, "phone": phone]
        if let contactID { variables["id"] = contactID }
        return try await execute(contactID == nil ? "addContact" : "updateContact",
            declaration: contactID == nil ? "($code: String!, $name: String!, $phone: String!)" : "($code: String!, $id: ID!, $name: String!, $phone: String!)",
            arguments: contactID == nil ? "(groupCode: $code, name: $name, phoneNumber: $phone)" : "(groupCode: $code, contactID: $id, name: $name, phoneNumber: $phone)",
            variables: variables, fields: contactFields, mutation: true)
    }

    func deleteContact(code: String, contactID: String) async throws {
        let result: MutationResult = try await execute("deleteContact", declaration: "($code: String!, $id: ID!)", arguments: "(groupCode: $code, contactID: $id)", variables: ["code": code, "id": contactID], fields: "success message", mutation: true)
        if !result.success { throw CocoaError(.validationMissingMandatoryProperty) }
    }

    func linkDevice(_ payload: LinkDevicePayload) async throws {
        let _: DeviceID = try await execute("linkDevice", declaration: "($input: LinkDeviceInput!)", arguments: "(input: $input)", variables: ["input": try input(payload)], fields: "deviceID", mutation: true)
    }

    func uploadTelemetry(_ payload: FamilyTelemetryPayload) async throws {
        let _: DeviceID = try await execute("uploadFamilyTelemetry", declaration: "($input: FamilyTelemetryInput!)", arguments: "(input: $input)", variables: ["input": try input(payload)], fields: "deviceID", mutation: true)
    }

    func startEmergency(_ payload: StartEmergencyInput) async throws -> CloudAlert {
        try await execute("startEmergency", declaration: "($input: StartEmergencyInput!)", arguments: "(input: $input)", variables: ["input": try input(payload)], fields: Self.alertFields, mutation: true)
    }

    func cancelEmergency(alertID: String) async throws -> CloudAlert {
        try await execute("cancelEmergency", declaration: "($id: ID!)", arguments: "(alertID: $id)", variables: ["id": alertID], fields: Self.alertFields, mutation: true)
    }

    func alerts(code: String) async throws -> [CloudAlert] {
        try await execute("alertsForGroup", declaration: "($code: String!, $limit: Int)", arguments: "(groupCode: $code, limit: $limit)", variables: ["code": code, "limit": 20], fields: Self.alertFields)
    }

    func fetchFamilyDevices(groupCode: String) async throws -> [FamilyDeviceSnapshot] {
        let devices: [FamilyDeviceWire] = try await execute("familyDevices", declaration: "($code: String!)", arguments: "(groupCode: $code)", variables: ["code": groupCode], fields: "deviceID displayName ownerName bpm state latitude longitude isLocationShared isOnline lastUpdated")
        return devices.map {
            FamilyDeviceSnapshot(id: $0.deviceID, displayName: $0.displayName, ownerName: $0.ownerName, bpm: $0.bpm, state: $0.state, latitude: $0.latitude, longitude: $0.longitude, isLocationShared: $0.isLocationShared, isOnline: $0.isOnline, lastUpdated: Self.parseDate($0.lastUpdated))
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

private struct DeviceID: Decodable { let deviceID: String }
private struct FamilyDeviceWire: Decodable {
    let deviceID: String
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
