import Foundation
import GRDB
@testable import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// A body with control characters (a pasted terminal escape sequence) is not allowed in XML.
    /// Prosody and ejabberd closed the stream on it, Openfire failed to decode it, and the message was
    /// written first again on every reconnect with everything behind it stuck.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=prosody swift test --filter ControlCharacterIntegration`
    struct ControlCharacterIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        @Test func aBodyWithControlCharactersIsDeliveredWithoutThemAndTheStreamStaysUp() async throws {
            let a = try await LiveServer.connectedSession(alice, resource: "control")
            let b = try await LiveServer.connectedSession(bob, resource: "control")
            defer { a.disconnect(); b.disconnect() }
            try a.setEncrypted(false, with: bob)
            try b.setEncrypted(false, with: alice)
            let dropped = OSAllocatedBool()
            let watch = a.state.sink { if case .connected = $0 {} else { dropped.set() } }
            defer { watch.cancel() }

            let first = try a.send("bell \u{07} and escape \u{1B}[0m", to: bob)
            let after = try a.send("after", to: bob)
            func body(_ id: String?) throws -> String? {
                try b.database.reader.read { try YapnestKit.Message.filter(Column("remoteId") == id).fetchOne($0)?.body }
            }
            try await LiveServer.waitUntil("bob to receive both messages", timeout: 60) { try body(first.remoteId) != nil && body(after.remoteId) != nil }
            #expect(try body(first.remoteId) == "bell  and escape [0m")
            #expect(try body(after.remoteId) == "after")
            #expect(!dropped.value)
        }
    }
}
