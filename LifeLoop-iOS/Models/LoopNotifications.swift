import Foundation
import Observation
import UserNotifications

extension Notification.Name {
    static let lifeLoopCancelEmergencyFromNotification = Notification.Name("com.lifeloop.cancelEmergencyFromNotification")
}

@MainActor @Observable
final class LoopNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LoopNotifications()
    var selectedGroupCode: String?
    private var seen: [String: String] = UserDefaults.standard.dictionary(forKey: "notifications.alertStates") as? [String: String] ?? [:]

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "OPEN_GROUP", title: "View family", options: [.foreground])
        let cancelEmergency = UNNotificationAction(identifier: "CANCEL_EMERGENCY", title: "I’m OK — Cancel Alert", options: [.destructive, .foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "FAMILY_ALERT", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LOCAL_EMERGENCY_COUNTDOWN", actions: [cancelEmergency], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted && UserDefaults.standard.object(forKey: "profile.notifications") == nil {
                UserDefaults.standard.set(true, forKey: "profile.notifications")
            }
        }
    }

    nonisolated func postLocalEmergencyCountdown(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "EMERGENCY ALERT — Do you need help?"
        content.body = "\(reason). 30-second countdown started. Tap to open or cancel if you are safe."
        content.sound = .default
        content.categoryIdentifier = "LOCAL_EMERGENCY_COUNTDOWN"
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(identifier: "lifeloop.local.emergency.countdown", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func clearLocalEmergencyCountdown() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["lifeloop.local.emergency.countdown"])
        center.removeDeliveredNotifications(withIdentifiers: ["lifeloop.local.emergency.countdown"])
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
        if seen.count > 500 { seen = Dictionary(alerts.map { ($0.id, $0.status) }, uniquingKeysWith: { _, latest in latest }) }
        UserDefaults.standard.set(seen, forKey: "notifications.alertStates")
    }

    func resetForAccountChange() {
        seen = [:]
        UserDefaults.standard.removeObject(forKey: "notifications.alertStates")
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let complete = {
            guard UserDefaults.standard.bool(forKey: "profile.notifications") else {
                completionHandler([])
                return
            }
            let soundEnabled = UserDefaults.standard.object(forKey: "notifications.sound") as? Bool ?? true
            completionHandler(soundEnabled ? [.banner, .list, .sound] : [.banner, .list])
        }
        if Thread.isMainThread {
            complete()
        } else {
            DispatchQueue.main.async(execute: complete)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let code = response.notification.request.content.userInfo["groupCode"] as? String
        let completeOnMain = {
            MainActor.assumeIsolated {
                if actionIdentifier == "CANCEL_EMERGENCY" {
                    NotificationCenter.default.post(name: .lifeLoopCancelEmergencyFromNotification, object: nil)
                } else if actionIdentifier != UNNotificationDismissActionIdentifier,
                          let code, !code.isEmpty {
                    self.selectedGroupCode = code
                }
            }
            completionHandler()
        }
        if Thread.isMainThread {
            completeOnMain()
        } else {
            DispatchQueue.main.async(execute: completeOnMain)
        }
    }
}
