import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What can safely be done with a received animated image. A GIF's frames are
/// drawn over each other, so ImageIO needs a bitmap of the whole canvas for
/// any frame, however small it's shown: an 8000 by 8000 GIF takes about
/// 256 MB per frame, which gets the app killed. So the canvas size, read
/// from the header, decides whether it is played, played from a smaller copy,
/// or not decoded at all.
public enum AnimatedImages {
    public enum Plan: Equatable, Sendable {
        /// Small enough to play as it is.
        case play
        /// Too big to play, but a smaller copy can be made, once.
        case downsample
        /// Not decoded at all, not even for a still.
        case tooLarge
    }

    /// Canvases up to this many pixels play as they are (4 MP, about 16 MB a frame).
    static let playPixels = 4_000_000
    /// Beyond this nothing is decoded (25 MP, about 100 MB a frame).
    public static let maxPixels = 25_000_000
    /// Making the smaller copy decodes every frame at full size, one after
    /// the other, and the encoder holds the finished frames until the end.
    /// Frames times megapixels bounds both: measured, a 25 MP GIF of 40
    /// frames takes about 2 s and 400 MB at the peak. Past the budget the
    /// copy isn't made and the still stands in.
    static let workBudget = 1000
    /// The long side of the smaller copy. Larger would cost memory for every
    /// frame the encoder holds (60 frames at 1024 took 1 GB, at 640 450 MB).
    public static let downsampledSide = 640

    public static func plan(width: Int, height: Int) -> Plan {
        let pixels = width * height
        if pixels <= playPixels { return .play }
        return pixels <= maxPixels ? .downsample : .tooLarge
    }

    /// Whether making the smaller copy is worth the work.
    public static func canDownsample(width: Int, height: Int, frames: Int) -> Bool {
        plan(width: width, height: height) == .downsample && frames * (width * height) / 1_000_000 <= workBudget
    }

    public struct Header: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var frames: Int
        public var isGIF: Bool

        public var plan: Plan { isGIF ? AnimatedImages.plan(width: width, height: height) : .play }
        public var canDownsample: Bool { AnimatedImages.canDownsample(width: width, height: height, frames: frames) }
    }

    // Not caching keeps decoded frames from piling up inside the source.
    private static var noCache: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// The canvas size and frame count, from the header alone.
    public static func header(of source: CGImageSource) -> Header? {
        guard let type = CGImageSourceGetType(source), let (width, height) = AttachmentStore.pixelSize(of: source) else { return nil }
        return Header(width: width, height: height, frames: CGImageSourceGetCount(source), isGIF: type as String == UTType.gif.identifier)
    }

    public static func header(of url: URL) -> Header? {
        if let header = CGImageSourceCreateWithURL(url as CFURL, noCache).flatMap(header(of:)) {
            return header
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return oversizeHeader(fromScreenDescriptor: (try? handle.read(upToCount: 10)) ?? Data())
    }

    public static func header(of data: Data) -> Header? {
        CGImageSourceCreateWithData(data as CFData, noCache).flatMap(header(of:))
            ?? oversizeHeader(fromScreenDescriptor: data.prefix(10))
    }

    /// ImageIO refuses a GIF that compresses extremely well, as it does a
    /// truncated one, so a huge canvas can come with no header at all. The
    /// logical screen descriptor still says how big it claims to be (bytes 6
    /// to 9, little endian), and that decides whether to leave it alone. Only
    /// an oversize answer is trusted: anything else stays unreadable.
    static func oversizeHeader(fromScreenDescriptor bytes: Data) -> Header? {
        let bytes = [UInt8](bytes)
        guard bytes.count >= 10, bytes.starts(with: Array("GIF8".utf8)) else { return nil }
        let width = Int(bytes[6]) | Int(bytes[7]) << 8, height = Int(bytes[8]) | Int(bytes[9]) << 8
        guard plan(width: width, height: height) == .tooLarge else { return nil }
        return Header(width: width, height: height, frames: 1, isGIF: true)
    }

    // MARK: Playing

    /// The delay a viewer waits after a frame. Browsers treat anything under
    /// 11 ms, which includes a missing or zero delay, as 100 ms, because
    /// GIFs made for old renderers often say 0 and expect that.
    public static func frameDelay(_ seconds: Double?) -> Duration {
        guard let seconds, seconds >= 0.011 else { return .milliseconds(100) }
        return .seconds(seconds)
    }

    /// Reads a GIF, APNG or animated WebP frame by frame. The system's own
    /// animator decodes on the main queue, so the app plays frames from
    /// here instead, on a task of its own.
    ///
    /// It wraps a `CGImageSource` that ImageIO doesn't promise to be safe
    /// across threads, and it carries decoding state from one frame to the
    /// next, so it must only be used by one task at a time.
    public final class Frames: @unchecked Sendable {
        private let source: CGImageSource
        public let count: Int

        private init?(source: CGImageSource?) {
            guard let source, CGImageSourceGetCount(source) > 0 else { return nil }
            self.source = source
            count = CGImageSourceGetCount(source)
        }

        public convenience init?(url: URL) {
            self.init(source: CGImageSourceCreateWithURL(url as CFURL, AnimatedImages.noCache))
        }

        public convenience init?(data: Data) {
            self.init(source: CGImageSourceCreateWithData(data as CFData, AnimatedImages.noCache))
        }

        public func delay(at index: Int) -> Duration {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            func seconds(_ container: CFString, _ unclamped: CFString, _ clamped: CFString) -> Double? {
                guard let values = properties?[container] as? [CFString: Any] else { return nil }
                return (values[unclamped] as? Double) ?? (values[clamped] as? Double)
            }
            let found = seconds(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
                ?? seconds(kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
                ?? seconds(kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
            return frameDelay(found)
        }

        /// The frame, drawn complete. ImageIO composites a GIF's frames onto
        /// the canvas as they're asked for in order, which is why this isn't
        /// a thumbnail request. A frame larger than `maxSide` is scaled down
        /// here, so the main thread uploads a bitmap of the size it shows.
        /// Decoding takes a few milliseconds: call it off the main thread.
        public func image(at index: Int, maxSide: Int) -> CGImage? {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            let longSide = max(frame.width, frame.height)
            guard maxSide > 0, longSide > maxSide else { return frame }
            let scale = Double(maxSide) / Double(longSide)
            let width = max(1, Int((Double(frame.width) * scale).rounded())), height = max(1, Int((Double(frame.height) * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { return frame }
            context.interpolationQuality = .high
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage() ?? frame
        }
    }

    // MARK: Smaller copies

    /// Where the smaller copy of the GIF at `source` is kept. In the caches
    /// directory, which the system empties when it needs room, and which a
    /// copy that is missing simply is made again in. `AttachmentStore.remove`
    /// deletes it with the attachment.
    public static func copyURL(for source: URL) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "AnimatedImages")
            .appending(path: source.lastPathComponent + ".gif")
    }

    public enum TranscodeError: Error {
        case unreadable
        case unwritable
    }

    /// Writes a copy of the GIF at `source` to `destination`, scaled to fit
    /// `side` pixels, with the same frames, delays and loop count. One frame
    /// is decoded at a time, and the destination is only replaced once whole.
    public static func downsample(_ source: URL, to destination: URL, side: Int = downsampledSide) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, noCache),
              CGImageSourceGetCount(input) > 0 else { throw TranscodeError.unreadable }
        let count = CGImageSourceGetCount(input)
        let fileProperties = CGImageSourceCopyProperties(input, nil) as? [CFString: Any]
        let loops = (fileProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        guard let output = CGImageDestinationCreateWithURL(partial as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw TranscodeError.unwritable
        }
        CGImageDestinationSetProperties(output, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops ?? 0],
        ] as CFDictionary)

        for index in 0..<count {
            try autoreleasepool {
                guard let frame = input.thumbnail(at: index, maxPixelSize: side, cacheImmediately: true) else { throw TranscodeError.unreadable }
                let properties = CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                var delays: [CFString: Any] = [:]
                if let delay = gif?[kCGImagePropertyGIFDelayTime] { delays[kCGImagePropertyGIFDelayTime] = delay }
                if let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] { delays[kCGImagePropertyGIFUnclampedDelayTime] = delay }
                CGImageDestinationAddImage(output, frame, [kCGImagePropertyGIFDictionary: delays] as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: partial)
            throw TranscodeError.unwritable
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
    }
}
