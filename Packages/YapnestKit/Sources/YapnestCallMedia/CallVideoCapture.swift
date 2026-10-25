import AVFoundation
import CoreVideo
import Foundation
import os
import YapnestKit
@preconcurrency import WebRTC

/// Where a call's outgoing video comes from, feeding one `RTCVideoSource`.
/// The camera when there is one, else a generated picture, so the call and
/// its tests also run where nothing can capture (the Simulator, a Mac test).
final class CallVideoCapture: @unchecked Sendable {
    private let source: RTCVideoSource
    private let useSynthetic: Bool
    // One queue for starting and stopping, so a quick off and on can't cross.
    private let queue = DispatchQueue(label: "app.yapnest.call-video-capture")
    private var camera: RTCCameraVideoCapturer?
    private var synthetic: SyntheticVideoCapturer?
    private var position = AVCaptureDevice.Position.front
    // Set once the user switches, and on the Mac from the chosen device at
    // every start. A Mac's cameras have no front or back, so the position
    // alone couldn't tell them apart.
    private var chosenID: String?
    private var choiceObserver: (any NSObjectProtocol)?
    // What the capture session reports while the camera runs.
    private var sessionObservers: [any NSObjectProtocol] = []
    // The capturer holds its delegate weakly.
    private lazy var framed = FirstFrameLogging(target: source)
    private lazy var upright = UprightFrames(target: framed)

    /// `synthetic` skips the camera even if there is one, so a test never
    /// prompts for it.
    init(source: RTCVideoSource, synthetic: Bool) {
        self.source = source
        useSynthetic = synthetic
        #if targetEnvironment(macCatalyst)
        // The Mac's camera is picked in Settings and on the call screen, also
        // while the call goes on.
        choiceObserver = NotificationCenter.default.addObserver(
            forName: CallDeviceChoices.didChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.cameraChoiceChanged() }
        }
        #endif
    }

    deinit {
        if let choiceObserver { NotificationCenter.default.removeObserver(choiceObserver) }
    }

    func start() {
        queue.async { [self] in startLocked() }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    /// Moves to the next camera, if one is capturing.
    func switchCamera() {
        queue.async { [self] in
            let devices = useSynthetic ? [] : RTCCameraVideoCapturer.captureDevices()
            let current = devices.firstIndex { $0.uniqueID == chosenID }
                ?? devices.firstIndex { $0.position == position } ?? 0
            DiagLog.info(.calls, "Call camera switch asked", .int("devices", devices.count), .bool("capturing", camera != nil))
            if !devices.isEmpty {
                let next = devices[(current + 1) % devices.count]
                chosenID = next.uniqueID
                position = next.position
            }
            guard camera != nil else { return }
            stopLocked()
            startLocked()
        }
    }

    private func cameraChoiceChanged() {
        guard let camera, let current = camera.captureSession.inputs.first as? AVCaptureDeviceInput else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        let wanted = CallDeviceResolution.camera(choice: CallDeviceChoices.shared.cameraID, available: devices.map(\.uniqueID))
        guard wanted != current.device.uniqueID else { return }
        DiagLog.info(.calls, "Call camera choice changed")
        stopLocked()
        startLocked()
    }

    private func startLocked() {
        let devices = useSynthetic ? [] : RTCCameraVideoCapturer.captureDevices()
        #if targetEnvironment(macCatalyst)
        chosenID = CallDeviceResolution.camera(choice: CallDeviceChoices.shared.cameraID, available: devices.map(\.uniqueID))
        #endif
        let candidates = devices.map { CameraCandidate(id: $0.uniqueID, position: $0.position) }
        guard let pick = Self.choose(from: candidates, chosenID: chosenID, position: position) else {
            startSynthetic(useSynthetic ? .syntheticRequested : .syntheticNoDevice, devices: devices.count)
            return
        }
        let device = devices[pick.index]
        guard camera == nil else { return }
        #if targetEnvironment(macCatalyst)
        let capturer = RTCCameraVideoCapturer(delegate: upright)
        #else
        let capturer = RTCCameraVideoCapturer(delegate: framed)
        #endif
        // A capturer without a format would never start, and the call would
        // send nothing, so a generated picture stands in as with no camera.
        guard let format = Self.format(of: device, preferring: capturer.preferredOutputPixelFormat()) else {
            startSynthetic(.syntheticNoFormat, devices: devices.count)
            return
        }
        camera = capturer
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = Self.frameRate(of: format)
        DiagLog.info(.calls, "Call camera starting",
            .int("devices", devices.count), .value("source", pick.source),
            .value("picture", PictureClass(height: Int(size.height))), .int("fps", fps))
        capturer.startCapture(with: device, format: format, fps: fps) { error in
            if let error {
                DiagLog.error(.calls, "Call camera failed to start", .error(error))
            } else {
                DiagLog.info(.calls, "Call camera capturing")
            }
        }
        observe(capturer.captureSession)
    }

    private func startSynthetic(_ source: CallCaptureSource, devices: Int) {
        guard synthetic == nil else { return }
        DiagLog.info(.calls, "Call camera starting", .int("devices", devices), .value("source", source))
        let capturer = SyntheticVideoCapturer(delegate: framed)
        synthetic = capturer
        capturer.start()
    }

    private func observe(_ session: AVCaptureSession) {
        removeObservers()
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
                if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                    DiagLog.error(.calls, "Call camera runtime error", .error(error))
                } else {
                    DiagLog.error(.calls, "Call camera runtime error")
                }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { note in
                #if os(iOS)
                let code = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                #else
                let code: Int? = nil
                _ = note
                #endif
                DiagLog.notice(.calls, "Call camera interrupted", .value("reason", CaptureInterruptionKind(code: code)))
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
                DiagLog.info(.calls, "Call camera interruption ended")
            },
        ]
    }

    private func removeObservers() {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers = []
    }

    /// Which camera is used: the one chosen, else the one at the position
    /// asked for, else the first. Nil when there is none.
    static func choose(from devices: [CameraCandidate], chosenID: String?, position: AVCaptureDevice.Position) -> (index: Int, source: CallCaptureSource)? {
        if let index = devices.firstIndex(where: { $0.id == chosenID }) { return (index, .chosenDevice) }
        if let index = devices.firstIndex(where: { $0.position == position }) { return (index, .positionMatch) }
        return devices.isEmpty ? nil : (0, .firstDevice)
    }

    private func stopLocked() {
        DiagLog.info(.calls, "Call camera stopping", .bool("camera", camera != nil), .bool("synthetic", synthetic != nil))
        removeObservers()
        camera?.stopCapture()
        camera = nil
        synthetic?.stop()
        synthetic = nil
    }

    static let targetWidth: Int32 = 1280
    static let targetHeight: Int32 = 720
    static let maxFrameRate = 30

    /// The format closest to 720p, in the pixel format the encoder takes
    /// without a conversion.
    static func format(of device: AVCaptureDevice, preferring pixelFormat: FourCharCode) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let distance = { (format: AVCaptureDevice.Format) -> Int32 in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return abs(size.width - targetWidth) + abs(size.height - targetHeight)
        }
        return formats
            .filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == pixelFormat }
            .min { distance($0) < distance($1) } ?? formats.min { distance($0) < distance($1) }
    }

    static func frameRate(of format: AVCaptureDevice.Format) -> Int {
        let best = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? Double(maxFrameRate)
        return max(1, min(maxFrameRate, Int(best)))
    }
}

struct CameraCandidate {
    let id: String
    let position: AVCaptureDevice.Position
}

/// Logs the first picture the camera (or the generated one) delivers, once per
/// call, then passes every frame on. Together with the remote side's log, it
/// tells a camera that gave nothing from one whose picture wasn't drawn.
final class FirstFrameLogging: NSObject, RTCVideoCapturerDelegate, @unchecked Sendable {
    private let target: any RTCVideoCapturerDelegate
    private let logged = OSAllocatedUnfairLock(initialState: false)

    init(target: any RTCVideoCapturerDelegate) {
        self.target = target
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        if logged.withLock({ let first = !$0; $0 = true; return first }) {
            DiagLog.info(.calls, "First local video frame", .value("picture", PictureClass(height: Int(frame.height))))
        }
        target.capturer(capturer, didCapture: frame)
    }
}

/// Passes frames on with no rotation. On Catalyst the camera capturer takes
/// its rotation from the device's orientation, which a Mac never reports, so
/// it stays at portrait and tagged the Mac camera's upright frames as turned
/// a quarter, for the preview and for the other side alike.
final class UprightFrames: NSObject, RTCVideoCapturerDelegate, @unchecked Sendable {
    private let target: any RTCVideoCapturerDelegate

    init(target: any RTCVideoCapturerDelegate) {
        self.target = target
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        target.capturer(capturer, didCapture: frame.rotation == ._0
            ? frame : RTCVideoFrame(buffer: frame.buffer, rotation: ._0, timeStampNs: frame.timeStampNs))
    }
}

/// A moving colour pattern at about 15 frames a second.
final class SyntheticVideoCapturer: RTCVideoCapturer, @unchecked Sendable {
    static let width = 320
    static let height = 240
    static let framesPerSecond = 15

    private let queue = DispatchQueue(label: "app.yapnest.call-synthetic-video")
    private var timer: DispatchSourceTimer?
    private var frameNumber = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Self.framesPerSecond))
            timer.setEventHandler { [self] in emitFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func emitFrame() {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(
            nil, Self.width, Self.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer) == kCVReturnSuccess,
            let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let shift = frameNumber * 4
        frameNumber += 1
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<Self.height {
                let line = luma.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<Self.width { line[column] = UInt8(truncatingIfNeeded: column + row / 2 + shift) }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for row in 0..<Self.height / 2 {
                let line = chroma.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<Self.width / 2 {
                    line[column * 2] = UInt8(truncatingIfNeeded: 128 + shift / 2 + row)
                    line[column * 2 + 1] = UInt8(truncatingIfNeeded: 128 - shift / 2 + column)
                }
            }
        }
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
            timeStampNs: Int64(bitPattern: DispatchTime.now().uptimeNanoseconds))
        delegate?.capturer(self, didCapture: frame)
    }
}
