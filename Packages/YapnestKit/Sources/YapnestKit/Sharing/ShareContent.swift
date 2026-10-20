import Foundation

/// What the share sheet hands over, before it becomes messages.
public struct ShareContent: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var url: URL
        public var name: String?
        /// Sent as a photo: scaled down and stripped of its metadata, unless animated.
        public var isPhoto: Bool

        public init(url: URL, name: String? = nil, isPhoto: Bool = false) {
            self.url = url
            self.name = name
            self.isPhoto = isPhoto
        }
    }

    public enum Item: Sendable, Equatable {
        case file(File)
        case text(String)
    }

    public var files: [File]
    /// Shared text and links, each sent as a message of its own.
    public var texts: [String]
    /// What the user typed in the share sheet.
    public var comment: String

    public init(files: [File] = [], texts: [String] = [], comment: String = "") {
        self.files = files
        self.texts = texts
        self.comment = comment
    }

    /// The messages to send, in order: files, then text. A comment rides
    /// with the first text, so a link reads "look at this" above it;
    /// without any, it follows the files as a message of its own.
    public func items() -> [Item] {
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var texts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !comment.isEmpty {
            if texts.isEmpty { texts = [comment] } else { texts[0] = comment + "\n" + texts[0] }
        }
        return files.map(Item.file) + texts.map(Item.text)
    }
}
