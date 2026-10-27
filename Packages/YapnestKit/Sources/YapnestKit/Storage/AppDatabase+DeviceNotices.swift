import Foundation
import GRDB

/// A device that appeared on our own account after we first saw its device
/// list. Under blind trust it was trusted at once and gets a copy of every
/// message, so the user is told. (A contact's becomes a `MessageEvent`.)
struct DeviceNotice: Equatable {
    let deviceId: Int32
    /// Hex of the device's key, as `OMEMODevice.fingerprint`.
    let fingerprint: String
    let firstSeen: Date
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
        let seen = try reader.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM deviceListSeen WHERE name = ?)", arguments: [name]) } ?? false
        guard !seen else { return }
        try writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO deviceListSeen (name) VALUES (?)", arguments: [name])
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO baselineDevice (name, deviceId) VALUES (?, ?)", arguments: [name, id])
            }
        }
    }

    /// Records, in the transaction that stores a device's identity for the
    /// first time, that the user should be told of it. A device is news if
    /// the JID's first device list was already seen and did not hold it. Ours
    /// raises a notice for the chat list's warning; a contact's also needs an
    /// earlier device of theirs, so that the first devices we meet of someone
    /// are not news, and becomes a line in their chat. No chat is made for
    /// it: a contact we have never talked to has none.
    static func noteNewDevice(_ db: Database, name: String, deviceId: Int32, fingerprint: String, isOwn: Bool, hadDevices: Bool, at date: Date) throws {
        guard isOwn || hadDevices else { return }
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM deviceListSeen WHERE name = ?)", arguments: [name]) == true else { return }
        let inBaseline = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM baselineDevice WHERE name = ? AND deviceId = ?)", arguments: [name, deviceId]) ?? false
        guard !inBaseline else { return }
        if isOwn {
            try db.execute(
                sql: "INSERT OR IGNORE INTO deviceNotice (deviceId, fingerprint, firstSeen) VALUES (?, ?, ?)",
                arguments: [deviceId, fingerprint, date],
            )
        } else if let peer = JID(name), let conversation = try Conversation.filter(Column("peer") == peer && Column("kind") == Conversation.Kind.chat.rawValue).fetchOne(db), let conversationId = conversation.id {
            var event = newDeviceEvent(conversationId: conversationId, peer: peer, deviceId: deviceId, fingerprint: fingerprint, at: date)
            try event.insert(db)
        }
    }

    private static func newDeviceEvent(conversationId: Int64, peer: JID, deviceId: Int32, fingerprint: String, at date: Date) -> Message {
        var event = Message(conversationId: conversationId, direction: .event, sender: peer, body: "", timestamp: date, status: .received, isRead: true)
        event.event = .newDevice(deviceId: deviceId, fingerprint: fingerprint)
        return event
    }

    /// Our devices announced since their list was first seen, not yet dismissed, oldest first.
    func observeDeviceNotices() -> ValueObservation<ValueReducers.Fetch<[DeviceNotice]>> {
        ValueObservation.tracking { db in try Self.deviceNotices(db) }
    }

    func deviceNotices() throws -> [DeviceNotice] {
        try reader.read { try Self.deviceNotices($0) }
    }

    private static func deviceNotices(_ db: Database) throws -> [DeviceNotice] {
        try Row.fetchAll(db, sql: "SELECT deviceId, fingerprint, firstSeen FROM deviceNotice WHERE NOT isDismissed ORDER BY firstSeen, deviceId")
            .map { DeviceNotice(deviceId: $0["deviceId"], fingerprint: $0["fingerprint"], firstSeen: $0["firstSeen"]) }
    }

    /// Hides the notice for good, though the row stays so that the device
    /// isn't announced again. Trust is not touched.
    func dismissDeviceNotice(deviceId: Int32) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE deviceNotice SET isDismissed = 1 WHERE deviceId = ?", arguments: [deviceId])
        }
    }
}

extension AppDatabase {
    /// A device of our account that appeared after its list was first seen,
    /// as a development fixture's account would hold one.
    public func addDeviceNoticeForFixture(id: Int32, keyByte: UInt8) throws {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO deviceNotice (deviceId, fingerprint, firstSeen) VALUES (?, ?, ?)",
                arguments: [id, OMEMOStore.fingerprint(of: Data([0x05] + Array(repeating: keyByte, count: 32))), Date()],
            )
        }
    }

    /// The line a contact's new device leaves in their chat.
    public func addDeviceEventForFixture(peer: JID, id: Int32, keyByte: UInt8) throws {
        let conversation = try conversation(with: peer)
        var event = Self.newDeviceEvent(
            conversationId: conversation.id!, peer: peer, deviceId: id,
            fingerprint: OMEMOStore.fingerprint(of: Data([0x05] + Array(repeating: keyByte, count: 32))), at: Date(),
        )
        try writer.write { try event.insert($0) }
    }
}
