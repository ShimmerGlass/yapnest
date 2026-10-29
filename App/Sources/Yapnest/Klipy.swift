import Foundation
import SwiftUI
import YapnestKit

/// The KLIPY key the build was given, which is what the GIF picker needs.
enum Klipy {
    /// Nil without a key: the build setting is empty, or never expanded.
    static let apiKey: String? = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "KlipyAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty, raw != "$(KLIPY_API_KEY)" else { return nil }
        return raw
    }()

    /// What the GIF settings tell about where searches go.
    static var disclosure: LocalizedStringKey {
        "Searches go to KLIPY, a company in the United States, which sees what you search for, your region and your IP address. You are asked before the first one."
    }

    static func service() -> GifService? {
        apiKey.map { GifService(apiKey: $0, locale: Locale.current.region?.identifier.lowercased()) }
    }
}
