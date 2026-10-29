import Foundation
@preconcurrency import Martin

/// What an HTTP File Upload service (XEP-0363) answers a slot request with.
struct UploadSlot: Sendable {
    var getURL: URL
    var putURL: URL
    /// Only the headers XEP-0363 §6 lets a service ask for, one line each.
    var putHeaders: [String: String]
}

/// A refused slot request, with the two details XEP-0363 §4.3 adds to the
/// stanza error. Martin's `XMPPError` keeps neither.
struct UploadSlotError: Error {
    var error: ServerError
    /// A `file-too-large` error: the service won't take a file this size.
    var isFileTooLarge: Bool
    /// The `max-file-size` it named, in bytes.
    var maxFileSize: Int?
    /// The `retry` element's stamp: when to ask again.
    var retryAt: Date?
}

enum UploadSlotParser {
    static let namespace = "urn:xmpp:http:upload:0"

    /// The only headers a client may pass on from a slot (XEP-0363 §6): any
    /// other could change what the PUT does, or reach another host's
    /// credentials.
    static let allowedHeaders: Set<String> = ["authorization", "cookie", "expires"]

    /// `headers` reduced to the allowed ones, with the line breaks a value
    /// could use to start another header taken out.
    static func allowed(_ headers: [(name: String, value: String)]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedHeaders.contains(name.lowercased()) else { continue }
            let line = String(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { result[name] = line }
        }
        return result
    }

    static func slot(from iq: Iq) -> UploadSlot? {
        guard let slot = iq.firstChild(name: "slot", xmlns: namespace),
              let get = slot.firstChild(name: "get")?.getAttribute("url"), let put = slot.firstChild(name: "put")?.getAttribute("url"),
              let getURL = URL(string: get.replacingOccurrences(of: " ", with: "%20")), let putURL = URL(string: put.replacingOccurrences(of: " ", with: "%20"))
        else { return nil }
        let headers = slot.firstChild(name: "put")?.filterChildren(name: "header", xmlns: nil).compactMap { header -> (name: String, value: String)? in
            guard let name = header.getAttribute("name"), let value = header.value else { return nil }
            return (name, value)
        } ?? []
        return UploadSlot(getURL: getURL, putURL: putURL, putHeaders: allowed(headers))
    }

    /// The error decoder for a slot request. No answer is a timeout.
    static func error(from stanza: Stanza?) -> Error {
        guard let stanza else { return UploadSlotError(error: ServerError.timedOut, isFileTooLarge: false) }
        let details = stanza.firstChild(name: "error")
        let tooLarge = details?.firstChild(name: "file-too-large", xmlns: namespace)
        let retry = details?.firstChild(name: "retry", xmlns: namespace)
        return UploadSlotError(
            error: ServerError(stanza.element) ?? ServerError(condition: "undefined-condition"),
            isFileTooLarge: tooLarge != nil,
            maxFileSize: tooLarge?.firstChild(name: "max-file-size")?.value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            retryAt: retry?.getAttribute("stamp").flatMap(date(from:)),
        )
    }

    private static func date(from stamp: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: stamp) ?? fractional.date(from: stamp)
    }
}

extension ServerError {
    /// What a file host's HTTP status stands for. The ones that pass: a
    /// request timeout, too many requests, and a server error that is not a
    /// refusal to ever take the request. The rest is final, though not a
    /// server's XMPP error; `text` is its phrase.
    static func http(status: Int) -> ServerError {
        let text = HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 408: return ServerError(condition: "remote-server-timeout", type: .wait, text: text)
        case 429: return ServerError(condition: "resource-constraint", type: .wait, text: text)
        case 500, 502, 503, 504: return ServerError(condition: "internal-server-error", type: .wait, text: text)
        default: return ServerError(condition: "undefined-condition", type: .cancel, text: text)
        }
    }
}
