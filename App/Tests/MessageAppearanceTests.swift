import Testing
import YapnestKit
@testable import Yapnest

/// How a message shows the way it travelled. A message must never look safer
/// than what is known about it.
struct MessageAppearanceTests {
    private func message(_ direction: Message.Direction, _ encryption: Message.Encryption, trust: OMEMODevice.Trust? = nil) -> Message {
        Message(conversationId: 1, direction: direction, sender: JID("a@example.com")!, body: "x", encryption: encryption, omemoTrust: trust)
    }

    @Test(arguments: [Message.Direction.incoming, .outgoing])
    func aMessageSentInTheClearIsFlaggedRed(direction: Message.Direction) {
        let security = message(direction, .none).security
        #expect(security.color == .red)
        #expect(security.symbol == "lock.slash.fill")
    }

    @Test(arguments: [Message.Direction.incoming, .outgoing])
    func anUndecryptableMessageIsFlaggedRed(direction: Message.Direction) {
        #expect(message(direction, .omemoUndecryptable).security.color == .red)
    }

    @Test func undecidedAndCompromisedDevicesAreWarnedAbout() {
        for trust in [OMEMODevice.Trust.undecided, .compromised] {
            for direction in [Message.Direction.incoming, .outgoing] {
                let security = message(direction, .omemo, trust: trust).security
                #expect(security.color == .orange)
                #expect(security.detail == "Untrusted device")
            }
        }
    }

    @Test func onlyAVerifiedDeviceGetsTheCheckmark() {
        #expect(message(.incoming, .omemo, trust: .verified).security.symbol == "lock.badge.checkmark.fill")
        for trust in [OMEMODevice.Trust.undecided, .trusted, .compromised] {
            #expect(message(.incoming, .omemo, trust: trust).security.symbol != "lock.badge.checkmark.fill")
        }
    }

    @Test func aTrustedButUnverifiedSenderIsSaidToBeUnverified() {
        #expect(message(.incoming, .omemo, trust: .trusted).security.detail == "Unverified device")
    }

    @Test func aMessageFromAnUnknownDeviceIsWarnedAbout() {
        let security = message(.incoming, .omemo, trust: nil).security
        #expect(security.color == .orange)
        #expect(security.detail == "Unknown device")
    }

    @Test func ourOwnEncryptedMessageWithoutATrustLevelIsPlain() {
        let security = message(.outgoing, .omemo, trust: nil).security
        #expect(security.color == nil)
        #expect(security.detail == nil)
    }

    @Test func titleAndDetailJoinOnOneLine() {
        #expect(message(.incoming, .omemo, trust: .verified).security.fullTitle == "Encrypted · Verified device")
        #expect(message(.outgoing, .none).security.fullTitle == "Not encrypted")
    }
}
