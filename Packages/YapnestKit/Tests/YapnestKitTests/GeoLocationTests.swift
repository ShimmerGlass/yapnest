import Foundation
import Testing
@testable import YapnestKit

struct GeoLocationTests {
    @Test func parsesPlainAndDecoratedURIs() {
        #expect(GeoLocation(body: "geo:48.8584,2.2945") == GeoLocation(latitude: 48.8584, longitude: 2.2945))
        #expect(GeoLocation(body: "  GEO:-33.86,151.21,12.5;u=30\n") == GeoLocation(latitude: -33.86, longitude: 151.21, accuracy: 30))
        #expect(GeoLocation(body: "geo:1,2;crs=wgs84;u=3.5;foo=bar")?.accuracy == 3.5)
        #expect(GeoLocation(body: "geo:90,-180") != nil)
    }

    @Test func rejectsMalformedAndOutOfRange() {
        for body in ["geo:", "geo:1", "geo:91,0", "geo:0,181", "geo:a,b", "geo:nan,1", "geo:1e1,2", "geo:1,2,x",
                     "geo:1,2,3,4", "geo:1,2;u=-1", "geo:1,2;u=x", "geo:1,2;crs=osgb36", "geo: 1,2", "geo:1,,2"] {
            #expect(GeoLocation(body: body) == nil, "\(body)")
        }
    }

    @Test func onlyAWholeBodyIsALocation() {
        #expect(GeoLocation(body: "meet at geo:48.85,2.29") == nil)
        #expect(GeoLocation(body: "geo:48.85,2.29 see you") == nil)
        #expect(GeoLocation(body: "https://example.org/geo:1,2") == nil)
    }

    @Test func formatsTheBodyToSend() {
        #expect(GeoLocation(latitude: 48.8584, longitude: 2.2945).uri == "geo:48.858400,2.294500")
        #expect(GeoLocation(latitude: -0.0000001, longitude: 1, accuracy: 4.2).uri == "geo:0.000000,1.000000;u=5")
        let there = GeoLocation(latitude: 12.345678, longitude: -98.765432, accuracy: 10)
        #expect(GeoLocation(body: there.uri) == there)
    }

    @Test func locationsSummariseAndQuoteAsLocation() throws {
        #expect(Attachment.quoteSummary(text: "geo:1,2", attachment: nil) == "📍 Location")
        #expect(Attachment.quoteSummary(text: "look geo:1,2", attachment: nil) == nil)

        let db = try AppDatabase.inMemory()
        let me = JID("me@example.org")!, alice = JID("alice@example.org")!
        let id = try db.conversation(with: alice).id!
        let t0 = Date(timeIntervalSince1970: 1_000)
        try db.insert(Message(conversationId: id, direction: .incoming, sender: alice, body: "geo:1,2", timestamp: t0, remoteId: "g1"))
        try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "where?", timestamp: t0 + 1, remoteId: "r1", replyToId: "g1", replyToSender: alice))
        let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me) }
        #expect(items[1].quote?.text == "📍 Location")
    }
}
