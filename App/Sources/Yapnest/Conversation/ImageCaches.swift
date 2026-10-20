import AVFoundation
import ImageIO
import UIKit
import YapnestKit

/// Reading a picture at the size it's shown instead of the size it was taken.
enum ImageDownsampler {
    /// Decoded here, on whatever thread asks, so the first draw on the main
    /// thread has nothing left to do. `maxPixels` is the longer side.
    nonisolated static func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
        // A GIF's canvas is decoded whole for any frame, however small it's
        // shown, so a huge one isn't read at all.
        if AnimatedImages.header(of: url)?.plan == .tooLarge { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// The picture's size in pixels, from its header.
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
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
            await videoFrame(url)
        } else {
            await Task.detached(priority: .userInitiated) { ImageDownsampler.downsample(url, maxPixels: maxPixelSize) }.value
        }
        if let image { cache.setImage(image, forKey: url) }
        return image
    }

    /// Not on the main actor: the generator is made and used in one place.
    private nonisolated static func videoFrame(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Videos that fade in start black, so the frame comes from a little
        // way in. The tolerance lets it land on a nearby keyframe, but not
        // back on the black start.
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration.isFinite, duration > 0 {
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            let time = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)
            if let frame = try? await generator.image(at: time).image { return UIImage(cgImage: frame) }
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
        }
        return try? await UIImage(cgImage: generator.image(at: .zero).image)
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
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // The picture fills its frame, so a tall one is cropped to the
            // width and it's the longer side that has to be larger.
            var side = width
            if let size = ImageDownsampler.pixelSize(of: url), size.width > 0 {
                side = min(width * max(1, size.height / size.width), max(size.width, size.height))
            }
            return ImageDownsampler.downsample(url, maxPixels: Int(side.rounded(.up)))
        }.value
        if let image { cache.setImage(image, forKey: url) }
        return image
    }
}
