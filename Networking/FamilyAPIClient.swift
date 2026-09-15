import Foundation

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

final class FamilyAPIClient {
    static let shared = FamilyAPIClient()

    private let graphQLEndpoint = URL(string: "https://Placeholder.amazonaws.com/graphql")!
    private let apiKey = "da2-Placeholder"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func linkDevice(_ payload: LinkDevicePayload) async throws {
        let request = GraphQLRequest(
            query: """
            mutation LinkDevice($input: LinkDeviceInput!) {
              linkDevice(input: $input) {
                id: deviceID
              }
            }
            """,
            variables: GraphQLInputVariables(input: payload)
        )
        let _: LinkDeviceMutationData = try await sendGraphQL(request)
    }

    func uploadTelemetry(_ payload: FamilyTelemetryPayload) async throws {
        let request = GraphQLRequest(
            query: """
            mutation UploadFamilyTelemetry($input: FamilyTelemetryInput!) {
              uploadFamilyTelemetry(input: $input) {
                id: deviceID
              }
            }
            """,
            variables: GraphQLInputVariables(input: payload)
        )
        let _: UploadTelemetryMutationData = try await sendGraphQL(request)
    }

    func fetchFamilyDevices(groupCode: String) async throws -> [FamilyDeviceSnapshot] {
        let request = GraphQLRequest(
            query: """
            query FamilyDevices($groupCode: String!) {
              familyDevices(groupCode: $groupCode) {
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
            """,
            variables: FamilyDevicesQueryVariables(groupCode: groupCode)
        )
        let response: FamilyDevicesQueryData = try await sendGraphQL(request)
        return response.familyDevices
    }

    private func sendGraphQL<ResponseData: Decodable, Variables: Encodable>(
        _ graphQLRequest: GraphQLRequest<Variables>
    ) async throws -> ResponseData {
        var request = URLRequest(url: graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try encoder.encode(graphQLRequest)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw AppSyncError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let graphQLResponse = try decoder.decode(GraphQLResponse<ResponseData>.self, from: data)
        if let errors = graphQLResponse.errors, !errors.isEmpty {
            throw AppSyncError.graphQLErrors(errors.map(\.message).joined(separator: "\n"))
        }
        guard let responseData = graphQLResponse.data else {
            throw AppSyncError.missingData
        }
        return responseData
    }
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

private struct GraphQLInputVariables<Input: Encodable>: Encodable {
    let input: Input
}

private struct FamilyDevicesQueryVariables: Encodable {
    let groupCode: String
}

private struct GraphQLResponse<DataValue: Decodable>: Decodable {
    let data: DataValue?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
}

private struct LinkDeviceMutationData: Decodable {
    let linkDevice: MutationID
}

private struct UploadTelemetryMutationData: Decodable {
    let uploadFamilyTelemetry: MutationID
}

private struct MutationID: Decodable {
    let id: String
}

private struct FamilyDevicesQueryData: Decodable {
    let familyDevices: [FamilyDeviceSnapshot]
}

private enum AppSyncError: LocalizedError {
    case httpError(statusCode: Int, body: String)
    case graphQLErrors(String)
    case missingData

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body)"
        case .graphQLErrors(let message):
            return message
        case .missingData:
            return "AppSync returned no data."
        }
    }
}
