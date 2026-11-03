import Foundation
import GRDB
import SQLite3
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// A read of the key store that fails (a full disk, a locked file) is not the
/// same as one that finds nothing. Taken for nothing, a working session is
/// rebuilt over, which uses up one of the device's prekeys; a device list is
/// reconciled against devices that seem gone; a prekey message fails as if its
/// key were invalid. The failure is forced by renaming the table away.
struct OMEMOReadFailureTests {
    let me = YapnestKit.JID("me@example.org")!
    let alice = YapnestKit.JID("alice@example.org")!
    let bob = "bob@example.org"

    private func key(_ byte: UInt8) -> Data { Data([0x05] + Array(repeating: byte, count: 32)) }

    /// Runs `body` with `table` unreadable.
    private func without<T>(_ table: String, in database: AppDatabase, _ body: () async throws -> T) async throws -> T {
        try await database.writer.write { try $0.execute(sql: "ALTER TABLE \(table) RENAME TO \(table)Aside") }
        do {
            let value = try await body()
            try await database.writer.write { try $0.execute(sql: "ALTER TABLE \(table)Aside RENAME TO \(table)") }
            return value
        } catch {
            try await database.writer.write { try $0.execute(sql: "ALTER TABLE \(table)Aside RENAME TO \(table)") }
            throw error
        }
    }

    /// Runs `body` with reads of `column` failing for the rows where `condition` holds, while every
    /// write still goes through to the table. Reads that don't touch the column, or those rows, work.
    private func failingReads<T>(of column: String, in table: String, where condition: String, database: AppDatabase, _ body: () async throws -> T) async throws -> T {
        try await database.writer.write { db in
            try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(table)Aside")
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table)Aside)").map { $0["name"] as String }
            let selected = columns.map { $0 == column ? "CASE WHEN \(condition) THEN abs(-9223372036854775807 - 1) ELSE \($0) END AS \($0)" : $0 }
            try db.execute(sql: "CREATE VIEW \(table) AS SELECT \(selected.joined(separator: ", ")) FROM \(table)Aside")
            let list = columns.joined(separator: ", "), new = columns.map { "NEW.\($0)" }.joined(separator: ", ")
            let key = "name = OLD.name AND deviceId = OLD.deviceId"
            try db.execute(sql: "CREATE TRIGGER \(table)Insert INSTEAD OF INSERT ON \(table) BEGIN INSERT OR REPLACE INTO \(table)Aside (\(list)) VALUES (\(new)); END")
            try db.execute(sql: "CREATE TRIGGER \(table)Update INSTEAD OF UPDATE ON \(table) BEGIN UPDATE \(table)Aside SET \(columns.map { "\($0) = NEW.\($0)" }.joined(separator: ", ")) WHERE \(key); END")
            try db.execute(sql: "CREATE TRIGGER \(table)Delete INSTEAD OF DELETE ON \(table) BEGIN DELETE FROM \(table)Aside WHERE \(key); END")
        }
        func restore() async throws {
            try await database.writer.write { db in
                try db.execute(sql: "DROP VIEW \(table)")
                try db.execute(sql: "ALTER TABLE \(table)Aside RENAME TO \(table)")
            }
        }
        do {
            let value = try await body()
            try await restore()
            return value
        } catch {
            try await restore()
            throw error
        }
    }

    /// Runs `body` with the database refusing to read `omemoSession.data`, which makes the read throw
    /// and leaves writes alone. A view can't do that: the app upserts into the table.
    private func refusingReadsOfSessionData<T>(in database: AppDatabase, _ body: () async throws -> T) async throws -> T {
        func set(_ refuse: Bool) async throws {
            try await database.writer.write { db in
                guard let connection = db.sqliteConnection else { return }
                if refuse {
                    sqlite3_set_authorizer(connection, { _, action, table, column, _, _ in
                        action == SQLITE_READ && table.map(String.init(cString:)) == "omemoSession" && column.map(String.init(cString:)) == "data" ? SQLITE_DENY : SQLITE_OK
                    }, nil)
                } else {
                    sqlite3_set_authorizer(connection, nil, nil)
                }
                // Statements prepared before are kept, and were authorized then.
                db.releaseMemory()
            }
        }
        try await set(true)
        do {
            let value = try await body()
            try await set(false)
            return value
        } catch {
            try await set(false)
            throw error
        }
    }

    private func count(_ table: String, in database: AppDatabase) throws -> Int {
        try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    // MARK: The store

    @Test func eachReadThrowsWhenTheDatabaseCantBeRead() async throws {
        let database = try AppDatabase.inMemory()
        let store = OMEMOStore(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let address = SignalAddress(name: bob, deviceId: 1)
        #expect(store.save(identity: address, publicKeyData: key(1)))
        #expect(store.storeSessionRecord(Data([1]), forAddress: address))
        #expect(store.storePreKey(Data([2]), withId: 1))

        try await without("omemoSession", in: database) {
            #expect(throws: (any Error).self) { try store.sessionRecord(forAddress: address) }
            #expect(throws: (any Error).self) { try store.containsSessionRecord(forAddress: address) }
            #expect(throws: (any Error).self) { try store.allDevices(for: bob, activeAndTrusted: false) }
            #expect(throws: (any Error).self) { try store.allDevices(for: bob, activeAndTrusted: true) }
            #expect(throws: (any Error).self) { try store.ownDevicesToEncryptTo() }
        }
        try await without("omemoPreKey", in: database) {
            #expect(throws: (any Error).self) { try store.loadPreKey(withId: 1) }
        }
        #expect(try store.sessionRecord(forAddress: address) == Data([1]))
        #expect(try store.loadPreKey(withId: 1) == Data([2]))
    }

    @Test func eachReadReturnsNoneWhenThereIsNothingStored() throws {
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let address = SignalAddress(name: bob, deviceId: 1)
        #expect(try store.sessionRecord(forAddress: address) == nil)
        #expect(try !store.containsSessionRecord(forAddress: address))
        #expect(try store.allDevices(for: bob, activeAndTrusted: true).isEmpty)
        #expect(try store.allDevices(for: bob, activeAndTrusted: false).isEmpty)
        #expect(try store.loadPreKey(withId: 1) == nil)
    }

    // MARK: Decrypting

    /// A and B past the prekey stage.
    private func established(keyId: UInt32) throws -> (a: OMEMOPeer, b: OMEMOPeer) {
        let a = try OMEMOPeer("a@example.org"), b = try OMEMOPeer("b@example.org")
        try startSession(from: b.omemo, to: a.omemo, named: a.account.description, keyId: keyId)
        #expect(a.receive(try #require(b.send("hello", to: a)), from: b) == .init(outcome: "decrypted", body: "hello"))
        #expect(b.receive(try #require(a.send("hello back", to: b)), from: a) == .init(outcome: "decrypted", body: "hello back"))
        return (a, b)
    }

    private func sessionRecord(_ a: OMEMOPeer, with b: OMEMOPeer) throws -> Data? {
        try a.omemo.store.sessionRecord(forAddress: b.address)
    }

    @Test func aMessageWhileTheSessionCantBeReadFailsAndRepairsNothing() async throws {
        let (a, b) = try established(keyId: 5101)
        let before = try #require(try sessionRecord(a, with: b))
        let message = try #require(b.send("while unreadable", to: a))
        let writes = a.wire.written.count

        let received = try await without("omemoSession", in: a.database) { a.receive(message, from: b) }
        #expect(received.outcome == "failed")
        #expect(received.body == "storageFailed")
        // A repair starts with the fetch of the device's bundle.
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.wire.written.count == writes, "a repair was started")
        #expect(try sessionRecord(a, with: b) == before)
        #expect(a.receive(message, from: b) == .init(outcome: "decrypted", body: "while unreadable"), "the ratchet wasn't touched")
    }

    @Test func aPreKeyMessageWhileTheSessionCantBeReadDoesntReplaceTheSession() async throws {
        let (a, b) = try established(keyId: 5201)
        let before = try #require(try sessionRecord(a, with: b))
        // B starts over from a new bundle of A's, as after losing its session.
        try startSession(from: b.omemo, to: a.omemo, named: a.account.description, keyId: 5202)
        let message = try #require(b.send("fresh", to: a))
        let preKeys = try count("omemoPreKey", in: a.database)

        // Reading the session's data is refused while writes still work, so a session built from
        // nothing would be stored over the working one.
        let received = try await refusingReadsOfSessionData(in: a.database) { a.receive(message, from: b) }
        #expect(received.outcome == "failed")
        #expect(received.body == "storageFailed")
        #expect(try sessionRecord(a, with: b) == before, "the session was replaced")
        #expect(try count("omemoPreKey", in: a.database) == preKeys)
        #expect(!a.omemo.store.isPreKeyDeleted(withId: 5202), "the prekey was used up")
        #expect(a.receive(message, from: b) == .init(outcome: "decrypted", body: "fresh"))
    }

    @Test func aPreKeyMessageWhileThePreKeyCantBeReadFailsAsStorageNotAsAnInvalidKey() async throws {
        let a = try OMEMOPeer("a@example.org"), b = try OMEMOPeer("b@example.org")
        try startSession(from: b.omemo, to: a.omemo, named: a.account.description, keyId: 5301)
        let message = try #require(b.send("first", to: a))

        let received = try await without("omemoPreKey", in: a.database) { a.receive(message, from: b) }
        #expect(received.outcome == "failed")
        #expect(received.body == "storageFailed", "taken for an invalid key id")
        #expect(try a.omemo.store.loadPreKey(withId: 5301) != nil, "the prekey is gone")
        #expect(a.receive(message, from: b) == .init(outcome: "decrypted", body: "first"))
    }

    // MARK: Device lists

    private func listFixture() throws -> (encryption: OMEMOEncryption, client: XMPPClient, wire: FakeWire, database: AppDatabase) {
        let wire = FakeWire()
        wire.answer { [alice] iq in
            iq.to?.bareJid.stringValue == alice.description
                && iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE
                ? OMEMODeviceListTests.list([4, 9], to: iq) : FakeWire.error(to: iq)
        }
        let database = try AppDatabase.inMemory()
        let encryption = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = wire
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        // Device 1 is in use but not listed; device 4 is listed but was set inactive.
        for (id, active) in [(Int32(1), true), (4, false)] {
            let address = SignalAddress(name: alice.description, deviceId: id)
            #expect(encryption.store.save(identity: address, publicKeyData: key(UInt8(id))))
            #expect(encryption.store.storeSessionRecord(Data([UInt8(id)]), forAddress: address))
            #expect(encryption.store.setStatus(active: active, forIdentity: address))
        }
        return (encryption, client, wire, database)
    }

    private func isActive(_ id: Int32, in encryption: OMEMOEncryption) -> Bool? {
        encryption.store.status(forName: alice.description, deviceId: id)?.isActive
    }

    private func bundleFetches(_ wire: FakeWire) -> [String] {
        wire.written.compactMap { $0 as? Iq }
            .compactMap { $0.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") }
            .filter { $0.contains(".bundles:") }
    }

    @Test func aListFetchedWhileTheStoredDevicesCantBeReadChangesNoDeviceAndBuildsNoSession() async throws {
        let (encryption, client, wire, database) = try listFixture()
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module, jid = BareJID(alice.description)

        let found = try await without("omemoSession", in: database) {
            await withCheckedContinuation { (continuation: CheckedContinuation<[Int32], Never>) in
                module.addresses(for: [jid]) { continuation.resume(returning: ((try? $0.get()) ?? []).map(\.deviceId).sorted()) }
            }
        }
        #expect(found == [4, 9])
        #expect(isActive(1, in: encryption) == true, "marked inactive on a list it wasn't compared with")
        #expect(isActive(4, in: encryption) == false, "marked active on a list it wasn't compared with")
        #expect(bundleFetches(wire).isEmpty, "a session was built over one that may exist: \(bundleFetches(wire))")
    }

    @Test func aListNotifiedWhileTheStoredDevicesCantBeReadChangesNoDeviceAndTheNextOneDoes() async throws {
        let (encryption, client, _, database) = try listFixture()
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module, jid = BareJID(alice.description)
        func notify() async {
            let element = Element(name: "list", xmlns: OMEMOModule.XMLNS)
            for id in [4, 9] { element.addChild(Element(name: "device", attributes: ["id": String(id)])) }
            let message = Martin.Message()
            message.from = Martin.JID(alice.description)
            module.onItemNotification(notification: .init(
                message: message, node: OMEMOModule.DEVICES_LIST_NODE, timestamp: Date(),
                action: .published(.init(id: "current", payload: element))))
            await eventually("the notified list to be kept") { module.devices(for: jid) == [4, 9] }
        }

        try await without("omemoSession", in: database) { await notify() }
        #expect(isActive(1, in: encryption) == true)
        #expect(isActive(4, in: encryption) == false)

        await notify()
        #expect(isActive(1, in: encryption) == false, "a list with the devices readable reconciles them")
        #expect(isActive(4, in: encryption) == true)
    }

    @Test func aContactWhoseDevicesCantBeReadStaysAvailable() async throws {
        let (encryption, client, _, database) = try listFixture()
        defer { withExtendedLifetime(client) {} }
        let module = encryption.module
        let known = BareJID(alice.description), stranger = BareJID("carol@example.org")
        #expect(module.isAvailable(for: known))
        #expect(!module.isAvailable(for: stranger))

        try await without("omemoSession", in: database) {
            // Falling back to a message in the clear because of a failed read would be worse than a send that fails.
            #expect(module.isAvailable(for: known))
            #expect(module.isAvailable(for: stranger))
        }
    }

    // MARK: Encrypting

    private func sendOffMain(_ send: @escaping @Sendable () -> Result<(Martin.Message, OMEMODevice.Trust), OMEMOEncryption.EncryptError>) async -> Result<(Martin.Message, OMEMODevice.Trust), OMEMOEncryption.EncryptError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: send()) }
        }
    }

    @Test func encryptingWhileOnlyOurOwnDevicesCantBeReadFailsInsteadOfLeavingThemOut() async throws {
        let (a, b) = try established(keyId: 5501)
        // The recipient's list is answered, so the send has everything but our other device's status.
        let device = b.device
        a.wire.answer { iq in
            iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE
                ? OMEMODeviceListTests.list([device], to: iq) : FakeWire.error(to: iq)
        }
        let other = SignalAddress(name: a.account.description, deviceId: 77)
        #expect(a.omemo.store.save(identity: other, publicKeyData: key(7)))
        #expect(a.omemo.store.storeSessionRecord(Data([7]), forAddress: other))
        @Sendable func send() -> Result<(Martin.Message, OMEMODevice.Trust), OMEMOEncryption.EncryptError> {
            let message = Martin.Message()
            message.type = .chat
            message.body = "for everyone"
            return a.omemo.encrypt(message, for: [b.account])
        }
        // Reading the recipient's devices works; the status of our own can't be read.
        let failed = try await failingReads(of: "status", in: "omemoIdentity", where: "name = '\(a.account.description)'", database: a.database) {
            await sendOffMain(send)
        }
        guard case .failure(.setupFailed(let who)) = failed else {
            Issue.record("sent without our other devices, or failed otherwise: \(failed)")
            return
        }
        #expect(who == a.account)
        guard case .success = await sendOffMain(send) else {
            Issue.record("a send with the devices readable should work")
            return
        }
    }

    @Test func encryptingWhileOurOwnDevicesCantBeReadFailsInsteadOfLeavingThemOut() async throws {
        let (a, b) = try established(keyId: 5401)
        let message = Martin.Message()
        message.body = "for everyone"
        func encode() -> EncryptionResult<Martin.Message, SignalError> {
            nonisolated(unsafe) var result: EncryptionResult<Martin.Message, SignalError> = .failure(.unknown)
            a.omemo.module.encode(message: message, forAddresses: [b.address], withStoreHint: false, forSelf: true) { result = $0 }
            return result
        }

        let failed = try await without("omemoSession", in: a.database) { encode() }
        guard case .failure(let error) = failed else {
            Issue.record("sent without our other devices: \(failed)")
            return
        }
        #expect(error == .storageFailed)
        guard case .successMessage = encode() else {
            Issue.record("a send with the devices readable should work")
            return
        }
    }
}
