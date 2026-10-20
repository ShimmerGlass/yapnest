import Foundation
import os

/// The diagnostics log, which the user can export to help find a problem.
/// What goes in is a fixed message and typed fields (`DiagField`), so no
/// address, name or body can end up in it. Identifiers go through
/// `Redacted.id`.
public enum DiagLog {
    private static let shared = DiagnosticsStore(
        directory: SharedContainer.url.appending(path: "Logs"),
        process: .current,
    )

    /// This process's store.
    public static var store: DiagnosticsStore { shared }

    public static func debug(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        write(.debug, category, message, fields, to: shared)
    }

    public static func info(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        write(.info, category, message, fields, to: shared)
    }

    public static func notice(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        write(.notice, category, message, fields, to: shared)
    }

    public static func error(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        write(.error, category, message, fields, to: shared)
    }

    /// Writes what's buffered, for when the app goes to the background.
    public static func flush() {
        shared.flush()
    }

    static func write(_ level: DiagLevel, _ category: DiagCategory, _ message: StaticString, _ fields: [DiagField], to store: DiagnosticsStore) {
        let text = String(message.description.map { $0 == "\n" || $0 == "\r" ? " " : $0 })
        store.append(date: Date(), category: category, level: level, message: text, fields: fields)
        let summary = fields.reduce(text) { $0 + " \($1.key)=\($1.rendered)" }
        let logger = Logger(subsystem: "Yapnest", category: category.rawValue)
        // The message is static and the fields typed, so none of it is private.
        switch level {
        case .debug: logger.debug("\(summary, privacy: .public)")
        case .info: logger.info("\(summary, privacy: .public)")
        case .notice: logger.notice("\(summary, privacy: .public)")
        case .error: logger.error("\(summary, privacy: .public)")
        }
    }
}
