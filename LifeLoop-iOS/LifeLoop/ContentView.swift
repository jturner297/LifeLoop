import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bleMonitor: BLEMonitor

    private let background = Color(red: 5/255, green: 15/255, blue: 29/255)
    private let primaryText = Color(red: 235/255, green: 241/255, blue: 246/255)
    private let secondaryText = Color(red: 119/255, green: 135/255, blue: 151/255)
    private let teal = Color(red: 0/255, green: 210/255, blue: 174/255)
    private let blue = Color(red: 24/255, green: 126/255, blue: 255/255)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.top, 44)

                    ECGWaveform(color: teal)
                        .frame(height: 86)
                        .padding(.top, 22)

                    Text("Devices")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                    deviceRow(
                        name: bleMonitor.connectedDeviceName ?? "LifeLoop Band - Mom",
                        status: bleMonitor.isConnected ? "Connected" : "Tap + to connect",
                        battery: bleMonitor.isConnected ? "82%" : "--",
                        accent: blue,
                        active: true
                    )

                    deviceRow(
                        name: "LifeLoop Band - Dad",
                        status: "Offline",
                        battery: "54%",
                        accent: secondaryText,
                        active: false
                    )

                    Spacer(minLength: 235)

                    Text("View family devices")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryText.opacity(0.75))
                        .padding(.bottom, 26)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: addOrConnect) {
                Image(systemName: bleMonitor.isScanning ? "xmark" : "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(background)
                    .frame(width: 56, height: 56)
                    .background(teal)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 28)
            .accessibilityLabel(bleMonitor.isScanning ? "Stop scanning" : "Add LifeLoop device")
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)

            Text(attentionText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var attentionText: String {
        bleMonitor.isConnected ? "1 of 2 devices need attention" : "2 of 2 devices need attention"
    }

    private func deviceRow(
        name: String,
        status: String,
        battery: String,
        accent: Color,
        active: Bool
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(active ? primaryText : secondaryText)

                HStack(spacing: 6) {
                    if active && bleMonitor.isScanning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(teal)
                    }

                    Text(status)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(secondaryText)
                }
            }

            Spacer()

            Text(battery)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
        .onTapGesture {
            if active && !bleMonitor.isConnected && !bleMonitor.isScanning {
                bleMonitor.startScanning()
            } else if active && bleMonitor.isConnected {
                bleMonitor.disconnect()
            }
        }
    }

    private func addOrConnect() {
        if bleMonitor.isScanning {
            bleMonitor.stopScanning()
        } else if bleMonitor.isConnected {
            bleMonitor.disconnect()
        } else {
            bleMonitor.startScanning()
        }
    }
}

private struct ECGWaveform: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let mid = height * 0.52

            Path { path in
                let points: [(CGFloat, CGFloat)] = [
                    (0.00, 0.52), (0.11, 0.52), (0.13, 0.50), (0.15, 0.50),
                    (0.17, 0.23), (0.185, 0.75), (0.205, 0.47), (0.24, 0.52),
                    (0.40, 0.52), (0.42, 0.50), (0.44, 0.50), (0.46, 0.23),
                    (0.475, 0.75), (0.495, 0.47), (0.53, 0.52), (0.70, 0.52),
                    (0.72, 0.50), (0.74, 0.50), (0.76, 0.23), (0.775, 0.75),
                    (0.795, 0.47), (0.83, 0.52), (1.00, 0.52)
                ]

                guard let first = points.first else { return }
                path.move(to: CGPoint(x: first.0 * width, y: first.1 * height))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: point.0 * width, y: point.1 * height))
                }
            }
            .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .position(x: width * 0.28, y: mid)
                .shadow(color: color.opacity(0.5), radius: 4)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(BLEMonitor())
}
