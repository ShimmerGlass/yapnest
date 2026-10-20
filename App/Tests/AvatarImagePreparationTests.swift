import Testing
import UIKit
import YapnestKit
@testable import Yapnest

struct AvatarImagePreparationTests {
    /// Bytes a generator fills a bitmap with, cheap and repeatable.
    private struct Noise {
        var state: UInt32 = 12345
        mutating func next(below limit: UInt8) -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8((state >> 24) % UInt32(limit))
        }
    }

    /// A bitmap where `color(x, y)` is each pixel's base color, plus noise of `amount` levels.
    private func bitmap(width: Int, height: Int, alpha: Bool, noise amount: UInt8, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var noise = Noise()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = r &+ noise.next(below: amount)
                bytes[offset + 1] = g &+ noise.next(below: amount)
                bytes[offset + 2] = b &+ noise.next(below: amount)
                // One transparent corner pixel is enough to make it a PNG.
                bytes[offset + 3] = alpha && x == 0 && y == 0 ? 0 : 255
            }
        }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )!
    }

    private func pixel(of data: Data, atFractionX fx: CGFloat, y fy: CGFloat) throws -> (r: Int, b: Int) {
        let image = try #require(UIImage(data: data)?.cgImage)
        let x = Int(CGFloat(image.width - 1) * fx), y = Int(CGFloat(image.height - 1) * fy)
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(rgba[0]), Int(rgba[2]))
    }

    @Test func aRotatedCameraPhotoBecomesAnUprightJPEGWithinTheLimit() throws {
        // Stored 3000x4000 with its left half red and right half blue, and
        // turned a quarter clockwise on display: the top is red, the bottom blue.
        let stored = bitmap(width: 3000, height: 4000, alpha: false, noise: 24) { x, _ in x < 1500 ? (200, 0, 0) : (0, 0, 200) }
        let photo = UIImage(cgImage: stored, scale: 1, orientation: .right)
        let data = try #require(photo.jpegData(compressionQuality: 0.9))

        let prepared = try #require(AvatarImagePreparation.prepare(data))

        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.data.count <= AvatarImagePreparation.maxBytes)
        #expect(prepared.side == AvatarImagePreparation.maxSide)
        let top = try pixel(of: prepared.data, atFractionX: 0.5, y: 0.1)
        let bottom = try pixel(of: prepared.data, atFractionX: 0.5, y: 0.9)
        #expect(top.r > top.b + 100)
        #expect(bottom.b > bottom.r + 100)
    }

    @Test func aNoisyPictureWithTransparencyIsRetriedSmallerAsAPNGWithinTheLimit() throws {
        let source = bitmap(width: 1024, height: 1024, alpha: true, noise: 40) { x, y in (UInt8(x / 5), UInt8(y / 5), 90) }
        let data = try #require(UIImage(cgImage: source).pngData())

        let prepared = try #require(AvatarImagePreparation.prepare(data))

        #expect(prepared.mimeType == "image/png")
        #expect(prepared.data.count <= AvatarImagePreparation.maxBytes)
        #expect([384, 256].contains(prepared.side))
    }
}
