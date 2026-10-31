import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
import YapnestKit

@testable import Yapnest

/// The copy the composer's paste and drop and the share sheet both make of
/// what a provider offers. The share extension had its own, which lost the
/// suggested name and ignored a picture given only as an image object; none of
/// these could pass for it, as it couldn't be reached from a test.
struct ProviderCopyTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func square() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    @Test func aSuggestedNameIsKept() async throws {
        let provider = try #require(NSItemProvider(contentsOf: try makeTemporaryFile("tmp-1234.txt")))
        provider.suggestedName = "Quarterly report"
        let copy = try await ProviderCopy.copyOut(provider, kind: AttachmentIntake.kind(of: provider), under: try folder())
        #expect(copy.lastPathComponent == "Quarterly report.txt")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "contents of tmp-1234.txt")
    }

    @Test func aPictureGivenAsAnImageObjectIsTaken() async throws {
        let provider = NSItemProvider(object: square())
        let kind = AttachmentIntake.kind(of: provider)
        #expect(kind == .image)
        let copy = try await ProviderCopy.copyOut(provider, kind: kind, under: try folder())
        #expect(UIImage(contentsOfFile: copy.path) != nil)
    }

    @Test func aPictureWithNoFileBehindItIsWrittenAsAJpeg() async throws {
        let image = square()
        let provider = NSItemProvider()
        provider.registerObject(ofClass: UIImage.self, visibility: .all) { completion in
            completion(image, nil)
            return nil
        }
        let copy = try await ProviderCopy.copyOut(provider, kind: .image, under: try folder())
        #expect(UIImage(contentsOfFile: copy.path) != nil)
    }

    @Test func aFileOverTheLimitIsRefusedWithItsName() async throws {
        let provider = try #require(NSItemProvider(contentsOf: try makeTemporaryFile("big.txt")))
        let destination = try folder()
        await #expect(throws: ProviderCopy.TooLarge.self) {
            try await ProviderCopy.copyOut(provider, kind: .file, under: destination, maxSize: 1)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func aPictureFileIsAnImageAndATextFileIsAFile() throws {
        let picture = try #require(NSItemProvider(contentsOf: try makeTemporaryFile("shot.png")))
        let text = try #require(NSItemProvider(contentsOf: try makeTemporaryFile("notes.txt")))
        #expect(AttachmentIntake.kind(of: picture) == .image)
        #expect(AttachmentIntake.kind(of: text) == .file)
    }
}
