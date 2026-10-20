import Foundation

/// Finds the links in message text.
public enum LinkDetector {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Schemes worth making tappable; anything else a sender writes stays text.
    private static let openableSchemes: Set<String> = ["http", "https", "mailto", "xmpp"]

    public static func links(in text: String) -> [(range: NSRange, url: URL)] {
        detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else { return nil }
            return (match.range, url)
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
