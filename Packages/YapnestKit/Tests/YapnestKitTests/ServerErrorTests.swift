import Foundation
@preconcurrency import Martin
import Testing
@testable import YapnestKit

struct ServerErrorTests {
    private func parse(_ xml: String) -> ServerError? {
        ServerError(Element.from(string: xml)!)
    }

    private let stanzas = "xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'"

    @Test func anErrorElementGivesItsTypeConditionAndTrimmedText() throws {
        let error = try #require(parse("<error type='auth'><forbidden \(stanzas)/><text \(stanzas)>\n  Not for you \n</text></error>"))
        #expect(error == ServerError(condition: "forbidden", type: .auth, text: "Not for you"))
    }

    @Test func aStanzaGivesItsErrorChild() throws {
        let error = try #require(parse("<iq type='error'><error type='wait'><resource-constraint \(stanzas)/></error></iq>"))
        #expect(error.condition == "resource-constraint")
        #expect(error.type == .wait)
        #expect(error.text == nil)
    }

    @Test func aMissingTypeTakesTheConditionsDefault() throws {
        #expect(try #require(parse("<error><item-not-found \(stanzas)/></error>")).type == .cancel)
        #expect(try #require(parse("<error><recipient-unavailable \(stanzas)/></error>")).type == .wait)
        #expect(try #require(parse("<error type='bogus'><forbidden \(stanzas)/></error>")).type == .auth)
    }

    @Test func aTextBeforeTheConditionIsNotTakenForIt() throws {
        let error = try #require(parse("<error type='cancel'><text \(stanzas)>Gone</text><conflict \(stanzas)/></error>"))
        #expect(error.condition == "conflict")
        #expect(error.text == "Gone")
    }

    @Test func aConditionRFC6120DoesntDefineIsShownAsUndefined() throws {
        let error = try #require(parse("<error type='modify'><weird-thing \(stanzas)/></error>"))
        #expect(error.condition == "undefined-condition")
        #expect(error.type == .modify)
        #expect(ServerError(condition: "Send money to evil.example").condition == "undefined-condition")
    }

    @Test func controlAndBidiCharactersAreStrippedFromTheText() {
        let text = "pay\u{202E}now\u{200F}\u{2066}x\u{2069}\u{7}\u{200B}!"
        #expect(ServerError(condition: "forbidden", text: text).text == "paynowx!")
        #expect(ServerError(condition: "forbidden", text: "\u{202E}\u{7}").text == nil)
    }

    @Test func aDeclaredConditionIsToldFromABareError() {
        #expect(ServerError.declaredCondition(in: Element.from(string: "<error/>")!) == nil)
        #expect(ServerError.declaredCondition(in: Element.from(string: "<presence><error><undefined-condition \(stanzas)/></error></presence>")!) == "undefined-condition")
        #expect(ServerError.declaredCondition(in: Element.from(string: "<error><conflict \(stanzas)/></error>")!) == "conflict")
    }

    @Test func martinsInternalErrorIsPassingAsItsTypeIsLost() {
        #expect(ServerError(XMPPError.internal_server_error(nil)).isPassing)
        #expect(ServerError(condition: "internal-server-error").isFinal)
    }

    @Test func aWaitAnswerOfServiceUnavailableIsAFailureNotAnUnsupportedNode() {
        let wait = parseStanza("<iq type='error'><error type='wait'><service-unavailable \(stanzas)/></error></iq>") as Iq
        guard case .failed = NodeRead(PubSubError.from(stanza: wait)) else { Issue.record("not a failure"); return }
        let cancel = parseStanza("<iq type='error'><error type='cancel'><service-unavailable \(stanzas)/></error></iq>") as Iq
        guard case .unsupported = NodeRead(PubSubError.from(stanza: cancel)) else { Issue.record("not unsupported"); return }
    }

    @Test func anErrorWithNoConditionIsUndefined() throws {
        #expect(try #require(parse("<error/>")).condition == "undefined-condition")
        #expect(parse("<iq type='result'/>") == nil)
    }

    @Test func textIsOneLineAndCutShort() {
        #expect(ServerError(condition: "forbidden", text: "a\nb").text == "a b")
        #expect(ServerError(condition: "forbidden", text: "  \n ").text == nil)
        #expect(ServerError(condition: "forbidden", text: String(repeating: "x", count: 1000)).text?.count == ServerError.maxTextLength)
    }

    @Test func eachConditionHasItsRFC6120Type() {
        let expected: [String: ServerError.ErrorType] = [
            "bad-request": .modify, "conflict": .cancel, "feature-not-implemented": .cancel, "forbidden": .auth,
            "gone": .cancel, "internal-server-error": .cancel, "item-not-found": .cancel, "jid-malformed": .modify,
            "not-acceptable": .modify, "not-allowed": .cancel, "not-authorized": .auth, "policy-violation": .modify,
            "recipient-unavailable": .wait, "redirect": .modify, "registration-required": .auth,
            "remote-server-not-found": .cancel, "remote-server-timeout": .wait, "resource-constraint": .wait,
            "service-unavailable": .cancel, "subscription-required": .auth, "undefined-condition": .cancel,
            "unexpected-request": .wait,
        ]
        for (condition, type) in expected {
            #expect(ServerError(condition: condition).type == type, "\(condition)")
        }
    }

    @Test func martinsErrorsKeepTheirConditionAndText() {
        let error = ServerError(XMPPError.forbidden("No"))
        #expect(error == ServerError(condition: "forbidden", type: .auth, text: "No"))
        #expect(ServerError(XMPPError.remote_server_timeout).type == .wait)
        #expect(ServerError(XMPPError.recipient_unavailable(nil)).condition == "recipient-unavailable")
    }

    @Test func aRecipientUnavailableStanzaIsNotUndefinedForMartin() {
        let iq = parseStanza("<iq type='error'><error type='wait'><recipient-unavailable \(stanzas)/></error></iq>") as Iq
        #expect(XMPPError.parse(stanza: iq) == .recipient_unavailable(nil))
    }

    @Test func aPubSubErrorAddsItsOwnCondition() {
        let error = ServerError(PubSubError(error: .feature_not_implemented, pubsubErrorCondition: .unsupported))
        #expect(error.condition == "feature-not-implemented")
        #expect(error.detail == "unsupported")
        #expect(error.describe("Failed") == "Failed (feature-not-implemented, unsupported)")
    }

    @Test func anyErrorIsClassified() {
        #expect(ServerError.classify(XMPPError.remote_server_timeout).isPassing)
        #expect(ServerError.classify(PubSubError.remote_server_timeout).isPassing)
        #expect(ServerError.classify(URLError(.timedOut)).isPassing)
        #expect(ServerError.classify(URLError(.networkConnectionLost)).isPassing)
        #expect(ServerError.classify(TimeoutError()).isPassing)
        #expect(ServerError.classify(XMPPError.forbidden(nil)).isFinal)
        #expect(ServerError.classify(URLError(.badURL)).isFinal)
        #expect(ServerError.classify(CocoaError(.fileNoSuchFile)).isFinal)
    }

    @Test func cancelModifyAndAuthAreFinalAndWaitIsNot() {
        for type in [ServerError.ErrorType.cancel, .modify, .auth] {
            #expect(ServerError(condition: "x", type: type).isFinal)
        }
        #expect(!ServerError(condition: "x", type: .wait).isFinal)
        #expect(ServerError(condition: "x", type: .wait).isPassing)
        #expect(ServerError(condition: "x", type: .continue).isPassing)
    }

    @Test func notOfferedAndNotFoundAreTold() {
        #expect(ServerError(condition: "feature-not-implemented").isUnsupported)
        #expect(ServerError(condition: "service-unavailable").isUnsupported)
        #expect(!ServerError(condition: "item-not-found").isUnsupported)
        #expect(ServerError(condition: "item-not-found").isNotFound)
        #expect(!ServerError(condition: "internal-server-error").isNotFound)
    }

    @Test func describeGivesTheSentenceThenTheServersWordsAndCondition() {
        let withText = ServerError(condition: "recipient-unavailable", text: "User session not found")
        #expect(withText.describe("The message couldn't be delivered.") == "The message couldn't be delivered: User session not found (recipient-unavailable)")
        let without = ServerError(condition: "recipient-unavailable")
        #expect(without.describe("The message couldn't be delivered") == "The message couldn't be delivered (recipient-unavailable)")
    }

    @Test func theDiagnosticsLogHoldsTheConditionButNeverTheText() {
        let field = DiagField.error(ServerError(condition: "forbidden", text: "secret@example.org"))
        #expect(field.rendered.contains("condition=forbidden"))
        #expect(!field.rendered.contains("secret"))
        #expect(DiagField.error(PubSubError.remote_server_timeout).rendered.contains("condition=remote-server-timeout"))
    }

    @Test func aPubSubErrorKeepsTheTypeTheServerWrote() {
        let iq = parseStanza("<iq type='error'><error type='wait'><internal-server-error \(stanzas)/></error></iq>") as Iq
        let error = ServerError(PubSubError.from(stanza: iq))
        #expect(error.type == .wait)
        #expect(error.isPassing)
        let final = parseStanza("<iq type='error'><error type='cancel'><internal-server-error \(stanzas)/></error></iq>") as Iq
        #expect(ServerError(PubSubError.from(stanza: final)).isFinal)
    }

    @Test func aPubSubErrorWithoutATypeTakesTheConditionsOwn() {
        let iq = parseStanza("<iq type='error'><error><resource-constraint \(stanzas)/></error></iq>") as Iq
        #expect(ServerError(PubSubError.from(stanza: iq)).isPassing)
    }

    @Test func martinWritesTheTypesOfRFC6120() {
        #expect(ErrorCondition.internal_server_error.type == "cancel")
        #expect(ErrorCondition.gone.type == "cancel")
        #expect(ErrorCondition.policy_violation.type == "modify")
    }

    @Test func onlyAServersErrorsAreOneOfItsErrors() {
        #expect(ServerError(XMPPError.forbidden(nil)) == ServerError(condition: "forbidden"))
        #expect(ServerError(URLError(.timedOut) as Error) == nil)
        #expect(ServerError(CocoaError(.fileNoSuchFile) as Error) == nil)
        #expect(!DiagField.error(URLError(.timedOut)).rendered.contains("condition"))
    }
}
