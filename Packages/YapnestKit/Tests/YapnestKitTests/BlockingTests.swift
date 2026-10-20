import Foundation
import Testing
@testable import YapnestKit

/// XEP-0191 blocklists.
struct BlockingTests {
    let db: AppDatabase
    let alice = JID("alice@example.org")!
    let bob = JID("bob@example.org")!
    let spammer = JID("spam@example.net")!

    init() throws {
        db = try AppDatabase.inMemory()
    }

    @Test func blocklistReplacesWhatWeHad() throws {
        try db.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try db.setBlocklist([alice, spammer])
        #expect(try db.isBlocked(alice))
        #expect(try db.isBlocked(spammer))
        #expect(try !db.isBlocked(bob))
        // Blocking keeps what we know of them.
        #expect(try db.contact(alice)?.name == "Alice")

        try db.setBlocklist([spammer])
        #expect(try !db.isBlocked(alice))
        #expect(try db.isBlocked(spammer))
    }

    @Test func reportNamesTheirLatestMessages() throws {
        let conversation = try db.conversation(with: spammer)
        for index in 0..<3 {
            try db.insert(Message(conversationId: conversation.id!, direction: .incoming, sender: spammer, body: "buy \(index)",
                                  timestamp: Date(timeIntervalSince1970: Double(index)), serverId: "s\(index)"))
        }
        try db.insert(Message(conversationId: conversation.id!, direction: .outgoing, sender: alice, body: "stop", serverId: "mine"))
        #expect(try db.lastServerIds(from: spammer, limit: 2) == ["s2", "s1"])
    }
}
