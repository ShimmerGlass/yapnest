import Foundation

/// Recognizes a message that is a file, the way Conversations and other
/// clients send them: the body is just the file's URL, `aesgcm://` when
/// encrypted, or an `https://` URL repeated in a XEP-0066 `<x>` element.
/// Plain `http://` counts only for development servers (`allowsInsecure`),
/// as a downloaded link makes the device send a request unasked.
enum AttachmentLink {
    static func parse(body: String?, oob: String?, allowsInsecure: Bool = false) -> (url: URL, name: String)? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.contains(where: \.isWhitespace),
              let url = URL(string: body), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "aesgcm": break
        case "https": guard oob == body else { return nil }
        case "http": guard allowsInsecure, oob == body else { return nil }
        default: return nil
        }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return (url, name.isEmpty || name == "/" ? "file" : name)
    }
}
