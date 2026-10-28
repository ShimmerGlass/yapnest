import Foundation
import GRDB

/// Someone counted as being in a group.
struct RosterPerson: Hashable, Sendable {
    /// Their real address where the room shows it, else their nickname.
    let key: String
    let nick: String?
    let jid: JID?

    init(nick: String?, jid: JID?) {
        self.key = jid?.description ?? nick ?? ""
        self.nick = nick
        self.jid = jid
    }
}

/// A group's people as we last counted them, so that a room which quietly
/// adds someone, who then gets everything we encrypt there, shows in the
/// chat. Every call is for one group and writes its lines, when `writesLines`,
/// in the same transaction as the change they report. Nothing is recorded
/// until the group's first join has taken its baseline.
extension AppDatabase {
    private struct RosterEntry: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "groupRoster"
        var conversationId: Int64
        var key: String
        var nick: String?
        var jid: JID?
        var isPresent: Bool
        var hasLeft = false

        init(conversationId: Int64, person: RosterPerson, isPresent: Bool) {
            self.conversationId = conversationId
            self.key = person.key
            self.nick = person.nick
            self.jid = person.jid
            self.isPresent = isPresent
        }

        var person: RosterPerson { RosterPerson(nick: nick, jid: jid) }
    }

    private static func rosterIsTaken(_ db: Database, _ conversationId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM groupRosterTaken WHERE conversationId = ?)", arguments: [conversationId]) ?? false
    }

    private static func rosterEntry(_ db: Database, _ conversationId: Int64, _ key: String) throws -> RosterEntry? {
        try RosterEntry.filter(Column("conversationId") == conversationId && Column("key") == key).fetchOne(db)
    }

    private static func rosterLine(_ db: Database, _ event: MessageEvent, room: JID, conversationId: Int64, person: RosterPerson, at date: Date) throws {
        var line = Message.eventLine(conversationId: conversationId, sender: person.jid ?? room, nick: person.nick, event: event, at: date)
        try line.insert(db)
    }

    /// Our own join is over with `present` in the room. The first time, they
    /// are counted without a word. After that, whoever is present and was not
    /// counted joined, whoever was counted as present and is not has left,
    /// and the rest stay.
    func rosterSelfJoined(conversationId: Int64, room: JID, present: [RosterPerson], writesLines: Bool, at date: Date) throws {
        try writer.write { db in
            guard try Self.rosterIsTaken(db, conversationId) else {
                try Self.rosterTake(db, conversationId, present)
                return
            }
            let now = Dictionary(present.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            var entries = Dictionary(
                uniqueKeysWithValues: try RosterEntry.filter(Column("conversationId") == conversationId).fetchAll(db).map { ($0.key, $0) },
            )
            for entry in entries.values.sorted(by: { $0.key < $1.key }) where entry.isPresent && !entry.hasLeft && now[entry.key] == nil {
                try Self.rosterLeave(db, entry, room: room, endsMembership: false, writesLines: writesLines, at: date)
            }
            for person in now.values.sorted(by: { $0.key < $1.key }) {
                if var entry = entries.removeValue(forKey: person.key) {
                    try Self.rosterReturn(db, &entry, as: person, room: room, writesLines: writesLines, at: date)
                } else {
                    try Self.rosterInsert(db, person, isPresent: true, room: room, conversationId: conversationId, writesLines: writesLines, at: date)
                }
            }
        }
    }

    /// Someone with an entry is here, under the name they are seen by: one
    /// counted from a member list has none yet. Having left, they have come back.
    private static func rosterReturn(_ db: Database, _ entry: inout RosterEntry, as person: RosterPerson, room: JID, writesLines: Bool, at date: Date) throws {
        let returned = entry.hasLeft
        guard !entry.isPresent || entry.nick != person.nick || returned else { return }
        entry.isPresent = true
        entry.hasLeft = false
        entry.nick = person.nick
        try entry.update(db)
        if returned, writesLines { try rosterLine(db, .joinedGroup, room: room, conversationId: entry.conversationId, person: person, at: date) }
    }

    private static func rosterTake(_ db: Database, _ conversationId: Int64, _ present: [RosterPerson]) throws {
        try db.execute(sql: "INSERT INTO groupRosterTaken (conversationId) VALUES (?)", arguments: [conversationId])
        for person in present {
            try RosterEntry(conversationId: conversationId, person: person, isPresent: true).insert(db, onConflict: .replace)
        }
    }

    private static func rosterInsert(_ db: Database, _ person: RosterPerson, isPresent: Bool, room: JID, conversationId: Int64, writesLines: Bool, at date: Date) throws {
        try RosterEntry(conversationId: conversationId, person: person, isPresent: isPresent).insert(db)
        if writesLines { try rosterLine(db, .joinedGroup, room: room, conversationId: conversationId, person: person, at: date) }
    }

    private static func rosterArrive(_ db: Database, _ person: RosterPerson, room: JID, conversationId: Int64, writesLines: Bool, at date: Date) throws {
        if var entry = try rosterEntry(db, conversationId, person.key) {
            try rosterReturn(db, &entry, as: person, room: room, writesLines: writesLines, at: date)
            return
        }
        try rosterInsert(db, person, isPresent: true, room: room, conversationId: conversationId, writesLines: writesLines, at: date)
    }

    /// Someone is gone. Unless that ends their membership, they stay listed
    /// as having left, so that being listed again says nothing.
    private static func rosterLeave(_ db: Database, _ entry: RosterEntry, room: JID, endsMembership: Bool, writesLines: Bool, at date: Date) throws {
        if endsMembership {
            try entry.delete(db)
        } else {
            var entry = entry
            entry.isPresent = false
            entry.hasLeft = true
            try entry.update(db)
        }
        if writesLines { try rosterLine(db, .leftGroup, room: room, conversationId: entry.conversationId, person: entry.person, at: date) }
    }

    /// Someone arrived in a group that has its baseline.
    func rosterArrived(conversationId: Int64, room: JID, person: RosterPerson, writesLines: Bool, at date: Date) throws {
        try writer.write { db in
            guard try Self.rosterIsTaken(db, conversationId) else { return }
            try Self.rosterArrive(db, person, room: room, conversationId: conversationId, writesLines: writesLines, at: date)
        }
    }

    /// Someone counted as present is gone.
    func rosterDeparted(conversationId: Int64, room: JID, key: String, endsMembership: Bool, writesLines: Bool, at date: Date) throws {
        try writer.write { db in
            guard let entry = try Self.rosterEntry(db, conversationId, key), entry.isPresent, !entry.hasLeft else { return }
            try Self.rosterLeave(db, entry, room: room, endsMembership: endsMembership, writesLines: writesLines, at: date)
        }
    }

    /// Someone changed nickname. In a room that shows no addresses the
    /// nickname is who they are, so their entry moves to it.
    func rosterRenamed(conversationId: Int64, from key: String, to person: RosterPerson) throws {
        try writer.write { db in
            guard var entry = try Self.rosterEntry(db, conversationId, key) else { return }
            if key != person.key {
                try entry.delete(db)
                entry.key = person.key
            }
            entry.nick = person.nick
            try entry.save(db)
        }
    }

    /// The room lists members, not present unless we know otherwise. Those
    /// listed right after the baseline was taken are counted quietly: they
    /// were there. After that, a member we have no entry for was added since.
    func rosterListed(conversationId: Int64, room: JID, members: [JID], writesLines: Bool, at date: Date) throws {
        try writer.write { db in
            guard let listed = try Bool.fetchOne(db, sql: "SELECT listed FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId]) else { return }
            for jid in members {
                guard try Self.rosterEntry(db, conversationId, jid.description) == nil else { continue }
                try Self.rosterInsert(db, RosterPerson(nick: nil, jid: jid), isPresent: false, room: room, conversationId: conversationId, writesLines: writesLines && listed, at: date)
            }
        }
    }

    /// Every list asked for after the baseline was taken has come.
    func rosterListingDone(conversationId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE groupRosterTaken SET listed = 1 WHERE conversationId = ?", arguments: [conversationId])
        }
    }

    /// Counts `present` afresh, quietly, for a room whose people are told
    /// apart differently now. A join in progress takes its own baseline.
    func rosterRekeyed(conversationId: Int64, present: [RosterPerson]?) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM groupRoster WHERE conversationId = ?", arguments: [conversationId])
            try db.execute(sql: "DELETE FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId])
            if let present { try Self.rosterTake(db, conversationId, present) }
        }
    }

    /// The room made `jid` a member, or took their membership. Someone who
    /// is here keeps their place; the room ending it is theirs to hear of.
    func rosterAffiliated(conversationId: Int64, room: JID, jid: JID, isMember: Bool, isPresent: Bool, writesLines: Bool, at date: Date) throws {
        try writer.write { db in
            guard try Self.rosterIsTaken(db, conversationId) else { return }
            let entry = try Self.rosterEntry(db, conversationId, jid.description)
            if isMember {
                guard entry == nil else { return }
                try Self.rosterInsert(db, RosterPerson(nick: nil, jid: jid), isPresent: false, room: room, conversationId: conversationId, writesLines: writesLines, at: date)
            } else if let entry, !isPresent {
                // One who had left was told of already.
                try Self.rosterLeave(db, entry, room: room, endsMembership: true, writesLines: writesLines && !entry.hasLeft, at: date)
            }
        }
    }

    /// Forgets a group's people, for a group we left or that ended: coming
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
                try Self.rosterLine(db, event, room: room, conversationId: conversationId, person: RosterPerson(nick: who.nick, jid: who.jid), at: Date().addingTimeInterval(base + Double(index)))
            }
        }
    }
}
