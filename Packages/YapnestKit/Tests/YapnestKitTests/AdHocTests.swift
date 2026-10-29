import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// Ad-hoc commands (XEP-0050) against a stand-in for the entity.
struct AdHocTests {
    let session: XMPPSession
    let wire = FakeWire()
    let command = AdHocCommand(jid: "example.org", node: "add-user", name: "Add user")

    init() throws {
        session = try makeSession(JID("me@example.org")!)
    }

    private func commandElement(
        node: String = "add-user", status: String, sessionID: String? = "s1", actions: Element? = nil, notes: [(String, String)] = [], form: Element? = nil,
    ) -> Element {
        let element = Element(name: "command", xmlns: NS.commands)
        element.setAttribute("node", value: node)
        element.setAttribute("status", value: status)
        if let sessionID { element.setAttribute("sessionid", value: sessionID) }
        if let actions { element.addChild(actions) }
        for (type, text) in notes { element.addChild(Element(name: "note", cdata: text, attributes: ["type": type])) }
        if let form { element.addChild(form) }
        return element
    }

    private func actions(_ names: String..., execute: String? = nil) -> Element {
        let element = Element(name: "actions")
        if let execute { element.setAttribute("execute", value: execute) }
        for name in names { element.addChild(Element(name: name)) }
        return element
    }

    private func form(_ xml: String) -> Element { Element.from(string: xml)! }

    /// The requests written that `matches`. The session sends others of its own when it connects, a roster
    /// or a feature lookup, at a time the test doesn't choose, so the last request written is not always
    /// the one the test asked for.
    private func requests(where matches: (Iq) -> Bool) -> [Iq] {
        wire.written.compactMap { $0 as? Iq }.filter(matches)
    }

    private func sentCommands() -> [Iq] {
        requests { $0.firstChild(name: "command", xmlns: NS.commands) != nil }
    }

    private func sent(_ n: Int = -1) throws -> Element {
        let iqs = sentCommands()
        return try #require((n < 0 ? iqs.last : iqs[n])?.firstChild(name: "command", xmlns: NS.commands))
    }

    // MARK: Listing

    @Test func listsTheCommandsAnEntityOffers() async throws {
        session.connectForTesting(wire)
        wire.answer { iq in
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items")
            query.setAttribute("node", value: NS.commands)
            query.addChild(Element(name: "item", attributes: ["jid": "example.org", "node": "ping", "name": "Ping"]))
            query.addChild(Element(name: "item", attributes: ["jid": "example.org", "node": "bare"]))
            // Another entity's, and one without a node, are not offered.
            query.addChild(Element(name: "item", attributes: ["jid": "evil.example", "node": "x", "name": "Evil"]))
            query.addChild(Element(name: "item", attributes: ["jid": "example.org", "name": "Nothing"]))
            return FakeWire.result(to: iq, query)
        }
        let commands = try await session.adHocCommands(at: "example.org")
        #expect(commands == [
            AdHocCommand(jid: "example.org", node: "ping", name: "Ping"),
            AdHocCommand(jid: "example.org", node: "bare", name: "bare"),
        ])
        let listing = requests { $0.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#items")?.getAttribute("node") == NS.commands }
        #expect(listing.count == 1)
        let request = try #require(listing.last)
        #expect(request.type == .get)
        #expect(request.to?.stringValue == "example.org")
    }

    @Test func aListFromAnotherEntityIsRejected() async throws {
        session.connectForTesting(wire)
        wire.answer { iq in
            let reply = FakeWire.result(to: iq, Element(name: "query", xmlns: "http://jabber.org/protocol/disco#items"))
            reply.from = Martin.JID("evil.example")
            return reply
        }
        await #expect(throws: AdHocError.unexpectedReply) { try await session.adHocCommands(at: "example.org") }
    }

    @Test func anOccupantOffersCommandsIfItListsTheFeature() async throws {
        session.connectForTesting(wire)
        wire.answer { iq in
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "feature", attributes: ["var": NS.commands]))
            let reply = FakeWire.result(to: iq, query)
            reply.from = iq.to
            return reply
        }
        #expect(await session.offersCommands(at: "room@conference.example.org/bot"))
        let probes = requests { $0.to?.stringValue == "room@conference.example.org/bot" }
        #expect(probes.count == 1)
        let request = try #require(probes.last)
        #expect(request.firstChild(name: "query", xmlns: "http://jabber.org/protocol/disco#info")?.getAttribute("node") == nil)
    }

    @Test func offersCommandsReadsTheFeatureList() {
        func reply(_ features: [String]?) -> Iq {
            guard let features else { return FakeWire.result(to: Iq()) }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            for feature in features { query.addChild(Element(name: "feature", attributes: ["var": feature])) }
            return FakeWire.result(to: Iq(), query)
        }
        #expect(AdHocStanza.offersCommands(in: reply(["urn:xmpp:ping", NS.commands])))
        #expect(!AdHocStanza.offersCommands(in: reply(["urn:xmpp:ping"])))
        #expect(!AdHocStanza.offersCommands(in: reply(nil)))
    }

    @Test func aProbeFromAnotherEntityOrOfflineIsNo() async {
        #expect(await !session.offersCommands(at: "room@conference.example.org/bot"))
        session.connectForTesting(wire)
        wire.answer { iq in
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "feature", attributes: ["var": NS.commands]))
            let reply = FakeWire.result(to: iq, query)
            reply.from = Martin.JID("evil.example")
            return reply
        }
        #expect(await !session.offersCommands(at: "room@conference.example.org/bot"))
    }

    @Test func offlineNothingIsSent() async {
        await #expect(throws: AdHocError.offline) { try await session.adHocCommands(at: "example.org") }
        await #expect(throws: AdHocError.offline) { try await session.execute(command) }
        #expect(wire.written.isEmpty)
    }

    // MARK: A session

    @Test func aTwoStageCommandIsRunToTheEnd() async throws {
        session.connectForTesting(wire)
        let step = OSAllocatedCounter()
        wire.answer { [self] iq in
            // Only the commands count: the session's own requests aren't steps of this one.
            guard iq.firstChild(name: "command", xmlns: NS.commands) != nil else { return nil }
            switch step.next() {
            case 0:
                return FakeWire.result(to: iq, commandElement(status: "executing", actions: actions("next", "complete", execute: "next"), form: form("""
                <x xmlns='jabber:x:data' type='form'><title>Who?</title><field type='text-single' var='name'><required/></field></x>
                """)))
            default:
                return FakeWire.result(to: iq, commandElement(status: "completed", notes: [("info", "Added."), ("warn", "Careful."), ("bogus", "Odd.")], form: form("""
                <x xmlns='jabber:x:data' type='result'><reported><field var='n' label='N'/></reported><item><field var='n'><value>1</value></field></item></x>
                """)))
            }
        }

        let first = try await session.execute(command)
        let start = try sent(0)
        #expect(start.getAttribute("node") == "add-user")
        #expect(start.getAttribute("action") == "execute")
        #expect(start.getAttribute("sessionid") == nil)
        #expect(sentCommands().first?.type == .set)
        #expect(first.sessionID == "s1")
        #expect(first.status == .executing)
        #expect(first.allowed == [.next, .complete])
        #expect(first.defaultAction == .next)
        #expect(first.notes.isEmpty)
        var answer = try #require(first.form)
        #expect(answer.title == "Who?")
        answer.fields[0].value = "ann"

        let last = try await session.execute(command, action: .complete, sessionID: first.sessionID, form: answer)
        let second = try sent(1)
        #expect(second.getAttribute("action") == "complete")
        #expect(second.getAttribute("sessionid") == "s1")
        let submitted = try #require(second.firstChild(name: "x", xmlns: NS.dataForms))
        #expect(submitted.getAttribute("type") == "submit")
        #expect(submitted.firstChild(name: "field")?.firstChild(name: "value")?.value == "ann")
        #expect(last.status == .completed)
        #expect(last.allowed.isEmpty && last.defaultAction == nil)
        #expect(last.notes == [AdHocNote(kind: .info, text: "Added."), AdHocNote(kind: .warn, text: "Careful."), AdHocNote(kind: .info, text: "Odd.")])
        #expect(last.form?.type == .result)
        #expect(last.form?.reported?.map(\.name) == ["n"])
        #expect(last.form?.items.first?.first?.value == "1")
    }

    @Test func previousStepGoesBackWithTheSession() async throws {
        session.connectForTesting(wire)
        wire.answer { [self] iq in
            FakeWire.result(to: iq, commandElement(status: "executing", actions: actions("next")))
        }
        let back = try await session.execute(command, action: .prev, sessionID: "s1", form: XDataForm(fields: [.init(name: "a", values: ["x"])]))
        let request = try sent()
        #expect(request.getAttribute("action") == "prev")
        #expect(request.getAttribute("sessionid") == "s1")
        #expect(back.allowed == [.next])
        #expect(back.defaultAction == .next)
    }

    @Test func cancellingSendsNoFormAndEndsTheRun() async throws {
        session.connectForTesting(wire)
        wire.answer { [self] iq in FakeWire.result(to: iq, commandElement(status: "canceled")) }
        let response = try await session.execute(command, action: .cancel, sessionID: "s1", form: XDataForm(fields: [.init(name: "a", values: ["x"])]))
        let request = try sent()
        #expect(request.getAttribute("action") == "cancel")
        #expect(request.firstChild(name: "x") == nil)
        #expect(response.status == .canceled)
    }

    @Test func anExecutingCommandWithoutActionsCanOnlyBeCompleted() throws {
        let reply = FakeWire.result(to: Iq(), commandElement(status: "executing"))
        let response = try AdHocStanza.response(in: reply, node: "add-user", sessionID: nil)
        #expect(response.allowed == [.complete])
        #expect(response.defaultAction == .complete)
    }

    @Test func theDefaultActionIsTheOneNamedIfAllowed() throws {
        func response(_ element: Element) throws -> AdHocResponse {
            try AdHocStanza.response(in: FakeWire.result(to: Iq(), element), node: "add-user", sessionID: nil)
        }
        let prev = try response(commandElement(status: "executing", actions: actions("prev", "complete", execute: "prev")))
        #expect(prev.allowed == [.prev, .complete] && prev.defaultAction == .prev)
        // Named, but not among the actions: ignored.
        let stray = try response(commandElement(status: "executing", actions: actions("prev", "complete", execute: "next")))
        #expect(stray.defaultAction == .complete)
        let none = try response(commandElement(status: "executing", actions: actions("prev")))
        #expect(none.defaultAction == nil)
    }

    // MARK: Replies that don't fit

    @Test func aReplyFromTheWrongEntityIsRejected() async throws {
        session.connectForTesting(wire)
        wire.answer { [self] iq in
            let reply = FakeWire.result(to: iq, commandElement(status: "completed"))
            reply.from = Martin.JID("evil.example")
            return reply
        }
        await #expect(throws: AdHocError.unexpectedReply) { try await session.execute(command) }
        // Another device of the same contact is not the one asked.
        let device = AdHocCommand(jid: "bob@example.org/phone", node: "add-user", name: "x")
        wire.answer { [self] iq in
            let reply = FakeWire.result(to: iq, commandElement(status: "completed"))
            reply.from = Martin.JID("bob@example.org/laptop")
            return reply
        }
        await #expect(throws: AdHocError.unexpectedReply) { try await session.execute(device) }
    }

    @Test func aReplyWithoutAFromCountsOnlyForOurOwnAccount() async throws {
        session.connectForTesting(wire)
        wire.answer { [self] iq in
            let reply = FakeWire.result(to: iq, commandElement(status: "completed"))
            reply.from = nil
            return reply
        }
        await #expect(throws: AdHocError.unexpectedReply) { try await session.execute(command) }
        let own = AdHocCommand(jid: "me@example.org", node: "add-user", name: "x")
        #expect(try await session.execute(own).status == .completed)
    }

    @Test func aReplyForAnotherCommandOrRunIsRejected() throws {
        func response(_ element: Element, sessionID: String? = nil) throws -> AdHocResponse {
            try AdHocStanza.response(in: FakeWire.result(to: Iq(), element), node: "add-user", sessionID: sessionID)
        }
        #expect(throws: AdHocError.unexpectedReply) { try response(commandElement(node: "other", status: "completed")) }
        #expect(throws: AdHocError.unexpectedReply) { try response(commandElement(status: "executing", sessionID: "other"), sessionID: "s1") }
        #expect(throws: AdHocError.unexpectedReply) { try response(commandElement(status: "weird")) }
        #expect(throws: AdHocError.unexpectedReply) { try AdHocStanza.response(in: FakeWire.result(to: Iq()), node: "add-user", sessionID: nil) }
        // A reply that leaves the session out keeps the one that was sent.
        #expect(try response(commandElement(status: "executing", sessionID: nil), sessionID: "s1").sessionID == "s1")
    }

    // MARK: Errors

    private func error(_ condition: String, specific: String? = nil, text: String? = nil) -> Iq {
        let iq = FakeWire.error(to: Iq(), condition: condition)
        let element = iq.firstChild(name: "error")!
        if let specific { element.addChild(Element(name: specific, xmlns: NS.commands)) }
        if let text { element.addChild(Element(name: "text", cdata: text, xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas")) }
        return iq
    }

    @Test func eachErrorGetsItsOwnCase() {
        func decoded(_ iq: Iq?) -> AdHocError? { AdHocStanza.error(from: iq) as? AdHocError }
        #expect(decoded(nil) == .timedOut)
        #expect(decoded(error("bad-request", specific: "bad-action")) == .badAction(text: nil))
        #expect(decoded(error("bad-request", specific: "malformed-action")) == .malformedAction(text: nil))
        #expect(decoded(error("bad-request", specific: "bad-sessionid")) == .badSessionID(text: nil))
        #expect(decoded(error("not-allowed", specific: "session-expired")) == .sessionExpired(text: nil))
        #expect(decoded(error("bad-request", specific: "bad-payload", text: "Missing name")) == .badPayload(text: "Missing name"))
        #expect(decoded(error("forbidden", text: "Admins only")) == .forbidden(text: "Admins only"))
        #expect(decoded(error("not-allowed")) == .forbidden(text: nil))
        #expect(decoded(error("not-authorized")) == .forbidden(text: nil))
        #expect(decoded(error("item-not-found")) == .notFound(text: nil))
        #expect(decoded(error("service-unavailable")) == .unsupported(text: nil))
        #expect(decoded(error("feature-not-implemented")) == .unsupported(text: nil))
        #expect(decoded(error("remote-server-timeout")) == .timedOut)
        #expect(decoded(error("internal-server-error", text: "Oops")) == .refused(reason: "Oops"))
        #expect(decoded(error("conflict")) == .refused(reason: "conflict"))
        #expect(decoded(error("bad-request")) == .refused(reason: "bad-request"))
    }

    @Test func theTextComesFirstOrLast() {
        // ejabberd puts it before the condition.
        let iq = Iq()
        iq.type = .error
        let element = Element(name: "error", attributes: ["type": "auth"])
        element.addChild(Element(name: "text", cdata: "First", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
        element.addChild(Element(name: "forbidden", xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas"))
        iq.addChild(element)
        #expect(AdHocStanza.error(from: iq) as? AdHocError == .forbidden(text: "First"))
    }

    @Test func errorsReachTheCaller() async {
        session.connectForTesting(wire)
        wire.answer { [self] iq in
            let reply = error("bad-request", specific: "bad-sessionid")
            reply.id = iq.id
            reply.from = iq.to
            return reply
        }
        await #expect(throws: AdHocError.badSessionID(text: nil)) { try await session.execute(command, action: .next, sessionID: "s1") }
        wire.answer { iq in FakeWire.error(to: iq, condition: "service-unavailable") }
        await #expect(throws: AdHocError.unsupported(text: nil)) { try await session.adHocCommands(at: "example.org") }
    }

    @Test func everyErrorHasAMessage() {
        let all: [AdHocError] = [
            .offline, .timedOut, .forbidden(text: "x"), .notFound(text: nil), .unsupported(text: nil), .badAction(text: nil), .malformedAction(text: nil),
            .badSessionID(text: nil), .sessionExpired(text: nil), .badPayload(text: nil), .refused(reason: "r"), .unexpectedReply,
        ]
        for error in all { #expect(error.errorDescription?.isEmpty == false) }
        #expect(AdHocError.forbidden(text: "Admins only").errorDescription?.hasSuffix("Admins only") == true)
    }

    // MARK: Discovery

    @Test func theServerOffersCommandsWhenItsDiscoListsThem() {
        #expect(!session.serverOffersCommands)
        session.connectForTesting(wire)
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
                result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
                return FakeWire.result(to: iq, result)
            }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "feature", attributes: ["var": NS.commands]))
            return FakeWire.result(to: iq, query)
        }
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind()
        session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
        #expect(session.serverOffersCommands)
    }

    @Test func aContactWithNoOnlineDevicesHasNoCommandEntities() {
        #expect(session.commandEntities(of: JID("bob@example.org")!).isEmpty)
    }
}
