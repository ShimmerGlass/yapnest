import Foundation
@preconcurrency import Martin

extension Iq {
    /// An iq of `type` to `jid`, or to our own account without one, carrying `child`.
    static func make(_ type: StanzaType, to jid: Martin.JID?, _ child: Element) -> Iq {
        let iq = Iq()
        iq.type = type
        if let jid { iq.to = jid }
        iq.addChild(child)
        return iq
    }

    static func set(to jid: Martin.JID, _ child: Element) -> Iq {
        make(.set, to: jid, child)
    }

    /// A Jingle action (XEP-0166) for the session `sid`. Files and calls both
    /// build theirs here.
    static func jingle(to jid: Martin.JID, action: String, sid: String, attributes: [String: String] = [:], children: [Element] = []) -> Iq {
        set(to: jid, .jingle(action: action, sid: sid, attributes: attributes, children: children))
    }
}

extension Element {
    /// The `<jingle/>` element of `Iq.jingle`, for an action whose element is
    /// changed before it is sent.
    static func jingle(action: String, sid: String, attributes: [String: String] = [:], children: [Element] = []) -> Element {
        let jingle = Element(name: "jingle", xmlns: JingleModule.XMLNS)
        jingle.setAttribute("action", value: action)
        jingle.setAttribute("sid", value: sid)
        for (name, value) in attributes { jingle.setAttribute(name, value: value) }
        for child in children { jingle.addChild(child) }
        return jingle
    }
}

extension Element {
    /// The first condition in the `<reason>` that `R` knows. Others are left alone.
    func reason<R: RawRepresentable>(as type: R.Type) -> R? where R.RawValue == String {
        firstChild(name: "reason")?.children.lazy.compactMap { R(rawValue: $0.name) }.first
    }
}
