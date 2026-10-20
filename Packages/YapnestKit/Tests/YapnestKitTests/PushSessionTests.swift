import Foundation
import Martin
import Testing
@testable import YapnestKit

/// Push settings and stanzas, which need no connection.
struct PushSessionTests {
    let database: AppDatabase
    let session: XMPPSession

    init() throws {
        database = try AppDatabase.inMemory()
        session = try makeSession(JID("me@example.org")!, database: database)
    }

    @Test func tokenIsStoredAsHexWithItsEnvironment() throws {
        session.setPushToken(Data([0x01, 0xab, 0xff]), sandbox: true)
        #expect(try database.setting(.pushToken) == "01abff")
        #expect(try database.setting(.pushEnvironment) == "sandbox")
        session.setPushToken(Data([0x02]), sandbox: false)
        #expect(try database.setting(.pushToken) == "02")
        #expect(try database.setting(.pushEnvironment) == "production")
    }

    @Test func disablingOfflineKeepsTheNodeForTheNextSession() async throws {
        try database.setSetting(.pushRelay, "push.example.org")
        try database.setSetting(.pushNode, "node-1")
        await session.disablePush()
        #expect(try database.setting(.pushRelay) == "push.example.org")
        #expect(try database.setting(.pushNode) == "node-1")
    }

    @Test func enableAndDisableNameTheRelayAndNode() throws {
        let relay = JID("push.example.org")!
        for action in ["enable", "disable"] {
            let iq = XMPPSession.pushIq(action, relay: relay, node: "n1")
            #expect(iq.type == .set)
            let element = try #require(iq.firstChild(name: action, xmlns: "urn:xmpp:push:0"))
            #expect(element.getAttribute("jid") == "push.example.org")
            #expect(element.getAttribute("node") == "n1")
        }
    }

    // MARK: Against a stand-in for the server

    private let wire = FakeWire()
    private let relay = XMPPSession.defaultPushRelay

    /// Connects, with a server that advertises push.
    private func connect(syncing: Bool = false) {
        session.connectForTesting(wire, syncing: syncing)
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
                result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
                return FakeWire.result(to: iq, result)
            }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "feature", attributes: ["var": NS.push]))
            return FakeWire.result(to: iq, query)
        }
        // The discovery would otherwise start a catch-up of its own.
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind()
        session.client.module(.disco).discoverAccountFeatures(completionHandler: nil)
    }

    /// The server's answers: the relay hands out `node`, and our server
    /// either accepts the enable or refuses it.
    private func serve(node: String, enableSucceeds: Bool, disable: DisableAnswer = .succeeds) {
        wire.answer { iq in
            if iq.firstChild(name: "command", xmlns: NS.commands) != nil {
                let field = Element(name: "field", attributes: ["var": "node"])
                field.addChild(Element(name: "value", cdata: node))
                let form = Element(name: "x", xmlns: NS.dataForms)
                form.addChild(field)
                let command = Element(name: "command", xmlns: NS.commands)
                command.addChild(form)
                return FakeWire.result(to: iq, command)
            }
            if iq.firstChild(name: "disable", xmlns: NS.push) != nil {
                switch disable {
                case .succeeds: return FakeWire.result(to: iq)
                case .lost: return nil
                case .fails(let condition): return FakeWire.error(to: iq, condition: condition)
                }
            }
            if iq.firstChild(name: "enable", xmlns: NS.push) != nil, !enableSucceeds { return FakeWire.error(to: iq, condition: "internal-server-error") }
            return FakeWire.result(to: iq)
        }
    }

    private enum DisableAnswer { case succeeds, lost, fails(String) }

    private func pushStanzas(_ action: String) -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: action, xmlns: NS.push) != nil }
    }

    private func storeOldNode() throws {
        try database.setSetting(.pushToken, "01")
        try database.setSetting(.pushEnvironment, "sandbox")
        try database.setSetting(.pushRelay, "old.example.org")
        try database.setSetting(.pushNode, "old-node")
    }

    @Test func aRefusedEnableLeavesTheOldNodeEnabledAndStored() throws {
        try storeOldNode()
        connect()
        serve(node: "new-node", enableSucceeds: false)
        session.setPushToken(Data([0x02]), sandbox: true)

        #expect(pushStanzas("enable").count == 1)
        #expect(pushStanzas("disable").isEmpty)
        #expect(try database.setting(.pushRelay) == "old.example.org")
        #expect(try database.setting(.pushNode) == "old-node")
    }

    @Test func aConfirmedEnableDisablesTheOldNodeAndMovesTheSettings() throws {
        try storeOldNode()
        connect()
        serve(node: "new-node", enableSucceeds: true)
        session.setPushToken(Data([0x02]), sandbox: true)

        let disable = try #require(pushStanzas("disable").first?.firstChild(name: "disable", xmlns: NS.push))
        #expect(disable.getAttribute("node") == "old-node")
        #expect(disable.getAttribute("jid") == "old.example.org")
        #expect(try database.setting(.pushRelay) == relay.description)
        #expect(try database.setting(.pushNode) == "new-node")
    }

    @Test func theSameNodeAgainIsNotDisabled() throws {
        try database.setSetting(.pushToken, "02")
        try database.setSetting(.pushEnvironment, "sandbox")
        try database.setSetting(.pushRelay, relay.description)
        try database.setSetting(.pushNode, "new-node")
        connect()
        serve(node: "new-node", enableSucceeds: true)
        session.enablePush()
        #expect(pushStanzas("enable").count == 1)
        #expect(pushStanzas("disable").isEmpty)
    }

    @Test func anUnchangedTokenIsNotRegisteredAgain() throws {
        connect()
        serve(node: "n", enableSucceeds: true)
        session.setPushToken(Data([0x02]), sandbox: true)
        #expect(pushStanzas("enable").count == 1)
        session.setPushToken(Data([0x02]), sandbox: true)
        #expect(pushStanzas("enable").count == 1)
        session.setPushToken(Data([0x02]), sandbox: false)
        #expect(pushStanzas("enable").count == 2)
    }

    @Test func nothingIsRegisteredWhileOffline() throws {
        let offline = FakeWire()
        session.client.writer = offline
        session.setPushToken(Data([0x02]), sandbox: true)
        #expect(offline.written.isEmpty)
        #expect(try database.setting(.pushToken) == "02")
    }

    @Test func aTokenThatChangesWhileCatchingUpIsRegisteredWhenItEnds() throws {
        connect(syncing: true)
        serve(node: "n", enableSucceeds: true)
        session.setPushToken(Data([0x02]), sandbox: true)
        #expect(pushStanzas("enable").isEmpty)
        // The end of every catch-up enables push from what's stored.
        session.enablePush()
        #expect(pushStanzas("enable").count == 1)
    }

    @Test func aLostDisableOfTheOldNodeIsRetriedOnTheNextConnect() throws {
        try storeOldNode()
        connect()
        serve(node: "new-node", enableSucceeds: true, disable: .lost)
        session.setPushToken(Data([0x02]), sandbox: true)
        #expect(pushStanzas("disable").count == 1)

        // A new session: the same node is still owed a disable.
        let next = FakeWire()
        session.client.writer = next
        next.answer { FakeWire.result(to: $0) }
        session.enablePush()
        let retried = next.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "disable", xmlns: NS.push) != nil }
        #expect(retried.count == 1)
        #expect(retried.first?.firstChild(name: "disable")?.getAttribute("node") == "old-node")

        // Answered, so it isn't asked a third time.
        session.enablePush()
        #expect(next.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "disable", xmlns: NS.push) != nil }.count == 1)
    }

    @Test func aDisableTheServerRefusesIsRetriedButOneForAGoneNodeIsNot() throws {
        try storeOldNode()
        connect()
        serve(node: "new-node", enableSucceeds: true, disable: .fails("internal-server-error"))
        session.setPushToken(Data([0x02]), sandbox: true)
        #expect(pushStanzas("disable").count == 1)
        session.enablePush()
        #expect(pushStanzas("disable").count == 2)

        serve(node: "new-node", enableSucceeds: true, disable: .fails("item-not-found"))
        session.enablePush()
        #expect(pushStanzas("disable").count == 3)
        session.enablePush()
        #expect(pushStanzas("disable").count == 3)
    }

    @Test func signingOutDisablesTheCurrentNodeAndTheOlderOnesAndForgetsThemOnceAnswered() async throws {
        try storeOldNode()
        try database.setSetting(.pushStaleNodes, #"[{"relay":"older.example.org","node":"older-node"}]"#)
        connect()
        serve(node: "n", enableSucceeds: true)
        await session.disablePush()

        // Every disable names its node: one without would stop the account's other devices too.
        let nodes = pushStanzas("disable").map { $0.firstChild(name: "disable")?.getAttribute("node") }
        #expect(Set(nodes) == ["old-node", "older-node"])
        #expect(try database.setting(.pushNode) == nil)
        #expect(try database.setting(.pushRelay) == nil)
        #expect(try database.setting(.pushStaleNodes) == nil)
    }

    @Test func signingOutKeepsANodeTheServerRefusedToDisable() async throws {
        try storeOldNode()
        connect()
        serve(node: "n", enableSucceeds: true, disable: .fails("internal-server-error"))
        await session.disablePush()

        #expect(pushStanzas("disable").count == 1)
        #expect(try database.setting(.pushNode) == "old-node")
    }

    @Test func theCurrentNodeIsNeverDisabledEvenIfListedAsStale() throws {
        try database.setSetting(.pushToken, "02")
        try database.setSetting(.pushEnvironment, "sandbox")
        try database.setSetting(.pushRelay, relay.description)
        try database.setSetting(.pushNode, "new-node")
        try database.setSetting(.pushStaleNodes, #"[{"relay":"\#(relay.description)","node":"new-node"}]"#)
        connect()
        serve(node: "new-node", enableSucceeds: true)
        session.enablePush()
        #expect(pushStanzas("disable").isEmpty)
        #expect(try database.setting(.pushStaleNodes) == nil)
    }
}
