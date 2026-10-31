import Foundation

/// Where a received file may be fetched from without being asked to. A link
/// in a message makes the device send a request, so the same hosts and
/// addresses are refused as for link previews, and every redirect hop is
/// checked again. Development servers (`allowsInsecure`) live on localhost,
/// so nothing is checked for them.
///
/// The name is resolved here and again by URLSession, so a server that
/// changes its answer between the two (DNS rebinding) can still point the
/// connection at a local address. Previews close that by connecting to the
/// checked address, which URLSession can't do. Downloads accept it: they are
/// HTTPS only, and a local device can't show a certificate for the link's
/// name, so the handshake fails before any request is sent. All that reaches
/// it is a connection and a TLS hello, and the sender learns nothing of how
/// it went. Closing it would mean downloading through `SafeFetcher`, giving up
/// URLSession's HTTP/2, proxies and streaming to disk.
struct DownloadPolicy: Sendable {
    var allowsInsecure: Bool
    var transport: any FetchTransport

    init(allowsInsecure: Bool, transport: any FetchTransport = SystemTransport()) {
        self.allowsInsecure = allowsInsecure
        self.transport = transport
    }

    /// Throws if `url` must not be requested.
    func check(_ url: URL) async throws {
        if allowsInsecure { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FetchError.refused("host") }
        let kind = try AddressVetting.hostKind(of: components) { _ in true }
        _ = try await AddressVetting.addresses(for: kind, transport: transport, timeout: 15)
    }
}
