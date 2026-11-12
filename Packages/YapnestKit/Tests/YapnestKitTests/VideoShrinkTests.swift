import AVFoundation
import Foundation
import os
import Testing
@testable import YapnestKit

struct VideoShrinkTests {
    private static let width = 1920
    private static let height = 1080
    private static let frames = 10

    /// A scratch folder with a noisy 1080p clip of a second in it, and an empty folder for the results.
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "shrink-\(UUID().uuidString)")
        var source: URL { root.appending(path: "clip.mov") }
        var output: URL { root.appending(path: "out") }

        func contents() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).sorted()
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// Noise doesn't compress, so the video is large and a smaller picture is clearly smaller.
    private func makeFixture(location: String? = nil) async throws -> Fixture {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: fixture.source, fileType: .mov)
        if let location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = location as NSString
            writer.metadata = [item]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Self.width, AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for frame in 0..<Self.frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt64.self)
            for index in 0..<(CVPixelBufferGetBytesPerRow(pixels) * Self.height / 8) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                base[index] = state
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return fixture
    }

    private func dimensions(_ url: URL) async throws -> CGSize {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try await track.load(.naturalSize)
    }

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func size(of preset: String, _ fixture: Fixture) async throws -> Int64 {
        let result = try await VideoShrink.shrink(
            fixture.source, into: fixture.output.appending(path: preset), toFit: .max, presets: [preset], progress: { _ in },
        )
        return result.fileSize
    }

    @Test func aVideoOverTheLimitComesOutUnderItAsAnMP4OfTheSameLength() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let full = fixture.source.fileSize
        let limit = full / 2
        let result = try await VideoShrink.shrink(fixture.source, into: fixture.output, toFit: limit, progress: { _ in })
        #expect(result.fileSize <= limit)
        #expect(result.lastPathComponent == "clip.mp4")
        #expect(result.deletingLastPathComponent().standardizedFileURL == fixture.output.standardizedFileURL)
        #expect(fixture.contents() == ["clip.mp4"])
        #expect(try await AVURLAsset(url: result).load(.isPlayable))
        let header = try Data(contentsOf: result).prefix(12)
        #expect(String(decoding: header.dropFirst(4), as: UTF8.self).hasPrefix("ftyp"))
        let expected = try await duration(fixture.source)
        #expect(abs(try await duration(result) - expected) < 0.15)
    }

    @Test func aLimitTheBestPresetMissesStepsDownToASmallerPicture() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let big = try await size(of: AVAssetExportPreset1920x1080, fixture)
        let small = try await size(of: AVAssetExportPreset960x540, fixture)
        try #require(small < big)
        try FileManager.default.removeItem(at: fixture.output)
        let limit = (big + small) / 2
        let result = try await VideoShrink.shrink(
            fixture.source, into: fixture.output, toFit: limit,
            presets: [AVAssetExportPreset1920x1080, AVAssetExportPreset960x540], progress: { _ in },
        )
        #expect(result.fileSize <= limit)
        #expect(try await dimensions(result).width < 1000)
        #expect(fixture.contents() == ["clip.mp4"])
    }

    @Test func aLimitNothingCanMeetIsRefusedAndLeavesNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        await #expect(throws: VideoShrink.Failure.stillTooLarge) {
            _ = try await VideoShrink.shrink(fixture.source, into: fixture.output, toFit: 100, progress: { _ in })
        }
        #expect(fixture.contents().isEmpty)
    }

    @Test func aFileThatIsNotAVideoCantBeConverted() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("not a video".utf8).write(to: fixture.source)
        await #expect(throws: VideoShrink.Failure.cantBeConverted) {
            _ = try await VideoShrink.shrink(fixture.source, into: fixture.output, toFit: 1_000_000, progress: { _ in })
        }
        #expect(fixture.contents().isEmpty)
    }

    @Test func aCancelledShrinkIsACancellationAndLeavesNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let task = Task { try await VideoShrink.shrink(fixture.source, into: fixture.output, toFit: .max, progress: { _ in }) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.contents().isEmpty)
    }

    @Test func theLocationIsNotKept() async throws {
        let fixture = try await makeFixture(location: "+48.8584+002.2945/")
        defer { fixture.cleanUp() }
        let before = try await AVURLAsset(url: fixture.source).load(.metadata)
        try #require(before.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
        let result = try await VideoShrink.shrink(fixture.source, into: fixture.output, toFit: .max, progress: { _ in })
        let after = try await AVURLAsset(url: result).load(.metadata)
        #expect(!after.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
    }

    @Test func progressIsReportedAndEndsAtOne() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let seen = OSAllocatedUnfairLock<[Double]>(initialState: [])
        _ = try await VideoShrink.shrink(fixture.source, into: fixture.output, toFit: .max, progress: { value in seen.withLock { $0.append(value) } })
        let values = seen.withLock { $0 }
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
    }
}
