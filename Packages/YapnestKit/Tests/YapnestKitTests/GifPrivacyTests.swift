import Foundation
import Testing
@testable import YapnestKit

/// What the GIF picker fetches reveals the user's interests, so nothing may
/// tie one request to the next.
struct GifPrivacyTests {
    @Test func theServiceUsesThePrivateSessionByDefault() {
        #expect(GifService(apiKey: "k", locale: nil).session === GifService.privateSession)
    }

    @Test func thePrivateSessionKeepsNoCookiesAndNoCache() {
        let configuration = GifService.privateSession.configuration
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
    }
}
