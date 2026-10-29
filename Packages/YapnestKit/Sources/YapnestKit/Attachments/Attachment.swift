import Foundation
import GRDB
import os
import UniformTypeIdentifiers

/// A file sent with a message (XEP-0363 upload, XEP-0454 if encrypted).
/// One per message, as XMPP clients send them.
public struct Attachment: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        /// Ours, stored locally, not uploaded yet.
        case pendingUpload
        /// Someone else's (or another device's), not downloaded.
        case remote
        case downloadFailed
        /// The file is on this device.
        case ready
        /// A contact's Jingle file offer (XEP-0234) that hasn't arrived: waiting
        /// to be accepted, or coming in. It has no URL to fetch.
        case offered
        /// An offer that ended without the file: declined, cancelled, failed,
        /// timed out, or left over from an earlier launch, as a transfer can't
        /// outlive the session that made it. Nothing is left to retry.
        case unavailable
    }

    public var messageId: Int64
    /// What the message carries: `https://` or, encrypted, `aesgcm://` with
    /// the key in the fragment. Nil until our upload finishes.
    public var url: String?
    public var name: String
    public var mimeType: String?
    public var size: Int64?
    public var width: Double?
    public var height: Double?
    /// How long a sound plays, in seconds: what the sender announced, or
    /// what we measured of our own recording.
    public var duration: TimeInterval?
    /// A tiny PNG the sender announced (see `FileMetadata`), drawn blurred until
    /// the file is downloaded. Dropped once it is.
    public var thumbnail: Data?
    /// File name in the attachment store, once the file is on this device.
    public var localFile: String?
    public var state: State

    public init(
        messageId: Int64,
        url: String?,
        name: String,
        mimeType: String? = nil,
        size: Int64? = nil,
        width: Double? = nil,
        height: Double? = nil,
        duration: TimeInterval? = nil,
        thumbnail: Data? = nil,
        localFile: String? = nil,
        state: State,
    ) {
        self.messageId = messageId
        self.url = url
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.thumbnail = thumbnail
        self.localFile = localFile
        self.state = state
    }

    public static let databaseTableName = "attachment"

    /// What the file is, from its name's extension. A type the sender gave
    /// (a Jingle `media-type`, a server's `Content-Type`) never decides it:
    /// "image/png" on `photo.terminal` would make a picture of a script, and
    /// on the Mac a click on it would launch the app that owns `.terminal`.
    /// The media type is only used when the name has no extension.
    public var type: UTType? {
        UTTypeLookup.type(mimeType: mimeType, filenameExtension: (name as NSString).pathExtension)
    }

    public var isImage: Bool { type?.conforms(to: .image) ?? false }
    public var isVideo: Bool { type?.conforms(to: .movie) ?? false }
    public var isAudio: Bool { AudioFormat.isAudio(mimeType: mimeType, name: name) }

    /// Whether the bubble plays it itself. AVAudioPlayer has no Ogg or Opus
    /// decoder, and shipping one for those senders isn't worth it: they are
    /// shown as any other file.
    public var playsInline: Bool { isAudio && AudioFormat.isPlayable(mimeType: mimeType, name: name) }

    /// A voice message, as opposed to music or some other sound; see `AudioFormat.isVoiceClip`.
    public var isVoiceClip: Bool { AudioFormat.isVoiceClip(mimeType: mimeType, name: name) }

    public var isContact: Bool { type?.conforms(to: .vCard) ?? false }

    /// A contact's name, which is its file name without the extension.
    public var contactName: String { (name as NSString).deletingPathExtension }

    public var imageSize: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Takes what the sender announced about the file. The size is useful for
    /// any file; the shape and thumbnail only for a picture or video, whose
    /// bubble then has its final size before anything is downloaded. Our own
    /// idea of the type, from the link, decides what the file is: a claim that
    /// it is an image changes neither the bubble nor whether it downloads itself.
    mutating func apply(_ metadata: FileMetadata) {
        size = metadata.size ?? size
        if isAudio, let length = metadata.length { duration = length }
        guard metadata.describesMedia, isImage || isVideo else { return }
        if let width = metadata.width, let height = metadata.height {
            self.width = Double(width)
            self.height = Double(height)
        }
        thumbnail = metadata.thumbnail
    }

    /// For the chat list and notifications.
    public var summary: String {
        if isImage { return String(localized: "📷 Photo") }
        if isVideo { return String(localized: "🎬 Video") }
        if isAudio { return isVoiceClip ? String(localized: "🎤 Voice message") : "🎵 " + name }
        if isContact { return "👤 " + contactName }
        return "📎 " + name
    }

    /// What a quote of a file message shows, in place of the file's URL: the
    /// `aesgcm://` link carries the decryption key, so it must never be shown
    /// or sent on as quoted text. A shared location quotes as "Location". `attachment` is the stored record if there
    /// is one; without it, a body that is only a file link still counts.
    /// Returns nil for ordinary text.
    public static func quoteSummary(text: String, attachment: Attachment?) -> String? {
        if let attachment { return attachment.summary }
        if GeoLocation(body: text) != nil { return GeoLocation.summary }
        guard let (url, name) = AttachmentLink.parse(body: text, oob: text) else { return nil }
        // Any https URL passes `parse` here, so only trust ones that name a
        // file of a known type; a bare link to a web page is ordinary text.
        // An extension nothing declares, like the "5" of "release-1.5", still
        // gets a dynamic type, which says nothing.
        if url.scheme?.lowercased() != "aesgcm", UTTypeLookup.type(forName: name)?.isDynamic != false { return nil }
        return Attachment(messageId: 0, url: url.absoluteString, name: name, state: .remote).summary
    }
}

/// Resolving a type is an XPC call to LaunchServices, and a row's body reads
/// `Attachment.type` several times per evaluation, so answers are kept for the
/// life of the process. Misses are kept too. Names come from other people's
/// messages, so the cache starts over once it holds `limit` of them.
enum UTTypeLookup {
    private struct Key: Hashable {
        var mimeType: String?
        var filenameExtension: String
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: UTType?]())
    static let limit = 512

    static func type(mimeType: String?, filenameExtension: String) -> UTType? {
        let key = Key(mimeType: mimeType, filenameExtension: filenameExtension)
        if let known = cache.withLock({ $0[key] }) { return known }
        let resolved = filenameExtension.isEmpty ? mimeType.flatMap { UTType(mimeType: $0) } : UTType(filenameExtension: filenameExtension)
        cache.withLock {
            if $0.count >= limit { $0.removeAll(keepingCapacity: true) }
            $0[key] = .some(resolved)
        }
        return resolved
    }

    /// What a file name's extension says it is, ignoring any media type.
    static func type(forName name: String) -> UTType? {
        type(mimeType: nil, filenameExtension: (name as NSString).pathExtension)
    }
}
