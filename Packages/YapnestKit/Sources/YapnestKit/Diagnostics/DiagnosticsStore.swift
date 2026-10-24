import Foundation

/// One process's log files: `<process>.log`, and `<process>.1.log` once that
/// one passed its size. Each process writes only its own, so no locking
/// between processes is needed. Lines are buffered and written every couple
/// of seconds, or at once by `flush()`.
public final class DiagnosticsStore: @unchecked Sendable {
    public let directory: URL
    public let process: DiagProcess
    private let maxFileBytes: Int
    private let flushInterval: TimeInterval
    private let queue: DispatchQueue

    // Everything below is touched only on `queue`.
    private var buffer = Data()
    private var flushScheduled = false
    private var handle: FileHandle?
    private var size = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public init(directory: URL, process: DiagProcess, maxFileBytes: Int = 1_000_000, flushInterval: TimeInterval = 2) {
        self.directory = directory
        self.process = process
        self.maxFileBytes = maxFileBytes
        self.flushInterval = flushInterval
        queue = DispatchQueue(label: "fr.yapnest.diagnostics.\(process.rawValue)")
    }

    var currentFile: URL { directory.appending(path: "\(process.rawValue).log") }
    var previousFile: URL { directory.appending(path: "\(process.rawValue).1.log") }

    /// `text` is the message with its fields, already rendered.
    func append(date: Date, category: DiagCategory, level: DiagLevel, text: String) {
        queue.async {
            let line = "\(self.formatter.string(from: date)) \(self.process.rawValue) \(category.rawValue) \(level.rawValue) \(text)\n"
            self.buffer.append(contentsOf: line.utf8)
            if self.buffer.count >= 64 * 1024 {
                self.writeBuffer()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + self.flushInterval) {
                    self.flushScheduled = false
                    self.writeBuffer()
                }
            }
        }
    }

    /// Writes what's buffered and returns once it's on disk.
    public func flush() {
        queue.sync { writeBuffer() }
    }

    /// Like `flush()`, without waiting for the disk.
    func flushSoon() {
        queue.async { self.writeBuffer() }
    }

    private func writeBuffer() {
        guard !buffer.isEmpty else { return }
        let data = buffer
        buffer = Data()
        do {
            if handle == nil { try openCurrent() }
            if size > 0, size + data.count > maxFileBytes { try rotate() }
            try handle?.write(contentsOf: data)
            size += data.count
        } catch {
            // The log can't report its own failure, so these lines are lost.
            handle = nil
        }
    }

    private func openCurrent() throws {
        try FileManager.default.createProtectedDirectory(at: directory)
        if !FileManager.default.fileExists(atPath: currentFile.path) {
            FileManager.default.createFile(atPath: currentFile.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: currentFile)
        size = Int(try opened.seekToEnd())
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previousFile)
        try FileManager.default.moveItem(at: currentFile, to: previousFile)
        try openCurrent()
    }
}
