import Foundation
import GRDB
import Testing
@testable import YapnestKit

struct MapPreviewTests {
    private let alice = JID("alice@example.org")!
    private let room = JID("room@conference.example.org")!

    @Test(arguments: [
        // enabled, consented, trusted, tapped, shown
        (false, false, false, false, MapPreview.Display.off),
        (false, false, false, true, .off),
        (false, false, true, false, .off),
        (false, false, true, true, .off),
        (false, true, false, false, .off),
        (false, true, false, true, .off),
        (false, true, true, false, .off),
        (false, true, true, true, .off),
        (true, false, false, false, .askConsent),
        (true, false, false, true, .askConsent),
        (true, false, true, false, .askConsent),
        (true, false, true, true, .askConsent),
        (true, true, false, false, .tapToShow),
        (true, true, false, true, .map),
        (true, true, true, false, .map),
        (true, true, true, true, .map),
    ])
    func theDisplayForEveryCombination(enabled: Bool, consented: Bool, trusted: Bool, tapped: Bool, shown: MapPreview.Display) {
        let settings = MapPreview.Settings(enabled: enabled, consented: consented)
        #expect(settings.display(trusted: trusted, tappedToShow: tapped) == shown)
    }

    @Test func mapsAreOnWithoutConsentByDefault() throws {
        let db = try AppDatabase.inMemory()
        #expect(db.mapPreviewSettings == MapPreview.Settings())
    }

    @Test func theSettingsSwitchIsOnOnlyOnceMapsAreAllowedAndConsentedTo() throws {
        let db = try AppDatabase.inMemory()
        #expect(!db.mapPreviewSettings.switchIsOn)
        try db.agreeToMapPreviews()
        #expect(db.mapPreviewSettings.switchIsOn)
        try db.turnOffMapPreviews()
        #expect(!db.mapPreviewSettings.switchIsOn)
        try db.setMapPreviews(true)
        #expect(db.mapPreviewSettings.switchIsOn)
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
        #expect(chat.trusts(message(from: alice), groupIsPrivate: nil))
        #expect(!chat.trusts(message(from: JID("bob@example.org")!), groupIsPrivate: nil))
        #expect(MapPreview.Trust().trusts(message(from: alice, outgoing: true), groupIsPrivate: nil))

        let members = MapPreview.Trust(trustsGroupMembers: true)
        #expect(members.trusts(message(from: alice), groupIsPrivate: true))
        #expect(!members.trusts(message(from: alice), groupIsPrivate: false))
        #expect(!MapPreview.Trust(trustsGroupMembers: false).trusts(message(from: alice), groupIsPrivate: true))
        #expect(MapPreview.Trust(trustedContacts: [alice]).trusts(message(from: alice), groupIsPrivate: false))
        // A room's word that a message is ours isn't enough.
        #expect(!MapPreview.Trust().trusts(message(from: room, outgoing: true), groupIsPrivate: false))
        #expect(MapPreview.Trust().trusts(message(from: room, outgoing: true, writtenHere: true), groupIsPrivate: false))
    }

    @Test func aChatReadsOnlyItsPeerAndAGroupTheConsentedContacts() throws {
        let db = try AppDatabase.inMemory()
        let bob = JID("bob@example.org")!, carol = JID("carol@example.org")!, dave = JID("dave@example.org")!
        try db.writer.write { db in
            try Contact(jid: alice, subscription: .both, isInRoster: true).insert(db)
            try Contact(jid: bob, subscription: .both, isInRoster: true, isBlocked: true).insert(db)
            try Contact(jid: carol).insert(db)
            try Contact(jid: dave, isSubscriptionPending: true).insert(db)
        }
        #expect(try db.mapTrust(peer: alice, isGroup: false).trustedContacts == [alice])
        #expect(try db.mapTrust(peer: bob, isGroup: false).trustedContacts == [])
        #expect(try db.mapTrust(peer: carol, isGroup: false).trustedContacts == [])
        #expect(try db.mapTrust(peer: room, isGroup: true).trustedContacts == [alice, dave])

        try db.setFlag(.downloadsFromGroupMembers, false)
        #expect(try db.mapTrust(peer: room, isGroup: true).trustsGroupMembers == false)
    }

    @Test func aContactChangeUnrelatedToTheChatLeavesItsTrustAlone() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in try Contact(jid: alice, subscription: .both, isInRoster: true).insert(db) }
        let before = try db.mapTrust(peer: alice, isGroup: false)
        try db.writer.write { db in
            try Contact(jid: JID("bob@example.org")!, subscription: .both, isInRoster: true).insert(db)
            try Contact(jid: JID("carol@example.org")!, name: "Carol").insert(db)
        }
        #expect(try db.mapTrust(peer: alice, isGroup: false) == before)
    }

    /// What a chat's trust reads decides which writes wake its observation.
    @Test(arguments: [(JID?.none, true), (JID("alice@example.org"), false)])
    func trustIsNotWokenByAContactsNameAvatarOrLastSeen(peer: JID?, isGroup: Bool) async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var region: DatabaseRegion?
        }
        let db = try AppDatabase.inMemory()
        let box = Box()
        let room = room
        let running = ValueObservation.trackingConstantRegion { try AppDatabase.mapTrust($0, peer: peer ?? room, isGroup: isGroup) }
            .handleEvents(willTrackRegion: { region in box.lock.withLock { box.region = region } })
            .start(in: db.writer, scheduling: .async(onQueue: .global()), onError: { _ in }, onChange: { _ in })
        defer { running.cancel() }
        await eventually("the observation to track its region") { box.lock.withLock { box.region } != nil }
        let region = try #require(box.lock.withLock { box.region })
        for column in ["lastSeenAt", "avatarHash", "name"] {
            #expect(!region.isModified(byEventsOfKind: .update(tableName: "contact", columnNames: [column])), "\(column)")
        }
        #expect(region.isModified(byEventsOfKind: .update(tableName: "contact", columnNames: ["subscription"])))
        #expect(region.isModified(byEventsOfKind: .update(tableName: "contact", columnNames: ["isBlocked"])))
    }
}
