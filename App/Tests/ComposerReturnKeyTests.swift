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
