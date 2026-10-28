import Foundation
import Martin

/// Finds the connectors a client made, through its context, for the tests that drive a connector by hand.
///
/// A client freed by an earlier test can leave its address to a later one, and an `ObjectIdentifier` is
/// that address. Entries therefore hold their context weakly, and one whose context is not the client
/// asked about belongs to a client that is gone: its connectors are not that client's.
final class ConnectorRegistry<Made: AnyObject>: @unchecked Sendable {
    private struct Entry {
        weak var context: AnyObject?
        var made: [Made] = []
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func add(_ connector: Made, of context: Context) {
        let key = ObjectIdentifier(context)
        lock.withLock {
            var entry = entries[key].flatMap { $0.context === context ? $0 : nil } ?? Entry(context: context)
            entry.made.append(connector)
            entries[key] = entry
        }
    }

    func connectors(of context: Context) -> [Made] {
        lock.withLock {
            guard let entry = entries[ObjectIdentifier(context)], entry.context === context else { return [] }
            return entry.made
        }
    }
}
