import Foundation
import GRDB
import Testing
@testable import YapnestKit

private let alice = JID("alice@example.org")!
private let bob = JID("bob@example.org")!
private let room = JID("cake@rooms.example.org")!
private let me = JID("me@example.org")!

private struct Fixture {
    let db = try! AppDatabase.inMemory()
    var nextId = 0

    /// An approved contact when `inRoster`: a roster item alone isn't trusted.
    func contact(_ jid: JID, inRoster: Bool) throws {
        try db.writer.write { db in
            var contact = Contact(jid: jid)
            contact.isInRoster = inRoster
            if inRoster { contact.subscription = .both }
            try contact.save(db)
        }
    }

    func group(private isPrivate: Bool) throws {
        try db.writer.write { db in
            var conversation = Conversation(peer: room, kind: .groupchat)
            try conversation.insert(db)
            try GroupChat(conversationId: conversation.id!, jid: room, nickname: "me", isMembersOnly: isPrivate, isNonAnonymous: isPrivate).insert(db)
        }
    }

    /// Stores a received (or sent) attachment message and returns its id.
    @discardableResult
    mutating func add(
        in peer: JID, from sender: JID, outgoing: Bool = false, name: String = "cat.png", state: YapnestKit.Attachment.State = .remote,
        size: Int64? = nil, age: TimeInterval = 60,
    ) throws -> Int64 {
        nextId += 1
        let n = nextId
        return try db.writer.write { db in
            var conversation = try Conversation.filter(Column("peer") == peer).fetchOne(db) ?? Conversation(peer: peer)
            if conversation.id == nil { try conversation.insert(db) }
            var message = Message(
                conversationId: conversation.id!, direction: outgoing ? .outgoing : .incoming, sender: sender,
                body: "https://up.example/\(n)/\(name)", timestamp: Date().addingTimeInterval(-age), remoteId: "m\(n)",
            )
            try message.insert(db)
            try YapnestKit.Attachment(messageId: message.id!, url: message.body, name: name, size: size, state: state).insert(db)
            return message.id!
        }
    }

    func missed(limit: Int = 50, peer: JID? = nil) throws -> Set<Int64> {
        Set(try db.missedImages(since: Date().addingTimeInterval(-7 * 86400), limit: limit, maxSize: XMPPSession.autoDownloadSize, peer: peer).map(\.messageId))
    }
}

struct MissedImagesTests {
    @Test func rosterDecidesForDirectChats() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        try f.contact(bob, inRoster: false)
        let known = try f.add(in: alice, from: alice)
        _ = try f.add(in: bob, from: bob)
        let ours = try f.add(in: bob, from: me, outgoing: true)
        #expect(try f.missed() == [known, ours])
        #expect(try f.missed(peer: bob) == [ours])
    }

    @Test func aRosterItemWithoutASubscriptionIsNotTrusted() throws {
        var f = Fixture()
        try f.db.writer.write { try Contact(jid: alice, subscription: .none, isInRoster: true).save($0) }
        try f.db.writer.write { try Contact(jid: bob, subscription: .none, isSubscriptionPending: true, isInRoster: true).save($0) }
        try f.db.writer.write { try Contact(jid: JID("carol@example.org")!, isInRoster: true, isAddedByUser: true).save($0) }
        _ = try f.add(in: alice, from: alice)
        let asked = try f.add(in: bob, from: bob)
        let added = try f.add(in: JID("carol@example.org")!, from: JID("carol@example.org")!)
        #expect(try f.missed() == [asked, added])
    }

    @Test func someoneWeSubscribedToIsTrusted() throws {
        var f = Fixture()
        try f.db.writer.write { try Contact(jid: alice, subscription: .to, isInRoster: true).save($0) }
        let subscribed = try f.add(in: alice, from: alice)
        #expect(try f.missed() == [subscribed])
    }

    @Test func groupsTrustPrivateRoomsOrRosterSenders() throws {
        var f = Fixture()
        try f.group(private: false)
        try f.contact(alice, inRoster: true)
        let friend = try f.add(in: room, from: alice)
        _ = try f.add(in: room, from: bob)
        _ = try f.add(in: room, from: room)
        #expect(try f.missed() == [friend])

        var p = Fixture()
        try p.group(private: true)
        let anyone = try p.add(in: room, from: bob)
        #expect(try p.missed() == [anyone])
    }

    @Test func privateGroupStrangersAreSkippedWhenTheSettingIsOff() throws {
        var f = Fixture()
        try f.group(private: true)
        try f.contact(alice, inRoster: true)
        let friend = try f.add(in: room, from: alice)
        let stranger = try f.add(in: room, from: bob)
        #expect(try f.missed() == [friend, stranger])
        try f.db.setFlag(.downloadsFromGroupMembers, false)
        #expect(try f.missed() == [friend])
    }

    @Test func groupMembersAreDownloadedFromByDefault() throws {
        #expect(try AppDatabase.inMemory().flag(.downloadsFromGroupMembers, default: true))
    }

    @Test func failedIsRetriedReadyAndOtherFilesAreNot() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        let failed = try f.add(in: alice, from: alice, state: .downloadFailed)
        _ = try f.add(in: alice, from: alice, state: .ready)
        _ = try f.add(in: alice, from: alice, name: "notes.pdf")
        #expect(try f.missed() == [failed])
    }

    @Test func aFailureThatWontPassIsNotSweptAgain() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        let gone = try f.add(in: alice, from: alice, state: .downloadFailed)
        try f.db.setDownloadFailed(messageId: gone, automatic: true, isFinal: true)
        #expect(try f.missed().isEmpty)
        // Still there for the user's tap.
        #expect(try f.db.attachment(messageId: gone)?.state == .downloadFailed)
    }

    @Test func aTransientFailureIsSweptAgainUntilTheLimit() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        let flaky = try f.add(in: alice, from: alice)
        for _ in 1..<XMPPSession.autoDownloadAttemptLimit {
            try f.db.setDownloadFailed(messageId: flaky, automatic: true, isFinal: false)
            #expect(try f.missed() == [flaky])
        }
        try f.db.setDownloadFailed(messageId: flaky, automatic: true, isFinal: false)
        #expect(try f.db.autoDownloadAttempts(messageId: flaky) == XMPPSession.autoDownloadAttemptLimit)
        #expect(try f.missed().isEmpty)
    }

    @Test func aFailedTapDoesNotCountAgainstTheSweeps() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        let id = try f.add(in: alice, from: alice)
        try f.db.setDownloadFailed(messageId: id, automatic: false, isFinal: true)
        #expect(try f.db.autoDownloadAttempts(messageId: id) == 0)
        #expect(try f.missed() == [id])
    }

    @Test func aPictureOfUnknownSizeThatTurnedOutTooLargeIsNotSweptAgain() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        let id = try f.add(in: alice, from: alice)
        try f.db.setTooLarge(messageId: id, size: nil)
        #expect(try f.missed().isEmpty)
    }

    @Test func onlyAFailureThatSaysTheSameAgainIsFinal() {
        #expect(XMPPSession.isFinalDownloadFailure(HTTPStatusError(status: 404)))
        #expect(XMPPSession.isFinalDownloadFailure(HTTPStatusError(status: 410)))
        #expect(XMPPSession.isFinalDownloadFailure(FileCrypto.Failure.decryptionFailed))
        #expect(XMPPSession.isFinalDownloadFailure(FetchError.refused("address is local")))
        #expect(XMPPSession.isFinalDownloadFailure(TooLarge(size: 1)))
        #expect(!XMPPSession.isFinalDownloadFailure(HTTPStatusError(status: 503)))
        #expect(!XMPPSession.isFinalDownloadFailure(HTTPStatusError(status: 429)))
        #expect(!XMPPSession.isFinalDownloadFailure(HTTPStatusError(status: 408)))
        #expect(!XMPPSession.isFinalDownloadFailure(URLError(.timedOut)))
        #expect(!XMPPSession.isFinalDownloadFailure(URLError(.notConnectedToInternet)))
        #expect(!XMPPSession.isFinalDownloadFailure(FetchError.timedOut))
    }

    @Test func tooLargeIsSkippedButStaysDownloadable() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        let small = try f.add(in: alice, from: alice, size: 1000)
        let big = try f.add(in: alice, from: alice, size: XMPPSession.autoDownloadSize + 1)
        #expect(try f.missed() == [small])
        try f.db.setTooLarge(messageId: big, size: 20_000_000)
        let stored = try #require(try f.db.attachment(messageId: big))
        #expect(stored.state == .remote)
        #expect(stored.size == 20_000_000)
        #expect(try f.missed() == [small])
    }

    @Test func boundedByAgeAndCount() throws {
        var f = Fixture()
        try f.contact(alice, inRoster: true)
        _ = try f.add(in: alice, from: alice, age: 8 * 86400)
        let newest = try f.add(in: alice, from: alice, age: 10)
        let next = try f.add(in: alice, from: alice, age: 20)
        _ = try f.add(in: alice, from: alice, age: 30)
        #expect(try f.missed(limit: 2) == [newest, next])
        #expect(try f.missed().count == 3)
    }
}
