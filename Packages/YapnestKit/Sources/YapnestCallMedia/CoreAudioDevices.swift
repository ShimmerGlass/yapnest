#if os(macOS) || targetEnvironment(macCatalyst)
import CoreAudio
import Foundation

/// An audio device the Mac has, for the call's pickers.
public struct CallAudioDevice: Sendable, Hashable, Identifiable {
    public let uid: String
    public let name: String
    let objectID: AudioObjectID
    public var id: String { uid }
}

/// Where a sound of the app's own for the call, such as the ringback tone,
/// should come out: the speaker the user chose for calls, else the default.
public enum CallOutput {
    /// A CoreAudio device id for `kAudioOutputUnitProperty_CurrentDevice`.
    public static func deviceID(choices: CallDeviceChoices = .shared) -> UInt32? {
        CoreAudioDevices.resolved(uid: choices.outputUID, .output)?.objectID
    }
}

/// The Mac's audio devices, through CoreAudio. AVAudioSession on Catalyst lists
/// only the current input and offers no output choice, so it can't be used.
enum CoreAudioDevices {
    enum Scope {
        case input, output

        var coreAudio: AudioObjectPropertyScope {
            self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        }

        var defaultSelector: AudioObjectPropertySelector {
            self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Devices with at least one channel in `scope`, a virtual one included.
    static func devices(_ scope: Scope) -> [CallAudioDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device($0, scope) }
    }

    static func defaultDevice(_ scope: Scope) -> CallAudioDevice? {
        var address = address(scope.defaultSelector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown else { return nil }
        return device(id, scope)
    }

    /// The device to bind for a stored choice: that one if it is there, else the default.
    static func resolved(uid: String?, _ scope: Scope) -> CallAudioDevice? {
        let all = devices(scope)
        if let chosen = CallDeviceResolution.audio(choice: uid, available: all.map(\.uid)) {
            return all.first { $0.uid == chosen }
        }
        return defaultDevice(scope)
    }

    /// Seconds a sample takes to get through the device, as it reports it.
    static func latency(of device: CallAudioDevice, _ scope: Scope, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let frames = property(device, kAudioDevicePropertyLatency, scope: scope.coreAudio, UInt32.self)
            + property(device, kAudioDevicePropertySafetyOffset, scope: scope.coreAudio, UInt32.self)
        return Double(frames) / sampleRate
    }

    /// What the hardware itself runs at, which the unit converts to and from.
    struct Hardware {
        var sampleRate: Double
        var bufferFrames: Int
    }

    static func hardware(of device: CallAudioDevice) -> Hardware {
        Hardware(
            sampleRate: property(device, kAudioDevicePropertyNominalSampleRate, Float64.self),
            bufferFrames: Int(property(device, kAudioDevicePropertyBufferFrameSize, UInt32.self)))
    }

    /// A number of the device's, 0 where it can't say.
    private static func property<Value: Numeric>(
        _ device: CallAudioDevice, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _: Value.Type,
    ) -> Value {
        var address = address(selector, scope: scope)
        var value: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        _ = AudioObjectGetPropertyData(device.objectID, &address, 0, nil, &size, &value)
        return value
    }

    private static func device(_ id: AudioObjectID, _ scope: Scope) -> CallAudioDevice? {
        guard !isPrivateAggregate(id), hasChannels(id, scope), let uid = string(id, kAudioDevicePropertyDeviceUID),
            let name = string(id, kAudioObjectPropertyName) else { return nil }
        return CallAudioDevice(uid: uid, name: name, objectID: id)
    }

    /// The private aggregate device the voice-processing unit makes for itself
    /// while it runs shows up in the list, and isn't one to choose. (It isn't
    /// flagged hidden, but its composition says it is private.)
    private static func isPrivateAggregate(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioObjectPropertyClass)
        var deviceClass: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &deviceClass) == noErr,
            deviceClass == kAudioAggregateDeviceClassID else { return false }
        address = self.address(kAudioAggregateDevicePropertyComposition)
        var composition: Unmanaged<CFDictionary>?
        size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition) == noErr else { return false }
        let dictionary = composition?.takeRetainedValue() as? [String: Any]
        return (dictionary?[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
    }

    private static func hasChannels(_ id: AudioObjectID, _ scope: Scope) -> Bool {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope.coreAudio)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// Calls `handler` on `queue` when a device appears or goes, or a default changes.
    static func observe(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) -> Observation {
        Observation(queue: queue, handler: handler)
    }

    final class Observation: @unchecked Sendable {
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private let selectors = [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]

        fileprivate init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
            self.queue = queue
            block = { _, _ in handler() }
            for selector in selectors {
                var address = CoreAudioDevices.address(selector)
                AudioObjectAddPropertyListenerBlock(CoreAudioDevices.system, &address, queue, block)
            }
        }

        deinit {
            for selector in selectors {
                var address = CoreAudioDevices.address(selector)
                AudioObjectRemovePropertyListenerBlock(CoreAudioDevices.system, &address, queue, block)
            }
        }
    }
}
#endif
