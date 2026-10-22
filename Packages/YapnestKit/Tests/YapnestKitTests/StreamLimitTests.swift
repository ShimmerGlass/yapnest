import Foundation
import GRDB
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func features(maxBytes: Int?) -> Element {
    let element = Element(name: "features", xmlns: "http://etherx.jabber.org/streams")
    if let maxBytes {
        let limits = Element(name: "limits", xmlns: "urn:xmpp:stream-limits:0")
        limits.addChild(Element(name: "max-bytes", cdata: String(maxBytes)))
        element.addChild(limits)
    }
    return element
}

private func message(bytes: Int) -> Martin.Message {
    let message = Martin.Message()
    message.type = .chat
    message.to = Martin.JID("alice@example.org")
    message.body = String(repeating: "a", count: bytes)
    return message
}

/// A server closes the stream on a stanza past its size limit, which took
/// every message queued behind an oversized one with it, on each reconnect.
@Suite struct StreamLimitTests {
    let client = XMPPClient()
    let module: StreamFeaturesModule

    init() {
        module = StreamFeaturesModule()
        client.modulesManager.register(module)
        client.modulesManager.register(AuthModule())
    }

    @Test func withoutAnAdvertisedLimitTheDefaultApplies() {
        #expect(module.maxStanzaBytes == 262144)
    }

    /// Prosody advertises 10000 to a stream that isn't signed in. With SASL2 there is no restart
    /// to follow, so trusting it would refuse a key bundle.
    @Test func aLimitAdvertisedBeforeSigningInIsIgnored() {
        module.setStreamFeatures(features(maxBytes: 10000))
        #expect(module.maxStanzaBytes == 262144)
    }

    @Test func aLimitAdvertisedAfterSigningInIsUsed() {
        client.module(.auth).update(state: .authorized)
        module.setStreamFeatures(features(maxBytes: 1_000_000))
        #expect(module.maxStanzaBytes == 1_000_000)
        module.setStreamFeatures(features(maxBytes: nil))
        #expect(module.maxStanzaBytes == 262144)
    }

    @Test func theLimitIsForgottenWithTheStream() {
        client.module(.auth).update(state: .authorized)
        module.setStreamFeatures(features(maxBytes: 5000))
        module.reset(scopes: [.stream])
        #expect(module.maxStanzaBytes == 262144)
    }

    @Test func aStanzaOverTheLimitDoesNotFitAndIsReportedWhenRefused() {
        client.module(.auth).update(state: .authorized)
        module.setStreamFeatures(features(maxBytes: 1000))
        nonisolated(unsafe) var reported: [(String, Int, Int)] = []
        module.stanzaRefused = { reported.append(($0, $1, $2)) }
        #expect(module.fits(message(bytes: 500)))
        #expect(!module.fits(message(bytes: 1000)))
        #expect(reported.isEmpty)
        #expect(!module.refuses(message(bytes: 500)))
        #expect(module.refuses(message(bytes: 1000)))
        #expect(reported.count == 1)
        #expect(reported.first?.0 == "message")
        #expect((reported.first?.1 ?? 0) > 1000)
        #expect(reported.first?.2 == 1000)
    }

    /// Refused before it is handed on, so stream management never counts it, and with an error that
    /// says why rather than "not connected".
    @Test func theSessionLogicRefusesAnOversizedStanza() async {
        client.module(.auth).update(state: .authorized)
        module.setStreamFeatures(features(maxBytes: 1000))
        let responses = ResponseManager()
        let logic = SocketSessionLogic(connector: SocketConnectorNetwork(context: client.context), responseManager: responses, context: client.context, seeOtherHost: nil)

        let large: Result<Void, XMPPError> = await withCheckedContinuation { continuation in
            logic.send(stanza: message(bytes: 2000), completionHandler: { continuation.resume(returning: $0) })
        }
        guard case .failure(let error) = large else { Issue.record("an oversized stanza was accepted"); return }
        #expect(error.isStanzaTooLarge)

        let small: Result<Void, XMPPError> = await withCheckedContinuation { continuation in
            logic.send(stanza: message(bytes: 10), completionHandler: { continuation.resume(returning: $0) })
        }
        guard case .failure(let notConnected) = small else { Issue.record("a write succeeded while disconnected"); return }
        #expect(!notConnected.isStanzaTooLarge)
    }

    @Test func aRequestOverTheLimitFailsWithTheSizeNotATimeout() async {
        client.module(.auth).update(state: .authorized)
        module.setStreamFeatures(features(maxBytes: 1000))
        let responses = ResponseManager()
        let logic = SocketSessionLogic(connector: SocketConnectorNetwork(context: client.context), responseManager: responses, context: client.context, seeOtherHost: nil)
        let writer = LogicPacketWriter(sessionLogic: logic, responseManager: responses)
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID("pubsub.example.org")
        iq.addChild(Element(name: "payload", cdata: String(repeating: "a", count: 2000)))

        let failure: XMPPError? = await withCheckedContinuation { continuation in
            writer.write(iq, timeout: 30, errorDecoder: XMPPError.from(stanza:)) { (result: Result<Iq, XMPPError>) in
                if case .failure(let error) = result { continuation.resume(returning: error) } else { continuation.resume(returning: nil) }
            }
        }
        #expect(failure?.isStanzaTooLarge == true)
    }
}

/// An oversized message is marked failed instead of blocking those queued behind it.
struct OversizedMessageSessionTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try session.setEncrypted(false, with: alice)
        session.client.module(.streamFeatures).authenticatedMaxBytes = 5000
    }

    @Test func anOversizedMessageFailsAndTheOnesAfterItAreWritten() throws {
        let huge = try session.send(String(repeating: "x", count: 6000), to: alice)
        let after = try session.send("after", to: alice)
        session.drainSendQueue(alice)

        let stored = try database.reader.read { db in (try YapnestKit.Message.fetchOne(db, key: huge.id!), try YapnestKit.Message.fetchOne(db, key: after.id!)) }
        #expect(stored.0?.status == .failed)
        #expect(stored.0?.error == "This message is too large for your server.")
        #expect(!wire.messages.contains { $0.id == huge.remoteId })
        #expect(wire.messages.contains { $0.id == after.remoteId })
    }

    @Test func aFailedOversizedMessageIsNotSentAgainOnReconnect() throws {
        let huge = try session.send(String(repeating: "x", count: 6000), to: alice)
        session.drainSendQueue(alice)
        session.sendUnclaimedPending()
        session.drainSendQueue(alice)
        #expect(!wire.messages.contains { $0.id == huge.remoteId })
    }
}
