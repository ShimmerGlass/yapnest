import Foundation
import GRDB

/// An encrypted group message from a device we had never seen. The room's
/// word that the device is the member's isn't enough to decrypt it, so a
/// placeholder is stored and the raw stanza waits here until the device has
/// been checked against the member's own device list.
struct HeldGroupMessage: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "heldGroupMessage"

    var id: Int64?
    /// The undecryptable placeholder that stands in for the message.
    var messageId: Int64
    /// The member the room named as the sender.
    var sender: JID
    var deviceId: Int32
    /// The message element as received, before any decryption.
    var stanza: String
    var isHistory: Bool
    var heldAt: Date
    private var sourceKind: String
    private var serverId: String?
    private var archivedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, messageId, sender, deviceId, stanza, isHistory, heldAt
        case sourceKind = "source", serverId, archivedAt
    }

    init(id: Int64? = nil, messageId: Int64, sender: JID, deviceId: Int32, stanza: String, source: InboundMessage.Source, isHistory: Bool, heldAt: Date = Date()) {
        self.id = id
        self.messageId = messageId
        self.sender = sender
        self.deviceId = deviceId
        self.stanza = stanza
        self.isHistory = isHistory
        self.heldAt = heldAt
        switch source {
        case .live:
            sourceKind = "live"
        case .carbon(let sent):
            sourceKind = sent ? "carbon-sent" : "carbon-received"
        case .archive(let serverId, let timestamp):
            sourceKind = "archive"
            self.serverId = serverId
            archivedAt = timestamp
        }
    }

    var source: InboundMessage.Source {
        switch sourceKind {
        case "carbon-sent": .carbon(sent: true)
        case "carbon-received": .carbon(sent: false)
        case "archive": .archive(serverId: serverId ?? "", timestamp: archivedAt)
        default: .live
        }
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
