//
// ChannelBinding.swift
//
// Not part of upstream Martin. See Vendor/README.md.
//

import Foundation
import Network
import CryptoKit

/// What ties a sign-in to this TLS connection: SCRAM's proof then covers it,
/// so a party that relays the connection with a certificate of its own (one
/// the device was tricked or forced into trusting) can't use the proof.
public struct ChannelBindings: Equatable, Sendable {
    public static let exporterType = "tls-exporter";
    public static let serverEndPointType = "tls-server-end-point";
    static let exporterLabel = "EXPORTER-Channel-Binding";

    /// RFC 9266's exporter. Only from TLS 1.3: on 1.2 it is only safe with
    /// the extended master secret, which the connection doesn't tell us about.
    public var exporter: Data?;
    /// RFC 5929's hash of the server's certificate.
    public var serverEndPoint: Data?;

    public init(exporter: Data? = nil, serverEndPoint: Data? = nil) {
        self.exporter = exporter;
        self.serverEndPoint = serverEndPoint;
    }

    public var isEmpty: Bool { exporter == nil && serverEndPoint == nil }

    /// The data for a type the server listed, best first.
    func choose(from serverTypes: [String]) -> (type: String, data: Data)? {
        if let exporter, serverTypes.contains(Self.exporterType) {
            return (Self.exporterType, exporter);
        }
        if let serverEndPoint, serverTypes.contains(Self.serverEndPointType) {
            return (Self.serverEndPointType, serverEndPoint);
        }
        return nil;
    }

    /// Read from an established connection's TLS state.
    static func read(from metadata: sec_protocol_metadata_t) -> ChannelBindings {
        var bindings = ChannelBindings();
        if sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv13 {
            let label = exporterLabel;
            let secret = label.withCString { sec_protocol_metadata_create_secret(metadata, label.utf8.count, $0, 32) };
            if let secret = secret as DispatchData? {
                bindings.exporter = Data(secret);
            }
        }
        var leaf: SecCertificate?;
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if leaf == nil {
                leaf = sec_certificate_copy_ref(certificate).takeRetainedValue();
            }
        }
        if let leaf {
            bindings.serverEndPoint = serverEndPoint(ofCertificate: SecCertificateCopyData(leaf) as Data);
        }
        return bindings;
    }

    /// RFC 5929: the certificate hashed with its signature's hash, SHA-256
    /// for MD5 and SHA-1. Nil when that hash can't be told (RSASSA-PSS keeps
    /// it in parameters, EdDSA has none), so that type isn't offered.
    static func serverEndPoint(ofCertificate der: Data) -> Data? {
        guard let oid = signatureAlgorithmOID(ofCertificate: der) else {
            return nil;
        }
        switch oid {
        case "1.2.840.113549.1.1.4", "1.2.840.113549.1.1.5", "1.2.840.10045.4.1", "1.2.840.113549.1.1.11", "1.2.840.10045.4.3.2":
            return Data(SHA256.hash(data: der));
        case "1.2.840.113549.1.1.12", "1.2.840.10045.4.3.3":
            return Data(SHA384.hash(data: der));
        case "1.2.840.113549.1.1.13", "1.2.840.10045.4.3.4":
            return Data(SHA512.hash(data: der));
        default:
            return nil;
        }
    }

    /// The OID of `Certificate.signatureAlgorithm`: the second element of the
    /// outer SEQUENCE, after `tbsCertificate`.
    static func signatureAlgorithmOID(ofCertificate der: Data) -> String? {
        let bytes = [UInt8](der);
        guard let certificate = DER.element(in: bytes, at: 0), certificate.tag == 0x30,
              let tbs = DER.element(in: bytes, at: certificate.contentStart), tbs.tag == 0x30,
              let algorithm = DER.element(in: bytes, at: tbs.end), algorithm.tag == 0x30,
              let oid = DER.element(in: bytes, at: algorithm.contentStart), oid.tag == 0x06 else {
            return nil;
        }
        return DER.oidString(Array(bytes[oid.contentStart..<oid.end]));
    }
}

/// Just enough DER to find a certificate's signature algorithm.
enum DER {
    struct Element {
        let tag: UInt8;
        let contentStart: Int;
        let end: Int;
    }

    static func element(in bytes: [UInt8], at offset: Int) -> Element? {
        guard offset + 2 <= bytes.count else {
            return nil;
        }
        let tag = bytes[offset];
        var index = offset + 1;
        let first = bytes[index];
        index += 1;
        var length = 0;
        if first & 0x80 == 0 {
            length = Int(first);
        } else {
            let count = Int(first & 0x7F);
            // Indefinite lengths aren't DER, and more than 4 bytes can't fit a certificate.
            guard count >= 1, count <= 4, index + count <= bytes.count else {
                return nil;
            }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index]);
                index += 1;
            }
        }
        guard index + length <= bytes.count else {
            return nil;
        }
        return Element(tag: tag, contentStart: index, end: index + length);
    }

    static func oidString(_ bytes: [UInt8]) -> String? {
        guard let first = bytes.first else {
            return nil;
        }
        var parts = [first < 80 ? Int(first) / 40 : 2, first < 80 ? Int(first) % 40 : Int(first) - 80];
        var value = 0;
        for byte in bytes.dropFirst() {
            guard value < Int.max >> 7 else {
                return nil;
            }
            value = value << 7 | Int(byte & 0x7F);
            if byte & 0x80 == 0 {
                parts.append(value);
                value = 0;
            }
        }
        guard value == 0 else {
            return nil;
        }
        return parts.map(String.init).joined(separator: ".");
    }
}

extension Context {

    /// This connection's channel bindings; empty without TLS.
    var channelBindings: ChannelBindings {
        guard let connector = (self as? XMPPClient)?.connector as? SocketConnectorNetwork, connector.activeFeatures.contains(.TLS) else {
            return ChannelBindings();
        }
        return connector.channelBindings;
    }

    /// The binding types the server lists (XEP-0440).
    var serverChannelBindingTypes: [String] {
        let features = module(.streamFeatures).streamFeatures.element;
        return features?.findChild(name: "sasl-channel-binding", xmlns: "urn:xmpp:sasl-cb:0")?
            .getChildren(name: "channel-binding").compactMap({ $0.getAttribute("type") }) ?? [];
    }

    /// Whether the server offers any -PLUS mechanism, by SASL or SASL2.
    var serverOffersChannelBinding: Bool {
        let features = module(.streamFeatures).streamFeatures.element;
        let sasl = features?.findChild(name: "mechanisms")?.getChildren(name: "mechanism") ?? [];
        let sasl2 = features?.findChild(name: "authentication", xmlns: Sasl2Module.XMLNS)?.getChildren(name: "mechanism") ?? [];
        return (sasl + sasl2).contains { $0.value?.hasSuffix("-PLUS") == true };
    }
}
