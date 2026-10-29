import AVFoundation
import ImageIO
import UIKit
import YapnestKit

/// Reading a picture at the size it's shown instead of the size it was taken.
enum ImageDownsampler {
    /// Decoded here, on whatever thread asks, so the first draw on the main
    /// thread has nothing left to do. `maxPixels` is the longer side.
    nonisolated static func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
        downsample(url) { _ in maxPixels }
    }

    /// For a size that depends on the picture's own: `maxPixels` is given its
    /// header, so the file is opened once for both.
    nonisolated static func downsample(_ url: URL, maxPixels: (AnimatedImages.Header?) -> Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let header = AnimatedImages.header(of: source) ?? AnimatedImages.header(of: url)
        // A GIF's canvas is decoded whole for any frame, however small it's
        // shown, so a huge one isn't read at all.
        if header?.plan == .tooLarge { return nil }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels(header),
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// A still from a video, a little way in because videos that fade in
    /// start black. The tolerances, in seconds, let the frame land on a nearby
    /// keyframe; a frame that can't be had within them falls back to the very
    /// first, wherever it is. Not on the main actor: the generator is made and
    /// used in one place.
    nonisolated static func videoFrame(of url: URL, maxSize: CGFloat, toleranceBefore: Double, toleranceAfter: Double) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration.isFinite, duration > 0 {
            generator.requestedTimeToleranceBefore = CMTime(seconds: toleranceBefore, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: toleranceAfter, preferredTimescale: 600)
            let time = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)
            if let frame = try? await generator.image(at: time).image { return UIImage(cgImage: frame) }
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
        }
        return try? await UIImage(cgImage: generator.image(at: .zero).image)
    }
}

private extension NSCache where KeyType == NSURL, ObjectType == UIImage {
    /// Costs are in pixels, so the limit follows what the pictures take
    /// rather than how many there are.
    func setImage(_ image: UIImage, forKey url: URL) {
        let pixels = image.cgImage.map { $0.width * $0.height } ?? Int(image.size.width * image.size.height)
        setObject(image, forKey: url as NSURL, cost: pixels)
    }
}

/// Downscaled pictures for bubbles: photos can be 12 megapixels.
@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        // About 100 MB of decoded pictures.
        cache.totalCostLimit = 24_000_000
        return cache
    }()
    nonisolated static let maxPixelSize = 1200

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func load(_ url: URL, video: Bool) async -> UIImage? {
        let image: UIImage? = if video {
            await ImageDownsampler.videoFrame(of: url, maxSize: CGFloat(maxPixelSize), toleranceBefore: 0.25, toleranceAfter: 1)
        } else {
            await decodeOffMain { ImageDownsampler.downsample(url, maxPixels: maxPixelSize) }
        }
        if let image { cache.setImage(image, forKey: url) }
        return image
    }
}

/// Link preview pictures, decoded ahead of drawing.
@MainActor
enum PreviewImageCache {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        // About 64 MB of decoded pictures.
        cache.totalCostLimit = 16_000_000
        return cache
    }()

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Read at the width a bubble can show, in the display's pixels.
    static func load(_ url: URL, scale: CGFloat) async -> UIImage? {
        let width = MediaLimits.maxBubbleWidth * scale
        let image = await decodeOffMain { () -> UIImage? in
            ImageDownsampler.downsample(url) { header in
                // The picture fills its frame, so a tall one is cropped to the
                // width and it's the longer side that has to be larger.
                var side = width
                if let header {
                    let (w, h) = (CGFloat(header.width), CGFloat(header.height))
                    side = min(width * max(1, h / w), max(w, h))
                }
                return Int(side.rounded(.up))
            }
        }
        if let image { cache.setImage(image, forKey: url) }
        return image
    }
}
