import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

private func node(_ name: String, _ attributes: [String: String], _ children: [Element] = []) -> Element {
    let element = Element(name: name, attributes: attributes)
    for child in children { element.addChild(child) }
    return element
}

/// A server holding the settings node, which answers the session's requests
/// as a real one would and as the odd ones do.
private final class SettingsServer: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var published: [(id: String, options: [String: [String]])] = []
    var exists: Bool
    /// The access model the node reports, and keeps whatever it is asked.
    var access: String
    var keepsAccess = false
    /// Never answers a publish that asks for `max_items=max`, like Openfire.
    var silentOnMax = false
    /// Fails a publish that asks for `max_items=max`, as Openfire does on a node with a limit.
    var failsOnMax = false
    /// The condition that failure carries.
    var maxFailure = "internal-server-error"
    /// Refuses publishing these items, whatever the options.
    var refusedIds: Set<String> = []
    /// Runs once when the items are read in pages, to have something happen during the read.
    var onItems: (() -> Void)?
    /// Runs when a publish asking for `max` goes unanswered.
    var onSilentPublish: (() -> Void)?
    var items: [(id: String, payload: Element)] = []
    /// How many items a page holds, if the server pages.
    var pageSize: Int?
    /// Refuses reading the items.
    var failsReads = false
    private(set) var created: [String: [String]]?
    private(set) var configured: [[String: [String]]] = []

    init(exists: Bool = true, access: String = "whitelist") {
        self.exists = exists
        self.access = access
    }

    var events: [String] { lock.withLock { log } }
    var publishes: [(id: String, options: [String: [String]])] { lock.withLock { published } }

    static func fields(of form: Element?) -> [String: [String]] {
        let fields = form.flatMap(XDataForm.init)?.fields ?? []
        return Dictionary(fields.compactMap { field in field.name.map { ($0, field.values) } }, uniquingKeysWith: { _, last in last })
    }

    func attach(to wire: FakeWire) {
        wire.answer { [self] in respond(to: $0) }
    }

    private func respond(to iq: Iq) -> Iq? {
        lock.withLock {
            guard let pubsub = iq.firstChild(name: "pubsub") else { return nil }
            if pubsub.xmlns == "http://jabber.org/protocol/pubsub#owner" {
                if let configure = pubsub.firstChild(name: "configure") {
                    if iq.type == .get {
                        log.append("config-get")
                        let form = XMPPSession.dataForm(type: "form", formType: "http://jabber.org/protocol/pubsub#node_config", fields: ["pubsub#access_model": [access]])
                        return FakeWire.result(to: iq, Element(name: "pubsub", xmlns: pubsub.xmlns, children: [Element(name: "configure", children: [form])]))
                    }
                    let fields = Self.fields(of: configure.firstChild(name: "x"))
                    log.append("config-set")
                    configured.append(fields)
                    if !keepsAccess, let model = fields["pubsub#access_model"]?.first { access = model }
                    return FakeWire.result(to: iq)
                }
                log.append("delete")
                return FakeWire.result(to: iq)
            }
            if let create = pubsub.firstChild(name: "create") {
                _ = create
                log.append("create")
                if exists { return FakeWire.error(to: iq, condition: "conflict") }
                exists = true
                created = Self.fields(of: pubsub.firstChild(name: "configure")?.firstChild(name: "x"))
                access = created?["pubsub#access_model"]?.first ?? "open"
                return FakeWire.result(to: iq)
            }
            if let publish = pubsub.firstChild(name: "publish") {
                let id = publish.firstChild(name: "item")?.attribute("id") ?? ""
                let options = Self.fields(of: pubsub.firstChild(name: "publish-options")?.firstChild(name: "x"))
                log.append("publish")
                published.append((id, options))
                if silentOnMax, options["pubsub#max_items"] == ["max"] {
                    onSilentPublish?()
                    return nil
                }
                if refusedIds.contains(id) { return FakeWire.error(to: iq, condition: "forbidden") }
                if failsOnMax, options["pubsub#max_items"] == ["max"] { return FakeWire.error(to: iq, condition: maxFailure) }
                if !exists { return FakeWire.error(to: iq, condition: "item-not-found") }
                return FakeWire.result(to: iq)
            }
            if let items = pubsub.firstChild(name: "items") {
                log.append("items")
                if pubsub.firstChild(name: "set") != nil, let hook = onItems {
                    onItems = nil
                    hook()
                }
                if !exists || failsReads { return failsReads ? FakeWire.error(to: iq, condition: "service-unavailable") : FakeWire.error(to: iq) }
                return FakeWire.result(to: iq, page(of: items, in: pubsub))
            }
            return nil
        }
    }

    private func page(of itemsRequest: Element, in pubsub: Element) -> Element {
        let after = pubsub.firstChild(name: "set")?.firstChild(name: "after")?.value
        var start = 0
        if let after, let index = items.firstIndex(where: { $0.id == after }) { start = index + 1 }
        let end = min(items.count, start + (pageSize ?? items.count))
        let slice = items[start..<end]
        let result = Element(name: "items", attributes: ["node": itemsRequest.attribute("node") ?? ""])
        for item in slice {
            result.addChild(node("item", ["id": item.id], [item.payload]))
        }
        let response = Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [result])
        if pageSize != nil, let first = slice.first, let last = slice.last {
            response.addChild(Element(name: "set", xmlns: "http://jabber.org/protocol/rsm", children: [
                Element(name: "first", cdata: first.id), Element(name: "last", cdata: last.id),
            ]))
        }
        return response
    }
}

/// The session's side of syncing settings, against a scripted server.
struct SettingsSyncSessionTests {
    let me = YapnestKit.JID("me@example.org")!
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func connect(_ server: SettingsServer, timeout: TimeInterval = 0.2) throws -> (XMPPSession, FakeWire) {
        let session = try makeSession(me, database: db)
        let wire = FakeWire()
        server.attach(to: wire)
        session.connectForTesting(wire)
        session.lock.withLock {
            $0.settingsSync.publishTimeout = timeout
            $0.settingsSync.settingsDelay = 0.05
        }
        return (session, wire)
    }

    private func entry(_ key: String, _ value: String?, by: String = "other") -> SettingsEntry {
        let ms = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        return SettingsEntry(key: key, value: value, version: SettingsVersion(ms: ms, counter: 0), by: by)
    }

    private func held(_ item: String) throws -> [SettingsEntry] {
        try db.reader.read { try AppDatabase.syncedEntries($0, item: item) }
    }

    private func hold(_ item: String, _ entries: SettingsEntry...) throws {
        try db.writer.write { _ = try AppDatabase.applyRemote($0, item: item, entries: entries) }
    }

    private func item(_ entries: SettingsEntry...) -> Element { SettingsItem(entries: entries).element }

    // MARK: Publishing

    @Test func aPublishCarriesTheWhitelistOptionsAfterTheConfigurationIsChecked() async throws {
        let server = SettingsServer()
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("a publish") { !server.publishes.isEmpty }
        let publish = try #require(server.publishes.first)
        #expect(publish.id == "global")
        #expect(publish.options["pubsub#access_model"] == ["whitelist"])
        #expect(publish.options["pubsub#max_items"] == ["max"])
        #expect(publish.options["pubsub#persist_items"] == ["true"])
        #expect(publish.options["pubsub#send_last_published_item"] == ["never"])
        let events = server.events
        #expect(try #require(events.firstIndex(of: "config-get")) < #require(events.firstIndex(of: "publish")))
        await eventually("the items to be published") { (try? db.pendingSyncItems().isEmpty) == true }
        #expect(try db.pendingSyncItems().isEmpty)
    }

    @Test func aLocalChangeAfterTheSyncIsPublishedWithoutAnotherSync() async throws {
        let server = SettingsServer()
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        try db.setSetting(.statusMessage, "later")
        await eventually("a publish") { !server.publishes.isEmpty }
        #expect(server.publishes.map(\.id) == ["global"])
    }

    @Test func nothingIsPublishedWhileTheNodeIsNotConfirmed() async throws {
        let server = SettingsServer()
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        session.requestSettingsPublish()
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.publishes.isEmpty)
    }

    @Test func aMissingNodeIsCreatedWithTheWhitelistBeforeTheFirstPublish() async throws {
        let server = SettingsServer(exists: false)
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("a publish") { !server.publishes.isEmpty }
        #expect(server.created?["pubsub#access_model"] == ["whitelist"])
        #expect(server.created?["pubsub#max_items"] == ["max"])
        let events = server.events
        #expect(try #require(events.firstIndex(of: "create")) < #require(events.firstIndex(of: "publish")))
        #expect(!server.publishes.isEmpty)
    }

    @Test func aNodeThatIsNotPrivateIsReconfiguredOnceThenPublishedTo() async throws {
        let server = SettingsServer(access: "open")
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("a publish") { !server.publishes.isEmpty }
        #expect(server.events.filter { $0 == "config-set" }.count == 1)
        #expect(server.access == "whitelist")
        let events = server.events
        #expect(try #require(events.lastIndex(of: "config-set")) < #require(events.firstIndex(of: "publish")))
    }

    @Test func aServerThatKeepsTheNodeOpenStopsTheSyncAndNeverDeletesIt() async throws {
        let server = SettingsServer(access: "open")
        server.keepsAccess = true
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        try db.setSetting(.statusMessage, "busier")
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.events.filter { $0 == "config-set" }.count == 1)
        #expect(server.publishes.isEmpty)
        #expect(!server.events.contains("delete"))
        // Later runs this session don't try again.
        await session.runSettingsSync()
        #expect(server.events.filter { $0 == "config-set" }.count == 1)
    }

    @Test func aPublishTheServerNeverAnswersIsRepeatedWithAnExplicitLimit() async throws {
        let server = SettingsServer()
        server.silentOnMax = true
        let (session, _) = try connect(server, timeout: 0.1)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("two publishes and nothing left to publish") { server.publishes.count >= 2 && (try? db.pendingSyncItems().isEmpty) == true }
        #expect(server.configured.last?["pubsub#max_items"] == ["1000"])
        #expect(server.publishes.last?.options["pubsub#max_items"] == nil)
        #expect(try db.pendingSyncItems().isEmpty)

        // The next one doesn't wait for a timeout again.
        try db.setSetting(.statusMessage, "busier")
        await eventually("three publishes") { server.publishes.count >= 3 }
        #expect(server.publishes.last?.options["pubsub#max_items"] == nil)
    }

    @Test func aPublishTheServerFailsForTheLimitIsRepeatedWithAnExplicitOne() async throws {
        let server = SettingsServer()
        server.failsOnMax = true
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("two publishes and nothing left to publish") { (try? db.pendingSyncItems().isEmpty) == true && server.publishes.count >= 2 }
        #expect(server.configured.last?["pubsub#max_items"] == ["1000"])
        #expect(try db.pendingSyncItems().isEmpty)
    }

    @Test func aRefusalThatIsNotAboutTheLimitDoesNotCapTheNode() async throws {
        let server = SettingsServer()
        server.failsOnMax = true
        server.maxFailure = "forbidden"
        let (session, _) = try connect(server)
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("a publish") { !server.publishes.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.configured.isEmpty)
        #expect(session.lock.withLock { !$0.settingsSync.explicitMaxItems })
        #expect(try db.pendingSyncItems().map(\.id) == ["global"])
    }

    @Test func aPublishThatTimesOutOnADroppedStreamDoesNotCapTheNode() async throws {
        let server = SettingsServer()
        server.silentOnMax = true
        let (session, _) = try connect(server, timeout: 0.1)
        server.onSilentPublish = { session.client.update(state: .disconnected()) }
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("a publish") { !server.publishes.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.configured.isEmpty)
        #expect(session.lock.withLock { !$0.settingsSync.explicitMaxItems })
        #expect(try db.pendingSyncItems().map(\.id) == ["global"])
    }

    @Test func oneItemTheServerRefusesDoesNotHoldBackTheOnesAfterIt() async throws {
        let server = SettingsServer()
        server.refusedIds = ["chat:a@example.org"]
        let (session, _) = try connect(server)
        try await db.writer.write { try AppDatabase.touch($0, item: "chat:a@example.org", key: "pinned", value: "1") }
        try db.setSetting(.statusMessage, "busy")
        await session.runSettingsSync()
        await eventually("the global item to be published") { server.publishes.contains { $0.id == "global" } }
        await eventually("the global item to be done with") { (try? db.pendingSyncItems().map(\.id)) == ["chat:a@example.org"] }
        #expect(try db.pendingSyncItems().map(\.id) == ["chat:a@example.org"])
    }

    // MARK: Fetching

    @Test func aDropDuringTheReadIsSyncedAgainWhenTheStreamResumes() async throws {
        let server = SettingsServer()
        server.items = [("chat:friend@example.org", item(entry("pinned", "1")))]
        let (session, _) = try connect(server)
        server.onItems = { session.client.update(state: .disconnected()) }
        await session.runSettingsSync()
        #expect(try held("chat:friend@example.org").isEmpty)
        session.client.update(state: .connected(resumed: true))
        await eventually("the node to be read again") { (try? held("chat:friend@example.org").count) == 1 }
        // Watching for changes began with the second run.
        await eventually("the sync to end") { session.lock.withLock { $0.settingsSync.syncCompleted } }
        try db.setSetting(.statusMessage, "after")
        await eventually("a publish") { server.publishes.contains { $0.id == "global" } }
    }

    @Test func anItemThatArrivedLiveDuringTheReadIsNotTakenAsGone() async throws {
        let server = SettingsServer()
        let (session, _) = try connect(server)
        server.onItems = {
            try? session.client.module(.pubsub).process(message: event(from: "me@example.org", id: "chat:late@example.org", item(entry("pinned", "1"))))
        }
        await session.runSettingsSync()
        #expect(try held("chat:late@example.org").count == 1)
    }

    @Test func aFullPageWithNoPagingDataIsNotTakenAsTheWholeNode() async throws {
        try hold("chat:old@example.org", entry("pinned", "1"))
        let server = SettingsServer()
        for index in 0..<XMPPSession.settingsPageSize {
            server.items.append(("chat:friend\(index)@example.org", item(entry("pinned", "1"))))
        }
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        #expect(try held("chat:old@example.org").count == 1)
        #expect(try held("chat:friend3@example.org").count == 1)
    }

    @Test func aShortPageWithNoPagingDataIsTheWholeNode() async throws {
        try hold("chat:old@example.org", entry("pinned", "1"))
        let server = SettingsServer()
        server.items = [("chat:friend@example.org", item(entry("pinned", "1")))]
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        #expect(try held("chat:old@example.org").isEmpty)
    }

    @Test func changingTheAvailabilityKeepsAMessageAnotherDeviceSet() throws {
        let (session, _) = try connect(SettingsServer())
        let remote = entry("statusMessage", "remote")
        try hold("global", remote)
        try session.setAvailability(.away)
        // A caller whose copy of the message is the current one writes it back.
        try session.setStatus(availability: .away, message: "remote")
        let global = try held("global")
        #expect(global.first { $0.key == "statusMessage" } == remote)
        #expect(global.first { $0.key == "availability" }?.value == "away")
    }

    @Test func aPagedNodeIsReadToTheEnd() async throws {
        let server = SettingsServer()
        server.pageSize = 2
        for index in 0..<5 {
            server.items.append(("chat:friend\(index)@example.org", item(entry("pinned", "1"))))
        }
        server.items.append(("global", item(entry("availability", "away"))))
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        #expect(try db.setting(.availability) == "away")
        for index in 0..<5 {
            let stored = try held("chat:friend\(index)@example.org")
            #expect(stored.count == 1)
        }
    }

    @Test func aFailedReadNeverDeletesWhatIsHeldHere() async throws {
        try hold("chat:friend@example.org", entry("pinned", "1"))
        let server = SettingsServer()
        server.failsReads = true
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        let stored = try held("chat:friend@example.org")
        #expect(stored.count == 1)
    }

    @Test func anIncompleteReadAppliesWhatCameWithoutDeleting() async throws {
        try hold("chat:friend@example.org", entry("pinned", "1"))
        let server = SettingsServer()
        server.pageSize = 1
        server.items = [("global", item(entry("availability", "away"))), ("global", item(entry("availability", "away")))]
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        // The server repeated a page, so the node isn't known to be read.
        #expect(try db.setting(.availability) == "away")
        let stored = try held("chat:friend@example.org")
        #expect(stored.count == 1)
    }

    @Test func aMissingNodeIsAnEmptyOneSoWhatWasRemovedThereGoesHere() async throws {
        try hold("chat:friend@example.org", entry("pinned", "1"))
        let server = SettingsServer(exists: false)
        let (session, _) = try connect(server)
        await session.runSettingsSync()
        let stored = try held("chat:friend@example.org")
        #expect(stored.isEmpty)
    }

    // MARK: Events

    private func event(from sender: String?, id: String = "global", _ payload: Element) -> Martin.Message {
        let message = Martin.Message()
        message.type = .headline
        if let sender { message.from = Martin.JID(sender) }
        let items = node("items", ["node": NS.settings], [node("item", ["id": id], [payload])])
        message.addChild(Element(name: "event", xmlns: "http://jabber.org/protocol/pubsub#event", children: [items]))
        return message
    }

    @Test func anEventFromSomeoneElseIsIgnored() throws {
        let (session, _) = try connect(SettingsServer())
        try session.client.module(.pubsub).process(message: event(from: "mallory@example.org", item(entry("availability", "dnd"))))
        #expect(try db.setting(.availability) == nil)
        try session.client.module(.pubsub).process(message: event(from: "me@example.org", item(entry("availability", "dnd"))))
        #expect(try db.setting(.availability) == "dnd")
    }

    @Test func aRemoteStatusChangeSendsPresenceAgain() throws {
        let (session, wire) = try connect(SettingsServer())
        let before = wire.written.compactMap { $0 as? Presence }.count
        try session.client.module(.pubsub).process(message: event(from: "me@example.org", item(entry("availability", "dnd"))))
        let presences = wire.written.compactMap { $0 as? Presence }
        #expect(presences.count == before + 1)
        #expect(presences.last?.show == .dnd)
    }

    @Test func aRemoteChangeToSharingLastSeenClearsWhatWasKnownAndSendsPresence() throws {
        let (session, wire) = try connect(SettingsServer())
        try db.setFlag(.sharesLastSeen, true)
        let contact = YapnestKit.JID("friend@example.org")!
        try db.writer.write { try Contact(jid: contact).save($0) }
        try db.setLastSeen(Date(), for: contact)
        let before = wire.written.compactMap { $0 as? Presence }.count
        try session.client.module(.pubsub).process(message: event(from: nil, item(entry("sharesLastSeen", nil))))
        #expect(!session.sharesLastSeen)
        #expect(wire.written.compactMap { $0 as? Presence }.count == before + 1)
        #expect(try db.contact(contact)?.lastSeenAt == nil)
    }

    @Test func aRetractedUsageItemDropsThatDevice() throws {
        let (session, _) = try connect(SettingsServer())
        var ranking = ReactionRanking()
        ranking.record("🔥", at: Date())
        try db.applyRemoteItem(id: "usage:phone", payload: ranking.usageElement)
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM remoteUsage") } == 1)
        let retract = Martin.Message()
        retract.type = .headline
        let items = node("items", ["node": NS.settings], [node("retract", ["id": "usage:phone"])])
        retract.addChild(Element(name: "event", xmlns: "http://jabber.org/protocol/pubsub#event", children: [items]))
        try session.client.module(.pubsub).process(message: retract)
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM remoteUsage") } == 0)
    }
}
