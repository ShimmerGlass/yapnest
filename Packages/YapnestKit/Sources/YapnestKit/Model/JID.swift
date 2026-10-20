import Foundation
import GRDB

/// A bare JID (`local@domain`), normalized so it can be used as a key.
///
/// Normalization is lowercasing of the local part and domain, which covers
/// what servers produce in practice. Full PRECIS (RFC 7622) can replace it later
/// without touching callers.
public struct JID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let localPart: String?
    public let domain: String

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if let slash = s.firstIndex(of: "/") {
            s = s[..<slash]
        }
        let local: Substring?
        let domain: Substring
        if let at = s.firstIndex(of: "@") {
            local = s[..<at]
            domain = s[s.index(after: at)...]
        } else {
            local = nil
            domain = s
        }
        guard !domain.isEmpty, !domain.contains("@") else { return nil }
        if let local, local.isEmpty { return nil }
        self.localPart = local.map { $0.lowercased() }
        self.domain = domain.lowercased()
    }

    /// A JID with a local part, which is what a person or a room has; a bare
    /// domain is a server. For addresses people type.
    public init?(userAddress string: String) {
        guard let jid = JID(string), jid.localPart != nil else { return nil }
        self = jid
    }

    /// For addresses people paste: an `xmpp:` link works too, with or
    /// without a query such as `?join`.
    public init?(pastedAddress text: String) {
        self.init(userAddress: Self.unwrapped(text))
    }

    /// For the New Chat field: what `init(pastedAddress:)` takes, and also a
    /// bare domain, which is how a gateway such as a WhatsApp bridge is
    /// addressed. A word with no dot stays refused, as the field also
    /// filters contacts and a name typed there isn't a server.
    public init?(chatAddress text: String) {
        let text = Self.unwrapped(text)
        if let jid = JID(userAddress: text) {
            self = jid
            return
        }
        guard let jid = JID(text), jid.localPart == nil,
              jid.domain.contains("."), !jid.domain.hasPrefix("."), !jid.domain.hasSuffix("."),
              !jid.domain.contains(where: \.isWhitespace) else { return nil }
        self = jid
    }

    private static func unwrapped(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("xmpp:") { text = String(text.dropFirst(5)) }
        if text.hasPrefix("//") { text = String(text.dropFirst(2)) }
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        return text
    }

    /// What to call a JID when nothing better is known.
    public var shortName: String { localPart ?? description }

    public var description: String {
        localPart.map { "\($0)@\(domain)" } ?? domain
    }

    public static func < (lhs: JID, rhs: JID) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let jid = JID(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid JID: \(string)"))
        }
        self = jid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension JID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> JID? {
        String.fromDatabaseValue(dbValue).flatMap(JID.init(_:))
    }
}
