import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

enum AvatarImages {
    /// A real, solid-colour PNG.
    static func png(side: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A PNG that claims to be `side` pixels square: only the header is real,
    /// which is all a size check should need to read.
    static func pngClaiming(side: Int) -> Data {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let tagged = Array(type.utf8) + body
            var crc: UInt32 = 0xffff_ffff
            for byte in tagged {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
            }
            func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32($0))) } }
            return be(UInt32(body.count)) + tagged + be(~crc)
        }
        func be(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
        let header = be(side) + be(side) + [8, 2, 0, 0, 0]
        return Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + chunk("IHDR", header) + chunk("IEND", []))
    }
}

struct AvatarSizeTests {
    @Test func aNormalAvatarIsStored() throws {
        let store = AvatarStore.temporary()
        let data = try AvatarImages.png(side: 96)
        #expect(store.save(data, hash: AvatarStore.hash(of: data)))
        try FileManager.default.removeItem(at: store.directory)
    }

    @Test func anImageWithHugeDimensionsIsRefused() {
        let store = AvatarStore.temporary()
        let data = AvatarImages.pngClaiming(side: 15000)
        #expect(data.count < 1024)
        #expect(!store.save(data, hash: AvatarStore.hash(of: data)))
        #expect(!store.contains(AvatarStore.hash(of: data)))
    }

    @Test func somethingThatIsNotAnImageIsRefused() {
        let store = AvatarStore.temporary()
        let data = Data("avatar".utf8)
        #expect(!store.save(data, hash: AvatarStore.hash(of: data)))
    }

    @Test func thumbnailsFitTheRequestedSize() throws {
        let data = try AvatarImages.png(side: 600)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(AvatarStore.thumbnail(of: source, pixels: 100))
        #expect(max(image.width, image.height) <= 100)
    }

    @Test func storedOversizedFilesAreNotDecoded() throws {
        let data = AvatarImages.pngClaiming(side: 15000)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(AvatarStore.thumbnail(of: source, pixels: 100) == nil)
    }
}
