import Foundation
import Testing
@testable import YapnestKit

private struct TestFailure: Error {}

/// One at a time: `PendingSendsSignal` is a Darwin notification, so one
/// test's signal to the app reaches every other test listening for it.
@Suite(.serialized)
struct ShareTests {
    let me = JID("me@example.org")!, alice = JID("alice@example.org")!
    let directory = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)")

    private func file(_ name: String, _ contents: String = "hello") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: Content

    @Test func filesGoFirstThenCommentAsItsOwnMessage() throws {
        let a = ShareContent.File(url: URL(fileURLWithPath: "/a.jpg"), isPhoto: true)
        let b = ShareContent.File(url: URL(fileURLWithPath: "/b.pdf"))
        let content = ShareContent(files: [a, b], comment: "  from the trip \n")
        #expect(content.items() == [.file(a), .file(b), .text("from the trip")])
    }

    @Test func aCommentRidesWithTheFirstLink() {
        let content = ShareContent(texts: ["https://example.org/a", "https://example.org/b"], comment: "look")
        #expect(content.items() == [.text("look\nhttps://example.org/a"), .text("https://example.org/b")])
        #expect(ShareContent(texts: ["https://example.org/a"]).items() == [.text("https://example.org/a")])
    }

    @Test func blankTextIsDropped() {
        #expect(ShareContent(texts: ["  ", "\n"], comment: " ").items().isEmpty)
    }

    // MARK: Staging

    @Test func stagedMessagesArePendingAndEncryptedWhereTheChatIs() async throws {
        let db = try AppDatabase.inMemory()
        let store = AttachmentStore(directory: directory.appending(path: "store"))
        let outgoing = OutgoingMessages(database: db, attachments: store, account: me)
        let chat = try db.conversation(with: alice)
        try db.setEncrypted(true, with: alice)
        _ = chat
        let prepared = try await outgoing.prepareFile(at: file("notes.txt"), asPhoto: false)
        let messages = try outgoing.stage([.file(prepared), .text("see notes")], to: alice)
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.status == .pending && $0.encryption == .omemo && $0.remoteId != nil })
        let attachment = try #require(try db.attachment(messageId: messages[0].id!))
        #expect(attachment.state == .pendingUpload && attachment.name == "notes.txt" && attachment.size == 5)
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: attachment.localFile!).path))
        // The app's resend finds them, however long they've waited.
        let found = try db.unconfirmedOutgoing()
        #expect(found.map(\.0.id) == messages.map(\.id))
    }

    @Test func unreadableFileStagesNothing() async throws {
        let db = try AppDatabase.inMemory()
        let outgoing = OutgoingMessages(database: db, attachments: AttachmentStore(directory: directory.appending(path: "store")), account: me)
        await #expect(throws: XMPPSession.AttachmentError.self) {
            try await outgoing.prepareFile(at: directory.appending(path: "missing.bin"))
        }
        #expect(try db.unconfirmedOutgoing().isEmpty)
    }

    @Test func pendingGroupMessagesAreFoundWhateverTheirAge() throws {
        let db = try AppDatabase.inMemory()
        let room = JID("room@conference.example.org")!
        let group = try db.joinGroupChat(room, nickname: "Me")
        func add(_ id: String, _ status: Message.Status, at time: TimeInterval, serverId: String? = nil) throws {
            try db.insert(Message(conversationId: group.conversationId, direction: .outgoing, sender: me, body: id,
                                  timestamp: Date(timeIntervalSince1970: time), status: status, remoteId: id, originId: id, serverId: serverId))
        }
        try add("old-pending", .pending, at: 10)
        try add("old-sent", .sent, at: 11)
        try add("new-pending", .pending, at: 5000)
        #expect(try db.pendingOutgoing(conversationId: group.conversationId).map(\.remoteId) == ["old-pending", "new-pending"])
    }

    // MARK: Sending

    @Test func whenTheAppHoldsTheSessionTheMessagesWaitAndTheAppIsTold() async throws {
        let account = directory.appending(path: "account")
        let lockURL = directory.appending(path: "session.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = ProcessLock(url: lockURL)
        #expect(app.tryLock(as: .app))

        let told = Told()
        let signal = PendingSendsSignal { told.set() }
        var sender = ShareSender(
            credentials: .init(jid: me, password: "x"), directory: account, resource: "share", lock: ProcessLock(url: lockURL),
        )
        sender.lockTimeout = 0.2
        let outcome = await sender.send(ShareContent(files: [.init(url: try file("a.txt"))], comment: "hi"), to: alice)
        #expect(outcome == .handedToApp)

        let db = try AccountDirectory(url: account).openDatabase()
        let pending = try db.unconfirmedOutgoing()
        #expect(pending.map(\.0.body) == ["", "hi"])
        #expect(pending.allSatisfy { $0.1 == alice })

        for _ in 0..<50 where !told.value { try await Task.sleep(for: .milliseconds(100)) }
        #expect(told.value)
        withExtendedLifetime(signal) {}
        app.unlock()
    }

    @Test func whenTheNotificationExtensionHoldsTheSessionItWaitsAndSendsItself() async throws {
        let account = directory.appending(path: "account")
        let lockURL = directory.appending(path: "session.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionLock = ProcessLock(url: lockURL)
        #expect(extensionLock.tryLock(as: .notification))
        Task.detached {
            try await Task.sleep(for: .milliseconds(600))
            extensionLock.unlock()
        }

        let told = Told()
        let signal = PendingSendsSignal { told.set() }
        var sender = ShareSender(
            credentials: .init(jid: me, password: "x"), directory: account, resource: "share", lock: ProcessLock(url: lockURL),
        )
        sender.lockTimeout = 0.2
        sender.makeSession = { _ in throw TestFailure() }
        let outcome = await sender.send(ShareContent(files: [], comment: "hi"), to: alice)
        // It got the lock, and went on to make its own session.
        #expect(outcome != .handedToApp)
        #expect(!told.value)
        withExtendedLifetime(signal) {}
    }

    @Test func anExtensionThatNeverLetsGoIsNotReportedAsTheApp() async throws {
        let account = directory.appending(path: "account")
        let lockURL = directory.appending(path: "session.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionLock = ProcessLock(url: lockURL)
        #expect(extensionLock.tryLock(as: .notification))
        var sender = ShareSender(
            credentials: .init(jid: me, password: "x"), directory: account, resource: "share", lock: ProcessLock(url: lockURL),
        )
        sender.lockTimeout = 0.2
        sender.extensionLockWait = 0.3
        let outcome = await sender.send(ShareContent(files: [], comment: "hi"), to: alice)
        guard case .queued = outcome else {
            Issue.record("expected queued, got \(outcome)")
            return
        }
        extensionLock.unlock()
    }

    @Test func nothingToSendIsAFailure() async throws {
        let sender = ShareSender(credentials: .init(jid: me, password: "x"), directory: directory.appending(path: "account"), resource: "share",
                                 lock: ProcessLock(url: directory.appending(path: "l")))
        #expect(await sender.send(ShareContent(), to: alice) == .failed("There's nothing to send."))
    }

    @Test func aFailureAfterWritingIsLeftToTheApp() {
        #expect(ShareSender.failure(status: .failed, error: "No trusted devices.") == .failedInApp("No trusted devices."))
        #expect(ShareSender.failure(status: .failed, error: nil) != nil)
        #expect(ShareSender.failure(status: .pending, error: nil) == nil)
        #expect(ShareSender.failure(status: .sent, error: nil) == nil)
    }

    @Test func recipientsSkipGroupsWeLeftAndBlockedContacts() throws {
        let account = directory.appending(path: "account")
        let sender = ShareSender(credentials: .init(jid: me, password: "x"), directory: account, resource: "share",
                                 lock: ProcessLock(url: directory.appending(path: "l")))
        let db = try AccountDirectory(url: account).openDatabase()
        let bob = JID("bob@example.org")!, room = JID("room@conference.example.org")!, gone = JID("gone@conference.example.org")!
        for peer in [alice, bob] { try db.insert(Message(conversationId: db.conversation(with: peer).id!, direction: .incoming, sender: peer, body: "hi", remoteId: peer.description)) }
        try db.setBlocked(true, bob)
        let group = try db.joinGroupChat(room, nickname: "Me")
        _ = group
        _ = try db.joinGroupChat(gone, nickname: "Me")
        try db.updateGroupChat(gone) { $0.hasLeft = true }
        #expect(Set(try sender.recipients().map(\.conversation.peer)) == [alice, room])
    }

    // MARK: Suggestions

    @Test func suggestionsNameTheChatByItsAddress() throws {
        let db = try AppDatabase.inMemory()
        var contact = Contact(jid: alice)
        contact.name = "Alice"
        try db.writer.write { try contact.save($0) }
        let intent = ShareSuggestions.intent(for: alice, database: db, avatars: .temporary())
        #expect(intent.conversationIdentifier == "alice@example.org")
        #expect(intent.recipients?.first?.displayName == "Alice")
        #expect(intent.speakableGroupName == nil)

        let room = JID("room@conference.example.org")!
        _ = try db.joinGroupChat(room, nickname: "Me", name: "Cake club")
        let group = ShareSuggestions.intent(for: room, database: db, avatars: .temporary())
        #expect(group.conversationIdentifier == "room@conference.example.org")
        #expect(group.speakableGroupName?.spokenPhrase == "Cake club")
    }
}

private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
