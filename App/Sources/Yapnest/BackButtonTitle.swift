import SwiftUI

/// Titles the back button of the screen it's in, such as with a chat's count
/// of what's unread elsewhere, when back leads to the stack's first screen.
/// SwiftUI only titles back after the previous screen, so this sets that
/// screen's `backButtonTitle`. Kept in the system's button, the count gets
/// its look and its swipe back. The bar redraws as `backButtonTitle`
/// changes, unlike the title of a `backBarButtonItem`, which it keeps
/// drawing as it was when the screen was pushed.
struct BackButtonTitle: UIViewControllerRepresentable {
    /// The previous screen's own title if nil.
    let title: String?

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.backTitle = title
        controller.apply()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        var backTitle: String?
        /// The item under the screen, which outlives it: the next screen
        /// pushed over the list, such as the archive, would show the count.
        private weak var item: UINavigationItem?
        /// Which screen titled each item last. A chat swapped for another in
        /// place (`.id(peer)`) can be dismantled after the new one titled it.
        private static let owners = NSMapTable<UINavigationItem, Controller>.weakToWeakObjects()

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        /// A screen being pushed isn't in the stack yet when it's made.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        func apply() {
            // The screen is the ancestor the navigation controller holds.
            var screen = parent
            while let current = screen, !(current.parent is UINavigationController) { screen = current.parent }
            guard let screen, let stack = screen.navigationController?.viewControllers,
                  stack.firstIndex(of: screen) == 1 else { return }
            let item = stack[0].navigationItem
            self.item = item
            item.backButtonTitle = backTitle
            Self.owners.setObject(self, forKey: item)
        }

        func restore() {
            guard let item, Self.owners.object(forKey: item) === self else { return }
            item.backButtonTitle = nil
        }
    }
}
