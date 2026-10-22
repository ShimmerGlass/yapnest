import Foundation
import Testing
@testable import Martin

/// A control character in a body (a pasted terminal escape sequence) was written as it was, which
/// XML forbids; Prosody and ejabberd closed the stream on it, on every reconnect.
struct XMLEscapingTests {
    @Test func forbiddenCharactersAreDroppedFromTextAndAttributes() throws {
        let forbidden = (0x0...0x1F).filter { ![0x9, 0xA, 0xD].contains($0) }.compactMap(Unicode.Scalar.init).map(String.init).joined() + "\u{FFFE}\u{FFFF}"
        let message = Message()
        message.type = .chat
        message.id = "a\(forbidden)b"
        message.body = "bell \u{07} escape \u{1B}[0m end\(forbidden)"
        let xml = message.element.stringValue
        #expect(xml.unicodeScalars.allSatisfy { ![0x7, 0x1B, 0xFFFE, 0xFFFF].contains($0.value) })
        #expect(xml.contains("<body>bell  escape [0m end</body>"))
        #expect(xml.contains("id='ab'"))
        let parsed = try #require(Element.from(string: xml))
        #expect(parsed.firstChild(name: "body")?.value == "bell  escape [0m end")
    }

    @Test func everythingElseIsUnchanged() {
        let text = "tab\t lf\n cr\r plain é 🙂 日本 & < > \" '"
        #expect(EscapeUtils.escape(text) == "tab\t lf\n cr\r plain é 🙂 日本 &amp; &lt; &gt; &quot; &apos;")
        #expect(EscapeUtils.escape("") == "")
    }
}
