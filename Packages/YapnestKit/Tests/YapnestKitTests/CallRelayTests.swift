import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// Always Relay Calls: media is never offered a direct path, and a call that
/// can't be relayed fails instead of falling back to one.
struct CallRelayTests {
    private let alice = YapnestKit.JID("alice@example.org")!

    private func serve(_ h: CallSessionHarness, services: [[String: String]]) {
        h.wire.answer { iq in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                return FakeWire.discoInfo(to: iq, category: "server", type: "im", features: ["urn:xmpp:extdisco:2"])
            }
            if iq.firstChild(name: "services", xmlns: "urn:xmpp:extdisco:2") != nil {
                let list = Element(name: "services", xmlns: "urn:xmpp:extdisco:2")
                for attributes in services { list.addChild(Element(name: "service", attributes: attributes)) }
                return FakeWire.result(to: iq, list)
            }
            return FakeWire.result(to: iq)
        }
        h.session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
    }

    private static let stun = ["type": "stun", "host": "198.51.100.1", "port": "3478"]
    private static let turn = ["type": "turn", "host": "198.51.100.1", "username": "u", "password": "p"]

    @Test func offByDefault() throws {
        #expect(!(try CallSessionHarness()).session.relaysCalls)
    }

    @Test func theSettingReachesTheMediaOfACall() async throws {
        let h = try CallSessionHarness()
        serve(h, services: [Self.stun, Self.turn])
        try h.database.setFlag(.relaysCalls, true)
        try h.session.startCall(to: alice)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(h.factory.last?.relayOnly == true)
    }

    @Test func withoutTheSettingMediaMayGoDirect() async throws {
        let h = try CallSessionHarness()
        serve(h, services: [Self.stun])
        try h.session.startCall(to: alice)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(h.factory.last?.relayOnly == false)
    }

    @Test(arguments: [[["type": "stun", "host": "198.51.100.1"]], []] as [[[String: String]]])
    func aCallerWithNoRelayFailsBeforeMediaStarts(services: [[String: String]]) async throws {
        let h = try CallSessionHarness()
        serve(h, services: services)
        try h.database.setFlag(.relaysCalls, true)
        try h.session.startCall(to: alice)
        await eventually("the call to fail") { h.phase == .ended(.failed) }
        #expect(h.factory.made.isEmpty)
        #expect(h.session.warnings.current.contains { $0.key == "call-relay" })
    }

    @Test func aCalleeWithNoRelayFailsToo() async throws {
        let h = try CallSessionHarness()
        serve(h, services: [Self.stun])
        try h.database.setFlag(.relaysCalls, true)
        h.receive(h.propose())
        h.session.answerCall()
        await eventually("the call to fail") { h.phase == .ended(.failed) }
        #expect(h.factory.made.isEmpty)
        #expect(h.session.warnings.current.contains { $0.key == "call-relay" })
    }

    @Test func aRelayLetsTheCallThroughAndClearsTheWarning() async throws {
        let h = try CallSessionHarness()
        serve(h, services: [Self.turn])
        h.session.warnings.post("call-relay", title: "x", detail: "y")
        try h.database.setFlag(.relaysCalls, true)
        try h.session.startCall(to: alice)
        await eventually("the media to start") { h.factory.last?.iceServers != nil }
        #expect(h.session.warnings.current.isEmpty)
    }

    @Test func onlyTurnServersCountAsRelays() {
        #expect(CallIceServer(urls: ["turn:a:3478?transport=udp"]).isRelay)
        #expect(CallIceServer(urls: ["turns:a:5349?transport=tcp"]).isRelay)
        #expect(!CallIceServer(urls: ["stun:a:3478"]).isRelay)
    }
}
