import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Publishing our display name to the real server, including onto a node
    /// another client created with a different access model.
    /// `YAPNEST_INTEGRATION=1 swift test --filter NicknameIntegration`
    @Suite
    struct NicknameIntegrationTests {
        let carol = LiveServer.jid("carol")

        private func connectedSession() async throws -> XMPPSession {
            let session = try LiveServer.makeSession(carol, resource: "nick-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
            session.connect()
            let deadline = Date().addingTimeInterval(10)
            while session.state.value != .connected(isSyncing: false) {
                if Date() > deadline { Issue.record("Timed out connecting"); break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return session
        }

        /// Starts each case from a server without the node.
        private func deleteNode(_ session: XMPPSession) async {
            await withCheckedContinuation { continuation in
                session.client.module(.pubsub).deleteNode(from: carol.martin, node: NS.nick) { _ in continuation.resume() }
            }
        }

        private func publishedNames(_ session: XMPPSession) async throws -> [String] {
            let items = try await session.client.module(.pubsub).retrieveItems(from: carol.martin, for: NS.nick)
            return items.items.compactMap { ProfileStanza.nick(from: $0.payload) }
        }

        @Test func setsChangesAndClearsTheName() async throws {
            let session = try await connectedSession()
            defer { session.disconnect() }
            await deleteNode(session)

            try await session.setNickname("Carol")
            #expect(try await publishedNames(session) == ["Carol"])
            #expect(session.nickname == "Carol")

            try await session.setNickname("Caroline")
            #expect(try await publishedNames(session) == ["Caroline"])

            try await session.setNickname(nil)
            #expect(try await publishedNames(session) == [])
            #expect(session.nickname == nil)

            // Taking back a name that isn't there is not an error.
            try await session.setNickname("  ")
        }

        /// The node as it stands before the setting matches, such as one an
        /// earlier version or another client left; publishing puts it right.
        @Test(arguments: [(sharesPublicly: false, left: "open", expected: "presence"), (sharesPublicly: true, left: "presence", expected: "open")])
        func reconfiguresANodeThatDoesNotMatchTheSetting(sharesPublicly: Bool, left: String, expected: String) async throws {
            let session = try await connectedSession()
            defer { session.disconnect() }
            try await LiveServer.forgettingSyncedSettings(of: session) {
                try await reconfigures(session, sharesPublicly: sharesPublicly, left: left, expected: expected)
            }
        }

        private func reconfigures(_ session: XMPPSession, sharesPublicly: Bool, left: String, expected: String) async throws {
            await deleteNode(session)
            try session.database.setFlag(.sharesProfilePublicly, sharesPublicly)

            try await session.publishPEP(node: NS.nick, itemId: "current", payload: ProfileStanza.nick("Old"), accessModel: left)

            try await session.setNickname("Carol")
            #expect(try await publishedNames(session) == ["Carol"])
            let accessModel: String? = try await withCheckedThrowingContinuation { continuation in
                session.client.module(.pubsub).retrieveNodeConfiguration(from: nil, node: NS.nick) { result in
                    continuation.resume(with: result.map { $0.accessModel?.rawValue })
                }
            }
            #expect(accessModel == expected)
            await deleteNode(session)
        }
    }
}
