import Foundation
import Network

private enum PathStatus: String, DiagEnum {
    case satisfied, unsatisfied, requiresConnection
}

extension DiagLog {
    /// Logs a path change, with what the path allows and not where it leads.
    public static func network(_ message: StaticString, _ path: NWPath) {
        log(.info, .network, message, fields(of: path))
    }

    private static func fields(of path: NWPath) -> [DiagField] {
        let status: PathStatus = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        default: .unsatisfied
        }
        return [
            .value("status", status),
            .bool("wifi", path.usesInterfaceType(.wifi)), .bool("cellular", path.usesInterfaceType(.cellular)),
            .bool("wired", path.usesInterfaceType(.wiredEthernet)),
            .bool("loopback", path.usesInterfaceType(.loopback)), .bool("otherInterface", path.usesInterfaceType(.other)),
            .bool("ipv4", path.supportsIPv4), .bool("ipv6", path.supportsIPv6), .bool("dns", path.supportsDNS),
            .bool("expensive", path.isExpensive), .bool("constrained", path.isConstrained),
        ]
    }
}
