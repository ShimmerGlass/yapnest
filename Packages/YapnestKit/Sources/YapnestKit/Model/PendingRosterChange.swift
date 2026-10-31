import Foundation
import GRDB

/// A change to the roster or to a contact request that the server hasn't
/// confirmed, and so isn't applied here yet.
public enum PendingRosterKind: String, Codable, Sendable, DatabaseValueConvertible {
    case accept, decline, remove, rename
}

/// A roster change made here, kept so that it survives being offline and the
/// app being killed, and sent in the order it was made. The contact keeps
/// showing as it was, marked as waiting, until the server answers.
struct PendingRosterChange: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pendingRosterChange"

    var id: Int64?
    var jid: JID
    var kind: PendingRosterKind
    /// For a rename: the name, cleaned; nil goes back to the name they publish.
    var name: String?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
