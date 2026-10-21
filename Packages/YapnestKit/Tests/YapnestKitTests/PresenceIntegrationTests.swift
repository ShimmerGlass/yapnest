import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Presence and avatars between alice and bob on the local dev server (`YAPNEST_SERVER`).
    /// `YAPNEST_INTEGRATION=1 swift test --filter PresenceIntegration`
    @Suite
    struct PresenceIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func session(_ jid: JID) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "presence-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        private func connected(_ session: XMPPSession) async throws {
            session.connect()
            try await waitUntil("\(session.account) to connect") { session.state.value == .connected(isSyncing: false) }
        }

        @Test func presenceAndAvatar() async throws {
            let a = try session(alice), b = try session(bob)
            try await connected(a)
            try await connected(b)
            defer { a.disconnect() }

            // Adding each other is enough for mutual subscription.
            a.addContact(bob)
            b.addContact(alice)
            try await waitUntil("alice to see bob online") { a.presence(of: bob) == .online }
            try await waitUntil("alice's roster to show the subscription") {
                try a.database.reader.read { try Contact.fetchOne($0, key: bob)?.seesPresence } == true
            }

            b.setShowForTesting(.dnd)
            try await waitUntil("alice to see bob busy") { a.presence(of: bob) == .busy }

            // A 1×1 PNG, unique per run so alice really fetches it.
            var png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
            png.append(contentsOf: Array(UUID().uuidString.utf8))
            let hash = AvatarStore.hash(of: png)
            try await b.publishAvatar(png, mimeType: "image/png", width: 1, height: 1)
            try await waitUntil("alice to receive bob's avatar") {
                try a.database.reader.read { try Contact.fetchOne($0, key: bob)?.avatarHash } == hash
            }
            #expect(try Data(contentsOf: a.avatars.url(for: hash)) == png)

            b.disconnect()
            try await waitUntil("alice to see bob offline") { a.presence(of: bob) == .offline }
        }
    }
}
