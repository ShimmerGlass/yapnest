import AVFoundation
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import YapnestCallMedia
@testable import YapnestKit

@Suite("Call video capture", .serialized)
struct CallVideoCaptureTests {
    private let front = CameraCandidate(id: "front", position: .front)
    private let back = CameraCandidate(id: "back", position: .back)

    @Test("the chosen camera wins, then the one at the position, then the first")
    func choosesACamera() {
        let both = [front, back]
        #expect(CallVideoCapture.choose(from: both, chosenID: "back", position: .front)?.source == .chosenDevice)
        #expect(CallVideoCapture.choose(from: both, chosenID: "back", position: .front)?.index == 1)
        #expect(CallVideoCapture.choose(from: both, chosenID: nil, position: .back)?.source == .positionMatch)
        #expect(CallVideoCapture.choose(from: both, chosenID: "gone", position: .unspecified)?.source == .firstDevice)
        #expect(CallVideoCapture.choose(from: [], chosenID: "back", position: .front) == nil)
    }

    @Test("a call without a camera says why, and logs its first picture")
    func generatedPictureIsLogged() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
        DiagLog.use(store)
        defer { DiagLog.use(nil) }

        let capture = CallVideoCapture(source: RTCPeerConnectionFactory().videoSource(), synthetic: true)
        capture.start()
        var text = ""
        for _ in 0..<100 where !text.contains("First local video frame") {
            try await Task.sleep(for: .milliseconds(50))
            text = try String(contentsOf: DiagnosticsExport.make(store: store), encoding: .utf8)
        }
        capture.stop()
        try await Task.sleep(for: .milliseconds(200))
        text = try String(contentsOf: DiagnosticsExport.make(store: store), encoding: .utf8)

        #expect(text.contains("Call camera starting devices=0 source=syntheticRequested"))
        #expect(text.contains("First local video frame picture=under480"))
        #expect(text.contains("Call camera stopping"))
    }

    @Test("a picture is logged as a class, not its size")
    func pictureClasses() {
        #expect(PictureClass(height: 240) == .under480)
        #expect(PictureClass(height: 480) == .p480)
        #expect(PictureClass(height: 720) == .p720)
        #expect(PictureClass(height: 1080) == .p1080)
        #expect(PictureClass(height: 2160) == .larger)
    }

    @Test("an interruption's reason is named")
    func interruptionReasons() {
        #expect(CaptureInterruptionKind(code: 1) == .notAvailableInBackground)
        #expect(CaptureInterruptionKind(code: 4) == .multipleForegroundApps)
        #expect(CaptureInterruptionKind(code: nil) == .other)
    }
}
