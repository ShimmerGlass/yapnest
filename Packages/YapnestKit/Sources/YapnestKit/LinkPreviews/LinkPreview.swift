import Foundation
import GRDB

/// What a link points to, fetched once and kept for every message that has it.
public struct LinkPreview: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        /// A web page, described by its OpenGraph tags.
        case page
        /// The link is an image itself.
        case image
        /// Nothing to show (not HTML or an image, no metadata, or an error page).
        case none
    }

    public var url: String
    public var kind: Kind
    public var title: String?
    public var summary: String?
    public var siteName: String?
    /// File name of the downloaded image, in the previewer's directory.
    public var imageFile: String?
    public var imageWidth: Double?
    public var imageHeight: Double?
    public var fetchedAt: Date

    public init(
        url: String,
        kind: Kind,
        title: String? = nil,
        summary: String? = nil,
        siteName: String? = nil,
        imageFile: String? = nil,
        imageWidth: Double? = nil,
        imageHeight: Double? = nil,
        fetchedAt: Date = Date(),
    ) {
        self.url = url
        self.kind = kind
        self.title = title
        self.summary = summary
        self.siteName = siteName
        self.imageFile = imageFile
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fetchedAt = fetchedAt
    }

    public static let databaseTableName = "linkPreview"

    public var imageSize: CGSize? {
        guard imageFile != nil, let imageWidth, let imageHeight, imageWidth > 0, imageHeight > 0 else { return nil }
        return CGSize(width: imageWidth, height: imageHeight)
    }
}
