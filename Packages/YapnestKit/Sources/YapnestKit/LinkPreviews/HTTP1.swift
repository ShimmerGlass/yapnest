import Foundation

/// How much of a response a fetch reads.
struct FetchLimits: Sendable {
    /// Larger bodies are refused up front when the server announces the size.
    var maxBytes: Int
    /// HTML is cut off at this size instead; its metadata is at the start.
    var maxHTMLBytes: Int
    /// Stop HTML after `</head>`, where the metadata ends.
    var stopAtEndOfHead: Bool
}

enum HTTP1 {
    static let userAgent = "WhatsApp/2"

    /// The request for one resource. `Connection: close` keeps the parser
    /// from having to find where a response ends on a reused connection.
    static func request(host: String, target: String) -> Data {
        let hostHeader = host.contains(":") ? "[\(host)]" : host
        let lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            // Many sites only serve OpenGraph tags to known link-preview bots;
            // Signal uses the same user agent for the same reason.
            "User-Agent: \(userAgent)",
            "Accept: text/html,image/*;q=0.9,*/*;q=0.5",
            "Accept-Encoding: identity",
            "Connection: close",
            "", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// The media type and charset of a `Content-Type` value.
    static func parseContentType(_ value: String?) -> (mimeType: String?, charset: String?) {
        guard let value else { return (nil, nil) }
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        let mime = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        var charset: String?
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "charset" {
                charset = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return (mime.isEmpty ? nil : mime, charset)
    }
}

/// An incremental HTTP/1.1 response reader: status line, headers, and a body
/// framed by `Content-Length`, chunking, or the connection closing.
struct HTTP1ResponseParser {
    static let maxHeadBytes = 32 * 1024
    static let maxHeaders = 100
    private static let maxLineBytes = 1024

    enum Failure: Error, Equatable {
        case malformed, headTooLarge, tooManyHeaders, tooLarge, unsupported
    }

    struct Head: Equatable {
        var status: Int
        /// Lowercased names; repeated headers are joined with ", ".
        var headers: [String: String]
    }

    private enum State {
        case head, fixed(Int), chunkSize, chunk(Int), chunkEnd, trailers, untilClose, done
    }

    private let limits: FetchLimits
    private var state = State.head
    private var buffer: [UInt8] = []
    private var bodyLimit = 0
    private var isHTML = false
    private var trailerBytes = 0
    private var searched = 0

    private(set) var head: Head?
    private(set) var body = Data()

    init(limits: FetchLimits) {
        self.limits = limits
    }

    var isComplete: Bool {
        if case .done = state { return true }
        return false
    }

    mutating func receive(_ data: Data) throws {
        guard !isComplete else { return }
        buffer.append(contentsOf: data)
        while !isComplete, try advance() {}
    }

    /// The connection closed.
    mutating func receiveEnd() throws {
        switch state {
        case .done: return
        case .untilClose: state = .done
        default: throw Failure.malformed
        }
    }

    /// Returns whether it made progress.
    private mutating func advance() throws -> Bool {
        switch state {
        case .head:
            guard let end = Self.find([13, 10, 13, 10], in: buffer) else {
                if buffer.count > Self.maxHeadBytes { throw Failure.headTooLarge }
                return false
            }
            guard end + 4 <= Self.maxHeadBytes else { throw Failure.headTooLarge }
            let block = Array(buffer[..<end])
            buffer.removeFirst(end + 4)
            try parseHead(block)
            return true

        case .fixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let count = takeBody(remaining)
            if !isComplete { state = remaining == count ? .done : .fixed(remaining - count) }
            return true

        case .untilClose:
            guard !buffer.isEmpty else { return false }
            let taken = buffer
            buffer.removeAll()
            append(taken[...])
            return true

        case .chunkSize:
            guard let end = Self.find([13, 10], in: buffer) else {
                if buffer.count > Self.maxLineBytes { throw Failure.malformed }
                return false
            }
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeFirst(end + 2)
            // Chunk extensions come after a semicolon and carry nothing we use.
            let digits = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy(\.isHexDigit), let size = Int(digits, radix: 16) else {
                throw Failure.malformed
            }
            state = size == 0 ? .trailers : .chunk(size)
            return true

        case .chunk(let remaining):
            guard !buffer.isEmpty else { return false }
            let count = takeBody(remaining)
            if !isComplete { state = remaining == count ? .chunkEnd : .chunk(remaining - count) }
            return true

        case .chunkEnd:
            guard buffer.count >= 2 else { return false }
            guard buffer[0] == 13, buffer[1] == 10 else { throw Failure.malformed }
            buffer.removeFirst(2)
            state = .chunkSize
            return true

        case .trailers:
            guard let end = Self.find([13, 10], in: buffer) else {
                if trailerBytes + buffer.count > Self.maxHeadBytes { throw Failure.headTooLarge }
                return false
            }
            trailerBytes += end + 2
            if trailerBytes > Self.maxHeadBytes { throw Failure.headTooLarge }
            buffer.removeFirst(end + 2)
            if end == 0 { state = .done }
            return true

        case .done:
            return false
        }
    }

    /// Moves up to `remaining` buffered bytes into the body, and returns how
    /// many.
    private mutating func takeBody(_ remaining: Int) -> Int {
        let count = min(remaining, buffer.count)
        let taken = buffer.prefix(count)
        buffer.removeFirst(count)
        append(taken)
        return count
    }

    private mutating func parseHead(_ block: [UInt8]) throws {
        let text = String(decoding: block, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), statusLine[1].count == 3,
              let status = Int(statusLine[1]) else { throw Failure.malformed }
        guard lines.count <= Self.maxHeaders else { throw Failure.tooManyHeaders }

        var headers: [String: String] = [:]
        for line in lines {
            // Folded continuation lines are obsolete and a smuggling vector.
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t", colon != line.startIndex else {
                throw Failure.malformed
            }
            let name = line[..<colon].lowercased()
            guard !name.contains(where: { $0 == " " || $0 == "\t" }) else { throw Failure.malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }

        // Interim responses come before the real one.
        if (100..<200).contains(status) {
            guard status != 101 else { throw Failure.unsupported }
            return
        }
        head = Head(status: status, headers: headers)

        // Only successful responses have a body worth reading; redirects and
        // errors are judged by their headers.
        guard (200..<300).contains(status), status != 204 else {
            state = .done
            return
        }
        if let encoding = headers["content-encoding"], encoding.lowercased() != "identity" { throw Failure.unsupported }

        let mime = HTTP1.parseContentType(headers["content-type"]).mimeType ?? ""
        isHTML = mime.hasPrefix("text/html") || mime == "application/xhtml+xml"
        bodyLimit = isHTML ? limits.maxHTMLBytes : limits.maxBytes

        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked" else { throw Failure.unsupported }
            state = .chunkSize
        } else if let length = headers["content-length"] {
            let values = Set(length.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard values.count == 1, let text = values.first, !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
                  let size = Int(text) else { throw Failure.malformed }
            guard size <= limits.maxBytes else { throw Failure.tooLarge }
            state = size == 0 ? .done : .fixed(size)
        } else {
            state = .untilClose
        }
    }

    /// Adds body bytes up to the limit, and ends the body at `</head>` if asked.
    private mutating func append(_ bytes: ArraySlice<UInt8>) {
        body.append(contentsOf: bytes.prefix(bodyLimit - body.count))
        if body.count >= bodyLimit {
            state = .done
            return
        }
        guard limits.stopAtEndOfHead, isHTML else { return }
        let marker = Array("</head>".utf8)
        let start = max(0, searched - marker.count + 1)
        let unsearched = [UInt8](body.suffix(from: body.startIndex + start))
        var i = 0
        while i + marker.count <= unsearched.count {
            if (0..<marker.count).allSatisfy({ Self.lower(unsearched[i + $0]) == marker[$0] }) {
                body = body.prefix(start + i + marker.count)
                state = .done
                return
            }
            i += 1
        }
        searched = body.count
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] && haystack[i..<(i + needle.count)].elementsEqual(needle) {
            return i
        }
        return nil
    }
}
