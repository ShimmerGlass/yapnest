import Foundation
import GRDB
import Synchronization
import Testing
@testable import YapnestKit

extension LiveServer {
    /// How long a message takes to show as sent. The server's acknowledgement
    /// should arrive within a round trip on a local network; a user once saw
    /// it take seconds. Enable with
    /// `YAPNEST_INTEGRATION=1 swift test --filter SendLatency`.
    @Suite
    struct SendLatencyIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// Generous for a loopback server, but far under what users noticed.
        static let limit: TimeInterval = 1

        /// Which port to reach the server on: a file can name another, to go
        /// through a proxy that adds network delay.
        static let port = (try? String(contentsOf: FileManager.default.temporaryDirectory.appending(path: "yapnest-integration/port"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? LiveServer.target.port

        private func session(_ jid: JID, device: String) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: device, database: try OMEMOIntegrationTests.device(device), attachments: AttachmentStore(directory: LiveServer.stateDirectory.appending(path: "\(device)-attachments")), port: Self.port)
        }

        private func connect(_ sessions: XMPPSession...) async throws {
            for session in sessions {
                session.connect()
                while session.state.value != .connected(isSyncing: false) || !session.isEncryptionReady {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }

        /// Seconds from `send` until the message reads as sent.
        private func latency(_ text: String, from a: XMPPSession, to peer: JID) async throws -> TimeInterval {
            let start = Date()
            let sent = try a.send(text, to: peer)
            while Date().timeIntervalSince(start) < 20 {
                let status = try await a.database.reader.read { try Message.fetchOne($0, key: sent.id!)?.status }
                if let status, status >= .sent { return Date().timeIntervalSince(start) }
                try await Task.sleep(for: .milliseconds(5))
            }
            return .infinity
        }

        private func report(_ name: String, _ times: [TimeInterval]) {
            let text = times.map { $0.isFinite ? String(format: "%.0f", $0 * 1000) : "never" }.joined(separator: " ")
            print("LATENCY \(name) (ms): \(text)")
        }

        @Test func sentAppearsQuickly() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connect(a, b)
            defer { a.disconnect(); b.disconnect() }

            for encrypted in [false, true] {
                try a.setEncrypted(encrypted, with: bob)
                // The first message of a connection, then spaced ones.
                var times: [TimeInterval] = []
                for i in 0..<10 {
                    times.append(try await latency("\(encrypted) \(i) \(UUID().uuidString.prefix(6))", from: a, to: bob))
                    try await Task.sleep(for: .milliseconds(i < 5 ? 200 : 1500))
                }
                report(encrypted ? "encrypted, spaced" : "plain, spaced", times)
                #expect(times.allSatisfy { $0 < Self.limit }, "\(times)")

                // Back to back, all in flight together.
                let start = Date()
                let ids = try (0..<8).map { try a.send("burst \($0) \(UUID().uuidString.prefix(6))", to: bob).id! }
                var done: [Int64: TimeInterval] = [:]
                while done.count < ids.count, Date().timeIntervalSince(start) < 20 {
                    for id in ids where done[id] == nil {
                        if let status = try await a.database.reader.read({ try Message.fetchOne($0, key: id)?.status }), status >= .sent {
                            done[id] = Date().timeIntervalSince(start)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let burst = ids.map { done[$0] ?? .infinity }
                report(encrypted ? "encrypted, burst" : "plain, burst", burst)
                #expect(burst.allSatisfy { $0 < Self.limit }, "\(burst)")
            }
        }

        /// Seconds from the sender's `send` until the message is in the
        /// receiver's database, which leaves out everything the UI adds.
        private func arrival(_ text: String, from a: XMPPSession, to b: XMPPSession, peer: JID) async throws -> TimeInterval {
            let start = Date()
            try a.send(text, to: peer)
            while Date().timeIntervalSince(start) < 20 {
                if try await b.database.reader.read({ try Message.filter(Column("body") == text).fetchOne($0) }) != nil {
                    return Date().timeIntervalSince(start)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            return .infinity
        }

        @Test func receivedAppearsQuickly() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connect(a, b)
            defer { a.disconnect(); b.disconnect() }
            for active in [true, false] {
                b.setActive(active)
                for encrypted in [false, true] {
                    try a.setEncrypted(encrypted, with: bob)
                    var times: [TimeInterval] = []
                    for i in 0..<8 {
                        times.append(try await arrival("recv \(i) \(UUID().uuidString.prefix(6))", from: a, to: b, peer: bob))
                        try await Task.sleep(for: .milliseconds(i < 4 ? 200 : 1500))
                    }
                    report("received, \(active ? "active" : "inactive"), \(encrypted ? "encrypted" : "plain")", times)
                    if active { #expect(times.allSatisfy { $0 < Self.limit }, "\(times)") }
                }
            }
        }

        /// Until the conversation's observation, the one the open chat shows,
        /// emits the message: what the screen can't beat.
        @Test func receivedReachesObservationQuickly() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connect(a, b)
            defer { a.disconnect(); b.disconnect() }
            try a.setEncrypted(true, with: bob)
            let seen = Mutex<Set<String>>([])
            let observing = Task {
                await b.database.forEachValue(of: b.database.observeConversation(peer: alice, me: bob), "Test") { items in
                    seen.withLock { $0.formUnion(items.compactMap(\.message.body)) }
                }
            }
            defer { observing.cancel() }
            var times: [TimeInterval] = []
            for i in 0..<8 {
                let text = "observed \(i) \(UUID().uuidString.prefix(6))"
                let start = Date()
                try a.send(text, to: bob)
                while !seen.withLock({ $0.contains(text) }), Date().timeIntervalSince(start) < 20 {
                    try await Task.sleep(for: .milliseconds(5))
                }
                times.append(Date().timeIntervalSince(start))
                try await Task.sleep(for: .milliseconds(i < 4 ? 200 : 1500))
            }
            report("received in observation, encrypted", times)
            #expect(times.allSatisfy { $0 < Self.limit }, "\(times)")
        }

        /// A contact setting up a new device, and a long quiet spell: the
        /// sends that follow may need sessions, but not for seconds.
        @Test func sentAppearsQuicklyAfterChanges() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connect(a, b)
            defer { a.disconnect(); b.disconnect() }
            try a.setEncrypted(true, with: bob)
            var times: [TimeInterval] = []
            times.append(try await latency("warm \(UUID().uuidString.prefix(6))", from: a, to: bob))

            // A fresh device for bob, which alice has no session with yet.
            let fresh = "bob-new-\(UUID().uuidString.prefix(6))"
            let b2 = try LiveServer.makeSession(bob, resource: fresh, database: try AppDatabase.open(at: LiveServer.stateDirectory.appending(path: "\(fresh).sqlite")), port: Self.port)
            try await connect(b2)
            defer { b2.disconnect() }
            for i in 0..<4 {
                times.append(try await latency("new device \(i) \(UUID().uuidString.prefix(6))", from: a, to: bob))
                try await Task.sleep(for: .milliseconds(300))
            }
            report("encrypted, after bob's new device", times)

            try await Task.sleep(for: .seconds(70))
            var later: [TimeInterval] = []
            for i in 0..<3 {
                later.append(try await latency("quiet \(i) \(UUID().uuidString.prefix(6))", from: a, to: bob))
                try await Task.sleep(for: .milliseconds(500))
            }
            report("encrypted, after a minute idle", later)
            #expect((times + later).allSatisfy { $0 < Self.limit }, "\(times + later)")
        }

        /// Sending while messages pour in: the acknowledgement has to be
        /// processed in between them.
        @Test func sentAppearsQuicklyWhileReceiving() async throws {
            let a = try session(alice, device: "alice-1"), b = try session(bob, device: "bob-1")
            try await connect(a, b)
            defer { a.disconnect(); b.disconnect() }
            try a.setEncrypted(true, with: bob)
            try b.setEncrypted(true, with: alice)
            _ = try await latency("warm \(UUID().uuidString.prefix(6))", from: a, to: bob)

            let flood = Task {
                for i in 0..<60 {
                    try b.send("incoming \(i) \(UUID().uuidString.prefix(6)) " + String(repeating: "lorem ipsum ", count: 40), to: alice)
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            var times: [TimeInterval] = []
            for i in 0..<10 {
                times.append(try await latency("outgoing \(i) \(UUID().uuidString.prefix(6))", from: a, to: bob))
                try await Task.sleep(for: .milliseconds(100))
            }
            try await flood.value
            report("encrypted, while receiving", times)
            #expect(times.allSatisfy { $0 < Self.limit }, "\(times)")
        }
    }
}
