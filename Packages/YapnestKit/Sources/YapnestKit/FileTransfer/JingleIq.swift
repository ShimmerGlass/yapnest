import Foundation
@preconcurrency import Martin

extension Iq {
    /// A set iq to `jid` carrying `child`.
    static func set(to jid: Martin.JID, _ child: Element) -> Iq {
        let iq = Iq()
        iq.to = jid
        iq.type = .set
        iq.addChild(child)
        return iq
    }

    /// A Jingle action (XEP-0166) for the session `sid`. Files and calls both
    /// build theirs here.
    static func jingle(to jid: Martin.JID, action: String, sid: String, attributes: [String: String] = [:], children: [Element] = []) -> Iq {
        let jingle = Element(name: "jingle", xmlns: JingleModule.XMLNS)
        jingle.setAttribute("action", value: action)
        jingle.setAttribute("sid", value: sid)
        for (name, value) in attributes { jingle.setAttribute(name, value: value) }
        for child in children { jingle.addChild(child) }
        return set(to: jid, jingle)
    }
}

extension Element {
    /// The first condition in the `<reason>` that `R` knows. Others are left alone.
    func reason<R: RawRepresentable>(as type: R.Type) -> R? where R.RawValue == String {
        firstChild(name: "reason")?.children.lazy.compactMap { R(rawValue: $0.name) }.first
    }
}
