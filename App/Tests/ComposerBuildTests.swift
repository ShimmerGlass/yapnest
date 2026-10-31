import Testing
import UIKit
@testable import Yapnest

/// Opening a chat builds a composer, which cost a frame; these keep what the
/// trims in `ConversationInputBar` must not change.
@MainActor
struct ComposerBuildTests {
    private func makeBar() -> ConversationInputBar {
        ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    }

    /// Every button, and every view that is hidden or faded, in tree order.
    /// The recording row is left out: it is built when first needed.
    private func controls(of bar: ConversationInputBar) -> [String] {
        var lines: [String] = []
        func walk(_ view: UIView, _ depth: Int) {
            if view is VoiceRecordingRow { return }
            if view is UIButton || view.isHidden || view.alpha != 1 {
                let label = view.accessibilityLabel ?? ""
                lines.append("\(depth) \(type(of: view)) \(label) hidden=\(view.isHidden) alpha=\(view.alpha)")
            }
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(bar, 0)
        return lines
    }

    private func attachment() -> PendingAttachment {
        PendingAttachment(content: .file(URL(fileURLWithPath: "/tmp/a.txt"), isPhoto: false))
    }

    private static let emptyControls = [
        "5 UIButton Attach hidden=false alpha=1.0",
        "4 UIButton GIF hidden=true alpha=1.0",
        "4 UIButton Emoji hidden=true alpha=1.0",
        "6 UIScrollView  hidden=true alpha=1.0",
        "6 UIView  hidden=true alpha=1.0",
        "8 UIButton Cancel hidden=false alpha=1.0",
        "6 AttachmentTray  hidden=true alpha=1.0",
        "7 UIButton Camera hidden=false alpha=1.0",
        "3 UIButton Send hidden=true alpha=0.0",
        "3 MicButton Record voice message hidden=false alpha=1.0",
    ]

    @Test func anEmptyComposerShowsTheMicrophoneAndCamera() {
        #expect(controls(of: makeBar()) == Self.emptyControls)
    }

    @Test func textReplacesTheMicrophoneAndCameraWithSend() {
        let bar = makeBar()
        bar.setText("hi", notify: false)
        #expect(controls(of: bar) == [
            "5 UIButton Attach hidden=false alpha=1.0",
            "4 UIButton GIF hidden=true alpha=1.0",
            "4 UIButton Emoji hidden=true alpha=1.0",
            "6 UIScrollView  hidden=true alpha=1.0",
            "6 UIView  hidden=true alpha=1.0",
            "8 UIButton Cancel hidden=false alpha=1.0",
            "6 AttachmentTray  hidden=true alpha=1.0",
            "8 UILabel  hidden=true alpha=1.0",
            "7 UIButton Camera hidden=true alpha=0.0",
            "3 UIButton Send hidden=false alpha=1.0",
            "3 MicButton Record voice message hidden=true alpha=0.0",
        ])
    }

    @Test func aStagedAttachmentReplacesTheMicrophoneAndCameraWithSend() {
        let bar = makeBar()
        bar.setPendingAttachments([attachment()])
        #expect(controls(of: bar) == [
            "5 UIButton Attach hidden=false alpha=1.0",
            "4 UIButton GIF hidden=true alpha=1.0",
            "4 UIButton Emoji hidden=true alpha=1.0",
            "6 UIScrollView  hidden=true alpha=1.0",
            "6 UIView  hidden=true alpha=1.0",
            "8 UIButton Cancel hidden=false alpha=1.0",
            "9 UIButton Remove hidden=false alpha=1.0",
            "7 UIButton Camera hidden=true alpha=0.0",
            "3 UIButton Send hidden=false alpha=1.0",
            "3 MicButton Record voice message hidden=true alpha=0.0",
        ])
    }

    @Test func aReplyShowsItsPreviewAndKeepsTheMicrophone() {
        let bar = makeBar()
        bar.setReply((author: "Ann", text: "Hello"))
        #expect(controls(of: bar) == [
            "5 UIButton Attach hidden=false alpha=1.0",
            "4 UIButton GIF hidden=true alpha=1.0",
            "4 UIButton Emoji hidden=true alpha=1.0",
            "6 UIScrollView  hidden=true alpha=1.0",
            "8 UIButton Cancel hidden=false alpha=1.0",
            "6 AttachmentTray  hidden=true alpha=1.0",
            "7 UIButton Camera hidden=false alpha=1.0",
            "3 UIButton Send hidden=true alpha=0.0",
            "3 MicButton Record voice message hidden=false alpha=1.0",
        ])
    }

    @Test func theRecordingRowIsBuiltWhenTheFirstRecordingStarts() async {
        let recorder = VoiceRecorder(
            engine: VoiceRecorderTests.FakeEngine(),
            audio: VoicePlayback(session: VoicePlaybackTests.FakeSession()),
            requestMicrophone: { true },
            isMicrophoneUndetermined: { false },
        )
        let bar = makeBar()
        bar.voice = recorder
        recorder.onChange = { [weak bar] in bar?.voiceChanged() }
        #expect(!bar.hasRecordingRow)
        #expect(controls(of: bar) == Self.emptyControls)

        recorder.press(locked: true)
        for _ in 0..<100 where recorder.phase == .starting { await Task.yield() }
        #expect(recorder.phase == .locked)
        #expect(bar.hasRecordingRow)
        let row = bar.firstDescendant(ofType: VoiceRecordingRow.self)
        #expect(row?.isHidden == false)
        #expect(row?.isUserInteractionEnabled == true)

        recorder.cancel()
        #expect(bar.hasRecordingRow)
    }

    /// Printed, not asserted: the average to build a composer, for comparing a
    /// change. Simulator numbers only indicate direction.
    @Test func printBuildTime() {
        let runs = 20
        _ = makeBar()
        let start = ContinuousClock.now
        for _ in 0..<runs { _ = makeBar() }
        let elapsed = ContinuousClock.now - start
        print("COMPOSER BUILD average ms: \(Double(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000) / Double(runs))")
    }
}

private extension UIView {
    func firstDescendant<T: UIView>(ofType type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T ?? view.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
