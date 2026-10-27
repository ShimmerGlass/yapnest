import Foundation
import Network

/// What about a network path matters to a connection: whether it is usable
/// and which interfaces it runs over. Two updates with the same signature
/// leave a live connection or an attempt in flight on the network it started
/// on. Gateways are left out: their order and presence vary between updates
/// on the same network, so they would report changes that aren't one.
struct PathSignature: Equatable, Sendable {
    enum Status: String, DiagEnum {
        case satisfied, unsatisfied, requiresConnection
    }

    var status: Status
    /// Each available interface as `name/type`, sorted. Kept in memory only,
    /// never logged, as a name can identify a network.
    var interfaces: [String]

    init(status: Status, interfaces: [String]) {
        self.status = status
        self.interfaces = interfaces.sorted()
    }

    init(_ path: NWPath) {
        let status: Status = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        default: .unsatisfied
        }
        self.init(status: status, interfaces: path.availableInterfaces.map { "\($0.name)/\($0.type)" })
    }

    var isSatisfied: Bool { status == .satisfied }
}

/// Decides what a stream of path updates is worth. Updates that change
/// nothing usable still arrive in bursts (when the app comes to the front,
/// or in pairs on the Mac), and acting on each one dropped sign-ins that had
/// just begun and pinged the server over and over.
final class PathUpdateGate: @unchecked Sendable {
    struct Difference: Equatable {
        var status: Bool
        var interfaces: Bool
        var any: Bool { status || interfaces }
    }

    private struct State {
        var last: PathSignature?
        /// Set once a real change is waiting for the debounce, so a quieter update can't downgrade it.
        var pendingChange = false
        var lastActed: Date?
    }

    private let lock = NSLock()
    private var state = State()
    private let debouncer = Debouncer()
    private let changeDelay: TimeInterval
    private let quietDelay: TimeInterval
    private let quietInterval: TimeInterval
    private let act: @Sendable (_ changed: Bool) -> Void

    /// - Parameters:
    ///   - changeDelay: how long to wait for more updates after a real change.
    ///   - quietDelay: the same after updates that changed nothing; long enough to join a pair 0.6 s apart.
    ///   - quietInterval: the least time between two actions that changed nothing, so a burst longer than `quietDelay` still gives one.
    ///   - act: runs once per burst; `changed` is false when nothing usable differed, and then must not restart an attempt.
    init(changeDelay: TimeInterval = 0.5, quietDelay: TimeInterval = 2, quietInterval: TimeInterval = 10, act: @escaping @Sendable (_ changed: Bool) -> Void) {
        self.changeDelay = changeDelay
        self.quietDelay = quietDelay
        self.quietInterval = quietInterval
        self.act = act
    }

    /// Takes an update. Returns what differed from the one before, or nil for the first, which only reports the start.
    @discardableResult
    func receive(_ signature: PathSignature) -> Difference? {
        let (difference, wasPending): (Difference?, Bool) = lock.withLock {
            defer { state.last = signature }
            guard let last = state.last else { return (nil, false) }
            return (Difference(status: last.status != signature.status, interfaces: last.interfaces != signature.interfaces), state.pendingChange)
        }
        guard let difference else { return nil }
        if difference.any {
            DiagLog.info(.network, "Network path differs", fields: Self.fields(difference))
        } else {
            DiagLog.debug(.network, "Network path repeated", fields: Self.fields(difference))
        }
        guard signature.isSatisfied else {
            // Whatever was waiting was for a network that has since gone.
            if difference.any { lock.withLock { state.pendingChange = false } }
            return difference
        }
        let changed = difference.any || wasPending
        lock.withLock { state.pendingChange = changed }
        debouncer.schedule(after: changed ? changeDelay : quietDelay) { [weak self] in self?.fire() }
        return difference
    }

    static func fields(_ difference: Difference) -> [DiagField] {
        [.bool("statusChanged", difference.status), .bool("interfacesChanged", difference.interfaces)]
    }

    private func fire() {
        let changed: Bool? = lock.withLock {
            let changed = state.pendingChange
            state.pendingChange = false
            if !changed, let last = state.lastActed, Date().timeIntervalSince(last) < quietInterval { return nil }
            state.lastActed = Date()
            return changed
        }
        guard let changed else {
            DiagLog.debug(.network, "Network path check skipped")
            return
        }
        act(changed)
    }
}
