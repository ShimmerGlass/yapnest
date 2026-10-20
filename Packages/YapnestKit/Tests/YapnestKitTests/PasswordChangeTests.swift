import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

/// Changing the password (XEP-0077 §3.3) against a stand-in for the server.
struct PasswordChangeTests {
    let tokens = MemoryFastTokenStore()
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        session = try XMPPSession(
            credentials: .init(jid: JID("me@example.org")!, password: "old"), resource: "t",
            database: try AppDatabase.inMemory(), fastTokens: tokens,
        )
    }

    private let token = Sasl2Module.FastToken(mechanism: "HT-SHA-256-NONE", token: "secret-token", expiry: .distantFuture)

    private func password(of session: XMPPSession) -> String? {
        if case .password(let password, _, _) = session.client.connectionConfiguration.credentials { password } else { nil }
    }

    private func query(_ iq: Iq) -> Element? { iq.firstChild(name: "query", xmlns: "jabber:iq:register") }

    /// The server answers the question about fields with `fields`, and the change with `outcome`.
    private func serve(fields: Element, outcome: @escaping @Sendable (Iq) -> Iq) {
        session.connectForTesting(wire)
        wire.answer { iq in
            guard iq.firstChild(name: "query", xmlns: "jabber:iq:register") != nil else { return FakeWire.result(to: iq) }
            return iq.type == .get ? FakeWire.result(to: iq, fields) : outcome(iq)
        }
    }

    private func plainFields() -> Element {
        let query = Element(name: "query", xmlns: "jabber:iq:register")
        query.addChild(Element(name: "registered"))
        query.addChild(Element(name: "username", cdata: "me"))
        query.addChild(Element(name: "password"))
        return query
    }

    private func changeForm() -> Element {
        let query = Element(name: "query", xmlns: "jabber:iq:register")
        let x = Element(name: "x", xmlns: "jabber:x:data")
        x.setAttribute("type", value: "form")
        func field(_ name: String, type: String, required: Bool = true, value: String? = nil) {
            let field = Element(name: "field", attributes: ["var": name, "type": type])
            if required { field.addChild(Element(name: "required")) }
            if let value { field.addChild(Element(name: "value", cdata: value)) }
            x.addChild(field)
        }
        field("FORM_TYPE", type: "hidden", required: false, value: "jabber:iq:register:changepassword")
        field("username", type: "text-single")
        field("old_password", type: "text-private")
        field("password", type: "text-private")
        query.addChild(x)
        return query
    }

    // MARK: Local checks

    @Test func whatIsTypedIsCheckedBeforeAskingTheServer() {
        #expect(XMPPSession.passwordProblem(current: "", new: "b", confirmation: "b") == .emptyCurrent)
        #expect(XMPPSession.passwordProblem(current: "a", new: "", confirmation: "") == .emptyNew)
        #expect(XMPPSession.passwordProblem(current: "a", new: "b", confirmation: "c") == .mismatch)
        #expect(XMPPSession.passwordProblem(current: "a", new: "a", confirmation: "a") == .unchanged)
        #expect(XMPPSession.passwordProblem(current: "a", new: "b", confirmation: "b") == nil)
    }

    // MARK: Stanzas

    @Test func theRequestsGoToTheServerDomain() throws {
        let ask = PasswordStanza.fieldsRequest(domain: "example.org")
        #expect(ask.type == .get)
        #expect(ask.to?.description == "example.org")
        #expect(query(ask) != nil)

        let change = PasswordStanza.plainChange(username: "me", password: "new", domain: "example.org")
        #expect(change.type == .set)
        #expect(change.to?.description == "example.org")
        let body = try #require(query(change))
        #expect(body.firstChild(name: "username")?.value == "me")
        #expect(body.firstChild(name: "password")?.value == "new")
    }

    @Test func aFormIsFilledFromTheFieldNamesItGives() throws {
        let form = try #require(PasswordStanza.form(in: FakeWire.result(to: Iq(), changeForm())))
        let answer = try #require(PasswordStanza.answer(form, username: "me", new: "new", current: "old"))
        #expect(answer.getAttribute("type") == "submit")
        let values = Dictionary(uniqueKeysWithValues: answer.filterChildren(name: "field", xmlns: nil).map { ($0.getAttribute("var")!, $0.firstChild(name: "value")?.value) })
        #expect(values == [
            "FORM_TYPE": "jabber:iq:register:changepassword", "username": "me", "old_password": "old", "password": "new",
        ])
    }

    @Test func aFormAskingForSomethingUnknownIsNotAnswered() throws {
        let x = Element(name: "x", xmlns: "jabber:x:data")
        let field = Element(name: "field", attributes: ["var": "email", "type": "text-single"])
        field.addChild(Element(name: "required"))
        x.addChild(field)
        #expect(PasswordStanza.answer(x, username: "me", new: "new", current: "old") == nil)
        // An optional one is left out.
        field.removeChild(field.firstChild(name: "required")!)
        let answer = try #require(PasswordStanza.answer(x, username: "me", new: "new", current: "old"))
        #expect(answer.filterChildren(name: "field", xmlns: nil).isEmpty)
    }

    // MARK: Errors

    @Test func eachRefusalGetsItsOwnMessage() {
        #expect(XMPPSession.passwordError(from: XMPPError.not_allowed()) == .notAllowed)
        #expect(XMPPSession.passwordError(from: XMPPError.forbidden()) == .notAllowed)
        #expect(XMPPSession.passwordError(from: XMPPError.service_unavailable()) == .notAllowed)
        #expect(XMPPSession.passwordError(from: XMPPError.not_authorized()) == .notAuthorized)
        #expect(XMPPSession.passwordError(from: XMPPError.not_acceptable()) == .notAcceptable(reason: nil))
        #expect(XMPPSession.passwordError(from: XMPPError.not_acceptable("Too short")) == .notAcceptable(reason: "Too short"))
        #expect(XMPPSession.passwordError(from: XMPPError.remote_server_timeout) == .timedOut)
        #expect(XMPPSession.passwordError(from: XMPPError.conflict()) == .refused(reason: "conflict"))
        for error: XMPPSession.PasswordError in [.offline, .notAllowed, .notAuthorized, .notAcceptable(reason: nil), .formRequired, .timedOut, .wrongCurrentPassword, .changedButNotSaved] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: Against a stand-in for the server

    @Test func offlineItDoesNothing() async {
        await #expect(throws: XMPPSession.PasswordError.offline) { try await session.changePassword(to: "new", current: "old") }
        #expect(wire.written.isEmpty)
        #expect(password(of: session) == "old")
    }

    @Test func aServerWithAPlainChangeTakesTheNewPasswordAndDropsTheToken() async throws {
        tokens.save(token)
        serve(fields: plainFields()) { FakeWire.result(to: $0) }

        try await session.changePassword(to: "new", current: "old")

        let change = try #require(wire.written.compactMap { $0 as? Iq }.last)
        #expect(change.type == .set)
        let body = try #require(query(change))
        #expect(body.firstChild(name: "username")?.value == "me")
        #expect(body.firstChild(name: "password")?.value == "new")
        // The plain change has no place for the old password; it isn't sent.
        #expect(body.firstChild(name: "old_password") == nil)
        #expect(password(of: session) == "new")
        #expect(tokens.load() == nil)
        #expect(session.client.module(.sasl2).fastToken == nil)
    }

    @Test func aServerThatWantsAFormGetsTheOldPasswordToo() async throws {
        serve(fields: changeForm()) { FakeWire.result(to: $0) }

        try await session.changePassword(to: "new", current: "old")

        let change = try #require(wire.written.compactMap { $0 as? Iq }.last)
        let form = try #require(query(change)?.firstChild(name: "x", xmlns: "jabber:x:data"))
        let sent = Dictionary(uniqueKeysWithValues: form.filterChildren(name: "field", xmlns: nil).map { ($0.getAttribute("var")!, $0.firstChild(name: "value")?.value) })
        #expect(sent["old_password"] == "old")
        #expect(sent["password"] == "new")
        #expect(sent["username"] == "me")
        #expect(password(of: session) == "new")
    }

    @Test(arguments: [
        ("not-allowed", XMPPSession.PasswordError.notAllowed),
        ("not-authorized", .notAuthorized),
        ("not-acceptable", .notAcceptable(reason: nil)),
    ])
    func aRefusalLeavesThePasswordAndTokenAlone(condition: String, expected: XMPPSession.PasswordError) async throws {
        tokens.save(token)
        serve(fields: plainFields()) { FakeWire.error(to: $0, condition: condition) }

        await #expect(throws: expected) { try await session.changePassword(to: "new", current: "old") }

        #expect(password(of: session) == "old")
        #expect(tokens.load() == token)
    }

    @Test func aFormWithUnknownRequiredFieldsIsNotSent() async throws {
        let fields = Element(name: "query", xmlns: "jabber:iq:register")
        let x = Element(name: "x", xmlns: "jabber:x:data")
        let field = Element(name: "field", attributes: ["var": "captcha", "type": "text-single"])
        field.addChild(Element(name: "required"))
        x.addChild(field)
        fields.addChild(x)
        serve(fields: fields) { FakeWire.result(to: $0) }

        await #expect(throws: XMPPSession.PasswordError.formRequired) { try await session.changePassword(to: "new", current: "old") }

        #expect(wire.written.compactMap { $0 as? Iq }.filter { $0.type == .set && query($0) != nil }.isEmpty)
        #expect(password(of: session) == "old")
    }

    @Test func aServerThatWontDescribeTheFieldsIsStillAskedPlainly() async throws {
        session.connectForTesting(wire)
        wire.answer { iq in iq.type == .get ? FakeWire.error(to: iq, condition: "service-unavailable") : FakeWire.result(to: iq) }

        try await session.changePassword(to: "new", current: "old")

        #expect(password(of: session) == "new")
    }

    @Test func theFeatureIsOfferedOnlyWhenTheDomainListsIt() {
        #expect(!session.canChangePassword)
        session.connectForTesting(wire)
        wire.answer { iq in
            if let bind = iq.firstChild(name: "bind"), bind.xmlns == "urn:ietf:params:xml:ns:xmpp-bind" {
                let result = Element(name: "bind", xmlns: "urn:ietf:params:xml:ns:xmpp-bind")
                result.addChild(Element(name: "jid", cdata: "me@example.org/t"))
                return FakeWire.result(to: iq, result)
            }
            let query = Element(name: "query", xmlns: "http://jabber.org/protocol/disco#info")
            query.addChild(Element(name: "feature", attributes: ["var": "jabber:iq:register"]))
            return FakeWire.result(to: iq, query)
        }
        session.lock.withLock { $0.awaitsAccountDiscovery = false }
        session.client.module(.resourceBind).bind()
        session.client.module(.disco).discoverServerFeatures(completionHandler: nil)
        #expect(session.canChangePassword)
    }
}
