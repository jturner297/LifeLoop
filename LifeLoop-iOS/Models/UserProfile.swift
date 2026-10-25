import Foundation
import Observation
import Amplify

struct LoopGroup: Identifiable, Codable, Equatable {
    var id: String
    var name: String
}

struct GroupContactDraft: Codable {
    let groupCode: String
    let ownerName: String
    let phone: String
    let email: String
    let consent: Bool
}

/// Contact drafts are intentionally local only. No API client accepts this type.
@MainActor @Observable
final class UserProfile {
    var name: String { didSet { save() } }
    var birthday: Date? { didSet { save() } }
    var phone: String { didSet { save() } }
    var email: String { didSet { save() } }
    var contactConsent: Bool { didSet { save() } }
    var groups: [LoopGroup] { didSet { save() } }
    private(set) var memberships: [CloudMember] = []
    private(set) var isSignedIn = false
    private(set) var currentUserID: String?
    private(set) var cloudStatus = "Sign in to load your families."
    private var lastCloudRefresh: Date?
    private(set) var managers: [String: FamilyDeviceManager] = [:]

    init() {
        let defaults = UserDefaults.standard
        name = defaults.string(forKey: "profile.name") ?? ""
        birthday = defaults.object(forKey: "profile.birthday") as? Date
        phone = defaults.string(forKey: "profile.phone") ?? ""
        email = defaults.string(forKey: "profile.email") ?? ""
        contactConsent = defaults.bool(forKey: "profile.contactConsent")
        groups = defaults.data(forKey: "profile.groups")
            .flatMap { try? JSONDecoder().decode([LoopGroup].self, from: $0) } ?? []
        if defaults.data(forKey: "profile.groups") == nil, let legacy = defaults.string(forKey: "com.lifeloop.family.groupCode"), !legacy.isEmpty {
            groups = [LoopGroup(id: legacy, name: "My group")]
        }
        groups = [] // Membership is authoritative on AWS, never inferred from a saved code.
    }

    var contactDrafts: [GroupContactDraft] {
        groups.map { GroupContactDraft(groupCode: $0.id, ownerName: name, phone: phone, email: email, consent: contactConsent) }
    }

    func refreshFamilies(force: Bool = true) async {
        if !force && Date().timeIntervalSince(lastCloudRefresh ?? .distantPast) < 30 { return }
        lastCloudRefresh = Date()
        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            isSignedIn = session.isSignedIn
            guard session.isSignedIn else {
                memberships = []
                groups = []
                managers = [:]
                currentUserID = nil
                cloudStatus = "Sign in to create or join a family."
                return
            }
            let user = try await Amplify.Auth.getCurrentUser()
            if UserDefaults.standard.string(forKey: "cloud.lastUserID") != user.userId {
                managers = [:]
                LoopNotifications.shared.resetForAccountChange()
            }
            currentUserID = user.userId
            UserDefaults.standard.set(user.userId, forKey: "cloud.lastUserID")
            let fetched = try await FamilyAPIClient.shared.myFamilies()
            memberships = fetched
            let savedNames = UserDefaults.standard.dictionary(forKey: "group.nicknames") as? [String: String] ?? [:]
            groups = fetched.map { LoopGroup(id: $0.groupCode, name: savedNames[$0.groupCode] ?? "Family " + $0.groupCode) }
            let codes = Set(groups.map(\.id))
            managers = managers.filter { codes.contains($0.key) }
            for group in groups where managers[group.id] == nil {
                managers[group.id] = FamilyDeviceManager(groupCode: group.id)
            }
            cloudStatus = "Families are up to date."
        } catch { cloudStatus = error.localizedDescription }
    }

    func createGroup(nickname: String) async throws {
        let family = try await FamilyAPIClient.shared.createFamily(displayName: name)
        saveNickname(nickname, code: family.groupCode)
        await refreshFamilies()
    }

    func joinGroup(nickname: String, code: String) async throws {
        let family = try await FamilyAPIClient.shared.joinFamily(code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), displayName: name)
        saveNickname(nickname, code: family.groupCode)
        await refreshFamilies()
    }

    func leaveGroup(_ group: LoopGroup) async throws {
        try await FamilyAPIClient.shared.membershipAction("leaveFamily", code: group.id)
        managers[group.id]?.stopSharing()
        managers.removeValue(forKey: group.id)
        await refreshFamilies()
    }

    func role(in code: String) -> FamilyRole? {
        memberships.first { $0.groupCode == code }?.role
    }

    private func saveNickname(_ name: String, code: String) {
        var names = UserDefaults.standard.dictionary(forKey: "group.nicknames") as? [String: String] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { names[code] = trimmed }
        UserDefaults.standard.set(names, forKey: "group.nicknames")
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "profile.name")
        defaults.set(birthday, forKey: "profile.birthday")
        if let birthday {
            defaults.set(Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 0, forKey: "userAge")
        } else {
            defaults.set(0, forKey: "userAge")
        }
        defaults.set(phone, forKey: "profile.phone")
        defaults.set(email, forKey: "profile.email")
        defaults.set(contactConsent, forKey: "profile.contactConsent")
        defaults.set(try? JSONEncoder().encode(groups), forKey: "profile.groups")
        defaults.set(try? JSONEncoder().encode(contactDrafts), forKey: "profile.contactDrafts")
    }
}
