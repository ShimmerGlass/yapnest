import Foundation
import Martin

/// What an extension's wake read from the stream, by kind, logged when it leaves. On a server that pushes
/// for everything (ejabberd's `notify_on: all`), whatever reached the app's sleeping session since the last
/// wake caused this one's push, and the push itself says nothing of it: the kinds are what tell a wake that
/// causes the next (a loop) from one the contacts' traffic caused. Only kinds and counts, never who or what.
final class StreamTally: @unchecked Sendable {
    enum Kind: CaseIterable {
        case chat, encrypted, receipt, chatState, carbon, call, groupchat, archive, messageError, otherMessage
        case omemoDevices, omemoBundle, avatar, nick, bookmarks, otherEvent
        case ownPresence, roomPresence, contactPresence, subscription
        case ping, iqGet, iqSet, iqResult
    }

    private let lock = NSLock()
    private var counts: [Kind: Int] = [:]

    func count(_ element: Element, account: JID, isRoom: (JID) -> Bool) {
        guard let kind = Self.kind(of: element, account: account, isRoom: isRoom) else { return }
        lock.withLock { counts[kind, default: 0] += 1 }
    }

    var total: Int { lock.withLock { counts.values.reduce(0, +) } }

    func count(of kind: Kind) -> Int { lock.withLock { counts[kind] ?? 0 } }

    /// The kinds seen, as log fields; none for a kind that wasn't.
    var fields: [DiagField] {
        let counts = lock.withLock { self.counts }
        return Kind.allCases.compactMap { kind in counts[kind].map { Self.field(kind, $0) } }
    }

    /// Nil for what isn't a stanza: the stream's features, the sign-in and stream management's acks and
    /// requests, which every wake reads alike and say nothing of why it woke.
    static func kind(of element: Element, account: JID, isRoom: (JID) -> Bool) -> Kind? {
        let from = element.getAttribute("from").flatMap { JID($0) }
        switch element.name {
        case "presence":
            if let type = element.getAttribute("type"), type.hasPrefix("subscri") || type.hasPrefix("unsubscri") { return .subscription }
            guard let from else { return .ownPresence }
            if from == account { return .ownPresence }
            return isRoom(from) ? .roomPresence : .contactPresence
        case "iq":
            if element.findChild(name: "ping", xmlns: "urn:xmpp:ping") != nil { return .ping }
            return switch element.getAttribute("type") {
            case "get": .iqGet
            case "set": .iqSet
            default: .iqResult
            }
        case "message":
            return messageKind(element)
        default:
            return nil
        }
    }

    private static func messageKind(_ element: Element) -> Kind {
        if element.getAttribute("type") == "error" { return .messageError }
        // The wake's own catch-up, not what the server held for the app.
        if element.findChild(name: "result", xmlns: "urn:xmpp:mam:2") != nil { return .archive }
        if element.getAttribute("type") == "groupchat" { return .groupchat }
        if element.findChild(name: "received", xmlns: "urn:xmpp:carbons:2") != nil
            || element.findChild(name: "sent", xmlns: "urn:xmpp:carbons:2") != nil { return .carbon }
        if let event = element.findChild(name: "event", xmlns: "http://jabber.org/protocol/pubsub#event") {
            let node = event.findChild(name: "items")?.getAttribute("node") ?? ""
            if node == "eu.siacs.conversations.axolotl.devicelist" { return .omemoDevices }
            if node.hasPrefix("eu.siacs.conversations.axolotl.bundles") { return .omemoBundle }
            if node.hasPrefix("urn:xmpp:avatar") { return .avatar }
            if node == "http://jabber.org/protocol/nick" { return .nick }
            if node.contains("bookmarks") { return .bookmarks }
            return .otherEvent
        }
        if ResumeJournal.containsCallSignal(element) { return .call }
        if element.findChild(name: "encrypted", xmlns: "eu.siacs.conversations.axolotl") != nil { return .encrypted }
        if element.findChild(name: "body") != nil { return .chat }
        if element.findChild(name: "received", xmlns: "urn:xmpp:receipts") != nil
            || element.findChild(xmlns: "urn:xmpp:chat-markers:0") != nil { return .receipt }
        if element.findChild(xmlns: "http://jabber.org/protocol/chatstates") != nil { return .chatState }
        return .otherMessage
    }

    /// A log field's key has to be static, so each kind names its own.
    private static func field(_ kind: Kind, _ n: Int) -> DiagField {
        switch kind {
        case .chat: .int("chat", n)
        case .encrypted: .int("encrypted", n)
        case .receipt: .int("receipt", n)
        case .chatState: .int("chatState", n)
        case .carbon: .int("carbon", n)
        case .call: .int("call", n)
        case .groupchat: .int("groupchat", n)
        case .archive: .int("archive", n)
        case .messageError: .int("messageError", n)
        case .otherMessage: .int("otherMessage", n)
        case .omemoDevices: .int("omemoDevices", n)
        case .omemoBundle: .int("omemoBundle", n)
        case .avatar: .int("avatar", n)
        case .nick: .int("nick", n)
        case .bookmarks: .int("bookmarks", n)
        case .otherEvent: .int("otherEvent", n)
        case .ownPresence: .int("ownPresence", n)
        case .roomPresence: .int("roomPresence", n)
        case .contactPresence: .int("contactPresence", n)
        case .subscription: .int("subscription", n)
        case .ping: .int("ping", n)
        case .iqGet: .int("iqGet", n)
        case .iqSet: .int("iqSet", n)
        case .iqResult: .int("iqResult", n)
        }
    }
}
