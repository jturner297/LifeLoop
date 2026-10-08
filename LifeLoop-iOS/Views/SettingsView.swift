//
//  SettingsView.swift
//  LifeLoop
//
//  Created by Jes206 on 9/22/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("userAge") private var userAge: Int = 0
    @AppStorage("isAdminUser") private var isAdminUser: Bool = false
    @AppStorage("allowRemoteAdminCancel") private var allowRemoteAdminCancel: Bool = true
    
    // Injects the global role variable so it can be reset to unassigned
    @AppStorage("userRole") private var userRole: String = "unassigned"
    
    // Local state to power the scroll wheel before saving
    @State private var tempAge: Int = 65
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Emergency Thresholds")) {
                    VStack {
                        Text("Select Age: \(tempAge)")
                            .font(.headline)
                            .foregroundColor(Color(red: 255/255, green: 194/255, blue: 86/255))
                            .padding(.top, 10)
                        
                        // Classic Apple Scroll Wheel Implementation
                        Picker("Age", selection: $tempAge) {
                            ForEach(10...100, id: \.self) { age in
                                Text("\(age)").tag(age)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 140)
                        .clipped()
                    }
                    
                    if tempAge > 0 {
                        HStack {
                            Text("Tachycardia Auto-Trigger")
                            Spacer()
                            Text("\(220 - tempAge) BPM")
                                .bold()
                                .foregroundColor(Color(red: 255/255, green: 194/255, blue: 86/255))
                        }
                    }
                }
                .listRowBackground(Color(red: 13/255, green: 27/255, blue: 43/255))
                
                Section(header: Text("Admin & Permissions")) {
                    Toggle("I am an Admin for my family group", isOn: $isAdminUser)
                    Toggle("Allow remote admin to cancel my EMS call", isOn: $allowRemoteAdminCancel)
                        .tint(.red)
                    
                    // The destructive escape hatch back to the role selection flow
                    Button(role: .destructive) {
                        userRole = "unassigned"
                        dismiss()
                    } label: {
                        Text("Reset App Role (Switch to Patient)")
                    }
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
                        userAge = tempAge
                        dismiss()
                    }
                }
            }
            .onAppear {
                if userAge > 0 {
                    tempAge = userAge
                }
            }
            .interactiveDismissDisabled(userAge == 0)
        }
        .preferredColorScheme(.dark)
    }
}
