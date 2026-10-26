import Foundation

/// The OpenGraph (and fallback) metadata of an HTML page. A tolerant scan of
/// `<meta>` tags rather than a full parser: pages put these in `<head>`,
/// and plenty of them aren't well-formed.
struct OpenGraph: Equatable {
    var title: String?
    var description: String?
    var siteName: String?
    var image: URL?

    /// Only this much of a page is read. The tags sit in `<head>`, and the
    /// fetch already stops at its end, but a page without one can be a
    /// megabyte of whatever its author chose.
    static let maxScanned = 128 * 1024

    init(title: String? = nil, description: String? = nil, siteName: String? = nil, image: URL? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.image = image
    }

    /// - Parameter base: the page's URL, for resolving a relative image URL.
    init(html: String, base: URL) {
        let bytes = Array(html.utf8.prefix(Self.maxScanned))
        var meta: [String: String] = [:]
        var position = 0
        // Every step moves forward and the end of a tag is found once, so the
        // scan is linear. Regexes over `[^>]*` were quadratic on a page of
        // tags that never close.
        while let start = Self.find("<meta", in: bytes, from: position, wholeWord: true),
              let end = bytes[start...].firstIndex(of: UInt8(ascii: ">")) {
            position = end + 1
            let attributes = Self.attributes(in: bytes[(start + 5)..<end])
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(), let content = attributes["content"] else { continue }
            // The first occurrence wins, as with og:image arrays.
            if meta[key] == nil { meta[key] = content }
        }

        func value(_ keys: String...) -> String? {
            keys.lazy.compactMap { meta[$0].map(Self.clean) }.first { !$0.isEmpty }
        }

        var pageTitle: String?
        if let start = Self.find("<title", in: bytes, from: 0, wholeWord: true),
           let open = bytes[start...].firstIndex(of: UInt8(ascii: ">")),
           let close = Self.find("</title>", in: bytes, from: open + 1, wholeWord: false) {
            pageTitle = Self.clean(String(decoding: bytes[(open + 1)..<close], as: UTF8.self))
        }

        title = value("og:title", "twitter:title") ?? pageTitle.flatMap { $0.isEmpty ? nil : $0 }
        description = value("og:description", "twitter:description", "description")
        siteName = value("og:site_name")
        image = value("og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src")
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A)
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    /// The first ASCII case-insensitive `needle` at or after `from`. `wholeWord`
    /// refuses `<metadata` for `<meta`, as a regex's `\b` would.
    private static func find(_ needle: String, in bytes: [UInt8], from: Int, wholeWord: Bool) -> Int? {
        let needle = Array(needle.utf8)
        guard bytes.count >= needle.count, from <= bytes.count - needle.count else { return nil }
        var i = from
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0] {
                var j = 1
                while j < needle.count, lowercased(bytes[i + j]) == needle[j] { j += 1 }
                let after = i + needle.count
                if j == needle.count, !wholeWord || after >= bytes.count || !isWordByte(bytes[after]) { return i }
            }
            i += 1
        }
        return nil
    }

    /// The `name=value` pairs in a tag's text, with names lowercased. Values
    /// are double-quoted, single-quoted or bare.
    private static func attributes(in tag: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        var i = tag.startIndex
        func skipSpace() { while i < tag.endIndex, isSpace(tag[i]) { i += 1 } }
        while i < tag.endIndex {
            let nameStart = i
            while i < tag.endIndex, isNameByte(tag[i]) { i += 1 }
            guard i > nameStart else { i += 1; continue }
            let name = tag[nameStart..<i]
            skipSpace()
            guard i < tag.endIndex, tag[i] == UInt8(ascii: "=") else { continue }
            i += 1
            skipSpace()
            guard i < tag.endIndex else { break }
            let valueStart: Int, valueEnd: Int
            if tag[i] == UInt8(ascii: "\"") || tag[i] == UInt8(ascii: "'") {
                guard let close = tag[(i + 1)...].firstIndex(of: tag[i]) else { i += 1; continue }
                valueStart = i + 1
                valueEnd = close
                i = close + 1
            } else {
                valueStart = i
                while i < tag.endIndex, !isSpace(tag[i]), tag[i] != UInt8(ascii: "\""), tag[i] != UInt8(ascii: "'") { i += 1 }
                valueEnd = i
                guard valueEnd > valueStart else { continue }
            }
            result[String(decoding: name, as: UTF8.self).lowercased()] = String(decoding: tag[valueStart..<valueEnd], as: UTF8.self)
        }
        return result
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A)
    }

    var isEmpty: Bool { title == nil && description == nil && image == nil }

    /// Decodes entities and collapses whitespace.
    static func clean(_ text: String) -> String {
        decodeEntities(text)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let entity = try! NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#)
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "laquo": "«", "raquo": "»",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var last = text.startIndex
        for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let name = String(text[body])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[name.lowercased()]
            }
            result += replacement ?? String(text[whole])
            last = whole.upperBound
        }
        return result + text[last...]
    }
}
