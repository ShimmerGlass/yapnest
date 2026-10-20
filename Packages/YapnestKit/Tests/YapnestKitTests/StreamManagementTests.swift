import Combine
import Foundation
import Martin
import Testing
@testable import Martin

/// Stands in for the connection: like Martin's session, it shows every
/// stanza to the stream management module before "sending" it.
private final class RecordingWriter: PacketWriter {
    var module: StreamManagementModule?
    var written: [String] = []
    /// Everything written, requests for acks included, in order.
    var sequence: [String] = []

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}

    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {
        module?.processOutgoing(stanza: stanza)
        sequence.append(stanza.getAttribute("id") ?? stanza.name)
        if stanza.name != "r" { written.append(stanza.getAttribute("id") ?? stanza.name) }
    }
}

private final class Harness {
    let module = StreamManagementModule()
    let writer = RecordingWriter()
    let client: XMPPClient
    var acked: [String] = []
    private var subscription: AnyCancellable?

    init(enabled: Bool = true) {
        client = XMPPClient()
        client.writer = writer
        writer.module = module
        _ = client.modulesManager.register(StreamFeaturesModule())
        module.context = client
        subscription = module.ackedStanzas.sink { [unowned self] in
            acked.append($0.getAttribute("id") ?? "?")
        }
        if enabled { enabledByServer() }
    }

    func enabledByServer() {
        module.processEnabled(Stanza(name: "enabled", xmlns: "urn:xmpp:sm:3"))
    }

    func send(_ id: String) {
        let message = Message()
        message.id = id
        module.processOutgoing(stanza: message)
    }

    func ack(_ h: UInt32) {
        let a = Stanza(name: "a", xmlns: "urn:xmpp:sm:3")
        a.setAttribute("h", value: String(h))
        module.processAckAnswer(a)
    }

    func resumed(h: UInt32) {
        let r = Stanza(name: "resumed", xmlns: "urn:xmpp:sm:3")
        r.setAttribute("h", value: String(h))
        module.processResumed(r)
    }
}

struct StreamManagementTests {
    /// A partial ack used to rewind the counter to the server's count, so
    /// the next ack counted stanzas the server hadn't handled as handled.
    @Test func partialAckKeepsLaterStanzasQueued() {
        let h = Harness()
        h.send("A"); h.send("B")
        h.ack(1)
        #expect(h.acked == ["A"])
        h.send("C")
        h.ack(2)
        #expect(h.acked == ["A", "B"])
        h.ack(3)
        #expect(h.acked == ["A", "B", "C"])
    }

    @Test func repeatedAckAcknowledgesNothingNew() {
        let h = Harness()
        h.send("A"); h.send("B")
        h.ack(1)
        h.ack(1)
        h.ack(0)
        #expect(h.acked == ["A"])
    }

    @Test func ackWrapsAroundAt32Bits() {
        let h = Harness()
        // Start just below the wrap by acknowledging a long run.
        let start = UInt32.max - 1
        h.module.setOutgoingCounterForTesting(start)
        h.send("A"); h.send("B"); h.send("C")   // counter wraps to 1
        h.ack(start &+ 1)
        #expect(h.acked == ["A"])
        h.ack(start &+ 3)
        #expect(h.acked == ["A", "B", "C"])
    }

    /// Stanzas the server didn't handle are written again on resumption.
    /// They must be queued once, and counted from what the server handled.
    @Test func resumptionResendsUnhandledOnce() {
        let h = Harness()
        h.send("A"); h.send("B"); h.send("C")
        h.resumed(h: 1)
        #expect(h.acked == ["A"])
        #expect(h.writer.written == ["B", "C"])
        h.ack(2)
        #expect(h.acked == ["A", "B"])
        h.ack(3)
        #expect(h.acked == ["A", "B", "C"])
    }

    /// Nothing else asks the server about the stanzas written again, so
    /// without a request they stayed unacknowledged until the next message.
    @Test func resumptionAsksForAnAckOfWhatItResent() {
        let h = Harness()
        h.send("A"); h.send("B")
        h.resumed(h: 1)
        #expect(h.writer.sequence == ["B", "r"])
    }

    @Test func resumptionWithNothingToResendAsksForNothing() {
        let h = Harness()
        h.send("A")
        h.resumed(h: 1)
        #expect(h.writer.sequence.isEmpty)
    }

    /// ejabberd counts from `<enable>`, and what is written before `<enabled>`
    /// arrives counts too. Without it the client was one behind for the whole
    /// stream.
    @Test func stanzaWrittenBeforeEnabledArrivesIsCountedAndAcked() {
        let h = Harness(enabled: false)
        h.send("before")            // precedes `<enable>`, so the server doesn't count it
        h.module.enable(completionHandler: nil)
        h.send("A")                 // after `<enable>`, before `<enabled>`
        h.enabledByServer()
        h.send("B")
        h.ack(1)
        #expect(h.acked == ["A"])
        h.ack(2)
        #expect(h.acked == ["A", "B"])
    }

    @Test func failedEnableStopsCountingStanzas() {
        let h = Harness(enabled: false)
        h.module.enable(completionHandler: nil)
        h.module.processFailed(Stanza(name: "failed", xmlns: "urn:xmpp:sm:3"))
        h.send("A")
        h.enabledByServer()
        h.send("B")
        h.ack(1)
        #expect(h.acked == ["B"])
    }

    /// A server count above ours used to wrap to a huge difference, so no
    /// later ack ever released anything.
    @Test func ackAheadOfOurCountAcknowledgesQueueAndLaterAcksStillWork() {
        let h = Harness()
        h.send("A"); h.send("B")
        h.ack(3)
        #expect(h.acked == ["A", "B"])
        h.send("C"); h.send("D")
        h.ack(4)
        #expect(h.acked == ["A", "B", "C"])
        h.ack(5)
        #expect(h.acked == ["A", "B", "C", "D"])
    }

    @Test func resumptionAheadOfOurCountDoesNotRewriteHandledStanzas() {
        let h = Harness()
        h.send("A"); h.send("B")
        h.resumed(h: 3)
        #expect(h.acked == ["A", "B"])
        #expect(h.writer.written.isEmpty)
        h.send("C")
        h.ack(4)
        #expect(h.acked == ["A", "B", "C"])
    }

    /// The ack for a request, or for stanzas received, goes out after a
    /// delay. Written to the next stream, which isn't authenticated yet,
    /// it made Prosody close that stream with unsupported-stanza-type.
    @Test(arguments: [true, false])
    func delayedAckDoesNotOutliveTheStream(reset: Bool) async throws {
        for request in [true, false] {
            let h = Harness()
            if request {
                h.module.processAckRequest(Stanza(name: "r", xmlns: "urn:xmpp:sm:3"))
            } else {
                let message = Message()
                message.id = "in"
                _ = h.module.processIncoming(stanza: message)
            }
            if reset { h.module.reset(scopes: [.stream]) }
            try await Task.sleep(for: .milliseconds(400))
            // Without a reset the ack is sent, so the wait proves something.
            #expect((h.writer.written == ["a"]) == !reset)
        }
    }
}
