import Foundation
import YapnestKit

/// The KLIPY key the build was given, which is what the GIF picker needs.
enum Klipy {
    /// Nil without a key: the build setting is empty, or never expanded.
    static var apiKey: String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "KlipyAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty, raw != "$(KLIPY_API_KEY)" else { return nil }
        return raw
    }

    static func service() -> GifService? {
        apiKey.map { GifService(apiKey: $0, locale: Locale.current.region?.identifier.lowercased()) }
    }
}
