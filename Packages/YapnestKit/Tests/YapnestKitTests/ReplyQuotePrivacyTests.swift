import Foundation
import Testing
@testable import Martin
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

struct ReplyQuotePrivacyTests {
    let database: AppDatabase
    let session: XMPPSession
    var wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        try session.setEncrypted(false, with: alice)
    }

    private func original(_ encryption: YapnestKit.Message.Encryption) throws -> YapnestKit.Message {
        let conversation = try #require(try database.conversation(with: alice).id)
        return try database.insert(YapnestKit.Message(conversationId: conversation, direction: .incoming, sender: alice, body: "secret plans", encryption: encryption, remoteId: "in1"))
    }

    @Test func anEncryptedMessageIsNotQuotedInTheClearInAnUnencryptedReply() throws {
        let sent = try session.send("ok", to: alice, replyingTo: original(.omemo))
        session.drainSendQueue(alice)
        let wired = try #require(wire.messages.first { $0.id == sent.remoteId })
        #expect(wired.body == "ok")
        #expect(wired.firstChild(name: "fallback", xmlns: NS.fallback) == nil)
        #expect(wired.firstChild(name: "reply", xmlns: NS.reply)?.attribute("id") == "in1")
    }

    @Test func anUnencryptedMessageIsStillQuoted() throws {
        let sent = try session.send("ok", to: alice, replyingTo: original(.none))
        session.drainSendQueue(alice)
        let wired = try #require(wire.messages.first { $0.id == sent.remoteId })
        #expect(wired.body == "> secret plans\nok")
    }
}
