import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    @Suite
    struct RestoreChatsIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func session(_ jid: JID) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "restore-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
        }

        private func connected(_ session: XMPPSession) async throws {
            session.connect()
            try await LiveServer.waitUntil("\(session.account) to connect and sync") { session.state.value == .connected(isSyncing: false) }
            try session.setEncrypted(false, with: session.account == alice ? bob : alice)
        }

        /// A new device whose first sync sees nothing of the archive, as when
        /// a chat's last message is older than the window.
        @Test func aChatOlderThanTheSyncWindowIsRestoredOnANewDevice() async throws {
            let a = try session(alice), b = try session(bob)
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }
            try await a.addContactAndWait(bob)
            let text = "long ago \(UUID().uuidString.prefix(8))"
            try a.send(text, to: bob)
            try await LiveServer.waitUntil("bob to receive it") {
                try b.database.reader.read { try Message.filter(Column("body") == text).fetchCount($0) } == 1
            }
            // The server has stored it once bob has it.
            let fresh = try session(alice)
            fresh.accountSyncWindow = -3600
            fresh.connect()
            defer { fresh.disconnect() }

            try await LiveServer.waitUntil("the new device to list the chat") {
                try fresh.database.reader.read { try Message.filter(Column("body") == text).fetchCount($0) } == 1
            }
            let chat = try #require(try await fresh.database.reader.read { try Conversation.filter(Column("peer") == bob).fetchOne($0) })
            // Dated by its message, which is new here, not by the placeholder.
            #expect(chat.lastActivityAt > Date().addingTimeInterval(-300))
            #expect(try await fresh.database.reader.read { try Message.filter(Column("isRead") == false).fetchCount($0) } == 0)
            try await LiveServer.waitUntil("the restore to finish") { try fresh.database.setting(.historyRestore) == nil }
        }
    }
}
