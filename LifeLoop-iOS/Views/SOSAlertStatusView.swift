import SwiftUI

struct SOSAlertStatusView: View {
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(LoopStyle.green)
                    .padding(32)
                    .background(LoopStyle.mint, in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.largeTitle.bold())
                Text(message).font(.title3).foregroundStyle(.secondary)
                Text("Close returns Home and requests cancellation. Calls that have already started cannot be stopped here.")
                    .foregroundStyle(.secondary)
                Button("Close", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Stops the alarm, requests cancellation, and returns Home.")
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .padding(.top, 70)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
        }.loopPage()
    }
}
