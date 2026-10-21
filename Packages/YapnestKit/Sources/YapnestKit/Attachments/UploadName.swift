import Foundation

enum UploadName {
    /// The name an upload slot is requested under. An encrypted file gets a
    /// random one so the upload server learns nothing from it; the extension
    /// stays because receiving clients use it to decide how to show the file.
    static func slotName(for name: String, encrypted: Bool) -> String {
        guard encrypted else { return name }
        let ext = (name as NSString).pathExtension
        let id = UUID().uuidString.lowercased()
        return ext.isEmpty ? id : "\(id).\(ext)"
    }
}
