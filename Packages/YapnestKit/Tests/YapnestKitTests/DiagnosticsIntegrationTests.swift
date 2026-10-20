import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    /// What a real session leaves in the exported log: the connection and the
    /// send, and none of the accounts, the server, the device or the text.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=ejabberd swift test --filter DiagnosticsIntegration`
    @Suite
    struct DiagnosticsIntegrationTests {
        @Test func aLiveConnectAndSendLeavesNoIdentifiersInTheExport() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
            let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
            DiagLog.use(store)
            defer { DiagLog.use(nil) }

            let alice = LiveServer.jid("alice"), bob = LiveServer.jid("bob")
            let resource = "diag-\(UUID().uuidString.prefix(6))"
            let session = try LiveServer.makeSession(alice, resource: resource, database: try AppDatabase.inMemory())
            session.connect()
            defer { session.disconnect() }
            try await LiveServer.waitUntil("the session") { session.state.value == .connected(isSyncing: false) }
            try session.setEncrypted(false, with: bob)
            let body = "diagnostic body \(UUID().uuidString.prefix(6))"
            try session.send(body, to: bob)
            try await LiveServer.waitUntil("the server to confirm it") {
                try session.database.reader.read { try Message.filter(Column("body") == body).fetchOne($0) }?.status ?? .pending >= .sent
            }

            let text = try String(contentsOf: DiagnosticsExport.make(store: store), encoding: .utf8)
            for event in ["Connecting", "Endpoint connected", "Signed in", "Connected", "Send queued", "Server acknowledged"] {
                #expect(text.contains(event), "\(event)")
            }
            for secret in ["alice", "bob", "localhost", "127.0.0.1", resource, "diagnostic body", "password"] {
                #expect(!text.contains(secret), "\(secret)")
            }
        }
    }
}
