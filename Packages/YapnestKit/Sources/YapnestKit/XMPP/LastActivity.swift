import Foundation
@preconcurrency import Martin

/// Last activity (XEP-0012). Opt-in and reciprocal: when the user shares
/// theirs, contacts may ask us how long we've been idle, and we ask offline
/// contacts' servers when they were last online. Idle-in-presence (XEP-0319)
/// is left out, as presence goes to every contact and can't be limited.
enum LastActivity {
    /// Whether `requester` is a contact who sees our presence anyway, so
    /// telling them how long we've been idle gives nothing new away.
    static func mayAnswer(requester: Contact?) -> Bool {
        guard let requester, requester.isInRoster else { return false }
        return requester.subscription == .from || requester.subscription == .both
    }

    /// The seconds in a result, nil when it isn't one.
    static func seconds(in iq: Element) -> Int? {
        guard let query = iq.firstChild(name: "query", xmlns: NS.last),
              let seconds = query.getAttribute("seconds").flatMap({ Int($0) }), seconds >= 0 else { return nil }
        return seconds
    }
}

/// When to ask a contact's server for their last seen again. Servers that
/// refuse once are left alone for the session, as asking again won't change
/// the answer and each query tells the server we're curious.
struct LastSeenSchedule {
    static let refreshInterval: TimeInterval = 5 * 60

    private var asked: [JID: Date] = [:]
    private var refused: Set<JID> = []
    private var sawLeave: Set<JID> = []

    /// We watched `jid` go offline, so we know when they were last seen and
    /// their server can't tell us better.
    mutating func sawLeaving(_ jid: JID) { sawLeave.insert(jid) }

    /// `jid` is back, and the last departure we saw no longer says it all.
    mutating func sawArriving(_ jid: JID) { sawLeave.remove(jid) }

    mutating func forgetDepartures() { sawLeave = [] }

    /// Whether to ask now. A yes counts as asking, so two callers at once
    /// send one query.
    mutating func claim(_ jid: JID, now: Date) -> Bool {
        guard !refused.contains(jid), !sawLeave.contains(jid) else { return false }
        if let last = asked[jid], now.timeIntervalSince(last) < Self.refreshInterval { return false }
        asked[jid] = now
        return true
    }

    mutating func refuse(_ jid: JID) { refused.insert(jid) }

    /// Forgets everything, as when the user stops sharing and starts again.
    mutating func reset() {
        asked = [:]
        refused = []
        sawLeave = []
    }
}

/// Answers `jabber:iq:last` queries to our full address. `answer` gets the
/// requester and returns the seconds, or nil to refuse. A refusal is the
/// error for a feature we don't have, so it doesn't tell a stranger that we
/// have one, nor why we won't.
final class LastActivityModule: XmppModuleBase, AbstractIQModule, @unchecked Sendable {
    static let ID = NS.last
    static let IDENTIFIER = XmppModuleIdentifier<LastActivityModule>()

    let criteria = Criteria.name("iq").add(Criteria.name("query", xmlns: NS.last))
    private let isOffered: @Sendable () -> Bool
    private let answer: @Sendable (JID) -> Int?

    /// Advertised only while the user shares: capabilities are the account's,
    /// not a contact's, so every contact who looks sees it.
    var features: [String] { isOffered() ? [NS.last] : [] }

    init(isOffered: @escaping @Sendable () -> Bool, answer: @escaping @Sendable (JID) -> Int?) {
        self.isOffered = isOffered
        self.answer = answer
    }

    func processGet(stanza: Stanza) throws {
        guard let from = stanza.from.flatMap({ JID($0.bareJid.stringValue) }), let seconds = answer(from) else {
            throw ErrorCondition.feature_not_implemented
        }
        let result = stanza.makeResult(type: .result)
        let query = Element(name: "query", xmlns: NS.last)
        query.setAttribute("seconds", value: String(seconds))
        result.addChild(query)
        write(result)
    }

    func processSet(stanza: Stanza) throws {
        throw ErrorCondition.feature_not_implemented
    }
}
