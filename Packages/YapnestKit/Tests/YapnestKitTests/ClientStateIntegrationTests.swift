import Combine
import Foundation
import Synchronization
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Whether the server really hears the app's state (XEP-0352). Prosody's
    /// `csi_simple` holds back chat states for an inactive session, and
    /// delivers them once it's active again, which only happens if our
    /// `<inactive/>` and `<active/>` arrive.
    /// `YAPNEST_INTEGRATION=1 swift test --filter ClientStateIntegration`
    @Suite
    struct ClientStateIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        private func session(_ jid: JID, port: Int? = nil) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "csi-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: port ?? LiveServer.target.port)
        }

        /// Waits until nothing has gone either way through `proxy` for a second.
        /// `csi_simple` lets out what it holds as soon as the client sends
        /// anything or an answer reaches it, and a session is still at work
        /// after its sync: joining the rooms earlier runs left in its
        /// bookmarks, publishing a new device, fetching avatars.
        private func quiet(_ proxy: FreezableProxy, within seconds: TimeInterval = 30) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            var last = (proxy.clientTraffic.count, proxy.serverTraffic.count), since = Date()
            while Date().timeIntervalSince(since) < 1 {
                if Date() > deadline { Issue.record("the session never went quiet"); return }
                try await Task.sleep(for: .milliseconds(100))
                let now = (proxy.clientTraffic.count, proxy.serverTraffic.count)
                if now != last { (last, since) = (now, Date()) }
            }
        }

        private func connected(_ session: XMPPSession) async throws {
            session.connect()
            while session.state.value != .connected(isSyncing: false) { try await Task.sleep(for: .milliseconds(50)) }
        }

        /// Counts the chat states a session has received while it's alive.
        final class Heard: Sendable {
            private let count = Mutex(0)
            private let token = Mutex<AnyCancellable?>(nil)
            var value: Int { count.withLock { $0 } }
            init(_ session: XMPPSession) {
                token.withLock { $0 = session.events.sink { [unowned self] in if case .chatState = $0 {  count.withLock { $0 += 1 } } } }
            }
        }

        private func listen(to session: XMPPSession) -> Heard { Heard(session) }

        private func waitForArrival(_ heard: Heard, _ n: Int, within seconds: TimeInterval) async throws -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while heard.value < n {
                if Date() > deadline { return false }
                try await Task.sleep(for: .milliseconds(50))
            }
            return true
        }

        private func ping(from a: XMPPSession) {
            a.write(OutboundStanza.chatState(.composing, to: bob))
        }

        /// While connected: inactive holds the state, active releases it.
        @Test func changesWhileConnected() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try session(alice), b = try session(bob, port: proxy.port)
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }
            let heard = listen(to: b)

            ping(from: a)
            #expect(try await waitForArrival(heard, 1, within: 5), "an active session gets chat states at once")

            try await quiet(proxy)
            b.setActive(false)
            try await Task.sleep(for: .milliseconds(500))
            let sentBefore = proxy.clientTraffic.count
            ping(from: a)
            #expect(try await !waitForArrival(heard, 2, within: 2),
                    "an inactive session shouldn't, unless it sent something: \(proxy.clientTraffic.dropFirst(sentBefore).prefix(2000))")

            b.setActive(true)
            #expect(try await waitForArrival(heard, 2, within: 5), "going active delivers what was held")
        }

        /// A session that connects while the app is in the background says so
        /// right away, rather than starting active.
        @Test func reportedOnConnect() async throws {
            let a = try session(alice), b = try session(bob)
            b.setActive(false)
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }
            let heard = listen(to: b)

            // The server delivers what it holds whenever something important
            // reaches us, and the session's own follow-up requests are that.
            try await Task.sleep(for: .seconds(5))
            ping(from: a)
            #expect(try await !waitForArrival(heard, 1, within: 2))
            b.setActive(true)
            #expect(try await waitForArrival(heard, 1, within: 5))
        }
    }
}
