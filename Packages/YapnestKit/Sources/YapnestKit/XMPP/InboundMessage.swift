import Foundation
@preconcurrency import Martin

/// What an incoming `<message>` stanza means to us, independent of Martin
/// types so the storage side can be tested in isolation.
public struct InboundMessage: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Delivered to this resource.
        case live
        /// A XEP-0280 carbon of a message sent or received by another of our resources.
        case carbon(sent: Bool)
        /// A XEP-0313 archive result.
        case archive(serverId: String, timestamp: Date?)

        /// When the archive says the message was sent.
        var archivedAt: Date? {
            if case .archive(_, let timestamp) = self { timestamp } else { nil }
        }
    }

    public enum ChatState: String, Sendable {
        case active, composing, paused, inactive, gone
    }

    public struct Reply: Sendable, Equatable {
        public var id: String
        /// The replied-to author: a bare JID in 1:1 chats, the occupant's
        /// full room JID (room@service/nick) in group chats.
        public var to: String?
        public var fallback: String?
    }

    /// XEP-0444: the full reaction set for the referenced message.
    public struct Reactions: Sendable, Equatable {
        public var id: String
        public var emojis: Set<String>

        public static let maxDistinct = 20
        public static let maxBytes = 32

        /// What of a sender's reactions is kept: one emoji (a single character,
        /// however many scalars it joins) of sensible size each, no repeats,
        /// and at most `maxDistinct`, in the order sent. A stanza can carry
        /// any number of any length, and each becomes a stored row.
        public static func accepted(_ raw: [String]) -> Set<String> {
            var seen: [String] = []
            for value in raw where value.count == 1 && value.utf8.count <= maxBytes && !seen.contains(value) {
                seen.append(value)
                if seen.count == maxDistinct { break }
            }
            return Set(seen)
        }
    }

    public var peer: JID
    public var isOutgoing: Bool
    public var sender: JID
    /// In group chats: the sender's nickname.
    public var nick: String?
    /// XEP-0421: the sender's occupant id, from rooms that vouch for it.
    public var occupantId: String?
    public var type: String?
    public var timestamp: Date
    /// The timestamp came from a `<delay>` rather than from now. A live
    /// message's delay is only as good as the server that wrote it, so ingest
    /// keeps such a message from landing before what's already stored.
    public var isDelayed = false

    public static let maxBodyCharacters = 64 * 1024

    public var id: String?
    public var originId: String?
    /// The stanza-id our server (or, in group chats, the room) assigned, if any.
    public var serverId: String?

    /// Body with any XEP-0428 reply fallback removed.
    public var body: String?
    public var encryption: Message.Encryption
    /// For decrypted messages: the sending device and how far it's trusted.
    public var omemoDevice: Int32?
    public var omemoTrust: OMEMODevice.Trust?
    public var reply: Reply?
    /// XEP-0066 out-of-band URL; a file when it repeats the body.
    public var oobURL: String?
    /// XEP-0446 metadata of the file, from a `<file-sharing>` element.
    public var fileMetadata: FileMetadata?
    /// The `id` of that `<file-sharing>`, which a later message's sources name.
    public var fileSharingId: String?
    /// The `id` of XEP-0447 sources sent apart from their file (Dino's second
    /// message), which belong to the `<file-sharing>` with that id.
    public var sourcesId: String?
    /// XEP-0439: the replies and actions a bot offers with this message.
    public var quickResponses: QuickResponses?
    /// XEP-0439: the action of an offer that one of our devices chose.
    public var actionSelected: String?
    public var reactions: Reactions?
    /// XEP-0308: this stanza's body replaces that of the message with this
    /// id, the original's stanza id even after several corrections.
    public var correctionOf: String?
    /// XEP-0424: the message with this id is taken back: in 1:1 chats its
    /// stanza id, in group chats the room's stanza-id. An archive's
    /// tombstone of a retracted message points at itself.
    public var retractionOf: String?
    /// XEP-0372: someone the message mentions, as an xmpp: URI.
    public var mentions: [String] = []
    /// In group chats: one of `mentions` is us.
    public var mentionsMe = false
    /// From a group chat, whose conversation must already exist.
    public var isGroupChat = false
    /// A group chat's new subject; empty when it was cleared.
    public var subject: String?

    /// From a request for older history: part of the past, stored read and
    /// without moving the chat in the list, however old the chat's newest
    /// message makes it look.
    public var isHistory = false

    public var requestsReceipt = false
    public var receiptFor: String?
    public var isMarkable = false
    public var displayedMarkerFor: String?
    public var chatState: ChatState?
    public var isError: Bool
    /// For error stanzas: what went wrong, for display.
    public var errorText: String?
    /// What the error said, for whoever works out which send it answers.
    public var bounce: ServerError?
}

/// What a group chat stanza needs from the room to be understood.
public struct RoomContext: Sendable {
    public var jid: JID
    /// Our nickname there.
    public var nickname: String
    /// Real addresses of current occupants, by nickname, if the room shows them.
    public var occupants: [String: JID]
    /// Whether the room vouches for XEP-0421 occupant ids; without that,
    /// they're the sender's say-so and ignored.
    public var trustsOccupantIds: Bool
    /// Ours, from our own presence in the room.
    public var ownOccupantId: String?
    /// The room shows everyone's real address, so its archive adds one to
    /// each message.
    public var isNonAnonymous: Bool

    public init(jid: JID, nickname: String, occupants: [String: JID] = [:], trustsOccupantIds: Bool = false, ownOccupantId: String? = nil, isNonAnonymous: Bool = false) {
        self.jid = jid
        self.nickname = nickname
        self.occupants = occupants
        self.trustsOccupantIds = trustsOccupantIds
        self.ownOccupantId = ownOccupantId
        self.isNonAnonymous = isNonAnonymous
    }
}

extension InboundMessage {
    /// Parses `stanza`, which must already be OMEMO-decrypted if it was
    /// encrypted. Returns nil for stanzas that aren't from or to `account`'s
    /// 1:1 conversations.
    ///
    /// - Parameter encryption: what decryption found, if anything.
    public init?(
        _ stanza: Martin.Message,
        account: JID,
        source: Source,
        encryption: Message.Encryption = .none,
        now: Date = Date(),
    ) {
        let from = stanza.from.flatMap { JID($0.stringValue) } ?? account
        let to = stanza.to.flatMap { JID($0.stringValue) } ?? account

        let isOutgoing: Bool
        switch source {
        case .carbon(let sent): isOutgoing = sent
        case .live, .archive: isOutgoing = from == account
        }
        let peer = isOutgoing ? to : from
        guard peer != account || from == to else { return nil }
        if stanza.type == .groupchat { return nil }

        self.init(stanza, peer: peer, isOutgoing: isOutgoing, sender: from, nick: nil, stampedBy: account, account: account,
                  source: source, encryption: encryption, now: now)
        self.requestsReceipt = stanza.firstChild(name: "request", xmlns: NS.receipts) != nil
        self.receiptFor = stanza.firstChild(name: "received", xmlns: NS.receipts)?.getAttribute("id")
        self.isMarkable = stanza.firstChild(name: "markable", xmlns: NS.markers) != nil
        self.displayedMarkerFor = stanza.firstChild(name: "displayed", xmlns: NS.markers)?.getAttribute("id")
        self.chatState = stanza.element.children
            .first { $0.xmlns == NS.chatStates }
            .flatMap { ChatState(rawValue: $0.name) }
    }

    /// Parses a stanza from a group chat: a message (type groupchat) or an
    /// error bouncing one of ours. Returns nil for what isn't a message from
    /// an occupant, such as the room's own announcements.
    public init?(
        groupchat stanza: Martin.Message,
        room: RoomContext,
        account: JID,
        source: Source,
        encryption: Message.Encryption = .none,
        now: Date = Date(),
    ) {
        guard let from = stanza.from, JID(from.bareJid.stringValue) == room.jid else { return nil }
        if stanza.type == .error {
            self.init(stanza, peer: room.jid, isOutgoing: true, sender: account, nick: room.nickname, stampedBy: room.jid, account: account,
                      source: source, encryption: encryption, now: now)
            self.isGroupChat = true
            return
        }
        guard stanza.type == .groupchat, let nick = from.resource else { return nil }
        let isArchived = if case .archive = source { true } else { false }
        // Current occupants say nothing about who wrote an archived message,
        // and anyone may have held our nick before we joined.
        let real = Self.archivedAddress(in: stanza, source: source, isNonAnonymous: room.isNonAnonymous) ?? (isArchived ? nil : room.occupants[nick])
        let occupantId = room.trustsOccupantIds ? Self.occupantId(in: stanza.element) : nil
        let isOutgoing = if let real {
            real == account
        } else if let occupantId, let own = room.ownOccupantId {
            occupantId == own
        } else {
            // Live, the room keeps nicks unique.
            !isArchived && nick == room.nickname
        }
        self.init(stanza, peer: room.jid, isOutgoing: isOutgoing, sender: isOutgoing ? account : real ?? room.jid, nick: nick,
                  stampedBy: room.jid, account: account, source: source, encryption: encryption, now: now)
        self.occupantId = occupantId
        self.isGroupChat = true
        // By our address, or as an occupant of the room.
        let us = ["xmpp:\(account)", "xmpp:\(room.jid)/\(room.nickname)"]
        self.mentionsMe = !isOutgoing && mentions.contains { uri in us.contains { $0.caseInsensitiveCompare(uri) == .orderedSame } }
        if body == nil, let subject = stanza.firstChild(name: "subject") {
            self.subject = subject.value ?? ""
        }
    }

    var author: Author { Author(jid: sender, nick: nick, occupantId: occupantId) }

    /// Names a file announcement by the one who sent it, so that no one else
    /// can have their link take another's metadata.
    func announcementKey(forSharingId id: String) -> String {
        [peer.description, sender.description, nick ?? "", id].joined(separator: "\u{1F}")
    }

    /// The real address a non-anonymous room's archive gives an occupant's
    /// message. Live, the address comes from the occupant's presence: the
    /// same element in a live message is whatever its sender put there.
    static func archivedAddress(in stanza: Martin.Message, source: Source, isNonAnonymous: Bool) -> JID? {
        guard case .archive = source else { return nil }
        if let item = stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "item")?.getAttribute("jid").flatMap(JID.init(_:)) {
            return item
        }
        // Openfire's archive gives it the way XEP-0313 suggests, as a XEP-0033
        // original sender. The archive adds its own after anything the
        // sender put there, so the last one is the one to believe. Rooms
        // don't strip these, so in an anonymous room, where the archive adds
        // none, the only one would be the sender's own claim.
        guard isNonAnonymous else { return nil }
        return stanza.filterChildren(name: "addresses", xmlns: "http://jabber.org/protocol/address")
            .flatMap { $0.filterChildren(name: "address", xmlns: nil) }
            .last { $0.getAttribute("type") == "ofrom" }?
            .getAttribute("jid").flatMap(JID.init(_:))
    }

    /// The XEP-0421 id a room stamped on a message or presence. Only to be
    /// believed when the room says it supports them.
    static func occupantId(in element: Element) -> String? {
        guard let id = element.firstChild(name: "occupant-id", xmlns: NS.occupantId)?.getAttribute("id"), !id.isEmpty else { return nil }
        return id
    }

    /// The parts every message shares.
    private init(
        _ stanza: Martin.Message,
        peer: JID,
        isOutgoing: Bool,
        sender: JID,
        nick: String?,
        stampedBy stamper: JID,
        account: JID,
        source: Source,
        encryption: Message.Encryption,
        now: Date,
    ) {
        self.peer = peer
        self.isOutgoing = isOutgoing
        self.sender = sender
        self.nick = nick
        self.type = stanza.type?.rawValue
        self.isError = stanza.type == .error
        self.bounce = isError ? (ServerError(stanza.element) ?? ServerError(condition: "undefined-condition")) : nil
        self.errorText = bounce.map(Self.describeError)

        switch source {
        case .archive(let serverId, let timestamp):
            self.serverId = serverId
            // Our server's own time stays as it is, so a clock that runs behind
            // doesn't flatten history onto now.
            self.timestamp = timestamp ?? Self.trustedDelay(in: stanza, stamper: stamper, account: account, now: now)
        case .live, .carbon:
            self.serverId = stanza.stanzaId?[stamper.martin]
            let stamp = Self.trustedStamp(in: stanza, stamper: stamper, account: account)
            self.timestamp = min(stamp ?? now, now)
            self.isDelayed = stamp != nil
        }

        self.id = stanza.id
        self.originId = stanza.originId
        self.encryption = encryption

        if let replyEl = stanza.firstChild(name: "reply", xmlns: NS.reply), let replyId = replyEl.getAttribute("id") {
            let (body, fallback) = Self.strip(fallbackFor: NS.reply, from: stanza, encrypted: encryption == .omemo)
            self.body = body.map { Self.capped(Self.withoutSearchMarkers($0)) }
            self.reply = Reply(id: replyId, to: replyEl.getAttribute("to"), fallback: fallback.map(Self.capped))
        } else {
            self.body = stanza.body.map { Self.capped(Self.withoutSearchMarkers($0)) }
            self.reply = nil
        }
        if self.body?.isEmpty == true { self.body = nil }
        self.oobURL = stanza.firstChild(name: "x", xmlns: NS.oob)?.firstChild(name: "url")?.value
        // The file's size, shape, thumbnail and announcement ids sit outside the
        // OMEMO payload, so whoever relays the message could write them. In an
        // encrypted message they are ignored, as the send side never adds them.
        let plain = encryption == .none
        self.fileMetadata = plain ? FileMetadata(stanza) : nil
        func announcementId(_ name: String) -> String? {
            guard plain else { return nil }
            return stanza.firstChild(name: name, xmlns: NS.sfs)?.getAttribute("id").flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 }
        }
        self.fileSharingId = announcementId("file-sharing")
        self.sourcesId = announcementId("sources")

        // Outside the OMEMO payload too, so ignored in an encrypted message for
        // the same reason. They are an offer to the reader, so one in our own
        // message, or with no text to go with it, means nothing. Nor does one
        // from a room, or a private message through one (it carries the MUC
        // user element): choosing an action answers the sender, and in a room
        // that would reach everyone.
        let fromRoom = stanza.type == .groupchat || stanza.firstChild(name: "x", xmlns: NS.mucUser) != nil
        self.quickResponses = plain && !isOutgoing && !fromRoom && self.body != nil ? QuickResponses(stanza) : nil
        // Only our own devices' choices count, from a carbon or the archive, so
        // that our other devices stop offering the action. A contact's says
        // nothing to us, and an encrypted one is not covered by OMEMO.
        self.actionSelected = plain && isOutgoing && !fromRoom
            ? stanza.firstChild(name: "action-selected", xmlns: NS.quickResponse)?.getAttribute("id")
                .flatMap { QuickResponses.clean($0, maxLength: QuickResponses.maxValueLength) }
            : nil

        if let reactionsEl = stanza.firstChild(name: "reactions", xmlns: NS.reactions), let target = reactionsEl.getAttribute("id") {
            let emojis = reactionsEl.filterChildren(name: "reaction", xmlns: nil).compactMap { $0.value?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self.reactions = Reactions(id: target, emojis: Reactions.accepted(emojis))
        } else {
            self.reactions = nil
        }

        self.mentions = stanza.filterChildren(name: "reference", xmlns: NS.reference)
            .filter { $0.getAttribute("type") == "mention" }
            .compactMap { $0.getAttribute("uri") }

        self.correctionOf = stanza.firstChild(name: "replace", xmlns: NS.correction)?.getAttribute("id")
        if let retract = stanza.firstChild(name: "retract", xmlns: NS.retraction)?.getAttribute("id") {
            self.retractionOf = retract
        } else if let legacy = stanza.messageRetractionId {
            // Version 0, wrapped in XEP-0422 apply-to, from older clients.
            self.retractionOf = legacy
        } else if stanza.firstChild(name: "retracted", xmlns: NS.retraction) != nil {
            // The archive's tombstone stands in for the message itself.
            self.retractionOf = serverId ?? stanza.id
        }
        // Whatever a retraction says is only there for clients without it.
        if retractionOf != nil {
            self.body = nil
            self.correctionOf = nil
        }
    }

    /// When the stanza was held back, if someone we trust to know says so, and
    /// otherwise `now`. A `<delay>` is a claim by whoever added it, so any
    /// sender could back-date a message into old history, where it stays
    /// unread and raises no notification. Only the entity that stamped it
    /// counts: the room for a group chat, and for a 1:1 chat our own server
    /// (offline storage, by its domain or our address). Never in the future.
    static func trustedDelay(in stanza: Martin.Message, stamper: JID, account: JID, now: Date) -> Date {
        min(trustedStamp(in: stanza, stamper: stamper, account: account) ?? now, now)
    }

    /// The latest stamp of a trusted `<delay>`, if there is one.
    static func trustedStamp(in stanza: Martin.Message, stamper: JID, account: JID) -> Date? {
        var trusted: Set<JID> = [stamper]
        if stamper == account { trusted.insert(JID(account.domain)!) }
        let stamps = stanza.element.filterChildren(name: "delay", xmlns: "urn:xmpp:delay")
            .map { Delay(element: $0) }
            .filter { delay in delay.from.flatMap { JID($0.stringValue) }.map(trusted.contains) ?? false }
            .compactMap(\.stamp)
        return stamps.max()
    }

    /// What a bounce says to the user: a sentence for the common conditions,
    /// then the server's own words and the condition, so a failure can be
    /// told from another. The text comes from whoever sent the error, which
    /// is shown as it is (a line, cut short) and never as markup.
    static func describeError(_ error: ServerError) -> String {
        error.describe(friendlyBounce(error.condition))
    }

    static func friendlyBounce(_ condition: String) -> String {
        switch condition {
        case "remote-server-not-found", "remote-server-timeout": String(localized: "Couldn't reach the recipient's server.")
        case "service-unavailable", "item-not-found": String(localized: "The recipient's server refused the message.")
        case "not-acceptable", "policy-violation": String(localized: "The server refused the message.")
        case "forbidden", "not-allowed": String(localized: "You're not allowed to message this contact.")
        case "recipient-unavailable": String(localized: "The recipient isn't available.")
        default: String(localized: "The message couldn't be delivered.")
        }
    }

    /// `text` cut to `maxBodyCharacters`, between characters. Nothing sensible
    /// is that long, and every copy we store, index and draw would pay for it.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maxBodyCharacters else { return text }
        return String(text.prefix(maxBodyCharacters))
    }

    /// `text` without the characters that mark a match in a search result, as
    /// a sender could otherwise make words in one look matched.
    static func withoutSearchMarkers(_ text: String) -> String {
        let start = MessageSearchResult.matchStart.unicodeScalars.first!
        let end = MessageSearchResult.matchEnd.unicodeScalars.first!
        guard text.unicodeScalars.contains(where: { $0 == start || $0 == end }) else { return text }
        var text = text
        text.unicodeScalars.removeAll { $0 == start || $0 == end }
        return text
    }

    /// Removes the XEP-0428 fallback range for `namespace` from the body.
    /// Offsets count Unicode code points. Returns the remaining body and the
    /// removed text with its leading `> ` quote markers dropped.
    static func strip(fallbackFor namespace: String, from stanza: Martin.Message, encrypted: Bool = false) -> (body: String?, fallback: String?) {
        guard let body = stanza.body else { return (nil, nil) }
        let fallbacks = stanza.filterChildren(name: "fallback", xmlns: NS.fallback).filter { $0.getAttribute("for") == namespace }
        guard let range = fallbacks.lazy.compactMap({ $0.firstChild(name: "body") }).first,
              let start = range.getAttribute("start").flatMap(Int.init),
              let end = range.getAttribute("end").flatMap(Int.init) else {
            // A fallback without a range covers the whole body, unless the body
            // was decrypted: the fallback is plaintext anyone on the path could add.
            return fallbacks.isEmpty || encrypted ? (body, nil) : (nil, body)
        }
        let scalars = Array(body.unicodeScalars)
        guard 0 <= start, start <= end, end <= scalars.count else { return (body, nil) }
        // An encrypted body is only trusted to lose the quote of a reply: from
        // the start, and only lines that quote. Otherwise a server could cut
        // words out of what a verified contact said.
        if encrypted, start != 0 || !Self.isQuote(String(String.UnicodeScalarView(scalars[..<end]))) { return (body, nil) }
        var remaining = String.UnicodeScalarView()
        remaining.append(contentsOf: scalars[..<start])
        remaining.append(contentsOf: scalars[end...])
        let removed = String(String.UnicodeScalarView(scalars[start..<end]))
        let quote = removed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var line = line
                if line.hasPrefix(">") { line = line.dropFirst() }
                if line.hasPrefix(" ") { line = line.dropFirst() }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(remaining).trimmingCharacters(in: .whitespacesAndNewlines), quote.isEmpty ? nil : quote)
    }
}

extension InboundMessage {
    /// Whether `text` is nothing but lines starting with `>`, the last one
    /// ended by a newline.
    static func isQuote(_ text: String) -> Bool {
        guard text.unicodeScalars.last == "\n" else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()
        return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix(">") }
    }
}

extension JID {
    var martin: BareJID { BareJID(description) }

    init?(_ jid: Martin.JID) {
        self.init(jid.stringValue)
    }
}
