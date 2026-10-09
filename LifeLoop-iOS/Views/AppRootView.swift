//
//  AppRootView.swift
//  LifeLoop
//
//  Created by Jes206 on 10/6/26.
//

import SwiftUI

enum UserRole: String {
    case unassigned = "unassigned"
    case wearer = "wearer"
    case family = "family"
}

struct AppRootView: View {
    // Automatically reads/writes to UserDefaults. Defaults to unassigned on first launch.
    @AppStorage("userRole") private var userRole: UserRole = .unassigned
    
    var body: some View {
        Group {
            switch userRole {
            case .unassigned:
                RoleSelectionView(role: $userRole)
            case .wearer:
                WearerDashboardView()
            case .family:
                // Your massive existing ContentView safely handles all the complex family logic
                ContentView()
            }
        }
        // Smooth fade when switching between roles during initial setup
        .animation(.easeInOut, value: userRole)
    }
}
