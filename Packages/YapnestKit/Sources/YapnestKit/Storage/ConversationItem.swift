import Foundation
import GRDB

/// A message ready for display: reactions grouped by emoji and the
/// replied-to message resolved.
public struct ConversationItem: Hashable, Sendable, Identifiable {
    public struct ReactionGroup: Hashable, Sendable {
        public var emoji: String
        public var senders: [Author]
        public var includesMe: Bool
        /// One of ours is still waiting for the server to acknowledge it.
        public var isPending: Bool
    }

    public struct Quote: Hashable, Sendable {
        public var author: Author?
        public var text: String
        /// Local id of the quoted message, if we have it, for jumping to it.
        public var messageId: Int64?
    }

    public var message: Message
    public var reactions: [ReactionGroup]
    public var quote: Quote?
    /// The preview of `message.link`, once fetched.
    public var preview: LinkPreview?
    public var attachment: Attachment?

    public var id: Int64 { message.id! }
}

/// A place in a conversation's message order, which is by time and then id.
public struct MessageCursor: Hashable, Sendable {
    public var timestamp: Date
    public var id: Int64

    public init(timestamp: Date, id: Int64) {
        self.timestamp = timestamp
        self.id = id
    }

    public init(_ message: Message) {
        self.init(timestamp: message.timestamp, id: message.id!)
    }
}

extension ConversationItem {
    public var cursor: MessageCursor { MessageCursor(message) }

    /// What quoting this message shows in place of its body: an undecryptable
    /// message's body is the sender's fallback text, and a file's or a
    /// location's is a URL.
    public var quoteSummary: String { Self.quoteSummary(of: message, attachment: attachment) }

    static func quoteSummary(of message: Message, attachment: Attachment?) -> String {
        if message.isRetracted {
            String(localized: "Deleted message")
        } else if message.encryption == .omemoUndecryptable {
            String(localized: "Couldn't decrypt this message")
        } else {
            Attachment.quoteSummary(text: message.body, attachment: attachment) ?? message.body
        }
    }
}

extension AppDatabase {
    /// How many messages a conversation shows before the user scrolls back.
    public static let initialWindow = 500

    /// The messages of the conversation with `peer`, oldest first: those from
    /// `since` on if given, which grows with new messages instead of sliding
    /// like the newest `limit` do, so what the user scrolled back to stays.
    /// `until` ends it at that message, included, instead of at the newest.
    public static func conversationItems(_ db: Database, peer: JID, me: JID, limit: Int = initialWindow, since: MessageCursor? = nil, until: MessageCursor? = nil) throws -> [ConversationItem] {
        guard let conversation = try Conversation.filter(Column("peer") == peer).fetchOne(db), let conversationId = conversation.id else {
            return []
        }
        var request = Message.filter(Column("conversationId") == conversationId)
        if let until {
            request = request.filter(Column("timestamp") < until.timestamp || (Column("timestamp") == until.timestamp && Column("id") <= until.id))
        }
        if let since {
            request = request.filter(Column("timestamp") > since.timestamp || (Column("timestamp") == since.timestamp && Column("id") >= since.id))
        } else {
            request = request.limit(limit)
        }
        // Newest first so that a limit keeps the newest; flipped below.
        let messages = try request
            .order(Column("timestamp").desc, Column("id").desc)
            .fetchAll(db)
            .reversed()

        let ids = messages.compactMap(\.id)
        let reactions = try Reaction.filter(ids.contains(Column("messageId"))).fetchAll(db)
        let reactionsByMessage = Dictionary(grouping: reactions, by: \.messageId)
        let attachments = Dictionary(
            try Attachment.filter(ids.contains(Column("messageId"))).fetchAll(db).map { ($0.messageId, $0) },
            uniquingKeysWith: { a, _ in a },
        )
        let links = Set(messages.compactMap(\.link))
        let previews = links.isEmpty ? [:] : Dictionary(
            try LinkPreview.fetchAll(db, keys: links).map { ($0.url, $0) },
            uniquingKeysWith: { a, _ in a },
        )

        // Everything replied to, in one query: as `referencedMessage` finds
        // each, by any of its ids and ranked the same way.
        let replyIds = Set(messages.compactMap(\.replyToId))
        var quoted: [String: Message] = [:]
        var quotedAttachments: [Int64: Attachment] = [:]
        if !replyIds.isEmpty {
            let candidates = try Message
                .filter(Column("conversationId") == conversationId)
                .filter(replyIds.contains(Column("remoteId")) || replyIds.contains(Column("originId")) || replyIds.contains(Column("serverId")))
                .fetchAll(db)
            for candidate in candidates {
                for id in Set([candidate.remoteId, candidate.originId, candidate.serverId].compactMap({ $0 })) where replyIds.contains(id) {
                    if let current = quoted[id], current.referenceRank(for: id)! >= candidate.referenceRank(for: id)! { continue }
                    quoted[id] = candidate
                }
            }
            quotedAttachments = Dictionary(
                try Attachment.filter(candidates.compactMap(\.id).contains(Column("messageId"))).fetchAll(db).map { ($0.messageId, $0) },
                uniquingKeysWith: { a, _ in a },
            )
        }

        return messages.map { message in
            Self.item(
                message, me: me,
                reactions: reactionsByMessage[message.id!] ?? [],
                attachment: attachments[message.id!],
                preview: message.link.flatMap { previews[$0] },
                quoted: message.replyToId.flatMap { quoted[$0] },
                quotedAttachment: message.replyToId.flatMap { quoted[$0] }.flatMap { quotedAttachments[$0.id!] },
            )
        }
    }

    /// Everything that goes into one item. Both the full fetch and the cached
    /// observation build items here, so they can't drift apart.
    static func item(_ message: Message, me: JID, reactions: [Reaction], attachment: Attachment?, preview: LinkPreview?, quoted original: Message?, quotedAttachment: Attachment?) -> ConversationItem {
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .map { emoji, reactions in
                ConversationItem.ReactionGroup(
                    emoji: emoji,
                    senders: reactions.sorted { ($0.sender, $0.nick) < ($1.sender, $1.nick) }.map(\.author),
                    includesMe: reactions.contains { $0.sender == me },
                    isPending: reactions.contains { $0.sender == me && $0.pendingId != nil },
                )
            }
            .sorted { ($0.senders.count, $1.emoji) > ($1.senders.count, $0.emoji) }

        var quote: ConversationItem.Quote?
        if message.replyToId != nil {
            if let original {
                quote = .init(author: original.author, text: ConversationItem.quoteSummary(of: original, attachment: quotedAttachment), messageId: original.id)
            } else {
                quote = .init(author: message.replyToSender.map { Author(jid: $0) }, text: message.replyFallback.map { Attachment.quoteSummary(text: $0, attachment: nil) ?? $0 } ?? "", messageId: nil)
            }
        }
        return ConversationItem(message: message, reactions: groups, quote: quote, preview: preview, attachment: attachment)
    }

    /// What `observeConversation` emits: the items, and a version that moves
    /// only when some item changed, so a write that touched nothing visible is
    /// dropped by comparing one number instead of the whole window.
    public struct ConversationSnapshot: Equatable, Sendable {
        let version: Int
        let items: [ConversationItem]

        public static func == (a: Self, b: Self) -> Bool { a.version == b.version }
    }

    /// GRDB can't tell which conversation a write touched, so every message
    /// stored re-reads this one. A cache keeps what was built for each message
    /// and rebuilds only those whose rows changed, so a receipt or a read
    /// mark costs a few cheap queries, not 500 to 2500 decoded items.
    public func observeConversation(peer: JID, me: JID, since: MessageCursor? = nil, until: MessageCursor? = nil) -> ValueObservation<ValueReducers.Map<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<ConversationSnapshot>>, [ConversationItem]>> {
        let cache = ConversationItemCache(me: me)
        return ValueObservation
            .tracking { db in try cache.fetch(db, peer: peer, since: since, until: until) }
            .removeDuplicates()
            .map(\.items)
    }

    /// Where a window reaching `count` messages further back than `cursor`
    /// would start, or nil if nothing older is stored. `found` is how many
    /// older messages there are, up to `count`.
    public func olderCursor(peer: JID, before cursor: MessageCursor, count: Int) throws -> (cursor: MessageCursor, found: Int)? {
        try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return nil }
            let older = try Message
                .filter(Column("conversationId") == conversationId)
                .filter(Column("timestamp") < cursor.timestamp || (Column("timestamp") == cursor.timestamp && Column("id") < cursor.id))
                .order(Column("timestamp").desc, Column("id").desc)
                .limit(count)
                .fetchAll(db)
            return older.last.map { (MessageCursor($0), older.count) }
        }
    }

    /// Where a window reaching `count` messages further on than `cursor` would
    /// end, or nil if nothing newer is stored. `found` is how many newer
    /// messages there are, up to `count`.
    public func newerCursor(peer: JID, after cursor: MessageCursor, count: Int) throws -> (cursor: MessageCursor, found: Int)? {
        try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return nil }
            let newer = try Message
                .filter(Column("conversationId") == conversationId)
                .filter(Column("timestamp") > cursor.timestamp || (Column("timestamp") == cursor.timestamp && Column("id") > cursor.id))
                .order(Column("timestamp"), Column("id"))
                .limit(count)
                .fetchAll(db)
            return newer.last.map { (MessageCursor($0), newer.count) }
        }
    }

    /// The window to show `messageId` in: nil if it isn't in the conversation
    /// with `peer`. Up to `limit` newer messages, it is the usual window that
    /// runs on to the newest, with `margin` older messages for context.
    /// Further back than that, reaching the newest would mean loading the
    /// whole stretch, so the window is bounded: `boundedMargin` messages
    /// either side, with an `end`.
    public func window(peer: JID, around messageId: Int64, boundedBeyond limit: Int, margin: Int = 30, boundedMargin: Int = 100) throws -> (start: MessageCursor, end: MessageCursor?)? {
        let target: (cursor: MessageCursor, newer: Int)? = try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id,
                  let message = try Message.fetchOne(db, key: messageId), message.conversationId == conversationId else { return nil }
            let cursor = MessageCursor(message)
            let newer = try Message
                .filter(Column("conversationId") == conversationId)
                .filter(Column("timestamp") > cursor.timestamp || (Column("timestamp") == cursor.timestamp && Column("id") > cursor.id))
                .fetchCount(db)
            return (cursor, newer)
        }
        guard let target else { return nil }
        guard target.newer > limit else {
            return (try olderCursor(peer: peer, before: target.cursor, count: margin)?.cursor ?? target.cursor, nil)
        }
        return (
            try olderCursor(peer: peer, before: target.cursor, count: boundedMargin)?.cursor ?? target.cursor,
            try newerCursor(peer: peer, after: target.cursor, count: boundedMargin)?.cursor ?? target.cursor,
        )
    }

    /// Incoming messages of the conversation with `peer` not read yet, however
    /// many of them a bounded window leaves out.
    public func unreadMessageCount(peer: JID) throws -> Int {
        try reader.read { try Self.unreadCount($0, peer: peer) }
    }

    /// The same count, kept up to date as messages arrive and are read.
    public func observeUnreadMessageCount(peer: JID) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<Int>>> {
        ValueObservation.tracking { try Self.unreadCount($0, peer: peer) }.removeDuplicates()
    }

    private static func unreadCount(_ db: Database, peer: JID) throws -> Int {
        guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return 0 }
        return try Message
            .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.incoming && Column("isRead") == false)
            .fetchCount(db)
    }

    /// The start of a window that includes `messageId`, with `margin` older
    /// messages for context; nil if it isn't in the conversation with `peer`.
    public func windowStart(peer: JID, including messageId: Int64, margin: Int = 30) throws -> MessageCursor? {
        let target: MessageCursor? = try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id,
                  let message = try Message.fetchOne(db, key: messageId), message.conversationId == conversationId else { return nil }
            return MessageCursor(message)
        }
        guard let target else { return nil }
        return try olderCursor(peer: peer, before: target, count: margin)?.cursor ?? target
    }

    /// What to open the conversation with `peer` on: its first unread message
    /// (the oldest incoming one not read yet), and where the window must start
    /// to include it, with some context above. That's nil when the newest
    /// `initialWindow` messages already do. Past `limit` messages the window
    /// stops reaching back, to bound what every change re-reads; the first
    /// unread one is then older than the window.
    public func openingWindow(peer: JID, limit: Int = 2500) throws -> (firstUnread: Int64?, start: MessageCursor?) {
        let unread: Message? = try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return nil }
            return try Message
                .filter(Column("conversationId") == conversationId && Column("direction") == Message.Direction.incoming && Column("isRead") == false)
                .order(Column("timestamp"), Column("id"))
                .fetchOne(db)
        }
        guard let unread, let id = unread.id else { return (nil, nil) }
        let newer: Int = try reader.read { db in
            try Message
                .filter(Column("conversationId") == unread.conversationId)
                .filter(Column("timestamp") > unread.timestamp || (Column("timestamp") == unread.timestamp && Column("id") >= id))
                .fetchCount(db)
        }
        guard newer > Self.initialWindow else { return (id, nil) }
        guard newer <= limit else {
            // Too much unread to show: as far back as the limit goes.
            let start: MessageCursor? = try reader.read { db in
                try Message
                    .filter(Column("conversationId") == unread.conversationId)
                    .order(Column("timestamp").desc, Column("id").desc)
                    .limit(limit)
                    .fetchAll(db)
                    .last
                    .map(MessageCursor.init)
            }
            return (id, start)
        }
        return (id, try windowStart(peer: peer, including: id, margin: 20))
    }

    /// The message of the conversation with `peer` that `reference` points at
    /// by any of its ids, if stored.
    public func referencedMessage(peer: JID, id reference: String) throws -> Message? {
        try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return nil }
            return try Self.referencedMessage(db, conversationId: conversationId, id: reference)
        }
    }

    /// The oldest message stored for the conversation with `peer`.
    public func oldestMessage(peer: JID) throws -> Message? {
        try reader.read { db in
            guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else { return nil }
            return try Message.filter(Column("conversationId") == conversationId).order(Column("timestamp"), Column("id")).fetchOne(db)
        }
    }

    public func observeContact(_ jid: JID) -> ValueObservation<ValueReducers.Fetch<Contact?>> {
        ValueObservation.tracking { db in try Contact.fetchOne(db, key: jid) }
    }

    /// The conversation's link preview choice; nil until the user decides.
    public func observeLinkPreviews(peer: JID) -> ValueObservation<ValueReducers.Fetch<Bool?>> {
        ValueObservation.tracking { db in
            try Conversation.filter(Column("peer") == peer).fetchOne(db)?.linkPreviews
        }
    }

    public func linkPreviews(peer: JID) throws -> Bool? {
        try reader.read { db in try Conversation.filter(Column("peer") == peer).fetchOne(db)?.linkPreviews }
    }

    public func setLinkPreviews(_ allowed: Bool?, peer: JID) throws {
        try writer.write { db in
            _ = try Self.conversation(db, with: peer)
            try Self.setChatSetting(db, peer, "linkPreviews", allowed.map { $0 ? "1" : "0" })
        }
    }

    /// What `NotificationSound` stored for the chat's notifications; nil is the system's sound.
    public func notificationSound(peer: JID) throws -> String? {
        try reader.read { db in try Conversation.filter(Column("peer") == peer).fetchOne(db)?.notificationSound }
    }

    public func setNotificationSound(_ sound: String?, peer: JID) throws {
        try writer.write { db in
            _ = try Self.conversation(db, with: peer)
            try Self.setChatSetting(db, peer, "notificationSound", sound)
        }
    }

    public func contact(_ jid: JID) throws -> Contact? {
        try reader.read { db in try Contact.fetchOne(db, key: jid) }
    }

    /// Every contact's display name, for views that name many authors and
    /// shouldn't read the database for each one.
    public func contactNames() throws -> [JID: String] {
        try reader.read { db in try Self.contactNames(db) }
    }

    /// The display names of those among `jids` who are contacts.
    public func contactNames(of jids: [JID]) throws -> [JID: String] {
        try reader.read { db in
            Dictionary(try Contact.fetchAll(db, keys: jids).map { ($0.jid, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func observeContactNames() -> ValueObservation<ValueReducers.Fetch<[JID: String]>> {
        ValueObservation.tracking { db in try Self.contactNames(db) }
    }

    private static func contactNames(_ db: Database) throws -> [JID: String] {
        Dictionary(try Contact.fetchAll(db).map { ($0.jid, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The items last built for a conversation window. A write to any tracked
/// table re-reads only each window message's `(id, rev)` pair: `rev` goes up
/// by a trigger whenever a message, or a reaction, attachment or link preview
/// belonging to it, changes. Only messages whose `rev` moved are fetched and
/// rebuilt, along with those whose quoted message moved.
final class ConversationItemCache: @unchecked Sendable {
    /// Which message a reply resolved to, and the revision it was at.
    private struct QuoteKey: Equatable {
        var id: Int64
        var rev: Int64
    }

    private struct Entry {
        var message: Message
        var rev: Int64
        var reactions: [Reaction]
        var attachment: Attachment?
        var preview: LinkPreview?
        var quote: QuoteKey?
        var item: ConversationItem
    }

    private let me: JID
    private let lock = NSLock()
    private var entries: [Int64: Entry] = [:]
    private var order: [Int64] = []
    private var items: [ConversationItem] = []
    private var version = 0

    init(me: JID) {
        self.me = me
    }

    func fetch(_ db: Database, peer: JID, since: MessageCursor?, until: MessageCursor? = nil, limit: Int = AppDatabase.initialWindow) throws -> AppDatabase.ConversationSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let conversationId = try Conversation.filter(Column("peer") == peer).fetchOne(db)?.id else {
            return publish([], [:])
        }
        var window = Message.filter(Column("conversationId") == conversationId)
        if let until {
            window = window.filter(Column("timestamp") < until.timestamp || (Column("timestamp") == until.timestamp && Column("id") <= until.id))
        }
        if let since {
            window = window.filter(Column("timestamp") > since.timestamp || (Column("timestamp") == since.timestamp && Column("id") >= since.id))
        } else {
            window = window.limit(limit)
        }
        window = window.order(Column("timestamp").desc, Column("id").desc)

        // Newest first, as the window is cut; flipped below.
        var revisions: [(id: Int64, rev: Int64)] = []
        let cursor = try Row.fetchCursor(db, window.select(Column("id"), Column("rev")))
        while let row = try cursor.next() {
            revisions.append((row[0], row[1]))
        }
        revisions.reverse()

        // What moved: new messages and those whose revision is not the one built.
        let moved = revisions.filter { entries[$0.id]?.rev != $0.rev }.map(\.id)
        var fresh: [Int64: Message] = [:]
        var revs: [Int64: Int64] = [:]
        if !moved.isEmpty {
            // The first read takes the whole window, as the full fetch does.
            let request = moved.count == revisions.count ? window : Message.filter(moved.contains(Column("id")))
            for row in try Row.fetchAll(db, request) {
                let message = try Message(row: row)
                fresh[message.id!] = message
                revs[message.id!] = row["rev"]
            }
        }
        let ids = Array(fresh.keys)
        let reactions = Dictionary(grouping: try Reaction.filter(ids.contains(Column("messageId"))).fetchAll(db), by: \.messageId)
        let attachments = Dictionary(
            try Attachment.filter(ids.contains(Column("messageId"))).fetchAll(db).map { ($0.messageId, $0) },
            uniquingKeysWith: { a, _ in a },
        )
        let links = Set(fresh.values.compactMap(\.link))
        let previews = links.isEmpty ? [:] : Dictionary(
            try LinkPreview.fetchAll(db, keys: links).map { ($0.url, $0) },
            uniquingKeysWith: { a, _ in a },
        )

        // Replies resolve as `conversationItems` does.
        func message(_ id: Int64) -> Message? { fresh[id] ?? entries[id]?.message }
        let replyIds = Set(revisions.compactMap { message($0.id)?.replyToId })
        var quoteKeys: [String: QuoteKey] = [:]
        if !replyIds.isEmpty {
            let candidates = try Row.fetchAll(db, Message
                .filter(Column("conversationId") == conversationId)
                .filter(replyIds.contains(Column("remoteId")) || replyIds.contains(Column("originId")) || replyIds.contains(Column("serverId")))
                .select(Column("id"), Column("rev"), Column("timestamp"), Column("remoteId"), Column("originId"), Column("serverId")))
            var best: [String: Message.ReferenceRank] = [:]
            for row in candidates {
                let key = QuoteKey(id: row["id"], rev: row["rev"])
                let ids: [String?] = [row["remoteId"], row["originId"], row["serverId"]]
                for reference in Set(ids.compactMap { $0 }) where replyIds.contains(reference) {
                    let rank = Message.ReferenceRank(isServerId: (row["serverId"] as String?) == reference, timestamp: row["timestamp"], id: key.id)
                    if let current = best[reference], current >= rank { continue }
                    best[reference] = rank
                    quoteKeys[reference] = key
                }
            }
        }

        // Rebuild what moved and what quotes something that did.
        var rebuild: [Int64] = []
        var needed: Set<Int64> = []
        for (id, _) in revisions {
            let quote = message(id)?.replyToId.flatMap { quoteKeys[$0] }
            if fresh[id] != nil || entries[id]?.quote != quote {
                rebuild.append(id)
                if let quote { needed.insert(quote.id) }
            }
        }
        let quotedMessages = Dictionary(
            try Message.filter(needed.contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) },
            uniquingKeysWith: { a, _ in a },
        )
        let quotedAttachments = Dictionary(
            try Attachment.filter(needed.contains(Column("messageId"))).fetchAll(db).map { ($0.messageId, $0) },
            uniquingKeysWith: { a, _ in a },
        )

        var next: [Int64: Entry] = [:]
        next.reserveCapacity(revisions.count)
        for id in rebuild {
            let old = entries[id]
            let isFresh = fresh[id] != nil
            let message = fresh[id] ?? old!.message
            let quote = message.replyToId.flatMap { quoteKeys[$0] }
            let entryReactions = isFresh ? reactions[id] ?? [] : old!.reactions
            let attachment = isFresh ? attachments[id] : old!.attachment
            let preview = isFresh ? message.link.flatMap { previews[$0] } : old!.preview
            let item = AppDatabase.item(
                message, me: me, reactions: entryReactions, attachment: attachment, preview: preview,
                quoted: quote.flatMap { quotedMessages[$0.id] },
                quotedAttachment: quote.flatMap { quotedAttachments[$0.id] },
            )
            next[id] = Entry(message: message, rev: revs[id] ?? old!.rev, reactions: entryReactions, attachment: attachment, preview: preview, quote: quote, item: item)
        }
        for (id, _) in revisions where next[id] == nil {
            next[id] = entries[id]
        }
        return publish(revisions.map(\.id), next, rebuilt: rebuild)
    }

    /// Keeps `entries` and moves the version only if the items differ. Reused
    /// items are the ones already published, so only rebuilt ones are compared.
    private func publish(_ order: [Int64], _ next: [Int64: Entry], rebuilt: [Int64] = []) -> AppDatabase.ConversationSnapshot {
        var changed = order != self.order
        if !changed {
            changed = rebuilt.contains { entries[$0]?.item != next[$0]!.item }
        }
        entries = next
        if changed {
            self.order = order
            items = order.map { next[$0]!.item }
            version += 1
        }
        return .init(version: version, items: items)
    }
}
