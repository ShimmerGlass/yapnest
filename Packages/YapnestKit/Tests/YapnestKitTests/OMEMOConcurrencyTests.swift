import Foundation
import GRDB
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

/// A device with its own OMEMO state, driven the way the app drives it: a
/// send goes through MartinOMEMO's `encode` under one lock and a receive
/// through `OMEMOEncryption.decrypt`, which has its own.
final class OMEMOPeer: @unchecked Sendable {
    let account: YapnestKit.JID
    let omemo: OMEMOEncryption
    let database: AppDatabase
    let identityKeys: any IdentityKeyStore
    private let client = XMPPClient()

    /// A file-backed database when `url` is given, which is also how a device
    /// is reopened: the same file and identity keys again.
    init(_ account: String, url: URL? = nil, identityKeys: any IdentityKeyStore = MemoryIdentityKeyStore()) throws {
        self.account = YapnestKit.JID(account)!
        self.identityKeys = identityKeys
        database = try url.map { try AppDatabase.open(at: $0) } ?? AppDatabase.inMemory()
        omemo = try OMEMOEncryption(database: database, account: self.account, identityKeys: identityKeys)
        client.connectionConfiguration.userJid = BareJID(account)
        client.writer = FakeWire()
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(omemo.module)
    }

    var device: Int32 { Int32(bitPattern: omemo.deviceId) }
    var address: SignalAddress { SignalAddress(name: account.description, deviceId: device) }

    /// The `<encrypted>` element of `body` for `addresses`, or nil if encoding failed outright.
    func send(_ body: String?, to addresses: [SignalAddress]) -> Element? {
        let message = Martin.Message()
        message.body = body
        guard case .successMessage(let message, _) = omemo.encodeKeepingSessions(message, for: addresses) else { return nil }
        return message.firstChild(name: "encrypted", xmlns: NS.omemoLegacy).map { Element(element: $0) }
    }

    func send(_ body: String, to peer: OMEMOPeer) -> Element? { send(body, to: [peer.address]) }

    struct Received: Equatable {
        var outcome: String
        var body: String?
        var decrypted: Bool { outcome == "decrypted" }
    }

    func receive(_ encrypted: Element, from sender: OMEMOPeer) -> Received {
        let message = Martin.Message()
        message.type = .chat
        message.addChild(Element(element: encrypted))
        let result = omemo.decrypt(message, from: sender.account, ownCopy: false)
        switch result {
        case .decrypted: return Received(outcome: "decrypted", body: message.body)
        case .ignore: return Received(outcome: "ignore", body: nil)
        case .ownCopy: return Received(outcome: "ownCopy", body: nil)
        case .unvouched: return Received(outcome: "unvouched", body: nil)
        case .failed(let reason): return Received(outcome: "failed", body: reason)
        }
    }

    func hasKey(in encrypted: Element, for peer: OMEMOPeer) -> Bool {
        keys(in: encrypted).contains { $0.getAttribute("rid") == peer.device.omemoId }
    }

    func keys(in encrypted: Element) -> [Element] {
        encrypted.firstChild(name: "header")?.filterChildren(name: "key", xmlns: nil) ?? []
    }

    func sessionRecord(of peer: OMEMOPeer) -> Data? {
        try? database.reader.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM omemoSession WHERE name = ? AND deviceId = ?", arguments: [peer.account.description, peer.device])
        }
    }
}

/// Runs each job on a queue of its own and waits for all of them; false if
/// they didn't finish in time, as a deadlock would leave them.
private func finish(within seconds: TimeInterval = 90, _ jobs: [@Sendable () -> Void]) -> Bool {
    let group = DispatchGroup()
    for (index, job) in jobs.enumerated() {
        DispatchQueue(label: "omemo-concurrency-\(index)", qos: .userInitiated).async(group: group, execute: job)
    }
    return group.wait(timeout: .now() + seconds) == .success
}

/// A hand-over between two queues, in the order things were put in.
private final class Inbox<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [T] = []
    func push(_ item: T) {
        condition.lock()
        items.append(item)
        condition.signal()
        condition.unlock()
    }
    func pop(timeout: TimeInterval = 60) -> T? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while items.isEmpty {
            if !condition.wait(until: deadline) { return nil }
        }
        return items.removeFirst()
    }
}

private struct Outgoing: @unchecked Sendable {
    var element: Element
    var body: String
}

/// One side of a live exchange: a sender queue and a receiver queue that
/// also answers every few messages, so ratchet steps happen while the same
/// side is encrypting.
private final class LiveSide: @unchecked Sendable {
    let me: OMEMOPeer
    let other: OMEMOPeer
    let inbox = Inbox<Outgoing>()
    var peerInbox: Inbox<Outgoing>!
    let failures = Collected<String>()
    private let sendLock = NSLock()

    init(me: OMEMOPeer, other: OMEMOPeer) {
        self.me = me
        self.other = other
    }

    /// Encrypting and handing over are one step, so the other side reads in the order of encryption.
    func produce(_ body: String) {
        sendLock.withLock {
            guard let element = me.send(body, to: other) else { failures.add("no message \(body)"); return }
            peerInbox.push(Outgoing(element: element, body: body))
        }
    }

    func sendAll(_ count: Int) {
        for i in 0..<count { produce("\(me.account) main \(i)") }
    }

    func receiveAll(_ expected: Int, answerEvery: Int, answering mains: Int) {
        var mainsRead = 0
        for _ in 0..<expected {
            guard let item = inbox.pop() else { failures.add("inbox ran dry"); return }
            let result = me.receive(item.element, from: other)
            if result != .init(outcome: "decrypted", body: item.body) { failures.add("\(item.body): \(result)") }
            if item.body.contains(" main ") {
                mainsRead += 1
                if mainsRead % answerEvery == 0 { produce("\(me.account) reply \(mainsRead)") }
            }
        }
    }
}

private struct TempDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("omemo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// A and B with a session B started and A answered, so both sides are past the prekey stage.
private func establish(_ a: OMEMOPeer, _ b: OMEMOPeer, keyId: UInt32 = 4242) throws {
    try startSession(from: b.omemo, to: a.omemo, named: a.account.description, keyId: keyId)
    let first = try #require(b.send("hello", to: a))
    #expect(a.receive(first, from: b) == .init(outcome: "decrypted", body: "hello"))
    let answer = try #require(a.send("hello back", to: b))
    #expect(b.receive(answer, from: a) == .init(outcome: "decrypted", body: "hello back"))
}

@Suite(.serialized)
struct OMEMOConcurrencyTests {
    @Test func aLongPingPongKeepsTheRatchetInStep() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let b = try OMEMOPeer("b@example.org", url: directory.file("b.sqlite"))
        try establish(a, b)

        nonisolated(unsafe) var failures: [String] = []
        nonisolated(unsafe) var count = 0
        let finished = finish([{ [a, b] in
            // Alternating, then bursts of 10 one way, then the other.
            var plan: [Bool] = []
            for _ in 0..<40 { plan += [true, false] }
            for _ in 0..<3 {
                plan += Array(repeating: true, count: 10)
                plan += Array(repeating: false, count: 10)
            }
            plan += Array(repeating: true, count: 10) + [false, true, true, false, false, false]
            plan += Array(repeating: false, count: 200 - plan.count)
            for (index, aSends) in plan.enumerated() {
                let (from, to) = aSends ? (a, b) : (b, a)
                let body = "message \(index) from \(from.account)"
                guard let encrypted = from.send(body, to: to) else { failures.append("no encrypted element at \(index)"); return }
                let received = to.receive(encrypted, from: from)
                if received != .init(outcome: "decrypted", body: body) { failures.append("\(index): \(received)") }
                count += 1
            }
        }])
        #expect(finished, "the exchange didn't finish")
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(count == 200)
    }

    @Test func stateIsOnDiskWhenAMessageIsReturned() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let keys = MemoryIdentityKeyStore()
        var a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"), identityKeys: keys)
        let b = try OMEMOPeer("b@example.org")
        let device = a.device
        try startSession(from: b.omemo, to: a.omemo, named: a.account.description)

        func reopen() throws {
            a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"), identityKeys: keys)
            #expect(a.device == device)
        }

        // The first message creates A's session; A is reopened before it goes on.
        #expect(a.receive(try #require(b.send("first", to: a)), from: b) == .init(outcome: "decrypted", body: "first"))
        try reopen()
        #expect(a.sessionRecord(of: b) != nil)

        for round in 0..<8 {
            // The send's state must be on disk: B reads it, the reopened A sends on from it.
            let sent = "a\(round)"
            #expect(b.receive(try #require(a.send(sent, to: b)), from: a) == .init(outcome: "decrypted", body: sent))
            try reopen()
            // A burst with a reopening between every message.
            for burst in 0..<3 {
                let body = "a\(round).\(burst)"
                #expect(b.receive(try #require(a.send(body, to: b)), from: a) == .init(outcome: "decrypted", body: body), "round \(round) burst \(burst)")
                try reopen()
            }
            // The receive's state must be on disk too.
            let reply = "b\(round)"
            #expect(a.receive(try #require(b.send(reply, to: a)), from: b) == .init(outcome: "decrypted", body: reply))
            try reopen()
            let second = "b\(round).2"
            #expect(a.receive(try #require(b.send(second, to: a)), from: b) == .init(outcome: "decrypted", body: second))
            try reopen()
        }
    }

    @Test func sendingAndReceivingWithOnePeerBesideOtherWrites() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let b = try OMEMOPeer("b@example.org")
        try establish(a, b)

        let count = 200
        let incoming = try (0..<count).map { i in (i, try #require(b.send("from b \(i)", to: a))) }

        let sent = Collected<(Int, Element)>()
        let received = Collected<String>()
        let other = Collected<String>()
        let database = a.database
        let finished = finish([{ [a, b] in
            for i in 0..<count {
                if let encrypted = a.send("from a \(i)", to: b) { sent.add((i, encrypted)) }
            }
        }, { [a, b] in
            for (i, encrypted) in incoming {
                let result = a.receive(encrypted, from: b)
                if result != .init(outcome: "decrypted", body: "from b \(i)") { received.add("\(i): \(result)") }
            }
        }, {
            // What ingest does beside encryption.
            for i in 0..<400 {
                do {
                    try database.writer.write { db in
                        try db.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: ["test.\(i % 20)", "v\(i)"])
                    }
                    _ = try database.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM setting") }
                } catch {
                    other.add("\(error)")
                    return
                }
            }
        }])
        #expect(finished, "the three loops didn't finish")
        #expect(received.all.isEmpty, "\(received.all.prefix(5))")
        #expect(other.all.isEmpty, "\(other.all.prefix(3))")

        let all = sent.all.sorted { $0.0 < $1.0 }
        #expect(all.count == count)
        for (i, encrypted) in all {
            #expect(b.receive(encrypted, from: a) == .init(outcome: "decrypted", body: "from a \(i)"), "message \(i)")
        }

        // No update was lost: the session works on in both directions.
        for i in 0..<5 {
            #expect(b.receive(try #require(a.send("after a \(i)", to: b)), from: a) == .init(outcome: "decrypted", body: "after a \(i)"))
            #expect(a.receive(try #require(b.send("after b \(i)", to: a)), from: b) == .init(outcome: "decrypted", body: "after b \(i)"))
        }
    }

    @Test func aGroupMessageFansOutToManyDevicesBesideReceiving() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let devices = try (0..<20).flatMap { r in try (0..<2).map { _ in try OMEMOPeer("r\(r)@example.org") } }

        // The first device of five recipients writes to A first, and A answers
        // from the session that creates.
        let talkers = stride(from: 0, to: 10, by: 2).map { devices[$0] }
        for talker in talkers {
            try startSession(from: talker.omemo, to: a.omemo, named: a.account.description, keyId: UInt32(100 + talker.device & 0xFFFF))
            #expect(a.receive(try #require(talker.send("hi", to: a)), from: talker) == .init(outcome: "decrypted", body: "hi"))
        }
        for device in devices where !talkers.contains(where: { $0 === device }) {
            try startSession(from: a.omemo, to: device.omemo, named: device.account.description)
        }
        let perTalker = 10
        let incoming = try talkers.map { talker in try (0..<perTalker).map { (talker, $0, try #require(talker.send("t\($0)", to: a))) } }.flatMap { $0 }

        let sent = Collected<(Int, Element)>()
        let failures = Collected<String>()
        let messages = 50
        let addresses = devices.map(\.address)
        let finished = finish([{ [a] in
            for i in 0..<messages {
                if let encrypted = a.send("group \(i)", to: addresses) { sent.add((i, encrypted)) } else { failures.add("no message \(i)") }
            }
        }, { [a] in
            for (talker, i, encrypted) in incoming {
                let result = a.receive(encrypted, from: talker)
                if result != .init(outcome: "decrypted", body: "t\(i)") { failures.add("\(talker.account) \(i): \(result)") }
            }
        }])
        #expect(finished, "the fan-out didn't finish")
        #expect(failures.all.isEmpty, "\(failures.all.prefix(5))")

        let ordered = sent.all.sorted { $0.0 < $1.0 }
        #expect(ordered.count == messages)
        for device in devices {
            for (i, encrypted) in ordered {
                #expect(a.hasKey(in: encrypted, for: device), "no key for \(device.account) in \(i)")
                let result = device.receive(encrypted, from: a)
                #expect(result == .init(outcome: "decrypted", body: "group \(i)"), "\(device.account)/\(device.device) message \(i): \(result)")
                if !result.decrypted { break }
            }
        }
    }

    @Test func newSessionsStartWhileSending() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let existing = try (0..<5).map { try OMEMOPeer("p\($0)@example.org") }
        for peer in existing { try startSession(from: a.omemo, to: peer.omemo, named: peer.account.description) }
        let newcomers = try (0..<10).map { try OMEMOPeer("n\($0)@example.org") }
        for (i, newcomer) in newcomers.enumerated() {
            try startSession(from: newcomer.omemo, to: a.omemo, named: a.account.description, keyId: UInt32(1000 + i))
        }
        let firsts = try newcomers.map { try #require($0.send("first from \($0.account)", to: a)) }
        let seconds = try newcomers.map { try #require($0.send("second from \($0.account)", to: a)) }

        let sent = Collected<(Int, Element)>()
        let failures = Collected<String>()
        let finished = finish([{ [a] in
            for i in 0..<100 {
                if let encrypted = a.send("to existing \(i)", to: [existing[i % 5].address]) { sent.add((i, encrypted)) } else { failures.add("no message \(i)") }
            }
        }, { [a] in
            for (i, newcomer) in newcomers.enumerated() {
                let result = a.receive(firsts[i], from: newcomer)
                if result != .init(outcome: "decrypted", body: "first from \(newcomer.account)") { failures.add("\(newcomer.account): \(result)") }
            }
        }])
        #expect(finished, "didn't finish")
        #expect(failures.all.isEmpty, "\(failures.all.prefix(5))")
        for (i, encrypted) in sent.all.sorted(by: { $0.0 < $1.0 }) {
            let peer = existing[i % 5]
            #expect(peer.receive(encrypted, from: a) == .init(outcome: "decrypted", body: "to existing \(i)"))
        }

        // The identity is stored, the prekey used is gone, a second message
        // that still carries the prekey is read from the session the first
        // made, and a replay of the first is ignored as a duplicate.
        for i in 0..<newcomers.count {
            let stored = a.omemo.store.identities(forName: newcomers[i].account.description).map(\.address.deviceId)
            #expect(stored == [newcomers[i].device])
            #expect(!a.omemo.store.containsPreKey(withId: UInt32(1000 + i)), "prekey \(1000 + i) was kept")
            let second = a.receive(seconds[i], from: newcomers[i])
            #expect(second == .init(outcome: "decrypted", body: "second from \(newcomers[i].account)"))
            let replay = a.receive(firsts[i], from: newcomers[i])
            #expect(replay == .init(outcome: "ignore", body: nil), "replay of a first message: \(replay)")
        }

        // And the sessions work both ways.
        for newcomer in newcomers {
            let reply = try #require(a.send("welcome", to: newcomer))
            #expect(newcomer.receive(reply, from: a) == .init(outcome: "decrypted", body: "welcome"))
            #expect(a.receive(try #require(newcomer.send("thanks", to: a)), from: newcomer) == .init(outcome: "decrypted", body: "thanks"))
        }
    }

    @Test func theAppAndTheExtensionHandTheAccountOver() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let keys = MemoryIdentityKeyStore()
        let app = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"), identityKeys: keys)
        let extensionPeer = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"), identityKeys: keys)
        #expect(app.device == extensionPeer.device)
        let b = try OMEMOPeer("b@example.org")
        try startSession(from: b.omemo, to: app.omemo, named: app.account.description)

        let failures = Collected<String>()
        let finished = finish([{ [app, extensionPeer, b] in
            // Each takes its turn; the process lock keeps them from overlapping.
            let turns = [app, extensionPeer]
            for i in 0..<20 {
                let receiver = turns[i % 2]
                guard let encrypted = b.send("b\(i)", to: [app.address]) else { failures.add("no message \(i)"); return }
                let result = receiver.receive(encrypted, from: b)
                if result != .init(outcome: "decrypted", body: "b\(i)") { failures.add("receive \(i): \(result)") }
            }
            for i in 0..<20 {
                let sender = turns[i % 2]
                guard let encrypted = sender.send("a\(i)", to: b) else { failures.add("no send \(i)"); return }
                let result = b.receive(encrypted, from: sender)
                if result != .init(outcome: "decrypted", body: "a\(i)") { failures.add("send \(i): \(result)") }
                // B answers now and then, to whichever is next.
                if i % 3 == 0 {
                    let next = turns[(i + 1) % 2]
                    guard let reply = b.send("r\(i)", to: [app.address]) else { failures.add("no reply \(i)"); return }
                    let received = next.receive(reply, from: b)
                    if received != .init(outcome: "decrypted", body: "r\(i)") { failures.add("reply \(i): \(received)") }
                }
            }
        }])
        #expect(finished, "didn't finish")
        #expect(failures.all.isEmpty, "\(failures.all.prefix(5))")
    }

    @Test func aFailedSessionWriteFailsTheSendAndLeavesTheSessionUsable() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let b = try OMEMOPeer("b@example.org")
        try establish(a, b)
        let before = try #require(a.sessionRecord(of: b))

        func install() throws {
            try a.database.writer.write { db in
                try db.execute(sql: "CREATE TRIGGER failUpdate BEFORE UPDATE ON omemoSession BEGIN SELECT RAISE(ABORT, 'test'); END")
                try db.execute(sql: "CREATE TRIGGER failInsert BEFORE INSERT ON omemoSession BEGIN SELECT RAISE(ABORT, 'test'); END")
            }
        }
        func drop() throws {
            try a.database.writer.write { db in
                try db.execute(sql: "DROP TRIGGER failUpdate")
                try db.execute(sql: "DROP TRIGGER failInsert")
            }
        }

        // Send: the sessions are written once the message is encrypted, and
        // when that fails the message isn't returned, as its keys weren't kept.
        try install()
        #expect(a.send("lost", to: b) == nil, "a message came out though its session didn't store")
        #expect(a.sessionRecord(of: b) == before, "the session moved")
        try drop()

        let next = try #require(a.send("after", to: b))
        #expect(a.hasKey(in: next, for: b))
        #expect(b.receive(next, from: a) == .init(outcome: "decrypted", body: "after"))
        #expect(a.receive(try #require(b.send("reply", to: a)), from: b) == .init(outcome: "decrypted", body: "reply"))

        // Receive: the message is refused and the session doesn't advance.
        let lost = try #require(b.send("never stored", to: a))
        let beforeReceive = try #require(a.sessionRecord(of: b))
        try install()
        let refused = a.receive(lost, from: b)
        #expect(refused == .init(outcome: "failed", body: "unknown"), "\(refused)")
        #expect(a.sessionRecord(of: b) == beforeReceive, "the session moved")
        try drop()

        // The same message is read once the write works, and B's next ones after it.
        #expect(a.receive(lost, from: b) == .init(outcome: "decrypted", body: "never stored"))
        for i in 0..<3 {
            #expect(a.receive(try #require(b.send("b\(i)", to: a)), from: b) == .init(outcome: "decrypted", body: "b\(i)"))
            #expect(b.receive(try #require(a.send("a\(i)", to: b)), from: a) == .init(outcome: "decrypted", body: "a\(i)"))
        }
    }

    @Test func aDecryptThatFailsChangesNothing() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let b = try OMEMOPeer("b@example.org")
        try establish(a, b)

        func check(_ comment: Comment, line: UInt = #line) throws {
            let sent = try #require(b.send("ok \(line)", to: a))
            #expect(a.receive(sent, from: b) == .init(outcome: "decrypted", body: "ok \(line)"), comment)
            #expect(b.receive(try #require(a.send("ok back \(line)", to: b)), from: a) == .init(outcome: "decrypted", body: "ok back \(line)"), comment)
        }

        // A key that is no ciphertext at all.
        let garbage = try #require(b.send("garbage", to: a))
        let key = try #require(a.keys(in: garbage).first)
        key.value = Data((0..<80).map { UInt8(truncatingIfNeeded: $0 &* 7) }).base64EncodedString()
        let before = try #require(a.sessionRecord(of: b))
        let garbled = a.receive(garbage, from: b)
        #expect(garbled.outcome == "failed", "\(garbled)")
        #expect(a.sessionRecord(of: b) == before)
        try check("after garbage")

        // The same, claiming to be a prekey message.
        let claimed = try #require(b.send("claimed", to: a))
        let beforeClaimed = try #require(a.sessionRecord(of: b))
        let claimedKey = try #require(a.keys(in: claimed).first)
        claimedKey.value = Data((0..<80).map { UInt8(truncatingIfNeeded: $0 &* 3) }).base64EncodedString()
        claimedKey.setAttribute("prekey", value: "true")
        let claimedResult = a.receive(claimed, from: b)
        #expect(claimedResult.outcome == "failed", "\(claimedResult)")
        #expect(a.sessionRecord(of: b) == beforeClaimed)
        try check("after a false prekey")

        // A replay of a message already read is ignored as a duplicate.
        let once = try #require(b.send("once", to: a))
        #expect(a.receive(once, from: b) == .init(outcome: "decrypted", body: "once"))
        let afterOnce = try #require(a.sessionRecord(of: b))
        let replay = a.receive(once, from: b)
        #expect(replay == .init(outcome: "ignore", body: nil), "\(replay)")
        #expect(a.sessionRecord(of: b) == afterOnce, "a replay moved the session")
        try check("after a replay")

        // A message with no key for this device.
        let other = try OMEMOPeer("c@example.org")
        try startSession(from: b.omemo, to: other.omemo, named: other.account.description)
        let forOther = try #require(b.send("not for A", to: other))
        let beforeOthers = try #require(a.sessionRecord(of: b))
        let wrongDevice = a.receive(forOther, from: b)
        #expect(wrongDevice.outcome == "failed", "\(wrongDevice)")
        #expect(a.sessionRecord(of: b) == beforeOthers, "a message for another device moved the session")
        try check("after a message for someone else")
    }

    @Test func liveBothWaysAtOnce() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let b = try OMEMOPeer("b@example.org", url: directory.file("b.sqlite"))
        try establish(a, b)
        let sideA = LiveSide(me: a, other: b), sideB = LiveSide(me: b, other: a)
        sideA.peerInbox = sideB.inbox
        sideB.peerInbox = sideA.inbox

        let mains = 300, every = 4
        let arriving = mains + mains / every
        let finished = finish([
            { sideA.sendAll(mains) },
            { sideB.sendAll(mains) },
            { sideA.receiveAll(arriving, answerEvery: every, answering: mains) },
            { sideB.receiveAll(arriving, answerEvery: every, answering: mains) },
        ])
        #expect(finished, "the live exchange didn't finish")
        #expect(sideA.failures.all.isEmpty, "\(sideA.failures.all.prefix(5))")
        #expect(sideB.failures.all.isEmpty, "\(sideB.failures.all.prefix(5))")

        for i in 0..<5 {
            #expect(b.receive(try #require(a.send("after a \(i)", to: b)), from: a) == .init(outcome: "decrypted", body: "after a \(i)"))
            #expect(a.receive(try #require(b.send("after b \(i)", to: a)), from: b) == .init(outcome: "decrypted", body: "after b \(i)"))
        }
    }

    @Test func twoReceivesFromOneDeviceAtOnce() throws {
        let directory = try TempDirectory()
        defer { directory.remove() }
        let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
        let b = try OMEMOPeer("b@example.org")
        try establish(a, b)
        let incoming = try (0..<100).map { try #require(b.send("b \($0)", to: a)) }

        let results = Collected<(Int, OMEMOPeer.Received)>()
        let sent = Collected<(Int, Element)>()
        let finished = finish([
            { [a, b] in for i in stride(from: 0, to: 100, by: 2) { results.add((i, a.receive(incoming[i], from: b))) } },
            { [a, b] in for i in stride(from: 1, to: 100, by: 2) { results.add((i, a.receive(incoming[i], from: b))) } },
            { [a, b] in for i in 0..<50 { if let e = a.send("a \(i)", to: b) { sent.add((i, e)) } } },
        ])
        #expect(finished, "didn't finish")

        // Out of order within the chain is fine for Signal: skipped keys are kept, so every message reads once.
        let all = results.all.sorted { $0.0 < $1.0 }
        #expect(all.count == 100)
        for (i, result) in all {
            #expect(result == .init(outcome: "decrypted", body: "b \(i)"), "message \(i)")
        }
        for (i, encrypted) in sent.all.sorted(by: { $0.0 < $1.0 }) {
            #expect(b.receive(encrypted, from: a) == .init(outcome: "decrypted", body: "a \(i)"))
        }
        for i in 0..<5 {
            #expect(b.receive(try #require(a.send("after a \(i)", to: b)), from: a) == .init(outcome: "decrypted", body: "after a \(i)"))
            #expect(a.receive(try #require(b.send("after b \(i)", to: a)), from: b) == .init(outcome: "decrypted", body: "after b \(i)"))
        }
    }

    /// Marking a device compromised deletes its session (see `XMPPSession.setTrust`).
    /// A send under way holds that session in memory until the message is
    /// encrypted; written back after the delete, it would bring it back.
    @Test func aSessionDeletedDuringSendsStaysDeleted() throws {
        for round in 0..<20 {
            let directory = try TempDirectory()
            defer { directory.remove() }
            let a = try OMEMOPeer("a@example.org", url: directory.file("a.sqlite"))
            let b = try OMEMOPeer("b@example.org")
            let c = try OMEMOPeer("c@example.org")
            try establish(a, b)
            try establish(a, c, keyId: 4343)
            let sent = Collected<(Int, Element)>()
            let deleteAfter = round * 3
            let finished = finish([
                { [a, b, c] in for i in 0..<80 { if let e = a.send("a \(i)", to: [b.address, c.address]) { sent.add((i, e)) } } },
                { [a, b] in
                    while sent.all.count < deleteAfter { usleep(100) }
                    _ = a.omemo.store.deleteSessionRecord(forAddress: b.address)
                },
            ])
            #expect(finished, "didn't finish")
            #expect(a.sessionRecord(of: b) == nil, "round \(round): the deleted session came back")
            for (i, encrypted) in sent.all.sorted(by: { $0.0 < $1.0 }) {
                #expect(c.receive(encrypted, from: a) == .init(outcome: "decrypted", body: "a \(i)"), "round \(round), message \(i)")
            }
        }
    }
}
