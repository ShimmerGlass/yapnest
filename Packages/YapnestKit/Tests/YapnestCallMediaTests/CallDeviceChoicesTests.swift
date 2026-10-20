import Foundation
import Testing
@testable import YapnestCallMedia

@Suite("Call device choices")
struct CallDeviceChoicesTests {
    private func choices() -> (CallDeviceChoices, UserDefaults, String) {
        let suite = "app.yapnest.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CallDeviceChoices(defaults: defaults), defaults, suite)
    }

    @Test("nothing is chosen at first, and a choice is kept by a new reader")
    func persistence() {
        let (choices, defaults, suite) = choices()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(choices.inputUID == nil && choices.outputUID == nil && choices.cameraID == nil)
        choices.inputUID = "mic-uid"
        choices.outputUID = "speaker-uid"
        choices.cameraID = "camera-id"
        let again = CallDeviceChoices(defaults: defaults)
        #expect(again.inputUID == "mic-uid")
        #expect(again.outputUID == "speaker-uid")
        #expect(again.cameraID == "camera-id")
        choices.inputUID = nil
        #expect(again.inputUID == nil)
    }

    @Test("a change is announced, and setting the same value is not")
    func announcesChanges() {
        let (choices, defaults, suite) = choices()
        defer { defaults.removePersistentDomain(forName: suite) }
        nonisolated(unsafe) var count = 0
        let observer = NotificationCenter.default.addObserver(
            forName: CallDeviceChoices.didChange, object: choices, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        choices.outputUID = "a"
        choices.outputUID = "a"
        choices.outputUID = "b"
        choices.outputUID = nil
        choices.outputUID = nil
        #expect(count == 3)
    }

    @Test("a missing audio device means the system default")
    func audioFallsBackToDefault() {
        #expect(CallDeviceResolution.audio(choice: nil, available: ["a", "b"]) == nil)
        #expect(CallDeviceResolution.audio(choice: "b", available: ["a", "b"]) == "b")
        #expect(CallDeviceResolution.audio(choice: "gone", available: ["a", "b"]) == nil)
        #expect(CallDeviceResolution.audio(choice: "a", available: []) == nil)
    }

    @Test("the camera is the chosen one, else the first")
    func cameraResolution() {
        #expect(CallDeviceResolution.camera(choice: nil, available: ["x", "y"]) == "x")
        #expect(CallDeviceResolution.camera(choice: "y", available: ["x", "y"]) == "y")
        #expect(CallDeviceResolution.camera(choice: "gone", available: ["x", "y"]) == "x")
        #expect(CallDeviceResolution.camera(choice: "y", available: []) == nil)
    }

    #if os(macOS)
    @Test("the Mac's devices are listed with a UID and a name")
    func listsDevices() {
        for scope in [CoreAudioDevices.Scope.input, .output] {
            for device in CoreAudioDevices.devices(scope) {
                #expect(!device.uid.isEmpty && !device.name.isEmpty)
            }
            if let fallback = CoreAudioDevices.resolved(uid: "no-such-device", scope) {
                #expect(fallback.uid == CoreAudioDevices.defaultDevice(scope)?.uid)
            }
        }
    }
    #endif
}
