import SwiftUI
import YapnestKit

/// A strip across the top of the app for a call that isn't filling the screen,
/// so a call never blocks the app. It is all of an audio call's interface where
/// CallKit isn't used, rings an incoming call there with its answer and decline
/// buttons, and under CallKit, whose own screen can't be presented from here,
/// it is how a user in the app sees the call and ends it. Tapping the name
/// opens our call view where there is one.
struct CallBar: View {
    let session: XMPPSession
    let controller: CallController
    let state: CallState

    @State private var contact: Contact?

    private var name: String { contact?.displayName ?? state.peer.shortName }

    var body: some View {
        HStack(spacing: 12) {
            summary
            if !state.isOver { controls }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(CallBarBackground())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .task(id: state.peer) {
            let database = session.database, peer = state.peer
            contact = await offMain { try? database.contact(peer) }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var summary: some View {
        if CallController.canExpand(screen: state, usesCallKit: CallController.usesCallKit) {
            Button { controller.expand() } label: { names }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the call")
        } else {
            names
        }
    }

    private var names: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                CallStatus(state: state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var controls: some View {
        if state.phase == .incoming {
            ringingControls
        } else {
            activeControls
        }
    }

    private var ringingControls: some View {
        HStack(spacing: 12) {
            Button {
                controller.endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .frame(width: 36, height: 36)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Decline")
            Button {
                controller.answer()
            } label: {
                Image(systemName: state.isVideo ? "video.fill" : "phone.fill")
                    .frame(width: 36, height: 36)
                    .background(Color.green, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Answer")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var activeControls: some View {
        Group {
            Button {
                controller.setMuted(!state.isMuted)
            } label: {
                Image(systemName: state.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 36, height: 36)
                    .background(state.isMuted ? Color.primary : Color(.secondarySystemFill), in: Circle())
                    .foregroundStyle(state.isMuted ? Color(.systemBackground) : Color.primary)
            }
            .accessibilityLabel("Mute")
            .accessibilityAddTraits(state.isMuted ? .isSelected : [])
            if state.isVideo {
                Button {
                    controller.setCameraEnabled(!state.isCameraOn)
                } label: {
                    Image(systemName: state.isCameraOn ? "video.fill" : "video.slash.fill")
                        .frame(width: 36, height: 36)
                        .background(state.isCameraOn ? Color(.secondarySystemFill) : Color.primary, in: Circle())
                        .foregroundStyle(state.isCameraOn ? Color.primary : Color(.systemBackground))
                }
                .accessibilityLabel("Camera")
                .accessibilityAddTraits(state.isCameraOn ? [] : .isSelected)
            }
            #if targetEnvironment(macCatalyst)
            Menu {
                CallDevicePickers(showsCamera: state.isVideo, inMenu: true)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemFill), in: Circle())
                    .foregroundStyle(Color.primary)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("Devices")
            #endif
            Button {
                controller.endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .frame(width: 36, height: 36)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("End")
        }
        .buttonStyle(.plain)
    }
}

/// Glass where the composer uses it, a material before iOS 26.
private struct CallBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
