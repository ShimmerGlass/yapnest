import Testing
import UIKit
@testable import Yapnest

/// On the Mac, Return sends and its modified forms start a new line.
@MainActor
struct ComposerReturnKeyTests {
    private func returnAction(_ flags: UIKeyModifierFlags) throws -> Selector? {
        let field = ComposerTextView()
        field.returnSends = true
        let commands = try #require(field.keyCommands)
        return commands.first { $0.input == "\r" && $0.modifierFlags == flags }?.action
    }

    @Test func returnSends() throws {
        #expect(try returnAction([]) == NSSelectorFromString("sendFromKeyboard"))
    }

    /// Without a command of its own, Shift-Return fell through to the plain
    /// Return command and sent the message.
    @Test(arguments: [UIKeyModifierFlags.shift, .alternate, .command])
    func modifiedReturnStartsALine(_ flags: UIKeyModifierFlags) throws {
        #expect(try returnAction(flags) == NSSelectorFromString("insertNewLine"))
    }
}

/// Escape ends a reply or an edit, once suggestions have had the key.
@MainActor
struct ComposerEscapeKeyTests {
    private func escape(replying: Bool, suggesting: Bool) throws -> Selector? {
        let field = ComposerTextView()
        field.onCancelReply = {}
        field.hasReplyToCancel = { replying }
        field.capturesSuggestionKeys = { suggesting }
        let commands = try #require(field.keyCommands)
        return commands.first { $0.input == UIKeyCommand.inputEscape }?.action
    }

    @Test func escapeCancelsAReplyOrEdit() throws {
        #expect(try escape(replying: true, suggesting: false) == NSSelectorFromString("cancelReply"))
    }

    @Test func suggestionsGetEscapeFirst() throws {
        #expect(try escape(replying: true, suggesting: true) == NSSelectorFromString("suggestionDismiss"))
    }

    @Test func escapeIsLeftAloneWithNothingToCancel() throws {
        #expect(try escape(replying: false, suggesting: false) == nil)
    }

    @Test func escapeCallsTheCancel() throws {
        let field = ComposerTextView()
        var cancelled = false
        field.onCancelReply = { cancelled = true }
        field.perform(NSSelectorFromString("cancelReply"))
        #expect(cancelled)
    }
}
