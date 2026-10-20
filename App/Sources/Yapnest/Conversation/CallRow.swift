import SwiftUI
import YapnestKit

extension CallSummary {
    /// "Missed call", "Outgoing call · 2:31" and so on.
    var title: String {
        let base: String = switch outcome {
        case .answered where isVideo: direction == .outgoing ? String(localized: "Outgoing video call") : String(localized: "Incoming video call")
        case .answered: direction == .outgoing ? String(localized: "Outgoing call") : String(localized: "Incoming call")
        case .missed where isVideo: String(localized: "Missed video call")
        case .missed: String(localized: "Missed call")
        case .declined: String(localized: "Declined call")
        case .cancelled: String(localized: "Cancelled call")
        case .busy: String(localized: "Busy")
        case .failed: String(localized: "Call failed")
        }
        guard outcome == .answered, let duration else { return base }
        return "\(base) · \(Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1))))"
    }

    var symbol: String {
        switch outcome {
        case .answered where isVideo, .cancelled where isVideo: "video"
        case .answered, .cancelled: direction == .outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"
        case .missed where isVideo: "video.slash"
        case .missed, .declined, .busy, .failed: "phone.down"
        }
    }

    /// A video call is called back with video only if the peer can take it now.
    func callsBackWithVideo(peerTakesVideo: Bool) -> Bool { isVideo && peerTakesVideo }

    /// The chat list's line for a call.
    var snippet: String { "\(isVideo ? "📹" : "📞") \(title)" }
}

/// A call in the chat: a small centred line, not a bubble. Tapping it calls
/// the contact back.
struct CallRowView: View {
    let row: MessageRow
    let call: CallSummary
    let model: ConversationModel

    @Environment(AppModel.self) private var app

    private var isCallable: Bool { app.callablePeers.contains(model.peer) }

    var body: some View {
        Button {
            guard isCallable, !app.calls.isInCall else { return }
            app.calls.startCall(to: model.peer, video: call.callsBackWithVideo(peerTakesVideo: app.videoCallablePeers.contains(model.peer)))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: call.symbol)
                Text(call.title)
                Text(row.content.time).foregroundStyle(.tertiary)
            }
            .font(.footnote)
            .foregroundStyle(call.outcome == .missed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: Capsule())
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.content.accessibilityLabel)
        .accessibilityHint("Calls back")
    }
}
