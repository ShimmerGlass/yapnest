import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// A file from alice to bob over Jingle and in-band bytestreams, through
    /// the server.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=ejabberd swift test --filter FileTransferIntegration`
    @Suite
    struct FileTransferIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func device(_ jid: YapnestKit.JID, _ name: String) async throws -> XMPPSession {
            let session = try LiveServer.makeSession(jid, resource: "ft-\(name)-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
            try await LiveServer.connected(session)
            return session
        }

        private enum LiveServerError: Error { case noDevice }

        private func pair() async throws -> (alice: XMPPSession, bob: XMPPSession, device: Martin.JID) {
            let a = try await device(alice, "alice")
            let b = try await device(bob, "bob")
            try await LiveServer.befriend(a, b)
            var found: Martin.JID?
            try await LiveServer.waitUntil("alice to find a device of bob that takes files") {
                found = a.fileTransferDevice(of: bob)
                return found != nil
            }
            return (a, b, try #require(found))
        }

        /// Stages a file for bob in an unencrypted chat, as a send that the server couldn't take would.
        private func stage(_ session: XMPPSession, size: Int) async throws -> (YapnestKit.Message, YapnestKit.Attachment, Data) {
            var conversation = try session.database.conversation(with: bob)
            conversation.isEncrypted = false
            try await session.database.writer.write { [conversation] in try conversation.update($0) }
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
            let url = FileManager.default.temporaryDirectory.appending(path: "ft-live-\(UUID().uuidString).bin")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let outgoing = session.outgoingMessages
            let file = try await outgoing.prepareFile(at: url, name: "live.bin")
            let message = try outgoing.stage([.file(file)], to: bob)[0]
            return (message, try #require(try session.database.attachment(messageId: message.id!)), data)
        }

        private func received(_ session: XMPPSession) async throws -> YapnestKit.Attachment? {
            try await session.database.reader.read { try YapnestKit.Attachment.order(Column("messageId").desc).fetchOne($0) }
        }

        @Test func aFileGoesFromOneAccountToTheOther() async throws {
            let (a, b, device) = try await pair()
            defer { a.disconnect(); b.disconnect() }
            let (message, attachment, data) = try await stage(a, size: 300_000)

            _ = a.beginTransfer(message.id!)
            try await a.sendOverJingle(message, attachment, to: device)
            a.endTransfer(message.id!)

            try await LiveServer.waitUntil("bob to have the file") { try await received(b)?.state == .ready }
            let stored = try #require(await received(b))
            #expect(try Data(contentsOf: try #require(b.attachments.url(for: stored))) == data)
            #expect(stored.name == "live.bin" && stored.size == Int64(data.count))
            let sent = try #require(await a.database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
            #expect(sent.status == .delivered)
            #expect(try await a.database.attachment(messageId: message.id!)?.state == .ready)
            let row = try await b.database.reader.read { try YapnestKit.Message.fetchOne($0, key: stored.messageId) }
            #expect(row?.sender == alice && row?.body.isEmpty == true && row?.direction == .incoming)
        }

        @Test func anOfferAboveTheAutomaticLimitWaitsForBob() async throws {
            let (a, b, device) = try await pair()
            defer { a.disconnect(); b.disconnect() }
            b.autoAcceptedOfferSize = 1000
            let (message, attachment, data) = try await stage(a, size: 50_000)

            _ = a.beginTransfer(message.id!)
            let sending = Task { try await a.sendOverJingle(message, attachment, to: device) }
            try await LiveServer.waitUntil("bob to see the offer") { try await received(b)?.state == .offered }
            try await Task.sleep(for: .seconds(1))
            let waiting = try #require(await received(b))
            #expect(waiting.state == .offered)

            b.download(waiting)
            try await sending.value
            a.endTransfer(message.id!)
            try await LiveServer.waitUntil("bob to have the file") { try await received(b)?.state == .ready }
            let stored = try #require(await received(b))
            #expect(try Data(contentsOf: try #require(b.attachments.url(for: stored))) == data)
        }

        @Test func aDeclinedOfferFailsAlicesMessage() async throws {
            let (a, b, device) = try await pair()
            defer { a.disconnect(); b.disconnect() }
            b.autoAcceptedOfferSize = 0
            let (message, attachment, _) = try await stage(a, size: 2000)

            _ = a.beginTransfer(message.id!)
            let sending = Task { try await a.sendOverJingle(message, attachment, to: device) }
            try await LiveServer.waitUntil("bob to see the offer") { try await received(b)?.state == .offered }
            b.declineOffer(try #require(await received(b)))
            await #expect(throws: FileTransferFailure.self) { try await sending.value }
            a.endTransfer(message.id!)
            let ended = try await received(b)
            #expect(ended?.state == .unavailable)
        }
    }
}
