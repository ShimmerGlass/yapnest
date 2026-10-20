import Foundation
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!

/// The roster Martin keeps through our database. The session's client is a
/// Martin context, which the store is handed but never looks at.
struct DatabaseRosterStoreTests {
    let database: AppDatabase
    let store: DatabaseRosterStore
    let context: Context
    let session: XMPPSession
    let alice = Martin.JID("alice@example.org")
    let bob = Martin.JID("bob@example.org")

    init() throws {
        database = try AppDatabase.inMemory()
        store = DatabaseRosterStore(database: database)
        session = try makeSession(me, database: database)
        context = session.client
    }

    @Test func itemsRoundTrip() throws {
        store.updateItem(for: context, jid: alice, name: "Alice", subscription: .both, groups: ["friends"], ask: false, annotations: [])
        store.updateItem(for: context, jid: bob, name: nil, subscription: .to, groups: [], ask: true, annotations: [])

        let item = try #require(store.item(for: context, jid: alice))
        #expect(item.jid == alice)
        #expect(item.name == "Alice")
        #expect(item.subscription == .both)
        #expect(item.ask == false)
        // Kept, to send back with a rename.
        #expect(item.groups == ["friends"])

        let pending = try #require(store.item(for: context, jid: bob))
        #expect(pending.name == nil)
        #expect(pending.subscription == .to)
        #expect(pending.ask)
        #expect(Set(store.items(for: context).map(\.jid)) == [alice, bob])
    }

    @Test func updatingReplacesTheItem() throws {
        store.updateItem(for: context, jid: alice, name: "Alice", subscription: .to, groups: [], ask: false, annotations: [])
        store.updateItem(for: context, jid: alice, name: "Ally", subscription: .both, groups: [], ask: false, annotations: [])
        #expect(store.items(for: context).count == 1)
        #expect(store.item(for: context, jid: alice)?.name == "Ally")
        #expect(store.item(for: context, jid: alice)?.subscription == .both)
    }

    @Test func deletingDropsTheItem() throws {
        store.updateItem(for: context, jid: alice, name: "Alice", subscription: .both, groups: [], ask: false, annotations: [])
        store.updateItem(for: context, jid: bob, name: "Bob", subscription: .both, groups: [], ask: false, annotations: [])
        store.deleteItem(for: context, jid: alice)
        #expect(store.item(for: context, jid: alice) == nil)
        #expect(store.items(for: context).map(\.jid) == [bob])
        // Deleting what isn't there is harmless.
        store.deleteItem(for: context, jid: Martin.JID("nobody@example.org"))
    }

    @Test func unknownContactsAreNotItems() throws {
        // A contact we only chat with isn't on the roster.
        _ = try database.conversation(with: YapnestKit.JID("alice@example.org")!)
        try database.writer.write { try Contact(jid: YapnestKit.JID("alice@example.org")!).save($0) }
        #expect(store.item(for: context, jid: alice) == nil)
        #expect(store.items(for: context).isEmpty)
    }

    @Test func versionPersistsInSettings() throws {
        #expect(store.version(for: context) == nil)
        store.set(version: "42", for: context)
        #expect(store.version(for: context) == "42")
        #expect(try database.setting(.rosterVersion) == "42")
        // Another store over the same database, as in a new session.
        #expect(DatabaseRosterStore(database: database).version(for: context) == "42")
        store.clear(for: context)
        #expect(store.version(for: context) == nil)
    }
}
