import Foundation
import Martin

/// One error a server (or the connection to it) answered with, independent of
/// Martin. It tells apart what can pass by itself (a timeout, a dropped
/// connection, a `wait` error), which is retried, from what is final, which is
/// shown to the user.
public struct ServerError: Error, Equatable, Sendable {
    /// RFC 6120 §8.3.2: what the sender should do about the error.
    public enum ErrorType: String, Sendable {
        case cancel, `continue`, modify, auth, wait
    }

    /// The defined condition's name, such as `forbidden`; one we don't know
    /// is kept as the server wrote it.
    public var condition: String
    public var type: ErrorType
    /// The server's `<text>`, trimmed, if it sent any.
    public var text: String?
    /// A condition beside the defined one, such as a pubsub error's.
    public var detail: String?

    public init(condition: String, type: ErrorType? = nil, text: String? = nil, detail: String? = nil) {
        // Only a condition RFC 6120 defines is shown: the sender of an error
        // can be anyone able to send as the peer, and a made-up name would
        // reach the user's screen.
        self.condition = ErrorCondition(rawValue: condition) == nil ? "undefined-condition" : condition
        // Martin's table is RFC 6120 §8.3.3's. A condition it doesn't know is
        // `cancel`: nothing says it will pass.
        self.type = type ?? ErrorCondition(rawValue: condition).flatMap { ErrorType(rawValue: $0.type) } ?? .cancel
        self.text = Self.cleaned(text)
        self.detail = detail
    }

    /// From an `<error>` element, or a stanza that has one. A missing or
    /// unknown `type` takes the condition's default.
    public init?(_ element: Element) {
        guard let error = Self.errorElement(of: element) else { return nil }
        self.init(
            condition: Self.conditionElement(in: error)?.name ?? "undefined-condition",
            type: error.getAttribute("type").flatMap(ErrorType.init(rawValue:)),
            text: Self.stanzaChildren(of: error).first { $0.name == "text" }?.value,
        )
    }

    /// The error a bounced stanza carries; a bare `<error/>` or none is undefined.
    public static func bounce(of stanza: Martin.Message) -> ServerError {
        ServerError(stanza.element) ?? ServerError(condition: "undefined-condition")
    }

    /// The condition `element`'s error names, or nil if it names none (a bare
    /// `<error/>`), as `ServerError` would read it.
    public static func declaredCondition(in element: Element) -> String? {
        guard let error = errorElement(of: element), conditionElement(in: error) != nil else { return nil }
        return ServerError(element)?.condition
    }

    private static func errorElement(of element: Element) -> Element? {
        element.name == "error" ? element : element.firstChild(name: "error")
    }

    private static func stanzaChildren(of error: Element) -> [Element] {
        error.children.filter { $0.xmlns == "urn:ietf:params:xml:ns:xmpp-stanzas" }
    }

    /// <text> shares the namespace and may come first.
    private static func conditionElement(in error: Element) -> Element? {
        stanzaChildren(of: error).first { $0.name != "text" }
    }

    /// Martin's `XMPPError` is an enum that keeps the condition and text but
    /// not the `type`, so this falls back on the condition's own; it is left
    /// as it is rather than reshaped to carry one.
    /// The server's own type is lost here, and an internal error is what a
    /// restarting service answers with `wait`, so it is taken as passing.
    public init(_ error: XMPPError) {
        let condition = error.errorCondition
        self.init(condition: condition.rawValue, type: condition == .internal_server_error ? .wait : nil, text: error.message)
    }

    public init(_ error: PubSubError) {
        self.init(
            condition: error.error.errorCondition.rawValue, type: error.errorType.flatMap(ErrorType.init(rawValue:)),
            text: error.error.message, detail: error.pubsubErrorCondition?.rawValue,
        )
    }

    /// An error a server answered with, or nil for any other, such as one of
    /// the connection or of our own.
    public init?(_ error: Error) {
        switch error {
        case let error as ServerError: self = error
        case let error as PubSubError: self.init(error)
        case let error as XMPPError: self.init(error)
        case let condition as ErrorCondition: self.init(condition: condition.rawValue)
        default: return nil
        }
    }

    /// Any error a request can fail with, as one question to ask. What isn't
    /// from a server and isn't a connection that passes is final, so it is
    /// shown rather than retried.
    public static func classify(_ error: Error) -> ServerError {
        if let error = ServerError(error) { return error }
        switch error {
        case is TimeoutError: return ServerError(condition: "remote-server-timeout")
        case let error as URLError:
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost, .dataNotAllowed:
                return ServerError(condition: "remote-server-timeout", type: .wait)
            default: break
            }
        default: break
        }
        return ServerError(condition: "undefined-condition", type: .cancel)
    }

    /// Can't be fixed by trying again unchanged: `cancel`, `modify` and `auth`.
    public var isFinal: Bool {
        switch type {
        case .cancel, .modify, .auth: true
        case .wait, .continue: false
        }
    }

    /// May go away by itself, so it is retried without asking.
    public var isPassing: Bool { !isFinal }

    /// The server or entity doesn't offer what was asked.
    public var isUnsupported: Bool {
        condition == "feature-not-implemented" || condition == "service-unavailable"
    }

    public var isNotFound: Bool { condition == "item-not-found" }

    /// `friendly` followed by what the server said, such as "The message
    /// couldn't be delivered: User session not found (recipient-unavailable)".
    public func describe(_ friendly: String) -> String {
        var lead = friendly.trimmingCharacters(in: .whitespacesAndNewlines)
        while lead.hasSuffix(".") { lead.removeLast() }
        let names = detail.map { "\(condition), \($0)" } ?? condition
        if let text { return "\(lead): \(text) (\(names))" }
        return "\(lead) (\(names))"
    }

    /// Long enough for any sentence a server means to be read, short enough
    /// that one can't fill an alert.
    static let maxTextLength = 300

    private static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Control and format characters (bidi overrides among them) could
        // make the text read as something else.
        let shown = String(String.UnicodeScalarView(line.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned: false
            default: true
            }
        }))
        return shown.isEmpty ? nil : String(shown.prefix(maxTextLength))
    }
}
