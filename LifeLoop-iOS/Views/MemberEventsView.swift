import SwiftUI

struct MemberEventsView: View {
    let events: [MemberEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent events").font(.title3.bold())
            if events.isEmpty {
                Text("No events recorded on this phone yet.").foregroundStyle(.secondary).loopCard()
            }
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 8) {
                    Label(event.title, systemImage: "exclamationmark.circle").font(.headline)
                    Text(event.date, format: .dateTime.month().day().year().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                }.loopCard()
            }
            Text("Events are recorded when this phone receives a group update.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
