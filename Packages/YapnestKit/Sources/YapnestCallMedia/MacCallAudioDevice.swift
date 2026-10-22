#if targetEnvironment(macCatalyst)
import AudioToolbox
import CoreAudio
import Foundation
import YapnestKit
@preconcurrency import WebRTC

/// A call's microphone and speaker on the Mac, with the choice of both that
/// WebRTC's own device doesn't have. That one is built on AVAudioSession, which
/// on the Mac can't pick devices (it lists only the current input, and no
/// outputs). This one runs a VoiceProcessingIO unit, so echo cancellation and
/// gain control stay, and binds the unit to the devices the user chose.
///
/// The unit takes the input device on element 1 and the output device on
/// element 0, both in the global scope, with IO enabled on the elements first.
/// One unit binds different devices for the two (checked by reading the
/// property back, and by input arriving from a microphone while playing out
/// of another device). Once a device is set there is no way to unset it, so
/// "System default" means binding the current default, and following it when
/// it changes. The system's own default is never touched.
///
/// WebRTC calls the `RTCAudioDevice` members from one thread of its own. The
/// device's state is only touched there, and a change of device is run there
/// too, through the delegate. The unit's callbacks run on its own thread and
/// read only what is set before the unit starts, so they take no lock and
/// allocate nothing.
final class MacCallAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    private static let fallbackSampleRate = 48_000.0
    private static let bufferDuration: TimeInterval = 0.01

    private var delegate: (any RTCAudioDeviceDelegate)?
    private var observation: CoreAudioDevices.Observation?
    private var choiceObserver: (any NSObjectProtocol)?
    private var engine: Engine?
    private var inputRate = MacCallAudioDevice.fallbackSampleRate
    private var outputRate = MacCallAudioDevice.fallbackSampleRate
    private var inputLatencySeconds: TimeInterval = 0
    private var outputLatencySeconds: TimeInterval = 0
    private var playoutInitialized = false
    private var playing = false
    private var recordingInitialized = false
    private var recording = false

    // MARK: Parameters

    // WebRTC gets 16-bit mono at these rates whatever the hardware runs at:
    // the unit converts, so a change of device doesn't change the format.
    var deviceInputSampleRate: Double { inputRate }
    var inputIOBufferDuration: TimeInterval { Self.bufferDuration }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { inputLatencySeconds }
    var deviceOutputSampleRate: Double { outputRate }
    var outputIOBufferDuration: TimeInterval { Self.bufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { outputLatencySeconds }

    var isInitialized: Bool { delegate != nil }
    var isPlayoutInitialized: Bool { playoutInitialized }
    var isPlaying: Bool { playing }
    var isRecordingInitialized: Bool { recordingInitialized }
    var isRecording: Bool { recording }

    // MARK: Lifecycle

    // Nothing here opens a device: WebRTC initializes the device with the
    // factory, and the microphone must stay shut until a call is answered.
    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        inputRate = delegate.preferredInputSampleRate > 0 ? delegate.preferredInputSampleRate : Self.fallbackSampleRate
        outputRate = delegate.preferredOutputSampleRate > 0 ? delegate.preferredOutputSampleRate : Self.fallbackSampleRate
        nonisolated(unsafe) let delegate = delegate
        let changed: @Sendable () -> Void = { [weak self] in
            delegate.dispatchAsync { self?.devicesChanged() }
        }
        observation = CoreAudioDevices.observe(queue: .global(qos: .userInitiated), changed)
        choiceObserver = NotificationCenter.default.addObserver(
            forName: CallDeviceChoices.didChange, object: nil, queue: nil) { _ in changed() }
        return true
    }

    func terminateDevice() -> Bool {
        playing = false
        recording = false
        playoutInitialized = false
        recordingInitialized = false
        _ = reconfigure(interrupted: false)
        observation = nil
        if let choiceObserver { NotificationCenter.default.removeObserver(choiceObserver) }
        choiceObserver = nil
        delegate = nil
        return true
    }

    func initializePlayout() -> Bool {
        playoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        guard playoutInitialized else { return false }
        playing = true
        return reconfigure(interrupted: false)
    }

    func stopPlayout() -> Bool {
        playing = false
        playoutInitialized = false
        return reconfigure(interrupted: false)
    }

    func initializeRecording() -> Bool {
        recordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        guard recordingInitialized else { return false }
        recording = true
        return reconfigure(interrupted: false)
    }

    func stopRecording() -> Bool {
        recording = false
        recordingInitialized = false
        return reconfigure(interrupted: false)
    }

    // MARK: Unit

    /// Rebuilds the unit for what is playing and recording now. One unit does
    /// both, and its input is only enabled while recording, so a call that
    /// only listens never opens the microphone.
    private func reconfigure(interrupted: Bool) -> Bool {
        engine?.shutDown()
        engine = nil
        guard playing || recording, let delegate else { return true }
        // A device the user chose that the unit refuses (one that went away
        // between listing and binding) shouldn't end the call.
        guard let engine = Engine(device: self, delegate: delegate, useChoices: true)
            ?? Engine(device: self, delegate: delegate, useChoices: false)
        else {
            DiagLog.error(.calls, "Call audio unit could not be made", .bool("records", recording), .bool("plays", playing))
            return false
        }
        self.engine = engine
        inputLatencySeconds = engine.inputLatency
        outputLatencySeconds = engine.outputLatency
        if interrupted {
            // The new unit calls from a thread of its own.
            delegate.notifyAudioInputInterrupted()
            delegate.notifyAudioOutputInterrupted()
            delegate.notifyAudioInputParametersChange()
            delegate.notifyAudioOutputParametersChange()
        }
        guard engine.start() else {
            DiagLog.error(.calls, "Call audio unit failed to start", .bool("records", engine.records), .bool("plays", engine.plays))
            engine.shutDown()
            self.engine = nil
            return false
        }
        logStarted(engine, interrupted: interrupted)
        return true
    }

    /// What the unit runs at, for working out where a call's delay is. The
    /// devices themselves are never named.
    private func logStarted(_ engine: Engine, interrupted: Bool) {
        var fields: [DiagField] = [
            .bool("rebound", interrupted), .bool("records", engine.records), .bool("plays", engine.plays),
            .int("webrtcInputRate", Int(inputRate)), .int("webrtcOutputRate", Int(outputRate)),
            .duration("inputLatency", engine.inputLatency), .duration("outputLatency", engine.outputLatency),
        ]
        if let device = engine.inputDevice {
            let hardware = CoreAudioDevices.hardware(of: device)
            fields += [.int("inputDeviceRate", Int(hardware.sampleRate)), .int("inputDeviceBuffer", hardware.bufferFrames)]
        }
        if let device = engine.outputDevice {
            let hardware = CoreAudioDevices.hardware(of: device)
            fields += [.int("outputDeviceRate", Int(hardware.sampleRate)), .int("outputDeviceBuffer", hardware.bufferFrames)]
        }
        DiagLog.info(.calls, "Call audio unit started", fields: fields)
    }

    /// A device came or went, a default moved, or the user chose another.
    /// Runs on WebRTC's thread.
    private func devicesChanged() {
        guard delegate != nil, let engine else { return }
        let choices = CallDeviceChoices.shared
        let input = engine.records ? CoreAudioDevices.resolved(uid: choices.inputUID, .input)?.uid : nil
        let output = CoreAudioDevices.resolved(uid: choices.outputUID, .output)?.uid
        guard input != engine.inputUID || output != engine.outputUID else { return }
        DiagLog.info(.calls, "Call audio devices changed, rebinding")
        if !reconfigure(interrupted: true) {
            DiagLog.error(.calls, "Call audio could not follow the change of device")
        }
    }

    /// One VoiceProcessingIO unit and what its callbacks need.
    private final class Engine {
        let records: Bool
        let plays: Bool
        private(set) var inputDevice: CallAudioDevice?
        private(set) var outputDevice: CallAudioDevice?
        var inputUID: String? { inputDevice?.uid }
        var outputUID: String? { outputDevice?.uid }
        private(set) var inputLatency: TimeInterval = 0
        private(set) var outputLatency: TimeInterval = 0

        // Set before the unit starts and not after, so the callbacks read
        // them without a lock.
        private var unit: AudioUnit?
        private let deliver: RTCAudioDeviceDeliverRecordedDataBlock
        private let getPlayout: RTCAudioDeviceGetPlayoutDataBlock
        private var render: RTCAudioDeviceRenderRecordedDataBlock?
        private var started = false

        init?(device: MacCallAudioDevice, delegate: any RTCAudioDeviceDelegate, useChoices: Bool) {
            records = device.recording
            plays = device.playing
            deliver = delegate.deliverRecordedData
            getPlayout = delegate.getPlayoutData

            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { return nil }
            var created: AudioUnit?
            guard AudioComponentInstanceNew(component, &created) == noErr, let unit = created else { return nil }
            self.unit = unit
            render = { [unit] flags, timestamp, bus, frames, data, _ in
                AudioUnitRender(unit, flags, timestamp, UInt32(bus), frames, data)
            }
            guard configure(unit, device: device, useChoices: useChoices) else {
                shutDown()
                return nil
            }
        }

        private func configure(_ unit: AudioUnit, device: MacCallAudioDevice, useChoices: Bool) -> Bool {
            var on: UInt32 = 1
            var input: UInt32 = records ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            // IO is enabled before any device is set.
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &input, size) == noErr,
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, size) == noErr
            else { return false }

            let choices = CallDeviceChoices.shared
            if records {
                guard let input = CoreAudioDevices.resolved(uid: useChoices ? choices.inputUID : nil, .input),
                    bind(unit, input, element: 1) else { return false }
                inputDevice = input
                inputLatency = CoreAudioDevices.latency(of: input, .input, sampleRate: device.inputRate) + MacCallAudioDevice.bufferDuration
            }
            guard let output = CoreAudioDevices.resolved(uid: useChoices ? choices.outputUID : nil, .output),
                bind(unit, output, element: 0) else { return false }
            outputDevice = output
            outputLatency = CoreAudioDevices.latency(of: output, .output, sampleRate: device.outputRate) + MacCallAudioDevice.bufferDuration

            // The unit converts between these and the hardware's format.
            var recorded = Self.format(sampleRate: device.inputRate)
            var played = Self.format(sampleRate: device.outputRate)
            let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &recorded, formatSize) == noErr,
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &played, formatSize) == noErr
            else { return false }

            let context = Unmanaged.passUnretained(self).toOpaque()
            let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            if records {
                var callback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, bus, frames, _ in
                    let engine = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
                    return engine.deliver(flags, timestamp, Int(bus), frames, nil, nil, engine.render)
                }, inputProcRefCon: context)
                guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callback, callbackSize) == noErr
                else { return false }
            }
            var playback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, bus, frames, data in
                guard let data else { return noErr }
                let engine = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
                if engine.plays { return engine.getPlayout(flags, timestamp, Int(bus), frames, data) }
                // The output is enabled for the echo canceller even when
                // only recording; it plays silence.
                for buffer in UnsafeMutableAudioBufferListPointer(data) {
                    if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }, inputProcRefCon: context)
            guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &playback, callbackSize) == noErr
            else { return false }
            return AudioUnitInitialize(unit) == noErr
        }

        private func bind(_ unit: AudioUnit, _ device: CallAudioDevice, element: AudioUnitElement) -> Bool {
            var id = device.objectID
            return AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element,
                &id, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr
        }

        private static func format(sampleRate: Double) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        }

        func start() -> Bool {
            guard let unit else { return false }
            started = AudioOutputUnitStart(unit) == noErr
            return started
        }

        /// Stopping waits for a callback in progress, so nothing reads the
        /// engine once this returns.
        func shutDown() {
            guard let unit else { return }
            if started { AudioOutputUnitStop(unit) }
            started = false
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
            render = nil
        }

        deinit { shutDown() }
    }
}
#endif
