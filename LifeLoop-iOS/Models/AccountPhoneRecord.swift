import Foundation

/// A self-reported phone number associated with an existing signed-in account.
/// This is not proof of phone ownership and is not a cloud synchronization record.
struct AccountPhoneRecord: Codable, Equatable {
    let userID: String
    let phoneNumber: String
    let updatedAt: String
    let verificationStatus: String

    init(userID: String, phoneNumber: String, date: Date = Date()) {
        self.userID = userID
        self.phoneNumber = phoneNumber
        updatedAt = ISO8601DateFormatter().string(from: date)
        verificationStatus = "SELF_REPORTED"
    }
}

struct AccountPhoneStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(userID: String) throws -> AccountPhoneRecord? {
        guard !userID.isEmpty else { return nil }
        guard let data = defaults.data(forKey: key(for: userID)) else { return nil }
        let record = try JSONDecoder().decode(AccountPhoneRecord.self, from: data)
        guard record.userID == userID else { throw StoreError.accountMismatch }
        return record
    }

    @discardableResult
    func save(phoneNumber: String, userID: String) throws -> AccountPhoneRecord {
        guard !userID.isEmpty else { throw StoreError.missingAccount }
        guard phoneNumber.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil,
              !phoneNumber.hasPrefix("+1") || phoneNumber.count == 12 else {
            throw StoreError.invalidNumber
        }
        let record = AccountPhoneRecord(userID: userID, phoneNumber: phoneNumber)
        let data = try JSONEncoder().encode(record)
        defaults.set(data, forKey: key(for: userID))
        return record
    }

    private func key(for userID: String) -> String {
        "account.phoneRecord." + userID
    }

    private enum StoreError: LocalizedError {
        case missingAccount, accountMismatch, invalidNumber

        var errorDescription: String? {
            switch self {
            case .missingAccount: "Sign in before linking a phone number."
            case .accountMismatch: "This phone record belongs to another account."
            case .invalidNumber: "Enter a complete phone number with a country code."
            }
        }
    }
}
