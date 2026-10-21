import CoreVideo
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import YapnestCallMedia

@Suite("Upright frames")
struct UprightFramesTests {
    private final class Recorder: NSObject, RTCVideoCapturerDelegate, @unchecked Sendable {
        var frames: [RTCVideoFrame] = []
        func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) { frames.append(frame) }
    }

    @Test("a frame the Mac's capturer tags as portrait reaches the source unturned, with its picture and time")
    func dropsTheRotation() throws {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer) == kCVReturnSuccess)
        let picture = RTCCVPixelBuffer(pixelBuffer: try #require(buffer))
        let recorder = Recorder()
        let upright = UprightFrames(target: recorder)
        upright.capturer(RTCVideoCapturer(), didCapture: RTCVideoFrame(buffer: picture, rotation: ._90, timeStampNs: 42))
        let frame = try #require(recorder.frames.first)
        #expect(frame.rotation == ._0)
        #expect(frame.timeStampNs == 42)
        #expect(frame.width == 64 && frame.height == 36)
    }
}
