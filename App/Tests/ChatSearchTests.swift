import GRDB
import Testing
import YapnestKit
@testable import Yapnest

@MainActor
struct ChatSearchTests {
    private func searchable() async throws -> (ConversationFixture, ChatSearch, [Message]) {
        let f = try ConversationFixture()
        let messages = [
            try f.add("apple pie", read: true),
            try f.add("banana split", read: true),
            try f.add("apple tart", read: true),
            try f.add("cherry", read: true),
        ]
        await f.start()
        let search = ChatSearch(session: f.session, peer: f.peer, conversation: f.model)
        search.open()
        return (f, search, messages)
    }

    @Test func matchesAreNewestFirstAndSteppingStopsAtBothEnds() async throws {
        let (f, search, m) = try await searchable()
        search.query = "apple"
        await eventually("the search never finished") { !search.isSearching && search.hasMatches }
        #expect(search.matches == [m[2].id!, m[0].id!])
        #expect(search.current == 0)
        #expect(f.model.scroll.messageID == m[2].id)
        #expect(!search.canGoNewer && search.canGoOlder)

        search.goOlder()
        #expect(search.current == 1)
        #expect(f.model.scroll.messageID == m[0].id)
        #expect(!search.canGoOlder && search.canGoNewer)

        // At the oldest match, "older" does nothing.
        search.goOlder()
        #expect(search.current == 1)
        #expect(f.model.scroll.messageID == m[0].id)

        search.goNewer()
        #expect(search.current == 0)
        search.goNewer()
        #expect(search.current == 0)
        #expect(f.model.scroll.messageID == m[2].id)
    }

    @Test func aNewQueryStartsOverAtTheNewestMatch() async throws {
        let (_, search, m) = try await searchable()
        search.query = "apple"
        await eventually("no matches") { search.matches.count == 2 }
        search.goOlder()
        #expect(search.current == 1)

        search.query = "banana"
        await eventually("the new query never answered") { search.matches == [m[1].id!] }
        #expect(search.current == 0)
    }

    @Test func aQueryTypedOverBeforeItRanNeverShowsItsMatches() async throws {
        let (_, search, m) = try await searchable()
        search.query = "apple"
        search.query = "banana"
        await eventually("the search never finished") { !search.isSearching }
        #expect(search.matches == [m[1].id!])
        #expect(await stays { search.matches == [m[1].id!] })
    }

    @Test func aQueryWithNoMatchEndsWithNoResults() async throws {
        let (_, search, _) = try await searchable()
        search.query = "zzz"
        #expect(search.isSearching)
        await eventually("the search never finished") { !search.isSearching }
        #expect(!search.hasMatches)
        #expect(!search.summary.isEmpty)
    }

    @Test func clearingTheQueryClearsTheMatchesAtOnce() async throws {
        let (_, search, _) = try await searchable()
        search.query = "apple"
        await eventually("no matches") { search.hasMatches }
        search.query = "  "
        #expect(!search.hasMatches && !search.isSearching)
        #expect(search.summary.isEmpty)
        #expect(search.current == 0)
    }

    @Test func closingWhileASearchIsPendingNeverBringsItsMatchesBack() async throws {
        let (_, search, _) = try await searchable()
        search.query = "apple"
        search.close()
        #expect(!search.isActive && search.query.isEmpty && !search.isSearching)
        #expect(await stays(for: .milliseconds(700)) { !search.hasMatches && !search.isSearching })
    }

    private func retract(_ message: Message, in f: ConversationFixture) throws {
        try f.database.writer.write { try $0.execute(sql: "UPDATE message SET isRetracted = 1 WHERE id = ?", arguments: [message.id]) }
    }

    @Test func aMatchDeletedOrRetractedLaterLeavesTheListAndTheCount() async throws {
        let (f, search, m) = try await searchable()
        try f.add("apple crumble", read: true)
        search.query = "apple"
        await eventually("no matches") { search.matches.count == 3 }
        #expect(search.summary.contains("1") && search.summary.contains("3"))

        try retract(m[0], in: f)
        await eventually("the retracted message stayed") { search.matches.count == 2 }
        try await f.database.writer.write { _ = try Message.deleteOne($0, key: m[2].id) }
        await eventually("the deleted message stayed") { search.matches.count == 1 }
        #expect(!search.matches.contains(m[0].id!) && !search.matches.contains(m[2].id!))
        #expect(search.current == 0 && !search.canGoOlder && !search.canGoNewer)
    }

    @Test func whenTheCurrentMatchIsRemovedTheNextOlderOneTakesItsPlace() async throws {
        let (f, search, m) = try await searchable()
        let newest = try f.add("apple crumble", read: true)
        search.query = "apple"
        await eventually("no matches") { search.matches == [newest.id!, m[2].id!, m[0].id!] }
        search.goOlder()
        #expect(search.matches[search.current] == m[2].id)

        try await f.database.writer.write { _ = try Message.deleteOne($0, key: m[2].id) }
        await eventually("the deleted message stayed") { search.matches == [newest.id!, m[0].id!] }
        #expect(search.current == 1)
        #expect(f.model.scroll.messageID == m[0].id)

        // The oldest one going leaves the newest of what's left.
        try retract(m[0], in: f)
        await eventually("the retracted message stayed") { search.matches == [newest.id!] }
        #expect(search.current == 0)
        #expect(f.model.scroll.messageID == newest.id)
    }

    @Test func theCurrentMatchStaysWhereItIsWhenAnotherOneIsRemovedOrAdded() async throws {
        let (f, search, m) = try await searchable()
        search.query = "apple"
        await eventually("no matches") { search.matches.count == 2 }
        search.goOlder()
        let newer = try f.add("apple again", read: true)
        await eventually("the new match never joined") { search.matches == [newer.id!, m[2].id!, m[0].id!] }
        #expect(search.matches[search.current] == m[0].id)
        try await f.database.writer.write { _ = try Message.deleteOne($0, key: newer.id) }
        await eventually("the deleted match stayed") { search.matches == [m[2].id!, m[0].id!] }
        #expect(search.current == 1 && search.matches[search.current] == m[0].id)
    }

    @Test func removingEveryMatchEndsWithNoResults() async throws {
        let (f, search, m) = try await searchable()
        search.query = "banana"
        await eventually("no matches") { search.hasMatches }
        try retract(m[1], in: f)
        await eventually("the match stayed") { !search.hasMatches }
        #expect(search.current == 0)
        #expect(!search.summary.isEmpty && !search.canGoOlder)
    }
}
