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
            func setting(_ key: SettingKey) throws -> String? {
                try Self.setting(db, key)
            }
            func set(_ key: SettingKey, _ value: String) throws {
                try Self.setSetting(db, key, value)
            }
            let newest = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM message") ?? 0
            let markId = try setting(.lastNotifiedMessageId).flatMap { Int64($0) }
            let markDate = try Self.date(db, .lastNotifiedAt)
            try set(.lastNotifiedMessageId, String(max(newest, markId ?? 0)))
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
                                .filter(Column("conversationId") == message.conversationId && Column("isRead") == false)
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
        if message.mentionsMe { return true }
        // An empty nickname has no text to look for. Most group messages
        // don't contain the nickname at all, so only those that do pay for
        // a regex.
        if !nickname.isEmpty, message.body.range(of: nickname, options: .caseInsensitive) != nil {
            if let regex = word ?? nicknameRegex(nickname),
               regex.firstMatch(in: message.body, range: NSRange(message.body.startIndex..., in: message.body)) != nil {
                return true
            }
        }
        guard let replyId = message.replyToId else { return false }
        // Rooms reference messages by their stanza-id; some clients by ours.
        return try referenceRequest(conversationId: message.conversationId, id: replyId, direction: .outgoing)
            .isEmpty(db) == false
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
        var unread = Message.filter(Column("conversationId") == conversationId && Column("isRead") == false)
        // A busy room can have thousands of unread messages and most mention
        // nobody. SQL clears those that can't match and `isMention` decides
        // the rest. SQLite lowercases ASCII only, so a nickname beyond that,
        // which `isMention` matches by Unicode case, narrows nothing.
        if !nickname.isEmpty, nickname.allSatisfy(\.isASCII) {
            let mightMention = Column("mentionsMe") == true || Column("replyToId") != nil
                || SQL("instr(lower(body), lower(\(nickname))) > 0").sqlExpression
            try unread.filter(!mightMention && Column("addressesMe") == true).updateAll(db, Column("addressesMe").set(to: false))
            unread = unread.filter(mightMention)
        }
        for message in try unread.fetchAll(db) {
            let mention = try isMention(db, message, nickname: nickname, word: word)
            if mention != message.addressesMe {
                try Message.filter(key: message.id).updateAll(db, Column("addressesMe").set(to: mention))
            }
        }
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
    public func observeUnreadBadge() -> ValueObservation<ValueReducers.Fetch<UnreadBadge>> {
        ValueObservation.tracking { db in
            let hasUnread = try Message
                .filter(Column("isRead") == false)
                .joining(required: Message.conversation.filter(Column("isArchived") == false))
                .isEmpty(db) == false
            return UnreadBadge(counts: try Self.badgeCounts(db), hasUnread: hasUnread)
        }
        // Not deduplicated: the notification extension sets the badge too,
        // so a write that leaves the counts as they were can still follow a
        // badge the app has to put right. Callers skip the costly work
        // themselves when the counts are the same.
    }

    /// What the badge counts, per peer. Archived conversations are left out;
    /// the others appear, with 0 when nothing is unread.
    static func badgeCounts(_ db: Database) throws -> [JID: Int] {
        var counts: [JID: Int] = [:]
        for entry in try notifyingCounts(db, archived: false) { counts[entry.peer, default: 0] += entry.count }
        return counts
    }

    /// The one place that decides which unread messages notify, so the badge
    /// and the chat list can't disagree. Each conversation of the archived or
    /// the unarchived set appears, with 0 when nothing notifying is unread.
    static func notifyingCounts(_ db: Database, archived: Bool) throws -> [(id: Int64, peer: JID, count: Int)] {
        // A mention-only group counts the messages stored as addressing us.
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversation.id, conversation.peer, COUNT(message.id) AS unread
            FROM conversation
            LEFT JOIN groupChat ON groupChat.conversationId = conversation.id
            LEFT JOIN message ON message.conversationId = conversation.id AND message.isRead = 0
                AND CASE groupChat.notify WHEN ? THEN 0 WHEN ? THEN message.addressesMe ELSE 1 END
            WHERE conversation.isArchived = ?
            GROUP BY conversation.id
            """, arguments: [GroupChat.Notify.never.rawValue, GroupChat.Notify.onMention.rawValue, archived])
        var counts: [(id: Int64, peer: JID, count: Int)] = []
        for row in rows {
            guard let peer = JID(row["peer"] as String) else { continue }
            let id: Int64 = row["id"]
            let unread: Int = row["unread"]
            counts.append((id, peer, unread))
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
