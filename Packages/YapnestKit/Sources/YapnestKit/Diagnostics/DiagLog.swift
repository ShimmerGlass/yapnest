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

    private static let override = OSAllocatedUnfairLock<DiagnosticsStore?>(initialState: nil)

    /// This process's store.
    public static var store: DiagnosticsStore { override.withLock { $0 } ?? shared }

    /// Sends the log to `store` instead, for the tests.
    static func use(_ store: DiagnosticsStore?) {
        override.withLock { $0 = store }
    }

    /// Deletes the log and the key its ids are hashed with, for signing out.
    public static func reset() {
        store.reset()
        Redacted.reset()
    }

    public static func debug(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        debug(category, message, fields: fields)
    }

    public static func info(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        info(category, message, fields: fields)
    }

    public static func notice(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        notice(category, message, fields: fields)
    }

    public static func error(_ category: DiagCategory, _ message: StaticString, _ fields: DiagField...) {
        error(category, message, fields: fields)
    }

    /// For a line whose fields depend on what was measured, which a variadic
    /// call can't leave out.
    public static func debug(_ category: DiagCategory, _ message: StaticString, fields: [DiagField]) {
        log(.debug, category, message, fields)
    }

    public static func info(_ category: DiagCategory, _ message: StaticString, fields: [DiagField]) {
        log(.info, category, message, fields)
    }

    public static func notice(_ category: DiagCategory, _ message: StaticString, fields: [DiagField]) {
        log(.notice, category, message, fields)
    }

    public static func error(_ category: DiagCategory, _ message: StaticString, fields: [DiagField]) {
        log(.error, category, message, fields)
    }

    /// Writes what's buffered without waiting, for the main thread.
    public static func flushSoon() {
        store.flushSoon()
    }

    static func log(_ level: DiagLevel, _ category: DiagCategory, _ message: StaticString, _ fields: [DiagField]) {
        write(level, category, message, fields, to: store)
    }

    /// Writes what's buffered, for when the app goes to the background.
    public static func flush() {
        store.flush()
    }

    private static let loggers = Dictionary(uniqueKeysWithValues: DiagCategory.allCases.map {
        ($0, Logger(subsystem: "Yapnest", category: $0.rawValue))
    })

    static func write(_ level: DiagLevel, _ category: DiagCategory, _ message: StaticString, _ fields: [DiagField], to store: DiagnosticsStore) {
        var text = String(message.description.map { $0 == "\n" || $0 == "\r" ? " " : $0 })
        for field in fields {
            text += " \(field.key)=\(field.rendered)"
        }
        store.append(date: Date(), category: category, level: level, text: text)
        guard let logger = loggers[category] else { return }
        // The message is static and the fields typed, so none of it is private.
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
}
