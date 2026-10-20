import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

enum GifFixtures {
    static let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]

    /// A GIF of solid red, green and blue frames, with distinct delays.
    static func write(width: Int, height: Int, to url: URL, loops: Int = 3) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        for (index, color) in colors.enumerated() {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let delay = 0.1 * Double(index + 1)
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
    }
}

struct AnimatedImagesTests {
    @Test func tiersChangeAtTheirBoundaries() {
        #expect(AnimatedImages.plan(width: 2000, height: 2000) == .play)
        #expect(AnimatedImages.plan(width: 2001, height: 2000) == .downsample)
        #expect(AnimatedImages.plan(width: 5000, height: 5000) == .downsample)
        #expect(AnimatedImages.plan(width: 5001, height: 5000) == .tooLarge)
        #expect(AnimatedImages.plan(width: 8000, height: 8000) == .tooLarge)
    }

    @Test func theWorkBudgetRefusesLongGifs() {
        // 5 MP a frame: 200 frames fit, 201 don't.
        #expect(AnimatedImages.canDownsample(width: 2500, height: 2000, frames: 200))
        #expect(!AnimatedImages.canDownsample(width: 2500, height: 2000, frames: 201))
        #expect(!AnimatedImages.canDownsample(width: 2000, height: 2000, frames: 1))
        #expect(!AnimatedImages.canDownsample(width: 6000, height: 6000, frames: 1))
    }

    @Test func headerIsReadWithoutDecoding() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try GifFixtures.write(width: 40, height: 30, to: url)
        let header = try #require(AnimatedImages.header(of: url))
        #expect(header == AnimatedImages.Header(width: 40, height: 30, frames: 3, isGIF: true))
        #expect(header.plan == .play)
        #expect(AnimatedImages.header(of: Data("nope".utf8)) == nil)
        // A big picture that isn't a GIF is left to ImageIO's own subsampling.
        let png = try AvatarImages.png(side: 8)
        #expect(AnimatedImages.header(of: png)?.isGIF == false)
    }

    @Test func aSmallerCopyKeepsFramesDelaysAndLoops() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "in.gif"), copy = directory.appending(path: "out/copy.gif")
        try GifFixtures.write(width: 400, height: 300, to: source)

        try AnimatedImages.downsample(source, to: copy, side: 100)

        let image = try #require(CGImageSourceCreateWithURL(copy as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == 3)
        let loops = ((CGImageSourceCopyProperties(image, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(loops == 3)
        for index in 0..<3 {
            let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any]
            let delay = (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double
            #expect(abs((delay ?? 0) - 0.1 * Double(index + 1)) < 0.001)
            #expect(max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 999, properties?[kCGImagePropertyPixelHeight] as? Int ?? 999) <= 100)

            // Each frame is the whole picture, in its own color.
            let frame = try #require(CGImageSourceCreateImageAtIndex(image, index, nil))
            let pixel = Array((try #require(frame.dataProvider?.data) as Data).prefix(3))
            let expected = GifFixtures.colors[index]
            #expect(abs(Int(pixel[0]) - Int(expected.0 * 255)) < 40)
            #expect(abs(Int(pixel[1]) - Int(expected.1 * 255)) < 40)
            #expect(abs(Int(pixel[2]) - Int(expected.2 * 255)) < 40)
        }
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathExtension("partial").path))
    }

    @Test func somethingUnreadableFailsWithoutLeavingAFile() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(throws: AnimatedImages.TranscodeError.self) {
            try AnimatedImages.downsample(directory.appending(path: "missing.gif"), to: directory.appending(path: "o.gif"))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "o.gif").path))
    }

    @Test func theBrowserRuleSetsTooShortDelaysToAHundredMilliseconds() {
        #expect(AnimatedImages.frameDelay(nil) == .milliseconds(100))
        #expect(AnimatedImages.frameDelay(0) == .milliseconds(100))
        #expect(AnimatedImages.frameDelay(0.005) == .milliseconds(100))
        #expect(AnimatedImages.frameDelay(0.04) == .milliseconds(40))
        #expect(AnimatedImages.frameDelay(1.5) == .milliseconds(1500))
    }

    /// A GIF of `frames` noisy frames, each tinted differently. The noise is
    /// there because ImageIO rejects a GIF that compresses too well.
    private func animation(frames: Int, width: Int = 200, height: Int = 100, delay: Double = 0.2) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            let color = GifFixtures.colors[frame % GifFixtures.colors.count]
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
                // Only the top rows, so the middle keeps the frame's color.
                for index in stride(from: 0, to: width * 10 * 4, by: 4) {
                    pixels[index] = UInt8(truncatingIfNeeded: (index &+ frame) &* 2_654_435_761 >> 13)
                }
            }
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func middlePixel(of image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel
    }

    @Test func framesAreReadWithTheirDelaysAndSizes() throws {
        let frames = try #require(AnimatedImages.Frames(data: animation(frames: 3)))
        #expect(frames.count == 3)
        #expect(frames.delay(at: 1) == .milliseconds(200))
        let full = try #require(frames.image(at: 2, maxSide: 0))
        #expect(full.width == 200 && full.height == 100)
        let small = try #require(frames.image(at: 2, maxSide: 50))
        #expect(small.width == 50 && small.height == 25)
        // Frame 2 is blue.
        #expect(try middlePixel(of: full) == [0, 0, 255, 255])
        #expect(try middlePixel(of: small) == [0, 0, 255, 255])
    }

    @Test func nothingReadableGivesNoFrames() {
        #expect(AnimatedImages.Frames(data: Data("nope".utf8)) == nil)
        #expect(AnimatedImages.Frames(url: URL(filePath: "/nonexistent.gif")) == nil)
    }
}
