import Foundation

/// Gathers every process's log into one text file the user can share.
public enum DiagnosticsExport {
    /// Flushes this process, merges all the processes' lines by time under a
    /// header, and returns the file in a fresh temporary folder. The header
    /// holds no identifiers. `date` is the export time. Exports in `root`
    /// older than `keepFor` seconds are deleted so logs don't pile up in tmp;
    /// a newer one may still be waiting to be shared, or be written by a
    /// concurrent call.
    public static func make(
        at date: Date = Date(),
        store: DiagnosticsStore = DiagLog.store,
        root: URL = FileManager.default.temporaryDirectory.appending(path: "YapnestDiagnostics"),
        keepFor: TimeInterval = 60
    ) throws -> URL {
        store.flush()
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var lines: [(stamp: Substring, order: Int, text: Substring)] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                lines.append((line.prefix(20), lines.count, line))
            }
        }
        // The timestamps are fixed-width UTC, so they sort as text. They are
        // to the second, so the order breaks ties: a file's own lines are in
        // order already, and the processes' lines within a second are grouped
        // by file.
        lines.sort { ($0.stamp, $0.order) < ($1.stamp, $1.order) }

        var output = header(at: date) + "\n"
        for line in lines { output += line.text + "\n" }

        let older = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for old in older {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > keepFor {
                try? fm.removeItem(at: old)
            }
        }
        let folder = root.appending(path: UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Yapnest-diagnostics.txt")
        try Data(output.utf8).write(to: url, options: .atomic)
        return url
    }

    static func header(at date: Date) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = TimeZone(identifier: "UTC")
        return """
        Yapnest diagnostics
        App: \(version) (\(build))
        Platform: \(platform)
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Device: \(deviceModel)
        Exported: \(format.string(from: date))
        """
    }

    private static var platform: String {
        #if targetEnvironment(macCatalyst)
        "Mac Catalyst"
        #elseif os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    private static var deviceModel: String {
        #if targetEnvironment(macCatalyst) || os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }
}
