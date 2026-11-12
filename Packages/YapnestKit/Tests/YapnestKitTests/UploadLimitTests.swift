import Foundation
@preconcurrency import Martin
@testable import Martin
import Testing
@testable import YapnestKit

struct UploadLimitTests {
    private func harness(announcing max: String?, connected: Bool = true) throws -> CallSessionHarness {
        let h = try CallSessionHarness(withMedia: false, connected: connected)
        h.wire.answer { iq -> Iq? in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items") != nil {
                let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
                query.addChild(Element(name: "item", attributes: ["jid": "upload.example.org"]))
                return FakeWire.result(to: iq, query)
            }
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info") != nil {
                let result = FakeWire.discoInfo(to: iq, category: "store", type: "file", features: ["urn:xmpp:http:upload:0"])
                if let max {
                    let form = Element(name: "x", attributes: ["xmlns": "jabber:x:data", "type": "result"])
                    for (name, value) in [("FORM_TYPE", "urn:xmpp:http:upload:0"), ("max-file-size", max)] {
                        let field = Element(name: "field", attributes: ["var": name])
                        field.addChild(Element(name: "value", cdata: value))
                        form.addChild(field)
                    }
                    result.firstChild(name: "query")?.addChild(form)
                }
                return result
            }
            return FakeWire.result(to: iq)
        }
        return h
    }

    private func discoRequests(_ h: CallSessionHarness) -> Int {
        h.wire.written.compactMap { $0 as? Iq }.filter { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items") != nil }.count
    }

    @Test func theAnnouncedLimitIsTheLimit() async throws {
        let h = try harness(announcing: "500")
        #expect(await h.session.uploadLimit(encrypted: false) == 500)
    }

    @Test func aServerThatAnnouncesNoLimitHasNoneNotIntMax() async throws {
        let h = try harness(announcing: nil)
        #expect(await h.session.uploadLimit(encrypted: false) == nil)
        let cached = h.session.lock.withLock { $0.uploadService }
        #expect(cached != nil)
        #expect(cached?.maxSize == nil)
    }

    @Test func anEncryptedFileIsSealedBeforeTheLimitApplies() async throws {
        let h = try harness(announcing: "500")
        #expect(await h.session.uploadLimit(encrypted: true) == 500 - FileCrypto.tagLength)
    }

    @Test func anEncryptedFileIsNeverOverWhatCanBeDownloaded() async throws {
        let big = try harness(announcing: String(1 << 40))
        #expect(await big.session.uploadLimit(encrypted: true) == XMPPSession.maxDownloadSize)
        let none = try harness(announcing: nil)
        #expect(await none.session.uploadLimit(encrypted: true) == XMPPSession.maxDownloadSize)
    }

    @Test func aLimitSmallerThanTheSealingOverheadIsZeroNotNegative() async throws {
        let h = try harness(announcing: "10")
        #expect(await h.session.uploadLimit(encrypted: true) == 0)
    }

    @Test func offlineNothingIsDiscovered() async throws {
        let h = try harness(announcing: "500", connected: false)
        #expect(await h.session.uploadLimit(encrypted: false) == nil)
        #expect(await h.session.uploadLimit(encrypted: true) == XMPPSession.maxDownloadSize)
        #expect(discoRequests(h) == 0)
    }

    @Test func aSessionWithoutAnUploadServiceDoesNotKnow() async throws {
        let h = try CallSessionHarness(withMedia: false)
        h.wire.answer { iq -> Iq? in
            if iq.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items") != nil {
                return FakeWire.result(to: iq, Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items"))
            }
            return FakeWire.result(to: iq)
        }
        #expect(await h.session.uploadLimit(encrypted: false) == nil)
    }

    @Test func theDiscoveryIsAskedOnce() async throws {
        let h = try harness(announcing: "500")
        _ = await h.session.uploadLimit(encrypted: false)
        let asked = discoRequests(h)
        #expect(asked == 1)
        #expect(await h.session.uploadLimit(encrypted: false) == 500)
        #expect(discoRequests(h) == asked)
    }
}
