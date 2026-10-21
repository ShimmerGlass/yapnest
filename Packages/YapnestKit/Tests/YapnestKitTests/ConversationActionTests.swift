import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct ConversationActionTests {
    let bob = JID("bob@example.org")!
    let me = JID("me@example.org")!

    @Test func pinArchiveUnreadAndDelete() throws {
        let database = try AppDatabase.inMemory()
        let conversation = try database.conversation(with: bob)
        let id = try #require(conversation.id)
        try database.insert(Message(conversationId: id, direction: .incoming, sender: bob, body: "hi", remoteId: "1"))
        try database.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "hey", remoteId: "2"))
        try database.markRead(conversationId: id)
        #expect(try database.chatList().first?.unreadCount == 0)

        try database.markUnread(conversationId: id)
        #expect(try database.chatList().first?.unreadCount == 1)

        try database.setPinned(true, conversationId: id)
        #expect(try database.chatList().first?.conversation.isPinned == true)

        try database.setArchived(true, conversationId: id)
        #expect(try database.chatList().isEmpty)
        #expect(try database.chatList(archived: true).count == 1)

        try database.deleteConversation(id: id)
        #expect(try database.chatList(archived: true).isEmpty)
        #expect(try database.reader.read { try Message.fetchCount($0) } == 0)
    }
}

struct MarkUnreadTests {
    let bob = JID("bob@example.org")!

    @Test func aRetractedLastMessageStaysReadAndTheOneBeforeBecomesUnread() throws {
        let database = try AppDatabase.inMemory()
        let id = try #require(try database.conversation(with: bob).id)
        let t = Date(timeIntervalSince1970: 1_000)
        try database.insert(Message(conversationId: id, direction: .incoming, sender: bob, body: "kept", timestamp: t, remoteId: "1"))
        var gone = Message(conversationId: id, direction: .incoming, sender: bob, body: "", timestamp: t.addingTimeInterval(10), remoteId: "2")
        gone.isRetracted = true
        try database.insert(gone)
        try database.markRead(conversationId: id)

        try database.markUnread(conversationId: id)

        let rows = try database.reader.read { try Message.order(Column("timestamp")).fetchAll($0) }
        #expect(rows.map(\.isRead) == [false, true])
        #expect(try database.chatList().first?.unreadCount == 1)
    }
}

struct DraftTests {
    let bob = JID("bob@example.org")!

    @Test func draftIsKeptWithoutMovingTheChat() throws {
        let database = try AppDatabase.inMemory()
        let id = try #require(try database.conversation(with: bob).id)
        let before = try #require(try database.chatList().first).conversation.lastActivityAt

        try database.setDraft("half a thought", peer: bob)
        #expect(try database.draft(peer: bob) == "half a thought")
        let item = try #require(try database.chatList().first)
        #expect(item.conversation.draft == "half a thought")
        #expect(item.conversation.lastActivityAt == before)
        #expect(item.conversation.id == id)

        try database.setDraft("  \n", peer: bob)
        #expect(try database.draft(peer: bob) == nil)
        try database.setDraft("again", peer: bob)
        try database.setDraft(nil, peer: bob)
        #expect(try database.draft(peer: bob) == nil)
    }
}

struct DraftChatTests {
    let bob = JID("bob@example.org")!
    let carol = JID("carol@example.org")!

    @Test func draftInAChatWithoutMessagesCreatesItsConversation() throws {
        let database = try AppDatabase.inMemory()
        try database.setDraft("first words", peer: bob)
        #expect(try database.draft(peer: bob) == "first words")
        let item = try #require(try database.chatList().first)
        #expect(item.conversation.peer == bob)
        #expect(item.lastMessage == nil)

        // The first message then moves it up like any other.
        let id = try #require(item.conversation.id)
        try database.insert(Message(conversationId: id, direction: .outgoing, sender: carol, body: "hi", remoteId: "1"))
        #expect(try database.chatList().count == 1)
    }

    @Test func clearingADraftMakesNoConversation() throws {
        let database = try AppDatabase.inMemory()
        try database.setDraft(nil, peer: bob)
        try database.setDraft("  ", peer: bob)
        #expect(try database.chatList().isEmpty)
    }

    @Test func typingIsOnlyWhatTheUserTypes() {
        var tracker = DraftTracker()
        let typed = tracker.typed("hel", editing: false)
        #expect(typed)
        #expect(tracker.isDirty)
        let saved = tracker.flush()
        #expect(saved == "hel")
        let savedAgain = tracker.flush()
        #expect(savedAgain == nil)
        // The same text again changes nothing to save.
        let retyped = tracker.typed("hel", editing: false)
        #expect(!retyped)
        // An edit's text isn't a draft.
        let edited = tracker.typed("edited", editing: true)
        #expect(!edited)
        #expect(tracker.composerText == "hel")
    }

    @Test func aRestoredDraftIsNotSavedAgain() {
        var tracker = DraftTracker()
        tracker.restore("from before")
        #expect(!tracker.isDirty)
        let saved = tracker.flush()
        #expect(saved == nil)
        #expect(tracker.composerText == "from before")
        // Clearing after a send still clears the stored one.
        let cleared = tracker.typed("", editing: false)
        #expect(cleared)
        let savedClear = tracker.flush()
        #expect(savedClear == "")
    }

    @Test func signingOutForgetsUnsavedDrafts() {
        let writer = DraftWriter()
        writer.note("for the old account", for: bob)
        writer.forgetAll()
        #expect(writer.pending(for: bob) == nil)
    }

    @Test func pendingDraftIsKeptUntilItsOwnTextLands() async throws {
        let database = try AppDatabase.inMemory()
        let writer = DraftWriter()
        writer.note("typed", for: bob)
        #expect(writer.pending(for: bob) == "typed")

        writer.save("typed", for: bob, to: database)
        #expect(writer.pending(for: bob) == "typed")
        writer.note("typed more", for: bob)
        await writer.settled()
        // The write carried older text than what's been noted since.
        #expect(writer.pending(for: bob) == "typed more")
        #expect(try database.draft(peer: bob) == "typed")

        writer.save("typed more", for: bob, to: database)
        await writer.settled()
        #expect(writer.pending(for: bob) == nil)
        #expect(try database.draft(peer: bob) == "typed more")
    }

    @Test func writesLandInTheOrderTheyWereMade() async throws {
        let database = try AppDatabase.inMemory()
        let writer = DraftWriter()
        for text in ["a", "ab", "abc", "abcd", ""] + (0..<20).map({ "t\($0)" }) {
            writer.save(text, for: bob, to: database)
        }
        await writer.settled()
        #expect(try database.draft(peer: bob) == "t19")
        #expect(writer.pending(for: bob) == nil)
    }

    @Test func fitsAgainOnWidthOrFontChange() {
        var trigger = FitTrigger()
        let first = trigger.changed(width: 300, pointSize: 17)
        #expect(first)
        let same = trigger.changed(width: 300, pointSize: 17)
        #expect(!same)
        let font = trigger.changed(width: 300, pointSize: 20)
        #expect(font)
        let width = trigger.changed(width: 320, pointSize: 20)
        #expect(width)
        let sameAgain = trigger.changed(width: 320, pointSize: 20)
        #expect(!sameAgain)
    }

    @Test func rowOffsetsFollowTheLayoutDirection() {
        func x(_ rtl: Bool, _ end: ComposerRowOffset.End, content: CGFloat = 500) -> CGFloat {
            ComposerRowOffset.x(contentWidth: content, frameWidth: 300, rightToLeft: rtl, showing: end)
        }
        // The newest tile: the right end, or the left one when mirrored.
        #expect(x(false, .trailing) == 200)
        #expect(x(true, .trailing) == 0)
        // The best suggestion: the left end, or the right one when mirrored.
        #expect(x(false, .leading) == 0)
        #expect(x(true, .leading) == 200)
        // Nothing to scroll when it fits.
        #expect(x(true, .leading, content: 300) == 0)
        #expect(x(false, .trailing, content: 100) == 0)
    }
}

struct ConversationFilesTests {
    let bob = JID("bob@example.org")!
    let carol = JID("carol@example.org")!

    @Test func deletingAConversationReturnsItsOwnAttachmentsOnly() throws {
        let database = try AppDatabase.inMemory()
        let bobId = try #require(try database.conversation(with: bob).id)
        let carolId = try #require(try database.conversation(with: carol).id)
        let mine = try database.insert(Message(conversationId: bobId, direction: .incoming, sender: bob, body: "a", remoteId: "1"))
        let theirs = try database.insert(Message(conversationId: carolId, direction: .incoming, sender: carol, body: "b", remoteId: "2"))
        try database.writer.write { db in
            try Attachment(messageId: mine.id!, url: nil, name: "a.jpg", localFile: "a.jpg", state: .ready).insert(db)
            try Attachment(messageId: theirs.id!, url: nil, name: "b.jpg", localFile: "b.jpg", state: .ready).insert(db)
        }

        let removed = try database.deleteConversation(id: bobId)
        #expect(removed.map(\.localFile) == ["a.jpg"])
        #expect(try database.reader.read { try Attachment.fetchCount($0) } == 1)
    }

    @Test func theSessionRemovesTheFilesOfADeletedConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttachmentStore(directory: directory)
        let database = try AppDatabase.inMemory()
        let session = try XMPPSession(
            credentials: .init(jid: JID("me@example.org")!, password: "x"), resource: "test",
            database: database, attachments: store,
        )
        let id = try #require(try database.conversation(with: bob).id)
        let message = try database.insert(Message(conversationId: id, direction: .incoming, sender: bob, body: "a", remoteId: "1"))
        let file = try store.save(Data("x".utf8), name: "a.jpg")
        try database.writer.write { try Attachment(messageId: message.id!, url: nil, name: "a.jpg", localFile: file, state: .ready).insert($0) }
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: file).path))

        try session.deleteConversation(id: id)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: file).path))
    }
}

struct ReadThroughTests {
    let bob = JID("bob@example.org")!

    @Test func readingThroughAMessageLeavesNewerOnesUnreadAndNeverGoesBack() throws {
        let database = try AppDatabase.inMemory()
        let id = try #require(try database.conversation(with: bob).id)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for n in 0..<4 {
            try database.insert(Message(conversationId: id, direction: .incoming, sender: bob, body: "m\(n)", timestamp: t0 + Double(n), remoteId: "m\(n)"))
        }
        #expect(try database.hasUnread(conversationId: id, through: t0 + 1))
        try database.markRead(conversationId: id, through: t0 + 1)
        #expect(try database.chatList().first?.unreadCount == 2)

        // An older message than the read point has nothing left to read.
        #expect(try database.hasUnread(conversationId: id, through: t0) == false)
        try database.markRead(conversationId: id, through: t0)
        #expect(try database.chatList().first?.unreadCount == 2)

        #expect(try database.lastIncoming(conversationId: id, through: t0 + 2)?.remoteId == "m2")
    }
}
