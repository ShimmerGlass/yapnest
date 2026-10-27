import Foundation
import GRDB

/// A device that appeared on our own account after we first saw its device
/// list. Under blind trust it was trusted at once and gets a copy of every
/// message, so the user is told. (A contact's becomes a `MessageEvent`.)
public struct DeviceNotice: Sendable, Equatable, Identifiable {
    public let jid: JID
    public let deviceId: Int32
    /// Hex of the device's key, as `OMEMODevice.fingerprint`.
    public let fingerprint: String
    public let firstSeen: Date

    public var id: String { "\(jid):\(deviceId)" }

    /// The fingerprint in groups of eight, the way the devices list shows it.
    public var groupedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 8).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: 8, limitedBy: fingerprint.endIndex) ?? fingerprint.endIndex
            return String(fingerprint[start..<end])
        }.joined(separator: " ")
    }
}

extension AppDatabase {
    /// Remembers which devices a bare JID's first device list held, so that
    /// later ones can be told from them. Only the first list counts: a
    /// device already announced when we first looked isn't new to us, and the
    /// lists we get after that name only what changed since. The session
    /// calls this for every list it hears; the notification and share
    /// extensions never hear one, so they only record against what the app
    /// has already seen.
    func noteDeviceList(of name: String, ids: [Int32]) throws {
        try writer.write { db in
            guard try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM deviceListSeen WHERE name = ?)", arguments: [name])! else { return }
            try db.execute(sql: "INSERT INTO deviceListSeen (name) VALUES (?)", arguments: [name])
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO baselineDevice (name, deviceId) VALUES (?, ?)", arguments: [name, id])
            }
        }
    }

    /// Records, in the transaction that stores a device's identity for the
    /// first time, that the user should be told of it. Our own account's
    /// devices need only a baseline and raise a notice for the chat list's
    /// warning; a contact's also need an earlier device of theirs, so that
    /// the first devices we meet of someone are not news, and become a line
    /// in their chat. No chat is made for it: a contact we have never talked
    /// to has none, and the first message will not need the line.
    static func noteNewDevice(_ db: Database, name: String, deviceId: Int32, fingerprint: String, isOwn: Bool, hadDevices: Bool, at date: Date) throws {
        guard isOwn || hadDevices else { return }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM deviceListSeen WHERE name = ?)", arguments: [name]) == true else { return }
        let inBaseline = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM baselineDevice WHERE name = ? AND deviceId = ?)", arguments: [name, deviceId]) ?? false
        guard !inBaseline else { return }
        if isOwn {
            try db.execute(
                sql: "INSERT OR IGNORE INTO deviceNotice (name, deviceId, fingerprint, firstSeen) VALUES (?, ?, ?, ?)",
                arguments: [name, deviceId, fingerprint, date],
            )
        } else if let peer = JID(name), let conversation = try Conversation.filter(Column("peer") == peer && Column("kind") == Conversation.Kind.chat.rawValue).fetchOne(db), let conversationId = conversation.id {
            var event = Message(conversationId: conversationId, direction: .incoming, sender: peer, body: "", timestamp: date, status: .received, isRead: true)
            event.event = .newDevice(deviceId: deviceId, fingerprint: fingerprint)
            try event.insert(db)
        }
    }

    /// The notices for `jid` the user hasn't dismissed, oldest first.
    public func observeDeviceNotices(of jid: JID) -> ValueObservation<ValueReducers.Fetch<[DeviceNotice]>> {
        ValueObservation.tracking { db in try Self.deviceNotices(db, of: jid) }
    }

    public func deviceNotices(of jid: JID) throws -> [DeviceNotice] {
        try reader.read { try Self.deviceNotices($0, of: jid) }
    }

    private static func deviceNotices(_ db: Database, of jid: JID) throws -> [DeviceNotice] {
        try Row.fetchAll(db, sql: "SELECT deviceId, fingerprint, firstSeen FROM deviceNotice WHERE name = ? AND NOT isDismissed ORDER BY firstSeen, deviceId", arguments: [jid.description])
            .map { DeviceNotice(jid: jid, deviceId: $0["deviceId"], fingerprint: $0["fingerprint"], firstSeen: $0["firstSeen"]) }
    }

    /// Hides the notice for good, though the row stays so that the device
    /// isn't announced again. Trust is not touched.
    public func dismissDeviceNotice(of jid: JID, deviceId: Int32) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE deviceNotice SET isDismissed = 1 WHERE name = ? AND deviceId = ?", arguments: [jid.description, deviceId])
        }
    }
}

extension AppDatabase {
    /// A device of our `jid` that appeared after its list was first seen, as
    /// a development fixture's account would hold one.
    public func addDeviceNoticeForFixture(of jid: JID, id: Int32, keyByte: UInt8) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO deviceNotice (name, deviceId, fingerprint, firstSeen) VALUES (?, ?, ?, ?)",
                arguments: [jid.description, id, Data(repeating: keyByte, count: 32).map { String(format: "%02x", $0) }.joined(), Date()],
            )
        }
    }
}
