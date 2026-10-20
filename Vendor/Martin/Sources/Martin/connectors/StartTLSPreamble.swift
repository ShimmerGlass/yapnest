//
// StartTLSPreamble.swift
//
// Not part of upstream Martin. See Vendor/README.md.
//

import Foundation

/// What the client says and expects before TLS starts on a STARTTLS
/// connection (RFC 6120 5.4): open a stream, read the features, ask for
/// STARTTLS, read `<proceed/>`. `StartTLSFramer` runs it under the TLS layer
/// of a connection; it is kept apart from Network.framework so it can be
/// tested on its own.
///
/// It reads the server's side as text, not as XML: every answer it needs is
/// one small element, and the bytes after `<proceed/>` have to be told apart
/// from it by position, which a parser doesn't give.
struct StartTLSPreamble {

    enum Step: Equatable {
        /// Nothing to decide yet.
        case needMore
        /// The server offers STARTTLS: send `StartTLSPreamble.request`.
        case sendStartTLS
        /// The server agreed and said nothing else; TLS starts now.
        case proceed
        case fail(Failure)
    }

    enum Failure: Error, Equatable {
        /// The features don't offer STARTTLS. With TLS required that is a
        /// refusal, never a reason to carry on in the clear.
        case notOffered
        /// The server answered `<failure/>`.
        case refused
        /// The server ended the stream with an error.
        case streamError
        /// Something that is neither what we waited for nor valid there.
        case unexpected
        /// Bytes after `<proceed/>`. The server waits for the handshake, so
        /// they came from someone else, in the clear (RFC 6120 5.4.3.3).
        case dataAfterProceed
        /// The connection ended before TLS started.
        case closed
        /// More than any real server sends here.
        case tooLarge
    }

    static let tlsNamespace = "urn:ietf:params:xml:ns:xmpp-tls"
    static let request = Data("<starttls xmlns='\(tlsNamespace)'/>".utf8)
    private static let limit = 64 * 1024

    /// The stream header that opens the exchange.
    static func streamHeader(to domain: String) -> Data {
        Data("<?xml version='1.0'?><stream:stream to='\(escaped(domain))' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>".utf8)
    }

    private enum Phase { case features, proceed, done }
    private var phase = Phase.features
    private var received = Data()

    /// Feeds what the server sent. After a `.proceed` or a `.fail` it only
    /// repeats that answer.
    mutating func receive(_ data: Data) -> Step {
        switch phase {
        case .done: return finished
        case .features, .proceed: break
        }
        received.append(data)
        guard received.count <= Self.limit else { return finish(.fail(.tooLarge)) }
        let text = String(decoding: received, as: UTF8.self)
        switch phase {
        case .features: return readFeatures(text)
        case .proceed: return readAnswer(text)
        case .done: return finished
        }
    }

    /// The connection ended.
    mutating func receiveEnd() -> Step {
        phase == .done ? finished : finish(.fail(.closed))
    }

    private var finished = Step.needMore

    private mutating func finish(_ step: Step) -> Step {
        phase = .done
        received = Data()
        finished = step
        return step
    }

    // MARK: Features

    private mutating func readFeatures(_ text: String) -> Step {
        if Self.hasStreamError(text) { return finish(.fail(.streamError)) }
        guard let features = Self.firstMatch(Self.featuresPattern, in: text) else { return .needMore }
        // The server has nothing more to say until we ask.
        if !Self.isBlank(text[features.upperBound...]) { return finish(.fail(.unexpected)) }
        guard Self.offersStartTLS(String(text[features])) else { return finish(.fail(.notOffered)) }
        phase = .proceed
        received = Data()
        return .sendStartTLS
    }

    private static let featuresPattern = #"<(?:[\w.-]+:)?features\s*/>|<(?:[\w.-]+:)?features[\s>][\s\S]*?</(?:[\w.-]+:)?features\s*>"#
    private static let startTLSPattern = #"<(?:[\w.-]+:)?starttls\s[^>]*?xmlns\s*=\s*(?:'\#(tlsNamespace)'|"\#(tlsNamespace)")"#

    private static func offersStartTLS(_ features: String) -> Bool {
        firstMatch(startTLSPattern, in: features) != nil
    }

    // MARK: The answer

    private mutating func readAnswer(_ text: String) -> Step {
        if Self.hasStreamError(text) { return finish(.fail(.streamError)) }
        let body = text.drop(while: { $0.isWhitespace })
        if body.isEmpty { return .needMore }
        guard body.hasPrefix("<") else { return finish(.fail(.unexpected)) }
        let element = String(body)

        if let proceed = Self.firstMatch(Self.proceedPattern, in: element), proceed.lowerBound == element.startIndex {
            return element[proceed.upperBound...].isEmpty ? finish(.proceed) : finish(.fail(.dataAfterProceed))
        }
        if Self.firstMatch(Self.failurePattern, in: element) != nil { return finish(.fail(.refused)) }
        // A tag we can't place yet, or one that can't be either answer.
        if let end = element.firstIndex(of: ">") {
            let tag = element[...end]
            // `<proceed ...>` waiting for its end tag.
            if tag.hasPrefix("<proceed") || tag.contains(":proceed"), !tag.hasSuffix("/>") { return .needMore }
            return finish(.fail(.unexpected))
        }
        return .needMore
    }

    private static let proceedPattern = #"<(?:[\w.-]+:)?proceed\s[^>]*?xmlns\s*=\s*(?:'\#(tlsNamespace)'|"\#(tlsNamespace)")[^>]*?(?:/>|>\s*</(?:[\w.-]+:)?proceed\s*>)"#
    private static let failurePattern = #"^<(?:[\w.-]+:)?failure[\s/>]"#

    // MARK: Text

    private static func hasStreamError(_ text: String) -> Bool {
        firstMatch(#"<(?:[\w.-]+:)?error[\s/>]"#, in: text) != nil
    }

    private static func isBlank(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
