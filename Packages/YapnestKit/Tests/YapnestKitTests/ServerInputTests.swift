import Foundation
import Martin
import Testing
@testable import Martin

/// What the SASL and stream management modules do with input a server
/// shouldn't send. None of it may trap.
@Suite struct ServerInputTests {
    private final class NullWriter: PacketWriter {
        func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
        func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {}
    }

    private func client() -> XMPPClient {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.credentials = .password(password: "secret")
        client.writer = NullWriter()
        _ = client.modulesManager.register(StreamFeaturesModule())
        return client
    }

    @Test func unsolicitedSaslSuccessFailsAuthentication() throws {
        let client = client()
        _ = client.modulesManager.register(AuthModule())
        let sasl = client.modulesManager.register(SaslModule())
        try sasl.process(stanza: Stanza(elem: Element(name: "success", xmlns: "urn:ietf:params:xml:ns:xmpp-sasl")))
        guard case .error = sasl.state else {
            Issue.record("state is \(sasl.state)")
            return
        }
    }

    @Test func resumedWithoutCountDoesNotTrap() {
        let client = client()
        let sm = client.modulesManager.register(StreamManagementModule())
        sm.processResumed(Stanza(elem: Element(name: "resumed", xmlns: "urn:xmpp:sm:3")))
    }

    private func firstChallenge(iterations: String) throws -> (ScramMechanism, Context) {
        let client = client()
        let scram = ScramMechanism.ScramSha1()
        _ = try scram.evaluateChallenge(nil, context: client)
        return (scram, client)
    }

    @Test(arguments: ["0", "-3", "99999999999", "1000001"])
    func scramRefusesUnreasonableIterationCounts(iterations: String) throws {
        let (scram, client) = try firstChallenge(iterations: iterations)
        let challenge = Data("r=abc,s=c2FsdA==,i=\(iterations)".utf8).base64EncodedString()
        #expect(throws: ClientSaslException.self) { try scram.evaluateChallenge(challenge, context: client) }
    }

    @Test func scramRefusesChallengeThatIsNotUTF8() throws {
        let (scram, client) = try firstChallenge(iterations: "4096")
        let challenge = Data([0xff, 0xfe, 0xfd]).base64EncodedString()
        #expect(throws: ClientSaslException.self) { try scram.evaluateChallenge(challenge, context: client) }
    }

    @Test func plainAndFastTokensAreNotSentInTheClear() {
        let client = client()
        let token = HTMechanism(token: "t")
        #expect(!PlainMechanism().isAllowedToUse(client))
        #expect(!token.isAllowedToUse(client))
        #expect(ScramMechanism.ScramSha1().isAllowedToUse(client))
        // A local development server, with TLS turned off on purpose.
        client.connectionConfiguration.disableTLS = true
        #expect(PlainMechanism().isAllowedToUse(client))
        #expect(token.isAllowedToUse(client))
    }
}
