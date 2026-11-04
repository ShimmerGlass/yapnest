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

    /// The two flags `display` reads, as one value to observe.
    public struct Settings: Sendable, Equatable {
        public var enabled: Bool
        public var consented: Bool

        public init(enabled: Bool = true, consented: Bool = false) {
            self.enabled = enabled
            self.consented = consented
        }

        /// What Settings' switch shows. Maps are on by default but wait for
        /// consent, so a switch that read only the flag would say on while
        /// every card still asks.
        public var switchIsOn: Bool { enabled && consented }

        /// The order matters: the setting beats everything, consent comes
        /// before the stranger rule, and a tap only lifts the stranger rule.
        public func display(trusted: Bool, tappedToShow: Bool) -> Display {
            if !enabled { return .off }
            if !consented { return .askConsent }
            if !trusted && !tappedToShow { return .tapToShow }
            return .map
        }
    }

    /// Who counts as trusted in a chat: exactly who has images downloaded
    /// for them unasked (`XMPPSession.trustsForAutoDownload`). What it holds
    /// is read narrowly: a 1:1 chat's peer alone, and in a group the
    /// contacts the user consented to.
    public struct Trust: Sendable, Equatable {
        public var trustedContacts: Set<JID>
        public var trustsGroupMembers: Bool

        public init(trustedContacts: Set<JID> = [], trustsGroupMembers: Bool = true) {
            self.trustedContacts = trustedContacts
            self.trustsGroupMembers = trustsGroupMembers
        }

        /// `groupIsPrivate` is nil outside a group. A 1:1 chat's sender is the
        /// peer; a group message's is the real address of its author, which
        /// only a room that shows them has.
        public func trusts(_ message: Message, groupIsPrivate: Bool?) -> Bool {
            XMPPSession.trustsForAutoDownload(
                isOutgoing: Message.isTrustedOutgoing(isOutgoing: message.direction == .outgoing, isWrittenHere: message.isWrittenHere, inGroup: groupIsPrivate != nil),
                isPrivateGroup: groupIsPrivate ?? false, trustsGroupMembers: trustsGroupMembers,
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

    public func mapTrust(peer: JID, isGroup: Bool) throws -> MapPreview.Trust {
        try reader.read { try Self.mapTrust($0, peer: peer, isGroup: isGroup) }
    }

    static func mapTrust(_ db: Database, peer: JID, isGroup: Bool) throws -> MapPreview.Trust {
        MapPreview.Trust(
            trustedContacts: try consentedContacts(db, peer: isGroup ? nil : peer),
            trustsGroupMembers: try flag(db, .downloadsFromGroupMembers, default: true),
        )
    }

    public func observeMapTrust(peer: JID, isGroup: Bool) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<MapPreview.Trust>>> {
        ValueObservation.trackingConstantRegion { db in try Self.mapTrust(db, peer: peer, isGroup: isGroup) }
        .removeDuplicates()
    }

    /// Settings' switch. Turning maps on there has the disclosure beside it,
    /// so it records the agreement too, in one write with the flag.
    public func setMapPreviews(_ on: Bool) throws {
        try writer.write { db in
            try Self.setFlagRecordingSync(db, .mapPreviews, on)
            if on { try Self.setFlagRecordingSync(db, .mapConsent, true) }
        }
    }

    /// "Show Maps" on a card. Recorded per install and not synced, like the GIF consent.
    public func agreeToMapPreviews() throws {
        try setFlag(.mapConsent, true)
    }
}
