import Foundation

/// Finds the links in message text.
public enum LinkDetector {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Schemes worth making tappable; anything else a sender writes stays text.
    private static let openableSchemes: Set<String> = ["http", "https", "mailto", "xmpp"]

    /// A `geo:` URI as a word of its own. The data detector doesn't know the scheme.
    private static let geoPattern = try! NSRegularExpression(pattern: #"(?<![\w/:.])geo:[-+0-9.,]+(?:;[\w.=-]+)*"#, options: .caseInsensitive)

    public static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let whole = NSRange(text.startIndex..., in: text)
        let links: [(range: NSRange, url: URL)] = detector.matches(in: text, range: whole).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else { return nil }
            return (match.range, url)
        }
        let places = geoLinks(in: text, range: whole).filter { place in
            !links.contains { NSIntersectionRange($0.range, place.range).length > 0 }
        }
        return (links + places).sorted { $0.range.location < $1.range.location }
    }

    /// Places written among other text, linked to the map rather than to
    /// `geo:`, which nothing on iOS or the Mac opens.
    private static func geoLinks(in text: String, range: NSRange) -> [(range: NSRange, url: URL)] {
        let source = text as NSString
        return geoPattern.matches(in: text, range: range).compactMap { match in
            var range = match.range
            // A sentence's full stop or comma after the link isn't part of it.
            while range.length > 0, ".,".contains(source.substring(with: NSRange(location: range.upperBound - 1, length: 1))) {
                range.length -= 1
            }
            guard let url = GeoLocation(body: source.substring(with: range))?.mapsURL else { return nil }
            return (range, url)
        }
    }

    /// The link a message's preview is for: its first web link. Only HTTPS
    /// links get previews, so fetching one never goes out in the clear.
    public static func previewLink(in text: String) -> URL? {
        var first: URL?
        detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let url = match?.url, let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme), scheme.hasPrefix("http") else { return }
            first = url
            stop.pointee = true
        }
        guard let first, first.scheme?.lowercased() == "https" else { return nil }
        return first
    }
}
