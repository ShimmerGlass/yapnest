import Combine
import Foundation
import os
import Martin
import Testing
@testable import Martin

private func chatMessage(_ id: String) -> Element {
    element("message", "jabber:client", ["id": id, "from": "bob@localhost/x", "type": "chat"], [Element(name: "body", cdata: "hi")])
}

private let earlier = StreamManagementModule.Snapshot(
    id: "app-stream", location: "other.example:5222", timeout: 600, incoming: 7, outgoing: 5, boundJid: "alice@localhost/yapnest-app", resumedH: 4,
)

/// A module holds its client weakly, so a helper that returns only the module would lose it.
private final class Clients: @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var all: [XMPPClient] = []
    static func keep(_ client: XMPPClient) { lock.withLock { all.append(client) } }
}


private final class Acked: @unchecked Sendable {
    let ids = OSAllocatedUnfairLock(initialState: [String]())
    var subscription: AnyCancellable?
}

struct StreamSnapshotTests {
    private func module(bound: String? = nil) -> StreamManagementModule {
        let client = XMPPClient(eventBus: nil)
        Clients.keep(client)
        _ = client.modulesManager.register(StreamFeaturesModule())
        let binder = client.modulesManager.register(ResourceBinderModule())
        if let bound { binder.bindedJid = JID(bound) }
        let module = client.modulesManager.register(StreamManagementModule())
        module.context = client
        return module
    }

    /// What resuming needs survives being written down and read back, in a client that has never been
    /// connected.
    @Test func aSnapshotSeedsAnotherClientToTheSameState() throws {
        let source = module(bound: "alice@localhost/yapnest-app")
        let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
        enabled.setAttribute("id", value: "app-stream")
        enabled.setAttribute("resume", value: "true")
        enabled.setAttribute("location", value: "other.example:5222")
        enabled.setAttribute("max", value: "600")
        source.processEnabled(enabled)
        for _ in 0..<3 { _ = source.processIncoming(stanza: Stanza.from(element: chatMessage("m"))) }
        for id in ["A", "B"] {
            let message = Message()
            message.id = id
            source.processOutgoing(stanza: message)
        }
        let snapshot = try #require(source.snapshot)
        #expect(snapshot == StreamManagementModule.Snapshot(
            id: "app-stream", location: "other.example:5222", timeout: 600, incoming: 3, outgoing: 2, boundJid: "alice@localhost/yapnest-app", resumedH: nil,
        ))

        let decoded = try JSONDecoder().decode(StreamManagementModule.Snapshot.self, from: JSONEncoder().encode(snapshot))
        let target = module()
        #expect(target.snapshot == nil)
        target.seed(decoded)
        #expect(target.snapshot == snapshot)
        #expect(target.resumptionEnabled)
        #expect(target.resumptionTime == 600)
        #expect(target.context?.boundJid == JID("alice@localhost/yapnest-app"))
    }

    @Test func aStreamThatCannotBeResumedHasNoSnapshot() {
        let plain = module()
        plain.processEnabled(Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3"))
        #expect(plain.snapshot == nil)
    }

    /// A snapshot is the stream's, so a graceful close that ends it takes it away, and a forced one doesn't.
    @Test func resetEndsTheSnapshot() {
        let seeded = module()
        seeded.seed(earlier)
        #expect(seeded.snapshot != nil)
        seeded.reset()
        #expect(seeded.snapshot == nil)
    }

    /// The id alone, for what asks of every stanza, follows the snapshot's.
    @Test func theStreamIdIsTheSnapshotsId() {
        let seeded = module()
        #expect(seeded.streamId == nil)
        seeded.seed(earlier)
        #expect(seeded.streamId == seeded.snapshot?.id)
        #expect(seeded.streamId == earlier.id)
        seeded.reset()
        #expect(seeded.streamId == nil)
    }

    /// How many of our stanzas the server had handled, as it said when it resumed the stream: what a
    /// process that takes the stream over after this one needs to tell its own count from the server's.
    @Test func theServersCountFromResumedIsKeptUntilANewStream() {
        let seeded = module()
        seeded.seed(StreamManagementModule.Snapshot(id: "s", incoming: 1, outgoing: 5))
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "4")
        seeded.processResumed(resumed)
        #expect(seeded.snapshot?.resumedH == 4)
        seeded.reset()
        seeded.processEnabled({
            let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
            enabled.setAttribute("id", value: "new")
            enabled.setAttribute("resume", value: "true")
            return enabled
        }())
        #expect(seeded.snapshot?.resumedH == nil)
    }

    /// The SASL1 way: `<resume>` goes out with the seeded id and incoming count, and the JID is known
    /// without a bind.
    @Test func aSeededClientSendsResumeAndKnowsItsJid() {
        let client = XMPPClient(eventBus: nil)
        let writer = FeedWriter()
        client.writer = writer
        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(ResourceBinderModule())
        let sm = client.modulesManager.register(StreamManagementModule())
        sm.context = client
        writer.module = sm
        sm.seed(earlier)
        #expect(client.context.boundJid == JID("alice@localhost/yapnest-app"))

        sm.resume { _ in }
        let resume = writer.written.first { $0.name == "resume" }
        #expect(resume?.getAttribute("previd") == "app-stream")
        #expect(resume?.getAttribute("h") == "7")
    }

    /// What the server replays right after `<resumed>` is counted, whichever way the stream was resumed:
    /// the `<resumed>` makes the module count, and each stanza after it is seen in order.
    @Test func stanzasReplayedAfterResumedAreCounted() {
        let sm = module()
        sm.seed(earlier)
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "5")
        #expect(sm.processIncoming(stanza: resumed))
        #expect(!sm.processIncoming(stanza: Stanza.from(element: chatMessage("r1"))))
        #expect(!sm.processIncoming(stanza: Stanza.from(element: chatMessage("r2"))))
        #expect(sm.snapshot?.incoming == 9)
    }

    /// Over SASL2 the seeded id and count ride in the `<authenticate>`, and the replayed stanzas that
    /// arrive with `<success>` in the same read are counted and answered.
    @Test func aSeededClientResumesOverSasl2AndCountsTheReplay() async throws {
        let h = try Sasl2Harness(seeding: .snapshot(earlier))
        let authenticate = try #require(h.writer.written.first { $0.name == "authenticate" })
        let resume = try #require(authenticate.findChild(name: "resume", xmlns: "urn:xmpp:sm:3"))
        #expect(resume.getAttribute("previd") == "app-stream")
        #expect(resume.getAttribute("h") == "7")

        h.receive(element("block", "test"))
        h.receive(element("success", "urn:xmpp:sasl:2", [:], [
            Element(name: "authorization-identifier", cdata: "alice@localhost/yapnest-app"),
            element("resumed", "urn:xmpp:sm:3", ["h": "5", "previd": "app-stream"]),
        ]))
        h.receive(chatMessage("r1"))
        h.receive(chatMessage("r2"))
        h.receive(element("r", "urn:xmpp:sm:3"))
        h.blocker.gate.signal()

        await eventually("the answer") { h.writer.written.contains { $0.name == "a" } }
        #expect(h.writer.written.last { $0.name == "a" }?.getAttribute("h") == "9")
        #expect(h.recorder.ids == ["r1", "r2"])
        await eventually("connected") { h.states.contains { if case .connected(let resumed) = $0 { resumed } else { false } } }
        #expect(h.client.context.boundJid == JID("alice@localhost/yapnest-app"))
        #expect(h.sm.snapshot?.resumedH == 5)
    }

    /// The final acknowledgement is written before `acknowledge()` returns, once, and not again when the
    /// server has been told everything.
    @Test func acknowledgeWritesTheCountOnce() async {
        let client = XMPPClient(eventBus: nil)
        let writer = FeedWriter()
        client.writer = writer
        _ = client.modulesManager.register(StreamFeaturesModule())
        let sm = client.modulesManager.register(StreamManagementModule())
        sm.context = client
        writer.module = sm
        sm.processEnabled(Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3"))
        _ = sm.processIncoming(stanza: Stanza.from(element: chatMessage("m1")))
        await sm.acknowledge()
        #expect(writer.written.filter { $0.name == "a" }.map { $0.getAttribute("h") } == ["1"])
        await sm.acknowledge()
        #expect(writer.written.filter { $0.name == "a" }.count == 1)
    }

    private func adopting(written ids: [String]) -> (StreamManagementModule, FeedWriter, Acked) {
        let client = XMPPClient(eventBus: nil)
        Clients.keep(client)
        let writer = FeedWriter()
        client.writer = writer
        _ = client.modulesManager.register(StreamFeaturesModule())
        let sm = client.modulesManager.register(StreamManagementModule())
        sm.context = client
        writer.module = sm
        sm.processEnabled({
            let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
            enabled.setAttribute("id", value: "app-stream")
            enabled.setAttribute("resume", value: "true")
            return enabled
        }())
        for id in ids {
            let message = Message()
            message.id = id
            sm.processOutgoing(stanza: message)
        }
        let acked = Acked()
        acked.subscription = sm.ackedStanzas.sink { stanza in
            let id = stanza.id ?? ""
            acked.ids.withLock { $0.append(id) }
        }
        return (sm, writer, acked)
    }

    /// Another process used the stream: its counters are the stream's now. Of the stanzas still queued, the
    /// ones the server had handled when it resumed are acknowledged, and the ones it never got are written
    /// again as new stanzas after the other process's, so the server's count and ours agree.
    @Test func adoptingTheCountersAcknowledgesWhatArrivedAndSendsWhatDidNot() {
        let (sm, writer, acked) = adopting(written: ["A", "B", "C"])
        let used = StreamManagementModule.Snapshot(id: "app-stream", incoming: 12, outgoing: 10, resumedH: 10)

        let unsent = sm.adopt(used, handled: 2)

        #expect(unsent.map(\.id) == ["C"])
        #expect(acked.ids.withLock { $0 } == ["A", "B"])
        #expect(sm.snapshot?.incoming == 12)
        #expect(sm.snapshot?.outgoing == 10)
        #expect(sm.unacknowledgedStanzas.isEmpty, "the queue still holds stanzas the server has handled")

        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "10")
        sm.processResumed(resumed)
        #expect(writer.written.compactMap(\.id) == ["C"])
        #expect(sm.snapshot?.outgoing == 11)
        #expect(sm.unacknowledgedStanzas.map(\.id) == ["C"])
    }

    @Test func adoptingWhenEverythingArrivedSendsNothing() {
        let (sm, writer, acked) = adopting(written: ["A", "B", "C"])
        let unsent = sm.adopt(StreamManagementModule.Snapshot(id: "app-stream", incoming: 12, outgoing: 10, resumedH: 10), handled: 3)

        #expect(unsent.isEmpty)
        #expect(acked.ids.withLock { $0 } == ["A", "B", "C"])
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "10")
        sm.processResumed(resumed)
        #expect(writer.written.isEmpty)
        #expect(sm.snapshot?.outgoing == 10)
    }

    /// A resumption that fails starts a new session, which sends what it has itself.
    @Test func aFailedResumptionForgetsWhatWasAdoptedToSend() {
        let (sm, writer, _) = adopting(written: ["A"])
        sm.adopt(StreamManagementModule.Snapshot(id: "app-stream", incoming: 1, outgoing: 3), handled: 0)
        sm.processFailed(Stanza(name: "failed", xmlns: "urn:xmpp:sm:3"))
        sm.processEnabled({
            let enabled = Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3")
            enabled.setAttribute("id", value: "new")
            enabled.setAttribute("resume", value: "true")
            return enabled
        }())
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "0")
        sm.processResumed(resumed)
        #expect(writer.written.isEmpty)
    }

    /// The handler runs once the counters are settled, before anything that follows is read: a stanza it feeds in
    /// is seen first.
    @Test func theResumedHandlerRunsAfterTheResumedAndBeforeWhatFollows() {
        let sm = module()
        sm.seed(earlier)
        let order = Acked()
        sm.resumedHandler = { [unowned sm] in
            let outgoing = sm.snapshot?.outgoing ?? 0
            order.ids.withLock { $0.append("handler \(outgoing)") }
        }
        let resumed = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        resumed.setAttribute("h", value: "5")
        _ = sm.processIncoming(stanza: resumed)
        #expect(order.ids.withLock { $0 } == ["handler 5"])
    }
}
