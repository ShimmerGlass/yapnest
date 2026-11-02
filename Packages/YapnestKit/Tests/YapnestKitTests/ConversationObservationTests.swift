import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The observation keeps what it built per message, so each kind of write must
/// leave it equal to a fresh full fetch, which stays as the oracle.
struct ConversationObservationTests {
    let db: AppDatabase
    let me = JID("me@example.org")!
    let alice = JID("alice@example.org")!
    let bob = JID("bob@example.org")!
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var conversationId: Int64

    init() throws {
        db = try AppDatabase.inMemory()
        conversationId = try db.conversation(with: alice).id!
    }

    /// Alternating senders, a reply to the previous message on every fifth,
    /// a reaction on every third, a link on every seventh.
    private func fill(_ count: Int, from start: Int = 0, conversationId: Int64? = nil) throws {
        let id = conversationId ?? self.conversationId
        try db.writer.write { db in
            for index in start..<(start + count) {
                var message = Message(
                    conversationId: id, direction: index % 2 == 0 ? .outgoing : .incoming, sender: index % 2 == 0 ? me : alice,
                    body: "message \(index)", timestamp: t0 + Double(index), remoteId: "m\(index)",
                    replyToId: index % 5 == 4 ? "m\(index - 1)" : nil,
                )
                if index % 7 == 0 { message.link = "https://example.org/\(index)" }
                try message.insert(db)
                if index % 3 == 0 { try Reaction(messageId: message.id!, sender: alice, emoji: "👍").insert(db) }
            }
        }
    }

    private func fresh(since: MessageCursor? = nil) throws -> [ConversationItem] {
        try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, since: since) }
    }

    private func id(_ remoteId: String) throws -> Int64 {
        try #require(try db.reader.read { try Message.filter(Column("remoteId") == remoteId).fetchOne($0) }?.id)
    }

    /// Runs `write`, then checks that the cache and a fresh fetch agree, and
    /// that the cache said whether anything changed.
    private func check(_ cache: ConversationItemCache, since: MessageCursor? = nil, changes: Bool = true, _ write: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let before = try db.reader.read { try cache.fetch($0, peer: alice, since: since) }
        try write()
        let after = try db.reader.read { try cache.fetch($0, peer: alice, since: since) }
        let expected = try fresh(since: since)
        #expect(after.items == expected, sourceLocation: sourceLocation)
        #expect((after == before) == !changes, sourceLocation: sourceLocation)
    }

    private func stamps(_ cache: ConversationItemCache) throws -> [Int64: Int64] {
        let snapshot = try db.reader.read { try cache.fetch($0, peer: alice, since: nil) }
        return Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0.stamp) })
    }

    @Test func anUnchangedMessageKeepsItsStampAndAChangedOneGetsANewOne() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        var before = try stamps(cache)
        #expect(Set(before.values).count == before.count)
        // Nothing changed: nothing is restamped.
        #expect(try stamps(cache) == before)

        func expectOnlyChanged(_ ids: [Int64], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let after = try stamps(cache)
            #expect(Set(after.keys) == Set(before.keys), Comment(rawValue: what), sourceLocation: sourceLocation)
            let moved = Set(after.filter { before[$0.key] != $0.value }.keys)
            #expect(moved == Set(ids), Comment(rawValue: what), sourceLocation: sourceLocation)
            before = after
        }

        _ = try db.applyEdit("edited", to: try id("m8"))
        // m9 replies to m8.
        try expectOnlyChanged([try id("m8"), try id("m9")], "edit")
        _ = try db.setReactions(["🎉"], from: bob, conversationId: conversationId, messageRef: "m5")
        try expectOnlyChanged([try id("m5")], "reaction")
        try db.updateStatus(.delivered, conversationId: conversationId, remoteId: "m10")
        try expectOnlyChanged([try id("m10")], "receipt")
        let withFile = try id("m12")
        try db.writer.write { try Attachment(messageId: withFile, url: nil, name: "a.png", state: .pendingUpload).insert($0) }
        try expectOnlyChanged([withFile], "attachment")
        _ = try db.applyRetraction(of: try id("m16"))
        try expectOnlyChanged([try id("m16")], "retraction")
        // m14 replies to m13: its quote shows what m13 says.
        _ = try db.applyEdit("quoted, changed", to: try id("m13"))
        try expectOnlyChanged([try id("m13"), try id("m14")], "a reply whose quote changed")
        try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "new", timestamp: t0 + 1000, remoteId: "new"))
        let after = try stamps(cache)
        #expect(after.count == before.count + 1)
        #expect(Set(after.filter { before[$0.key] != $0.value }.keys) == [try id("new")])
    }

    @Test func aRebuildThatComesOutTheSameKeepsTheStamp() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        let before = try stamps(cache)
        // m4 replies to m3, which is rebuilt as it is marked read, but what the
        // quote shows doesn't change.
        try db.markRead(conversationId: conversationId)
        let after = try stamps(cache)
        #expect(after[try id("m3")] != before[try id("m3")])
        #expect(after[try id("m4")] == before[try id("m4")])
    }

    @Test func aMutatedItemGetsANewStamp() throws {
        try fill(3)
        let cache = ConversationItemCache(me: me)
        var item = try #require(try db.reader.read { try cache.fetch($0, peer: alice, since: nil) }.items.first)
        let stamp = item.stamp
        item.message.body = "changed"
        #expect(item.stamp != stamp)
    }

    @Test func firstFetchEqualsFullFetch() throws {
        try fill(60)
        let cache = ConversationItemCache(me: me)
        let snapshot = try db.reader.read { try cache.fetch($0, peer: alice, since: nil) }
        #expect(snapshot.items == (try fresh()))
        #expect(!snapshot.items.isEmpty)
    }

    @Test func unknownConversationIsEmpty() throws {
        let cache = ConversationItemCache(me: me)
        let snapshot = try db.reader.read { try cache.fetch($0, peer: bob, since: nil) }
        #expect(snapshot.items.isEmpty)
    }

    @Test func insertAppendsAndOthersAreReused() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        try check(cache) {
            try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "new", timestamp: t0 + 1000, remoteId: "new"))
        }
    }

    @Test func insertWithReplyToTheNewestMessage() throws {
        try fill(10)
        let cache = ConversationItemCache(me: me)
        try check(cache) {
            try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "re", timestamp: t0 + 1000, remoteId: "re", replyToId: "m9"))
        }
    }

    @Test func statusChange() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        try check(cache) { try db.updateStatus(.delivered, conversationId: conversationId, remoteId: "m10") }
        try check(cache) { try db.markFailed(conversationId: conversationId, remoteId: "m12", error: "nope") }
        try check(cache) { try db.markPending(conversationId: conversationId, remoteId: "m12") }
    }

    @Test func markRead() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        try check(cache) { try db.markRead(conversationId: conversationId) }
        // Nothing left to mark: no change, and the same snapshot.
        try check(cache, changes: false) { try db.markRead(conversationId: conversationId) }
    }

    @Test func edit() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        try check(cache) { _ = try db.applyEdit("edited", to: try id("m8")) }
    }

    @Test func retraction() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        try check(cache) { _ = try db.applyRetraction(of: try id("m16")) }
    }

    @Test func reactionAddAndRemove() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        try check(cache) { _ = try db.setReactions(["🎉"], from: bob, conversationId: conversationId, messageRef: "m5") }
        try check(cache) { _ = try db.setReactions(["🎉", "👍"], from: me, conversationId: conversationId, messageRef: "m5") }
        try check(cache) { _ = try db.setReactions([], from: bob, conversationId: conversationId, messageRef: "m5") }
        try check(cache) { _ = try db.setReactions([], from: alice, conversationId: conversationId, messageRef: "m3") }
    }

    @Test func attachmentProgressAndState() throws {
        try fill(20)
        let cache = ConversationItemCache(me: me)
        let messageId = try id("m6")
        try check(cache) {
            try db.writer.write { db in
                try Attachment(messageId: messageId, url: nil, name: "a.png", state: .pendingUpload).insert(db)
            }
        }
        try check(cache) { try db.setAttachmentState(.ready, messageId: messageId) }
        try check(cache) { _ = try db.setUploaded(messageId: messageId, url: "https://example.org/a.png") }
        try check(cache) { try db.setDownloaded(messageId: messageId, localFile: "x", size: 10, mimeType: "image/png", width: 10, height: 20) }
    }

    @Test func linkPreviewArrival() throws {
        try fill(30)
        let cache = ConversationItemCache(me: me)
        try check(cache) { try db.writer.write { try LinkPreview(url: "https://example.org/7", kind: .page, title: "Seven").insert($0) } }
        try check(cache) { try db.writer.write { try LinkPreview(url: "https://example.org/7", kind: .page, title: "Seven again").update($0) } }
        // A preview for a link no message in the window has.
        try check(cache, changes: false) { try db.writer.write { try LinkPreview(url: "https://example.org/other", kind: .none).insert($0) } }
    }

    @Test func quotedMessageEditedRetractedAndGivenAnAttachment() throws {
        try fill(40)
        let cache = ConversationItemCache(me: me)
        // Every fifth message replies to the one before it: m13 is quoted by m14.
        try check(cache) { _ = try db.applyEdit("edited quote", to: try id("m13")) }
        let quotedId = try id("m18")
        try check(cache) { try db.writer.write { try Attachment(messageId: quotedId, url: "u", name: "q.png", mimeType: "image/png", state: .ready).insert($0) } }
        try check(cache) { _ = try db.applyRetraction(of: try id("m8")) }
        let quoting = try #require(try fresh().first { $0.message.remoteId == "m9" })
        #expect(quoting.quote?.text == String(localized: "Deleted message"))
    }

    /// A sender picks the `id` of what they send, so another message can carry
    /// the id of the one a reply names. Only the stanza-id is the server's own,
    /// so it wins over a newer message with the id as its `id`.
    @Test func aQuoteResolvesLikeAFullFetchWhenIdsCollide() throws {
        try fill(10)
        let cache = ConversationItemCache(me: me)
        try check(cache) {
            try db.writer.write { db in
                var original = Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "original", timestamp: t0 + 100, remoteId: "a1", serverId: "shared")
                var imposter = Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "imposter", timestamp: t0 + 200, remoteId: "shared")
                var reply = Message(conversationId: conversationId, direction: .outgoing, sender: me, body: "re", timestamp: t0 + 300, remoteId: "r1", replyToId: "shared")
                try original.insert(db)
                try imposter.insert(db)
                try reply.insert(db)
            }
        }
        let quoted = try #require(try fresh().first { $0.message.remoteId == "r1" }?.quote?.messageId)
        #expect(quoted == (try id("a1")))
        // Also when the quoted message is what changes.
        try check(cache) { _ = try db.applyEdit("original, edited", to: try id("a1")) }
    }

    @Test func quotedMessageOutsideTheWindowThenArriving() throws {
        try fill(30)
        let cursor = try fresh()[10].cursor
        let cache = ConversationItemCache(me: me)
        // A reply to a message we don't have falls back to its quote; once the
        // original is stored the quote resolves.
        try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "re", timestamp: t0 + 500, remoteId: "re", replyToId: "late", replyFallback: "fallback"))
        try check(cache, since: cursor) {
            try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "the late one", timestamp: t0 - 5, remoteId: "late"))
        }
        #expect(try fresh(since: cursor).last?.quote?.messageId != nil)
    }

    @Test func windowGrowsWhenOlderHistoryIsPrepended() throws {
        try fill(40, from: 100)
        let cursor = try fresh()[20].cursor
        let cache = ConversationItemCache(me: me)
        // Older history arrives behind the window: it stays as it was.
        try check(cache, since: cursor, changes: false) { try fill(20, from: 0) }
        // Then the window reaches back into it, and keeps following changes.
        let older = try #require(try db.olderCursor(peer: alice, before: cursor, count: 15)).cursor
        try check(cache, since: older) { try fill(10, from: 200) }
        try check(cache, since: older) { try db.updateStatus(.delivered, conversationId: conversationId, remoteId: "m110") }
        let snapshot = try db.reader.read { try cache.fetch($0, peer: alice, since: nil) }
        #expect(snapshot.items == (try fresh()))
    }

    @Test func slidingDefaultWindowTrimsOldest() throws {
        try fill(AppDatabase.initialWindow + 5)
        let cache = ConversationItemCache(me: me)
        try check(cache) {
            try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "new", timestamp: t0 + 10_000, remoteId: "new"))
        }
        let items = try fresh()
        #expect(items.count == AppDatabase.initialWindow)
    }

    @Test func otherConversationsDontChangeTheSnapshot() throws {
        try fill(20)
        let cache = ConversationItemCache(me: me)
        let other = try db.conversation(with: bob).id!
        try check(cache, changes: false) { try fill(5, from: 500, conversationId: other) }
    }

    @Test func manyWritesStayEqual() throws {
        try fill(80)
        let cache = ConversationItemCache(me: me)
        for round in 0..<30 {
            try check(cache) {
                switch round % 5 {
                case 0: try db.updateStatus(.displayed, conversationId: conversationId, remoteId: "m\(round * 2)")
                case 1: _ = try db.setReactions(["😀"], from: bob, conversationId: conversationId, messageRef: "m\(round)")
                case 2: _ = try db.applyEdit("round \(round)", to: try id("m\(round + 1)"))
                case 3: try db.insert(Message(conversationId: conversationId, direction: .incoming, sender: alice, body: "x\(round)", timestamp: t0 + 2000 + Double(round), remoteId: "x\(round)", replyToId: "m\(round)"))
                default: try db.markRead(conversationId: conversationId, through: t0 + Double(round))
                }
            }
        }
    }

    /// Through the real observation: bursts collapse and each value is a
    /// fresh fetch.
    @Test func observationEmitsOnlyRealChanges() async throws {
        try fill(30)
        var iterator = db.observeConversation(peer: alice, me: me)
            .values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first == (try fresh()))
        try db.updateStatus(.delivered, conversationId: conversationId, remoteId: "m4")
        let second = try #require(try await iterator.next())
        #expect(second == (try fresh()))
        #expect(second != first)
    }

    /// Clearing the pending id changes no other row of the message, so the
    /// cached item only follows if that bumps the message's revision.
    @Test func acknowledgingAReactionRedrawsItsMessage() async throws {
        try fill(3)
        try db.setReactions(["👍"], from: Author(jid: me), conversationId: conversationId, messageRef: "m1", pendingId: "r1")
        var iterator = db.observeConversation(peer: alice, me: me)
            .values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.contains { $0.ownReactions == .pending })
        try db.clearPending(.reaction, id: "r1")
        let second = try #require(try await iterator.next())
        #expect(!second.contains { $0.ownReactions == .pending })
        #expect(second == (try fresh()))
    }

    /// An empty set has no reaction rows, so the record alone must redraw the
    /// message, and a failure must show on the item.
    @Test func aRecordWithNoReactionRowsRedrawsItsMessage() async throws {
        try fill(3)
        try db.setReactions([], from: Author(jid: me), conversationId: conversationId, messageRef: "m1", pendingId: "r1")
        var iterator = db.observeConversation(peer: alice, me: me)
            .values(in: db.reader, bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.contains { $0.ownReactions == .pending })
        try db.clearPending(.reaction, id: "r1", error: "Nope")
        let second = try #require(try await iterator.next())
        #expect(second.contains { $0.ownReactions == .failed("Nope") })
        #expect(second == (try fresh()))
    }

    // MARK: Cost

    /// A receipt for the newest outgoing message, with the window at 500 and 2500.
    @Test(arguments: [500, 2500]) func receiptCostsLessThanAFullFetch(window: Int) throws {
        try fill(window)
        let cache = ConversationItemCache(me: me)
        let start = window > AppDatabase.initialWindow ? try db.oldestMessage(peer: alice).map(MessageCursor.init) : nil
        let clock = ContinuousClock()
        _ = try db.reader.read { try cache.fetch($0, peer: alice, since: start) }
        var oldTotal: Duration = .zero
        var newTotal: Duration = .zero
        var previous: [ConversationItem] = []
        let rounds = 5
        for round in 0..<rounds {
            try db.updateStatus(round % 2 == 0 ? .delivered : .displayed, conversationId: conversationId, remoteId: "m\(window - 2)")
            oldTotal += try clock.measure {
                let items = try db.reader.read { try AppDatabase.conversationItems($0, peer: alice, me: me, limit: window, since: start) }
                _ = items == previous
                previous = items
            }
            newTotal += try clock.measure {
                let snapshot = try db.reader.read { try cache.fetch($0, peer: alice, since: start) }
                _ = snapshot
            }
        }
        print("PERF window \(window): full fetch+compare \(oldTotal / rounds), cached \(newTotal / rounds) per receipt")
        #expect(newTotal < oldTotal)
    }
}
