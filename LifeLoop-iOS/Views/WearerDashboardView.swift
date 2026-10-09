import SwiftUI

struct WearerDashboardView: View {
    @EnvironmentObject private var bleMonitor: BLEMonitor
    @AppStorage("userRole") private var userRole: String = "unassigned"
    @AppStorage("userAge") private var userAge: Int = 0
    
    @StateObject private var timerManager = EMSTimerManager.shared
    @StateObject private var GPS = LocationManager()
    @StateObject private var familyManager = FamilyDeviceManager()
    
    @State private var showSetup = false
    @State private var hasDismissedCriticalBattery = false
    
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
                                
                                Text(connectedDevice != nil ? "Hardware Connected" : "Band Disconnected")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(connectedDevice != nil ? Color.green : Color.red)
                            }
                        }
                        Spacer()
                    }
                    .padding(24)
                    .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                    
                    // Intelligent View Routing
                    if timerManager.isAlertTriggered {
                        activeEmergencyView
                    } else {
                        // Normal Dashboard State
                        if bleMonitor.knownDevices.isEmpty {
                            pairingList
                        } else if connectedDevice == nil {
                            troubleshootingCard
                        } else {
                            vitalsPanel
                        }
                        
                        Spacer()
                        
                        // Massive Manual SOS Button
                        Button {
                            timerManager.startCountdown(reason: "MANUAL SOS\nTRIGGERED")
                            bleMonitor.sendSOSCommand() // Immediately flags the C++ board
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
                
                if let level = connectedDevice?.lifeLoopState.battery,
                   level <= 10,
                   !hasDismissedCriticalBattery,
                   !timerManager.isAlertTriggered,
                   !timerManager.isActive {
                    criticalBatteryOverlay(level: level)
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
            .fullScreenCover(isPresented: $timerManager.isActive) {
                EMSCountdown(timerManager: timerManager)
            }
            .onAppear {
                if userAge == 0 { showSetup = true }
                if !bleMonitor.isScanning && !bleMonitor.isConnected {
                    bleMonitor.startScanning()
                }
            }
            .onChange(of: timerManager.isAlertTriggered, perform: { newTriggered in
                if newTriggered {
                    let linked = bleMonitor.knownDevices.first { familyManager.linkedDeviceIDs.contains($0.id) }
                    let deviceID = linked?.id
                    let displayName = linked.map { bleMonitor.deviceStatuses[$0.id]?.name ?? $0.name } ?? "This iPhone"
                    
                    Task {
                        await familyManager.sendMyEmergencyAlert(
                            deviceID: deviceID,
                            displayName: displayName,
                            latitude: GPS.latitude,
                            longitude: GPS.longitude,
                            reason: timerManager.triggerReason
                        )
                    }
                }
            })
            .onChange(of: connectedDevice?.lifeLoopState.battery, perform: { level in
                if let level = level, level > 15 {
                    hasDismissedCriticalBattery = false
                }
            })
        }
    }
    
    // MARK: - Subviews
    
    private var activeEmergencyView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 70))
                .foregroundStyle(Color(red: 24/255, green: 126/255, blue: 255/255))
                .symbolEffect(.variableColor.iterative.reversing) // Native iOS 17 pulse effect
            
            Text("Alert Sent")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            
            Text("Your family and caregivers have been notified of the emergency and are tracking your location.")
                .font(.system(size: 18, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.gray)
                .padding(.horizontal, 30)
            
            Spacer()
            
            Button {
                cancelActiveEmergency()
            } label: {
                Text("False Alarm - Cancel Alert")
                    .font(.system(size: 20, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.white.opacity(0.1))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
    
    private func cancelActiveEmergency() {
        let linked = bleMonitor.knownDevices.first { familyManager.linkedDeviceIDs.contains($0.id) }
        let deviceID = linked?.id
        let displayName = linked.map { bleMonitor.deviceStatuses[$0.id]?.name ?? $0.name } ?? "This iPhone"
        
        Task {
            await familyManager.cancelMyOwnEmergency(deviceID: deviceID, displayName: displayName)
        }
        
        bleMonitor.sendCancelCommand() // Tells the C++ hardware to stop buzzing
        timerManager.cancelCountdown() // Forcefully kills the iPhone's haptic/vibration loop
        timerManager.isAlertTriggered = false // Returns to standard dashboard
    }
    
    private func criticalBatteryOverlay(level: Int) -> some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            
            VStack(spacing: 24) {
                Image(systemName: "battery.0")
                    .font(.system(size: 60))
                    .foregroundStyle(.red)
                
                Text("Battery Critical")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text("Your band is at \(level)%. Please charge your LifeLoop band immediately to ensure fall detection remains active.")
                    .font(.system(size: 18))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                Button {
                    hasDismissedCriticalBattery = true
                } label: {
                    Text("I Understand")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
            }
        }
        .zIndex(100)
    }
    
    private var pairingList: some View {
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
    }
    
    private var troubleshootingCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.red)
            
            Text("Band Disconnected")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "1.circle.fill").foregroundStyle(.gray)
                    Text("Ensure the band is charged and powered on.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top) {
                    Image(systemName: "2.circle.fill").foregroundStyle(.gray)
                    Text("Keep it within 30 feet of this iPhone.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top) {
                    Image(systemName: "3.circle.fill").foregroundStyle(.gray)
                    Text("Check that Bluetooth is ON in Settings.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.gray)
            .padding(.horizontal, 10)
            
            Button {
                if !bleMonitor.isScanning {
                    bleMonitor.startScanning()
                }
                for device in bleMonitor.knownDevices {
                    bleMonitor.connect(toKnown: device)
                }
            } label: {
                Text("Tap to Reconnect")
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(red: 24/255, green: 126/255, blue: 255/255))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.top, 10)
        }
        .padding(24)
        .background(Color(red: 13/255, green: 27/255, blue: 43/255))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
    }
    
    private var vitalsPanel: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                // BPM Card
                VStack(spacing: 8) {
                    HeartBeatIcon(bpm: currentBPM)
                    
                    Text(currentBPM > 0 ? "\(Int(currentBPM.rounded()))" : "Not Worn")
                        .font(.system(size: currentBPM > 0 ? 42 : 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.vertical, currentBPM > 0 ? 0 : 8)
                    
                    Text("Current BPM")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.gray)
                    
                    if userAge > 0 {
                        Text("Auto-Alert > \(220 - userAge)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(red: 255/255, green: 194/255, blue: 86/255))
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                
                // Dynamic Battery Card
                VStack(spacing: 8) {
                    Image(systemName: connectedDevice?.lifeLoopState.battery ?? 100 > 20 ? "battery.100" : "battery.25")
                        .font(.system(size: 28))
                        .foregroundStyle(batteryColor)
                    
                    Text(batteryText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text("Band Battery")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.gray)
                    
                    if userAge > 0 {
                        Text(" ")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Color(red: 13/255, green: 27/255, blue: 43/255))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            
            VStack(spacing: 6) {
                Text(lastUpdatedText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0/255, green: 210/255, blue: 174/255))
                
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12))
                        .padding(.top, 2)
                    
                    Text(GPS.currentAddress.isEmpty ? "Locating..." : GPS.currentAddress)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .foregroundStyle(.gray)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var currentBPM: Double {
        guard let device = connectedDevice else { return 0 }
        return Double(device.lifeLoopState.bpm)
    }
    
    private var batteryText: String {
        guard let device = connectedDevice else { return "--%" }
        return "\(device.lifeLoopState.battery)%"
    }
    
    private var batteryColor: Color {
        guard let device = connectedDevice else { return .gray }
        let level = device.lifeLoopState.battery
        if level > 20 { return .green }
        if level > 10 { return .yellow }
        return .red
    }
    
    private var lastUpdatedText: String {
        guard let device = connectedDevice, let lastUpdated = device.lastUpdated else {
            return "Awaiting data from band..."
        }
        let timeString = DateFormatter.localizedString(from: lastUpdated, dateStyle: .none, timeStyle: .short)
        return "Last synced with band at \(timeString)"
    }
}

// BUG FIX: The sluggish app issue is solved by using a smooth, generic pulse
// that doesn't constantly recalculate its timing when the exact BPM decimal floats.
struct HeartBeatIcon: View {
    let bpm: Double
    @State private var isAnimating = false
    
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 28))
            .foregroundStyle(bpm > 0 ? Color.red : Color.gray)
            .scaleEffect(isAnimating ? 1.15 : 1.0)
            .onAppear {
                if bpm > 0 { startPulse() }
            }
            .onChange(of: bpm) { newBPM in
                if newBPM > 0 && !isAnimating {
                    startPulse()
                } else if newBPM == 0 && isAnimating {
                    withAnimation(.default) {
                        isAnimating = false
                    }
                }
            }
    }
    
    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
}

struct WearerSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("userAge") private var userAge: Int = 0
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
