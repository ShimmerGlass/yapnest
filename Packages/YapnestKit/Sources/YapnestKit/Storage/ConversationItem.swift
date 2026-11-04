import Foundation
import GRDB
import os

/// A message ready for display: reactions grouped by emoji and the
/// replied-to message resolved.
public struct ConversationItem: Hashable, Sendable, Identifiable {
    public struct ReactionGroup: Hashable, Sendable {
        public var emoji: String
        public var senders: [Author]
        public var includesMe: Bool
        /// What a reaction that wasn't delivered says when the server gave no
        /// reason of its own.
        public static var notDelivered: String { String(localized: "The reaction couldn't be delivered.") }
    }

    /// Where our reactions on the message stand when the server hasn't
    /// acknowledged them, which an empty set has no reaction to show.
    public enum OwnReactionState: Hashable, Sendable {
        case pending
        case failed(String)
    }

    public struct Quote: Hashable, Sendable {
        public var author: Author?
        public var text: String
        /// Local id of the quoted message, if we have it, for jumping to it.
        public var messageId: Int64?
    }

    // Equal stamps short-cut `==`, so every stored content property must take a new stamp
    // in its `didSet` and be compared in `==` and hashed. One that doesn't would keep the
    // stamp when changed, and the rows built from it would never be rebuilt.
    public var message: Message {
        didSet { stamp = Self.nextStamp() }
    }
    public var reactions: [ReactionGroup] {
        didSet { stamp = Self.nextStamp() }
    }
    /// Nil once the server has our reactions, or if we have none to send.
    public var ownReactions: OwnReactionState? = nil {
        didSet { stamp = Self.nextStamp() }
    }
    public var quote: Quote? {
        didSet { stamp = Self.nextStamp() }
    }
    /// The preview of `message.link`, once fetched.
    public var preview: LinkPreview? {
        didSet { stamp = Self.nextStamp() }
    }
    public var attachment: Attachment? {
        didSet { stamp = Self.nextStamp() }
    }

    /// Why our reactions never reached the other side, which shows even when
    /// we have none left to show (we took the last one back).
    public var reactionFailure: String? {
        if case .failed(let reason) = ownReactions { reason } else { nil }
    }

    /// Whether a chip hangs off the message: it has reactions, or ours failed.
    public var showsReactionChip: Bool { !reactions.isEmpty || reactionFailure != nil }

    /// Whether the chip shows ours as still sending. Only while some of ours
    /// are on it: an empty set on its way has nothing of ours to mark, and
    /// others' reactions mustn't look like they are waiting on us.
    public var showsReactionsPending: Bool {
        ownReactions == .pending && reactions.contains(where: \.includesMe)
    }

    /// Names this content: every build and every change gets a stamp no other
    /// content in the process has had, so items with equal stamps are equal
    /// without comparing them field by field. Items built apart have different
    /// stamps and still compare equal by their fields. Hashing ignores it.
    public private(set) var stamp: Int64 = ConversationItem.nextStamp()

    public var id: Int64 { message.id! }

    private static let stamps = OSAllocatedUnfairLock(initialState: Int64(0))

    private static func nextStamp() -> Int64 { stamps.withLock { $0 += 1; return $0 } }

    public static func == (a: Self, b: Self) -> Bool {
        a.stamp == b.stamp || a.message == b.message && a.reactions == b.reactions && a.ownReactions == b.ownReactions && a.quote == b.quote
            && a.preview == b.preview && a.attachment == b.attachment
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(message)
        hasher.combine(reactions)
        hasher.combine(ownReactions)
        hasher.combine(quote)
        hasher.combine(preview)
        hasher.combine(attachment)
    }
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

    /// A row that selects `id` and `timestamp`.
    init(row: Row) {
        self.init(timestamp: row["timestamp"], id: row["id"])
    }

    // The bound on the timestamp alone is redundant. SQLite can't make a
    // range of the index out of the OR beside it, and would scan from one
    // end of the conversation.
    func sqlBefore(inclusive: Bool) -> SQLExpression {
        let ties = inclusive ? Column("id") <= id : Column("id") < id
        return Column("timestamp") <= timestamp && (Column("timestamp") < timestamp || (Column("timestamp") == timestamp && ties))
    }

    func sqlAfter(inclusive: Bool) -> SQLExpression {
        let ties = inclusive ? Column("id") >= id : Column("id") > id
        return Column("timestamp") >= timestamp && (Column("timestamp") > timestamp || (Column("timestamp") == timestamp && ties))
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
            message.undecryptableReason == .notForThisDevice
                ? String(localized: "Not encrypted for this device") : String(localized: "Couldn't decrypt this message")
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
        guard let conversation = try Self.existingConversation(db, peer: peer), let conversationId = conversation.id else {
            return []
        }
        var request = Message.all().inConversation(conversationId)
        if let until {
            request = request.filter(until.sqlBefore(inclusive: true))
        }
        if let since {
            request = request.filter(since.sqlAfter(inclusive: true))
        } else {
            request = request.limit(limit)
        }
        // Newest first so that a limit keeps the newest; flipped below.
        let messages = try request
            .newestFirst()
            .fetchAll(db)
            .reversed()

        let ids = messages.compactMap(\.id)
        let reactionsByMessage = try Self.reactions(db, messageIds: ids)
        let ownByMessage = try Self.ownReactions(db, messageIds: ids)
        let attachments = try Self.attachments(db, messageIds: ids)
        let previews = try Self.linkPreviews(db, urls: Set(messages.compactMap(\.link)))

        // Everything replied to, in one query: as `referencedMessage` finds
        // each, by any of its ids and ranked the same way.
        let replyIds = Set(messages.compactMap(\.replyToId))
        var quoted: [String: Message] = [:]
        var quotedAttachments: [Int64: Attachment] = [:]
        if !replyIds.isEmpty {
            let candidates = try Message
                .filter(Self.repliedTo(replyIds, in: conversationId))
                .fetchAll(db)
            quoted = Self.bestReferenced(
                candidates, replyIds: replyIds,
                references: { Set($0.referenceIds) }, rank: { $0.referenceRank(for: $1)! },
            )
            quotedAttachments = try Self.attachments(db, messageIds: candidates.compactMap(\.id))
        }

        return messages.map { message in
            Self.item(
                message, me: me,
                reactions: reactionsByMessage[message.id!] ?? [],
                own: ownByMessage[message.id!],
                attachment: attachments[message.id!],
                preview: message.link.flatMap { previews[$0] },
                quoted: message.replyToId.flatMap { quoted[$0] },
                quotedAttachment: message.replyToId.flatMap { quoted[$0] }.flatMap { quotedAttachments[$0.id!] },
            )
        }
    }

    /// For each of `replyIds`, the candidate it most likely names, by
    /// `Message.ReferenceRank`. `references` are the ids a candidate can be named
    /// by, and `rank` how well a candidate fits one of them. A caller that
    /// holds whole messages and one that holds only the columns share it.
    static func bestReferenced<Candidate>(
        _ candidates: [Candidate], replyIds: Set<String>,
        references: (Candidate) -> Set<String>, rank: (Candidate, String) -> Message.ReferenceRank,
    ) -> [String: Candidate] {
        var best: [String: (rank: Message.ReferenceRank, candidate: Candidate)] = [:]
        for candidate in candidates {
            for reference in references(candidate) where replyIds.contains(reference) {
                let candidateRank = rank(candidate, reference)
                if let current = best[reference], current.rank >= candidateRank { continue }
                best[reference] = (candidateRank, candidate)
            }
        }
        return best.mapValues(\.candidate)
    }

    /// The messages of the conversation that any of `ids` names, by any of their ids.
    /// The conversation is in each branch: SQLite doesn't carry it into an OR.
    static func repliedTo(_ ids: Set<String>, in conversationId: Int64) -> SQLExpression {
        let conversation = Column("conversationId") == conversationId
        return (conversation && ids.contains(Column("remoteId")))
            || (conversation && ids.contains(Column("originId")))
            || (conversation && ids.contains(Column("serverId")))
    }

    /// Everything that goes into one item. Both the full fetch and the cached
    /// observation build items here, so they can't drift apart.
    static func item(_ message: Message, me: JID, reactions: [Reaction], own: OwnReaction?, attachment: Attachment?, preview: LinkPreview?, quoted original: Message?, quotedAttachment: Attachment?) -> ConversationItem {
        let groups = Dictionary(grouping: reactions, by: \.emoji)
            .map { emoji, reactions in
                ConversationItem.ReactionGroup(
                    emoji: emoji,
                    senders: reactions.sorted { ($0.sender, $0.nick) < ($1.sender, $1.nick) }.map(\.author),
                    includesMe: reactions.contains { $0.sender == me },
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
        let state: ConversationItem.OwnReactionState? = if own?.pendingId != nil { .pending } else { own?.error.map { .failed($0) } }
        return ConversationItem(message: message, reactions: groups, ownReactions: state, quote: quote, preview: preview, attachment: attachment)
    }

    /// What `observeConversation` emits: the items, and a version that moves
    /// only when some item changed, so a write that touched nothing visible is
    /// dropped by comparing one number instead of the whole window.
    public struct ConversationSnapshot: Equatable, Sendable {
        let version: Int
        let items: [ConversationItem]

        public static func == (a: Self, b: Self) -> Bool { a.version == b.version }
    }

    /// Every table `ConversationItemCache.fetch` reads. Listed rather than
    /// worked out by GRDB, which would fetch on the writer after each commit
    /// and hold every write up while a chat is open (see `observeChatList`).
    static let conversationTables: [any DatabaseRegionConvertible] = [
        Table(Conversation.databaseTableName), Table(Message.databaseTableName), Table(Reaction.databaseTableName), Table(OwnReaction.databaseTableName),
        Table(Attachment.databaseTableName), Table(LinkPreview.databaseTableName),
    ]

    /// GRDB can't tell which conversation a write touched, so every message
    /// stored re-reads this one. A cache keeps what was built for each message
    /// and rebuilds only those whose rows changed, so a receipt or a read
    /// mark costs a few cheap queries, not 500 to 2500 decoded items.
    public func observeConversation(peer: JID, me: JID, since: MessageCursor? = nil, until: MessageCursor? = nil) -> ValueObservation<ValueReducers.Map<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<ConversationSnapshot>>, [ConversationItem]>> {
        let cache = ConversationItemCache(me: me)
        return ValueObservation
            .tracking(regions: Self.conversationTables) { db in try cache.fetch(db, peer: peer, since: since, until: until) }
            .removeDuplicates()
            .map(\.items)
    }

    /// Where a window reaching `count` messages further back than `cursor`
    /// would start, or nil if nothing older is stored. `found` is how many
    /// older messages there are, up to `count`.
    public func olderCursor(peer: JID, before cursor: MessageCursor, count: Int) throws -> (cursor: MessageCursor, found: Int)? {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer) else { return nil }
            return try Self.cursor(db, conversationId: conversationId, from: cursor, count: count, newer: false)
        }
    }

    /// Where a window reaching `count` messages further on than `cursor` would
    /// end, or nil if nothing newer is stored. `found` is how many newer
    /// messages there are, up to `count`.
    public func newerCursor(peer: JID, after cursor: MessageCursor, count: Int) throws -> (cursor: MessageCursor, found: Int)? {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer) else { return nil }
            return try Self.cursor(db, conversationId: conversationId, from: cursor, count: count, newer: true)
        }
    }

    private static func cursor(_ db: Database, conversationId: Int64, from cursor: MessageCursor, count: Int, newer: Bool) throws -> (cursor: MessageCursor, found: Int)? {
        let request = Message.all().inConversation(conversationId)
        let rows = try Row.fetchAll(db, (newer
            ? request.filter(cursor.sqlAfter(inclusive: false)).order(Column("timestamp"), Column("id"))
            : request.filter(cursor.sqlBefore(inclusive: false)).newestFirst())
            .limit(count)
            .select(Column("id"), Column("timestamp")))
        return rows.last.map { (MessageCursor(row: $0), rows.count) }
    }

    /// The window to show `messageId` in: nil if it isn't in the conversation
    /// with `peer`. Up to `limit` newer messages, it is the usual window that
    /// runs on to the newest, with `margin` older messages for context.
    /// Further back than that, reaching the newest would mean loading the
    /// whole stretch, so the window is bounded: `boundedMargin` messages
    /// either side, with an `end`.
    public func window(peer: JID, around messageId: Int64, boundedBeyond limit: Int, margin: Int = 30, boundedMargin: Int = 100) throws -> (start: MessageCursor, end: MessageCursor?)? {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer),
                  let message = try Message.fetchOne(db, key: messageId), message.conversationId == conversationId else { return nil }
            let target = MessageCursor(message)
            let newer = try Message.all()
                .inConversation(conversationId)
                .filter(target.sqlAfter(inclusive: false))
                .fetchCount(db)
            guard newer > limit else {
                return (try Self.cursor(db, conversationId: conversationId, from: target, count: margin, newer: false)?.cursor ?? target, nil)
            }
            return (
                try Self.cursor(db, conversationId: conversationId, from: target, count: boundedMargin, newer: false)?.cursor ?? target,
                try Self.cursor(db, conversationId: conversationId, from: target, count: boundedMargin, newer: true)?.cursor ?? target,
            )
        }
    }

    /// Incoming messages of the conversation with `peer` not read yet, however
    /// many of them a bounded window leaves out.
    public func unreadMessageCount(peer: JID) throws -> Int {
        try reader.read { try Self.unreadCount($0, peer: peer) }
    }

    /// The same count, kept up to date as messages arrive and are read.
    public func observeUnreadMessageCount(peer: JID) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<Int>>> {
        ValueObservation.tracking(regions: Self.unreadCountTables) { try Self.unreadCount($0, peer: peer) }.removeDuplicates()
    }

    static func unreadCount(_ db: Database, peer: JID) throws -> Int {
        guard let conversationId = try Self.conversationId(db, peer: peer) else { return 0 }
        return try Message.all()
            .inConversation(conversationId)
            .incomingOnly()
            .unread()
            .fetchCount(db)
    }

    /// The start of a window that includes `messageId`, with `margin` older
    /// messages for context; nil if it isn't in the conversation with `peer`.
    public func windowStart(peer: JID, including messageId: Int64, margin: Int = 30) throws -> MessageCursor? {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer),
                  let message = try Message.fetchOne(db, key: messageId), message.conversationId == conversationId else { return nil }
            return try Self.windowStart(db, conversationId: conversationId, target: MessageCursor(message), margin: margin)
        }
    }

    private static func windowStart(_ db: Database, conversationId: Int64, target: MessageCursor, margin: Int) throws -> MessageCursor {
        try cursor(db, conversationId: conversationId, from: target, count: margin, newer: false)?.cursor ?? target
    }

    /// What to open the conversation with `peer` on: its first unread message
    /// (the oldest incoming one not read yet), and where the window must start
    /// to include it, with some context above. That's nil when the newest
    /// `initialWindow` messages already do. Past `limit` messages the window
    /// stops reaching back, to bound what every change re-reads; the first
    /// unread one is then older than the window.
    public func openingWindow(peer: JID, limit: Int = 2500) throws -> (firstUnread: Int64?, start: MessageCursor?) {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer),
                  let unread = try Message.all()
                    .inConversation(conversationId)
                    .incomingOnly()
                    .unread()
                    .order(Column("timestamp"), Column("id"))
                    .fetchOne(db),
                  let id = unread.id else { return (nil, nil) }
            let newer = try Message.all()
                .inConversation(conversationId)
                .filter(MessageCursor(unread).sqlAfter(inclusive: true))
                .fetchCount(db)
            guard newer > Self.initialWindow else { return (id, nil) }
            guard newer <= limit else {
                // Too much unread to show: as far back as the limit goes.
                let start = try Row.fetchOne(db, Message.all()
                    .inConversation(conversationId)
                    .newestFirst()
                    .select(Column("id"), Column("timestamp"))
                    .limit(1, offset: limit - 1))
                    .map { MessageCursor(row: $0) }
                return (id, start)
            }
            return (id, try Self.windowStart(db, conversationId: conversationId, target: MessageCursor(unread), margin: 20))
        }
    }

    /// The message of the conversation with `peer` that `reference` points at
    /// by any of its ids, if stored.
    public func referencedMessage(peer: JID, id reference: String) throws -> Message? {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer) else { return nil }
            return try Self.referencedMessage(db, conversationId: conversationId, id: reference)
        }
    }

    /// The oldest message stored for the conversation with `peer`.
    public func oldestMessage(peer: JID) throws -> Message? {
        try reader.read { db in
            guard let conversationId = try Self.conversationId(db, peer: peer) else { return nil }
            return try Message.all().inConversation(conversationId).excludingEvents().order(Column("timestamp"), Column("id")).fetchOne(db)
        }
    }

    public func observeContact(_ jid: JID) -> ValueObservation<ValueReducers.Fetch<Contact?>> {
        ValueObservation.trackingConstantRegion { db in try Contact.fetchOne(db, key: jid) }
    }

    /// The conversation's link preview choice; nil until the user decides.
    public func observeLinkPreviews(peer: JID) -> ValueObservation<ValueReducers.Fetch<Bool?>> {
        ValueObservation.trackingConstantRegion { db in
            try Self.existingConversation(db, peer: peer)?.linkPreviews
        }
    }

    /// Whether the conversation is encrypted, as `isEncrypted(with:)` says.
    public func observeEncrypted(peer: JID) -> ValueObservation<ValueReducers.Fetch<Bool>> {
        ValueObservation.trackingConstantRegion { db in try Self.isEncrypted(db, peer: peer) }
    }

    public func linkPreviews(peer: JID) throws -> Bool? {
        try reader.read { db in try Self.existingConversation(db, peer: peer)?.linkPreviews }
    }

    public func setLinkPreviews(_ allowed: Bool?, peer: JID) throws {
        try writer.write { db in
            _ = try Self.conversation(db, with: peer)
            try Self.setChatSetting(db, peer, "linkPreviews", allowed.map { $0 ? "1" : "0" })
        }
    }

    /// What `NotificationSound` stored for the chat's notifications; nil is the system's sound.
    public func notificationSound(peer: JID) throws -> String? {
        try reader.read { db in try Self.existingConversation(db, peer: peer)?.notificationSound }
    }

    public func setNotificationSound(_ sound: String?, peer: JID) throws {
        try writer.write { db in
            _ = try Self.conversation(db, with: peer)
            try Self.setChatSetting(db, peer, "notificationSound", sound)
        }
    }

    /// The minutes a group that notifies for every message stays silent after a notification; nil is off.
    public func notificationInterval(peer: JID) throws -> Int? {
        try reader.read { db in try Self.existingConversation(db, peer: peer)?.notificationInterval }
    }

    public func setNotificationInterval(_ minutes: Int?, peer: JID) throws {
        try writer.write { db in
            _ = try Self.conversation(db, with: peer)
            try Self.setChatSetting(db, peer, "notificationInterval", minutes.map(String.init))
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

    static let unreadCountTables: [any DatabaseRegionConvertible] = [Table(Conversation.databaseTableName), Table(Message.databaseTableName)]

    public func observeContactNames() -> ValueObservation<ValueReducers.Fetch<[JID: String]>> {
        ValueObservation.trackingConstantRegion { db in try Self.contactNames(db) }
    }

    static func contactNames(_ db: Database) throws -> [JID: String] {
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
        var own: OwnReaction?
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

        guard let conversationId = try AppDatabase.conversationId(db, peer: peer) else {
            return publish([], [:])
        }
        var window = Message.all().inConversation(conversationId)
        if let until {
            window = window.filter(until.sqlBefore(inclusive: true))
        }
        if let since {
            window = window.filter(since.sqlAfter(inclusive: true))
        } else {
            window = window.limit(limit)
        }
        window = window.newestFirst()

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
        let reactions = try AppDatabase.reactions(db, messageIds: ids)
        let owned = try AppDatabase.ownReactions(db, messageIds: ids)
        let attachments = try AppDatabase.attachments(db, messageIds: ids)
        let previews = try AppDatabase.linkPreviews(db, urls: Set(fresh.values.compactMap(\.link)))

        // Replies resolve as `conversationItems` does.
        func message(_ id: Int64) -> Message? { fresh[id] ?? entries[id]?.message }
        let replyIds = Set(revisions.compactMap { message($0.id)?.replyToId })
        var quoteKeys: [String: QuoteKey] = [:]
        if !replyIds.isEmpty {
            let candidates = try Row.fetchAll(db, Message
                .filter(AppDatabase.repliedTo(replyIds, in: conversationId))
                .select(Column("id"), Column("rev"), Column("timestamp"), Column("remoteId"), Column("originId"), Column("serverId")))
            let best = AppDatabase.bestReferenced(
                candidates, replyIds: replyIds,
                references: { row in
                    let ids: [String?] = [row["remoteId"], row["originId"], row["serverId"]]
                    return Set(ids.compactMap { $0 })
                },
                rank: { row, reference in
                    Message.ReferenceRank(isServerId: (row["serverId"] as String?) == reference, timestamp: row["timestamp"], id: row["id"])
                },
            )
            quoteKeys = best.mapValues { QuoteKey(id: $0["id"], rev: $0["rev"]) }
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
            try Message.fetchAll(db, keys: needed).map { ($0.id!, $0) },
            uniquingKeysWith: { a, _ in a },
        )
        let quotedAttachments = try AppDatabase.attachments(db, messageIds: needed)

        var next: [Int64: Entry] = [:]
        next.reserveCapacity(revisions.count)
        for id in rebuild {
            let old = entries[id]
            let isFresh = fresh[id] != nil
            let message = fresh[id] ?? old!.message
            let quote = message.replyToId.flatMap { quoteKeys[$0] }
            let entryReactions = isFresh ? reactions[id] ?? [] : old!.reactions
            let own = isFresh ? owned[id] : old!.own
            let attachment = isFresh ? attachments[id] : old!.attachment
            let preview = isFresh ? message.link.flatMap { previews[$0] } : old!.preview
            let item = AppDatabase.item(
                message, me: me, reactions: entryReactions, own: own, attachment: attachment, preview: preview,
                quoted: quote.flatMap { quotedMessages[$0.id] },
                quotedAttachment: quote.flatMap { quotedAttachments[$0.id] },
            )
            next[id] = Entry(message: message, rev: revs[id] ?? old!.rev, reactions: entryReactions, own: own, attachment: attachment, preview: preview, quote: quote, item: item)
        }
        for (id, _) in revisions where next[id] == nil {
            next[id] = entries[id]
        }
        return publish(revisions.map(\.id), next, rebuilt: rebuild)
    }

    /// Keeps `entries` and moves the version only if the items differ. Reused
    /// items are the ones already published, so only rebuilt ones are compared.
    private func publish(_ order: [Int64], _ next: [Int64: Entry], rebuilt: [Int64] = []) -> AppDatabase.ConversationSnapshot {
        var next = next
        var changed = order != self.order
        for id in rebuilt {
            // A rebuild that came out the same keeps the published item, and
            // with it the stamp that says nothing changed.
            guard let old = entries[id]?.item else {
                changed = true
                continue
            }
            if old == next[id]!.item {
                next[id]!.item = old
            } else {
                changed = true
            }
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
