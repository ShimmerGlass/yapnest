import Foundation
import GRDB
import Testing
import UserNotifications
@testable import YapnestKit

struct NotificationSoundTests {
    let alice = JID("alice@example.org")!

    @Test func noChoiceIsTheSystemSound() {
        #expect(NotificationSound.choice(kind: .chat, stored: nil, isQuiet: false) == .systemDefault)
    }

    @Test func noneIsSilent() {
        #expect(NotificationSound.choice(kind: .chat, stored: NotificationSound.silent, isQuiet: false) == .none)
        #expect(NotificationSound.Choice.none.unSound == nil)
    }

    @Test func aBundledSoundIsPlayedByFileName() {
        #expect(NotificationSound.choice(kind: .chat, stored: "chime.caf", isQuiet: false) == .file("chime.caf"))
    }

    @Test func mutedStaysSilentWhateverWasChosen() {
        #expect(NotificationSound.choice(kind: .chat, stored: "chime.caf", isQuiet: true) == .none)
        #expect(NotificationSound.choice(kind: .chat, stored: nil, isQuiet: true) == .none)
    }

    @Test func anUnknownNameFallsBackToTheSystemSound() {
        #expect(NotificationSound.choice(kind: .chat, stored: "gone.caf", isQuiet: false) == .systemDefault)
    }

    @Test func groupsIgnoreTheStoredChoice() {
        #expect(NotificationSound.choice(kind: .groupchat, stored: "chime.caf", isQuiet: false) == .systemDefault)
        #expect(NotificationSound.choice(kind: .groupchat, stored: NotificationSound.silent, isQuiet: false) == .systemDefault)
    }

    @Test func namesAreShownForTheChoice() {
        #expect(NotificationSound.displayName(of: nil) == "Default")
        #expect(NotificationSound.displayName(of: NotificationSound.silent) == "None")
        #expect(NotificationSound.displayName(of: "chime.caf") == "Chime")
        #expect(NotificationSound.displayName(of: "gone.caf") == "Default")
    }

    @Test func theBundledFilesAreDistinct() {
        let files = NotificationSound.bundled.map(\.file)
        #expect(Set(files).count == files.count)
        #expect(!files.contains(NotificationSound.silent))
    }

    @Test func theSettingIsStoredPerChat() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.notificationSound(peer: alice) == nil)
        try db.setNotificationSound("pop.caf", peer: alice)
        #expect(try db.notificationSound(peer: alice) == "pop.caf")
        #expect(try db.notificationSound(peer: JID("bob@example.org")!) == nil)
        try db.setNotificationSound(nil, peer: alice)
        #expect(try db.notificationSound(peer: alice) == nil)
    }

    @Test func theMigrationAddsTheColumn() throws {
        let db = try AppDatabase.inMemory()
        let columns = try db.reader.read { try $0.columns(in: "conversation").map(\.name) }
        #expect(columns.contains("notificationSound"))
    }

    @Test func aNotificationCarriesTheChatsSound() throws {
        let db = try AppDatabase.inMemory()
        let chat = try db.conversation(with: alice)
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "old", remoteId: "r0"))
        _ = try db.claimNotifications()
        try db.setNotificationSound("bloom.caf", peer: alice)
        try db.insert(Message(conversationId: chat.id!, direction: .incoming, sender: alice, body: "hi", remoteId: "r1"))
        let notification = try #require(try db.claimNotifications().first)
        #expect(notification.content(badge: nil).sound == UNNotificationSound(named: UNNotificationSoundName("bloom.caf")))
    }

    @Test func aQuietNotificationHasNoSound() {
        var notification = MessageNotification(messageId: 1, peer: alice, title: "a", body: "b", timestamp: Date(), isQuiet: true, sound: "pop.caf")
        #expect(notification.content(badge: nil).sound == nil)
        notification.isQuiet = false
        #expect(notification.content(badge: nil).sound != nil)
        notification.sound = nil
        #expect(notification.content(badge: nil).sound == .default)
    }
}
