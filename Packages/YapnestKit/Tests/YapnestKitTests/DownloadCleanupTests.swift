import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let me = JID("me@example.org")!
private let alice = JID("alice@example.org")!

struct DownloadCleanupTests {
    /// A received attachment whose file has been saved, as a download does just before recording it.
    private func arrived(in session: XMPPSession) throws -> (messageId: Int64, file: URL) {
        let messageId = try session.database.writer.write { db -> Int64 in
            var conversation = Conversation(peer: alice)
            try conversation.insert(db)
            var message = YapnestKit.Message(conversationId: conversation.id!, direction: .incoming, sender: alice, body: "https://up.example/a.m4a", remoteId: "m1")
            try message.insert(db)
            try YapnestKit.Attachment(messageId: message.id!, url: message.body, name: "a.m4a", state: .remote).insert(db)
            return message.id!
        }
        let name = try session.attachments.save(Data("sound".utf8), name: "a.m4a")
        let file = session.attachments.directory.appending(path: name)
        try Data("bars".utf8).write(to: AudioWaveform.cacheURL(for: file))
        return (messageId, file)
    }

    @Test func aFileWhoseMessageWasDeletedMeanwhileIsDeleted() throws {
        let session = try makeSession(me)
        let (messageId, file) = try arrived(in: session)
        defer { try? FileManager.default.removeItem(at: session.attachments.directory) }
        try session.database.writer.write { db in _ = try YapnestKit.Message.deleteOne(db, key: messageId) }

        let recorded = try session.recordDownloaded(
            messageId: messageId, localFile: file.lastPathComponent, size: 5, mimeType: nil, width: nil, height: nil, duration: nil,
        )
        #expect(!recorded)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: AudioWaveform.cacheURL(for: file).path))
    }

    @Test func aFileThatIsRecordedIsKept() throws {
        let session = try makeSession(me)
        let (messageId, file) = try arrived(in: session)
        defer { try? FileManager.default.removeItem(at: session.attachments.directory) }

        let recorded = try session.recordDownloaded(
            messageId: messageId, localFile: file.lastPathComponent, size: 5, mimeType: nil, width: nil, height: nil, duration: nil,
        )
        #expect(recorded)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileThatCouldNotBeRecordedIsDeleted() throws {
        let session = try makeSession(me)
        let (messageId, file) = try arrived(in: session)
        defer { try? FileManager.default.removeItem(at: session.attachments.directory) }
        try session.database.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse BEFORE UPDATE ON attachment BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }

        #expect(throws: (any Error).self) {
            try session.recordDownloaded(messageId: messageId, localFile: file.lastPathComponent, size: 5, mimeType: nil, width: nil, height: nil, duration: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
