import Foundation
@preconcurrency import Martin

/// Builds outgoing `<message>` stanzas. Encryption is applied afterwards.
enum OutboundStanza {
    static func newId() -> String { UUID().uuidString.lowercased() }

    private static func base(to route: Route, id: String) -> Martin.Message {
        let message = Martin.Message()
        message.to = Martin.JID(route.peer.martin)
        message.type = route.isGroup ? .groupchat : .chat
        message.id = id
        message.originId = id
        return message
    }

    /// A request to see `peer`'s presence, with the name we go by (XEP-0172).
    /// A `preauth` token from their invitation (XEP-0379) lets their server
    /// approve it without asking them.
    static func subscriptionRequest(to peer: JID, nickname: String?, preauth: String? = nil) -> Presence {
        let presence = Presence()
        presence.to = Martin.JID(peer.martin)
        presence.type = .subscribe
        if let nickname { presence.nickname = nickname }
        if let preauth {
            let element = Element(name: "preauth", xmlns: "urn:xmpp:pars:0")
            element.attribute("token", newValue: preauth)
            presence.addChild(element)
        }
        return presence
    }

    struct QuotedMessage {
        /// The stanza id in 1:1 chats, the room's stanza-id in group chats.
        var id: String
        /// A bare JID in 1:1 chats, room@service/nick in group chats.
        var author: String
        var text: String
    }

    /// A XEP-0372 mention: who, and where in the text they're named, in
    /// Unicode code points from the start of the text.
    struct Mention: Equatable {
        var uri: String
        var begin: Int
        var end: Int
    }

    /// A text message, optionally replying to `quote` (XEP-0461) with a
    /// XEP-0428 fallback quote for clients that don't support replies.
    /// Group chat messages carry no receipt or marker request: those are for
    /// 1:1 chats. `active` adds the chat state every content message should
    /// carry (XEP-0085), for contacts who may use them.
    static func text(_ text: String, to route: Route, id: String, replyingTo quote: QuotedMessage? = nil, mentions: [Mention] = [], active: Bool = false) -> Martin.Message {
        let message = base(to: route, id: id)
        var quoteLength = 0
        if let quote {
            message.addChild(Element(name: "reply", attributes: ["xmlns": NS.reply, "to": quote.author, "id": quote.id]))
            // Nothing to quote: the reference alone still links the reply.
            if quote.text.isEmpty {
                message.body = text
            } else {
                let quoted = quote.text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n") + "\n"
                message.body = quoted + text
                quoteLength = quoted.unicodeScalars.count
                let range = Element(name: "body", attributes: ["start": "0", "end": String(quoteLength)])
                message.addChild(Element(name: "fallback", xmlns: NS.fallback, children: [range]).with(attribute: "for", NS.reply))
            }
        } else {
            message.body = text
        }
        // Mentions count from the start of the body, quote included.
        for mention in mentions {
            message.addChild(Element(name: "reference", attributes: [
                "xmlns": NS.reference, "type": "mention", "uri": mention.uri,
                "begin": String(mention.begin + quoteLength), "end": String(mention.end + quoteLength),
            ]))
        }
        if !route.isGroup {
            message.addChild(Element(name: "request", xmlns: NS.receipts))
            message.addChild(Element(name: "markable", xmlns: NS.markers))
        }
        if active {
            message.addChild(Element(name: "active", xmlns: NS.chatStates))
        }
        return message
    }

    /// Marks `message`, whose body is the link `url`, as a file for clients
    /// that know XEP-0066, and with `metadata` (XEP-0447, 0446, 0264) for those
    /// that know more, which show the file's shape before it is fetched. The
    /// message still works without any of it. Nothing at all goes out when
    /// `encrypted`: only the body is encrypted, so these elements would show
    /// the link, and what the picture looks like, to the server. So `metadata`
    /// is only evaluated, and the file only read, when it isn't.
    static func addFile(url: String, metadata: @autoclosure () -> FileMetadata?, encrypted: Bool, to message: Martin.Message) {
        guard !encrypted else { return }
        message.addChild(Element(name: "x", xmlns: NS.oob, children: [Element(name: "url", cdata: url)]))
        if let metadata = metadata() { message.addChild(metadata.sharing(url: url)) }
    }

    /// A body-less message into a group, for OMEMO to fill with keys alone. The
    /// store hint is added by the encryption, so that the room archives it.
    static func keyTransport(to room: JID, id: String) -> Martin.Message {
        base(to: .room(room, status: nil), id: id)
    }

    /// XEP-0444: the complete set of our reactions to message `target`. An
    /// empty set removes them.
    static func reactions(_ emojis: Set<String>, to route: Route, target: String, id: String) -> Martin.Message {
        let message = base(to: route, id: id)
        let children = emojis.sorted().prefix(InboundMessage.Reactions.maxDistinct).map { Element(name: "reaction", cdata: $0) }
        message.addChild(Element(name: "reactions", xmlns: NS.reactions, children: children).with(attribute: "id", target))
        message.addChild(Element(name: "store", xmlns: NS.hints))
        return message
    }

    /// XEP-0439: chooses the action `actionId` that a message offered. It has no
    /// body, so it is stored for the archive but shows nothing in a chat.
    static func actionSelected(_ actionId: String, to route: Route, id: String) -> Martin.Message {
        let message = base(to: route, id: id)
        message.addChild(Element(name: "action-selected", attributes: ["xmlns": NS.quickResponse, "id": actionId]))
        message.addChild(Element(name: "store", xmlns: NS.hints))
        return message
    }

    /// XEP-0424: takes back message `target`, with a body only for clients
    /// that don't know retractions, which must not say what was taken back.
    static func retraction(of target: String, to route: Route, id: String) -> Martin.Message {
        let message = base(to: route, id: id)
        message.addChild(Element(name: "retract", attributes: ["xmlns": NS.retraction, "id": target]))
        message.addChild(Element(name: "fallback", xmlns: NS.fallback).with(attribute: "for", NS.retraction))
        message.body = "/me retracted a previous message, but it's unsupported by your client."
        message.addChild(Element(name: "store", xmlns: NS.hints))
        return message
    }

    /// XEP-0184 delivery receipt.
    static func receipt(to peer: JID, for target: String) -> Martin.Message {
        let message = base(to: .direct(peer), id: newId())
        message.addChild(Element(name: "received", attributes: ["xmlns": NS.receipts, "id": target]))
        message.addChild(Element(name: "store", xmlns: NS.hints))
        return message
    }

    /// XEP-0333 displayed marker; also tells our other devices we've read up to `target`.
    static func displayed(to peer: JID, target: String) -> Martin.Message {
        let message = base(to: .direct(peer), id: newId())
        message.addChild(Element(name: "displayed", attributes: ["xmlns": NS.markers, "id": target]))
        message.addChild(Element(name: "store", xmlns: NS.hints))
        return message
    }

    /// XEP-0249 direct invitation to a group chat.
    static func invitation(to invitee: JID, room: JID, reason: String? = nil) -> Martin.Message {
        let message = Martin.Message()
        message.to = Martin.JID(invitee.martin)
        message.id = newId()
        let x = Element(name: "x", xmlns: NS.conference)
        x.setAttribute("jid", value: room.description)
        if let reason { x.setAttribute("reason", value: reason) }
        message.addChild(x)
        return message
    }

    /// XEP-0045 §7.8.2: tells `inviter`, through `room`, that we won't join.
    /// There is no reason: it would be one more thing for a stranger to read.
    static func invitationDecline(room: JID, inviter: JID) -> Martin.Message {
        let message = Martin.Message()
        message.to = Martin.JID(room.martin)
        message.id = newId()
        let x = Element(name: "x", xmlns: NS.mucUser)
        x.addChild(Element(name: "decline", attributes: ["to": inviter.description]))
        message.addChild(x)
        return message
    }

    /// XEP-0045 §9: sets `jid`'s affiliation with `room`. One item per
    /// request, as Prosody only applies the first.
    static func affiliation(_ affiliation: RoomAffiliation, of jid: JID, in room: JID) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucAdmin)
        query.addChild(Element(name: "item", attributes: ["affiliation": affiliation.rawValue, "jid": jid.description]))
        iq.addChild(query)
        return iq
    }

    /// XEP-0045 §8.2: takes the occupant `nickname` out of `room` for now, by
    /// setting their role to none. Their affiliation stays.
    static func kick(nickname: String, reason: String?, in room: JID) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucAdmin)
        let item = Element(name: "item", attributes: ["nick": nickname, "role": "none"])
        if let reason, !reason.isEmpty { item.addChild(Element(name: "reason", cdata: reason)) }
        query.addChild(item)
        iq.addChild(query)
        return iq
    }

    /// XEP-0045 §10.9: asks `room` to destroy itself.
    static func destroy(_ room: JID, reason: String?) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucOwner)
        let destroy = Element(name: "destroy")
        if let reason, !reason.isEmpty { destroy.addChild(Element(name: "reason", cdata: reason)) }
        query.addChild(destroy)
        iq.addChild(query)
        return iq
    }

    /// XEP-0045 §9.5: the list of those with `affiliation`.
    static func affiliationList(_ affiliation: RoomAffiliation, of room: JID) -> Iq {
        let iq = Iq()
        iq.type = .get
        iq.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucAdmin)
        query.addChild(Element(name: "item", attributes: ["affiliation": affiliation.rawValue]))
        iq.addChild(query)
        return iq
    }

    /// XEP-0045 §10.2: the room's configuration form.
    static func configurationRequest(of room: JID) -> Iq {
        let iq = Iq()
        iq.type = .get
        iq.to = Martin.JID(room.martin)
        iq.addChild(Element(name: "query", xmlns: NS.mucOwner))
        return iq
    }

    /// Submits `fields` as the room's configuration.
    static func configuration(_ fields: [String: [String]], of room: JID) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucOwner)
        query.addChild(XMPPSession.dataForm(type: "submit", formType: "http://jabber.org/protocol/muc#roomconfig", fields: fields))
        iq.addChild(query)
        return iq
    }

    /// XEP-0054: the vCard of `room`, to read before changing it.
    static func vCardRequest(of room: JID) -> Iq {
        let iq = Iq()
        iq.type = .get
        iq.to = Martin.JID(room.martin)
        iq.addChild(Element(name: "vCard", xmlns: NS.vcardTemp))
        return iq
    }

    /// Sets `room`'s vCard to `vCard`.
    static func vCard(_ vCard: Element, of room: JID) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        iq.addChild(vCard)
        return iq
    }

    /// XEP-0425: asks `room` to retract the message it stamped `stanzaId`,
    /// for everyone. No reason: the room would show it to all.
    static func moderatedRetraction(of stanzaId: String, in room: JID) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        let moderate = Element(name: "moderate", xmlns: NS.moderation)
        moderate.setAttribute("id", value: stanzaId)
        moderate.addChild(Element(name: "retract", xmlns: NS.retraction))
        iq.addChild(moderate)
        return iq
    }

    /// XEP-0085 standalone chat state notification. It may hold nothing
    /// but the state (§5.6), so no storage hint: servers don't archive
    /// messages without a body anyway.
    static func chatState(_ state: InboundMessage.ChatState, to peer: JID) -> Martin.Message {
        let message = Martin.Message()
        message.to = Martin.JID(peer.martin)
        message.type = .chat
        message.addChild(Element(name: state.rawValue, xmlns: NS.chatStates))
        return message
    }
}

extension Element {
    func with(attribute name: String, _ value: String) -> Element {
        setAttribute(name, value: value)
        return self
    }
}

enum Mentions {
    /// Where `text` names any of `nicks` as a word of its own, longest
    /// nicknames first, without overlaps. Offsets count Unicode code points,
    /// as XEP-0372 does.
    static func find(_ nicks: some Sequence<String>, in text: String) -> [(nick: String, begin: Int, end: Int)] {
        var found: [(nick: String, range: Range<String.Index>)] = []
        for nick in Set(nicks).sorted(by: { $0.count > $1.count }) where !nick.isEmpty {
            // Compiling a regex per occupant is the cost; most nicknames
            // aren't in the text at all.
            guard text.range(of: nick, options: .caseInsensitive) != nil else { continue }
            let pattern = "(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: nick))(?![\\p{L}\\p{N}_])"
            var start = text.startIndex
            while let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive], range: start..<text.endIndex) {
                if !found.contains(where: { $0.range.overlaps(range) }) { found.append((nick, range)) }
                start = range.upperBound
            }
        }
        return found
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { item in
                let begin = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: item.range.lowerBound)
                let length = text.unicodeScalars.distance(from: item.range.lowerBound, to: item.range.upperBound)
                return (item.nick, begin, begin + length)
            }
    }
}

/// The Jingle Message Initiation messages (XEP-0353) a call sends, shaped as
/// Conversations sends them, which is what the other clients expect.
enum CallMessage: Sendable, Equatable {
    /// To the peer's bare address, so all their devices ring.
    case propose(to: String, video: Bool)
    /// With `tieBreak`, because a call the other way took precedence.
    case retract(to: String, reason: CallReason, tieBreak: Bool = false)
    /// To the caller's device, once the call is shown here.
    case ringing(to: String)
    /// To the caller's device, which then starts the Jingle session with us.
    case proceed(to: String)
    /// To our own bare address, so our other devices stop ringing.
    case accept(to: String)
    case reject(to: String, reason: CallReason, tieBreak: Bool = false)
    case finish(to: String, reason: CallReason)

    /// Whether it tells the peer a call is over, which is still worth sending
    /// late. A proposal or an answer isn't.
    var endsACall: Bool {
        switch self {
        case .retract, .reject, .finish: true
        case .propose, .ringing, .proceed, .accept: false
        }
    }

    var elementName: String {
        switch self {
        case .propose: "propose"
        case .retract: "retract"
        case .ringing: "ringing"
        case .proceed: "proceed"
        case .accept: "accept"
        case .reject: "reject"
        case .finish: "finish"
        }
    }

    var recipient: String {
        switch self {
        case .propose(let to, _), .retract(let to, _, _), .ringing(let to), .proceed(let to), .accept(let to),
             .reject(let to, _, _), .finish(let to, _): to
        }
    }
}

extension OutboundStanza {
    static let proposeIdPrefix = "jm-propose-"
    static let proceedIdPrefix = "jm-proceed-"

    /// With `omemoDevice`, a `proceed` names our OMEMO device, which tells the
    /// caller that the call's fingerprints can be encrypted to it
    /// (`CallFingerprints`).
    static func call(_ call: CallMessage, sid: String, omemoDevice: UInt32? = nil) -> Martin.Message {
        let message = Martin.Message()
        message.type = .chat
        message.to = Martin.JID(call.recipient)
        // A receipt for a propose names its call by the id.
        message.id = switch call {
        case .propose: proposeIdPrefix + sid
        case .proceed: proceedIdPrefix + sid
        default: newId()
        }
        var children = if case .propose(_, let video) = call {
            (video ? ["audio", "video"] : ["audio"]).map { Element(name: "description", attributes: ["xmlns": CallSignal.rtp, "media": $0]) }
        } else {
            reasonElement(for: call).map { [$0] } ?? []
        }
        switch call {
        case .retract(_, _, true), .reject(_, _, true): children.append(Element(name: "tie-break"))
        default: break
        }
        if case .proceed = call, let omemoDevice {
            let device = Element(name: "device", xmlns: CallFingerprints.namespace)
            device.setAttribute("id", value: String(omemoDevice))
            children.append(device)
        }
        let element = Element(name: call.elementName, xmlns: CallSignal.namespace, children: children)
        element.setAttribute("id", value: sid)
        message.addChild(element)
        if case .propose = call {
            message.addChild(Element(name: "request", xmlns: NS.receipts))
        }
        message.addChild(Element(name: "store", xmlns: NS.hints))
        return message
    }

    private static func reasonElement(for call: CallMessage) -> Element? {
        let (reason, text): (CallReason, String?)
        switch call {
        case .retract(_, let why, let tieBreak): (reason, text) = (why, tieBreak ? "Tie-Break" : "Retracted")
        case .reject(_, let why, let tieBreak): (reason, text) = (why, tieBreak ? "Tie-Break" : nil)
        case .finish(_, let why): (reason, text) = (why, nil)
        case .propose, .ringing, .proceed, .accept: return nil
        }
        var children = [Element(name: reason.rawValue)]
        if let text { children.append(Element(name: "text", cdata: text)) }
        return Element(name: "reason", xmlns: JingleModule.XMLNS, children: children)
    }
}
