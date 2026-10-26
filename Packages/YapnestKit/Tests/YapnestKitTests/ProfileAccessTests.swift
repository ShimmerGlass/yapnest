import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

/// A server holding our profile nodes, each with its own access model.
private final class ProfileServer: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: String]
    private var sets: [(node: String, model: String)] = []
    private var reads = 0
    private var failure: (condition: String, type: String)?
    private var failingNodes: [String: (condition: String, type: String)] = [:]
    private var publishOptions: [String: [String]] = [:]

    init(_ models: [String: String]) { self.models = models }

    var access: [String: String] { lock.withLock { models } }
    var configured: [(node: String, model: String)] { lock.withLock { sets } }
    var configReads: Int { lock.withLock { reads } }
    var lastPublishOptions: [String: [String]] { lock.withLock { publishOptions } }
    /// Fails every configuration request this way.
    func fail(_ condition: String, type: String) { lock.withLock { failure = (condition, type) } }
    /// Fails the configuration requests that change `node`, but not reads of it.
    func failChanges(to node: String, _ condition: String, type: String) { lock.withLock { failingNodes[node] = (condition, type) } }
    func recover() { lock.withLock { failure = nil } }

    func attach(to wire: FakeWire) {
        wire.answer { [self] iq in
            lock.withLock {
                guard let pubsub = iq.firstChild(name: "pubsub") else { return nil }
                if let publish = pubsub.firstChild(name: "publish") {
                    let node = publish.attribute("node") ?? ""
                    let form = pubsub.firstChild(name: "publish-options")?.firstChild(name: "x")
                    let fields = formFields(of: form)
                    publishOptions = fields
                    if let model = fields["pubsub#access_model"]?.first { models[node] = models[node] ?? model }
                    return FakeWire.result(to: iq)
                }
                guard pubsub.xmlns == "http://jabber.org/protocol/pubsub#owner", let configure = pubsub.firstChild(name: "configure") else { return nil }
                let node = configure.attribute("node") ?? ""
                if let failure { return FakeWire.error(to: iq, condition: failure.condition, type: failure.type) }
                guard let model = models[node] else { return FakeWire.error(to: iq, condition: "item-not-found") }
                if iq.type == .get {
                    reads += 1
                    let form = XMPPSession.dataForm(type: "form", formType: "http://jabber.org/protocol/pubsub#node_config", fields: ["pubsub#access_model": [model]])
                    return FakeWire.result(to: iq, Element(name: "pubsub", xmlns: pubsub.xmlns, children: [Element(name: "configure", children: [form])]))
                }
                if let failure = failingNodes[node] { return FakeWire.error(to: iq, condition: failure.condition, type: failure.type) }
                let form = configure.firstChild(name: "x").flatMap(XDataForm.init)
                let new = form?.fields.first { $0.name == "pubsub#access_model" }?.values.first ?? ""
                sets.append((node, new))
                models[node] = new
                return FakeWire.result(to: iq)
            }
        }
    }
}

private let me = YapnestKit.JID("me@example.org")!

struct ProfileAccessTests {
    private let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    private func connect(_ server: ProfileServer) throws -> XMPPSession {
        let session = try makeSession(me, database: db)
        let wire = FakeWire()
        server.attach(to: wire)
        session.connectForTesting(wire)
        return session
    }

    private static func open(except missing: String? = nil) -> ProfileServer {
        var models = [NS.avatarData: "open", NS.avatarMetadata: "open", NS.nick: "open"]
        if let missing { models[missing] = nil }
        return ProfileServer(models)
    }

    @Test func offByDefaultClosesNodesThatWereOpen() async throws {
        let server = Self.open()
        let session = try connect(server)
        await session.reconcileProfileAccess()
        #expect(server.access == [NS.avatarData: "presence", NS.avatarMetadata: "presence", NS.nick: "presence"])
    }

    @Test func onOpensNodesThatWereClosed() async throws {
        let server = ProfileServer([NS.avatarData: "presence", NS.avatarMetadata: "presence", NS.nick: "presence"])
        let session = try connect(server)
        try db.setFlag(.sharesProfilePublicly, true)
        await session.reconcileProfileAccess()
        #expect(server.access.values.allSatisfy { $0 == "open" })
    }

    @Test func aNodeThatAlreadyMatchesIsLeftAlone() async throws {
        let server = ProfileServer([NS.avatarData: "presence", NS.avatarMetadata: "presence", NS.nick: "presence"])
        let session = try connect(server)
        await session.reconcileProfileAccess()
        #expect(server.configured.isEmpty)
        #expect(server.configReads == 3)
    }

    @Test func aNodeThatDoesNotExistIsSkippedQuietly() async throws {
        let server = Self.open(except: NS.nick)
        let session = try connect(server)
        await session.reconcileProfileAccess()
        #expect(server.access[NS.avatarData] == "presence")
        #expect(server.access[NS.avatarMetadata] == "presence")
        #expect(server.configured.count == 2)
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aFailureThatCanPassIsLeftForTheNextConnect() async throws {
        let server = Self.open()
        server.fail("remote-server-timeout", type: "wait")
        let session = try connect(server)
        await session.reconcileProfileAccess()
        #expect(session.warnings.current.isEmpty)
        server.recover()
        await session.reconcileProfileAccess()
        #expect(server.access.values.allSatisfy { $0 == "presence" })
    }

    @Test func aFinalFailureIsShownAndRetried() async throws {
        let server = Self.open()
        server.fail("forbidden", type: "auth")
        let session = try connect(server)
        await session.reconcileProfileAccess()
        let warning = try #require(session.warnings.current.first { $0.key == "profile-access" })
        server.recover()
        try await warning.retry?()
        #expect(server.access.values.allSatisfy { $0 == "presence" })
        #expect(session.warnings.current.isEmpty)
    }

    @Test func aRemoteFlipReconfiguresTheNodes() async throws {
        let server = ProfileServer([NS.avatarData: "presence", NS.avatarMetadata: "presence", NS.nick: "presence"])
        let session = try connect(server)
        let event = settingsEvent(from: nil, settingsItem(settingsEntry("sharesProfilePublicly", "1")))
        try session.client.module(.pubsub).process(message: event)
        #expect(session.sharesProfilePublicly)
        await eventually("the nodes open") { server.access.values.allSatisfy { $0 == "open" } }
    }

    @Test func switchingItOnConfiguresAtOnceAndKeepsTheSetting() async throws {
        let server = Self.open()
        let session = try connect(server)
        try await session.setSharesProfilePublicly(false)
        #expect(server.access.values.allSatisfy { $0 == "presence" })
        try await session.setSharesProfilePublicly(true)
        #expect(server.access.values.allSatisfy { $0 == "open" })
        #expect(session.sharesProfilePublicly)
    }

    @Test func aRefusalPutsTheSettingBack() async throws {
        let server = Self.open()
        server.fail("forbidden", type: "auth")
        let session = try connect(server)
        await #expect(throws: (any Error).self) { try await session.setSharesProfilePublicly(true) }
        #expect(!session.sharesProfilePublicly)
    }

    @Test func aRefusalOnOneNodeClosesTheOnesAlreadyOpened() async throws {
        let server = ProfileServer([NS.avatarData: "presence", NS.avatarMetadata: "presence", NS.nick: "presence"])
        server.failChanges(to: NS.nick, "forbidden", type: "auth")
        let session = try connect(server)
        await #expect(throws: (any Error).self) { try await session.setSharesProfilePublicly(true) }
        #expect(!session.sharesProfilePublicly)
        #expect(server.access.values.allSatisfy { $0 == "presence" })
    }

    @Test func aFailureThatCanPassKeepsTheSettingForTheNextConnect() async throws {
        let server = Self.open()
        server.fail("remote-server-timeout", type: "wait")
        let session = try connect(server)
        try await session.setSharesProfilePublicly(true)
        #expect(session.sharesProfilePublicly)
    }

    @Test func publishingAsksForTheCurrentModel() async throws {
        let server = Self.open()
        let session = try connect(server)
        try await session.setNickname("Carol")
        #expect(server.lastPublishOptions["pubsub#access_model"] == ["presence"])
        try db.setFlag(.sharesProfilePublicly, true)
        try await session.setNickname("Caroline")
        #expect(server.lastPublishOptions["pubsub#access_model"] == ["open"])
    }
}
