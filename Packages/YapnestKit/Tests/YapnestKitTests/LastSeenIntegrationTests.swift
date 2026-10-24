import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Last seen (XEP-0012) between alice, bob and carol on the local Prosody,
    /// which answers for offline users with its core `lastactivity` module.
    /// `YAPNEST_INTEGRATION=1 swift test --filter LastSeenIntegration`
    @Suite
    struct LastSeenIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")
        let carol = LiveServer.jid("carol")

        private func session(_ jid: YapnestKit.JID, resource: String) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "\(resource)-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
        }

        /// Makes `a` and `b` contacts who see each other.
        private func befriend(_ a: XMPPSession, _ b: XMPPSession) async throws {
            try await LiveServer.befriend(a, b)
            try await waitUntil("\(a.account) to see \(b.account)") {
                try a.database.contact(b.account)?.subscription == .both && a.presence(of: b.account) == .online
            }
            try await waitUntil("\(b.account) to see \(a.account)") {
                try b.database.contact(a.account)?.subscription == .both
            }
        }

        private func fullJID(of session: XMPPSession) -> Martin.JID {
            session.client.context.boundJid!
        }

        private func lastActivity(by asker: XMPPSession, of target: Martin.JID) async -> Result<Int, Error> {
            do { return .success(try await asker.lastActivity(of: target)) } catch { return .failure(error) }
        }

        @Test func offlineContactIsAskedItsServer() async throws {
            let a = try session(alice, resource: "seen"), b = try session(bob, resource: "seen")
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            try await LiveServer.setSharesLastSeen(true, on: a)

            // The server notes when a user says they're unavailable.
            let leaving = Presence()
            leaving.type = .unavailable
            b.client.context.writer.write(leaving)
            b.disconnect()
            try await waitUntil("alice to see bob offline") { a.presence(of: bob) == .offline }
            try await Task.sleep(for: .seconds(2))

            let seconds = try await a.lastActivity(of: Martin.JID(bob.martin))
            #expect((1...60).contains(seconds))

            await a.refreshLastSeen(of: bob)
            let seen = try #require(try a.database.contact(bob)?.lastSeenAt)
            #expect(abs(seen.timeIntervalSinceNow + Double(seconds)) < 30)
            try await LiveServer.setSharesLastSeen(false, on: a)
        }

        @Test func notAskedWhileNotSharing() async throws {
            let a = try session(alice, resource: "off"), b = try session(bob, resource: "off")
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            try await LiveServer.setSharesLastSeen(false, on: a)
            b.disconnect()
            try await waitUntil("alice to see bob offline") { a.presence(of: bob) == .offline }

            await a.refreshLastSeen(of: bob)
            #expect(try a.database.contact(bob)?.lastSeenAt == nil)
        }

        @Test func onlineContactAnswersOnlyWhenSharing() async throws {
            let a = try session(alice, resource: "ask"), b = try session(bob, resource: "answer")
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let target = fullJID(of: b)
            try await LiveServer.setSharesLastSeen(false, on: b)

            // Off by default: the same error as for a client without the feature.
            let refused = await lastActivity(by: a, of: target)
            guard case .failure(let error) = refused else { Issue.record("Bob answered while not sharing"); return }
            #expect("\(error)".contains("feature") || "\(error)".contains("not_implemented"), "\(error)")

            try await LiveServer.setSharesLastSeen(true, on: b)
            let answered = await lastActivity(by: a, of: target)
            #expect(try answered.get() < 5)

            // Idle since bob left the app.
            b.setActive(false)
            try await Task.sleep(for: .seconds(2))
            #expect(try await a.lastActivity(of: target) >= 1)

            try await LiveServer.setSharesLastSeen(false, on: b)
            if case .success = await lastActivity(by: a, of: target) { Issue.record("Bob answered after stopping") }
        }

        @Test func strangersAreRefusedEvenWhenSharing() async throws {
            let b = try session(bob, resource: "shares"), c = try session(carol, resource: "stranger")
            try await connected(b)
            try await connected(c)
            defer { b.disconnect(); c.disconnect() }
            try await LiveServer.setSharesLastSeen(true, on: b)

            if case .success = await lastActivity(by: c, of: fullJID(of: b)) { Issue.record("Bob answered a stranger") }
            try await LiveServer.setSharesLastSeen(false, on: b)
        }
    }
}
