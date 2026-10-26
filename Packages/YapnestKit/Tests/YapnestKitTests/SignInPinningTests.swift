import CryptoKit
import Foundation
import Martin
import Testing
@testable import Martin
@testable import YapnestKit

private final class RecordingWriter: PacketWriter {
    private let lock = NSLock()
    private var _written: [Stanza] = []
    var written: [Stanza] { lock.withLock { _written } }

    func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
    func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) {
        lock.withLock { _written.append(stanza) }
    }
}

private func element(_ name: String, _ xmlns: String, _ attributes: [String: String] = [:], _ children: [Element] = []) -> Element {
    let e = Element(name: name, xmlns: xmlns)
    for (k, v) in attributes { e.setAttribute(k, value: v) }
    for c in children { e.addChild(c) }
    return e
}

private func hmac(_ token: String, _ label: String, _ bindingData: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + bindingData, using: SymmetricKey(data: Data(token.utf8))))
}

private let exporter = Data(repeating: 0xE1, count: 32)
private let endPoint = Data(repeating: 0xE2, count: 32)
private let both = ChannelBindings(exporter: exporter, serverEndPoint: endPoint)
private let endPointOnly = ChannelBindings(serverEndPoint: endPoint)

/// HT-SHA-256-NONE, -EXPR and -ENDP: what each proof covers.
struct HTMechanismTests {
    private func client() -> XMPPClient {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.credentials = .password(password: "secret")
        client.connectionConfiguration.disableTLS = true
        return client
    }

    @Test(arguments: [
        (HTMechanism.sha256None, Data()),
        (HTMechanism.sha256Expr, exporter),
        (HTMechanism.sha256Endp, endPoint),
    ])
    func proofsCoverTheBindingData(mechanism: String, bindingData: Data) throws {
        let ht = HTMechanism(token: "tok", mechanism: mechanism, bindings: both)
        let client = client()
        let initial = try #require(try ht.evaluateChallenge(nil, context: client))
        #expect(Data(base64Encoded: initial) == Data("alice".utf8) + Data([0]) + hmac("tok", "Initiator", bindingData))

        _ = try ht.evaluateChallenge(hmac("tok", "Responder", bindingData).base64EncodedString(), context: client)
        #expect(ht.status == .completed)
    }

    @Test(arguments: [HTMechanism.sha256None, HTMechanism.sha256Expr, HTMechanism.sha256Endp])
    func theServersProofIsRefusedForOtherBindingData(mechanism: String) throws {
        let ht = HTMechanism(token: "tok", mechanism: mechanism, bindings: both)
        let client = client()
        _ = try ht.evaluateChallenge(nil, context: client)
        // The right token, but proven on another connection (or, for NONE, with data it doesn't cover).
        let wrong = hmac("tok", "Responder", Data(repeating: 9, count: 32)).base64EncodedString()
        #expect(throws: ClientSaslException.self) { try ht.evaluateChallenge(wrong, context: client) }
        #expect(ht.status != .completed)
    }

    @Test func aBoundVariantNeedsItsBindingData() throws {
        let client = client()
        #expect(!HTMechanism(token: "t", mechanism: HTMechanism.sha256Expr, bindings: endPointOnly).isAllowedToUse(client))
        #expect(HTMechanism(token: "t", mechanism: HTMechanism.sha256Endp, bindings: endPointOnly).isAllowedToUse(client))
        #expect(HTMechanism(token: "t", mechanism: HTMechanism.sha256None, bindings: ChannelBindings()).isAllowedToUse(client))
        #expect(throws: ClientSaslException.self) {
            try HTMechanism(token: "t", mechanism: HTMechanism.sha256Expr, bindings: endPointOnly).evaluateChallenge(nil, context: client)
        }
    }

    @Test func theStrongestBindableVariantIsChosen() {
        let offered = [HTMechanism.sha256None, HTMechanism.sha256Endp, HTMechanism.sha256Expr, "HT-SHA-256-UNIQ"]
        #expect(HTMechanism.strongest(in: offered, bindings: both) == HTMechanism.sha256Expr)
        #expect(HTMechanism.strongest(in: offered, bindings: endPointOnly) == HTMechanism.sha256Endp)
        #expect(HTMechanism.strongest(in: offered, bindings: ChannelBindings()) == HTMechanism.sha256None)
        #expect(HTMechanism.strongest(in: [HTMechanism.sha256Expr], bindings: endPointOnly) == nil)
    }
}

/// Which mechanisms rank where, and when a sign-in is refused.
struct SignInPinningRulesTests {
    @Test func mechanismsAreRankedByWhatTheyProtect() {
        #expect(SignInTier(mechanism: "SCRAM-SHA-256-PLUS") == .bound)
        #expect(SignInTier(mechanism: "SCRAM-SHA-1-PLUS") == .bound)
        #expect(SignInTier(mechanism: "HT-SHA-256-EXPR") == .bound)
        #expect(SignInTier(mechanism: "HT-SHA-256-ENDP") == .bound)
        #expect(SignInTier(mechanism: "SCRAM-SHA-256") == .scram)
        #expect(SignInTier(mechanism: "SCRAM-SHA-1") == .scram)
        #expect(SignInTier(mechanism: "HT-SHA-256-NONE") == .scram)
        #expect(SignInTier(mechanism: "PLAIN") == .plain)
        #expect(SignInTier(mechanism: "ANONYMOUS") == nil)
    }

    @Test func aSignInBelowTheRecordIsRefused() {
        #expect(SignInPinning.refusal(chosen: "PLAIN", recorded: "SCRAM-SHA-256-PLUS") == WeakerSignInError(recorded: "SCRAM-SHA-256-PLUS", offered: "PLAIN"))
        #expect(SignInPinning.refusal(chosen: "SCRAM-SHA-256", recorded: "SCRAM-SHA-256-PLUS") != nil)
        #expect(SignInPinning.refusal(chosen: "HT-SHA-256-NONE", recorded: "HT-SHA-256-EXPR") != nil)
        #expect(SignInPinning.refusal(chosen: "PLAIN", recorded: "SCRAM-SHA-1") != nil)
    }

    @Test func aSignInAtOrAboveTheRecordIsAllowed() {
        #expect(SignInPinning.refusal(chosen: "PLAIN", recorded: nil) == nil)
        #expect(SignInPinning.refusal(chosen: "PLAIN", recorded: "PLAIN") == nil)
        #expect(SignInPinning.refusal(chosen: "SCRAM-SHA-1", recorded: "SCRAM-SHA-256") == nil)
        #expect(SignInPinning.refusal(chosen: "SCRAM-SHA-256-PLUS", recorded: "SCRAM-SHA-256") == nil)
        #expect(SignInPinning.refusal(chosen: "HT-SHA-256-ENDP", recorded: "SCRAM-SHA-256-PLUS") == nil)
    }

    @Test func theRecordOnlyRises() {
        #expect(SignInPinning.recording(succeeded: "PLAIN", recorded: nil) == "PLAIN")
        #expect(SignInPinning.recording(succeeded: "SCRAM-SHA-256", recorded: "PLAIN") == "SCRAM-SHA-256")
        #expect(SignInPinning.recording(succeeded: "SCRAM-SHA-256-PLUS", recorded: "SCRAM-SHA-256") == "SCRAM-SHA-256-PLUS")
        #expect(SignInPinning.recording(succeeded: "SCRAM-SHA-1", recorded: "SCRAM-SHA-256") == nil)
        #expect(SignInPinning.recording(succeeded: "PLAIN", recorded: "SCRAM-SHA-256-PLUS") == nil)
        #expect(SignInPinning.recording(succeeded: "SCRAM-SHA-256-PLUS", recorded: "HT-SHA-256-EXPR") == nil)
        #expect(SignInPinning.recording(succeeded: "ANONYMOUS", recorded: nil) == nil)
    }

    @Test func theMessageNamesBothMechanisms() {
        let message = WeakerSignInError(recorded: "SCRAM-SHA-256-PLUS", offered: "PLAIN").localizedDescription
        #expect(message.contains("PLAIN instead of SCRAM-SHA-256-PLUS"))
    }

    @Test func recordsAreKeptPerStore() {
        let store = MemorySignInRecordStore()
        #expect(store.load() == nil)
        store.save("PLAIN")
        #expect(store.load() == "PLAIN")
        store.save(nil)
        #expect(store.load() == nil)
    }

    /// The extension may have read the record before the app raised it.
    @Test func aSignInRaisesTheStoredRecordButNeverLowersIt() {
        let store = MemorySignInRecordStore("SCRAM-SHA-256-PLUS")
        XMPPSession.raise(store, to: "SCRAM-SHA-256")
        #expect(store.load() == "SCRAM-SHA-256-PLUS")
        let plain = MemorySignInRecordStore("PLAIN")
        XMPPSession.raise(plain, to: "HT-SHA-256-EXPR")
        #expect(plain.load() == "HT-SHA-256-EXPR")
    }
}

/// SASL2's choice of mechanism and token, and the pinning, on stanzas the
/// test writes into the module.
struct Sasl2PinningTests {
    private final class Setup {
        let client = XMPPClient()
        let writer = RecordingWriter()
        let features: StreamFeaturesModule
        let sasl2: Sasl2Module
        var recordChanges: [String] = []
        var tokenChanges: [Sasl2Module.FastToken?] = []

        init(record: String? = nil, token: Sasl2Module.FastToken? = nil, bindings: ChannelBindings = ChannelBindings()) {
            client.connectionConfiguration.userJid = BareJID("alice@localhost")
            client.connectionConfiguration.credentials = .password(password: "secret")
            // The test has no TLS for PLAIN and tokens to go over.
            client.connectionConfiguration.disableTLS = true
            client.writer = writer
            features = client.modulesManager.register(StreamFeaturesModule())
            _ = client.modulesManager.register(AuthModule())
            sasl2 = client.modulesManager.register(Sasl2Module())
            sasl2.userAgent = .init(id: "agent")
            sasl2.signInRecord = record
            sasl2.fastToken = token
            sasl2.channelBindingsOverride = bindings
            sasl2.signInRecordChanged = { [unowned self] in recordChanges.append($0) }
            sasl2.tokenChanged = { [unowned self] in tokenChanges.append($0) }
        }

        func offer(_ mechanisms: [String], fast: [String] = []) {
            var children = mechanisms.map { Element(name: "mechanism", cdata: $0) }
            if !fast.isEmpty {
                children.append(element("inline", "urn:xmpp:sasl:2", [:], [
                    element("fast", "urn:xmpp:fast:0", [:], fast.map { Element(name: "mechanism", cdata: $0) }),
                ]))
            }
            let features = Element(name: "features", xmlns: "http://etherx.jabber.org/streams")
            features.addChild(element("authentication", "urn:xmpp:sasl:2", [:], children))
            self.features.setStreamFeatures(features)
        }

        var authenticate: Stanza? { writer.written.first { $0.name == "authenticate" } }
        var requestedToken: String? { authenticate?.findChild(name: "request-token")?.getAttribute("mechanism") }

        func success(token: String? = nil) {
            let success = element("success", "urn:xmpp:sasl:2")
            if let token {
                success.addChild(element("token", "urn:xmpp:fast:0", ["token": token, "expiry": "2099-01-01T00:00:00Z"]))
            }
            try? sasl2.process(stanza: Stanza.from(element: success))
        }
    }

    private func storedToken(_ mechanism: String) -> Sasl2Module.FastToken {
        .init(mechanism: mechanism, token: "tok", expiry: Date().addingTimeInterval(3600))
    }

    // MARK: Binding the token

    @Test func requestsTheStrongestVariantTheConnectionCanBind() {
        let all = [HTMechanism.sha256None, HTMechanism.sha256Endp, HTMechanism.sha256Expr]
        let withExporter = Setup(bindings: both)
        withExporter.offer(["PLAIN"], fast: all)
        withExporter.sasl2.login()
        #expect(withExporter.requestedToken == HTMechanism.sha256Expr)

        // TLS 1.2 gives no exporter.
        let withoutExporter = Setup(bindings: endPointOnly)
        withoutExporter.offer(["PLAIN"], fast: all)
        withoutExporter.sasl2.login()
        #expect(withoutExporter.requestedToken == HTMechanism.sha256Endp)

        let unbound = Setup()
        unbound.offer(["PLAIN"], fast: all)
        unbound.sasl2.login()
        #expect(unbound.requestedToken == HTMechanism.sha256None)
    }

    @Test func requestsNothingTheConnectionCannotBind() {
        let setup = Setup(bindings: endPointOnly)
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256Expr])
        setup.sasl2.login()
        #expect(setup.authenticate != nil)
        #expect(setup.requestedToken == nil)
    }

    @Test func storesTheTokenWithTheMechanismItWasRequestedFor() {
        let setup = Setup(bindings: both)
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256None, HTMechanism.sha256Expr])
        setup.sasl2.login()
        setup.success(token: "new")
        #expect(setup.tokenChanges.compactMap { $0?.mechanism } == [HTMechanism.sha256Expr])
        #expect(setup.sasl2.fastToken?.token == "new")
    }

    @Test func signsInWithTheStoredTokenAsItsOwnMechanism() throws {
        let setup = Setup(token: storedToken(HTMechanism.sha256Endp), bindings: both)
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256Expr, HTMechanism.sha256Endp])
        setup.sasl2.login()
        let authenticate = try #require(setup.authenticate)
        #expect(authenticate.getAttribute("mechanism") == HTMechanism.sha256Endp)
        #expect(authenticate.findChild(name: "fast") != nil)
        let initial = try #require(authenticate.findChild(name: "initial-response")?.value)
        #expect(Data(base64Encoded: initial) == Data("alice".utf8) + Data([0]) + hmac("tok", "Initiator", endPoint))
    }

    @Test func aStoredNoneTokenStillSignsIn() {
        let setup = Setup(token: storedToken(HTMechanism.sha256None), bindings: both)
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256None, HTMechanism.sha256Expr])
        setup.sasl2.login()
        #expect(setup.authenticate?.getAttribute("mechanism") == HTMechanism.sha256None)
    }

    @Test func aStoredBoundTokenWithoutItsBindingDataSignsInWithThePassword() {
        let setup = Setup(token: storedToken(HTMechanism.sha256Expr), bindings: endPointOnly)
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256Expr, HTMechanism.sha256Endp])
        setup.sasl2.login()
        #expect(setup.authenticate?.getAttribute("mechanism") == "PLAIN")
        #expect(setup.authenticate?.findChild(name: "fast") == nil)
        // And asks for a token this connection can use.
        #expect(setup.requestedToken == HTMechanism.sha256Endp)
    }

    @Test func aStoredTokenTheServerNoLongerListsIsNotUsed() {
        let setup = Setup(token: storedToken(HTMechanism.sha256Expr), bindings: both)
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256None])
        setup.sasl2.login()
        #expect(setup.authenticate?.getAttribute("mechanism") == "PLAIN")
    }

    // MARK: Pinning

    @Test func aServerThatOffersOnlyPlainAfterABoundSignInIsRefusedBeforeAnythingIsSent() {
        let setup = Setup(record: "SCRAM-SHA-256-PLUS")
        setup.offer(["PLAIN"])
        setup.sasl2.login()
        #expect(setup.writer.written.isEmpty)
        guard case .error(let error) = setup.sasl2.state else {
            Issue.record("state is \(setup.sasl2.state)")
            return
        }
        #expect(error as? WeakerSignInError == WeakerSignInError(recorded: "SCRAM-SHA-256-PLUS", offered: "PLAIN"))
    }

    @Test func onlyUnboundScramAfterABoundSignInIsRefusedToo() {
        let setup = Setup(record: "SCRAM-SHA-256-PLUS")
        setup.offer(["SCRAM-SHA-256", "SCRAM-SHA-1", "PLAIN"])
        setup.sasl2.login()
        #expect(setup.writer.written.isEmpty)
        guard case .error(let error) = setup.sasl2.state else {
            Issue.record("state is \(setup.sasl2.state)")
            return
        }
        #expect((error as? WeakerSignInError)?.offered == "SCRAM-SHA-256")
    }

    @Test func plainIsStillAllowedAfterPlainOnlyHistory() {
        let setup = Setup(record: "PLAIN")
        setup.offer(["PLAIN"])
        setup.sasl2.login()
        #expect(setup.authenticate?.getAttribute("mechanism") == "PLAIN")
    }

    @Test func theFirstSignInWithoutARecordMayUsePlain() {
        let setup = Setup()
        setup.offer(["PLAIN"])
        setup.sasl2.login()
        #expect(setup.authenticate?.getAttribute("mechanism") == "PLAIN")
    }

    @Test func aNoneTokenIsNotUsedOnceBoundIsRecorded() {
        let setup = Setup(record: "SCRAM-SHA-256-PLUS", token: storedToken(HTMechanism.sha256None))
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256None])
        setup.sasl2.login()
        #expect(setup.writer.written.isEmpty)
        guard case .error(let error) = setup.sasl2.state else {
            Issue.record("state is \(setup.sasl2.state)")
            return
        }
        #expect(error is WeakerSignInError)
    }

    @Test func aNoneTokenIsUsedWhileOnlyScramIsRecorded() {
        let setup = Setup(record: "SCRAM-SHA-256", token: storedToken(HTMechanism.sha256None))
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256None])
        setup.sasl2.login()
        #expect(setup.authenticate?.getAttribute("mechanism") == HTMechanism.sha256None)
    }

    @Test func theRecordRisesOnSuccessAndNotOnAnAttempt() {
        let setup = Setup()
        setup.offer(["PLAIN"])
        setup.sasl2.login()
        #expect(setup.recordChanges.isEmpty)
        #expect(setup.sasl2.signInRecord == nil)

        setup.success()
        #expect(setup.recordChanges == ["PLAIN"])
        #expect(setup.sasl2.signInRecord == "PLAIN")
    }

    @Test func aRefusedTokenLeavesTheRecordAlone() throws {
        let setup = Setup(record: "SCRAM-SHA-256", token: storedToken(HTMechanism.sha256None))
        setup.offer(["PLAIN"], fast: [HTMechanism.sha256None])
        setup.sasl2.login()
        try setup.sasl2.process(stanza: Stanza.from(element: element("failure", "urn:xmpp:sasl:2", [:], [
            element("not-authorized", "urn:ietf:params:xml:ns:xmpp-sasl"),
        ])))
        #expect(setup.recordChanges.isEmpty)
        #expect(setup.sasl2.signInRecord == "SCRAM-SHA-256")
    }
}

/// The same pinning for servers without SASL2.
struct SaslPinningTests {
    private final class NullWriter: PacketWriter {
        private let lock = NSLock()
        private var count = 0
        var writes: Int { lock.withLock { count } }
        func write<Failure: Error>(_ iq: Iq, timeout: TimeInterval, errorDecoder: @escaping PacketErrorDecoder<Failure>, completionHandler: ((Result<Iq, Failure>) -> Void)?) {}
        func write(_ stanza: Stanza, writeCompleted: ((Result<Void, XMPPError>) -> Void)?) { lock.withLock { count += 1 } }
    }

    /// The client comes back too: the module holds it weakly.
    private func sasl(record: String?, offering mechanisms: [String]) -> (SaslModule, NullWriter, XMPPClient) {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID("alice@localhost")
        client.connectionConfiguration.credentials = .password(password: "secret")
        client.connectionConfiguration.disableTLS = true
        let writer = NullWriter()
        client.writer = writer
        let features = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        let sasl = client.modulesManager.register(SaslModule())
        sasl.signInRecord = record
        let element = Element(name: "features", xmlns: "http://etherx.jabber.org/streams")
        element.addChild(Martin.Element(name: "mechanisms", xmlns: "urn:ietf:params:xml:ns:xmpp-sasl"))
        for mechanism in mechanisms {
            element.findChild(name: "mechanisms")?.addChild(Element(name: "mechanism", cdata: mechanism))
        }
        features.setStreamFeatures(element)
        return (sasl, writer, client)
    }

    @Test func aServerThatOffersOnlyPlainAfterABoundSignInIsRefusedBeforeAnythingIsSent() {
        let (sasl, writer, client) = sasl(record: "SCRAM-SHA-256-PLUS", offering: ["PLAIN"])
        sasl.login()
        #expect(writer.writes == 0)
        #expect(sasl.lastMechanism == nil)
        guard case .error(let error) = sasl.state else {
            Issue.record("state is \(sasl.state)")
            return
        }
        #expect(error as? WeakerSignInError == WeakerSignInError(recorded: "SCRAM-SHA-256-PLUS", offered: "PLAIN"))
        withExtendedLifetime(client) {}
    }

    @Test func plainIsStillAllowedAfterPlainOnlyHistoryAndWithoutARecord() {
        for record in [nil, "PLAIN"] {
            let (sasl, writer, client) = sasl(record: record, offering: ["PLAIN"])
            sasl.login()
            #expect(writer.writes == 1)
            #expect(sasl.lastMechanism == "PLAIN")
            withExtendedLifetime(client) {}
        }
    }

    @Test func theRecordRisesWhenTheSignInSucceeds() throws {
        let (sasl, _, client) = sasl(record: nil, offering: ["PLAIN"])
        var changes: [String] = []
        sasl.signInRecordChanged = { changes.append($0) }
        sasl.login()
        #expect(changes.isEmpty)
        try sasl.process(stanza: Stanza.from(element: Element(name: "success", xmlns: "urn:ietf:params:xml:ns:xmpp-sasl")))
        #expect(changes == ["PLAIN"])
        withExtendedLifetime(client) {}
    }
}
