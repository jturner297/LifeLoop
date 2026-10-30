import SwiftUI
import Amplify
import AWSCognitoAuthPlugin
import AWSAPIPlugin
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    var bleMonitor: BLEMonitor?
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        // 2. Check if the push payload contains the AWS ping trigger
        if let ping = userInfo["ping"] as? String, ping == "true" {
            bleMonitor?.sendPingCommand()
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }
}

@main
struct LifeLoopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var bleMonitor = BLEMonitor()

    init() {
        configureAmplify()
        LoopNotifications.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(bleMonitor)
                .onAppear() {
                    appDelegate.bleMonitor = bleMonitor
                }
        }
    }

    private func configureAmplify() {
        do {
            try Amplify.add(plugin: AWSCognitoAuthPlugin())
            try Amplify.add(plugin: AWSAPIPlugin())
            try Amplify.configure()
            print("Amplify configured successfully")
            print("Bundle path check: \(Bundle.main.path(forResource: "amplifyconfiguration", ofType: "json") ?? "NOT FOUND")")
        } catch {
            print("❌ Failed to configure Amplify: \(error)")
        }
    }
}
