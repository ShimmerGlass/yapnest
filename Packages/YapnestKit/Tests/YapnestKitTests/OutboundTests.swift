import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

struct OutboundTests {
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!

    /// Serializes and re-parses, as the receiving side would.
    private func roundTrip(_ stanza: Martin.Message, from sender: YapnestKit.JID) throws -> InboundMessage {
        stanza.from = Martin.JID(sender.martin)
        let parsed = try #require(Element.from(string: stanza.element.stringValue))
        let message = try #require(Stanza.from(element: parsed) as? Martin.Message)
        return try #require(InboundMessage(message, account: alice, source: .live))
    }

    @Test func replyRoundTripsThroughFallback() throws {
        let quote = OutboundStanza.QuotedMessage(id: "orig", author: alice.description, text: "Cake? 🎂\nTonight")
        let stanza = OutboundStanza.text("Yes!", to: .direct(alice), id: "m1", replyingTo: quote)
        let inbound = try roundTrip(stanza, from: me)
        #expect(inbound.body == "Yes!")
        #expect(inbound.reply == .init(id: "orig", to: alice.description, fallback: "Cake? 🎂\nTonight"))
        #expect(inbound.id == "m1")
        #expect(inbound.originId == "m1")
        #expect(inbound.requestsReceipt)
        #expect(inbound.isMarkable)
    }

    @Test func reactionsRoundTrip() throws {
        let inbound = try roundTrip(OutboundStanza.reactions(["👍", "❤️"], to: .direct(alice), target: "orig", id: "r1"), from: me)
        #expect(inbound.reactions?.id == "orig")
        #expect(inbound.reactions?.emojis == ["👍", "❤️"])
        #expect(inbound.body == nil)
    }

    @Test func receiptAndMarker() throws {
        #expect(try roundTrip(OutboundStanza.receipt(to: alice, for: "x"), from: me).receiptFor == "x")
        #expect(try roundTrip(OutboundStanza.displayed(to: alice, target: "y"), from: me).displayedMarkerFor == "y")
        #expect(try roundTrip(OutboundStanza.chatState(.composing, to: alice), from: me).chatState == .composing)
    }
}
