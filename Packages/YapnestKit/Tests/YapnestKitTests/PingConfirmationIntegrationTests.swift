import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    /// A stream without stream management has the server's reply to a ping
    /// stand in for its acknowledgement.
    /// `YAPNEST_INTEGRATION=1 swift test --filter PingConfirmation`
    @Suite
    struct PingConfirmationIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func session(_ jid: JID, port: Int = LiveServer.target.port, streamManagement: Bool = true) throws -> XMPPSession {
            let session = try LiveServer.makeSession(jid, resource: "ping-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: port)
            if !streamManagement { session.withoutStreamManagementForTesting() }
            return session
        }

        private func messages(_ session: XMPPSession, body: String) throws -> [Message] {
            try session.database.reader.read { try Message.filter(Column("body") == body).fetchAll($0) }
        }

        @Test func aMessageIsSentOnceTheServerAnswersThePing() async throws {
            let a = try session(alice, streamManagement: false)
            let b = try session(bob)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.connected(a, b)
            #expect(a.client.modulesManager.moduleOrNil(.streamManagement) == nil)
            try a.setEncrypted(false, with: bob)

            let body = "no sm \(UUID().uuidString.prefix(6))"
            try a.send(body, to: bob)
            try await LiveServer.waitUntil("bob to get it") { try messages(b, body: body).count == 1 }
            try await LiveServer.waitUntil("the message to be sent") { try messages(a, body: body).first?.status ?? .pending >= .sent }
        }

        @Test func aReactionIsNoLongerPendingOnceTheServerAnswersThePing() async throws {
            let a = try session(alice, streamManagement: false)
            let b = try session(bob)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.connected(a, b)
            try b.setEncrypted(false, with: alice)

            let body = "react to me \(UUID().uuidString.prefix(6))"
            try b.send(body, to: alice)
            try await LiveServer.waitUntil("alice to get it") { try messages(a, body: body).count == 1 }
            let message = try #require(try messages(a, body: body).first)

            try a.toggleReaction("👍", on: message, peer: bob)
            // The databases hold the reactions of earlier runs too.
            try await LiveServer.waitUntil("the reaction to be confirmed") {
                let rows = try a.database.reader.read { try Reaction.filter(Column("messageId") == message.id).fetchAll($0) }
                return rows.count == 1 && rows.allSatisfy { $0.pendingId == nil }
            }
            let theirs = try #require(try messages(b, body: body).first)
            try await LiveServer.waitUntil("bob to see it") {
                try b.database.reader.read { try Reaction.filter(Column("messageId") == theirs.id).fetchCount($0) } == 1
            }
        }

        /// The connection dies before the server's reply: the message is still
        /// pending, and the next stream sends it, once.
        @Test func aMessageWhosePingWasNeverAnsweredIsSentOnTheNextStream() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice, port: proxy.port, streamManagement: false)
            let b = try session(bob)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.connected(a, b)
            try a.setEncrypted(false, with: bob)

            // The ping follows the message on the wire; the link goes as it passes.
            proxy.cutWhen(.toServer, sees: "urn:xmpp:ping")
            let body = "unanswered \(UUID().uuidString.prefix(6))"
            try a.send(body, to: bob)
            try await LiveServer.waitUntil("the drop") { proxy.firedTriggers == 1 && !a.isConnected }
            #expect(try messages(a, body: body).first?.status == .pending)

            try await LiveServer.waitUntil("the message to be sent") { try messages(a, body: body).first?.status ?? .pending >= .sent }
            try await Task.sleep(for: .seconds(1))
            #expect(try messages(b, body: body).count == 1)
            #expect(try messages(a, body: body).count == 1)
        }
    }
}
