import Foundation
import UIKit
import UniformTypeIdentifiers
import YapnestKit

/// Copies what an `NSItemProvider` offers into a file the app or the share
/// extension can keep, since the provider's own file is deleted as soon as its
/// callback returns. The composer's paste and drop and the share sheet take
/// attachments through the same code, so they can't drift apart again.
enum ProviderCopy {
    /// The file is bigger than `maxSize`; nothing was copied.
    struct TooLarge: Error {
        let name: String
    }

    /// The provider offered a folder or a package, which can't be sent.
    struct IsFolder: Error {
        let name: String
    }

    /// Why a folder is turned away, as the share sheet words it.
    nonisolated static var foldersReason: String { String(localized: "Folders can't be sent") }

    /// The name to give the copy: the one the sender suggests, with the
    /// file's extension unless it already ends in it.
    nonisolated static func copyName(suggested: String?, file: URL) -> String {
        guard let suggested else { return file.lastPathComponent }
        let ext = file.pathExtension
        if ext.isEmpty || suggested.lowercased().hasSuffix("." + ext.lowercased()) { return suggested }
        return suggested + "." + ext
    }

    /// Copies the provider's file of `type` into a folder of its own under
    /// `folder`, named as the sender suggests when it does.
    nonisolated(nonsending) static func copy(from provider: NSItemProvider, type: UTType, under folder: URL, maxSize: Int64? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                let name = copyName(suggested: provider.suggestedName, file: url)
                if url.isDirectory {
                    continuation.resume(throwing: IsFolder(name: name))
                    return
                }
                if let maxSize, url.fileSize > maxSize {
                    continuation.resume(throwing: TooLarge(name: name))
                    return
                }
                do {
                    continuation.resume(returning: try FileManager.default.copyIntoUniqueFolder(url, named: name, under: folder))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Copies a pasted, dropped or shared item out of its provider. A picture
    /// that only exists as an object, with no file behind it, is written as a
    /// JPEG.
    nonisolated(nonsending) static func copyOut(_ provider: NSItemProvider, kind: AttachmentIntake.Kind, under folder: URL, maxSize: Int64? = nil) async throws -> URL {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let type: UTType?
        if kind == .image {
            type = types.first { $0.conforms(to: .image) }
        } else {
            type = types.first { $0 != .fileURL && $0 != .url && $0.conforms(to: .data) } ?? .item
        }
        if let type {
            do {
                return try await copy(from: provider, type: type, under: folder, maxSize: maxSize)
            } catch where kind != .image || error is TooLarge || error is IsFolder {
                throw error
            } catch {}
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                guard let image = image as? UIImage else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // The callback is already off the main thread.
                continuation.resume(with: Result { try writeJPEG(image, under: folder) })
            }
        }
    }

    /// Encodes a picture that only exists in memory and writes it in a new
    /// folder directly under `folder`. Blocking, so call it off the main thread.
    nonisolated static func writeJPEG(_ image: UIImage, under folder: URL) throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw CocoaError(.fileWriteUnknown) }
        return try writeIntoOwnFolder(data, named: "photo-\(UUID().uuidString.prefix(8)).jpg", under: folder)
    }

    /// Writes `data` as `name` in a new folder directly under `folder`.
    nonisolated static func writeIntoOwnFolder(_ data: Data, named name: String, under folder: URL) throws -> URL {
        let directory = folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: name)
        try data.write(to: file)
        return file
    }
}
