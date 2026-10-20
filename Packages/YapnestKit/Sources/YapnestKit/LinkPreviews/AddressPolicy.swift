import Foundation

/// An IPv4 (4 bytes) or IPv6 (16 bytes) address in network byte order.
struct IPAddress: Hashable, Sendable {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Parses a numeric address. Only the strict dotted-quad and RFC 4291
    /// forms are accepted; the sloppy forms `getaddrinfo` also takes
    /// ("127.1", "0x7f.1", "2130706433") are not literals here.
    init?(literal: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            self.bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            self.bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    var isIPv4: Bool { bytes.count == 4 }
}

/// An address range: the first `length` bits of `address`.
struct AddressPrefix: Hashable, Sendable {
    let address: IPAddress
    let length: Int

    init(_ address: IPAddress, length: Int) {
        self.address = address
        self.length = length
    }

    /// "10.0.0.0/8" or "fe80::/10". Only used for the fixed tables below.
    init(_ text: String) {
        let parts = text.split(separator: "/")
        self.init(IPAddress(literal: String(parts[0]))!, length: Int(parts[1])!)
    }

    func contains(_ other: IPAddress) -> Bool {
        guard other.bytes.count == address.bytes.count else { return false }
        let whole = length / 8
        if whole > 0, Array(other.bytes[..<whole]) != Array(address.bytes[..<whole]) { return false }
        let rest = length % 8
        guard rest > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - rest))
        return other.bytes[whole] & mask == address.bytes[whole] & mask
    }
}

/// Which addresses link previews may connect to: public ones only.
enum AddressPolicy {
    static let blockedIPv4 = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
        "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4",
        // Reserved, and the broadcast address 255.255.255.255.
        "240.0.0.0/4",
    ].map(AddressPrefix.init)

    /// Ranges blocked outright. The ones that carry an IPv4 address
    /// (mapped, compatible, NAT64, 6to4) are not here; see `embeddedIPv4`.
    static let blockedIPv6 = [
        "::/128", "::1/128", "fe80::/10", "fc00::/7", "ff00::/8", "fec0::/10", "2001:db8::/32", "100::/64",
        // Teredo hides addresses behind obfuscation; not worth decoding.
        "2001::/32",
    ].map(AddressPrefix.init)

    /// Whether a preview must not connect to `address`. `localPrefixes` are the
    /// networks the device itself is on (see `LocalInterfaces`): a public
    /// address inside one is still a neighbour, such as another machine in
    /// the LAN's IPv6 /64, or a host behind a VPN.
    static func isBlocked(_ address: IPAddress, localPrefixes: [AddressPrefix]) -> Bool {
        if localPrefixes.contains(where: { $0.contains(address) }) { return true }
        if address.isIPv4 {
            return blockedIPv4.contains { $0.contains(address) }
        }
        let inner = embeddedIPv4(address)
        if !inner.isEmpty {
            return inner.contains { isBlocked($0, localPrefixes: localPrefixes) }
        }
        return blockedIPv6.contains { $0.contains(address) }
    }

    private static let mapped = AddressPrefix("::ffff:0:0/96")
    private static let compatible = AddressPrefix("::/96")
    private static let nat64 = AddressPrefix("64:ff9b::/96")
    private static let nat64Local = AddressPrefix("64:ff9b:1::/48")
    private static let sixToFour = AddressPrefix("2002::/16")

    /// The IPv4 addresses an IPv6 address stands for, if it's a form that
    /// wraps one. NAT64 prefixes stay allowed, because an IPv6-only mobile
    /// network synthesizes them for every IPv4-only site; what matters is
    /// the address inside.
    static func embeddedIPv4(_ address: IPAddress) -> [IPAddress] {
        let b = address.bytes
        guard b.count == 16 else { return [] }
        func v4(_ bytes: [UInt8]) -> IPAddress { IPAddress(bytes: bytes)! }
        if mapped.contains(address) || compatible.contains(address) || nat64.contains(address) {
            return [v4(Array(b[12...]))]
        }
        if nat64Local.contains(address) {
            // RFC 6052 puts the address after a /48 in bytes 6-7 and 9-10
            // (skipping the reserved byte 8); also try the plain tail, since
            // an operator may use either layout. Blocked if either is.
            return [v4([b[6], b[7], b[9], b[10]]), v4(Array(b[12...]))]
        }
        if sixToFour.contains(address) {
            return [v4(Array(b[2..<6]))]
        }
        return []
    }

    /// Whether the connection ended up where we meant it to. A NAT64 network
    /// may legitimately reach our IPv4 address through a synthesized IPv6 one.
    static func endpoint(_ actual: IPAddress, matches chosen: IPAddress) -> Bool {
        if actual == chosen { return true }
        return chosen.isIPv4 && embeddedIPv4(actual).contains(chosen)
    }
}

/// Name rules, applied before any lookup so that a name that would reach
/// the LAN (mDNS for `.local`, search domains for single labels) is never
/// resolved at all.
enum HostPolicy {
    static let blockedSuffixes = ["localhost", "local", "internal", "lan", "home.arpa", "intranet", "corp", "private"]

    /// Lowercased, without trailing dots.
    static func normalize(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    enum Kind: Equatable {
        case literal(IPAddress)
        case name(String)
    }

    /// The normalized host, or nil if it must not be fetched. IP literals are
    /// returned as such; whether their address is allowed is for `AddressPolicy`.
    static func classify(_ rawHost: String) -> Kind? {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        host = normalize(host)
        // No zone ids ("fe80::1%en0"): inet_pton takes them, and they name an interface.
        guard !host.isEmpty, !host.contains("%") else { return nil }
        if let literal = IPAddress(literal: host) { return .literal(literal) }
        // Anything with a colon that isn't a plain IPv6 literal, such as a zone id.
        guard !host.contains(":") else { return nil }

        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard host.allSatisfy({ allowed.contains($0) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        // "127.1", "2130706433" and "0x7f.1" are IPv4 addresses to getaddrinfo.
        let last = labels.last!
        guard !last.allSatisfy(\.isNumber), !last.hasPrefix("0x") else { return nil }
        for suffix in blockedSuffixes where host == suffix || host.hasSuffix("." + suffix) { return nil }
        return .name(host)
    }
}

/// The networks this device is attached to.
enum LocalInterfaces {
    struct Unavailable: Error {}

    /// Read fresh before every connection, as networks change under a running
    /// app. Every interface counts, VPN tunnels included: what's reachable
    /// through one is as private as the LAN.
    static func prefixes() throws -> [AddressPrefix] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { throw Unavailable() }
        defer { freeifaddrs(list) }

        var result: [AddressPrefix] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard Int32(entry.pointee.ifa_flags) & IFF_UP != 0, let sa = entry.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            guard let address = bytes(of: sa) else { continue }
            // Point-to-point links may have no mask: just the address itself.
            let length = entry.pointee.ifa_netmask.flatMap { bytes(of: UnsafePointer($0)) }.map(prefixLength) ?? address.count * 8
            if let ip = IPAddress(bytes: address) { result.append(AddressPrefix(ip, length: length)) }
        }
        return result
    }

    private static func bytes(of sa: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
        default:
            return nil
        }
    }

    private static func prefixLength(_ mask: [UInt8]) -> Int {
        var length = 0
        for byte in mask {
            if byte == 0xFF { length += 8; continue }
            length += byte.leadingZeroBitCount == 0 ? (~byte).leadingZeroBitCount : 0
            break
        }
        return length
    }
}
