import Intents
import SwiftUI
import UIKit
import YapnestKit

/// The share sheet's entry point: hosts the SwiftUI picker and ends the
/// extension's request when it's done.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
        AppDatabase.trapsMainThreadAccess = true
        #endif
        let context = extensionContext
        // A tap on a suggestion at the top of the share sheet names its chat.
        let suggested = (context?.intent as? INSendMessageIntent)?.conversationIdentifier.flatMap(JID.init(_:))
        let model = ShareModel(items: context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [], suggested: suggested)
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}
