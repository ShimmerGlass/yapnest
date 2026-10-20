import Foundation
import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Changing pwchange's password on the real server (XEP-0077), signing in with
    /// the new one and not the old, and putting "password" back. It has an
    /// account of its own (the setup scripts create it), as the other suites
    /// run in parallel on the same server and would fail while a password of
    /// theirs was changed. Over TLS, so the server hands out FAST tokens
    /// where it can.
    /// `YAPNEST_INTEGRATION=1 swift test --filter PasswordChangeIntegration`
    @Suite(.serialized)
    struct PasswordChangeIntegrationTests {
        let account = LiveServer.jid("pwchange")
        static let original = "password"

        private func session(password: String, tokens: FastTokenStore = MemoryFastTokenStore(), resource: String = "pw-\(UUID().uuidString.prefix(6))") throws -> XMPPSession {
            try LiveServer.makeTLSSession(account, resource: resource, password: password, fastTokens: tokens)
        }

        private func connected(password: String, tokens: FastTokenStore = MemoryFastTokenStore()) async throws -> XMPPSession {
            let s = try session(password: password, tokens: tokens)
            s.connect()
            try await waitUntil("signing in", timeout: 60) { s.state.value == .connected(isSyncing: false) || { if case .failed = s.state.value { true } else { false } }() }
            if password == Self.original, case .failed = s.state.value {
                try Test.cancel("\(account) can't sign in on \(LiveServer.target.name): create it with `register pwchange localhost password` (prosodyctl, ejabberdctl) or run dev/\(LiveServer.target.name)/setup.sh")
            }
            try #require(s.state.value == .connected(isSyncing: false), "couldn't sign in as pwchange: \(s.state.value)")
            // The server's features arrive just after the session is up.
            try await waitUntil("the server's features", timeout: 10) { !s.client.module(.disco).serverDiscoResult.features.isEmpty }
            return s
        }

        /// Sets pwchange's password back, whatever the test did. Failing to is
        /// recorded loudly: the other suites would all fail from then on.
        private func restore(from password: String) async {
            guard password != Self.original else { return }
            do {
                let s = try await connected(password: password)
                defer { s.disconnect() }
                try await s.changePassword(to: Self.original, current: password)
            } catch {
                Issue.record("COULD NOT RESTORE pwchange's password on \(LiveServer.target.name): \(error). Reset it on the server.")
            }
        }

        @Test func theServerJudgesAPasswordWithoutDisturbingTheSession() async throws {
            let tokens = MemoryFastTokenStore()
            let live = try await connected(password: Self.original, tokens: tokens)
            defer { live.disconnect() }
            let token = tokens.load()

            #expect(try await live.accepts(password: Self.original))
            #expect(try await live.accepts(password: "not-\(Self.original)") == false)

            // The session stayed up on its own resource, and no token was issued or replaced.
            #expect(live.state.value == .connected(isSyncing: false))
            #expect(tokens.load() == token)
            #expect(live.client.module(.sasl2).signedInWithToken == false)
        }

        @Test func theNewPasswordSignsInAndTheOldOneDoesnt() async throws {
            let tokens = MemoryFastTokenStore()
            let first = try await connected(password: Self.original, tokens: tokens)
            defer { first.disconnect() }
            guard first.canChangePassword else {
                try Test.cancel("\(LiveServer.target.name) doesn't advertise jabber:iq:register on its domain, so the option stays hidden")
            }
            let hadToken = tokens.load() != nil
            let fresh = "pw-\(UUID().uuidString.prefix(12))"

            do {
                try await first.changePassword(to: fresh, current: Self.original)
            } catch {
                print("PASSWORDCHANGE \(LiveServer.target.name) refused: \(error)")
                // An unanswered request may have gone through all the same.
                if error as? XMPPSession.PasswordError == .timedOut { await restore(from: fresh) }
                throw error
            }
            // From here the server has the new password.
            do {
                try await Task.sleep(for: .seconds(1))
                print("PASSWORDCHANGE \(LiveServer.target.name) accepted; session still \(first.state.value); had token: \(hadToken)")
                #expect(tokens.load() == nil, "the FAST token should be dropped")

                // The same session reconnects with the new password.
                first.disconnect()
                try await waitUntil("the old connection to close", timeout: 60) { if case .disconnected = first.client.state { true } else { false } }
                first.connect()
                try await waitUntil("signing in again", timeout: 60) { first.state.value == .connected(isSyncing: false) }
                #expect(first.state.value == .connected(isSyncing: false))
                #expect(first.client.module(.sasl2).signedInWithToken == false)

                // A fresh one with the old password is refused.
                let old = try session(password: Self.original)
                old.connect()
                defer { old.disconnect() }
                try await waitUntil("the refusal", timeout: 60) { if case .failed = old.state.value { true } else { false } }
                #expect(old.state.value == .failed("Wrong address or password."))

                // A fresh one with the new password signs in.
                let again = try await connected(password: fresh)
                again.disconnect()
            } catch {
                await restore(from: fresh)
                throw error
            }
            await restore(from: fresh)
        }
    }
}
