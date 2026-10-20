#if os(macOS)
import Foundation
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Contact invitations (XEP-0379) on a real server. Only Snikket's
    /// Prosody has them (mod_invites, behind XEP-0401): the plain Prosody
    /// dev server doesn't load it, and neither do ejabberd or Openfire. The
    /// invitation is made through the container, so Docker has to be there.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=snikket swift test --filter PreauthIntegration`
    @Suite(.enabled(if: LiveServer.target.name == "snikket"))
    struct PreauthIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// A fresh invitation to become alice's contact, as Snikket's admin
        /// would hand it out: an `xmpp:` link.
        private func invitation() throws -> XMPPURI {
            let compose = URL(filePath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appending(path: "dev/snikket")
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.currentDirectoryURL = compose
            process.arguments = ["docker", "compose", "exec", "-T", "-u", "prosody", "snikket",
                                 "prosodyctl", "shell", "invite", "create_contact", alice.description]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let link = try #require(text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("xmpp:") }, "no invitation in: \(text)")
            return try #require(XMPPURI(String(link)))
        }

        private func reset(_ a: XMPPSession, _ b: XMPPSession) async throws {
            try? await a.removeContact(bob)
            try? await b.removeContact(alice)
            try await waitUntil("bob to be off alice's roster") { try !a.database.isInRoster(bob) }
        }

        @Test func aPreauthTokenGetsTheSubscriptionApprovedWithoutAlice() async throws {
            let a = try await LiveServer.connectedSession(alice, resource: "pre"), b = try await LiveServer.connectedSession(bob, resource: "pre")
            defer { a.disconnect(); b.disconnect() }
            try await reset(a, b)

            let link = try invitation()
            #expect(link.jid == alice)
            guard case .addContact(_, let token?) = link.action else {
                Issue.record("not an invitation to become contacts: \(link)")
                return
            }

            b.addContact(link.jid, preauth: token)
            // Bob sees alice, and alice's server added bob and let him see her
            // without a request for her to answer.
            try await waitUntil("bob to see alice") { try b.database.contact(alice)?.seesPresence == true }
            try await waitUntil("bob to be on alice's roster") { try a.database.contact(bob)?.subscription == .from || a.database.contact(bob)?.subscription == .both }
            #expect(try a.database.contact(bob)?.hasContactRequest != true)

            try await reset(a, b)
        }

        /// Without the token, or with a wrong one, alice is asked as usual.
        @Test func aWrongTokenLeavesTheRequestToAlice() async throws {
            let a = try await LiveServer.connectedSession(alice, resource: "pre"), b = try await LiveServer.connectedSession(bob, resource: "pre")
            defer { a.disconnect(); b.disconnect() }
            try await reset(a, b)

            b.addContact(alice, preauth: "not-a-real-token")
            try await waitUntil("alice to get the request") { try a.database.contact(bob)?.hasContactRequest == true }
            #expect(try a.database.contact(bob)?.seesPresence != true)
            #expect(try a.database.contact(bob)?.subscription != .from)

            try await reset(a, b)
        }
    }
}

#endif
