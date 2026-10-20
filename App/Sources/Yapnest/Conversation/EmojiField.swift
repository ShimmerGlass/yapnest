import UIKit

/// An invisible field that brings up the emoji keyboard and hands back
/// the first emoji typed into it.
final class EmojiField: UITextField, UITextFieldDelegate {
    var onPick: ((String) -> Void)?
    /// Where in the window to show the Mac's character viewer, which opens
    /// by the caret. The field itself sits out of sight in the middle of
    /// the conversation, so without this the viewer opens there.
    var anchor: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        alpha = 0.01
        autocorrectionType = .no
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The emoji keyboard, when it's one of the user's keyboards.
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        CharacterPalette.show()
        return true
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        guard let anchor else { return super.caretRect(for: position) }
        return convert(CGRect(x: anchor.minX, y: anchor.minY, width: 1, height: anchor.height), from: nil)
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        guard let anchor else { return super.firstRect(for: range) }
        return convert(anchor, from: nil)
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let emoji = string.first(where: \.isEmoji) else { return false }
        onPick?(String(emoji))
        onPick = nil
        resignFirstResponder()
        return false
    }
}

private extension Character {
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        // Digits and # are emoji too, but only when something follows.
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}
