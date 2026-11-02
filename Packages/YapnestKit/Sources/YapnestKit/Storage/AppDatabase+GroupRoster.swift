import Foundation
import GRDB

/// A private group's members as we last counted them, so that a room which
/// quietly adds someone, who then gets everything we encrypt there, shows in
/// the chat, and so does one who is taken out. Membership is what decides who
/// reads what we encrypt in a private group; being online in the room says
/// nothing about it, so presence never moves anyone in or out. Every call is
/// for one group and writes its lines in the same transaction as the change
/// they report. Nothing is recorded until the group's first join has taken
/// its baseline, and the first complete member listing after it is the
/// baseline's content: counted, with no lines.
///
/// `groupRoster.isPresent` and `hasLeft` once followed presence. Nothing
/// reads them now: `isPresent` is always written false, and `hasLeft` is only
/// read on rows an older version left, which are dropped without a line.
extension AppDatabase {
    private struct RosterEntry: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "groupRoster"
        var conversationId: Int64
        var key: String
        var nick: String?
        var jid: JID?
        var isPresent = false
        var hasLeft = false

        init(conversationId: Int64, member: JID) {
            self.conversationId = conversationId
            self.key = member.description
            self.jid = member
        }
    }

    private static func rosterIsTaken(_ db: Database, _ conversationId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM groupRosterTaken WHERE conversationId = ?)", arguments: [conversationId]) ?? false
    }

    private static func rosterEntry(_ db: Database, _ conversationId: Int64, _ key: String) throws -> RosterEntry? {
        try RosterEntry.filter(Column("conversationId") == conversationId && Column("key") == key).fetchOne(db)
    }

    private static func rosterLine(_ db: Database, _ event: MessageEvent, room: JID, conversationId: Int64, sender: JID?, nick: String?, at date: Date) throws {
        var line = Message.eventLine(conversationId: conversationId, sender: sender ?? room, nick: nick, event: event, at: date)
        try line.insert(db)
    }

    private static func rosterAdd(_ db: Database, _ member: JID, room: JID, conversationId: Int64, writesLine: Bool, at date: Date) throws {
        try RosterEntry(conversationId: conversationId, member: member).insert(db)
        if writesLine { try rosterLine(db, .joinedGroup, room: room, conversationId: conversationId, sender: member, nick: nil, at: date) }
    }

    private static func rosterRemove(_ db: Database, _ entry: RosterEntry, room: JID, writesLine: Bool, at date: Date) throws {
        try entry.delete(db)
        if writesLine { try rosterLine(db, .leftGroup, room: room, conversationId: entry.conversationId, sender: entry.jid, nick: entry.nick, at: date) }
    }

    /// Our own join is over. The first time, the baseline begins, to be filled
    /// by the first complete listing.
    func rosterSelfJoined(conversationId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO groupRosterTaken (conversationId) VALUES (?)", arguments: [conversationId])
        }
    }

    /// The room lists members. Those listed before the baseline's listing is
    /// done are counted quietly: they were there. After that, a member we
    /// have no entry for was added since.
    func rosterListed(conversationId: Int64, room: JID, members: [JID], at date: Date) throws {
        try writer.write { db in
            guard let listed = try Bool.fetchOne(db, sql: "SELECT listed FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId]) else { return }
            for jid in members where try Self.rosterEntry(db, conversationId, jid.description) == nil {
                try Self.rosterAdd(db, jid, room: room, conversationId: conversationId, writesLine: listed, at: date)
            }
        }
    }

    /// One fetch of every member list came whole, naming `members` together.
    /// The first such listing is the baseline: it is counted as it is, those
    /// it no longer names included, without a word. After that, whoever was
    /// counted and is no longer named has left.
    func rosterListingDone(conversationId: Int64, room: JID, members: [JID], at date: Date) throws {
        try writer.write { db in
            guard let listed = try Bool.fetchOne(db, sql: "SELECT listed FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId]) else { return }
            let named = Set(members.map(\.description))
            let entries = try RosterEntry.filter(Column("conversationId") == conversationId).fetchAll(db)
            for entry in entries.sorted(by: { $0.key < $1.key }) where !named.contains(entry.key) {
                try Self.rosterRemove(db, entry, room: room, writesLine: listed && !entry.hasLeft, at: date)
            }
            let counted = Set(entries.map(\.key))
            for jid in members.sorted(by: { $0.description < $1.description }) where !counted.contains(jid.description) {
                try Self.rosterAdd(db, jid, room: room, conversationId: conversationId, writesLine: listed, at: date)
            }
            try db.execute(sql: "UPDATE groupRosterTaken SET listed = 1 WHERE conversationId = ?", arguments: [conversationId])
        }
    }

    /// Counts afresh, quietly, for a room whose privacy changed, so that what
    /// was counted under other rules is not compared with. A join in progress
    /// (`takesBaseline`) begins its baseline now; otherwise the next join does.
    func rosterRekeyed(conversationId: Int64, takesBaseline: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM groupRoster WHERE conversationId = ?", arguments: [conversationId])
            try db.execute(sql: "DELETE FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId])
            if takesBaseline { try db.execute(sql: "INSERT INTO groupRosterTaken (conversationId) VALUES (?)", arguments: [conversationId]) }
        }
    }

    /// The room made `jid` a member, or took their membership, wherever they
    /// are. Told by an affiliation notice and by a presence that ends
    /// membership alike, which only the first to arrive writes a line for.
    func rosterAffiliated(conversationId: Int64, room: JID, jid: JID, isMember: Bool, at date: Date) throws {
        try writer.write { db in
            guard try Self.rosterIsTaken(db, conversationId) else { return }
            let entry = try Self.rosterEntry(db, conversationId, jid.description)
            if isMember {
                guard entry == nil else { return }
                try Self.rosterAdd(db, jid, room: room, conversationId: conversationId, writesLine: true, at: date)
            } else if let entry {
                try Self.rosterRemove(db, entry, room: room, writesLine: !entry.hasLeft, at: date)
            }
        }
    }

    /// Forgets a group's members, for a group we left or that ended: coming
    /// back is a first join.
    func forgetRoster(conversationId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM groupRoster WHERE conversationId = ?", arguments: [conversationId])
            try db.execute(sql: "DELETE FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId])
        }
    }

    /// The lines a group's chat holds for people joining and leaving, as a
    /// fixture would have them.
    public func addRosterLinesForFixture(room: JID, joined: [(nick: String, jid: JID)], left: [(nick: String, jid: JID)]) throws {
        guard let conversationId = try groupChat(room)?.conversationId else { return }
        let lines = joined.map { (MessageEvent.joinedGroup, $0, -10.0) } + left.map { (MessageEvent.leftGroup, $0, -5.0) }
        try writer.write { db in
            for (index, (event, who, base)) in lines.enumerated() {
                try Self.rosterLine(db, event, room: room, conversationId: conversationId, sender: who.jid, nick: who.nick, at: Date().addingTimeInterval(base + Double(index)))
            }
        }
    }
}
