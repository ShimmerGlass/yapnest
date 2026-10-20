import Foundation

/// The pages the app points people to, and the version they'd quote to
/// support. The addresses live in Info.plist so they can change without code.
enum AppLinks {
    static var privacyPolicy: URL? { url(for: "YapnestPrivacyPolicyURL") }
    static var terms: URL? { url(for: "YapnestTermsURL") }
    static var support: URL? { url(for: "YapnestSupportURL") }
    static var sourceCode: URL? { url(for: "YapnestSourceURL") }

    /// Like "Version 1.0 (42)".
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    private static func url(for key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap(URL.init(string:))
    }
}
