import Testing
@testable import YapnestKit

struct LivenessTests {
    /// The extensions run for seconds and have their own timeouts; a
    /// liveness check would only add a second way to drop their session.
    @Test func onlyTheAppChecksLiveness() {
        #expect(XMPPSession.Policy.app.verifiesLiveness)
        #expect(!XMPPSession.Policy.notificationService.verifiesLiveness)
        #expect(!XMPPSession.Policy.share.verifiesLiveness)
    }

    /// A session that isn't connected is already connecting or reconnecting.
    @Test func disconnectedSessionIsLeftAlone() throws {
        let session = try makeSession(JID("alice@localhost")!)
        session.verifyConnection(timeout: 0.1)
        session.setActive(true)
        #expect(session.state.value == .disconnected(error: nil))
    }
}
