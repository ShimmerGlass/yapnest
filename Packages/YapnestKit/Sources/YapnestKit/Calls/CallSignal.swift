import Foundation
@preconcurrency import Martin

/// Why a call, or a part of one, was ended or turned down: the condition
/// inside a Jingle `<reason>` (XEP-0166).
public enum CallReason: String, Sendable, Equatable {
    case success
    case decline
    case busy
    case cancel
    case connectivityError = "connectivity-error"
    case failedApplication = "failed-application"
    case generalError = "general-error"
    case timeout
    case gone
    /// A call that lost a tie-break, or an offer that is too old to take.
    case expired
    /// A propose whose media we can't take, such as video without audio.
    case unsupportedApplications = "unsupported-applications"

    /// The same condition as Martin names it, written out so that a case
    /// added to one side doesn't silently become another.
    var jingle: JingleSessionTerminateReason {
        switch self {
        case .success: .success
        case .decline: .decline
        case .busy: .busy
        case .cancel: .cancel
        case .connectivityError: .connectivityError
        case .failedApplication: .failedApplication
        case .generalError: .generalError
        case .timeout: .timeout
        case .gone: .gone
        case .expired: .expired
        case .unsupportedApplications: .unsupportedApplications
        }
    }
}

/// What an incoming Jingle Message Initiation message (XEP-0353) means,
/// independent of Martin, like `InboundMessage` for chat messages.
struct CallSignal: Sendable, Equatable {
    enum Media: String, Sendable {
        case audio, video
    }

    enum Action: Sendable, Equatable {
        /// A call is offered, with the kinds of media it asks for.
        case propose(media: Set<Media>)
        case ringing
        case proceed
        case accept
        case reject(CallReason?)
        case retract(CallReason?)
        case finish(CallReason?)

        var asksForVideo: Bool {
            if case .propose(let media) = self { media.contains(.video) } else { false }
        }
    }

    static let namespace = JingleModule.MESSAGE_INITIATION_XMLNS
    static let rtp = "urn:xmpp:jingle:apps:rtp:1"
    static let maxSessionIdLength = 256

    /// The session the signal is about; the same in every message of a call.
    var sid: String
    var action: Action
    /// Who sent it, bare. For a carbon of a message we sent, that's us.
    var sender: JID
    /// Who it was sent to, bare.
    var recipient: JID
    /// The sender's full address as the stanza had it, which names the device.
    var from: String?
    /// Written by one of our devices.
    var isFromAccount: Bool
    var timestamp: Date
    /// A `reject` or `retract` that says its call lost the tie-break against
    /// a call the other way (XEP-0353 §4.1), so the call carries on under the
    /// other one and this one is nobody's to log.
    var isTieBreak = false

    /// The other party of the call as the conversation holds it, or nil for a
    /// message we addressed to ourselves (the `accept` that stops our other
    /// devices ringing).
    var peer: JID? {
        guard isFromAccount else { return sender }
        return recipient == sender ? nil : recipient
    }

    /// Which way the call went, as far as this message says: who proposes or
    /// retracts is the caller, who answers or turns it down the callee.
    var impliedDirection: Message.Direction? {
        switch action {
        case .propose, .retract: isFromAccount ? .outgoing : .incoming
        case .proceed, .accept, .reject, .ringing: isFromAccount ? .incoming : .outgoing
        case .finish: nil
        }
    }

    /// Nil for what isn't a Jingle message, or is one we can't use.
    init?(_ stanza: Martin.Message, account: JID, source: InboundMessage.Source, now: Date = Date()) {
        guard stanza.type != .error, stanza.type != .groupchat,
              let element = stanza.element.children.first(where: { $0.xmlns == Self.namespace }),
              let sid = element.getAttribute("id"), !sid.isEmpty, sid.count <= Self.maxSessionIdLength,
              let action = Self.action(of: element) else { return nil }
        let from = stanza.from
        let sender = from.flatMap { JID($0.bareJid.stringValue) } ?? account
        let recipient = stanza.to.flatMap { JID($0.bareJid.stringValue) } ?? account
        let isFromAccount = switch source {
        case .carbon(let sent): sent
        case .live, .archive: sender == account
        }
        self.sid = sid
        self.action = action
        self.sender = isFromAccount ? account : sender
        self.recipient = recipient
        self.from = from?.stringValue
        self.isFromAccount = isFromAccount
        isTieBreak = element.name != "propose" && element.firstChild(name: "tie-break") != nil
        switch source {
        case .archive(_, let timestamp):
            self.timestamp = timestamp ?? InboundMessage.trustedDelay(in: stanza, stamper: account, account: account, now: now)
        case .live, .carbon:
            self.timestamp = InboundMessage.trustedDelay(in: stanza, stamper: account, account: account, now: now)
        }
    }

    init(sid: String, action: Action, sender: JID, recipient: JID, from: String? = nil, isFromAccount: Bool = false, timestamp: Date = Date()) {
        self.sid = sid
        self.action = action
        self.sender = sender
        self.recipient = recipient
        self.from = from
        self.isFromAccount = isFromAccount
        self.timestamp = timestamp
    }

    private static func action(of element: Element) -> Action? {
        switch element.name {
        case "propose":
            let media = Set(element.filterChildren(name: "description", xmlns: rtp).compactMap { $0.getAttribute("media").flatMap(Media.init) })
            return media.isEmpty ? nil : .propose(media: media)
        case "ringing": return .ringing
        case "proceed": return .proceed
        case "accept": return .accept
        case "reject": return .reject(reason(in: element))
        case "retract": return .retract(reason(in: element))
        case "finish": return .finish(reason(in: element))
        default: return nil
        }
    }

    /// The first condition we know. Others, and the `<device>` of Conversations'
    /// `proceed` (the DTLS verification of a later stage), are left alone.
    static func reason(in element: Element) -> CallReason? {
        element.firstChild(name: "reason")?.children.lazy.compactMap { CallReason(rawValue: $0.name) }.first
    }

    /// The session a delivery receipt for our `propose` is about.
    static func proposeReceipt(in stanza: Martin.Message) -> String? {
        guard let id = stanza.firstChild(name: "received", xmlns: NS.receipts)?.getAttribute("id"),
              id.hasPrefix(OutboundStanza.proposeIdPrefix) else { return nil }
        return String(id.dropFirst(OutboundStanza.proposeIdPrefix.count))
    }
}
