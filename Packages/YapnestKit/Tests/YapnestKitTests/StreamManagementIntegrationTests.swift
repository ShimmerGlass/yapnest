import Foundation
import GRDB
import Martin
import Network
import Synchronization
import Testing
@testable import YapnestKit

/// A TCP proxy to the dev server that can keep the server's stream
/// acknowledgements (`<a/>`, XEP-0198) from reaching the client, and can say
/// something in the server's name. `FreezableProxy` can only hold back
/// everything the server sends, which would also hold back the `<resumed/>`
/// these tests need to see. It is byte-exact otherwise: nothing but the
/// acknowledgements is ever changed.
final class StreamProxy: Sendable {
    private final class Pair: @unchecked Sendable {
        let client: NWConnection
        let server: NWConnection
        /// The start of an acknowledgement a read ended in the middle of. Only touched on the proxy's queue.
        var carry: [UInt8] = []
        /// Both directions in the order they passed, each chunk marked with who sent it.
        var log = ""
        init(client: NWConnection, server: NWConnection) { (self.client, self.server) = (client, server) }
    }

    private struct Traffic {
        var toServer = Data()
        var toClient = Data()
        var holdsAcks = false
        var droppedAcks = 0
        var pairs: [Pair] = []
        var everyPair: [Pair] = []
        var serverDelay: TimeInterval = 0
    }

    private let listener: NWListener
    private let traffic = Mutex(Traffic())
    private let queue = DispatchQueue(label: "stream-proxy")

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    /// While set, the server's `<a/>` elements are dropped.
    var holdsAcks: Bool {
        get { traffic.withLock { $0.holdsAcks } }
        set { traffic.withLock { $0.holdsAcks = newValue } }
    }

    /// How long what the server sends is kept before it reaches the client, in order. Widens the time a new
    /// stream spends before the server has accepted its sign-in.
    var serverDelay: TimeInterval {
        get { traffic.withLock { $0.serverDelay } }
        set { traffic.withLock { $0.serverDelay = newValue } }
    }

    /// How many acknowledgements were dropped, which shows the server did send them.
    var droppedAcks: Int { traffic.withLock { $0.droppedAcks } }

    /// How often `pattern` appears in what the client has sent so far, over every connection.
    func clientSent(_ pattern: String) -> Int { Self.count(pattern, in: traffic.withLock { $0.toServer }) }

    /// How often `pattern` appears in what the server has sent so far, over every connection.
    func serverSent(_ pattern: String) -> Int { Self.count(pattern, in: traffic.withLock { $0.toClient }) }

    /// How many streams were resumed: inline in SASL2's `<success>`, or as `<resumed/>` after XEP-0198's `<resume/>`.
    var resumptions: Int { serverSent("<resumed") }

    /// How many connections had the client write a stream ack before the server had accepted its sign-in.
    /// The server has no stream to count them against yet, and closes it with `unsupported-stanza-type`.
    var acksBeforeSignIn: Int {
        traffic.withLock { traffic in
            traffic.everyPair.filter { pair in
                var accepted = false
                for chunk in pair.log.components(separatedBy: "\u{1}").dropFirst() {
                    if chunk.hasPrefix("S"), chunk.contains("<success") { accepted = true }
                    if chunk.hasPrefix("C"), chunk.contains("<a "), !accepted { return true }
                }
                return false
            }.count
        }
    }

    private static func count(_ pattern: String, in data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: pattern).count - 1
    }

    /// Closes every open connection, as a network drop would.
    func cut() {
        let pairs = traffic.withLock { traffic in defer { traffic.pairs = [] }; return traffic.pairs }
        for pair in pairs { pair.client.cancel(); pair.server.cancel() }
    }

    /// Sends `text` to the client as if the server had, on its open connections.
    func tellClient(_ text: String) {
        let pairs = traffic.withLock { $0.pairs }
        for pair in pairs { pair.client.send(content: Data(text.utf8), completion: .contentProcessed { _ in }) }
    }

    init(to upstreamPort: UInt16) async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] client in
            let server = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
            let pair = Pair(client: client, server: server)
            traffic.withLock { $0.pairs.append(pair); $0.everyPair.append(pair) }
            pump(pair, from: client, to: server, toClient: false)
            pump(pair, from: server, to: client, toClient: true)
            client.start(queue: queue)
            server.start(queue: queue)
        }
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state, !resumed.withLock({ defer { $0 = true }; return $0 }) { continuation.resume() }
            }
            listener.start(queue: queue)
        }
    }

    private func pump(_ pair: Pair, from: NWConnection, to: NWConnection, toClient: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data {
                var delay: TimeInterval = 0
                let out: [UInt8] = traffic.withLock { traffic in
                    delay = toClient ? traffic.serverDelay : 0
                    if toClient { traffic.toClient += data } else { traffic.toServer += data }
                    pair.log += (toClient ? "\u{1}S" : "\u{1}C") + String(decoding: data, as: UTF8.self)
                    guard toClient else { return Array(data) }
                    // Bytes, not text: a read can end in the middle of a character.
                    let (out, dropped) = Self.strippingAcks(Array(data), carry: &pair.carry, drop: traffic.holdsAcks)
                    traffic.droppedAcks += dropped
                    return out
                }
                if !out.isEmpty {
                    let send = { to.send(content: Data(out), completion: .contentProcessed { _ in }) }
                    // Deadlines only grow, so the queue runs them in the order the reads came.
                    if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
                }
            }
            if error == nil, !done {
                pump(pair, from: from, to: to, toClient: toClient)
            } else {
                from.cancel()
                to.cancel()
            }
        }
    }

    /// `input` without the `<a ... urn:xmpp:sm:3 .../>` elements when `drop` is set, and how many there were.
    /// The start of one that `input` ends in the middle of is kept in `carry` for the next read.
    static func strippingAcks(_ input: [UInt8], carry: inout [UInt8], drop: Bool) -> (out: [UInt8], dropped: Int) {
        if carry.isEmpty, !drop { return (input, 0) }
        let open = Array("<a ".utf8), close = Array("/>".utf8), namespace = Array("urn:xmpp:sm:3".utf8)
        let buffer = carry + input
        carry = []
        var out: [UInt8] = [], dropped = 0, i = 0
        func find(_ needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
            guard haystack.count >= needle.count else { return nil }
            return (haystack.startIndex...(haystack.endIndex - needle.count)).first { haystack[$0..<$0 + needle.count].elementsEqual(needle) }
        }
        while i < buffer.count {
            if buffer[i] == UInt8(ascii: "<") {
                let tail = buffer[i...]
                if tail.count < open.count, open.starts(with: tail) { carry = Array(tail); break }
                if tail.starts(with: open) {
                    guard let end = find(close, in: tail) else { carry = Array(tail); break }
                    let element = buffer[i..<end + close.count]
                    if drop, find(namespace, in: element) != nil { dropped += 1 } else { out += element }
                    i = end + close.count
                    continue
                }
            }
            out.append(buffer[i])
            i += 1
        }
        return (out, dropped)
    }

    func stop() {
        listener.cancel()
        cut()
    }
}

extension LiveServer {
    /// A device's database, kept across runs like `OMEMOIntegrationTests.device`, but in a folder of its own:
    /// the dev servers' setup.sh scripts clear theirs, which fails a test with a disk I/O error halfway through.
    static func keptDevice(_ name: String) throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yapnest-integration-kept/\(target.name)-\(target.port)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase.open(at: directory.appending(path: "\(name).sqlite"))
    }
}

extension LiveServer {
    /// What stream management (XEP-0198) must do for the session, seen only
    /// through YapnestKit's API and the bytes on the wire: when a message
    /// counts as sent, what survives a drop, and when a dead connection is
    /// noticed. The unit tests that cover the same fixes use Martin's own API.
    /// `YAPNEST_INTEGRATION=1 swift test --filter StreamManagementIntegration`
    @Suite
    struct StreamManagementIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// A device whose database is kept across runs, as the other suites do.
        private func session(_ jid: YapnestKit.JID, device: String, port: Int = LiveServer.target.port) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "\(device)-\(UUID().uuidString.prefix(6))", database: try LiveServer.keptDevice(device), port: port)
        }

        private func stored(_ body: String, in session: XMPPSession) throws -> YapnestKit.Message? {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("body") == body).fetchOne($0) }
        }

        private func status(_ body: String, in session: XMPPSession) throws -> YapnestKit.Message.Status? {
            try stored(body, in: session)?.status
        }

        private func copies(_ body: String, in session: XMPPSession) throws -> Int {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("body") == body).fetchCount($0) }
        }

        /// A peer that is online and listening, on a connection nothing touches.
        private func peer(_ jid: YapnestKit.JID, talkingTo other: YapnestKit.JID, device: String) async throws -> XMPPSession {
            let peer = try session(jid, device: device)
            try await LiveServer.connected(peer, timeout: 60)
            try peer.setEncrypted(false, with: other)
            return peer
        }

        // MARK: Held acknowledgements

        /// A message is sent when the server says it has it, not when it was
        /// written. With the acknowledgements held back, three messages stay
        /// pending, and the resumption that follows a drop still delivers each
        /// once and marks it sent.
        @Test func heldAcksLoseNothing() async throws {
            let proxy = try await StreamProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice, device: "sm-held-alice", port: proxy.port)
            try await LiveServer.connected(a, timeout: 60)
            defer { a.disconnect() }
            try await LiveServer.waitUntil("stream management", timeout: 60) { a.client.module(.streamManagement).resumptionEnabled }
            try a.setEncrypted(false, with: bob)
            // What the sync left unacknowledged is not what this is about.
            try await Task.sleep(for: .seconds(2))

            proxy.holdsAcks = true
            let bodies = (1...3).map { "held \($0) \(UUID().uuidString.prefix(6))" }
            for body in bodies {
                try a.send(body, to: bob)
                try await Task.sleep(for: .milliseconds(300))
            }
            // Long enough for the server to have answered the requests for acks.
            try await Task.sleep(for: .seconds(4))
            try #require(proxy.droppedAcks > 0, "the server never acknowledged anything, so nothing was held")
            for body in bodies {
                #expect(try status(body, in: a) == .pending, "'\(body)' was marked before the server acknowledged it")
            }
            let resumedBefore = proxy.resumptions

            // The acks stay held on the new stream: only the resumption's own count can release them.
            proxy.cut()
            try await LiveServer.waitUntil("the stream to resume", timeout: 60) { proxy.resumptions > resumedBefore && a.state.value == .connected(isSyncing: false) }
            try await LiveServer.waitUntil("each message to be sent", timeout: 60) { try bodies.allSatisfy { try status($0, in: a).map { $0 >= .sent } ?? false } }

            let b = try await peer(bob, talkingTo: alice, device: "sm-held-bob")
            defer { b.disconnect() }
            try await LiveServer.waitUntil("bob to get all three", timeout: 60) { try bodies.allSatisfy { try stored($0, in: b) != nil } }
            // A duplicate would have time to arrive.
            try await Task.sleep(for: .seconds(3))
            for body in bodies {
                let seen = try copies(body, in: b)
                #expect(seen == 1, "bob has '\(body)' \(seen) times")
                #expect(proxy.clientSent(body) == 1, "'\(body)' was written \(proxy.clientSent(body)) times")
            }
        }

        // MARK: Resumes in a row

        /// Resuming works every time, not only the first: a stream ack the
        /// client had scheduled must never turn up on the stream that
        /// replaces the one it was meant for. Each round the server's `<r/>`
        /// arrives, the connection drops at once, and the session logs in
        /// again within 100 ms (the delay of the ack). The server's answers
        /// to the new stream are held back for 0.4 s, so an ack scheduled on
        /// the old stream would land on the new one before it is authenticated.
        /// With that guard taken out of Martin the test fails in about three
        /// runs out of four (the timing is not exact), so it can miss the
        /// bug once but not keep missing it.
        @Test func twentyResumesInARow() async throws {
            let rounds = 20
            let proxy = try await StreamProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice, device: "sm-twenty-alice", port: proxy.port)
            try await LiveServer.connected(a, timeout: 60)
            defer { a.disconnect() }
            try await LiveServer.waitUntil("stream management", timeout: 60) { a.client.module(.streamManagement).resumptionEnabled }
            try a.setEncrypted(false, with: bob)
            let b = try await peer(bob, talkingTo: alice, device: "sm-twenty-bob")
            defer { b.disconnect() }
            let enabledBefore = proxy.serverSent("<enabled")

            var sent: [String] = [], received: [String] = []
            for round in 1...rounds {
                let out = "twenty \(round) out \(UUID().uuidString.prefix(6))", back = "twenty \(round) back \(UUID().uuidString.prefix(6))"
                try a.send(out, to: bob)
                try b.send(back, to: alice)
                sent.append(out)
                received.append(back)
                try await LiveServer.waitUntil("round \(round)'s traffic", timeout: 60) {
                    try status(out, in: a).map { $0 >= .sent } ?? false && stored(back, in: a) != nil
                }

                // The new stream waits for the server's answers, so the ack scheduled on the old one comes due before it is signed in.
                proxy.serverDelay = 0.4
                proxy.tellClient("<r xmlns='urn:xmpp:sm:3'/>")
                proxy.cut()
                // Straight back in, as a network change does, rather than after the backoff.
                let dropped = Date().addingTimeInterval(10)
                while a.isConnected, Date() < dropped { await Task.yield() }
                // Varied, as when exactly the ack was scheduled differs. Every other round logs in with no
                // delay at all, in the millisecond of the drop's own clean-up.
                if round % 2 == 1 { try await Task.sleep(for: .milliseconds(15 + (round * 13) % 40)) }
                a.pathBecameSatisfied()
                try await LiveServer.waitUntil("round \(round) to resume", timeout: 30) { proxy.resumptions >= round }
                proxy.serverDelay = 0
                try await LiveServer.waitUntil("round \(round) to be connected again", timeout: 30) { a.state.value == .connected(isSyncing: false) }
                if proxy.resumptions < round { break }
            }

            #expect(proxy.acksBeforeSignIn == 0, "a stream ack was written before the server had accepted the sign-in")
            #expect(proxy.resumptions == rounds, "resumed \(proxy.resumptions) times out of \(rounds)")
            // A new session would enable stream management again.
            #expect(proxy.serverSent("<enabled") == enabledBefore, "a round started a new session")
            #expect(proxy.serverSent("unsupported-stanza-type") == 0, "the server refused a stanza that was written on the wrong stream")
            try await Task.sleep(for: .seconds(2))
            for body in sent {
                let seen = try copies(body, in: b)
                #expect(seen == 1, "bob has '\(body)' \(seen) times")
                #expect(proxy.clientSent(body) == 1, "'\(body)' was written \(proxy.clientSent(body)) times")
            }
            for body in received {
                let seen = try copies(body, in: a)
                #expect(seen == 1, "alice has '\(body)' \(seen) times")
            }
        }

        // MARK: Aborted sign-in

        /// iOS reports a path update with an identical path when the app returns, and the session then drops
        /// the attempt it has in flight. Martin took that drop for an unreachable server and forgot the
        /// stream, so the next attempt started a new session although the server still held the old one.
        /// The server's answers are held back so the abort lands while the resume is waiting for its answer. A
        /// server without SASL2 answers the login in several steps, each held back, and writes the resume
        /// only after them, so the delay is short and the wait for the resume long.
        @Test(.timeLimit(.minutes(3))) func aResumeWeAbortIsTriedAgain() async throws {
            let proxy = try await StreamProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice, device: "sm-abort-alice", port: proxy.port)
            try await LiveServer.connected(a, timeout: 60)
            defer { a.disconnect() }
            try await LiveServer.waitUntil("stream management", timeout: 60) { a.client.module(.streamManagement).resumptionEnabled }
            let enabledBefore = proxy.serverSent("<enabled")

            proxy.serverDelay = 2
            proxy.cut()
            let dropped = Date().addingTimeInterval(10)
            while a.isConnected, Date() < dropped { await Task.yield() }
            a.pathBecameSatisfied()
            try await LiveServer.waitUntil("the resume to be written", timeout: 30) { proxy.clientSent("<resume ") > 0 }
            #expect(a.state.value != .connected(isSyncing: false))

            a.pathBecameSatisfied()
            proxy.serverDelay = 0
            try await LiveServer.waitUntil("the stream to resume", timeout: 60) { proxy.resumptions >= 1 && a.state.value == .connected(isSyncing: false) }
            #expect(proxy.serverSent("<enabled") == enabledBefore, "the abort started a new session")
        }

        // MARK: Silent links

        /// Martin pings the server every `keepaliveTimeout` seconds, and drops
        /// the connection when the ping goes unanswered for its timeout. The
        /// app's own check (`verifyConnection`) only runs when the app
        /// returns or the network changes, and this test does neither, so
        /// the drop is Martin's. The ping's timeout (120 s,
        /// `PingModule.ping`'s default) is only noticed when the response
        /// manager sweeps, every 30 s, so the wait is the interval, 120 s
        /// and 30 s, about five and a half minutes, so it only runs with
        /// `YAPNEST_SLOW=1`.
        @Test(.timeLimit(.minutes(10))) func idleLinkIsDroppedByKeepalive() async throws {
            guard ProcessInfo.processInfo.environment["YAPNEST_SLOW"] == "1" else {
                try Test.cancel("takes five and a half minutes; set YAPNEST_SLOW=1 to run it")
            }
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice, device: "sm-keepalive", port: proxy.port)
            let drops = Mutex<[(at: Date, error: String?)]>([])
            let watch = a.state.sink { state in
                if case .disconnected(let error) = state { drops.withLock { $0.append((Date(), error)) } }
            }
            defer { watch.cancel() }
            try await LiveServer.connected(a, timeout: 60)
            defer { a.disconnect() }
            try await LiveServer.waitUntil("stream management", timeout: 60) { a.client.module(.streamManagement).resumptionEnabled }

            let interval = a.client.keepaliveTimeout
            try #require(interval > 0, "there is no keepalive")
            let pingTimeout: TimeInterval = 120, sweep: TimeInterval = 30
            let bound = interval + pingTimeout + sweep + 15
            let froze = Date()
            proxy.isFrozen = true
            try await LiveServer.waitUntil("the keepalive to drop the link", timeout: bound) { !drops.withLock { $0 }.filter { $0.at > froze }.isEmpty }

            let drop = try #require(drops.withLock { $0 }.first { $0.at > froze }, "still connected \(Int(bound)) s after the link went silent")
            let elapsed = drop.at.timeIntervalSince(froze)
            print("KEEPALIVE dropped \(Int(elapsed)) s after the link went silent (interval \(Int(interval)) s); reason: \(drop.error ?? "none")")
            // The app's own check says exactly this; Martin's drop does not.
            #expect(drop.error != "The connection was lost.", "the app's own liveness check dropped it, not the keepalive")
            // Nothing but a ping that waited out its timeout can drop a link this quickly after a freeze.
            #expect(elapsed > 60)
        }

        /// A message written to a connection that is dead but not yet known
        /// to be isn't sent: nothing has said the server has it. After the
        /// drop is noticed it goes out once, on the resumed stream.
        @Test func aSendOnADeadStreamStaysPending() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice, device: "sm-dead-alice", port: proxy.port)
            let resumed = Mutex(0)
            // Martin's State compares equal whatever `resumed` says, so match the payload.
            let watch = a.client.$state.sink { state in
                if case .connected(let wasResumed) = state, wasResumed { resumed.withLock { $0 += 1 } }
            }
            defer { watch.cancel() }
            try await LiveServer.connected(a, timeout: 60)
            defer { a.disconnect() }
            try await LiveServer.waitUntil("stream management", timeout: 60) { a.client.module(.streamManagement).resumptionEnabled }
            try a.setEncrypted(false, with: bob)
            try await Task.sleep(for: .seconds(2))

            proxy.isFrozen = true
            let body = "dead \(UUID().uuidString.prefix(6))"
            try a.send(body, to: bob)
            for _ in 0..<40 {
                let now = try status(body, in: a)
                #expect(now == .pending, "marked \(String(describing: now)) on a connection that never reached the server")
                try await Task.sleep(for: .milliseconds(150))
            }
            #expect(a.isConnected, "the drop was noticed, so this isn't the case under test")

            proxy.isFrozen = false
            proxy.cut()
            try await LiveServer.waitUntil("the stream to resume", timeout: 60) { resumed.withLock { $0 } >= 1 && a.state.value == .connected(isSyncing: false) }
            // Martin writes the queued message again after `<resumed/>`; it must also ask for the acknowledgement.
            try await LiveServer.waitUntil("the resent message to be sent", timeout: 15) { try status(body, in: a).map { $0 >= .sent } ?? false }
            #expect(resumed.withLock { $0 } == 1, "the stream should have been resumed")

            let b = try await peer(bob, talkingTo: alice, device: "sm-dead-bob")
            defer { b.disconnect() }
            try await LiveServer.waitUntil("bob to get it", timeout: 60) { try stored(body, in: b) != nil }
            try await Task.sleep(for: .seconds(3))
            #expect(try copies(body, in: b) == 1)
            // What was written while frozen never passed the proxy; this is the one that reached the server.
            #expect(proxy.clientSent(body) == 1, "written \(proxy.clientSent(body)) times to the server")
        }
    }
}
