import Foundation

extension URLSession {
    /// A session that keeps nothing between requests: no cookies and no cache,
    /// so a host can't tie one fetch to the next and nothing fetched is kept
    /// by the system.
    static func privateEphemeral() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
