import SwiftUI
import YapnestKit

extension MessageEvent {
    /// What the line says as one sentence, for VoiceOver.
    func words(of name: String) -> String {
        switch self {
        case .newDevice: String(localized: "\(name) has a new device. Check that it's theirs.")
        }
    }
}

/// Something that happened in the chat, as a small centred line rather than
/// a bubble. It has no menu, reply or reactions; tapping it does what its
/// words offer.
struct EventRowView: View {
    let row: MessageRow
    let event: MessageEvent
    let name: String
    let model: ConversationModel

    var body: some View {
        switch event {
        case .newDevice:
            Button {
                model.devicesSheet = model.peer
            } label: {
                (Text("\(name) has a new device.") + Text(" ") + Text("Check").foregroundStyle(.tint) + Text(" that it's theirs."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.content.accessibilityLabel)
            .accessibilityHint("Opens their devices")
            .accessibilityIdentifier("newDeviceEvent")
        }
    }
}
