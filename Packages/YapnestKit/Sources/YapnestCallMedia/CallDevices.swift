#if os(macOS) || targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import Observation
@preconcurrency import WebRTC

/// A camera the Mac has.
public struct CallCamera: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
}

/// The devices a call on the Mac can use and the user's choices among them,
/// for the call screen and Settings. The lists follow plugging and unplugging.
/// A choice is kept even while its device is away, so it applies again when
/// the device returns; `selectedInput` and the others say what is in use.
@MainActor
@Observable
public final class CallDevices {
    public static let shared = CallDevices()

    public private(set) var inputs: [CallAudioDevice] = []
    public private(set) var outputs: [CallAudioDevice] = []
    public private(set) var cameras: [CallCamera] = []

    public var inputUID: String? {
        didSet { choices.inputUID = inputUID }
    }

    public var outputUID: String? {
        didSet { choices.outputUID = outputUID }
    }

    public var cameraID: String? {
        didSet { choices.cameraID = cameraID }
    }

    /// The choice that is in effect: nil is the system default.
    public var selectedInput: String? { CallDeviceResolution.audio(choice: inputUID, available: inputs.map(\.uid)) }
    public var selectedOutput: String? { CallDeviceResolution.audio(choice: outputUID, available: outputs.map(\.uid)) }
    public var selectedCamera: String? { CallDeviceResolution.camera(choice: cameraID, available: cameras.map(\.id)) }

    @ObservationIgnored private let choices: CallDeviceChoices
    @ObservationIgnored private var audioObservation: CoreAudioDevices.Observation?
    @ObservationIgnored private var cameraObservers: [any NSObjectProtocol] = []

    init(choices: CallDeviceChoices = .shared) {
        self.choices = choices
        inputUID = choices.inputUID
        outputUID = choices.outputUID
        cameraID = choices.cameraID
        refresh()
        audioObservation = CoreAudioDevices.observe(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            cameraObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    public func refresh() {
        let inputs = CoreAudioDevices.devices(.input)
        if inputs != self.inputs { self.inputs = inputs }
        let outputs = CoreAudioDevices.devices(.output)
        if outputs != self.outputs { self.outputs = outputs }
        let cameras = RTCCameraVideoCapturer.captureDevices().map { CallCamera(id: $0.uniqueID, name: $0.localizedName) }
        if cameras != self.cameras { self.cameras = cameras }
    }
}
#endif
