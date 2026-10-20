import Foundation
import Network

/// What the network path allows, without saying where it leads.
public struct NetworkSnapshot: Sendable, Equatable {
    public enum Status: String, DiagEnum {
        case satisfied, unsatisfied, requiresConnection
        public var description: String { rawValue }
    }

    public var status: Status
    public var wifi, cellular, wired, loopback, otherInterface: Bool
    public var supportsIPv4, supportsIPv6, supportsDNS: Bool
    public var isExpensive, isConstrained: Bool

    public init(path: NWPath) {
        switch path.status {
        case .satisfied: status = .satisfied
        case .requiresConnection: status = .requiresConnection
        default: status = .unsatisfied
        }
        wifi = path.usesInterfaceType(.wifi)
        cellular = path.usesInterfaceType(.cellular)
        wired = path.usesInterfaceType(.wiredEthernet)
        loopback = path.usesInterfaceType(.loopback)
        otherInterface = path.usesInterfaceType(.other)
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
    }

    public var fields: [DiagField] {
        [
            .value("status", status),
            .bool("wifi", wifi), .bool("cellular", cellular), .bool("wired", wired),
            .bool("loopback", loopback), .bool("otherInterface", otherInterface),
            .bool("ipv4", supportsIPv4), .bool("ipv6", supportsIPv6), .bool("dns", supportsDNS),
            .bool("expensive", isExpensive), .bool("constrained", isConstrained),
        ]
    }
}

extension DiagLog {
    /// Logs a path change.
    public static func network(_ message: StaticString, _ path: NWPath) {
        write(.info, .network, message, NetworkSnapshot(path: path).fields, to: store)
    }
}
