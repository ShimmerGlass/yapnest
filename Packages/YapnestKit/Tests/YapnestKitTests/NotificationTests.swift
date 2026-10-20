import Foundation
import Testing
@testable import YapnestKit

struct NotificationTests {
    let db: AppDatabase
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @discardableResult
    private func incoming(_ body: String, from sender: JID? = nil, in conversation: Conversation, nick: String? = nil) throws -> Message {
        try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: sender ?? conversation.peer, nick: nick, body: body,
                              remoteId: UUID().uuidString))
    }

    /// What ingesting a correction does to the stored message.
    private func edit(_ message: Message, to body: String, at date: Date = Date()) throws {
        try db.writer.write { db in
            var edited = try #require(try Message.fetchOne(db, key: message.id))
            edited.setBody(body)
            edited.editedAt = date
            try edited.update(db)
        }
    }

    @Test func anEditOfAClaimedMessageIsReportedAsAnEdit() throws {
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        let message = try incoming("lunch at 5?", in: chat)
        #expect(try db.claimNotificationsAndEdits().new.map(\.body) == ["lunch at 5?"])

        try edit(message, to: "lunch at 6?")
        let claimed = try db.claimNotificationsAndEdits()
        #expect(claimed.new.isEmpty)
        #expect(claimed.edited.map(\.body) == ["lunch at 6?"])
        #expect(claimed.edited.first?.messageId == message.id)
    }

    /// The mark moves with the clock, so a repeat inside the slack is possible
    /// and harmless (it replaces a notification with the same text); an edit
    /// from before the slack isn't reported again.
    @Test func anEditIsReportedAgainOnlyWithinTheClockSlack() throws {
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        let message = try incoming("one", in: chat)
        let start = Date()
        _ = try db.claimNotificationsAndEdits(now: start)
        try edit(message, to: "two", at: start)
        #expect(try db.claimNotificationsAndEdits(now: start).edited.count == 1)
        #expect(try db.claimNotificationsAndEdits(now: start).edited.count == 1)
        let later = start.addingTimeInterval(AppDatabase.notificationClockSlack + 60)
        _ = try db.claimNotificationsAndEdits(now: later)
        #expect(try db.claimNotificationsAndEdits(now: later).edited.isEmpty)
    }

    @Test func anEditOfAReadMessageIsntReported() throws {
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        let message = try incoming("seen", in: chat)
        _ = try db.claimNotifications()
        try db.markRead(conversationId: chat.id!)
        try edit(message, to: "seen, edited")
        let claimed = try db.claimNotificationsAndEdits()
        #expect(claimed.new.isEmpty && claimed.edited.isEmpty)
    }

    @Test func anEditInAMutedGroupIsntReported() throws {
        let room = JID("cake@conference.example.org")!
        let group = try db.joinGroupChat(room, nickname: "Me", name: "Cake club")
        let chat = try #require(try db.conversation(id: group.conversationId))
        try db.updateGroupChat(room) { $0.notify = .never }
        _ = try db.claimNotifications()
        let message = try incoming("quiet", in: chat, nick: "ally")
        _ = try db.claimNotifications()
        try edit(message, to: "quieter")
        #expect(try db.claimNotificationsAndEdits().edited.isEmpty)
    }

    @Test func anEditOfAMessageNeverReceivedIsStillNew() throws {
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        // Ingest stores a correction of an unknown message as a message.
        var stored = Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "fixed", remoteId: "c1")
        stored.editedAt = Date()
        try db.insert(stored)
        let claimed = try db.claimNotificationsAndEdits()
        #expect(claimed.new.map(\.body) == ["fixed"])
        #expect(claimed.edited.isEmpty)
    }

    @Test func onlyChatsWithUnreadMessagesKeepTheirNotifications() {
        let bob = JID("bob@example.org")!
        let gone = JID("gone@example.org")!
        let delivered = [("1", alice.description), ("2", bob.description), ("3", gone.description), ("4", "")]
        // Bob is read, and gone is archived or deleted: not counted at all.
        let stale = AppDatabase.staleNotifications(threads: delivered.map { (id: $0.0, thread: $0.1) }, unread: [alice: 2, bob: 0])
        #expect(stale == ["2", "3"])
    }

    @Test func eachMessageIsClaimedOnce() throws {
        let chat = try db.conversation(with: alice)
        try incoming("from before", in: chat)
        // The first claim only sets the mark: history doesn't notify.
        #expect(try db.claimNotifications().isEmpty)

        try incoming("lunch?", in: chat)
        try db.insert(Message(conversationId: chat.id!, direction: .outgoing, sender: me, body: "mine", remoteId: "o1"))
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["lunch?"])
        #expect(claimed.first?.title == "alice")
        #expect(claimed.first?.peer == alice)
        #expect(try db.claimNotifications().isEmpty)
    }

    /// A new device claims before its first catch-up, with nothing stored
    /// yet; the week of history that follows isn't news.
    @Test func historyStoredLaterDoesntNotify() throws {
        let chat = try db.conversation(with: alice)
        #expect(try db.claimNotifications().isEmpty)
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "last week",
                              timestamp: Date().addingTimeInterval(-3 * 24 * 3600), remoteId: "old"))
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "just now", remoteId: "new"))
        #expect(try db.claimNotifications().map(\.body) == ["just now"])
    }

    @Test func readMessagesDontNotify() throws {
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        try incoming("seen elsewhere", in: chat)
        try db.markRead(conversationId: chat.id!)
        #expect(try db.claimNotifications().isEmpty)
        #expect(try db.unreadCount() == 0)
    }

    @Test func meMessagesReadAsActions() throws {
        let chat = try db.conversation(with: alice)
        try db.updateRosterItem(jid: alice, name: "Alice Liddell", subscription: .both, isPending: false)
        let room = JID("cake@conference.example.org")!
        let group = try db.joinGroupChat(room, nickname: "me", name: "Cake club")
        let groupChat = try #require(try db.conversation(id: group.conversationId))
        _ = try db.claimNotifications()

        try incoming("/me waves", in: chat)
        try incoming("/me bakes", from: room, in: groupChat, nick: "ally")
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["Alice Liddell waves", "ally bakes"])
    }

    @Test func blankLinesAroundABodyAreLeftOutOfTheBanner() throws {
        let chat = try db.conversation(with: alice)
        let room = JID("cake@conference.example.org")!
        let group = try db.joinGroupChat(room, nickname: "me", name: "Cake club")
        let groupChat = try #require(try db.conversation(id: group.conversationId))
        _ = try db.claimNotifications()

        try incoming("\n  \nHello\n\n", in: chat)
        try incoming("\n  \nHello\n\n", from: room, in: groupChat, nick: "ally")
        try incoming("/me waves\n \n", in: chat)
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["Hello", "Hello", "alice waves"])
    }

    @Test func trimmingBlankEdgeLines() {
        #expect("\n \n\t\n".trimmingBlankEdgeLines == "")
        #expect("\n  \nHello\n\n".trimmingBlankEdgeLines == "Hello")
        #expect("a\n\n  b".trimmingBlankEdgeLines == "a\n\n  b")
        #expect("  indented\n".trimmingBlankEdgeLines == "  indented")
    }

    @Test func groupMessagesNameTheGroupAndTheAuthor() throws {
        let room = JID("cake@conference.example.org")!
        let group = try db.joinGroupChat(room, nickname: "me", name: "Cake club")
        let chat = try #require(try db.conversation(id: group.conversationId))
        try db.updateRosterItem(jid: alice, name: "Alice Liddell", subscription: .both, isPending: false)
        _ = try db.claimNotifications()

        try incoming("chocolate", from: alice, in: chat, nick: "ally")
        try incoming("vanilla", from: room, in: chat, nick: "stranger")
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.title) == ["Cake club", "Cake club"])
        #expect(claimed.map(\.subtitle) == ["Alice Liddell", "stranger"])
        #expect(claimed.first?.content(badge: 2).threadIdentifier == room.description)
    }

    @Test func quietContentMakesNoSoundAndIsMarked() {
        let loud = MessageNotification(messageId: 1, peer: JID("a@example.org")!, title: "A", body: "hi", timestamp: Date())
        var quiet = loud
        quiet.isQuiet = true
        #expect(loud.content(badge: 1).sound != nil && loud.content(badge: 1).userInfo[MessageNotification.quietKey] == nil)
        let content = quiet.content(badge: 1)
        #expect(content.sound == nil && content.interruptionLevel == .passive && content.badge == 1)
        #expect(content.userInfo[MessageNotification.quietKey] as? Bool == true)
        #expect(content.userInfo[MessageNotification.peerKey] as? String == "a@example.org")
    }

    @Test func groupsNotifyAsTheirSettingSays() throws {
        let room = JID("cake@conference.example.org")!
        let group = try db.joinGroupChat(room, nickname: "Me", name: "Cake club")
        let chat = try #require(try db.conversation(id: group.conversationId))
        _ = try db.claimNotifications()

        try db.updateGroupChat(room) { $0.notify = .onMention }
        try db.insert(Message(conversationId: chat.id!, direction: .outgoing, sender: me, nick: "Me", body: "mine", remoteId: "o1", serverId: "s1"))
        try incoming("anyone?", in: chat, nick: "ally")
        try incoming("meme of the day", in: chat, nick: "ally")
        try incoming("hey me, cake?", in: chat, nick: "ally")
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: room, nick: "ally", body: "agreed",
                              remoteId: "r1", replyToId: "s1"))
        let claimed = try db.claimNotifications()
        #expect(claimed.map(\.body) == ["anyone?", "meme of the day", "hey me, cake?", "agreed"])
        #expect(claimed.map(\.isQuiet) == [true, true, false, false])
        #expect(claimed.allSatisfy { $0.title == "Cake club" && $0.isGroup })
        #expect(claimed.first?.subtitle == "ally")

        try db.updateGroupChat(room) { $0.notify = .never }
        try incoming("hey me", in: chat, nick: "ally")
        let muted = try db.claimNotifications()
        #expect(muted.map(\.isQuiet) == [true])
        #expect(muted.first?.title == "Cake club" && muted.first?.subtitle == "ally")
        #expect(try db.unreadCount() == 0)

        try db.updateGroupChat(room) { $0.notify = .always }
        #expect(try db.unreadCount() == 5)
        try incoming("hello", in: chat, nick: "ally")
        #expect(try db.claimNotifications().map(\.isQuiet) == [false])
    }

    @Test func undecryptableAndFilesSaySoInstead() throws {
        let chat = try db.conversation(with: alice)
        _ = try db.claimNotifications()
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "🔒", encryption: .omemoUndecryptable, remoteId: "e1"))
        #expect(try db.claimNotifications().map(\.body) == ["🔒 Encrypted message"])
    }

    @Test func lockExcludesOtherHolders() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)")
        let app = ProcessLock(url: url), extensionLock = ProcessLock(url: url)
        #expect(app.tryLock())
        #expect(!extensionLock.tryLock())
        #expect(!extensionLock.lock(timeout: 0.3))
        app.unlock()
        #expect(extensionLock.tryLock())
        #expect(!app.tryLock())
    }

    @Test func lockRecordsItsHolderOnlyWhileHeld() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)")
        let holder = ProcessLock(url: url), observer = ProcessLock(url: url)
        #expect(observer.holder == nil)
        #expect(holder.tryLock(as: .share))
        #expect(observer.holder == .share)
        holder.unlock()
        // The role is left in the file, but nobody holds the lock.
        #expect(observer.holder == nil)
        #expect(holder.tryLock())
        #expect(observer.holder == nil)
        holder.unlock()
        #expect(holder.tryLock(as: .app))
        #expect(observer.holder == .app)
    }
}
