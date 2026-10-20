import AVFoundation
import Foundation
import Testing
@testable import YapnestKit

/// The size a downloaded file is shown at, which the chat reserves room for
/// before the file is opened.
struct DisplaySizeTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "display-size-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A video recorded 64x32 and turned a quarter, which is how phones store portrait.
    private func portraitVideo() async throws -> URL {
        let url = directory.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @Test func aDownloadedPortraitVideoIsMeasuredAfterItsRotation() async throws {
        let file = try await portraitVideo()
        let size = await AttachmentStore.displaySize(of: try Data(contentsOf: file), savedAs: file, name: "clip.mov")

        #expect(size?.width == 32)
        #expect(size?.height == 64)
    }

    @Test func aPdfHasNoDisplaySize() async throws {
        let file = directory.appending(path: "doc.pdf")
        let data = Data("%PDF-1.4 not really".utf8)
        try data.write(to: file)

        let size = await AttachmentStore.displaySize(of: data, savedAs: file, name: "doc.pdf")
        #expect(size == nil)
    }

    @Test func aFileNamedLikeAVideoThatIsNotOneHasNoDisplaySize() async throws {
        let file = directory.appending(path: "broken.mp4")
        let data = Data("not a video".utf8)
        try data.write(to: file)

        let size = await AttachmentStore.displaySize(of: data, savedAs: file, name: "broken.mp4")
        #expect(size == nil)
    }
}
