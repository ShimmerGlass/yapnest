import SwiftUI
import YapnestKit

/// How a message's link preview is shown, which the conversation's and the
/// app's choices decide.
enum PreviewDisplay: Equatable {
    case none
    /// The conversation hasn't decided on previews yet.
    case ask
    case page(LinkPreview, URL?)
    case image(LinkPreview, URL)

    /// Whether it's drawn as a picture or a card, as opposed to nothing or a prompt.
    var hasCard: Bool {
        switch self {
        case .page, .image: true
        case .none, .ask: false
        }
    }
}

/// A message's file as the bubble draws it. Progress isn't part of it: it
/// changes many times a second and is read by the one view that shows it.
struct AttachmentDisplay: Equatable {
    var attachment: Attachment
    /// The file on this device, once there.
    var fileURL: URL?
    /// Worked out once, since formatting a size is not free.
    let sizeText: String?

    init(attachment: Attachment, fileURL: URL?) {
        self.attachment = attachment
        self.fileURL = fileURL
        sizeText = attachment.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Everything a message row needs to draw, worked out once per change so
/// that the row's body does no lookups, text analysis or database reads.
struct MessageRow: Identifiable, Equatable {
    struct Layout: Equatable {
        /// "Today", a date and so on; part of the layout so that a row is built again when midnight passes.
        var dayHeader: String?
        /// Marks where the unread messages began when the chat was opened.
        var showsUnreadDivider = false
        /// Grouped with the previous/next message: tighter spacing, sharper corners.
        var joinsPrevious = false
        var joinsNext = false
    }

    /// What the row is, decided when it is built: a call is a line, and skips
    /// the text, quote, link and attachment work a bubble needs.
    enum Kind: Equatable {
        case bubble
        case call(CallSummary)
    }

    struct Content: Equatable {
        var item: ConversationItem
        var kind = Kind.bubble
        var layout: Layout
        /// The sender's name above the bubble, for the first of a run in groups.
        var senderName: String?
        var quoteAuthor: String
        /// The quoted text without the blank lines around it.
        var quoteText: String
        /// The sender's name color, for groups.
        var senderColor: Color?
        /// The footer's time, and how the message was protected.
        var time: String
        var security: Message.Security
        /// Nil for a file message whose body is just the file's URL.
        var text: RenderedText?
        var preview: PreviewDisplay
        var attachment: AttachmentDisplay?
        /// Set when the whole body is a `geo:` URI, which is drawn as a map.
        var location: GeoLocation?
        /// The message is the chat's newest, so its suggested replies are offered.
        var showsResponses = false
        /// Drawn as the emoji alone, without a bubble; see `drawsWithoutBubble`.
        var isBare = false
        var accessibilityLabel: String
    }

    /// Whether a message is just emoji to be drawn large without a bubble:
    /// nothing else in it that the bubble would hold together (a quote, a
    /// file, a card), and not a deletion notice, a /me action or a message
    /// that couldn't be decrypted, whose words aren't the sender's emoji.
    static func drawsWithoutBubble(
        isEmojiOnly: Bool, isRetracted: Bool, isAction: Bool, isUndecryptable: Bool,
        hasQuote: Bool, hasAttachment: Bool, hasLocation: Bool, preview: PreviewDisplay,
    ) -> Bool {
        !isRetracted && !isAction && !isUndecryptable && !hasQuote && !hasAttachment && !hasLocation
            && preview == .none && isEmojiOnly
    }

    var content: Content
    /// Bumped whenever the content changes, so comparing two rows (which
    /// SwiftUI does for each visible one on every update) is two integers.
    var revision: Int

    var id: Int64 { content.item.id }
    var item: ConversationItem { content.item }
    var message: Message { content.item.message }
    var isOutgoing: Bool { message.direction == .outgoing }

    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.id == b.id && a.revision == b.revision
    }
}

/// Progress of uploads and downloads under way, by message id. Apart from
/// the rows, and with a value of its own for each transfer, so a percentage
/// ticking up redraws the one bubble showing it and not the others.
@MainActor
@Observable
final class TransferProgress {
    @MainActor
    @Observable
    final class Item {
        fileprivate(set) var value: Double

        fileprivate init(_ value: Double) {
            self.value = value
        }
    }

    @ObservationIgnored private var items: [Int64: Item] = [:]
    /// Which transfers are under way. Changes as they start and end, not as they advance.
    private var active: Set<Int64> = []

    /// Read in a view's body, it redraws the view when a transfer starts or ends.
    func item(for id: Int64) -> Item? {
        _ = active
        return items[id]
    }

    func isTransferring(_ id: Int64) -> Bool { items[id] != nil }

    func update(_ progress: [Int64: Double]) {
        for (id, value) in progress {
            if let item = items[id] {
                if item.value != value { item.value = value }
            } else {
                items[id] = Item(value)
            }
        }
        let ended = items.keys.filter { progress[$0] == nil }
        for id in ended { items[id] = nil }
        let keys = Set(progress.keys)
        if keys != active { active = keys }
    }
}

/// Owns the tasks that outlive a call, and cancels what's left when the
/// owner goes: a deinit on the main actor can't reach its own properties.
final class TaskBag: @unchecked Sendable {
    private var tasks: [String: Task<Void, Never>] = [:]

    subscript(name: String) -> Task<Void, Never>? {
        get { tasks[name] }
        set {
            tasks[name]?.cancel()
            tasks[name] = newValue
        }
    }

    func cancel(_ name: String) { self[name] = nil }

    /// Forgets a task that's ending by itself.
    func finish(_ name: String) { tasks[name] = nil }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}
