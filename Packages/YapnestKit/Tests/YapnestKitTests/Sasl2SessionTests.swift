import Combine
import Foundation
import Martin
import Testing
@testable import Martin

struct Sasl2SessionTests {
    /// After an inline resumption the server sends no stream features, so
    /// waiting for them left the client "connecting" until the watchdog
    /// gave up. Its `<r/>` and the resent results came right after
    /// `<success>`, ahead of the session logic noticing it.
    @Test func resumptionConnectsWithoutFeatures() async throws {
        let h = try Sasl2Harness()
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("resumed", "urn:xmpp:sm:3", ["h": "1", "previd": "prev"]),
        ]))
        for id in ["r1", "r2", "r3"] { h.receive(h.iqResult(id)) }
        h.receive(element("r", "urn:xmpp:sm:3"))

        await eventually("connected") {
            // State's == ignores whether it resumed.
            h.states.contains { if case .connected(let resumed) = $0 { resumed } else { false } }
        }
        #expect(h.connectedCount == 1)
        #expect(h.sm.ackEnabled)

        // What the server hadn't handled went out again, once.
        await eventually("the resend") { h.writer.written.filter { $0.name == "message" }.count == 2 }
        #expect(h.writer.written.filter { $0.name == "message" }.compactMap { $0.getAttribute("id") } == ["B", "C"])

        // The three results were counted, and the request was answered.
        await eventually("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "3")
    }

    /// Features that do follow a resumption mustn't set the session up
    /// again.
    @Test func featuresAfterResumptionAreIgnored() async throws {
        let h = try Sasl2Harness()
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            element("resumed", "urn:xmpp:sm:3", ["h": "1", "previd": "prev"]),
        ]))
        await eventually("connected") { h.connectedCount == 1 }
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.connectedCount == 1)
        #expect(h.writer.written.filter { $0.name == "message" }.count == 2)
    }

    /// A new session is bound from `<success>`, and the features that
    /// follow it carry on from there once.
    @Test func bindingConnectsOnceWithFeatures() async throws {
        let h = try Sasl2Harness()
        // Signing in is the only thing sent before the server answers.
        #expect(h.writer.written.map(\.name) == ["authenticate"])
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "new", "resume": "true"]),
            ]),
        ]))
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        await eventually("connected") { h.connectedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.states.contains(.connected(resumed: false)))
        #expect(h.connectedCount == 1)
        #expect(h.client.context.boundJid == JID("alice@localhost/phone"))
        #expect(!h.writer.written.contains { $0.name == "resume" })
    }

    /// A server sends the features right after `<success>`, and what comes
    /// next can arrive in the same read. Bind 2's `<enabled>` must be
    /// applied before those stanzas are handled, or they go uncounted and
    /// the `<r/>` is answered with a count that's short.
    /// The four events are sent back to back, as the connector does for one
    /// read, through the session logic's own queue hops. The XML parsing and
    /// the socket are not exercised.
    @Test func bindingIsAppliedBeforeStanzasInTheSameRead() async throws {
        let h = try Sasl2Harness()
        // A new connection: the earlier one's counting has stopped.
        h.sm.reset(scopes: [.stream])
        #expect(!h.sm.ackEnabled)
        // All four are queued before the first is handled, as in one read.
        h.receive(element("block", "test"))
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "x", "resume": "true"]),
            ]),
        ]))
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        let message = element("message", "jabber:client", ["id": "m1", "from": "bob@localhost/x", "type": "chat"], [
            Element(name: "body", cdata: "hi"),
        ])
        h.receive(message)
        h.receive(element("r", "urn:xmpp:sm:3"))
        h.blocker.gate.signal()

        await eventually("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "1")
        #expect(h.recorder.ids == ["m1"])
        await eventually("connected") { h.connectedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.connectedCount == 1)
        #expect(h.client.context.boundJid == JID("alice@localhost/phone"))
    }

    /// The usual outcome of a refused resumption: the server binds a new
    /// session instead. Clearing the old one must not undo what the new
    /// one's `<success>` brought, nor the stanzas counted before the session
    /// logic notices it.
    @Test func refusedResumptionKeepsTheNewBindingFromTheSameRead() async throws {
        let h = try Sasl2Harness()
        h.sm.reset(scopes: [.stream])
        h.receive(element("block", "test"))
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/phone"),
            element("failed", "urn:xmpp:sm:3"),
            element("bound", "urn:xmpp:bind:0", [:], [
                element("enabled", "urn:xmpp:sm:3", ["id": "y", "resume": "true"]),
            ]),
        ]))
        h.receive(element("features", "http://etherx.jabber.org/streams"))
        h.receive(element("message", "jabber:client", ["id": "m1", "from": "bob@localhost/x", "type": "chat"], [
            Element(name: "body", cdata: "hi"),
        ]))
        h.receive(element("r", "urn:xmpp:sm:3"))
        h.blocker.gate.signal()

        await eventually("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "1")
        #expect(h.recorder.ids == ["m1"])
        await eventually("connected") { h.connectedCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.connectedCount == 1)
        #expect(h.sm.ackEnabled)
        #expect(h.sm.resumptionEnabled)
        #expect(h.client.context.boundJid == JID("alice@localhost/phone"))
    }
}
