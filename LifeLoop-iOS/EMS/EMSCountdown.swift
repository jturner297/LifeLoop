import SwiftUI

struct EMSCountdown: View {
    @ObservedObject var timerManager: EMSTimerManager
    var onCancel: (() -> Void)?
    @EnvironmentObject private var bleMonitor: BLEMonitor

    var body: some View {
        EmergencyCountdownScreen(
            secondsRemaining: timerManager.timeRemaining,
            reason: timerManager.triggerReason
        ) {
            if let onCancel { onCancel() }
            else { timerManager.cancelCountdown(); bleMonitor.sendCancelCommand() }
        }
        .interactiveDismissDisabled()
    }
}

/// Presentation is separate from the alarm so previews never trigger audio, Bluetooth, or AWS.
struct EmergencyCountdownScreen: View {
    let secondsRemaining: Int
    let reason: String
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize = 100
    @State private var isPulsing = false

    private let emergencyRed = Color(red: 0.73, green: 0.08, blue: 0.13)
    private let deepRed = Color(red: 0.35, green: 0.03, blue: 0.07)

    private var progress: CGFloat {
        CGFloat(min(max(secondsRemaining, 0), 30)) / 30
    }

    private var readableReason: String {
        reason.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 26) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("EMERGENCY ALERT").tracking(2)
                    }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .background(.white.opacity(0.14), in: Capsule())

                    VStack(spacing: 12) {
                        Text("Do you need help?")
                            .font(.largeTitle.bold())
                        Text(readableReason)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .multilineTextAlignment(.center)

                    countdown
                        .frame(maxWidth: 270)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 10) {
                        Text("Emergency call countdown")
                            .font(.title2.bold())
                        Text("LifeLoop is contacting your family service. Saved contacts are called after the service’s grace period. Cancel now if you’re safe.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .frame(maxWidth: 650)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .foregroundStyle(.white)
        .background {
            LinearGradient(colors: [emergencyRed, deepRed], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Button(action: onCancel) {
                    Label("I’m OK — Cancel alert", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(deepRed)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Stops the alarm and requests cancellation before contact calls begin.")
                Text("Tap to stop the alarm")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
            .background(deepRed)
        }
        .preferredColorScheme(.dark)
        .onAppear { isPulsing = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in isPulsing = !reduced }
    }

    private var countdown: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 9)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.35), value: secondsRemaining)

            VStack(spacing: 0) {
                Image(systemName: "wave.3.right")
                    .font(.title2.bold())
                    .opacity(isPulsing ? 1 : 0.55)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                Text("\(max(secondsRemaining, 0))")
                    .font(.system(size: countdownSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("SECONDS")
                    .font(.caption.bold())
                    .tracking(3)
            }
            .padding(30)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time until family alert")
        .accessibilityValue("\(max(secondsRemaining, 0)) seconds")
    }
}

#Preview("Emergency countdown") {
    EmergencyCountdownScreen(secondsRemaining: 18, reason: "SEVERE FALL DETECTED", onCancel: {})
}

#Preview("Emergency · Large text") {
    EmergencyCountdownScreen(secondsRemaining: 8, reason: "MANUAL SOS", onCancel: {})
        .environment(\.dynamicTypeSize, .accessibility3)
}
