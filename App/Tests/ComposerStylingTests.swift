import Testing
import UIKit
import YapnestKit
@testable import Yapnest

/// The composer shows the styles a message will have while the text stays as typed.
@MainActor
struct ComposerStylingTests {
    private func makeBar() -> ConversationInputBar {
        ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    }

    private func attributes(_ bar: ConversationInputBar, at location: Int) -> [NSAttributedString.Key: Any] {
        bar.textView.textStorage.attributes(at: location, effectiveRange: nil)
    }

    private func font(_ bar: ConversationInputBar, at location: Int) -> UIFont {
        attributes(bar, at: location)[.font] as! UIFont
    }

    private func isDimmed(_ bar: ConversationInputBar, at location: Int) -> Bool {
        (attributes(bar, at: location)[.foregroundColor] as? UIColor) == .secondaryLabel
    }

    private func isBold(_ font: UIFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(.traitBold) }
    private func isItalic(_ font: UIFont) -> Bool { font.fontDescriptor.symbolicTraits.contains(.traitItalic) }
    private func isMonospace(_ font: UIFont) -> Bool { font.fontName.contains("Mono") }

    private let sample = "*bold* _it_ ~s~ `c` plain"

    @Test func styledTextIsDrawnAndItsMarkersDimmed() {
        let bar = makeBar()
        bar.setText(sample, notify: false)
        #expect(isBold(font(bar, at: 3)))
        #expect(isItalic(font(bar, at: 9)))
        #expect(attributes(bar, at: 14)[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(isMonospace(font(bar, at: 17)))
        for marker in [0, 5, 7, 10, 12, 14, 16, 18] {
            #expect(isDimmed(bar, at: marker), "marker at \(marker)")
        }
        #expect(!isDimmed(bar, at: 3))
        #expect(!isBold(font(bar, at: 21)))
        #expect(!isDimmed(bar, at: 21))
    }

    @Test func theTextIsNotChanged() {
        let bar = makeBar()
        bar.setText(sample, notify: false)
        #expect(bar.text == sample)
        #expect(bar.textView.selectedRange.length == 0)
    }

    @Test func theSelectionSurvivesRestyling() {
        let bar = makeBar()
        bar.setText(sample, notify: false)
        bar.textView.selectedRange = NSRange(location: 2, length: 4)
        bar.textView.restyle()
        #expect(bar.textView.selectedRange == NSRange(location: 2, length: 4))
    }

    @Test func typingRightAfterAClosedSpanIsNotStyled() {
        let bar = makeBar()
        bar.setText("*bold*", notify: false)
        bar.textView.selectedRange = NSRange(location: 6, length: 0)
        bar.textView.insertText("x")
        #expect(bar.text == "*bold*x")
        #expect(!isBold(font(bar, at: 6)))
        #expect(!isBold(font(bar, at: 3)))
        #expect(!isDimmed(bar, at: 5))
    }

    @Test func typingTheCloserStylesTheSpanAndTheNextCharacterIsPlain() {
        let bar = makeBar()
        bar.setText("*bold", notify: false)
        bar.textView.selectedRange = NSRange(location: 5, length: 0)
        #expect(!isBold(font(bar, at: 2)))
        bar.textView.insertText("*")
        #expect(isBold(font(bar, at: 2)))
        let typing = bar.textView.typingAttributes[.font] as? UIFont
        #expect(typing.map { !isBold($0) } == true)
    }

    @Test func anUnclosedMarkerHasNoStyle() {
        let bar = makeBar()
        bar.setText("*not closed _either", notify: false)
        for index in 0..<bar.text.utf16.count {
            #expect(!isBold(font(bar, at: index)) && !isItalic(font(bar, at: index)) && !isDimmed(bar, at: index))
        }
    }

    @Test func aFencedBlockHasNoStyle() {
        let bar = makeBar()
        let text = "```\n*raw* _raw_\n```\n*real*"
        bar.setText(text, notify: false)
        #expect(!isBold(font(bar, at: 5)) && !isDimmed(bar, at: 4))
        #expect(isBold(font(bar, at: (text as NSString).range(of: "real").location)))
    }

    @Test func removingTheCloserTakesTheStyleAway() {
        let bar = makeBar()
        bar.setText("*bold*", notify: false)
        bar.setText("*bold", notify: false)
        #expect(!isBold(font(bar, at: 2)) && !isDimmed(bar, at: 0))
    }

    @Test func undoPutsTheTextBackAndStylesItAgain() throws {
        let bar = makeBar()
        let field = bar.textView
        let manager = try #require(field.undoManager)
        bar.setText("*bold", notify: false)
        field.selectedRange = NSRange(location: 5, length: 0)
        manager.beginUndoGrouping()
        field.insertText("*")
        manager.endUndoGrouping()
        #expect(bar.text == "*bold*")
        #expect(isBold(font(bar, at: 2)))
        manager.undo()
        bar.textViewDidChange(field)
        #expect(bar.text == "*bold")
        #expect(!isBold(font(bar, at: 2)))
        manager.redo()
        bar.textViewDidChange(field)
        #expect(bar.text == "*bold*")
        #expect(isBold(font(bar, at: 2)))
    }

    @Test func restylingRegistersNothingForUndo() throws {
        let bar = makeBar()
        let manager = try #require(bar.textView.undoManager)
        bar.setText("*bold*", notify: false)
        #expect(!manager.canUndo)
        bar.textView.restyle()
        #expect(!manager.canUndo)
    }

    @Test func restylingDoesNotCallTheDelegate() {
        let bar = makeBar()
        var changes = 0
        bar.onTextChanged = { _ in changes += 1 }
        bar.setText("*bold*", notify: true)
        #expect(changes == 1)
        bar.textView.restyle()
        #expect(changes == 1)
    }

    @Test func aRestoredDraftAndAnEditStartAreStyled() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("an *edit* here", .outgoing)
        try f.database.setDraft("draft with _it_", peer: f.peer)
        await f.start()
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        bar.onTextChanged = { [weak model = f.model] text in model?.textChanged(text) }
        f.model.composer.bar = bar
        f.model.composerAttached()
        #expect(bar.text == "draft with _it_")
        #expect(isItalic(font(bar, at: 13)))
        f.model.startEditing(mine.id!)
        #expect(bar.text == "an *edit* here")
        #expect(isBold(font(bar, at: 6)))
        f.model.cancelReplyOrEdit()
        #expect(bar.text == "draft with _it_")
        #expect(isItalic(font(bar, at: 13)) && !isBold(font(bar, at: 6)))
    }

    @Test func aMentionInsertedThroughTheBarKeepsTheStyling() {
        let bar = makeBar()
        bar.setText("*bold* @al", notify: false)
        bar.textView.selectedRange = NSRange(location: 10, length: 0)
        bar.setSuggestions(["alice"])
        bar.textView.insertText("i")
        #expect(isBold(font(bar, at: 3)))
    }

    @Test func aLongTextIsRestyledWellWithinAFrame() {
        let bar = makeBar()
        let text = String(repeating: "word *bold* _it_ ~s~ `c` plain text here\n", count: 190)
        bar.setText(text, notify: false)
        let clock = ContinuousClock()
        let time = (0..<3).map { _ in clock.measure { bar.textView.restyle() } }.min()!
        #expect(time < .milliseconds(50), "\(time)")
    }
}
