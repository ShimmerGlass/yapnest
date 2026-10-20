import Foundation

/// The OpenGraph (and fallback) metadata of an HTML page. A tolerant scan of
/// `<meta>` tags rather than a full parser: pages put these in `<head>`,
/// and plenty of them aren't well-formed.
struct OpenGraph: Equatable {
    var title: String?
    var description: String?
    var siteName: String?
    var image: URL?

    private static let metaTag = try! NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(pattern: #"([a-zA-Z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let titleTag = try! NSRegularExpression(pattern: #"<title\b[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    init(title: String? = nil, description: String? = nil, siteName: String? = nil, image: URL? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
        self.image = image
    }

    /// - Parameter base: the page's URL, for resolving a relative image URL.
    init(html: String, base: URL) {
        var meta: [String: String] = [:]
        let range = NSRange(html.startIndex..., in: html)
        for match in Self.metaTag.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            var attributes: [String: String] = [:]
            for attr in Self.attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let name = Range(attr.range(at: 1), in: tag) else { continue }
                let value = (2...4).lazy.compactMap { Range(attr.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
                attributes[tag[name].lowercased()] = value
            }
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(), let content = attributes["content"] else { continue }
            // The first occurrence wins, as with og:image arrays.
            if meta[key] == nil { meta[key] = content }
        }

        func value(_ keys: String...) -> String? {
            keys.lazy.compactMap { meta[$0].map(Self.clean) }.first { !$0.isEmpty }
        }

        var pageTitle: String?
        if let match = Self.titleTag.firstMatch(in: html, range: range), let r = Range(match.range(at: 1), in: html) {
            pageTitle = Self.clean(String(html[r]))
        }

        title = value("og:title", "twitter:title") ?? pageTitle.flatMap { $0.isEmpty ? nil : $0 }
        description = value("og:description", "twitter:description", "description")
        siteName = value("og:site_name")
        image = value("og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src")
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
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
