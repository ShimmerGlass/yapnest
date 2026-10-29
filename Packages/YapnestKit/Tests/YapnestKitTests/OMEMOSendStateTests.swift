import Foundation
import GRDB
@preconcurrency import MartinOMEMO
import Testing
@testable import YapnestKit

struct OMEMOSendStateTests {
    let me = JID("me@example.org")!
    let bob = "bob@example.org"
    let carol = "carol@example.org"

    private func key(_ byte: UInt8) -> Data { Data([0x05] + Array(repeating: byte, count: 32)) }

    private func add(_ ids: [Int32], of name: String, sessions: Set<Int32>, to store: OMEMOStore) {
        for id in ids {
            let address = SignalAddress(name: name, deviceId: id)
            #expect(store.save(identity: address, publicKeyData: key(UInt8(id))))
            if sessions.contains(id) { #expect(store.storeSessionRecord(Data([UInt8(id)]), forAddress: address)) }
        }
    }

    @Test func theStateOfSeveralNamesIsWhatTheSeparateReadsGive() throws {
        let clock = TestClock()
        let store = OMEMOStore(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore(), now: { clock.now })
        add([1, 2, 3], of: bob, sessions: [1, 3], to: store)
        add([7], of: carol, sessions: [], to: store)
        #expect(store.storeSessionRecord(Data([9]), forAddress: SignalAddress(name: bob, deviceId: 9)), "a session with no identity")
        clock.advance(days: 1)
        store.noteUsed(name: bob, deviceId: 1, at: clock.now)

        let states = store.sendState(forNames: [bob, carol, "nobody@example.org"])
        for name in [bob, carol] {
            let state = try #require(states[name])
            #expect(state.statuses == Dictionary(uniqueKeysWithValues: store.identities(forName: name).map { ($0.address.deviceId, $0.status) }))
            #expect(state.usage == store.usage(forName: name))
        }
        #expect(states[bob]?.sessions == [1, 3, 9])
        #expect(states[carol]?.sessions == [])
        #expect(states["nobody@example.org"] == nil)
        #expect(store.sendState(forNames: []).isEmpty)
    }

    @Test func aStatusThatStaysAsItIsTakesNoWriteTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = Collected<String>()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            let readonly = db.configuration.readonly
            db.trace { event in
                if case .statement(let statement) = event, !readonly { writes.add(statement.sql) }
            }
        }
        let pool = try DatabasePool(path: directory.appendingPathComponent("db.sqlite").path, configuration: configuration)
        let store = OMEMOStore(database: try AppDatabase(pool), account: me, identityKeys: MemoryIdentityKeyStore())
        let address = SignalAddress(name: bob, deviceId: 1)
        #expect(store.save(identity: address, publicKeyData: key(1)))

        writes.removeAll()
        #expect(store.setStatus(active: true, forIdentity: address), "already active")
        #expect(writes.all.filter { $0.contains("omemoIdentity") }.isEmpty)

        #expect(store.setStatus(active: false, forIdentity: address))
        #expect(store.identities(forName: bob).first?.status == .trustedInactive)
        #expect(writes.all.contains { $0.contains("UPDATE omemoIdentity") })
        #expect(store.setStatus(active: true, forIdentity: address))
        #expect(store.identities(forName: bob).first?.status == .trustedActive)
        #expect(store.setStatus(active: true, forIdentity: SignalAddress(name: bob, deviceId: 5)), "no such device")
    }
}
