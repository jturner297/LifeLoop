import SwiftUI

struct WearerDashboardView: View {
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @AppStorage("userRole") private var userRole: String = "unassigned"
    @AppStorage("userAge") private var userAge: Int = 0
    
    // Injected to ensure the Wearer actually sees the red countdown screen if they fall
    @StateObject private var timerManager = EMSTimerManager.shared
    
    @State private var showSetup = false
    
    // Monitors the first actively connected device
    private var connectedDevice: DeviceStatus? {
        bleMonitor.deviceStatuses.values.first(where: { $0.isConnected })
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 5/255, green: 15/255, blue: 29/255).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Top Status Bar
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LifeLoop Monitoring")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(connectedDevice != nil ? Color.green : Color.red)
                                    .frame(width: 12, height: 12)
                                
                                Text(connectedDevice != nil ? "Hardware Connected" : "Searching for Hardware...")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(connectedDevice != nil ? Color.green : Color.red)
                            }
                        }
                        Spacer()
                    }
                    .padding(24)
                    .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                    
                    // Hardware Discovery List (Only visible if disconnected)
                    if connectedDevice == nil {
                        List {
                            Section {
                                if bleMonitor.discoveredPeripherals.isEmpty {
                                    Text("Scanning for your band...")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.gray)
                                        .listRowBackground(Color(red: 13/255, green: 27/255, blue: 43/255))
                                } else {
                                    ForEach(bleMonitor.discoveredPeripherals) { peripheral in
                                        Button {
                                            bleMonitor.addKnownDevice(peripheral)
                                        } label: {
                                            HStack {
                                                Text(peripheral.name)
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                Spacer()
                                                Text("Tap to Connect")
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundStyle(Color(red: 0/255, green: 210/255, blue: 174/255))
                                            }
                                        }
                                        .listRowBackground(Color(red: 13/255, green: 27/255, blue: 43/255))
                                    }
                                }
                            } header: {
                                Text("Available Devices")
                                    .foregroundStyle(.gray)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(height: 180)
                    } else {
                        // Live Vitals & Telemetry Panel
                        HStack(spacing: 16) {
                            // BPM Card
                            VStack(spacing: 8) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.red)
                                
                                Text(bpmText)
                                    .font(.system(size: 42, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                
                                Text("Current BPM")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            
                            // Battery Card (Placeholder pending C++ payload)
                            VStack(spacing: 8) {
                                Image(systemName: "battery.100")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.green)
                                
                                Text("100%")
                                    .font(.system(size: 42, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                
                                Text("Band Battery")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .padding(24)
                        
                        Text(lastUpdatedText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(red: 0/255, green: 210/255, blue: 174/255))
                    }
                    
                    Spacer()
                    
                    // Massive Manual SOS Button
                    Button {
                        EMSTimerManager.shared.startCountdown(reason: "MANUAL SOS\nTRIGGERED")
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.2))
                                .frame(width: 320, height: 320)
                            
                            Circle()
                                .fill(Color.red)
                                .frame(width: 260, height: 260)
                                .shadow(color: .red.opacity(0.5), radius: 20, x: 0, y: 10)
                            
                            VStack(spacing: 12) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 50))
                                Text("CALL HELP")
                                    .font(.system(size: 32, weight: .black, design: .rounded))
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                        impactHeavy.impactOccurred()
                    })
                    
                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Set Age") { showSetup = true }
                        Button("Switch to Caregiver", role: .destructive) { userRole = "unassigned" }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(Color(red: 0/255, green: 210/255, blue: 174/255))
                    }
                }
            }
            .sheet(isPresented: $showSetup) {
                WearerSetupSheet()
            }
            // CRITICAL: Connects the countdown alarm to the Wearer's screen
            .fullScreenCover(isPresented: $timerManager.isActive) {
                EMSCountdown(timerManager: timerManager)
            }
            .onAppear {
                if userAge == 0 {
                    showSetup = true
                }
                if !bleMonitor.isScanning && !bleMonitor.isConnected {
                    bleMonitor.startScanning()
                }
            }
        }
    }
    
    private var bpmText: String {
        guard let device = connectedDevice else { return "--" }
        let bpm = device.lifeLoopState.bpm
        return bpm > 0 ? "\(Int(bpm.rounded()))" : "--"
    }
    
    private var lastUpdatedText: String {
        guard let device = connectedDevice, let lastUpdated = device.lastUpdated else {
            return "Awaiting data from band..."
        }
        let timeString = DateFormatter.localizedString(from: lastUpdated, dateStyle: .none, timeStyle: .short)
        return "Last synced with band at \(timeString)"
    }
}

// Dedicated Sheet for the Classic Wheel Picker
struct WearerSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("userAge") private var userAge: Int = 0
    
    // Default starting point for the wheel to prevent it starting at 10
    @State private var temporaryAge: Int = 65
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 5/255, green: 15/255, blue: 29/255).ignoresSafeArea()
                
                VStack(spacing: 30) {
                    Text("Select Your Age")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.top, 40)
                    
                    Text("This calibrates your emergency heart rate thresholds.")
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.gray)
                        .padding(.horizontal)
                    
                    // Classic Apple Scroll Wheel
                    Picker("Age", selection: $temporaryAge) {
                        ForEach(10...100, id: \.self) { age in
                            Text("\(age)")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.white)
                                .tag(age)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 220)
                    .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                    
                    Button {
                        userAge = temporaryAge
                        dismiss()
                    } label: {
                        Text("Save & Continue")
                            .font(.system(size: 20, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(red: 0/255, green: 210/255, blue: 174/255))
                            .foregroundStyle(Color(red: 5/255, green: 15/255, blue: 29/255))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 20)
                    
                    Spacer()
                }
            }
            .onAppear {
                if userAge > 0 {
                    temporaryAge = userAge
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
