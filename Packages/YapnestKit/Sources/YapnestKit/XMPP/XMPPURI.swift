import Foundation

/// An `xmpp:` link (RFC 5122, XEP-0147) that asks the app to do something
/// with an address, such as the invitations Snikket hands out (XEP-0401).
/// Links come from strangers, so anything odd is refused rather than
/// repaired: the user is only shown what was parsed here.
public struct XMPPURI: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        /// No action, `?message` or one we don't know: a chat. A body is
        /// only ever put in the composer.
        case chat(body: String?)
        /// `?roster` and `?subscribe`. The token is a pre-authorization
        /// (XEP-0379) that lets the inviter's server approve us.
        case addContact(name: String?, preauth: String?)
        /// `?join`. A `password` parameter is ignored: joining can't use one.
        case join
    }

    /// Always bare: a resource says which device they were on, not who.
    public let jid: JID
    public let action: Action

    static let maxLength = 2048
    static let maxBodyLength = 2000
    static let maxNameLength = 100
    static let maxTokenLength = 256

    public init(jid: JID, action: Action) {
        self.jid = jid
        self.action = action
    }

    public init?(_ url: URL) {
        self.init(url.absoluteString)
    }

    /// Parses from the text rather than `URL`, which refuses the unescaped
    /// non-ASCII an IRI has.
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maxLength, text.lowercased().hasPrefix("xmpp:"),
              !text.unicodeScalars.contains(where: Self.isControl) else { return nil }
        var rest = Substring(text.dropFirst(5))
        // The fragment isn't part of the request.
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        // `xmpp://account@host/jid` names the account to act as. We have one
        // account, so it's skipped.
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = rest[rest.index(after: slash)...]
        }
        var path = rest
        var query: Substring = ""
        if let mark = rest.firstIndex(of: "?") {
            path = rest[..<mark]
            query = rest[rest.index(after: mark)...]
        }
        guard let address = path.removingPercentEncoding, let jid = Self.jid(from: address) else { return nil }

        // RFC 5122 separates with ";", and "&" is what links written by
        // hand often use.
        var parts = query.split(omittingEmptySubsequences: false) { $0 == ";" || $0 == "&" }
        let name = parts.isEmpty ? "" : parts.removeFirst().lowercased()
        var parameters: [String: String] = [:]
        for part in parts where !part.isEmpty {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair[0].removingPercentEncoding?.lowercased(),
                  let value = (pair.count > 1 ? pair[1] : "").removingPercentEncoding else { return nil }
            // The first of a repeated parameter counts.
            if parameters[key] == nil { parameters[key] = value }
        }

        do {
            switch name {
            case "roster", "subscribe":
                action = .addContact(
                    name: try Self.text(parameters["name"], maxLength: Self.maxNameLength),
                    preauth: try Self.token(parameters["preauth"]),
                )
            case "join":
                action = .join
            default:
                let body = try Self.text(parameters["body"], maxLength: Self.maxBodyLength, multiline: true)
                action = .chat(body: name == "message" ? body : nil)
            }
        } catch {
            return nil
        }
        self.jid = jid
    }

    // MARK: Pieces

    private struct Refused: Error {}

    /// A parameter's text; nil when it's absent or blank. A text that is too
    /// long, or holds controls or invisible characters, refuses the link.
    private static func text(_ raw: String?, maxLength: Int, multiline: Bool = false) throws -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard raw.count <= maxLength, !raw.unicodeScalars.contains(where: isHiddenInText) else { throw Refused() }
        for scalar in raw.unicodeScalars where isControl(scalar) {
            // Line breaks are the one control a message body may hold.
            guard multiline, scalar == "\n" || scalar == "\r" else { throw Refused() }
        }
        return raw.isEmpty ? nil : raw
    }

    /// A pre-auth token (XEP-0379) is opaque, but real ones are plain ASCII.
    private static func token(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~+/=")
        guard raw.count <= maxTokenLength, raw.unicodeScalars.allSatisfy(allowed.contains) else { throw Refused() }
        return raw
    }

    /// The address with a local part, such as `juliet@example.com/balcony`,
    /// as a bare JID. RFC 7622 keeps these characters out of a local part,
    /// and whitespace or direction overrides could make an address look like
    /// another in the confirmation.
    private static func jid(from address: String) -> JID? {
        let forbidden = CharacterSet(charactersIn: "\"&'/:<>").union(.whitespacesAndNewlines)
        guard let jid = JID(userAddress: address),
              !address.unicodeScalars.contains(where: { isControl($0) || isFormatting($0) }) else { return nil }
        let bare = jid.description
        guard !bare.unicodeScalars.contains(where: forbidden.contains),
              !jid.domain.hasPrefix("."), !jid.domain.hasSuffix("."),
              jid.domain.count <= 1023, (jid.localPart?.count ?? 0) <= 1023 else { return nil }
        return jid
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    /// What a name or body may not hold. Format characters are mostly fine
    /// here: emoji sequences need the joiner, variation selectors and tag
    /// characters, Persian needs the non-joiner, and a soft hyphen is plain
    /// text. The ones that can make text read as something else are the
    /// bidirectional embeddings, overrides, isolates and marks, and the
    /// interlinear annotations, which hide text between their marks.
    /// Unassigned characters are fine too: an emoji newer than this system's
    /// Unicode tables is one, and it would refuse a legitimate link. A JID
    /// has no such need, and keeps the strict check.
    static func isHiddenInText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C, 0xFFF9...0xFFFB: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .format, .unassigned: return false
        default: return isFormatting(scalar)
        }
    }

    /// Invisible characters, which include the bidirectional overrides.
    private static func isFormatting(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: true
        default: false
        }
    }
}
