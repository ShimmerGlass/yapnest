import Observation
import SwiftUI
import YapnestKit

/// Builds the diagnostics file for Settings and the Mac's Help menu, and shows
/// the share sheet for it, or on the Mac the save panel, as Save As… does for
/// an attachment. The file is made off the main thread, as it reads every
/// process's log.
@MainActor @Observable
final class DiagnosticsExporter {
    private(set) var isExporting = false
    /// The file whose share sheet is up, until it is dismissed.
    private(set) var presented: URL?
    var error: String?

    private let make: @Sendable () throws -> URL
    private let present: @MainActor (URL, _ finished: @escaping @MainActor () -> Void) -> Void

    init(
        make: @escaping @Sendable () throws -> URL = { try DiagnosticsExport.make() },
        present: @escaping @MainActor (URL, _ finished: @escaping @MainActor () -> Void) -> Void = Platform.isMac ? DiagnosticsExporter.presentSavePanel : DiagnosticsExporter.presentShareSheet,
    ) {
        self.make = make
        self.present = present
    }

    func start() async {
        guard !isExporting, presented == nil else { return }
        isExporting = true
        defer { isExporting = false }
        let make = make
        do {
            let url = try await offMain { try make() }
            presented = url
            present(url) { [weak self] in self?.presented = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Presented through UIKit from whatever is on top, so it shows over a
    /// sheet, and as a popover where the system draws one: a sheet's content
    /// is the wrong place for it on the Mac.
    static func presentShareSheet(_ url: URL, finished: @escaping @MainActor () -> Void) {
        guard let top = Presenter.top else {
            finished()
            return
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "diagnosticsShareSheet"
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in finished() }
        }
        if UIDevice.current.userInterfaceIdiom != .phone, let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    static func presentSavePanel(_ url: URL, finished: @escaping @MainActor () -> Void) {
        guard Presenter.top != nil else {
            finished()
            return
        }
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = SavePanelDelegate(finished)
        controller.delegate = delegate
        // The picker holds its delegate weakly.
        objc_setAssociatedObject(controller, &savePanelDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        Presenter.present(controller)
    }

    nonisolated(unsafe) private static var savePanelDelegateKey = 0
}

private final class SavePanelDelegate: NSObject, UIDocumentPickerDelegate {
    private let finished: @MainActor () -> Void
    init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated { finished() }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { finished() }
    }
}

extension View {
    func diagnosticsErrorAlert(_ exporter: DiagnosticsExporter) -> some View {
        errorAlert("Couldn't export the logs", Bindable(exporter).error)
    }
}
