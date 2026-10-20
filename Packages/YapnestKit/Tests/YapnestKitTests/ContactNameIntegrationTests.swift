import Foundation
import Testing
@testable import YapnestKit

extension LiveServer {
    /// A contact's roster name, set on one device and seen on another.
    /// `YAPNEST_INTEGRATION=1 swift test --filter ContactNameIntegration`
    @Suite
    struct ContactNameIntegrationTests {
        let alice = LiveServer.jid("alice")
        let carol = LiveServer.jid("carol")

        @Test func aRenameReachesTheAccountsOtherDevice() async throws {
            let phone = try await LiveServer.connectedSession(alice, resource: "phone")
            let mac = try await LiveServer.connectedSession(alice, resource: "mac")
            defer { phone.disconnect(); mac.disconnect() }
            try? await phone.removeContact(carol)
            try await waitUntil("carol to leave both rosters") { try !phone.database.isInRoster(carol) && !mac.database.isInRoster(carol) }

            phone.addContact(carol)
            try await waitUntil("carol on both rosters") { try phone.database.isInRoster(carol) && mac.database.isInRoster(carol) }

            try await phone.setContactName(carol, name: "  Caz  ")
            try await waitUntil("the name on the phone") { try phone.database.contact(carol)?.displayName == "Caz" }
            try await waitUntil("the name on the mac") { try mac.database.contact(carol)?.displayName == "Caz" }
            // Neither the subscription request nor anything else is touched.
            #expect(try mac.database.contact(carol)?.isSubscriptionPending == phone.database.contact(carol)?.isSubscriptionPending)

            try await phone.setContactName(carol, name: nil)
            try await waitUntil("the name to clear on the mac") { try mac.database.contact(carol)?.name == nil }
            #expect(try mac.database.contact(carol)?.isInRoster == true)

            try? await phone.removeContact(carol)
        }

        @Test func aStrangerCantBeNamed() async throws {
            let phone = try await LiveServer.connectedSession(alice, resource: "phone")
            defer { phone.disconnect() }
            try? await phone.removeContact(carol)
            try await waitUntil("carol to leave the roster") { try !phone.database.isInRoster(carol) }
            await #expect(throws: XMPPSession.ContactError.self) { try await phone.setContactName(carol, name: "Caz") }
            #expect(try !phone.database.isInRoster(carol))
        }
    }
}
