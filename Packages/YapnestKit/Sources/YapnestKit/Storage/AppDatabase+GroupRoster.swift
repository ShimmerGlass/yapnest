import Foundation
import GRDB

/// A private group's members as we last counted them, so that a room which
/// quietly adds someone, who then gets everything we encrypt there, shows in
/// the chat, and so does one who is taken out. Membership is what decides who
/// reads what we encrypt in a private group; being online in the room says
/// nothing about it, so presence never moves anyone in or out. Every call is
/// for one group and writes its lines in the same transaction as the change
/// they report. Nothing is recorded until the group's first join has begun
/// its baseline, and the first complete member listing after it is the
/// baseline's content: counted, with no lines.
extension AppDatabase {
    /// Whether the baseline's listing is complete; nil while no baseline has begun.
    private static func rosterListedState(_ db: Database, _ conversationId: Int64) throws -> Bool? {
        try Bool.fetchOne(db, sql: "SELECT listed FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId])
    }

    /// `date` is when the change that begins it happened: a member fetch begun
    /// at or after it belongs to this baseline, an earlier one to a baseline
    /// that has been cleared since.
    static func rosterBeginBaseline(_ db: Database, _ conversationId: Int64, at date: Date) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO groupRosterTaken (conversationId, begunAt) VALUES (?, ?)", arguments: [conversationId, date])
    }

    static func rosterClear(_ db: Database, _ conversationId: Int64) throws {
        try db.execute(sql: "DELETE FROM groupRoster WHERE conversationId = ?", arguments: [conversationId])
        try db.execute(sql: "DELETE FROM groupRosterTaken WHERE conversationId = ?", arguments: [conversationId])
    }

    private static func rosterLine(_ db: Database, _ event: MessageEvent, conversationId: Int64, sender: JID, nick: String? = nil, at date: Date) throws {
        var line = Message.eventLine(conversationId: conversationId, sender: sender, nick: nick, event: event, at: date)
        try line.insert(db)
    }

    private static func rosterAdd(_ db: Database, _ member: JID, conversationId: Int64, writesLine: Bool, at date: Date) throws {
        try db.execute(sql: "INSERT INTO groupRoster (conversationId, jid, countedAt) VALUES (?, ?, ?)", arguments: [conversationId, member, date])
        if writesLine { try rosterLine(db, .joinedGroup, conversationId: conversationId, sender: member, at: date) }
    }

    private static func rosterRemove(_ db: Database, _ member: JID, conversationId: Int64, writesLine: Bool, at date: Date) throws {
        try db.execute(sql: "DELETE FROM groupRoster WHERE conversationId = ? AND jid = ?", arguments: [conversationId, member])
        if writesLine { try rosterLine(db, .leftGroup, conversationId: conversationId, sender: member, at: date) }
    }

    /// Our own join is over, `date` being when it was told. The first time,
    /// the baseline begins, to be filled by the first complete listing.
    func rosterSelfJoined(conversationId: Int64, at date: Date) throws {
        try writer.write { try Self.rosterBeginBaseline($0, conversationId, at: date) }
    }

    /// The room lists members. Those listed before the baseline's listing is
    /// done are counted quietly: they were there. After that, a member we
    /// have no entry for was added since.
    func rosterListed(conversationId: Int64, room: JID, members: [JID], at date: Date) throws {
        try writer.write { db in
            guard let listed = try Self.rosterListedState(db, conversationId) else { return }
            var counted = Set(try JID.fetchAll(db, sql: "SELECT jid FROM groupRoster WHERE conversationId = ?", arguments: [conversationId]))
            for jid in members where counted.insert(jid).inserted {
                try Self.rosterAdd(db, jid, conversationId: conversationId, writesLine: listed, at: date)
            }
        }
    }

    /// Whether the baseline began before `since`, when the fetch that is
    /// reporting started. One that began earlier belongs to a baseline that
    /// was cleared since, and says nothing of this one.
    private static func rosterBegan(_ db: Database, _ conversationId: Int64, before since: Date) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT begunAt <= ? FROM groupRosterTaken WHERE conversationId = ?", arguments: [since, conversationId]) ?? false
    }

    /// One fetch of every member list, begun at `since`, came whole, naming
    /// `members` together (each list has been through `rosterListed` already).
    /// The first such listing is the baseline: those it no longer names are
    /// dropped without a word. After that, whoever was counted and is no
    /// longer named has left. Whoever was counted after `since` is left
    /// alone, as the listing can't have known of them.
    func rosterListingDone(conversationId: Int64, room: JID, members: [JID], since: Date, at date: Date) throws {
        try writer.write { db in
            guard try Self.rosterBegan(db, conversationId, before: since), let listed = try Self.rosterListedState(db, conversationId) else { return }
            let named = Set(members)
            let counted = try JID.fetchAll(db, sql: "SELECT jid FROM groupRoster WHERE conversationId = ? AND countedAt < ?", arguments: [conversationId, since])
            for jid in counted.sorted() where !named.contains(jid) {
                try Self.rosterRemove(db, jid, conversationId: conversationId, writesLine: listed, at: date)
            }
            try db.execute(sql: "UPDATE groupRosterTaken SET listed = 1 WHERE conversationId = ?", arguments: [conversationId])
        }
    }

    /// The room refused to list its members, for good. Nobody can be judged
    /// absent, but without a listing the baseline would never end, and
    /// everyone added from then on would go unsaid: it ends here.
    func rosterListingRefused(conversationId: Int64, since: Date) throws {
        try writer.write { db in
            guard try Self.rosterBegan(db, conversationId, before: since) else { return }
            try db.execute(sql: "UPDATE groupRosterTaken SET listed = 1 WHERE conversationId = ?", arguments: [conversationId])
        }
    }

    /// The room made `jid` a member, or took their membership, wherever they
    /// are. Told by an affiliation notice, by a presence that carries or ends
    /// membership and by our own change alike, which only the first to arrive
    /// writes a line for. Before the baseline's listing has come, nobody is
    /// known to be new or gone, so it is counted quietly.
    func rosterAffiliated(conversationId: Int64, room: JID, jid: JID, isMember: Bool, at date: Date) throws {
        try writer.write { db in
            guard let listed = try Self.rosterListedState(db, conversationId) else { return }
            let isCounted = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM groupRoster WHERE conversationId = ? AND jid = ?)", arguments: [conversationId, jid]) ?? false
            if isMember {
                guard !isCounted else { return }
                // A notice names the new affiliation only, so before the first
                // listing has counted everyone a promotion of a long-standing
                // member looks like an addition.
                try Self.rosterAdd(db, jid, conversationId: conversationId, writesLine: listed, at: date)
            } else if isCounted {
                try Self.rosterRemove(db, jid, conversationId: conversationId, writesLine: listed, at: date)
            }
        }
    }

    /// Forgets a group's members, for a group we left or that ended: coming
    /// back is a first join.
    func forgetRoster(conversationId: Int64) throws {
        try writer.write { try Self.rosterClear($0, conversationId) }
    }

    /// The lines a group's chat holds for people joining and leaving, as a
    /// fixture would have them.
    public func addRosterLinesForFixture(room: JID, joined: [(nick: String, jid: JID)], left: [(nick: String, jid: JID)]) throws {
        guard let conversationId = try groupChat(room)?.conversationId else { return }
        let lines = joined.map { (MessageEvent.joinedGroup, $0, -10.0) } + left.map { (MessageEvent.leftGroup, $0, -5.0) }
        try writer.write { db in
            for (index, (event, who, base)) in lines.enumerated() {
                try Self.rosterLine(db, event, conversationId: conversationId, sender: who.jid, nick: who.nick, at: Date().addingTimeInterval(base + Double(index)))
            }
        }
    }
}
