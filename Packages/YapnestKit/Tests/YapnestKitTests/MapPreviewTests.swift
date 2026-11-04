import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct MapPreviewTests {
    private let alice = JID("alice@example.org")!
    private let room = JID("room@conference.example.org")!

    @Test func policyCoversEveryCombination() {
        for enabled in [false, true] {
            for consented in [false, true] {
                for trusted in [false, true] {
                    for tapped in [false, true] {
                        let expected: MapPreview.Display = if !enabled {
                            .off
                        } else if !consented {
                            .askConsent
                        } else if !trusted && !tapped {
                            .tapToShow
                        } else {
                            .map
                        }
                        #expect(MapPreview.decide(enabled: enabled, consented: consented, trusted: trusted, tappedToShow: tapped) == expected)
                    }
                }
            }
        }
    }

    @Test func noSnapshotIsAskedForUntilTheUserAgrees() {
        for trusted in [false, true] {
            for tapped in [false, true] {
                #expect(MapPreview.decide(enabled: true, consented: false, trusted: trusted, tappedToShow: tapped) == .askConsent)
                #expect(MapPreview.decide(enabled: false, consented: true, trusted: trusted, tappedToShow: tapped) == .off)
            }
        }
        #expect(MapPreview.decide(enabled: true, consented: true, trusted: false, tappedToShow: false) == .tapToShow)
        #expect(MapPreview.decide(enabled: true, consented: true, trusted: false, tappedToShow: true) == .map)
        #expect(MapPreview.decide(enabled: true, consented: true, trusted: true, tappedToShow: false) == .map)
    }

    @Test func mapsAreOnWithoutConsentByDefault() throws {
        let db = try AppDatabase.inMemory()
        #expect(db.mapPreviewSettings == MapPreview.Settings(enabled: true, consented: false))
    }

    @Test func theFlagSyncsAndTheConsentDoesNot() throws {
        let synced = AppDatabase.syncedGlobalKeys
        #expect(synced[.mapPreviews] != nil)
        #expect(synced[.mapConsent] == nil)
    }

    @Test func turningTheFlagOnOrOffIsRecordedForSync() throws {
        let db = try AppDatabase.inMemory()
        try db.setMapPreviews(false)
        #expect(db.mapPreviewSettings.enabled == false)
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncedEntry WHERE item = 'global' AND key = 'mapPreviews'") } == 1)
    }

    @Test func notNowTurnsMapsOffWithoutConsent() throws {
        let db = try AppDatabase.inMemory()
        try db.turnOffMapPreviews()
        #expect(db.mapPreviewSettings == MapPreview.Settings(enabled: false, consented: false))
    }

    @Test func showMapsRecordsConsentAndKeepsTheFlag() throws {
        let db = try AppDatabase.inMemory()
        try db.agreeToMapPreviews()
        #expect(db.mapPreviewSettings == MapPreview.Settings(enabled: true, consented: true))
    }

    @Test func switchingMapsOnInSettingsCountsAsConsent() throws {
        let db = try AppDatabase.inMemory()
        try db.setMapPreviews(false)
        #expect(db.mapPreviewSettings.consented == false)
        try db.setMapPreviews(true)
        #expect(db.mapPreviewSettings == MapPreview.Settings(enabled: true, consented: true))
    }

    @Test func switchingMapsOffKeepsAnEarlierConsent() throws {
        let db = try AppDatabase.inMemory()
        try db.agreeToMapPreviews()
        try db.setMapPreviews(false)
        #expect(db.mapPreviewSettings == MapPreview.Settings(enabled: false, consented: true))
    }

    private func message(from sender: JID, outgoing: Bool = false, writtenHere: Bool = false) -> Message {
        var message = Message(conversationId: 1, direction: outgoing ? .outgoing : .incoming, sender: sender, body: "geo:1,2")
        message.isWrittenHere = writtenHere
        return message
    }

    @Test func trustFollowsTheImageAutoDownloadRule() {
        let chat = MapPreview.Trust(trustedContacts: [alice])
        #expect(chat.trusts(message(from: alice)))
        #expect(!chat.trusts(message(from: JID("bob@example.org")!)))
        #expect(MapPreview.Trust().trusts(message(from: alice, outgoing: true)))

        let privateGroup = MapPreview.Trust(isGroup: true, isPrivateGroup: true, trustsGroupMembers: true)
        #expect(privateGroup.trusts(message(from: alice)))
        var strict = privateGroup
        strict.trustsGroupMembers = false
        #expect(!strict.trusts(message(from: alice)))
        #expect(MapPreview.Trust(isGroup: true).trusts(message(from: alice)) == false)
        #expect(MapPreview.Trust(trustedContacts: [alice], isGroup: true).trusts(message(from: alice)))
        // A room's word that a message is ours isn't enough.
        #expect(!MapPreview.Trust(isGroup: true).trusts(message(from: room, outgoing: true)))
        #expect(MapPreview.Trust(isGroup: true).trusts(message(from: room, outgoing: true, writtenHere: true)))
    }

    @Test func trustReadsContactsAndTheGroupFromTheDatabase() throws {
        let db = try AppDatabase.inMemory()
        let bob = JID("bob@example.org")!, carol = JID("carol@example.org")!
        try db.writer.write { db in
            try Contact(jid: alice, subscription: .both, isInRoster: true).insert(db)
            try Contact(jid: bob, subscription: .both, isInRoster: true, isBlocked: true).insert(db)
            try Contact(jid: carol).insert(db)
        }
        let direct = try db.mapTrust(peer: alice)
        #expect(direct.trustedContacts == [alice])
        #expect(!direct.isGroup)

        let id = try db.writer.write { db in try AppDatabase.conversation(db, with: room).id! }
        try db.writer.write { db in
            try GroupChat(conversationId: id, jid: room, nickname: "me", isMembersOnly: true, isNonAnonymous: true).insert(db)
        }
        try db.setFlag(.downloadsFromGroupMembers, false)
        let group = try db.mapTrust(peer: room)
        #expect(group.isGroup && group.isPrivateGroup && !group.trustsGroupMembers)
    }
}
