import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let bob = JID("bob@example.org")!

struct EncryptedUploadLimitTests {
    /// A pending file message to bob, in a chat that is encrypted by default, whose stored file is `size` bytes, a
    /// sparse file so a test doesn't write hundreds of megabytes.
    private func pending(on session: XMPPSession, size: Int64) async throws -> (YapnestKit.Message, YapnestKit.Attachment) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "movie.bin")
        try Data("x".utf8).write(to: source)
        let outgoing = session.outgoingMessages
        let prepared = try await outgoing.prepareFile(at: source)
        let message = try outgoing.stage([.file(prepared)], to: bob)[0]
        let attachment = try #require(try session.database.attachment(messageId: message.id!))
        let stored = try #require(session.attachments.url(for: attachment))
        let handle = try FileHandle(forWritingTo: stored)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return (message, attachment)
    }

    @Test func anEncryptedFileOverTheDownloadCapFailsAtOnceAndIsNeverRetried() async throws {
        let session = try makeSession(me)
        let (message, attachment) = try await pending(on: session, size: XMPPSession.maxDownloadSize + 1)
        #expect(message.encryption == .omemo)

        session.upload(message, attachment, to: bob)
        let id = try #require(message.id)
        await eventually("the message fails") { (try? session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: id) })??.status == .failed }
        let stored = try #require(try await session.database.reader.read { try YapnestKit.Message.fetchOne($0, key: id) })
        #expect(stored.error?.contains("Too large to send encrypted") == true)
        #expect(try session.database.attachment(messageId: message.id!)?.state == .pendingUpload)
    }
}
