import AVFoundation
import ContactsUI
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import YapnestKit

/// The view controller that can present something right now: the top of the
/// stack, since the conversation is embedded in SwiftUI and may sit in a
/// split view's detail column or under a sheet.
@MainActor
enum Presenter {
    static var top: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var presenter = scene?.keyWindow?.rootViewController else { return nil }
        while let next = presenter.presentedViewController { presenter = next }
        return presenter
    }

    /// Counts what's presented here as a conversation sheet, as the menu
    /// bar's commands would otherwise queue their sheet behind it.
    weak static var model: AppModel?

    static func present(_ controller: UIViewController) {
        guard let top else { return }
        if let model {
            model.conversationSheetAppeared()
            // Released with the controller, whichever way it was dismissed:
            // a delegate, the swipe-down or QuickLook's own close.
            objc_setAssociatedObject(controller, &dismissalKey, DismissalToken { [weak model] in model?.conversationSheetDisappeared() }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        top.present(controller, animated: true)
    }

    nonisolated(unsafe) private static var dismissalKey = 0
}

private final class DismissalToken {
    private let onRelease: @MainActor () -> Void
    init(_ onRelease: @escaping @MainActor () -> Void) { self.onRelease = onRelease }
    deinit {
        let onRelease = onRelease
        Task { @MainActor in onRelease() }
    }
}

/// Picking photos, camera shots, files, places and contacts to add to the composer.
@MainActor
final class AttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate, UIDocumentPickerDelegate, @preconcurrency CNContactPickerDelegate {
    private unowned let model: ConversationModel

    /// Whether there is a camera, and whether it may be used, asked for if it
    /// isn't known yet. Tests replace them, as the real ones prompt.
    var cameraAvailable: () -> Bool = { UIImagePickerController.isSourceTypeAvailable(.camera) }
    var cameraAccess: () async -> Bool = {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    init(model: ConversationModel) {
        self.model = model
    }

    func attach(from source: ConversationInputBar.AttachmentSource) {
        guard model.refuseUnlessCanSend() else { return }
        switch source {
        case .photoLibrary:
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .any(of: [.images, .videos])
            config.selectionLimit = 10
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            Presenter.present(picker)
        case .camera:
            guard cameraAvailable() else {
                model.prompt = .notice(title: String(localized: "No camera"), message: String(localized: "This device has no camera available."))
                return
            }
            Task {
                // Asked first, as for calls, so a refusal is explained here
                // rather than left to the picker.
                guard await cameraAccess() else {
                    model.prompt = .notice(
                        title: String(localized: "No access to the camera"),
                        message: Platform.isMac
                            ? String(localized: "Turn it on for Yapnest in System Settings > Privacy & Security > Camera.")
                            : String(localized: "Turn it on for Yapnest in Settings > Yapnest."))
                    return
                }
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
                picker.delegate = self
                Presenter.present(picker)
            }
        case .file:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            Presenter.present(picker)
        case .location:
            model.showsLocationPicker = true
        case .contact:
            let picker = CNContactPickerViewController()
            picker.delegate = self
            Presenter.present(picker)
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let model = model
        model.preparing {
            // In order, so they arrive the way they were picked.
            for result in results {
                let provider = result.itemProvider
                let isImage = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                await model.stage(isPhoto: isImage) { try await Self.copy(from: provider, type: isImage ? .image : .movie) }
            }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        let model = model
        if let movie = info[.mediaURL] as? URL {
            // The camera's file isn't in a folder of ours, which discarding needs.
            model.preparing {
                await model.stage(isPhoto: false) { try await Self.copyIntoOwnFolder(movie) }
            }
        } else if let image = info[.originalImage] as? UIImage {
            model.preparing {
                await model.stage(isPhoto: true) { try await Self.writeJPEG(image) }
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let model = model
        model.preparing {
            for url in urls {
                await model.stage(isPhoto: false) { try await Self.copyIntoOwnFolder(url) }
            }
        }
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        let model = model
        // The contact isn't Sendable, so it is read here; only the file is written off the main thread.
        let data: Data
        do {
            data = try CNContactVCardSerialization.data(with: [contact])
        } catch {
            model.reportAttachFailure(error)
            return
        }
        var name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        if name.isEmpty { name = contact.organizationName }
        // The name becomes a path component and the file's name in the message.
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = String(localized: "Contact") }
        model.preparing {
            await model.stage(isPhoto: false) { try await Self.writeVCard(data, named: name) }
        }
    }

    /// Writes a contact's vCard off the main thread, in a folder of its own
    /// like `writeJPEG`.
    static func writeVCard(_ data: Data, named name: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try writeIntoOwnFolder(data, named: name + ".vcf")
        }.value
    }

    /// Encodes and writes a picture that only exists in memory, off the main
    /// thread. It goes in a folder of its own, which is what clearing a
    /// staged attachment removes.
    static func writeJPEG(_ image: UIImage) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let data = image.jpegData(compressionQuality: 0.95) else { throw CocoaError(.fileWriteUnknown) }
            return try writeIntoOwnFolder(data, named: "photo-\(UUID().uuidString.prefix(8)).jpg")
        }.value
    }

    /// Writes `data` as `name` in a new folder directly under the temporary
    /// directory, which is the layout `discardCopy` relies on. Blocking, so
    /// call it off the main thread.
    nonisolated static func writeIntoOwnFolder(_ data: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try data.write(to: file)
        return file
    }

    /// Copies a file the system handed over into a folder of our own, off the
    /// main thread, so `discardCopy` may delete it later.
    static func copyIntoOwnFolder(_ file: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyIntoUniqueFolder(file, under: FileManager.default.temporaryDirectory)
        }.value
    }

    /// Removes the folder `writeJPEG`, `writeVCard` or `copy` made for a file, once nothing
    /// needs it. Only a folder directly under the temporary directory goes:
    /// that is where they put their copies, and nothing else is theirs.
    nonisolated static func discardCopy(_ file: URL) {
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent() == temporary, folder != temporary else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copies the picked item out of the provider, whose file is deleted as
    /// soon as its callback returns.
    static func copy(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                let name = provider.suggestedName.map { url.pathExtension.isEmpty ? $0 : $0 + "." + url.pathExtension } ?? url.lastPathComponent
                do {
                    continuation.resume(returning: try FileManager.default.copyIntoUniqueFolder(url, named: name, under: FileManager.default.temporaryDirectory))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Opening a received or sent file in QuickLook.
@MainActor
enum QuickLookPresenter {
    /// Keeps QuickLook's data source alive while it's shown.
    private static var current: QuickLookCoordinator?

    static func show(_ file: URL, title: String, from id: Int64) {
        // The keyboard is still up when the composer has focus; dismissing it
        // under a running presentation leaves QuickLook's gestures unsettled.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let coordinator = QuickLookCoordinator(item: QuickLookItem(url: file, title: title)) {
            TransitionAnchors.view(for: id)
        }
        current = coordinator
        let controller = QLPreviewController()
        controller.dataSource = coordinator
        // QuickLook uses the delegate's transition view for its interactive
        // swipe-down dismissal; without one the gesture is unreliable.
        controller.delegate = coordinator
        Presenter.present(controller)
    }
}

/// The Mac's ways with a received or sent file: opened in the app the system
/// picks for it, Preview for a picture, or saved where the user chooses.
/// Both work on a copy under the attachment's own name, as the stored file
/// has a random one, which Preview would show as the title and the save
/// panel would offer.
@MainActor
enum MacFileActions {
    static func open(_ file: URL, named name: String, otherwise fallback: @escaping @MainActor @Sendable () -> Void) {
        Task {
            guard let copy = await named(file, name) else { return fallback() }
            UIApplication.shared.open(copy) { opened in
                if !opened { fallback() }
            }
        }
    }

    static func saveAs(_ file: URL, named name: String) {
        Task {
            guard let copy = await named(file, name) else { return }
            Presenter.present(UIDocumentPickerViewController(forExporting: [copy], asCopy: true))
        }
    }

    /// Off the main thread: a file can be a large video.
    private static func named(_ file: URL, _ name: String) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.copyIntoUniqueFolder(file, named: name, under: FileManager.default.temporaryDirectory)
        }.value
    }
}

@MainActor
private final class QuickLookCoordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
    let item: QuickLookItem
    private let transitionView: () -> UIView?

    init(item: QuickLookItem, transitionView: @escaping () -> UIView?) {
        self.item = item
        self.transitionView = transitionView
    }

    func previewController(_ controller: QLPreviewController, transitionViewFor item: any QLPreviewItem) -> UIView? {
        transitionView()
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
}

private final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// The picture of each attachment on screen, which QuickLook zooms from and
/// back to, so its interactive swipe-down dismissal has something to shrink
/// into. SwiftUI has no view to hand it, so each attachment drops a UIView
/// behind itself that sits exactly where it is.
@MainActor
enum TransitionAnchors {
    private final class Weak { weak var view: UIView?; init(_ view: UIView) { self.view = view } }
    private static var anchors: [Int64: Weak] = [:]

    static func view(for id: Int64) -> UIView? { anchors[id]?.view }

    static func register(_ view: UIView, for id: Int64) { anchors[id] = Weak(view) }

    static func unregister(_ view: UIView, for id: Int64) {
        if anchors[id]?.view === view { anchors[id] = nil }
    }
}

struct TransitionAnchor: UIViewRepresentable {
    let id: Int64

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.anchorID = id
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.anchorID = id
    }

    final class AnchorView: UIView {
        var anchorID: Int64? {
            didSet {
                if let oldValue, oldValue != anchorID { TransitionAnchors.unregister(self, for: oldValue) }
                if let anchorID { TransitionAnchors.register(self, for: anchorID) }
            }
        }
    }
}
