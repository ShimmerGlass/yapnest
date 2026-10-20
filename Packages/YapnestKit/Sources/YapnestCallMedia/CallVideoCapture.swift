import AVFoundation
import CoreVideo
import Foundation
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
    // Set once the user switches. A Mac's cameras have no front or back, so
    // the position alone couldn't tell them apart.
    private var chosenID: String?
    private var choiceObserver: (any NSObjectProtocol)?

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
        stopLocked()
        startLocked()
    }

    private func startLocked() {
        let devices = useSynthetic ? [] : RTCCameraVideoCapturer.captureDevices()
        #if targetEnvironment(macCatalyst)
        chosenID = CallDeviceResolution.camera(choice: CallDeviceChoices.shared.cameraID, available: devices.map(\.uniqueID))
        #endif
        guard let device = devices.first(where: { $0.uniqueID == chosenID })
            ?? devices.first(where: { $0.position == position }) ?? devices.first else {
            if synthetic == nil {
                let capturer = SyntheticVideoCapturer(delegate: source)
                synthetic = capturer
                capturer.start()
            }
            return
        }
        guard camera == nil else { return }
        let capturer = RTCCameraVideoCapturer(delegate: source)
        camera = capturer
        guard let format = Self.format(of: device, preferring: capturer.preferredOutputPixelFormat()) else { return }
        capturer.startCapture(with: device, format: format, fps: Self.frameRate(of: format))
    }

    private func stopLocked() {
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
