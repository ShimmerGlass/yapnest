import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!

/// The share extension's send, with a stand-in for the session that would
/// connect.
struct ShareSenderSessionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "share-session-\(UUID().uuidString)")
    let wire = FakeWire()

    private func sender() throws -> ShareSender {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sender = ShareSender(
            credentials: .init(jid: me, password: "x"), directory: root.appending(path: "account"), resource: "share",
            lock: ProcessLock(url: root.appending(path: "session.lock")),
        )
        let wire = self.wire
        sender.makeSession = { database in
            let session = try XMPPSession(credentials: .init(jid: me, password: "x"), resource: "share", database: database, mode: .share, identityKeys: testIdentityKeys(for: database))
            session.connectForTesting(wire)
            return session
        }
        return sender
    }

    private func chat(encrypted: Bool) throws {
        try AccountDirectory(url: root.appending(path: "account")).openDatabase().setEncrypted(encrypted, with: alice)
    }

    @Test func aMessageTheServerTookIsSent() async throws {
        try chat(encrypted: false)
        let outcome = await (try sender()).send(ShareContent(texts: ["hello"]), to: alice, timeout: 10)

        #expect(outcome == .sent)
        #expect(wire.messages.contains { $0.body == "hello" })
    }

    @Test func aMessageThatWasWrittenButCouldNotBeSentFailsInTheApp() async throws {
        // Encrypting for a contact with no devices fails, after the message
        // was written to the database.
        try chat(encrypted: true)
        wire.answer { FakeWire.error(to: $0) }
        let outcome = await (try sender()).send(ShareContent(texts: ["hello"]), to: alice, timeout: 10)

        guard case .failedInApp = outcome else {
            Issue.record("expected failedInApp, got \(outcome)")
            return
        }
        // The app has it, with its retry button.
        let database = try AccountDirectory(url: root.appending(path: "account")).openDatabase()
        let failed = try await database.reader.read { try Message.filter(Column("status") == Message.Status.failed).fetchCount($0) }
        #expect(failed == 1)
    }
}
