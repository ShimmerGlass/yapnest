import SwiftUI
import YapnestKit

import YapnestCallMedia

/// The screen a user opens from the call bar, where CallKit isn't used, and
/// for a video call, which CallKit draws no picture for. A video call opens on
/// it. With CallKit, its own screens are an audio call's, and `CallBar` is all
/// the app adds. It can be minimized back to the bar, so a call doesn't block
/// the app.
struct CallView: View {
    let session: XMPPSession
    let controller: CallController
    let state: CallState

    @State private var contact: Contact?
    @State private var speakerOn = false
    @State private var media: (any CallMedia)?
    /// Which camera is in use, as the preview is mirrored for the front one.
    @State private var usesFrontCamera = true

    private var name: String { contact?.displayName ?? state.peer.shortName }

    var body: some View {
        Group {
            if state.isVideo {
                videoBody
            } else {
                audioBody
            }
        }
        .task(id: state.peer) {
            let database = session.database, peer = state.peer
            contact = await offMain { try? database.contact(peer) }
        }
    }

    private var audioBody: some View {
        VStack(spacing: 0) {
            Spacer()
            AvatarView(name: name, seed: state.peer.description, imageURL: session.avatars.url(for: contact), isLarge: true)
                .frame(width: 140, height: 140)
            Text(name)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            CallStatus(state: state)
                .font(.title3)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 8)
            Spacer()
            activeControls
                .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .topLeading) {
            MinimizeButton(controller: controller).padding(.leading, 16).padding(.top, 8)
        }
        .accessibilityElement(children: .contain)
    }

    private var muteButton: some View {
        CallButton(title: "Mute", symbol: state.isMuted ? "mic.slash.fill" : "mic.fill", isOn: state.isMuted) {
            controller.setMuted(!state.isMuted)
        }
    }

    private var endButton: some View {
        CallButton(title: "End", symbol: "phone.down.fill", tint: .red, isProminent: true) {
            controller.endCall()
        }
    }

    private var activeControls: some View {
        HStack(spacing: 32) {
            muteButton
            #if targetEnvironment(macCatalyst)
            // The Mac has no earpiece to choose against, but speakers to choose among.
            CallDevicesButton(showsCamera: false)
            #else
            CallButton(title: "Speaker", symbol: "speaker.wave.3.fill", isOn: speakerOn) {
                speakerOn.toggle()
                controller.setSpeaker(speakerOn)
            }
            #endif
            endButton
        }
        .disabled(state.isOver)
    }
}

extension CallView {
    /// Whether the peer's picture is there to draw: before that, our own
    /// fills the screen, as in FaceTime.
    private var showsRemote: Bool { state.activeSince != nil }

    var videoBody: some View {
        ZStack {
            // Only the pictures run under the island and the home indicator:
            // the words and buttons keep to the safe area.
            ZStack {
                Color.black
                if showsRemote {
                    if let media { CallVideoView(media: media, side: .remote).id(state.sid) }
                } else {
                    localPicture
                }
            }
            .ignoresSafeArea()
            if showsRemote { localTile }
            VStack(spacing: 0) {
                header
                    .overlay(alignment: .topLeading) { MinimizeButton(controller: controller).padding(.leading, -8) }
                Spacer()
                videoControls
                    .padding(.top, 32)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .background {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            .padding(.horizontal, -24)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
            .padding(.horizontal, 24)
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .task(id: state.sid) { media = await session.callMedia(sid: state.sid) }
        .accessibilityElement(children: .contain)
    }

    /// The name and status, over a gradient so they read on any picture.
    private var header: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            CallStatus(state: state)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -24)
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Our own picture, filling the screen or a tile.
    @ViewBuilder
    private var localPicture: some View {
        if state.isCameraOn, let media {
            CallVideoView(media: media, side: .local)
                .id(state.sid)
                .scaleEffect(x: usesFrontCamera ? -1 : 1)
        } else {
            Image(systemName: "video.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.12))
        }
    }

    private var localTile: some View {
        VStack {
            HStack {
                Spacer()
                localPicture
                    .frame(width: 110, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(radius: 6)
            }
            Spacer()
        }
        .padding(.trailing, 16)
        // Below the name and status, which sit at the top.
        .padding(.top, 72)
        .allowsHitTesting(false)
    }

    private var videoControls: some View {
        HStack(spacing: 20) {
            muteButton
            CallButton(title: "Camera", symbol: state.isCameraOn ? "video.fill" : "video.slash.fill", isOn: !state.isCameraOn) {
                controller.setCameraEnabled(!state.isCameraOn)
            }
            #if targetEnvironment(macCatalyst)
            // A Mac's cameras all face the user, so the picture stays mirrored,
            // and the camera is picked from the list instead of flipped to.
            CallDevicesButton(showsCamera: true)
            #else
            if WebRTCCallMedia.cameraCount > 1 {
                CallButton(title: "Flip", symbol: "arrow.triangle.2.circlepath.camera") {
                    usesFrontCamera.toggle()
                    controller.switchCamera()
                }
                .disabled(!state.isCameraOn)
            }
            #endif
            endButton
        }
        .disabled(state.isOver)
    }
}

/// Sends the call back to the bar, leaving it running.
private struct MinimizeButton: View {
    let controller: CallController

    var body: some View {
        Button {
            controller.minimize()
        } label: {
            Image(systemName: "chevron.down")
                .font(.headline)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minimize")
    }
}

private struct CallButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color?
    var isOn = false
    var isProminent = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(foreground)
                    .modifier(CallButtonBackground(fill: fill, glassTint: isOn ? Color.primary : nil, isProminent: isProminent))
            }
            .buttonStyle(.plain)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color { isProminent ? .white : isOn ? Color(.systemBackground) : .primary }

    private var fill: Color { isProminent ? tint ?? .accentColor : isOn ? .primary : Color(.secondarySystemFill) }
}

#if targetEnvironment(macCatalyst)
/// A call button that opens the pickers for the Mac's microphone, speaker and,
/// in a video call, camera.
private struct CallDevicesButton: View {
    let showsCamera: Bool

    var body: some View {
        VStack(spacing: 8) {
            Menu {
                CallDevicePickers(showsCamera: showsCamera, inMenu: true)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.primary)
                    .modifier(CallButtonBackground(fill: Color(.secondarySystemFill), glassTint: nil, isProminent: false))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Text("Devices")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

/// Glass where the composer uses it, a plain disc before iOS 26.
private struct CallButtonBackground: ViewModifier {
    let fill: Color
    /// Nil leaves the glass untinted.
    let glassTint: Color?
    let isProminent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *), !isProminent {
            content.glassEffect(.regular.tint(glassTint).interactive(), in: .circle)
        } else {
            content.background(fill, in: Circle())
        }
    }
}

/// What a call is doing, in words or as the time it has been going on.
struct CallStatus: View {
    let state: CallState

    var body: some View {
        switch state.phase {
        case .proposing: Text("Calling…")
        case .ringing: Text("Ringing…")
        case .incoming: Text(state.isVideo ? "Incoming video call…" : "Incoming call…")
        case .accepted, .connecting: Text("Connecting…")
        case .active:
            if let since = state.activeSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))
                }
            } else {
                Text("Connecting…")
            }
        case .ended(let reason): Text(Self.title(of: reason))
        }
    }

    static func title(of reason: CallEndReason) -> LocalizedStringKey {
        switch reason {
        case .declined, .declinedElsewhere: "Declined"
        case .noAnswer: "No answer"
        case .busy: "Busy"
        case .failed: "Call failed"
        case .completed, .cancelled, .missed, .answeredElsewhere, .dismissed, .tieBreak: "Call ended"
        }
    }
}
