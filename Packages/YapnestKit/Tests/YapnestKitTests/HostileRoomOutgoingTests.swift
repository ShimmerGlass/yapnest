import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let room = YapnestKit.JID("cake@rooms.example.org")!
private let image = "https://up.example/1/cat.png"
private let oob = "<x xmlns='jabber:x:oob'><url>\(image)</url></x>"

private func stanza(_ xml: String) -> Martin.Message {
    Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
}

/// A room can say any message is ours; only what was written here is vouched for.
@Suite struct HostileRoomOutgoingTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
        _ = try db.joinGroupChat(room, nickname: "me", name: "Cake")
    }

    private func ingest(_ xml: String, source: InboundMessage.Source = .live, ownOccupantId: String? = nil) throws -> IngestResult {
        let context = RoomContext(jid: room, nickname: "me", trustsOccupantIds: ownOccupantId != nil, ownOccupantId: ownOccupantId, isNonAnonymous: true)
        return try db.ingest(try #require(InboundMessage(groupchat: stanza(xml), room: context, account: me, source: source)))
    }

    private func missed() throws -> [Int64] {
        try db.missedImages(since: Date().addingTimeInterval(-86400), limit: 50, maxSize: XMPPSession.autoDownloadSize).map(\.messageId)
    }

    private func isOurs(_ message: YapnestKit.Message) -> Bool {
        YapnestKit.Message.isTrustedOutgoing(isOutgoing: message.direction == .outgoing, isWrittenHere: message.isWrittenHere, inGroup: true)
    }

    private func autoDownloads(_ message: YapnestKit.Message, isPrivate: Bool = false) -> Bool {
        XMPPSession.trustsForAutoDownload(isOutgoing: isOurs(message), isPrivateGroup: isPrivate, trustsGroupMembers: true, isTrusted: false)
    }

    private func previews(_ message: YapnestKit.Message) -> LinkPreviewPolicy.Decision {
        LinkPreviewPolicy.decide(global: .askPerConversation, chat: nil, isOurs: isOurs(message))
    }

    private func expectNotVouched(_ result: IngestResult) throws {
        let message = try #require(result.newMessage)
        #expect(message.direction == .outgoing)
        #expect(!message.isWrittenHere)
        #expect(!autoDownloads(message))
        #expect(previews(message) == .ask)
        #expect(try missed().isEmpty)
    }

    @Test func archivedMessageNamingUsAsItsAuthorIsNotVouchedFor() throws {
        let result = try ingest("""
            <message from='cake@rooms.example.org/x' type='groupchat' id='a1'>
              <body>\(image)</body>\(oob)
              <x xmlns='http://jabber.org/protocol/muc#user'><item jid='me@example.org'/></x>
            </message>
            """, source: .archive(serverId: "r1", timestamp: Date()))
        try expectNotVouched(result)
        #expect(result.newAttachment != nil)
    }

    @Test func liveMessageUnderOurNickIsNotVouchedFor() throws {
        try expectNotVouched(try ingest("<message from='cake@rooms.example.org/me' type='groupchat' id='l1'><body>\(image)</body>\(oob)</message>"))
    }

    @Test func liveMessageWithOurOccupantIdIsNotVouchedFor() throws {
        try expectNotVouched(try ingest("""
            <message from='cake@rooms.example.org/x' type='groupchat' id='o1'>
              <body>\(image)</body>\(oob)<occupant-id xmlns='urn:xmpp:occupant-id:0' id='mine'/>
            </message>
            """, ownOccupantId: "mine"))
    }

    @Test func privateGroupsStillFetchWhatTheRoomCallsOurs() throws {
        let message = try #require(try ingest("<message from='cake@rooms.example.org/me' type='groupchat' id='l1'><body>\(image)</body>\(oob)</message>").newMessage)
        #expect(autoDownloads(message, isPrivate: true))
        try db.writer.write { db in
            try db.execute(sql: "UPDATE groupChat SET isMembersOnly = 1, isNonAnonymous = 1")
        }
        #expect(try missed() == [message.id!])
    }

    @Test func ourOwnMessageStaysVouchedForWhenTheRoomEchoesIt() throws {
        let store = AttachmentStore(directory: FileManager.default.temporaryDirectory.appending(path: "hostile-\(UUID().uuidString)"))
        let outgoing = OutgoingMessages(database: db, attachments: store, account: me)
        let staged = try outgoing.stage([.text(image)], to: room)[0]
        #expect(staged.isWrittenHere)
        try db.writer.write { db in
            try YapnestKit.Attachment(messageId: staged.id!, url: image, name: "cat.png", state: .remote).insert(db)
        }

        let echo = try ingest("""
            <message from='cake@rooms.example.org/me' type='groupchat' id='\(staged.remoteId!)'>
              <body>\(image)</body>\(oob)
              <origin-id xmlns='urn:xmpp:sid:0' id='\(staged.originId!)'/>
              <stanza-id xmlns='urn:xmpp:sid:0' by='cake@rooms.example.org' id='r5'/>
            </message>
            """)
        #expect(echo.newMessage == nil)
        let stored = try #require(try db.reader.read { try YapnestKit.Message.fetchOne($0, key: staged.id!) })
        #expect(stored.isWrittenHere && stored.serverId == "r5")
        #expect(autoDownloads(stored))
        #expect(previews(stored) == .show)
        #expect(try missed() == [staged.id!])
    }

    @Test func directChatsStillTrustTheirOwnServer() {
        #expect(YapnestKit.Message.isTrustedOutgoing(isOutgoing: true, isWrittenHere: false, inGroup: false))
        #expect(YapnestKit.Message.isTrustedOutgoing(isOutgoing: true, isWrittenHere: true, inGroup: true))
        #expect(!YapnestKit.Message.isTrustedOutgoing(isOutgoing: true, isWrittenHere: false, inGroup: true))
        #expect(!YapnestKit.Message.isTrustedOutgoing(isOutgoing: false, isWrittenHere: true, inGroup: true))
    }

    @Test func migrationKeepsEarlierOutgoingMessagesTrusted() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v26-attachment-thumbnail")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversation (peer, kind, lastActivityAt) VALUES ('a@example.org', 'chat', 0)")
            for direction in ["outgoing", "incoming"] {
                try db.execute(sql: """
                    INSERT INTO message (conversationId, direction, sender, body, timestamp, status, isRead, encryption)
                    VALUES (1, ?, 'a@example.org', 'hi', 0, 'received', 0, 'none')
                    """, arguments: [direction])
            }
        }
        try AppDatabase.migrator.migrate(queue)
        let flags = try queue.read { db in try Bool.fetchAll(db, sql: "SELECT isWrittenHere FROM message ORDER BY id") }
        #expect(flags == [true, false])
    }
}
