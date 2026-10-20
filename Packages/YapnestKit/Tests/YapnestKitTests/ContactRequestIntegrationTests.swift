import Foundation
import Testing
@testable import YapnestKit

extension LiveServer {
    /// What a stranger's chosen name does on a real server.
    /// `YAPNEST_INTEGRATION=1 swift test --filter ContactRequestIntegration`
    @Suite
    struct ContactRequestIntegrationTests {
        let alice = LiveServer.jid("alice")
        let carol = LiveServer.jid("carol")

        private func connected(_ jid: JID) async throws -> XMPPSession {
            let session = try LiveServer.makeSession(jid, resource: "req-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
            session.connect()
            try await waitUntil("\(jid) to connect") { session.state.value == .connected(isSyncing: false) }
            return session
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        @Test func acceptingARequestLeavesTheRosterNameUnset() async throws {
            let a = try await connected(alice), c = try await connected(carol)
            defer { a.disconnect(); c.disconnect() }
            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
            try await Task.sleep(for: .milliseconds(500))

            try a.database.setSetting(.nickname, "\u{202E}Mom")
            a.addContact(carol)
            try await waitUntil("carol to get the request") { try c.database.contact(alice)?.hasContactRequest == true }
            // Cleaned on arrival.
            #expect(try c.database.contact(alice)?.requestedNickname == "Mom")

            try c.acceptContactRequest(from: alice)
            try await waitUntil("carol's roster to show alice") { try c.database.contact(alice)?.subscription == .both }
            let contact = try #require(try c.database.contact(alice))
            #expect(contact.name == nil)
            // Their request's name never becomes the contact's name. Once they
            // are a contact, the name alice has published (XEP-0172 PEP, which
            // a server may keep from earlier runs) may stand for her: Prosody
            // delivers it on subscribing, Openfire has none to deliver. It is
            // only displayed, never written to the roster.
            #expect(contact.nickname != "Mom")
            #expect(contact.displayName == (contact.nickname ?? "alice"))

            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
        }

        /// Opening a chat with someone new puts them on the roster.
        @Test func startingAChatAddsTheContact() async throws {
            let a = try await connected(alice), c = try await connected(carol)
            defer { a.disconnect(); c.disconnect() }
            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
            try await waitUntil("carol to be off alice's roster") { try !a.database.isInRoster(carol) }

            a.befriendForNewChat(carol)
            try await waitUntil("carol to be on alice's roster") { try a.database.isInRoster(carol) }
            try await waitUntil("carol to get the request") { try c.database.contact(alice)?.hasContactRequest == true }

            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
        }

        /// Starting a chat with someone who asked to be a contact accepts
        /// them, and their request leaves the chat list.
        @Test func startingAChatWithARequesterAcceptsThem() async throws {
            let a = try await connected(alice), c = try await connected(carol)
            defer { a.disconnect(); c.disconnect() }
            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
            try await Task.sleep(for: .milliseconds(500))

            c.addContact(alice)
            try await waitUntil("alice to get the request") { try a.database.contact(carol)?.hasContactRequest == true }

            a.befriendForNewChat(carol)
            // At once: waiting would let the server's roster push clear it anyway.
            #expect(try a.database.contact(carol)?.hasContactRequest == false)
            try await waitUntil("carol to be on alice's roster") { try a.database.isInRoster(carol) }
            // The request was answered, not just dropped: they see us back.
            try await waitUntil("carol to be subscribed to alice") { try c.database.contact(alice)?.subscription == .both }

            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
        }
    }
}
