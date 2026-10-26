import Foundation
import UniformTypeIdentifiers

/// Which received files the Mac may hand to the app the system picks for
/// them. Opening a file launches whatever owns its extension, and the name
/// is the sender's: `.terminal`, `.command`, `.fileloc`, `.pkg` or
/// `.shortcut` start Terminal, Finder, Installer or Shortcuts. Only media
/// and PDFs pass, an allow-list rather than a list of what's dangerous;
/// everything else is previewed in QuickLook, which shows a file without
/// running it.
public enum MacOpenPolicy {
    /// Decided by the name's extension alone, never a type the sender gave.
    public static func opensInDefaultApp(name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        // Vector images can run script in a browser, and anything that is
        // also code or an app is refused whatever else it claims to be.
        let refused: [UTType] = [.executable, .application, .script, .sourceCode, .html, .xml, .svg, .bundle]
        if refused.contains(where: { type.conforms(to: $0) }) { return false }
        return [UTType.image, .movie, .audio, .pdf].contains { type.conforms(to: $0) }
    }
}
