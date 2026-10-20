import Foundation
import Testing
@testable import Yapnest

/// Where a tapped link goes: `xmpp:` to the app, never to another client.
@MainActor
struct LinkOpeningTests {
    @Test func anXMPPLinkGoesToTheAppsHandler() throws {
        let f = try ConversationFixture()
        var opened: [URL] = []
        f.model.linkHandler = { opened.append($0) }
        let url = URL(string: "XMPP:nest@fixture.test?message;body=hi")!
        f.model.open(link: url)
        #expect(opened == [url])
    }
}
