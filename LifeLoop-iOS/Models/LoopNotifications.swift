import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class LoopNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LoopNotifications()
    var selectedGroupCode: String?
    private var seen: [String: String] = UserDefaults.standard.dictionary(forKey: "notifications.alertStates") as? [String: String] ?? [:]

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        let open = UNNotificationAction(identifier: "OPEN_GROUP", title: "View family", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "FAMILY_ALERT", actions: [open], intentIdentifiers: [])
        ])
    }

    func receive(_ alerts: [CloudAlert]) {
        for alert in alerts {
            let previous = seen[alert.id]
            seen[alert.id] = alert.status
            guard previous != alert.status,
                  UserDefaults.standard.bool(forKey: "profile.notifications"),
                  let created = alert.createdDate,
                  Date().timeIntervalSince(created) < 86_400 else { continue }
            if alert.status != "PENDING" && !UserDefaults.standard.bool(forKey: "notifications.statusUpdates") { continue }
            // Do not announce old resolved alerts when a group is first loaded.
            if previous == nil && alert.status != "PENDING" { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.status == "PENDING" ? "\(alert.displayName) needs help" : "\(alert.displayName): alert update"
            switch alert.status {
            case "CANCELED":
                content.body = "\(alert.canceledByName ?? "A family member") canceled the alert. Open the group for details."
            case "DISPATCHED":
                content.body = "The call workflow has started for this family. Check on \(alert.displayName)."
            default:
                let time = alert.callDate?.formatted(date: .omitted, time: .shortened) ?? "soon"
                content.body = "\(alert.reason). Contact calls are scheduled for \(time). Open the group to review."
            }
            if UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true { content.sound = .default }
            content.threadIdentifier = alert.groupCode
            content.categoryIdentifier = "FAMILY_ALERT"
            content.userInfo = ["groupCode": alert.groupCode, "alertID": alert.alertID]
            let request = UNNotificationRequest(identifier: "alert.\(alert.alertID).\(alert.status)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        if seen.count > 500 { seen = Dictionary(uniqueKeysWithValues: alerts.map { ($0.id, $0.status) }) }
        UserDefaults.standard.set(seen, forKey: "notifications.alertStates")
    }

    func resetForAccountChange() {
        seen = [:]
        UserDefaults.standard.removeObject(forKey: "notifications.alertStates")
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard UserDefaults.standard.bool(forKey: "profile.notifications") else { return [] }
        return UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true ? [.banner, .list, .sound] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let code = response.notification.request.content.userInfo["groupCode"] as? String else { return }
        await MainActor.run { self.selectedGroupCode = code }
    }
}
