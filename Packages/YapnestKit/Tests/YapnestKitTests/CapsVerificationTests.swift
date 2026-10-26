import Foundation
import Martin
import Testing
@testable import Martin

/// A caps answer is cached for everyone who shows its node#ver, so it is
/// only believed if it hashes to that ver (XEP-0115 §5.4).
struct CapsVerificationTests {
    private func query(_ xml: String) -> Element {
        Element.from(string: "<query xmlns='http://jabber.org/protocol/disco#info'>\(xml)</query>")!
    }

    private let features = """
    <feature var='http://jabber.org/protocol/caps'/><feature var='http://jabber.org/protocol/disco#info'/>\
    <feature var='http://jabber.org/protocol/disco#items'/><feature var='http://jabber.org/protocol/muc'/>
    """

    /// XEP-0115 §5.2.
    @Test func theSimpleExampleHashesAsTheSpecSays() {
        let answer = query("<identity category='client' name='Exodus 0.9.1' type='pc'/>" + features)
        #expect(CapabilitiesModule.verificationString(of: answer, hash: "sha-1") == "QgayPKawpkPSDYmwT/WM94uAlu0=")
    }

    /// XEP-0115 §5.3: two languages, and an extended form.
    @Test func theComplexExampleHashesAsTheSpecSays() {
        let answer = query("""
        <identity xml:lang='en' category='client' name='Psi 0.11' type='pc'/>\
        <identity xml:lang='el' category='client' name='Ψ 0.11' type='pc'/>\(features)\
        <x xmlns='jabber:x:data' type='result'>\
        <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:dataforms:softwareinfo</value></field>\
        <field var='ip_version'><value>ipv4</value><value>ipv6</value></field>\
        <field var='os'><value>Mac</value></field><field var='os_version'><value>10.5.1</value></field>\
        <field var='software'><value>Psi</value></field><field var='software_version'><value>0.11</value></field>\
        </x>
        """)
        #expect(CapabilitiesModule.verificationString(of: answer, hash: "sha-1") == "q07IKJEyjvHSyhy//CH0CxmKi8w=")
    }

    /// Someone claiming a popular client's ver and answering without video.
    @Test func anAnswerThatDoesntMatchItsVerIsntItsVer() {
        let forged = query("<identity category='client' name='Exodus 0.9.1' type='pc'/><feature var='http://jabber.org/protocol/caps'/>")
        #expect(CapabilitiesModule.verificationString(of: forged, hash: "sha-1") != "QgayPKawpkPSDYmwT/WM94uAlu0=")
    }

    @Test func whatTheSpecSaysNotToCacheHasNoString() {
        let repeated = query("<identity category='client' type='pc'/>" + features + "<feature var='http://jabber.org/protocol/muc'/>")
        #expect(CapabilitiesModule.verificationString(of: repeated, hash: "sha-1") == nil)
        let twoTypes = query("""
        <identity category='client' type='pc'/><x xmlns='jabber:x:data' type='result'>\
        <field var='FORM_TYPE' type='hidden'><value>a</value><value>b</value></field></x>
        """)
        #expect(CapabilitiesModule.verificationString(of: twoTypes, hash: "sha-1") == nil)
        // A hash we can't compute can't be checked.
        #expect(CapabilitiesModule.verificationString(of: query(features), hash: "md5") == nil)
        #expect(CapabilitiesModule.verificationString(of: query(features), hash: nil) == nil)
    }

    /// Our own presence's ver is checked by others the same way.
    @Test func ourOwnVerPassesTheCheck() throws {
        let module = CapabilitiesModule()
        let identity = "client/phone//Yapnest"
        let own = try #require(module.generateVerificationString([identity], features: ["urn:xmpp:jingle:1", "http://jabber.org/protocol/caps"]))
        let answer = query("<identity category='client' type='phone' name='Yapnest'/><feature var='urn:xmpp:jingle:1'/><feature var='http://jabber.org/protocol/caps'/>")
        #expect(CapabilitiesModule.verificationString(of: answer, hash: "sha-1") == own)
    }
}
