import Foundation
import GRDB
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let uploadNS = "urn:xmpp:http:upload:0"

// MARK: What a slot and a status stand for

struct UploadSlotParsingTests {
    @Test func onlyTheHeadersTheSpecAllowsArePassedOn() {
        let headers = UploadSlotParser.allowed([
            ("Authorization", "Basic abc"), ("cookie", "a=b"), ("Expires", "Wed, 21 Oct 2026 07:28:00 GMT"),
            ("Host", "evil.example"), ("Content-Length", "1"), ("X-Anything", "x"),
        ])
        #expect(Set(headers.keys.map { $0.lowercased() }) == ["authorization", "cookie", "expires"])
        #expect(headers["Authorization"] == "Basic abc")
    }

    @Test func aHeaderValueCannotStartAnotherLine() {
        let headers = UploadSlotParser.allowed([("Authorization", "Basic abc\r\nX-Injected: 1\nmore")])
        #expect(headers["Authorization"] == "Basic abcX-Injected: 1more")
        #expect(!(headers["Authorization"] ?? "").contains { $0 == "\r" || $0 == "\n" })
    }

    @Test func aSlotKeepsOnlyAllowedHeaders() throws {
        let iq: Iq = parseStanza("""
        <iq type='result' id='1'><slot xmlns='\(uploadNS)'><put url='https://up.example/put'><header name='Authorization'>Basic x</header>\
        <header name='X-Other'>y</header></put><get url='https://up.example/get'/></slot></iq>
        """)
        let slot = try #require(UploadSlotParser.slot(from: iq))
        #expect(slot.putHeaders == ["Authorization": "Basic x"])
        #expect(slot.getURL.absoluteString == "https://up.example/get")
    }

    @Test func aFileTooLargeErrorNamesTheLimit() throws {
        let iq: Iq = parseStanza("""
        <iq type='error' id='1'><error type='modify'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
        <file-too-large xmlns='\(uploadNS)'><max-file-size>5000</max-file-size></file-too-large></error></iq>
        """)
        let error = try #require(UploadSlotParser.error(from: iq) as? UploadSlotError)
        #expect(error.isFileTooLarge)
        #expect(error.maxFileSize == 5000)
    }

    @Test func aRetryErrorCarriesItsStamp() throws {
        let iq: Iq = parseStanza("""
        <iq type='error' id='1'><error type='wait'><resource-constraint xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
        <retry xmlns='\(uploadNS)' stamp='2026-10-25T12:00:00Z'/></error></iq>
        """)
        let error = try #require(UploadSlotParser.error(from: iq) as? UploadSlotError)
        #expect(error.retryAt == Date(timeIntervalSince1970: 1_792_929_600))
        #expect(error.error.isPassing)
    }

    @Test func theStatusesThatPassAreTheOnesToRetry() {
        for status in [408, 429, 500, 502, 503, 504] { #expect(ServerError.http(status: status).isPassing, "\(status)") }
        for status in [400, 401, 403, 404, 405, 413, 501, 507] { #expect(!ServerError.http(status: status).isPassing, "\(status)") }
    }
}

// MARK: Uploading

final class UploadRetryTests: @unchecked Sendable {
    let database: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()
    let host: LocalHTTPServer

    init() async throws {
        database = try AppDatabase.inMemory()
        session = try XMPPSession(
            credentials: .init(jid: me, password: "x", disableTLS: true), resource: "t", database: database, identityKeys: testIdentityKeys(for: database),
        )
        host = try await LocalHTTPServer()
        session.connectForTesting(wire)
        session.client.module(.resourceBind).bindedJid = Martin.JID("me@example.org/t")
        session.lock.withLock { $0.retryBackoff = 0 }
        try session.setEncrypted(false, with: alice)
    }

    /// Answers the upload service lookup, then each slot request with `slot`.
    private func serve(slot: @escaping @Sendable (Iq) -> Iq, onlyOnDomain: Bool = false) {
        let service = "upload.example.org"
        wire.answer { iq in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items") != nil {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                if !onlyOnDomain { query.addChild(Element(name: "item", attributes: ["jid": service])) }
                return FakeWire.result(to: iq, query)
            }
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                let isService = iq.to?.stringValue == service || (onlyOnDomain && iq.to?.stringValue == "example.org")
                return isService ? FakeWire.discoInfo(to: iq, category: "store", type: "file", features: [uploadNS]) : FakeWire.discoInfo(to: iq, category: "server", type: "im")
            }
            if iq.firstChild(name: "request", xmlns: uploadNS) != nil { return slot(iq) }
            return nil
        }
    }

    private func okSlot(_ iq: Iq, headers: [(String, String)] = []) -> Iq {
        let put = Element(name: "put", attributes: ["url": "http://127.0.0.1:\(host.port)/put"])
        for (name, value) in headers { put.addChild(Element(name: "header", cdata: value, attributes: ["name": name])) }
        let slot = Element(name: "slot", xmlns: uploadNS)
        slot.addChild(put)
        slot.addChild(Element(name: "get", attributes: ["url": "https://files.example.org/get/report.bin"]))
        return FakeWire.result(to: iq, slot)
    }

    private func send() async throws -> YapnestKit.Message {
        let url = FileManager.default.temporaryDirectory.appending(path: "up-\(UUID().uuidString).bin")
        try Data(count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let outgoing = session.outgoingMessages
        let file = try await outgoing.prepareFile(at: url, name: "report.bin")
        let message = try outgoing.stage([.file(file)], to: alice)[0]
        session.transmit(message, to: alice)
        return message
    }

    private func stored(_ message: YapnestKit.Message) throws -> YapnestKit.Message {
        try #require(try database.reader.read { try YapnestKit.Message.fetchOne($0, key: message.id!) })
    }

    private func slotRequestCount() -> Int {
        wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "request", xmlns: uploadNS) != nil }.count
    }

    private func reached(_ message: YapnestKit.Message) -> Bool {
        wire.messages.contains { $0.id == message.remoteId }
    }

    @Test func aServerErrorOfTheFileHostIsTriedAgain() async throws {
        host.queue(.send([LocalHTTPServer.response(503)]))
        host.queue(.send([LocalHTTPServer.response(201)]))
        serve(slot: { iq in self.okSlot(iq) })
        let message = try await send()
        #expect(await eventually { reached(message) })
        #expect(host.requests.count == 2)
        #expect(try stored(message).status != .failed)
    }

    @Test func aFileHostThatKeepsFailingFailsTheMessageAfterThreeTries() async throws {
        for _ in 0..<3 { host.queue(.send([LocalHTTPServer.response(503)])) }
        serve(slot: { iq in self.okSlot(iq) })
        let message = try await send()
        #expect(await eventually { (try? stored(message).status) == .failed })
        #expect(host.requests.count == 3)
        #expect(try stored(message).error?.contains("Upload failed") == true)
    }

    @Test func aTooManyRequestsAnswerIsTriedAgain() async throws {
        host.queue(.send([LocalHTTPServer.response(429)]))
        host.queue(.send([LocalHTTPServer.response(200)]))
        serve(slot: { iq in self.okSlot(iq) })
        let message = try await send()
        #expect(await eventually { reached(message) })
    }

    @Test func aRefusalByTheFileHostIsNotTriedAgain() async throws {
        host.queue(.send([LocalHTTPServer.response(403)]))
        serve(slot: { iq in self.okSlot(iq) })
        let message = try await send()
        #expect(await eventually { (try? stored(message).status) == .failed })
        #expect(host.requests.count == 1)
    }

    @Test func aWaitErrorOnTheSlotRequestIsTriedAgain() async throws {
        host.queue(.send([LocalHTTPServer.response(201)]))
        let asked = OSAllocatedCounter()
        serve(slot: { iq in
            asked.next() == 0 ? FakeWire.error(to: iq, condition: "resource-constraint", type: "wait") : self.okSlot(iq)
        })
        let message = try await send()
        #expect(await eventually { reached(message) })
        #expect(slotRequestCount() == 2)
    }

    @Test func aFinalErrorOnTheSlotRequestIsShownAtOnce() async throws {
        serve(slot: { iq in FakeWire.error(to: iq, condition: "forbidden", type: "auth") })
        let message = try await send()
        #expect(await eventually { (try? stored(message).status) == .failed })
        #expect(slotRequestCount() == 1)
        #expect(try stored(message).error?.contains("forbidden") == true)
    }

    @Test func aRetryStampIsWaitedForAndTheRequestMadeAgain() async throws {
        host.queue(.send([LocalHTTPServer.response(201)]))
        let asked = OSAllocatedCounter()
        serve(slot: { iq in
            guard asked.next() == 0 else { return self.okSlot(iq) }
            let reply = FakeWire.error(to: iq, condition: "resource-constraint", type: "wait")
            let retryElement = Element(name: "retry", xmlns: uploadNS)
            retryElement.setAttribute("stamp", value: "2020-01-01T00:00:00Z")
            reply.firstChild(name: "error")?.addChild(retryElement)
            return reply
        })
        let message = try await send()
        #expect(await eventually { reached(message) })
        #expect(slotRequestCount() == 2)
    }

    @Test func aFileTooLargeAnswerNamesTheServersLimit() async throws {
        serve(slot: { iq in
            let reply = FakeWire.error(to: iq, condition: "not-acceptable", type: "modify")
            let tooLarge = Element(name: "file-too-large", xmlns: uploadNS)
            tooLarge.addChild(Element(name: "max-file-size", cdata: "5000"))
            reply.firstChild(name: "error")?.addChild(tooLarge)
            return reply
        })
        let message = try await send()
        #expect(await eventually { (try? stored(message).status) == .failed })
        #expect(try stored(message).error?.hasPrefix("The file is too large. Your server accepts up to") == true)
        #expect(slotRequestCount() == 1)
    }

    @Test func aSlotsHeadersAreLimitedToTheAllowedOnes() async throws {
        host.queue(.send([LocalHTTPServer.response(201)]))
        serve(slot: { iq in self.okSlot(iq, headers: [("Authorization", "Basic abc"), ("X-Evil", "1")]) })
        let message = try await send()
        #expect(await eventually { reached(message) })
        let request = try #require(host.requests.first).lowercased()
        #expect(request.contains("authorization: basic abc"))
        #expect(!request.contains("x-evil"))
    }

    @Test func theServerItselfCanBeTheUploadService() async throws {
        host.queue(.send([LocalHTTPServer.response(201)]))
        serve(slot: { iq in self.okSlot(iq) }, onlyOnDomain: true)
        let message = try await send()
        #expect(await eventually { reached(message) })
        let request = try #require(wire.written.compactMap { $0 as? Iq }.first { $0.firstChild(name: "request", xmlns: uploadNS) != nil })
        #expect(request.to?.stringValue == "example.org")
    }
}
