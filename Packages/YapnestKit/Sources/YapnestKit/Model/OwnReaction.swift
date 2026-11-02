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

    public init(messageId: Int64, pendingId: String? = nil, error: String? = nil) {
        self.messageId = messageId
        self.pendingId = pendingId
        self.error = error
    }

    public static let databaseTableName = "ownReaction"
}
