import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The setting that decides whether chats started from now on are encrypted.
struct EncryptNewChatsTests {
    let alice = YapnestKit.JID("alice@example.org")!
    let bob = YapnestKit.JID("bob@example.org")!
    let room = YapnestKit.JID("room@conference.example.org")!

    @Test func newChatsAreEncryptedUntilTurnedOff() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.conversation(with: alice).isEncrypted)
        #expect(try db.isEncrypted(with: bob))
    }

    @Test func turnedOffANewChatIsNotEncrypted() throws {
        let db = try AppDatabase.inMemory()
        try db.setFlag(.encryptsNewChats, false)
        #expect(try db.isEncrypted(with: bob) == false)
        #expect(try db.conversation(with: bob).isEncrypted == false)
    }

    @Test func existingChatsKeepTheirChoiceWhateverTheSettingSays() throws {
        let db = try AppDatabase.inMemory()
        try db.conversation(with: alice)
        try db.setFlag(.encryptsNewChats, false)
        #expect(try db.conversation(with: alice).isEncrypted)
        #expect(try db.isEncrypted(with: alice))

        try db.setFlag(.encryptsNewChats, true)
        try db.conversation(with: bob)
        try db.setEncrypted(false, with: bob)
        #expect(try db.conversation(with: bob).isEncrypted == false)
    }

    @Test func aChatCanStillBeEncryptedByChoiceWhenTheSettingIsOff() throws {
        let db = try AppDatabase.inMemory()
        try db.setFlag(.encryptsNewChats, false)
        try db.conversation(with: alice)
        try db.setEncrypted(true, with: alice)
        #expect(try db.isEncrypted(with: alice))
    }

    @Test func aNewGroupIsNotEncryptedUntilItsRoomIsKnownToBePrivate() throws {
        let db = try AppDatabase.inMemory()
        try db.joinGroupChat(room, nickname: "me")
        #expect(try db.isEncrypted(with: room) == false)
    }

    @Test func itSyncsLikeTheOtherPrivacySettings() throws {
        let db = try AppDatabase.inMemory()
        #expect(AppDatabase.syncedGlobalKeys[.encryptsNewChats] != nil)
        #expect(AppDatabase.syncedGlobalKeys[.welcomeShown] == nil)

        let off = SettingsEntry(key: "encryptsNewChats", value: "0", version: SettingsVersion(ms: 100, counter: 0), by: "other")
        let result = try db.writer.write { try AppDatabase.applyRemote($0, item: "global", entries: [off]) }
        #expect(result.changedGlobalKeys == [.encryptsNewChats])
        #expect(try db.isEncrypted(with: bob) == false)

        try db.setFlag(.encryptsNewChats, true)
        let published = try db.reader.read { try AppDatabase.syncedEntries($0, item: "global") }
        let entry = try #require(published.first { $0.key == "encryptsNewChats" })
        #expect(entry.version > off.version)
    }
}
