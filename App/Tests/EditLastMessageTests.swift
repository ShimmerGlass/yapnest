import Testing
import UIKit
import YapnestKit
@testable import Yapnest

@MainActor
struct EditLastMessageTests {
    private func attach(_ f: ConversationFixture) -> ConversationInputBar {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        bar.onTextChanged = { [weak model = f.model] text in model?.textChanged(text) }
        f.model.composer.bar = bar
        f.model.composerAttached()
        return bar
    }

    @Test func theNewestEditableMessageOfOursIsEdited() async throws {
        let f = try ConversationFixture()
        let older = try f.add("older", .outgoing)
        let withFile = try f.add("with a file", .outgoing)
        try f.attach("a.png", to: withFile)
        let retracted = try f.add("gone", .outgoing)
        try await f.database.writer.write { try $0.execute(sql: "UPDATE message SET isRetracted = 1 WHERE id = ?", arguments: [retracted.id]) }
        // A call row is ours with no words; editing it would turn the call into text.
        let call = try f.add("", .outgoing)
        try await f.database.writer.write { try $0.execute(sql: "UPDATE message SET callOutcome = 'answered' WHERE id = ?", arguments: [call.id]) }
        try f.add("theirs", .incoming)
        let bar = attach(f)
        await f.start()
        f.model.setOnScreen(true)
        bar.setText("half typed", notify: true)

        #expect(f.model.editLastMessage())
        #expect(f.model.editingItem?.id == older.id)
        #expect(bar.text == "older")

        f.model.cancelReplyOrEdit()
        #expect(bar.text == "half typed")
    }

    @Test func aReplyBeingWrittenIsLeftAlone() async throws {
        let f = try ConversationFixture()
        try f.add("mine", .outgoing)
        let theirs = try f.add("theirs", .incoming)
        _ = attach(f)
        await f.start()
        f.model.reply(to: theirs.id!)

        #expect(!f.model.editLastMessage())
        #expect(f.model.replyingTo?.id == theirs.id)
        #expect(f.model.editingItem == nil)
    }

    /// A group left or a contact blocked has a bar in the composer's place;
    /// an edit begun there would come back later in place of the draft.
    @Test func nothingHappensWithoutAComposer() async throws {
        let f = try ConversationFixture()
        try f.add("mine", .outgoing)
        await f.start()

        #expect(!f.model.editLastMessage())
        #expect(f.model.editingItem == nil)
    }

    @Test func nothingHappensWithoutAMessageToEdit() async throws {
        let f = try ConversationFixture()
        try f.add("theirs", .incoming)
        _ = attach(f)
        await f.start()
        #expect(!f.model.editLastMessage())
        #expect(f.model.editingItem == nil)
    }

    @Test func nothingHappensInAWindowShortOfTheNewestMessages() async throws {
        let f = try ConversationFixture()
        let first = try f.add("first", .outgoing)
        // Past the window's limit, so opening at the first leaves the newest out.
        try f.addMany(1700)
        f.reopen(openingAt: first.id)
        _ = attach(f)
        await f.start()
        await eventually("the bounded window never opened") { f.model.isBounded }
        #expect(!f.model.editLastMessage())
        #expect(f.model.editingItem == nil)
    }

    private func upArrow(_ text: String, returnSends: Bool = true, suggestions: Bool = false) -> Bool {
        let field = ComposerTextView()
        field.returnSends = returnSends
        field.onEditLast = {}
        field.capturesSuggestionKeys = { suggestions }
        field.text = text
        return field.keyCommands?.contains { $0.input == UIKeyCommand.inputUpArrow && $0.action == NSSelectorFromString("editLastMessage") } == true
    }

    @Test func upArrowEditsOnlyFromAnEmptyFieldOnTheMac() {
        #expect(upArrow(""))
        #expect(!upArrow("typed"))
        #expect(!upArrow("", returnSends: false))
        #expect(!upArrow("", suggestions: true))
    }
}
