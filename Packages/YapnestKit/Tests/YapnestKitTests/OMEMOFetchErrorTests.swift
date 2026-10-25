import Foundation
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!

private func isListRequest(_ iq: Iq, of jid: YapnestKit.JID) -> Bool {
    iq.to?.bareJid.stringValue == jid.description
        && iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") == OMEMOModule.DEVICES_LIST_NODE
}

/// Our own list, which is read along with theirs, is not there; the answer for
/// alice's is the test's. Anything else is left unanswered.
private func answeringLists(_ iq: Iq, ofAlice answer: (Iq) -> Iq?) -> Iq? {
    if isListRequest(iq, of: alice) { return answer(iq) }
    guard isListRequest(iq, of: me) else { return nil }
    return FakeWire.error(to: iq)
}

private func module(writingTo wire: FakeWire, publishing: Bool = true) throws -> (OMEMOEncryption, XMPPClient) {
    let encryption = try OMEMOEncryption(database: try AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
    encryption.module.publishesKeys = publishing
    let client = XMPPClient()
    client.connectionConfiguration.userJid = BareJID(me.description)
    client.writer = wire
    _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
    _ = client.modulesManager.register(PubSubModule())
    _ = client.modulesManager.register(encryption.module)
    return (encryption, client)
}

/// What a server answering for a contact's device list does with the error's
/// type, which decides whether the user hears of it or it is tried again.
struct OMEMOFetchErrorTests {
    typealias Outcome = Result<(Martin.Message, OMEMODevice.Trust), OMEMOEncryption.EncryptError>

    private func encrypt(listAnswer: @escaping @Sendable (Iq) -> Iq?) async throws -> Outcome {
        try await encryptWire(answering: { answeringLists($0, ofAlice: listAnswer) })
    }

    private func encryptWire(answering: @escaping @Sendable (Iq) -> Iq?) async throws -> Outcome {
        let wire = FakeWire()
        wire.answer(answering)
        let (encryption, client) = try module(writingTo: wire)
        let stanza = Martin.Message()
        stanza.to = JID(alice.description)
        stanza.body = "hi"
        return await Task.detached { withExtendedLifetime(client) { encryption.encrypt(stanza, for: [alice]) } }.value
    }

    private func fetchError(_ result: Outcome) -> (YapnestKit.JID, ServerError)? {
        if case .failure(.fetchFailed(let peer, let error)) = result { return (peer, error) }
        return nil
    }

    @Test func aListRequestThatTimesOutPassesAndIsNotALackOfOMEMO() async throws {
        let result = try await encrypt { FakeWire.error(to: $0, condition: "remote-server-timeout", type: "wait") }
        let (peer, error) = try #require(fetchError(result))
        #expect(peer == alice)
        #expect(error.isPassing)
        if case .failure(let failure) = result { #expect(failure.isPassing) }
    }

    @Test func anInternalErrorOfTheirServerPasses() async throws {
        let result = try await encrypt { FakeWire.error(to: $0, condition: "internal-server-error", type: "wait") }
        #expect(fetchError(result)?.1.isPassing == true)
    }

    @Test func aFinalRefusalIsShownWithTheServersReason() async throws {
        let result = try await encrypt { FakeWire.error(to: $0, condition: "remote-server-not-found", type: "cancel") }
        let (_, error) = try #require(fetchError(result))
        #expect(!error.isPassing)
        guard case .failure(let failure) = result else { Issue.record("it was encrypted"); return }
        #expect(failure.localizedDescription.contains("remote-server-not-found"))
    }

    @Test func noListAtAllIsStillALackOfOMEMO() async throws {
        let result = try await encrypt { FakeWire.error(to: $0, condition: "item-not-found") }
        guard case .failure(.unsupported(let peer)) = result else { Issue.record("not unsupported"); return }
        #expect(peer == alice)
    }

    @Test func aServerWithoutPEPIsALackOfOMEMO() async throws {
        let result = try await encrypt { FakeWire.error(to: $0, condition: "service-unavailable") }
        guard case .failure(.unsupported) = result else { Issue.record("not unsupported"); return }
    }

    @Test func aBundleRequestThatTimesOutPassesAndIsNotASetupFailure() async throws {
        let result = try await encryptWire(answering: { iq in
            let node = iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.getAttribute("node") ?? ""
            guard node == OMEMOModule.DEVICES_LIST_NODE else { return FakeWire.error(to: iq, condition: "remote-server-timeout", type: "wait") }
            let list = Element(name: "list", xmlns: OMEMOModule.XMLNS, children: [Element(name: "device", attributes: ["id": "4242"])])
            let item = Element(name: "item", attributes: ["id": "current"])
            item.addChild(list)
            let items = Element(name: "items", attributes: ["node": node])
            items.addChild(item)
            return FakeWire.result(to: iq, Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [items]))
        })
        let (peer, error) = try #require(fetchError(result))
        #expect(peer == alice)
        #expect(error.isPassing)
    }

    @Test func aListKeptFromStrangersIsWithheld() async throws {
        let result = try await encrypt { FakeWire.error(to: $0, condition: "forbidden", type: "auth") }
        guard case .failure(.listWithheld) = result else { Issue.record("not withheld"); return }
    }
}

/// The send path asks again for what passes, and says so only when it doesn't.
struct EncryptedSendRetryTests {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(me, database: database)
        session.connectForTesting(wire)
        session.lock.withLock { $0.retryBackoff = 0 }
        try session.setEncrypted(true, with: alice)
    }

    private func listRequests() -> Int {
        wire.written.compactMap { $0 as? Iq }.filter { isListRequest($0, of: alice) }.count
    }

    private func stored(_ message: YapnestKit.Message) throws -> YapnestKit.Message {
        try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
    }

    @Test func aListThatKeepsTimingOutIsAskedForThreeTimesBeforeTheMessageFails() async throws {
        wire.answer { iq in answeringLists(iq, ofAlice: { FakeWire.error(to: $0, condition: "remote-server-timeout", type: "wait") }) }
        let message = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        #expect(listRequests() == 3)
        let after = try stored(message)
        #expect(after.status == .failed)
        #expect(after.error?.contains("remote-server-timeout") == true)
    }

    @Test func aSetupThatTimedOutIsTriedOnce() async throws {
        session.omemo.setupTimeout = 0.2
        wire.answer { iq in answeringLists(iq, ofAlice: { _ in nil }) }
        let message = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        #expect(listRequests() == 1)
        #expect(try stored(message).status == .failed)
    }

    @Test func aListThatPassesTheSecondTimeIsNotShownAsAnError() async throws {
        let asked = OSAllocatedCounter()
        wire.answer { iq in
            answeringLists(iq, ofAlice: { asked.next() == 0 ? FakeWire.error(to: $0, condition: "internal-server-error", type: "wait") : FakeWire.error(to: $0) })
        }
        let message = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        #expect(listRequests() == 2, "asked again, not given up on the first answer")
        #expect(try stored(message).error?.contains("internal-server-error") != true)
    }

    @Test func aFinalRefusalIsNotAskedAgain() async throws {
        wire.answer { iq in answeringLists(iq, ofAlice: { FakeWire.error(to: $0, condition: "remote-server-not-found", type: "cancel") }) }
        let message = try session.send("hi", to: alice)
        session.drainSendQueue(alice)
        #expect(listRequests() == 1)
        #expect(try stored(message).status == .failed)
    }
}

struct OMEMOPublishOptionsTests {
    @Test func publishOptionsNameTheirForm() {
        let form = OMEMOModule.openPublishOptions().element(type: .submit, onlyModified: true)
        let fields = form.filterChildren(name: "field", xmlns: nil)
        let types = fields.filter { $0.getAttribute("var") == "FORM_TYPE" }
        #expect(types.count == 1)
        #expect(types.first?.firstChild(name: "value")?.value == "http://jabber.org/protocol/pubsub#publish-options")
        let access = fields.first { $0.getAttribute("var") == "pubsub#access_model" }
        #expect(access?.firstChild(name: "value")?.value == "open")
    }
}

/// The extensions read the keys the app stored and publish nothing.
struct ExtensionOMEMOPublishTests {
    @Test func onlyTheAppPublishesKeys() {
        #expect(XMPPSession.Policy.app.publishesOMEMOKeys)
        #expect(!XMPPSession.Policy.notificationService.publishesOMEMOKeys)
        #expect(!XMPPSession.Policy.share.publishesOMEMOKeys)
    }

    @Test func aSessionTakesItsModulesPermissionFromItsPolicy() throws {
        let share = try XMPPSession(credentials: .init(jid: me, password: "x"), resource: "t", database: try AppDatabase.inMemory(), mode: .share)
        #expect(!share.omemoModuleForTesting.publishesKeys)
        #expect(try makeSession(me).omemoModuleForTesting.publishesKeys)
    }

    @Test func aModuleThatMayNotPublishWritesNothingWhenPEPAppears() async throws {
        let wire = FakeWire()
        let (encryption, client) = try module(writingTo: wire, publishing: false)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        encryption.module.resumeRegistrationIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(wire.written.isEmpty)
        #expect(!encryption.module.isReady)
    }

    @Test func aModuleThatMayNotPublishStillRepublishesAfterUsingAPrekey() async throws {
        let wire = FakeWire()
        let (encryption, client) = try module(writingTo: wire, publishing: false)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(wire.written.isEmpty)

        encryption.module.publishDeviceBundleIfNeeded(completionHandler: nil, afterPreKeyUse: true)

        #expect(await eventually { !wire.written.isEmpty })
    }

    @Test func theSameModuleDoesPublishWhenItMay() async throws {
        let wire = FakeWire()
        let (encryption, client) = try module(writingTo: wire)
        defer { withExtendedLifetime(client) {} }
        encryption.module.isPepAvailable = true
        #expect(await eventually { !wire.written.isEmpty })
    }
}
