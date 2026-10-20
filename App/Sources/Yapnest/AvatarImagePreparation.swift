import PhotosUI
import SwiftUI
import UIKit

/// Gets a picked photo ready to publish as our avatar (XEP-0084).
enum AvatarImagePreparation {
    struct Prepared {
        var data: Data
        var mimeType: String
        /// The side of the square, in pixels.
        var side: Int
    }

    /// Avatars are shown small, and PEP items travel to every contact's
    /// devices, so aim far below `AvatarStore.maxSize`; servers also cap
    /// item sizes, and base64 adds a third.
    static let maxSide = 512
    static let maxBytes = 200 * 1024

    /// A centered square of at most `maxSide` pixels: PNG if the picture has
    /// transparency, which JPEG would lose, and JPEG otherwise.
    static func prepare(_ data: Data) -> Prepared? {
        guard let original = UIImage(data: data), let originalImage = original.cgImage else { return nil }
        // Read before redrawing: the redraw would give a photo an alpha
        // channel it never had, which would send it down the PNG path, where
        // a photograph is far too big.
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(originalImage.alphaInfo)
        guard let cgImage = original.normalized(opaque: !hasAlpha).cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        let crop = min(width, height)
        guard crop > 0,
              let square = cgImage.cropping(to: CGRect(x: (width - crop) / 2, y: (height - crop) / 2, width: crop, height: crop)) else { return nil }
        // A transparent picture can only be a PNG, which grows with detail,
        // so it is retried smaller before giving up.
        let sides = hasAlpha ? [maxSide, 384, 256] : [maxSide]
        for side in sides.map({ min(crop, $0) }) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = !hasAlpha
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            if hasAlpha {
                if let png = rendered.pngData(), png.count <= maxBytes {
                    return Prepared(data: png, mimeType: "image/png", side: side)
                }
                continue
            }
            for quality in stride(from: 0.85, through: 0.3, by: -0.1) {
                if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                    return Prepared(data: jpeg, mimeType: "image/jpeg", side: side)
                }
            }
        }
        return nil
    }
}

extension AvatarImagePreparation {
    struct UnreadableError: LocalizedError {
        var errorDescription: String? { String(localized: "That photo couldn't be used.") }
    }

    /// A picked photo, ready to publish. Throws `UnreadableError` if it can't be read.
    static func prepare(_ item: PhotosPickerItem) async throws -> Prepared {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw UnreadableError() }
        // Decoding and scaling a photo takes a while.
        guard let prepared = await Task.detached(operation: { prepare(data) }).value else { throw UnreadableError() }
        return prepared
    }
}

private extension UIImage {
    /// Redrawn upright, as photos carry their rotation as metadata that
    /// cropping the bitmap would ignore.
    func normalized(opaque: Bool) -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }
    }
}
