import Foundation

/// A place shared the way Conversations, Monal, Gajim and others do it: a
/// message whose whole body is an RFC 5870 `geo:` URI.
public struct GeoLocation: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Uncertainty in metres, from `;u=`.
    public var accuracy: Double?

    public init(latitude: Double, longitude: Double, accuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    /// For the chat list, notifications and quotes.
    public static var summary: String { String(localized: "📍 Location") }

    /// The location a message body is, or nil for anything else. A `geo:`
    /// link among other text stays ordinary text, so only a body that is
    /// nothing but the URI counts.
    public init?(body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "geo:", options: [.anchored, .caseInsensitive]) != nil else { return nil }
        let parts = text.dropFirst(4).split(separator: ";", omittingEmptySubsequences: false)
        guard let path = parts.first else { return nil }
        let numbers = path.split(separator: ",", omittingEmptySubsequences: false)
        guard numbers.count == 2 || numbers.count == 3,
              let latitude = Self.number(numbers[0]), let longitude = Self.number(numbers[1]),
              (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        if numbers.count == 3, Self.number(numbers[2]) == nil { return nil }

        var accuracy: Double?
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pair[0].lowercased()
            let value = pair.count == 2 ? pair[1] : ""
            switch name {
            case "crs":
                // Only WGS-84 is defined for `geo:`, and other systems can't be placed on a map.
                guard value.lowercased() == "wgs84" else { return nil }
            case "u":
                guard let metres = Self.number(value), metres >= 0 else { return nil }
                accuracy = metres
            default:
                break
            }
        }
        self.init(latitude: latitude, longitude: longitude, accuracy: accuracy)
    }

    /// Apple Maps through its web URL, which opens the Maps app on iOS and on the Mac.
    public var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude)), URLQueryItem(name: "q", value: String(localized: "Location"))]
        return components?.url
    }

    /// The body to send: six decimals is about a tenth of a metre.
    public var uri: String {
        var uri = "geo:" + Self.format(latitude) + "," + Self.format(longitude)
        if let accuracy { uri += ";u=" + String(Int(accuracy.rounded(.up))) }
        return uri
    }

    private static func format(_ value: Double) -> String {
        // Avoids "-0.000000" for a point that rounds to zero.
        let text = String(format: "%.6f", value)
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text
    }

    /// Plain decimals only: `Double("nan")` and `Double("1e3")` parse but aren't in the grammar.
    private static func number(_ text: some StringProtocol) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }) else { return nil }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}
