import SwiftUI

@main
struct LifeLoopApp: App {
    @StateObject private var bleMonitor = BLEMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleMonitor)
        }
    }
}
