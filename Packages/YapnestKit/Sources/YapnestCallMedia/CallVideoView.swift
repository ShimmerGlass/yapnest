#if os(iOS)
import SwiftUI
import YapnestKit
@preconcurrency import WebRTC

/// One side of a video call's picture. It draws only media made by
/// `WebRTCCallMediaFactory`; for any other it stays empty.
public struct CallVideoView: UIViewRepresentable {
    public let media: any CallMedia
    public let side: CallVideoSide

    public init(media: any CallMedia, side: CallVideoSide) {
        self.media = media
        self.side = side
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(media: media as? WebRTCCallMedia, side: side)
    }

    public func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        context.coordinator.attach(view)
        return view
    }

    public func updateUIView(_ view: RTCMTLVideoView, context: Context) {}

    public static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.detach(view)
    }

    public final class Coordinator {
        private let media: WebRTCCallMedia?
        private let side: CallVideoSide

        init(media: WebRTCCallMedia?, side: CallVideoSide) {
            self.media = media
            self.side = side
        }

        func attach(_ view: RTCMTLVideoView) { media?.addRenderer(view, for: side) }
        func detach(_ view: RTCMTLVideoView) { media?.removeRenderer(view, for: side) }
    }
}
#endif
