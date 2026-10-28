import Foundation
import os
@preconcurrency import Martin
@preconcurrency @testable import MartinOMEMO
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("tester@secret-domain.example")!
private let alice = YapnestKit.JID("alice@secret-domain.example")!

/// The log a send leaves behind: what happened, and nothing of who or what.
@Suite(.serialized)
struct DiagnosticsInstrumentationTests {
    private func withStore(_ body: (DiagnosticsStore) throws -> Void) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
        DiagLog.use(store)
        defer { DiagLog.use(nil) }
        try body(store)
        let url = try DiagnosticsExport.make(store: store)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aSendThatIsAcknowledgedThenOneThatIsDroppedAndOneOffline() throws {
        let text = try withStore { _ in
            let wire = FakeWire()
            let session = try makeSession(me)
            session.connectForTesting(wire)
            try session.setEncrypted(false, with: alice)
            session.enableAcknowledgementsForTesting()

            let first = try session.send("body canary one", to: alice)
            session.drainSendQueue(alice)
            let written = try #require(wire.messages.first { $0.id == first.remoteId })
            session.acknowledged(written)

            wire.failsWrites = true
            _ = try session.send("body canary two", to: alice)
            session.drainSendQueue(alice)
            wire.failsWrites = false
            session.sendUnclaimedPending()
            session.drainSendQueue(alice)

            let offline = try makeSession(me)
            _ = try offline.send("body canary three", to: alice)
        }
        for event in ["Send queued", "Written to the stream", "Server acknowledged", "Write dropped by the session", "Sending unclaimed pending messages", "Send waits"] {
            #expect(text.contains(event), "\(event)")
        }
        #expect(text.contains("reason=offline"))
        for secret in ["secret-domain", "tester", "alice", "canary", "body"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func connectionEventsLogKindsAndPortsButNoHost() throws {
        let text = try withStore { _ in
            XMPPSession.logConnect(.resolved(candidates: 0, fallback: true, duration: 0.12))
            XMPPSession.logConnect(.attempting(kind: .fallbackHost, port: 5222))
            XMPPSession.logConnect(.failed(kind: .fallbackHost, port: 5222, reason: .network, error: .posix, code: 61, duration: 1.5, triesNext: false))
            XMPPSession.logConnect(.ready(kind: .srvDirectTLS, port: 5223, family: .ipv6, duration: 0.3))
        }
        #expect(text.contains("fallbackHost=true"))
        #expect(text.contains("kind=fallbackHost portKind=standard reason=network took=1.500s triesNext=false errorKind=posix errorCode=61"))
        #expect(text.contains("kind=srvDirectTLS portKind=directTLS family=ipv6"))
    }

    @Test func theExportHoldsNoAddressHostOrExactTimeAfterItsHeader() throws {
        let uploadedBytes = 2_345_678
        let text = try withStore { _ in
            XMPPSession.logConnect(.resolved(candidates: 2, fallback: false, duration: 0.12))
            XMPPSession.logConnect(.attempting(kind: .srvDirectTLS, port: 5223))
            XMPPSession.logConnect(.failed(kind: .srvDirectTLS, port: 35222, reason: .network, error: .posix, code: 61, duration: 1.5, triesNext: true))
            XMPPSession.logConnect(.ready(kind: .srvStartTLS, port: 5222, family: .ipv4, duration: 0.3))

            let wire = FakeWire()
            let session = try makeSession(me)
            session.connectForTesting(wire)
            try session.setEncrypted(false, with: alice)
            session.enableAcknowledgementsForTesting()
            let sent = try session.send("body canary one", to: alice)
            session.drainSendQueue(alice)
            session.acknowledged(try #require(wire.messages.first { $0.id == sent.remoteId }))
            let offline = try makeSession(me)
            _ = try offline.send("body canary two", to: alice)

            // An upload talks to a real HTTP server, so its lines are written as the session does.
            let transfer = Redacted.id("https://upload.secret-domain.example/slot/alice.png")
            DiagLog.info(.upload, "Upload slot granted", .id("msg", transfer), .size("bytes", uploadedBytes), .duration("took", 0.4))
            DiagLog.info(.upload, "Upload finished", .id("msg", transfer), .int("status", 201), .size("bytes", uploadedBytes), .duration("took", 2.1))
            DiagLog.info(.receive, "Download finished", .id("file", transfer), .int("status", 200), .size("bytes", 987_654), .duration("took", 0.9))
            DiagLog.error(.send, "Stanza over the server's limit", .size("bytes", 70_000), .int("limit", 65_536))
            DiagLog.error(.upload, "Upload failed", .id("msg", transfer), .error(NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "Could not reach https://upload.secret-domain.example/alice@secret-domain.example"])))
            DiagLog.error(.upload, "Upload failed", .id("msg", transfer), .error(ServerError(condition: "internal-server-error")))
        }
        let body = try #require(text.range(of: "Exported:").map { text[$0.upperBound...].drop { $0 != "\n" }.dropFirst() })
        let lines = body.split(separator: "\n")
        #expect(lines.count > 8)
        let patterns = [
            "@", "://", "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+",
            "[A-Za-z0-9-]+\\.[A-Za-z]{2,}",
            "T[0-9:]{8}\\.[0-9]",
        ]
        // The error domain of a server's error is a Swift type name, `Martin.XMPPError` or
        // `YapnestKit.ServerError`, which looks like a host and names none. The log is the process's, so
        // a line another test writes while this one has the store can be one, such as a failed upload.
        let domains = try Regex("error=(Martin|YapnestKit)\\.[A-Za-z]+/")
        for line in lines.map({ $0.replacing(domains, with: "error=type/") }) {
            for pattern in patterns {
                #expect(line.range(of: pattern, options: .regularExpression) == nil, "\(pattern) in \(line)")
            }
        }
        #expect(text.contains("bytes=lt2e22"))
        for exact in ["port=", "bytes=2345678", "bytes=987654", "bytes=70000"] {
            #expect(!text.contains(exact), "\(exact)")
        }
        #expect(text.contains("portKind=custom"))
    }

    @Test func aDisconnectionIsLoggedByKindAndNeverByText() throws {
        let text = try withStore { _ in
            let stream = Element(name: "error", xmlns: "http://etherx.jabber.org/streams")
            stream.addChild(Element(name: "host-unknown", xmlns: "urn:ietf:params:xml:ns:xmpp-streams"))
            stream.addChild(Element(name: "text", cdata: "secret-domain is not ours"))
            let session = try makeSession(me)
            session.logDisconnection(.streamError(stream), failure: nil)
        }
        #expect(text.contains("reason=streamError"))
        #expect(text.contains("condition=host-unknown"))
        #expect(!text.contains("secret-domain"))
    }
}

/// What a call leaves in the log: where its time went, and nothing of who it
/// was with or where they are.
extension DiagnosticsInstrumentationTests {
    @Test func aCallLogsItsPhasesCandidatesAndTimingsButNoSessionIdOrAddress() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
        DiagLog.use(store)
        defer { DiagLog.use(nil) }

        let h = try CallSessionHarness()
        try h.session.startCall(to: YapnestKit.JID("alice@example.org")!)
        let sid = try #require(h.session.callState.value?.sid)
        h.receive(h.jmi("proceed", sid: sid))
        await eventually("the session-initiate") { !h.jingleIqs("session-initiate").isEmpty }
        let media = try #require(h.factory.last)
        media.emit(.candidate(CallCandidate(sdpMid: "0", sdpMLineIndex: 0, sdp: "candidate:1 1 udp 2122260223 10.0.0.2 40000 typ host generation 0 ufrag FakeU network-id 1")))
        // One candidate comes inside the answer, which reaches the media with
        // the description, and one as transport-info.
        try h.receive(iq: h.sessionAccept(sid: sid).replacingOccurrences(of: "</transport>", with: """
            <candidate component='1' foundation='2' generation='0' id='b' ip='203.0.113.9' network='0' port='4141' priority='1' protocol='udp' type='host'/></transport>
            """))
        try h.receive(iq: """
            <iq from='alice@example.org/phone' to='me@example.org/phone' type='set' id='t'><jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
            <content creator='initiator' name='0'><transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='Yy11' pwd='anothersecretanothersecret'>\
            <candidate component='1' foundation='3' generation='0' id='c' ip='198.51.100.7' network='0' port='4242' priority='1' protocol='udp' type='relay'/>\
            </transport></content></jingle></iq>
            """)
        await eventually("the candidate to reach the media") { media.remoteCandidates.count == 1 && media.answersSet.count == 1 }
        media.emit(.state(.connected))
        await eventually("the call to be active") { h.phase == .active }
        h.session.hangUpCall()
        await eventually("the media to close") { media.isClosed }

        let text = try String(contentsOf: DiagnosticsExport.make(store: store), encoding: .utf8)
        // Other suites' calls log into the same store while this one runs.
        let mine = text.split(separator: "\n").filter { $0.contains("sid=\(Redacted.id(sid).hex)") }.joined(separator: "\n")
        for line in ["Call phase", "Call local candidate", "Call remote candidate", "Call media sid", "Call media started"] {
            #expect(mine.contains(line), "\(line)")
        }
        #expect(mine.contains("phase=active"))
        #expect(mine.contains("phase=ended reason=completed"))
        #expect(mine.contains("type=relay"))
        #expect(mine.contains("state=connected"))
        #expect(mine.contains("localHost=1"))
        #expect(mine.contains("remoteHost=1"))
        #expect(mine.contains("remoteRelay=1"))
        #expect(mine.contains("sinceAnswered="))
        #expect(text.contains("Call relays ready"))
        for secret in [sid, "alice", "example.org", "10.0.0.2", "198.51.100.7", "203.0.113.9", "FakeU", "anothersecret"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    /// The reason only reached the private system log, so an export showed a
    /// 🔒 with nothing to say why.
    @Test func aMessageThatWontDecryptSaysWhyButNotFromWhom() throws {
        let database = try AppDatabase.inMemory()
        let omemo = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        // The module decodes only once it's registered with a client.
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = FakeWire()
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(omemo.module)
        defer { withExtendedLifetime(client) {} }
        func stanza(for rid: UInt32, prekey: Bool) -> Martin.Message {
            let header = Element(name: "header", attributes: ["sid": "4242"])
            let key = Element(name: "key", attributes: prekey ? ["rid": String(rid), "prekey": "true"] : ["rid": String(rid)])
            key.value = "AAAA"
            header.addChild(key)
            let payload = Element(name: "payload")
            payload.value = "AAAA"
            let message = Martin.Message()
            message.addChild(Element(name: "encrypted", xmlns: NS.omemoLegacy, children: [header, payload]))
            return message
        }
        let text = try withStore { _ in
            _ = omemo.decrypt(stanza(for: omemo.deviceId, prekey: true), from: alice, ownCopy: false)
            _ = omemo.decrypt(stanza(for: omemo.deviceId &+ 1, prekey: false), from: alice, ownCopy: false)
        }
        // Version 0, from the zero bytes.
        #expect(text.contains("Couldn't decrypt error=legacyMessage keyForUs=true preKey=true history=false device="))
        #expect(text.contains("Couldn't decrypt error=invalidMessage keyForUs=false preKey=false history=false device="))
        for secret in ["alice", "secret-domain", "4242"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    /// A group message from another of our devices that had a key for this
    /// one but wouldn't decrypt, as after a device's identity changed under
    /// its old sessions, was taken for a copy never meant for us and dropped
    /// without a line.
    @Test func anOwnMessageMeantForThisDeviceThatWontDecryptIsLogged() throws {
        let database = try AppDatabase.inMemory()
        let omemo = try OMEMOEncryption(database: database, account: me, identityKeys: MemoryIdentityKeyStore())
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(me.description)
        client.writer = FakeWire()
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(omemo.module)
        defer { withExtendedLifetime(client) {} }
        func stanza(for rid: UInt32) -> Martin.Message {
            let header = Element(name: "header", attributes: ["sid": "4242"])
            let key = Element(name: "key", attributes: ["rid": String(rid)])
            key.value = "AAAA"
            header.addChild(key)
            let payload = Element(name: "payload")
            payload.value = "AAAA"
            let message = Martin.Message()
            message.addChild(Element(name: "encrypted", xmlns: NS.omemoLegacy, children: [header, payload]))
            return message
        }
        var results: [OMEMOEncryption.DecryptResult] = []
        let text = try withStore { _ in
            results.append(omemo.decrypt(stanza(for: omemo.deviceId), from: me, ownCopy: true))
            results.append(omemo.decrypt(stanza(for: omemo.deviceId &+ 1), from: me, ownCopy: true))
        }
        #expect(results.allSatisfy { if case .ownCopy = $0 { true } else { false } })
        #expect(text.components(separatedBy: "Couldn't decrypt").count == 2)
        #expect(text.contains("keyForUs=true preKey=false history=false device="))
    }

    // MARK: OMEMO publishing

    private func withStore(_ body: () async throws -> Void) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
        let store = DiagnosticsStore(directory: directory, process: .app, flushInterval: 60)
        DiagLog.use(store)
        defer { DiagLog.use(nil) }
        try await body()
        let url = try DiagnosticsExport.make(store: store)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func omemoClient(_ encryption: OMEMOEncryption, account: YapnestKit.JID, wire: FakeWire) -> XMPPClient {
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(account.description)
        client.writer = wire
        _ = client.modulesManager.register(DiscoveryModule(identity: .init(category: "client", type: "pc", name: "Test")))
        _ = client.modulesManager.register(PubSubModule())
        _ = client.modulesManager.register(encryption.module)
        return client
    }

    private func items(_ request: Iq, node: String, _ payload: Element) -> Iq {
        let item = Element(name: "item", attributes: ["id": "current"])
        item.addChild(payload)
        let items = Element(name: "items", attributes: ["node": node])
        items.addChild(item)
        return FakeWire.result(to: request, Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub", children: [items]))
    }

    private func deviceList(_ ids: [Int32]) -> Element {
        Element(name: "list", xmlns: OMEMOModule.XMLNS, children: ids.map { Element(name: "device", attributes: ["id": String($0.omemoId)]) })
    }

    private func publishedNode(_ iq: Iq) -> String? {
        iq.firstChild(name: "pubsub")?.firstChild(name: "publish")?.attribute("node")
    }

    @Test func registeringLogsWhatWasReadAndPublishedButNoIds() async throws {
        let omemo = try OMEMOEncryption(database: AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let wire = FakeWire()
        let client = omemoClient(omemo, account: me, wire: wire)
        defer { withExtendedLifetime(client) {} }
        wire.answer { iq in
            if self.publishedNode(iq) != nil { return FakeWire.result(to: iq) }
            return FakeWire.error(to: iq)
        }
        let text = try await withStore {
            omemo.module.isPepAvailable = true
            await wait { omemo.module.isReady }
        }
        #expect(text.contains("Own device list read devices=0 includesThisDevice=false source=fetch"))
        #expect(text.contains("Own bundle published signedPreKey=1 rotated=true flushed=true preKeys=100"))
        #expect(text.contains("Own device list published devices=1 includesThisDevice=true reason=registration"))
        #expect(text.contains("OMEMO registration ended resumed=false pep=true ready=true after="))
        #expect(!text.contains(String(omemo.deviceId)))
        #expect(!text.contains("tester") && !text.contains("secret-domain"))
    }

    @Test func aDeviceTakenOutOfTheListIsReAddedAndTheRemovalSaysWhy() async throws {
        let omemo = try OMEMOEncryption(database: AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let wire = FakeWire()
        let client = omemoClient(omemo, account: me, wire: wire)
        defer { withExtendedLifetime(client) {} }
        let own = Int32(bitPattern: omemo.deviceId)
        let others: [Int32] = [1111, 2222]
        let listed = OSAllocatedUnfairLock(initialState: others)
        wire.answer { iq in
            if self.publishedNode(iq) != nil {
                if self.publishedNode(iq) == OMEMOModule.DEVICES_LIST_NODE {
                    let ids = iq.firstChild(name: "pubsub")?.firstChild(name: "publish")?.firstChild(name: "item")?.firstChild(name: "list")?
                        .mapChildren(transform: { $0.getAttribute("id") }).compactMap { UInt32($0).map { Int32(bitPattern: $0) } } ?? []
                    listed.withLock { $0 = ids }
                }
                return FakeWire.result(to: iq)
            }
            if iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.attribute("node") == OMEMOModule.DEVICES_LIST_NODE {
                return self.items(iq, node: OMEMOModule.DEVICES_LIST_NODE, self.deviceList(listed.withLock { $0 }))
            }
            return FakeWire.error(to: iq)
        }
        omemo.module.listPublishInterval = 0
        let text = try await withStore {
            omemo.module.isPepAvailable = true
            await wait { omemo.module.isReady }
            // Another of our clients removed this device: it is listed again.
            listed.withLock { $0 = others }
            omemo.module.publishDeviceIdIfNeeded()
            await wait { listed.withLock { $0.contains(own) } }
            let removed = OSAllocatedUnfairLock(initialState: false)
            omemo.module.removeDevices(withIds: [1111]) { _ in removed.withLock { $0 = true } }
            await wait { removed.withLock { $0 } }
        }
        #expect(text.contains("Own device list read devices=2 includesThisDevice=false source=fetch"))
        #expect(text.contains("Own device list published devices=3 includesThisDevice=true reason=registration"))
        #expect(text.contains("Own device list published devices=3 includesThisDevice=true reason=readdedSelf"))
        #expect(text.contains("Own device list published devices=2 includesThisDevice=true reason=removalRequested"))
        for id in [own, 1111, 2222] { #expect(!text.contains(String(id.omemoId))) }
    }

    @Test func aRefusedListPublishAndABundlePublishSayWhichConditionAndType() async throws {
        let listRefused = try OMEMOEncryption(database: AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let listWire = FakeWire()
        let listClient = omemoClient(listRefused, account: me, wire: listWire)
        listRefused.module.registrationRetryDelays = [3600]
        listWire.answer { iq in
            guard let node = self.publishedNode(iq) else { return FakeWire.error(to: iq) }
            return node == OMEMOModule.DEVICES_LIST_NODE ? FakeWire.error(to: iq, condition: "forbidden", type: "auth") : FakeWire.result(to: iq)
        }
        let bundleRefused = try OMEMOEncryption(database: AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let bundleWire = FakeWire()
        let bundleClient = omemoClient(bundleRefused, account: me, wire: bundleWire)
        bundleRefused.module.registrationRetryDelays = [3600]
        bundleWire.answer { iq in
            guard let node = self.publishedNode(iq) else { return FakeWire.error(to: iq) }
            return node == OMEMOModule.DEVICES_LIST_NODE ? FakeWire.result(to: iq) : FakeWire.error(to: iq, condition: "service-unavailable", type: "wait")
        }
        defer { withExtendedLifetime([listClient, bundleClient]) {} }
        let text = try await withStore {
            listRefused.module.isPepAvailable = true
            await wait { listWire.written.contains { self.publishedNode($0 as? Iq ?? Iq()) == OMEMOModule.DEVICES_LIST_NODE } }
            bundleRefused.module.isPepAvailable = true
            await wait { bundleWire.written.contains { ($0 as? Iq).flatMap(self.publishedNode)?.contains(".bundles:") == true } }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(text.contains("Own device list publish failed error="))
        #expect(text.contains("condition=forbidden type=auth"))
        #expect(text.contains("Own bundle publish failed"))
        #expect(text.contains("condition=service-unavailable type=wait"))
    }

    @Test func everyOMEMOEventIsALineWithCountsAndFlagsOnly() throws {
        let text = try withStore { _ in
            OMEMOEvent.log(.ownListRead(count: 3, includesThisDevice: true, source: .notification))
            OMEMOEvent.log(.ownListPublished(count: 2, includesThisDevice: false, reason: .droppedWithoutBundles))
            OMEMOEvent.log(.ownDevicesDropped(count: 2))
            OMEMOEvent.log(.ownDropDeferred(count: 1))
            OMEMOEvent.log(.bundlePublished(signedPreKeyId: 4, rotated: false, flushed: false, preKeys: 87))
            OMEMOEvent.log(.sessionRepairStarted(deviceId: 424242, ownAccount: true))
            OMEMOEvent.log(.ownListPublishFailed(condition: "<script>", type: "bogus"))
            OMEMOEvent.log(.registrationEnded(resumed: true, pepAvailable: true, ready: false, seconds: nil))
        }
        #expect(text.contains("Own device list read devices=3 includesThisDevice=true source=notification"))
        #expect(text.contains("Own device list published devices=2 includesThisDevice=false reason=droppedWithoutBundles"))
        #expect(text.contains("Own devices without bundles dropped devices=2"))
        #expect(text.contains("Drop of own devices without bundles deferred devices=1"))
        #expect(text.contains("Own bundle published signedPreKey=4 rotated=false flushed=false preKeys=87"))
        #expect(text.contains("Session repair started device="))
        #expect(text.contains("ownAccount=true"))
        #expect(text.contains("Own device list publish failed"))
        #expect(text.contains("OMEMO registration ended resumed=true pep=true ready=false"))
        #expect(!text.contains("424242"))
        #expect(!text.contains("<script>"))
    }

    @Test func aDifferentKeyForAKnownDeviceIsRefusedAndLoggedWithoutItsId() throws {
        let omemo = try OMEMOEncryption(database: AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let text = try withStore { _ in
            let theirs = SignalAddress(name: alice.description, deviceId: 31337)
            let own = SignalAddress(name: me.description, deviceId: 31338)
            for address in [theirs, own] {
                #expect(omemo.store.save(identity: address, publicKeyData: Data([0x05] + Array(repeating: 1, count: 32))))
                #expect(!omemo.store.save(identity: address, publicKeyData: Data([0x05] + Array(repeating: 2, count: 32))))
            }
        }
        #expect(text.contains("Different key for a known device refused device="))
        #expect(text.contains("ownAccount=false"))
        #expect(text.contains("ownAccount=true"))
        #expect(!text.contains("31337") && !text.contains("31338") && !text.contains("alice"))
    }

    @Test func encryptingLogsCountsOfRecipientsDevicesAndSkips() async throws {
        let theirs = try OMEMOEncryption(database: AppDatabase.inMemory(), account: alice, identityKeys: MemoryIdentityKeyStore())
        let theirWire = FakeWire()
        let theirClient = omemoClient(theirs, account: alice, wire: theirWire)
        let bundle = OSAllocatedUnfairLock<Element?>(initialState: nil)
        theirWire.answer { iq in
            if let publish = iq.firstChild(name: "pubsub")?.firstChild(name: "publish") {
                if publish.attribute("node")?.contains(".bundles:") == true {
                    bundle.withLock { $0 = publish.firstChild(name: "item")?.firstChild(name: "bundle") }
                }
                return FakeWire.result(to: iq)
            }
            return FakeWire.error(to: iq)
        }
        theirs.module.isPepAvailable = true
        await wait { bundle.withLock { $0 } != nil }
        let aliceDevice = Int32(bitPattern: theirs.deviceId)
        let second: Int32 = 77

        let omemo = try OMEMOEncryption(database: AppDatabase.inMemory(), account: me, identityKeys: MemoryIdentityKeyStore())
        let wire = FakeWire()
        let client = omemoClient(omemo, account: me, wire: wire)
        defer { withExtendedLifetime([theirClient, client]) {} }
        wire.answer { iq in
            guard let node = iq.firstChild(name: "pubsub")?.firstChild(name: "items")?.attribute("node") else { return FakeWire.result(to: iq) }
            if node == OMEMOModule.DEVICES_LIST_NODE, iq.to?.bareJid.stringValue == alice.description {
                return self.items(iq, node: node, self.deviceList([aliceDevice, second]))
            }
            if node.hasSuffix(":\(UInt32(bitPattern: aliceDevice))") || node.hasSuffix(":\(second)"), let payload = bundle.withLock({ $0 }) {
                return self.items(iq, node: node, Element(element: payload))
            }
            return FakeWire.error(to: iq)
        }
        let text = try await withStore {
            func send() async -> Bool {
                let stanza = Martin.Message()
                stanza.type = .chat
                stanza.body = "body canary"
                let result = await Task.detached { omemo.encrypt(stanza, for: [alice]) }.value
                if case .success = result { return true }
                return false
            }
            #expect(await send())
            _ = omemo.store.setStatus(.undecidedActive, forIdentity: SignalAddress(name: alice.description, deviceId: second))
            #expect(await send())
        }
        #expect(text.contains("Encrypting recipients=1 recipientDevices=2 ownDevices=0 skipped=0"))
        #expect(text.contains("Encrypting recipients=1 recipientDevices=1 ownDevices=0 skipped=1"))
        for secret in ["alice", "secret-domain", "canary"] { #expect(!text.contains(secret), "\(secret)") }
    }
}
