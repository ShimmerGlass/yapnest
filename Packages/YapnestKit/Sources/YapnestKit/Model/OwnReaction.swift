import GRDB

/// Where our reactions on one message stand with the server. It lives apart
/// from the reaction rows because the set we hold can be empty (we took our
/// last reaction back), and an empty set has no row to carry a pending id or an
/// error. A record exists only while the set is unacknowledged or failed.
public struct OwnReaction: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var messageId: Int64
    /// The id of the newest stanza carrying our set, which the server hasn't
    /// acknowledged. Nil once it was given up on.
    public var pendingId: String?
    /// Why the set never reached the other side for good. Cleared when it is
    /// sent again.
    public var error: String?
    /// The ids of our earlier stanzas for this message since the last
    /// acknowledgement. Their echoes arrive after we toggled again, and carry
    /// a set that is stale by then.
    public var earlierIds: [String]

    public init(messageId: Int64, pendingId: String? = nil, error: String? = nil, earlierIds: [String] = []) {
        self.messageId = messageId
        self.pendingId = pendingId
        self.error = error
        self.earlierIds = earlierIds
    }

    /// How many earlier ids are kept. A message toggled or failing again and
    /// again must not grow its record for ever, and an echo of a stanza older
    /// than this many is long gone.
    static let earlierIdsKept = 32

    /// Remembers `id` as the id of a stanza of ours that is no longer the newest.
    mutating func retire(_ id: String) {
        earlierIds.append(id)
        if earlierIds.count > Self.earlierIdsKept { earlierIds.removeFirst(earlierIds.count - Self.earlierIdsKept) }
    }

    public static let databaseTableName = "ownReaction"
}
