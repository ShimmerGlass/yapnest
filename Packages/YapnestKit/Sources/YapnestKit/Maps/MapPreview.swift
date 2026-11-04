import Foundation
import GRDB

/// What a shared location's card shows. A map snapshot is drawn by Apple's
/// servers, which learn the place and this device's IP address, so the card
/// only asks for one when the user has allowed it and, for someone they
/// haven't added, has tapped for it.
public enum MapPreview {
    public enum Display: Sendable, Equatable {
        /// Draws the map.
        case map
        /// A pin and the coordinates, with the notice asking to agree.
        case askConsent
        /// A pin and the coordinates, with a button that loads this map.
        case tapToShow
        /// A pin and the coordinates only.
        case off
    }

    /// The order matters: the setting beats everything, consent comes before
    /// the stranger rule, and a tap only lifts the stranger rule.
    public static func decide(enabled: Bool, consented: Bool, trusted: Bool, tappedToShow: Bool) -> Display {
        if !enabled { return .off }
        if !consented { return .askConsent }
        if !trusted && !tappedToShow { return .tapToShow }
        return .map
    }

    /// The two flags `decide` reads, as one value to observe.
    public struct Settings: Sendable, Equatable {
        public var enabled: Bool
        public var consented: Bool

        public init(enabled: Bool = true, consented: Bool = false) {
            self.enabled = enabled
            self.consented = consented
        }
    }

    /// Who counts as trusted in one chat: exactly who has images downloaded
    /// for them unasked (`XMPPSession.trustsForAutoDownload`).
    public struct Trust: Sendable, Equatable {
        /// The contacts the user added or approved and hasn't blocked.
        public var trustedContacts: Set<JID>
        public var isGroup: Bool
        public var isPrivateGroup: Bool
        public var trustsGroupMembers: Bool

        public init(trustedContacts: Set<JID> = [], isGroup: Bool = false, isPrivateGroup: Bool = false, trustsGroupMembers: Bool = true) {
            self.trustedContacts = trustedContacts
            self.isGroup = isGroup
            self.isPrivateGroup = isPrivateGroup
            self.trustsGroupMembers = trustsGroupMembers
        }

        /// A 1:1 chat's sender is the peer; a group message's is the real
        /// address of its author, which only a room that shows them has.
        public func trusts(_ message: Message) -> Bool {
            XMPPSession.trustsForAutoDownload(
                isOutgoing: Message.isTrustedOutgoing(isOutgoing: message.direction == .outgoing, isWrittenHere: message.isWrittenHere, inGroup: isGroup),
                isPrivateGroup: isGroup && isPrivateGroup, trustsGroupMembers: trustsGroupMembers,
                isTrusted: trustedContacts.contains(message.sender),
            )
        }
    }
}

extension AppDatabase {
    public var mapPreviewSettings: MapPreview.Settings {
        (try? reader.read { try Self.mapPreviewSettings($0) }) ?? MapPreview.Settings()
    }

    static func mapPreviewSettings(_ db: Database) throws -> MapPreview.Settings {
        MapPreview.Settings(enabled: try flag(db, .mapPreviews, default: true), consented: try flag(db, .mapConsent, default: false))
    }

    public func observeMapPreviewSettings() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<MapPreview.Settings>>> {
        ValueObservation.trackingConstantRegion { db in try Self.mapPreviewSettings(db) }
        .removeDuplicates()
    }

    public func mapTrust(peer: JID) throws -> MapPreview.Trust {
        try reader.read { try Self.mapTrust($0, peer: peer) }
    }

    static func mapTrust(_ db: Database, peer: JID) throws -> MapPreview.Trust {
        let group = try GroupChat.filter(Column("jid") == peer).fetchOne(db)
        return MapPreview.Trust(
            trustedContacts: Set(try Contact.fetchAll(db).filter(\.mayReceive).map(\.jid)),
            isGroup: group != nil,
            isPrivateGroup: group?.isPrivate ?? false,
            trustsGroupMembers: try flag(db, .downloadsFromGroupMembers, default: true),
        )
    }

    public func observeMapTrust(peer: JID) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<MapPreview.Trust>>> {
        ValueObservation.trackingConstantRegion { db in try Self.mapTrust(db, peer: peer) }
        .removeDuplicates()
    }

    /// Settings' switch. Turning maps on there has the disclosure beside it,
    /// so it records the agreement too, in one write with the flag.
    public func setMapPreviews(_ on: Bool) throws {
        try writer.write { db in
            try Self.setSetting(db, .mapPreviews, on ? "1" : "0")
            try Self.touch(db, item: Self.globalItem, key: SettingKey.mapPreviews.rawValue)
            if on { try Self.setSetting(db, .mapConsent, "1") }
        }
    }

    /// "Show Maps" on a card. Recorded per install and not synced, like the GIF consent.
    public func agreeToMapPreviews() throws {
        try setSetting(.mapConsent, "1")
    }

    /// "Not Now" on a card: the Settings switch, with no consent recorded.
    public func turnOffMapPreviews() throws {
        try setFlag(.mapPreviews, false)
    }
}
