import Foundation
import GRDB

/// A block or unblock (XEP-0191) we've made here and the server hasn't
/// confirmed, kept so that it survives being offline and the app being
/// killed. The latest change for a person replaces an earlier unsent one.
struct PendingBlockChange: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pendingBlockChange"

    var id: Int64?
    var jid: JID
    /// What we want: blocked or not.
    var blocked: Bool
    /// Why we report them along with the block, stored as the reason's raw value.
    var reason: XMPPSession.ReportReason?
    /// Whether they had a contact request that the block declines first.
    var declinesRequest: Bool
    /// Whether they were blocked before the first unsent change, for putting
    /// it back if the server refuses, and for a block undone before it was sent.
    var wasBlocked: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
