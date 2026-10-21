import SwiftUI
import YapnestKit

/// A strip across the top of the app for a call that isn't filling the screen,
/// so a call never blocks the app. Where CallKit isn't used it is where an audio
/// call starts, and rings an incoming call with its answer and decline
/// buttons, and under CallKit, whose own screen can't be presented from here,
/// it is how a user in the app sees the call and ends it. Tapping the name
/// opens our call view where there is one.
struct CallBar: View {
    let session: XMPPSession
    let controller: CallController
    let state: CallState

    @State private var loadedName: String?

    private var name: String { loadedName ?? state.peer.shortName }

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
        .task(id: state.peer) { loadedName = await CallController.displayName(of: state.peer, in: session) }
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

    private func disc(_ symbol: String, fill: Color, foreground: Color) -> some View {
        Image(systemName: symbol)
            .frame(width: 36, height: 36)
            .background(fill, in: Circle())
            .foregroundStyle(foreground)
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
                disc("phone.down.fill", fill: Color.red, foreground: .white)
            }
            .accessibilityLabel("Decline")
            Button {
                controller.answer()
            } label: {
                disc(state.isVideo ? "video.fill" : "phone.fill", fill: Color.green, foreground: .white)
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
                disc(state.isMuted ? "mic.slash.fill" : "mic.fill", fill: state.isMuted ? Color.primary : Color(.secondarySystemFill), foreground: state.isMuted ? Color(.systemBackground) : Color.primary)
            }
            .accessibilityLabel("Mute")
            .accessibilityAddTraits(state.isMuted ? .isSelected : [])
            if state.isVideo {
                Button {
                    controller.setCameraEnabled(!state.isCameraOn)
                } label: {
                    disc(state.isCameraOn ? "video.fill" : "video.slash.fill", fill: state.isCameraOn ? Color(.secondarySystemFill) : Color.primary, foreground: state.isCameraOn ? Color.primary : Color(.systemBackground))
                }
                .accessibilityLabel("Camera")
                .accessibilityAddTraits(state.isCameraOn ? [] : .isSelected)
            }
            #if targetEnvironment(macCatalyst)
            Menu {
                CallDevicePickers(showsCamera: state.isVideo, inMenu: true)
            } label: {
                disc("slider.horizontal.3", fill: Color(.secondarySystemFill), foreground: Color.primary)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("Devices")
            #endif
            Button {
                controller.endCall()
            } label: {
                disc("phone.down.fill", fill: Color.red, foreground: .white)
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
