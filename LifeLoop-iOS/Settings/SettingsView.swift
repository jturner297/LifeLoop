//
//  SettingsView.swift
//  LifeLoop
//
//  Created by Jes206 on 9/22/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    // Set to 0 so we know if the user hasn't configured it yet
    @AppStorage("userAge") private var userAge: Int = 0
    @AppStorage("isAdminUser") private var isAdminUser: Bool = false
    @AppStorage("allowRemoteAdminCancel") private var allowRemoteAdminCancel: Bool = true
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Emergency Thresholds")) {
                    // Only show the threshold calculation if they've set a valid age
                    if userAge > 0 {
                        Stepper("Age: \(userAge)", value: $userAge, in: 10...100)
                        
                        HStack {
                            Text("Tachycardia Auto-Trigger")
                            Spacer()
                            Text("\(220 - userAge) BPM")
                                .bold()
                                .foregroundColor(Color(red: 255/255, green: 194/255, blue: 86/255))
                        }
                    } else {
                        // The prompt they see on first launch
                        Stepper("Set your age to continue", value: $userAge, in: 0...100)
                            .foregroundColor(Color(red: 255/255, green: 194/255, blue: 86/255))
                    }
                }
                .listRowBackground(Color(red: 13/255, green: 27/255, blue: 43/255))
                
                Section(header: Text("Admin & Permissions")) {
                    Toggle("I am an Admin for my family group", isOn: $isAdminUser)
                    Toggle("Allow remote admin to cancel my EMS call", isOn: $allowRemoteAdminCancel)
                        .tint(.red)
                }
                .listRowBackground(Color(red: 13/255, green: 27/255, blue: 43/255))
            }
            .navigationTitle(userAge == 0 ? "Initial Setup" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color(red: 5/255, green: 15/255, blue: 29/255))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    // Lock the user on this screen until they set a valid age
                    .disabled(userAge == 0)
                }
            }
            // Prevent them from swiping the sheet down to escape
            .interactiveDismissDisabled(userAge == 0)
        }
        .preferredColorScheme(.dark)
    }
}

