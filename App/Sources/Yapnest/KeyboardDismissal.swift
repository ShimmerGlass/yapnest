import SwiftUI

extension View {
    /// Lets a tap on the background close the keyboard, and dragging the
    /// form too. A multi-line field takes Return as a newline, so a form
    /// otherwise has no way to put the keyboard away. Does nothing on the
    /// Mac, which has no on-screen keyboard.
    @ViewBuilder
    func dismissesKeyboardOnTap() -> some View {
        #if targetEnvironment(macCatalyst)
        self
        #else
        scrollDismissesKeyboard(.interactively)
            .background(KeyboardDismissalInstaller())
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
/// Puts a tap recognizer on the window while the view is in it. The
/// recognizer watches without taking the touch, so buttons, toggles and
/// rows still get their tap, and it ignores taps on a text input so
/// tapping another field moves focus instead of closing the keyboard, and
/// taps inside an alert.
private struct KeyboardDismissalInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        private let handler = Handler()
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: handler, action: #selector(Handler.tapped(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = handler
            return recognizer
        }()
        private weak var installedOn: UIWindow?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installedOn?.removeGestureRecognizer(recognizer)
            installedOn = window
            window?.addGestureRecognizer(recognizer)
        }
    }

    final class Handler: NSObject, UIGestureRecognizerDelegate {
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            recognizer.view?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextInput { return false }
                view = current.superview
            }
            // An alert with a text field sits in this window: a tap on its
            // buttons would put its keyboard away, and the alert moving back
            // down under the finger loses the tap.
            var responder: UIResponder? = touch.view
            while let current = responder {
                if current is UIAlertController { return false }
                responder = current.next
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
#endif
