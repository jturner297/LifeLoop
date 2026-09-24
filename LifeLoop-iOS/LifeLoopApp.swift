import SwiftUI
import Amplify
import AWSCognitoAuthPlugin
import AWSAPIPlugin

@main
struct LifeLoopApp: App {
    @StateObject private var bleMonitor = BLEMonitor()

    init() {
        configureAmplify()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleMonitor)
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
