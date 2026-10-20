import AVFoundation
import Foundation
import os
import YapnestKit

#if targetEnvironment(macCatalyst)
import AudioToolbox
import CoreAudio
import YapnestCallMedia
#endif

private let ringbackLogger = Logger(subsystem: "Yapnest", category: "Calls")

/// The tone an outgoing call plays while the other end rings. CallKit plays
/// nothing for a call we place, so the app does, on every platform.
///
/// It is the North American ringback, 440 and 480 Hz together for two seconds
/// of every six, made as samples instead of shipped as a file.
enum RingbackTone {
    static let period: Double = 6
    static let onDuration: Double = 2
    /// Each edge fades over this long, as a tone that starts at once clicks.
    static let fade: Double = 0.02
    /// The two partials add up to about -12 dBFS at their peak.
    static let partialLevel: Double = 0.125

    /// Whether the tone should be heard for `state`: only while our own call
    /// is waiting for the peer, so it is gone the moment the call is answered.
    static func plays(for state: CallState?) -> Bool {
        guard let state, state.direction == .outgoing else { return false }
        return state.phase.isAwaitingAnswer
    }

    /// The tone's loudness, from 0 to 1, at a sample of the cadence.
    static func envelope(frame: Int, sampleRate: Double) -> Double {
        let position = frame % Int(period * sampleRate)
        let on = Int(onDuration * sampleRate)
        guard position < on else { return 0 }
        let fadeFrames = max(1, fade * sampleRate)
        return min(1, Double(position) / fadeFrames, Double(on - 1 - position) / fadeFrames)
    }

    static func sample(frame: Int, sampleRate: Double) -> Float {
        let envelope = envelope(frame: frame, sampleRate: sampleRate)
        guard envelope > 0 else { return 0 }
        let t = Double(frame) / sampleRate
        return Float(envelope * partialLevel * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)))
    }
}

/// Writes the tone for an audio callback. Only that callback touches the
/// frame count, and nothing here locks or allocates.
final class RingbackRenderer: @unchecked Sendable {
    let sampleRate: Double
    private var frame = 0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func render(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        for i in 0..<frames {
            let value = RingbackTone.sample(frame: frame + i, sampleRate: sampleRate)
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                for channel in 0..<channels { data[i * channels + channel] = value }
            }
        }
        frame += frames
    }

    // The callbacks are made here, outside the main-actor players, as a closure
    // written inside one is isolated to the main actor too, and Swift traps
    // when the audio thread calls it.

    #if targetEnvironment(macCatalyst)
    /// For a HAL output unit whose refcon is an unretained renderer.
    static let renderCallback: AURenderCallback = { context, _, _, _, frames, data in
        guard let data else { return noErr }
        Unmanaged<RingbackRenderer>.fromOpaque(context).takeUnretainedValue()
            .render(UnsafeMutableAudioBufferListPointer(data), frames: Int(frames))
        return noErr
    }
    #else
    func renderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] _, _, frames, data in
            render(UnsafeMutableAudioBufferListPointer(data), frames: Int(frames))
            return noErr
        }
    }
    #endif
}

#if targetEnvironment(macCatalyst)
/// Plays the tone out of the speaker chosen for calls. AVAudioEngine can't
/// pick a device on the Mac, so this is a HAL output unit bound to one. It
/// holds nothing of the call audio's unit, which is made once the call is
/// answered and the tone is stopped.
@MainActor
final class RingbackPlayer {
    private static let sampleRate = 48_000.0
    /// `kAudioUnitSubType_HALOutput`, which the Catalyst SDK declares no name for.
    private static let halOutput: OSType = 0x6168_616C

    private var unit: AudioUnit?
    private var renderer: RingbackRenderer?

    func start() {
        guard unit == nil else { return }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: Self.halOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var created: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &created) == noErr, let unit = created else { return }
        let renderer = RingbackRenderer(sampleRate: Self.sampleRate)
        self.renderer = renderer
        self.unit = unit
        guard configure(unit, renderer), AudioOutputUnitStart(unit) == noErr else {
            ringbackLogger.error("Ringback tone could not start")
            stop()
            return
        }
    }

    private func configure(_ unit: AudioUnit, _ renderer: RingbackRenderer) -> Bool {
        var on: UInt32 = 1, off: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        // The unit is output only: the microphone stays shut.
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, size) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, size) == noErr,
              var device = CallOutput.deviceID(),
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &device, UInt32(MemoryLayout<UInt32>.size)) == noErr
        else { return false }
        // The unit converts this to the hardware's format.
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: RingbackRenderer.renderCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(renderer).toOpaque())
        return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr
    }

    /// Stopping waits for a callback in progress, so the renderer is free to go after it.
    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        renderer = nil
    }
}
#else
/// Plays the tone through the app's audio session, which must be active:
/// starting an engine on an inactive one would activate it, and with CallKit
/// that is CallKit's to do. It is stopped before the call's own audio starts.
@MainActor
final class RingbackPlayer {
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let renderer = RingbackRenderer(sampleRate: rate)
        let source = AVAudioSourceNode(format: format, renderBlock: renderer.renderBlock())
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            ringbackLogger.error("Ringback tone could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
#endif
