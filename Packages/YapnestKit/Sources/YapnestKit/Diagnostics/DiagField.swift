import Foundation
import Martin

/// A small enum a log line may carry. An adopting type's `description` must
/// come from a fixed set of values, never from data that was received or
/// typed. A `String` can't adopt it, as it isn't `CaseIterable`.
public protocol DiagEnum: CustomStringConvertible, CaseIterable, Sendable {}

/// One `key=value` of a log line. The only ways to make one are below, and
/// none takes a free-form string, so a log line can't carry a body, an
/// address or a name by mistake.
public struct DiagField: Sendable {
    let key: StaticString
    let rendered: String

    private init(_ key: StaticString, _ rendered: String) {
        self.key = key
        self.rendered = rendered
    }

    public static func int(_ key: StaticString, _ value: Int) -> DiagField {
        DiagField(key, String(value))
    }

    public static func duration(_ key: StaticString, _ seconds: TimeInterval) -> DiagField {
        DiagField(key, String(format: "%.3fs", seconds))
    }

    public static func duration(_ key: StaticString, since start: Date) -> DiagField {
        duration(key, Date().timeIntervalSince(start))
    }

    public static func bool(_ key: StaticString, _ value: Bool) -> DiagField {
        DiagField(key, value ? "true" : "false")
    }

    public static func value(_ key: StaticString, _ value: some DiagEnum) -> DiagField {
        DiagField(key, sanitized(value.description))
    }

    public static func id(_ key: StaticString, _ value: Redacted) -> DiagField {
        DiagField(key, value.hex)
    }

    /// An error as its domain and code, and the condition if the server sent
    /// one. Never its description, which can carry a URL or a name.
    public static func error(_ error: some Error) -> DiagField {
        let ns = error as NSError
        var text = "\(sanitized(ns.domain))/\(ns.code)"
        if let condition = (error as? XMPPError)?.errorCondition ?? error as? ErrorCondition {
            text += " condition=\(sanitized(condition.rawValue))"
        }
        return DiagField("error", text)
    }

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-/")

    /// Keeps a value to one token of plain characters, so it can't break the
    /// line or pass for another field.
    static func sanitized(_ text: String) -> String {
        let cleaned = String(text.prefix(64).map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }
}

public enum DiagCategory: String, Sendable, CaseIterable {
    case connection, network, send, receive, upload, sync, push, omemo, calls
    case notificationExtension, shareExtension, app
}

public enum DiagLevel: String, Sendable, CaseIterable {
    case debug, info, notice, error
}

public enum DiagProcess: String, Sendable, CaseIterable {
    case app, nse, share

    /// The process this code runs in, from the bundle id's last part.
    public static var current: DiagProcess {
        let id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".notifications") { return .nse }
        if id.hasSuffix(".share") { return .share }
        return .app
    }
}
