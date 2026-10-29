import Foundation
import GRDB

/// What a notification for one message says.
public struct MessageNotification: Sendable, Equatable {
    public var messageId: Int64
    /// The conversation's peer: the contact, or the group.
    public var peer: JID
    /// The contact's name, or the group's.
    public var title: String
    /// Who wrote it, in a group.
    public var subtitle: String?
    public var body: String
    public var timestamp: Date
    public var isGroup: Bool = false
    /// The avatar of the contact or of the group, when we've seen one.
    public var peerAvatarHash: String?
    /// The author's address in a group, when the room shows it. Rooms that
    /// hide addresses leave this, and the avatar, empty: an occupant has none.
    public var senderJID: JID?
    public var senderAvatarHash: String?
    /// A message of a group that doesn't notify for it, or that arrives within
    /// the group's notification interval of the last loud one and isn't a
    /// mention. The push that announced it can't be suppressed without Apple's
    /// filtering entitlement, so the extension shows this one silently and
    /// takes it down again.
    public var isQuiet: Bool = false
    /// Set on a message that is quiet only because of the group's notification
    /// interval, not because the group is muted: how many messages of the
    /// group are unread, for updating the loud notification still on screen.
    public var heldCount: Int?
    /// The conversation's stored sound choice, as `NotificationSound` reads it.
    public var sound: String?
    /// Set on the notification of a held group invitation, which has no
    /// message; `peer` is then the group.
    public var isInvitation: Bool = false
}

extension AppDatabase {
    /// Takes the incoming messages nobody was notified about yet and moves the
    /// mark past them, in one transaction: whichever of the app and the
    /// notification extension claims a message notifies about it, the other
    /// doesn't. Messages already read are claimed without a notification.
    ///
    /// New means stored since the last claim, and sent since then too: a
    /// catch-up also stores history, such as a new device's first week, which
    /// is new to the database but not to the user. The first claim only sets
    /// the mark.
    ///
    /// `notifies` is false for a claim whose notifications won't be shown, as
    /// the app's while it's on screen: it doesn't start a group's
    /// notification interval, so the next message after it still notifies.
    public func claimNotifications(now: Date = Date(), notifies: Bool = true) throws -> [MessageNotification] {
        try claimNotificationsAndEdits(now: now, notifies: notifies).new
    }

    /// `claimNotifications`, and the messages corrected since the last claim
    /// that were already claimed then, for replacing their delivered
    /// notification's text. An edit never notifies by itself: it's only
    /// reported for a message that's still unread and not quiet.
    ///
    /// An edit stamped within the clock slack of the last claim is reported
    /// again by the next one. Replacing a notification twice with the same
    /// text is harmless, and it's what keeps an edit stored just before the
    /// mark moved, but stamped by a slow clock, from being missed.
    public func claimNotificationsAndEdits(now: Date = Date(), notifies: Bool = true) throws -> (new: [MessageNotification], edited: [MessageNotification]) {
        try writer.write { db in
            let newest = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM message") ?? 0
            let markId = try Self.setting(db, .lastNotifiedMessageId).flatMap { Int64($0) }
            let markDate = try Self.date(db, .lastNotifiedAt)
            try Self.setSetting(db, .lastNotifiedMessageId, String(max(newest, markId ?? 0)))
            try Self.setDate(db, .lastNotifiedAt, max(now, markDate ?? now))
            guard let markId, let markDate else { return ([], []) }

            // Sent shortly before the last claim but not stored by then: the
            // server's clock and ours may disagree a little.
            let since = markDate.addingTimeInterval(-Self.notificationClockSlack)
            let incoming = Column("direction") == Message.Direction.incoming && Column("isRead") == false
            let messages = newest > markId ? try Message
                .filter(Column("id") > markId && Column("timestamp") > since)
                .filter(incoming)
                .order(Column("timestamp"), Column("id"))
                .fetchAll(db) : []
            let edits = try Message
                .filter(Column("id") <= markId && Column("editedAt") > since)
                .filter(incoming)
                .order(Column("editedAt"), Column("id"))
                .fetchAll(db)
            // Claimed with the messages, in the same transaction, so that the
            // app and the extension can't both show one.
            let invitations = try Self.claimInvitations(db, notifies: notifies)
            return (
                try messages.compactMap { try Self.notification(db, for: $0, claimedAt: notifies ? now : nil) } + invitations,
                try edits.compactMap { try Self.notification(db, for: $0) }.filter { !$0.isQuiet },
            )
        }
    }

    /// The held invitations nobody was notified about yet, marked as notified.
    /// Not told for a claim whose notifications won't be shown, as the app's
    /// while it's on screen: the invitation's row is in front of the user.
    private static func claimInvitations(_ db: Database, notifies: Bool) throws -> [MessageNotification] {
        let unnotified = GroupInvitation.filter(Column("isNotified") == false)
        guard notifies else {
            try unnotified.updateAll(db, Column("isNotified").set(to: true))
            return []
        }
        let pending = try unnotified.order(Column("receivedAt")).fetchAll(db)
        guard !pending.isEmpty else { return [] }
        try unnotified.updateAll(db, Column("isNotified").set(to: true))
        return try pending.map { invitation in
            let inviter = try Contact.fetchOne(db, key: invitation.inviter)?.displayName ?? invitation.inviter.description
            let group = try GroupChat.filter(Column("jid") == invitation.room).fetchOne(db)?.displayName ?? invitation.room.description
            // A room on another server named the inviter itself, so it's
            // the room that says so.
            let body = invitation.isVouched
                ? String(localized: "\(inviter) invited you to \(group)")
                : String(localized: "\(group) says \(inviter) invited you")
            return MessageNotification(
                messageId: 0, peer: invitation.room, title: String(localized: "Group invitation"),
                // A group, for the group's sound.
                body: body, timestamp: invitation.receivedAt, isGroup: true, isInvitation: true,
            )
        }
    }

    static let notificationClockSlack: TimeInterval = 5 * 60

    /// `claimedAt` is set when the message is new to the claim, which holds a
    /// group to its notification interval, and moves the interval on when
    /// the message notifies loudly. An edit only replaces what's shown.
    static func notification(_ db: Database, for message: Message, claimedAt now: Date? = nil) throws -> MessageNotification? {
        guard let id = message.id, let conversation = try Conversation.fetchOne(db, key: message.conversationId) else { return nil }
        var body: String
        if message.callOutcome != nil {
            // Only a missed call is unread, so that's the one that gets here.
            body = Message.missedCallSummary
        } else if message.encryption == .omemoUndecryptable {
            body = String(localized: "🔒 Encrypted message")
        } else if let attachment = try Attachment.filter(Column("messageId") == id).fetchOne(db) {
            body = attachment.summary
        } else if GeoLocation(body: message.body) != nil {
            body = GeoLocation.summary
        } else {
            body = message.body.trimmingBlankEdgeLines
        }
        let action = message.meAction?.trimmingBlankEdgeLines
        if conversation.kind == .groupchat {
            var isQuiet = false
            var heldCount: Int?
            let group = try GroupChat.filter(Column("conversationId") == conversation.id).fetchOne(db)
            switch group?.notify ?? .always {
            case .always:
                // Compared with the claim's clock, not the message's, as it's
                // when this device told the user.
                if let now, let group, let minutes = conversation.notificationInterval {
                    // A last time well ahead of now is from a clock set back
                    // since, and would hold the group silent until it's
                    // reached. Within a second it's this claim's own, stored
                    // to the millisecond.
                    let elapsed = conversation.lastLoudNotificationAt.map { now.timeIntervalSince($0) }
                    if let elapsed, elapsed > -1, elapsed < TimeInterval(minutes) * 60 {
                        isQuiet = !message.addressesMe
                        if isQuiet {
                            // Everything unread counts, as in the badge: a
                            // group that notifies for every message has no
                            // unread one that doesn't.
                            heldCount = try Message
                                .filter(Column("conversationId") == message.conversationId)
                                .unread()
                                .fetchCount(db)
                        }
                    }
                    if !isQuiet {
                        try Conversation.filter(key: message.conversationId).updateAll(db, Column("lastLoudNotificationAt").set(to: now))
                    }
                }
            case .onMention:
                if group != nil { isQuiet = !message.addressesMe }
            case .never: isQuiet = true
            }
            let contact = message.sender == conversation.peer ? nil : try Contact.fetchOne(db, key: message.sender)
            let room = try Contact.fetchOne(db, key: conversation.peer)
            // A contact's own name, where the room tells us who they are.
            let author = message.sender != conversation.peer ? contact?.name ?? message.nick : message.nick
            if let action { body = "\(author ?? "") \(action)" }
            return MessageNotification(
                messageId: id, peer: conversation.peer,
                title: group?.displayName ?? conversation.peer.shortName,
                subtitle: author, body: body, timestamp: message.timestamp,
                isGroup: true, peerAvatarHash: room?.avatarHash,
                senderJID: contact?.jid, senderAvatarHash: contact?.avatarHash,
                isQuiet: isQuiet, heldCount: heldCount,
            )
        }
        let contact = try Contact.fetchOne(db, key: conversation.peer)
        let name = contact?.displayName ?? conversation.peer.shortName
        if let action { body = "\(name) \(action)" }
        return MessageNotification(
            messageId: id, peer: conversation.peer,
            title: name,
            subtitle: nil, body: body, timestamp: message.timestamp,
            peerAvatarHash: contact?.avatarHash, sound: conversation.notificationSound,
        )
    }

    /// Whether a group message is for us: it mentions us (XEP-0372), says
    /// our nickname as a word of its own, or replies to one of ours. Decided
    /// once, when the message is stored or our nickname changes, and kept in
    /// `Message.addressesMe`, so that counting what notifies never reads a body.
    static func isMention(_ db: Database, _ message: Message, nickname: String, word: NSRegularExpression? = nil) throws -> Bool {
        try addressesUs(
            db, conversationId: message.conversationId, body: message.body, mentionsMe: message.mentionsMe,
            replyToId: message.replyToId, nickname: nickname, word: word,
        )
    }

    /// `isMention` from the few columns it reads and in plain SQL, so that
    /// the migration that first stored the decision can use it: it must not
    /// depend on `Message`, whose columns later migrations change.
    static func addressesUs(
        _ db: Database, conversationId: Int64, body: String, mentionsMe: Bool, replyToId: String?,
        nickname: String, word: NSRegularExpression? = nil,
    ) throws -> Bool {
        if mentionsMe { return true }
        // An empty nickname has no text to look for. Most group messages
        // don't contain the nickname at all, so only those that do pay for
        // a regex.
        if !nickname.isEmpty, body.range(of: nickname, options: .caseInsensitive) != nil {
            if let regex = word ?? nicknameRegex(nickname),
               regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil {
                return true
            }
        }
        guard let replyToId else { return false }
        // Rooms reference messages by their stanza-id; some clients by ours.
        return try !referenceRequest(conversationId: conversationId, id: replyToId, direction: .outgoing).isEmpty(db)
    }

    /// Sets `addressesMe` on a message about to be stored or changed. Only a
    /// message in a room we have a nickname in can address us.
    static func refreshAddressesMe(_ db: Database, _ message: inout Message) throws {
        // Our own messages never notify, so they need no look at the room.
        if message.direction == .outgoing { message.addressesMe = false; return }
        let nickname = try String.fetchOne(db, GroupChat.filter(Column("conversationId") == message.conversationId).select(Column("nickname")))
        guard let nickname else { message.addressesMe = false; return }
        message.addressesMe = try isMention(db, message, nickname: nickname)
    }

    /// Decides again which of a room's unread messages address us, after our
    /// nickname there changed or the room was first recorded. Read messages
    /// no longer count for anything, so they keep the decision they had.
    static func refreshAddressesMe(_ db: Database, conversationId: Int64, nickname: String) throws {
        let word = nicknameRegex(nickname)
        var arguments: StatementArguments = [conversationId]
        var narrowing = ""
        // A busy room can have thousands of unread messages and most mention
        // nobody. SQL clears those that can't match and `addressesUs` decides
        // the rest. SQLite lowercases ASCII only, so a nickname beyond that,
        // which `addressesUs` matches by Unicode case, narrows nothing.
        if !nickname.isEmpty, nickname.allSatisfy(\.isASCII) {
            let mightMention = "(mentionsMe = 1 OR replyToId IS NOT NULL OR instr(lower(body), lower(?)) > 0)"
            try db.execute(
                sql: "UPDATE message SET addressesMe = 0 WHERE conversationId = ? AND isRead = 0 AND addressesMe = 1 AND NOT \(mightMention)",
                arguments: [conversationId, nickname])
            narrowing = " AND \(mightMention)"
            arguments += [nickname]
        }
        let unread = try Row.fetchAll(db, sql: """
            SELECT id, body, mentionsMe, replyToId, addressesMe FROM message
            WHERE conversationId = ? AND isRead = 0\(narrowing)
            """, arguments: arguments)
        for row in unread {
            let mention = try addressesUs(
                db, conversationId: conversationId, body: row["body"], mentionsMe: row["mentionsMe"], replyToId: row["replyToId"],
                nickname: nickname, word: word,
            )
            if mention != (row["addressesMe"] as Bool) {
                try db.execute(sql: "UPDATE message SET addressesMe = ? WHERE id = ?", arguments: [mention, row["id"] as Int64])
            }
        }
    }

    /// A reply can be stored before the message of ours it answers: archive
    /// pages come newest first, and our copy from another device comes when
    /// it comes. Once that message is here, unread replies naming it in a
    /// room we have a nickname in address us.
    static func refreshReplies(_ db: Database, toOutgoing message: Message) throws {
        guard message.direction == .outgoing else { return }
        let ids = message.referenceIds
        guard !ids.isEmpty,
              try GroupChat.filter(Column("conversationId") == message.conversationId).isEmpty(db) == false else { return }
        try db.execute(
            sql: "UPDATE message SET addressesMe = 1 WHERE conversationId = ? AND isRead = 0 AND addressesMe = 0 AND direction != ? AND replyToId IN (\(databaseQuestionMarks(count: ids.count)))",
            arguments: StatementArguments([message.conversationId]) + StatementArguments([Message.Direction.outgoing.rawValue]) + StatementArguments(ids))
    }

    private static func nicknameRegex(_ nickname: String) -> NSRegularExpression? {
        let name = NSRegularExpression.escapedPattern(for: nickname)
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(name)(?![\\p{L}\\p{N}_])", options: .caseInsensitive)
    }

    /// Unread messages for the app's badge: outside archived conversations,
    /// and outside groups that never notify. A group that notifies only for
    /// mentions counts only those, so the badge never promises a message the
    /// user wasn't told about.
    public func unreadCount() throws -> Int {
        try reader.read { db in try Self.unreadCount(db) }
    }

    static func unreadCount(_ db: Database) throws -> Int {
        try badgeCounts(db).values.reduce(0, +)
    }

    /// Each conversation's unread count, for clearing its notifications once
    /// it's read here or on another device, and the app's badge. Counts the
    /// same messages as `unreadCount()`: groups that never notify count none,
    /// and those that notify for mentions count only the mentions.
    /// Watched by the tables `unreadCounts` reads, so it fetches beside the
    /// writes rather than holding each one up (see `observeChatList`).
    public func observeUnreadBadge() -> ValueObservation<ValueReducers.Fetch<UnreadBadge>> {
        ValueObservation.tracking(regions: Self.unreadBadgeTables) { db in
            let entries = try Self.unreadCounts(db, archived: false)
            return UnreadBadge(counts: Self.badgeCounts(entries), hasUnread: entries.contains { $0.unread > 0 })
        }
        // Not deduplicated: the notification extension sets the badge too,
        // so a write that leaves the counts as they were can still follow a
        // badge the app has to put right. Callers skip the costly work
        // themselves when the counts are the same.
    }

    /// Every table `unreadCounts` reads.
    static let unreadBadgeTables: [any DatabaseRegionConvertible] = [
        Table(Message.databaseTableName), Table(Conversation.databaseTableName), Table(GroupChat.databaseTableName),
    ]

    /// What the badge counts, per peer. Archived conversations are left out;
    /// the others appear, with 0 when nothing is unread.
    static func badgeCounts(_ db: Database) throws -> [JID: Int] {
        badgeCounts(try unreadCounts(db, archived: false))
    }

    private static func badgeCounts(_ entries: [(id: Int64, peer: JID, unread: Int, notifying: Int)]) -> [JID: Int] {
        var counts: [JID: Int] = [:]
        for entry in entries { counts[entry.peer, default: 0] += entry.notifying }
        return counts
    }

    /// The one place that decides which unread messages notify, so the badge
    /// and the chat list can't disagree. Each conversation of the archived or
    /// the unarchived set appears, with 0 when nothing notifying is unread.
    /// `unread` is every unread message, `notifying` those that count.
    static func unreadCounts(_ db: Database, archived: Bool) throws -> [(id: Int64, peer: JID, unread: Int, notifying: Int)] {
        // One count per conversation, each an index lookup: the unread
        // messages are the whole of a partial index. A mention-only group
        // counts the messages stored as addressing us.
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversation.id, conversation.peer, groupChat.notify,
                (SELECT COUNT(*) FROM message WHERE message.conversationId = conversation.id AND message.isRead = 0) AS unread,
                CASE groupChat.notify WHEN ? THEN
                    (SELECT COUNT(*) FROM message WHERE message.conversationId = conversation.id AND message.isRead = 0 AND message.addressesMe = 1)
                END AS mentions
            FROM conversation
            LEFT JOIN groupChat ON groupChat.conversationId = conversation.id
            WHERE conversation.isArchived = ?
            """, arguments: [GroupChat.Notify.onMention.rawValue, archived])
        var counts: [(id: Int64, peer: JID, unread: Int, notifying: Int)] = []
        for row in rows {
            guard let peer = JID(row["peer"] as String) else { continue }
            let unread: Int = row["unread"]
            let notifying: Int = switch (row["notify"] as String?).flatMap(GroupChat.Notify.init) {
            case .never: 0
            case .onMention: row["mentions"]
            case .always, nil: unread
            }
            counts.append((row["id"], peer, unread, notifying))
        }
        return counts
    }

    /// The delivered notifications to take down, given the chat each one is
    /// for (its `peerKey`). A chat that isn't counted any more is archived,
    /// deleted or read, so anything but a chat with unread messages goes. A
    /// message in an archived chat brings it back, and its new notification
    /// with it. Notifications that aren't for a chat, an invitation's, are
    /// left out of `chats`: they go when the invitation does
    /// (`removeStaleInvitationNotifications`).
    public static func staleNotifications(chats: [(id: String, peer: String)], unread: [JID: Int]) -> [String] {
        let unreadPeers = Set(unread.filter { $0.value > 0 }.keys.map(\.description))
        return chats.filter { !unreadPeers.contains($0.peer) }.map(\.id)
    }

    /// Tells this process's observers about changes another process made,
    /// such as the notification extension's.
    public func notifyExternalChanges() throws {
        try writer.write { db in try db.notifyChanges(in: .fullDatabase) }
    }
}

/// What the app's badge shows.
public struct UnreadBadge: Equatable, Sendable {
    /// What notifies, per peer, as `badgeCounts` has it.
    public var counts: [JID: Int]
    /// Anything is unread outside archived chats, notifying or not.
    public var hasUnread: Bool

    public var count: Int { counts.values.reduce(0, +) }

    /// Unread messages that don't notify, as in a quiet group, get a dot
    /// where the chat list draws one, unless something counted takes the
    /// badge. A count would promise messages the user wasn't told about.
    public var showsDot: Bool { count == 0 && hasUnread }
}
