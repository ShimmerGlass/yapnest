import AVFoundation
import Foundation

/// Re-encodes a video smaller, for a server whose upload limit it is over.
public enum VideoShrink {
    public enum Failure: Error, LocalizedError, Equatable {
        /// Even the smallest preset is over the limit.
        case stillTooLarge
        /// AVFoundation can't re-encode this file.
        case cantBeConverted
        /// The disk is full, which isn't the video's fault.
        case noSpace

        public var errorDescription: String? {
            switch self {
            case .stillTooLarge: String(localized: "This video is too large for your server even when made smaller.")
            case .cantBeConverted: String(localized: "This video can't be made smaller.")
            case .noSpace: String(localized: "There isn't enough free space on this device to make the video smaller.")
            }
        }
    }

    /// From the best quality down. Each step is a smaller picture, so a
    /// video is only made as small as it has to be.
    static let defaultPresets = [AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPreset960x540]

    /// The part of the limit left free (2%): the video is written once more
    /// when it is sent, to take its metadata out, and that copy isn't the
    /// same size to the byte.
    static let headroomDivisor: Int64 = 50

    /// Re-encodes the video at `source` into `folder` as an MP4 named after it,
    /// the best quality of the presets that is at most `limit` bytes. The
    /// length of the video is kept whole: no length limit is given to the
    /// export, which could end it early, so the size is checked once it is
    /// written. `progress` is 0...1 for the preset being tried, and starts
    /// over when the next one is. Nothing is left in `folder` unless it is
    /// the result. A cancelled task throws `CancellationError`.
    public static func shrink(_ source: URL, into folder: URL, toFit limit: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await shrink(source, into: folder, toFit: limit, presets: defaultPresets, progress: progress)
    }

    static func shrink(
        _ source: URL, into folder: URL, toFit limit: Int64, presets: [String], progress: @escaping @Sendable (Double) -> Void,
    ) async throws -> URL {
        let started = Date()
        let sourceSize = Int(source.fileSize)
        let destination = folder.appending(path: source.deletingPathExtension().lastPathComponent).appendingPathExtension("mp4")
        var outcome = VideoShrinkResult.cantBeConverted
        var resultSize = 0
        defer {
            DiagLog.info(
                .upload, "Video shrink ended", .value("result", outcome), .size("source", sourceSize), .size("result", resultSize),
                .duration("took", since: started),
            )
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let asset = AVURLAsset(url: source)
            for (index, preset) in presets.enumerated() {
                try Task.checkCancellation()
                guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4),
                      let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
                // The estimate is the preset's, so a simple video comes out under it: it only
                // spares a try that clearly won't fit, and never the last.
                let isLast = index == presets.count - 1
                if !isLast, let estimate = try? await session.estimatedOutputFileLength, estimate > 0, estimate > limit {
                    outcome = .stillTooLarge
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                session.metadataItemFilter = .forSharing()
                session.shouldOptimizeForNetworkUse = true
                try await export(session, to: destination, progress: progress)
                // Not `fileSize`: the same URL names each attempt, and a URL keeps the size it was first asked for.
                guard let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 else {
                    throw Failure.cantBeConverted
                }
                if size <= limit - limit / Self.headroomDivisor {
                    outcome = result(for: preset)
                    resultSize = Int(size)
                    return destination
                }
                try? FileManager.default.removeItem(at: destination)
                outcome = .stillTooLarge
            }
            // Still its first value if no preset could be run at all.
            throw outcome == .stillTooLarge ? Failure.stillTooLarge : Failure.cantBeConverted
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled || error is CancellationError {
                outcome = .cancelled
                throw CancellationError()
            }
            if error is Failure { throw error }
            outcome = .cantBeConverted
            if AttachmentStore.isOutOfSpace(error) { throw Failure.noSpace }
            throw Failure.cantBeConverted
        }
    }

    private static func export(_ session: AVAssetExportSession, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // The session is used from the monitor and the cancel handler, which its own API is made for.
        nonisolated(unsafe) let session = session
        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case let .exporting(current) = state { progress(current.fractionCompleted) }
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await session.export(to: destination, as: .mp4)
            } onCancel: {
                session.cancelExport()
            }
        } catch {
            monitor.cancel()
            throw error
        }
        await monitor.value
        progress(1)
    }

    private static func result(for preset: String) -> VideoShrinkResult {
        switch preset {
        case AVAssetExportPreset1920x1080: .fit1080
        case AVAssetExportPreset1280x720: .fit720
        case AVAssetExportPreset960x540: .fit540
        default: .fitOther
        }
    }
}
