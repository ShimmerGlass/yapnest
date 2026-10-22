import Combine
import Foundation
import GRDB
@testable import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// A message over the server's stanza size limit on the real server. Prosody closes the stream on
    /// one, which used to take every message queued behind it along, on each reconnect.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=prosody swift test --filter StreamLimitIntegration`
    struct StreamLimitIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// What each dev server advertises after sign-in (XEP-0478 `max-bytes`), nil where it says nothing.
        static let advertised: [String: Int?] = [
            "prosody": 262144, "ejabberd": nil, "snikket": 262144, "openfire": 1_048_576, "openfire-bare": 1_048_576,
        ]

        private func pair() async throws -> (alice: XMPPSession, bob: XMPPSession) {
            let a = try await LiveServer.connectedSession(alice, resource: "limit")
            let b = try await LiveServer.connectedSession(bob, resource: "limit")
            try a.setEncrypted(false, with: bob)
            try b.setEncrypted(false, with: alice)
            return (a, b)
        }

        /// The bytes of a plain message with an empty body, to size a body against the limit.
        private func overhead(_ session: XMPPSession) -> Int {
            let stanza = OutboundStanza.text("", to: session.route(to: bob), id: UUID().uuidString.lowercased(), active: true)
            return stanza.element.stringValue.utf8.count
        }

        private func message(_ id: Int64, in session: XMPPSession) throws -> YapnestKit.Message? {
            try session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: id) }
        }

        @Test func whatTheServerAdvertisesIsUsed() async throws {
            let (a, b) = try await pair()
            defer { a.disconnect(); b.disconnect() }
            let features = a.client.module(.streamFeatures)
            let expected = try #require(Self.advertised[LiveServer.target.name], "no expectation for \(LiveServer.target.name)")
            #expect(features.authenticatedMaxBytes == expected)
            #expect(features.maxStanzaBytes == (expected ?? StreamFeaturesModule.defaultMaxStanzaBytes))
        }

        @Test func aMessageJustUnderTheLimitIsDelivered() async throws {
            let (a, b) = try await pair()
            defer { a.disconnect(); b.disconnect() }
            let limit = a.client.module(.streamFeatures).maxStanzaBytes
            let body = String(repeating: "a", count: limit - overhead(a) - 100)
            let sent = try a.send(body, to: bob)
            try await LiveServer.waitUntil("bob to receive a message just under the limit", timeout: 120) {
                try b.database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == sent.remoteId).fetchCount($0) } == 1
            }
            #expect(try message(sent.id!, in: a)?.status != .failed)
            #expect(a.state.value == .connected(isSyncing: false))
        }

        @Test func anOversizedMessageFailsWithoutDroppingTheStreamOrTheMessagesBehindIt() async throws {
            let (a, b) = try await pair()
            defer { a.disconnect(); b.disconnect() }
            let dropped = OSAllocatedBool()
            let watch = a.state.sink { if case .connected = $0 {} else { dropped.set() } }
            defer { watch.cancel() }

            let limit = a.client.module(.streamFeatures).maxStanzaBytes
            // Well past it: Prosody checks the size once per read, so a stanza that ends within the
            // read that crosses the limit still gets through.
            let huge = try a.send(String(repeating: "a", count: limit * 2), to: bob)
            let after = try a.send("after the large one", to: bob)

            try await LiveServer.waitUntil("the large message to fail", timeout: 120) { try message(huge.id!, in: a)?.status == .failed }
            #expect(try message(huge.id!, in: a)?.error == "This message is too large for your server.")
            try await LiveServer.waitUntil("bob to receive the next message") {
                try b.database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == after.remoteId).fetchCount($0) } == 1
            }
            let arrived = try await b.database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == huge.remoteId).fetchCount($0) }
            #expect(arrived == 0)
            #expect(a.state.value == .connected(isSyncing: false))
            #expect(!dropped.value)
        }
    }
}
