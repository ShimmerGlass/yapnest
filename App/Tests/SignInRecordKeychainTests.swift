import Foundation
import Testing
import YapnestKit

/// The record of the strongest sign-in in the real keychain, which only a
/// signed process can reach: kept per account, and gone on sign-out.
@Suite(.serialized)
struct SignInRecordKeychainTests {
    let first = KeychainSignInRecordStore(account: JID("record-test-\(UUID().uuidString.prefix(8))@example.org")!)
    let second = KeychainSignInRecordStore(account: JID("record-test-\(UUID().uuidString.prefix(8))@example.org")!)

    @Test func keepsOneRecordPerAccountAndForgetsThemOnSignOut() {
        defer { KeychainSignInRecordStore.deleteAll() }
        #expect(first.load() == nil)
        first.save("PLAIN")
        second.save("SCRAM-SHA-256-PLUS")
        first.save("SCRAM-SHA-256")
        #expect(first.load() == "SCRAM-SHA-256")
        #expect(second.load() == "SCRAM-SHA-256-PLUS")

        KeychainSignInRecordStore.deleteAll()
        #expect(first.load() == nil)
        #expect(second.load() == nil)
    }
}
