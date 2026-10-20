import Foundation
@testable import Martin
import Testing

/// SCRAM channel binding (RFC 5802, 5929, 9266; XEP-0440): which GS2 header is
/// sent, and the certificate hash for tls-server-end-point. That the server
/// accepts what we compute is shown live (`TLSLiveIntegrationTests`).
struct ChannelBindingTests {
    /// Self-signed certificates made with OpenSSL, and their hashes from `openssl dgst`.
    private static let rsaSHA256 = Data(base64Encoded: "MIIB0zCCATygAwIBAgIUechFI0160u+WQELPAQBeQnJbs90wDQYJKoZIhvcNAQELBQAwDDEKMAgGA1UEAwwBYTAeFw0yNjEwMTkxMDIzMjlaFw0yNjEwMjAxMDIzMjlaMAwxCjAIBgNVBAMMAWEwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBALtqoEUNHAp5X/nMGHeTUdv2P8kjzyuGARLA5MbwA8s12K8pMfrjkpT8y9/kqIOGzg21sMH2SK33lGDT0A48s7Lh2p5nohvebcZZISpSm32OR8D1mAKOF8nL35PpdqpipPE9jn1Epkj0CUO2laRTCu622QOtpitT1KnkBU5jU6A9AgMBAAGjMjAwMB0GA1UdDgQWBBTTJWddBzlwHoN/Bvk2iUO0wvAfnzAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4GBACmxxk/fRBKCFAs2F7MaoxcyU4z6dV3VRvXFy3PaUFVogt5TuIJzdAvz7xlYFSv1tMRG5UQ8YQ//D2lAOb/ZoJxUGsMpbMRUt04HkLDXhJ6hwStCtENX4nrRO1PkEbOERK9NkcbOMDyyOzzQvanuUbw6OxPoLbNrXQNB3iPB3hcu")!
    private static let ecdsaSHA384 = Data(base64Encoded: "MIIBijCCAQ+gAwIBAgIUfbuYyGzYSDYc6NOxjQkibkBacuEwCgYIKoZIzj0EAwMwDDEKMAgGA1UEAwwBYTAeFw0yNjEwMTkxMDIzMjlaFw0yNjEwMjAxMDIzMjlaMAwxCjAIBgNVBAMMAWEwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAATD/ljOVkZHzhwscHwEaqDfDTdABANr4pHUe+tdOcsodmXGotspaWFuTNNNFd7XDEF8s7Wbqobgb8VQ7L0QUuPxzRPBoJXhr5FDReIN4NS6mUSvZMMVOQeXf1ASBMniNgCjMjAwMB0GA1UdDgQWBBQZcbwzWP0QTcRPGpcSTsO7OrzxTTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMDA2kAMGYCMQDHEU3DXH3TZgTsFbwf2ukY/Cjignu06EX21jin0HfB0U9se3T7dfGqYXlrUPTmZZACMQCzp2GlXAHZx09IYQf/YItVTcV3i8L1au7QhP8zlB2EqrmLgcf6XotQC+lFamvnowQ=")!
    private static let ed25519 = Data(base64Encoded: "MIIBCzCBvqADAgECAhQVT3bFLVJSSxJkbIzx4rqw+7kGCjAFBgMrZXAwDDEKMAgGA1UEAwwBYTAeFw0yNjEwMTkxMDIzMjlaFw0yNjEwMjAxMDIzMjlaMAwxCjAIBgNVBAMMAWEwKjAFBgMrZXADIQAkbqdcnvcBtFt09H7Yfk+XoKhrWYLJfXfXeOCeTg7ddKMyMDAwHQYDVR0OBBYEFHNneaxaHpzrQXqj8G5Bq7uPjB/OMA8GA1UdEwEB/wQFMAMBAf8wBQYDK2VwA0EAO13oP3YLrFY2K2IZChr+EjEB34Ld1Sb1gkkUzP0W4kt1UWNF1Gf0PMmcp88YnZDdqsHBYgZ65aytntzjzcsjCw==")!

    private let both = ChannelBindings(exporter: Data(repeating: 1, count: 32), serverEndPoint: Data(repeating: 2, count: 32))

    @Test func theCertificateIsHashedWithItsSignaturesHash() {
        #expect(ChannelBindings.signatureAlgorithmOID(ofCertificate: Self.rsaSHA256) == "1.2.840.113549.1.1.11")
        #expect(ChannelBindings.serverEndPoint(ofCertificate: Self.rsaSHA256)?.base64EncodedString() == "SnDJzHbWM+u6GFuQr5NY6v7eZ2oIvazWjcbJRI7Bs+I=")
        #expect(ChannelBindings.signatureAlgorithmOID(ofCertificate: Self.ecdsaSHA384) == "1.2.840.10045.4.3.3")
        #expect(ChannelBindings.serverEndPoint(ofCertificate: Self.ecdsaSHA384)?.base64EncodedString() == "lhhz7+6kBGitILvvq50+iUU1BkN9m6Png//QHbSQXjXxAv9tM4T3rZ7G+ZktaVkz")
    }

    /// RFC 5929 names no hash for EdDSA, so that type isn't offered rather than guessed.
    @Test func aCertificateWithNoSignatureHashGivesNoEndPoint() {
        #expect(ChannelBindings.signatureAlgorithmOID(ofCertificate: Self.ed25519) == "1.3.101.112")
        #expect(ChannelBindings.serverEndPoint(ofCertificate: Self.ed25519) == nil)
    }

    @Test func malformedCertificatesGiveNothing() {
        #expect(ChannelBindings.serverEndPoint(ofCertificate: Data()) == nil)
        #expect(ChannelBindings.serverEndPoint(ofCertificate: Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(ChannelBindings.serverEndPoint(ofCertificate: Self.rsaSHA256.prefix(40)) == nil)
    }

    @Test func plusBindsWithTheBestTypeTheServerTakes() throws {
        let exporter = try #require(ScramMechanism.gs2Header(plus: true, bindings: both, serverTypes: ["tls-server-end-point", "tls-exporter"], serverOffersPlus: true))
        #expect(exporter.header == "p=tls-exporter,,")
        #expect(exporter.data == Data(repeating: 1, count: 32))
        let endPoint = try #require(ScramMechanism.gs2Header(plus: true, bindings: both, serverTypes: ["tls-server-end-point"], serverOffersPlus: true))
        #expect(endPoint.header == "p=tls-server-end-point,,")
        #expect(endPoint.data == Data(repeating: 2, count: 32))
    }

    /// TLS 1.2 gives no exporter, and tls-unique isn't something we compute.
    @Test func plusIsUnavailableWithoutACommonType() {
        let noExporter = ChannelBindings(serverEndPoint: Data(repeating: 2, count: 32))
        #expect(ScramMechanism.gs2Header(plus: true, bindings: noExporter, serverTypes: ["tls-exporter"], serverOffersPlus: true) == nil)
        #expect(ScramMechanism.gs2Header(plus: true, bindings: both, serverTypes: ["tls-unique"], serverOffersPlus: true) == nil)
        #expect(ScramMechanism.gs2Header(plus: true, bindings: ChannelBindings(), serverTypes: ["tls-exporter"], serverOffersPlus: true) == nil)
    }

    /// "y" makes a server that can bind refuse a sign-in whose -PLUS offer was stripped on the way.
    @Test func withoutPlusOnOfferWeSayWeCouldHaveBound() {
        #expect(ScramMechanism.gs2Header(plus: false, bindings: both, serverTypes: [], serverOffersPlus: false)?.header == "y,,")
    }

    /// The server offered -PLUS but we had no type in common: "y" would be refused.
    @Test func plainScramAlongsideAnUnusablePlusSaysN() {
        #expect(ScramMechanism.gs2Header(plus: false, bindings: both, serverTypes: ["tls-unique"], serverOffersPlus: true)?.header == "n,,")
    }

    /// No TLS (the dev servers' plaintext suites): nothing to bind to.
    @Test func withoutTLSItsN() {
        #expect(ScramMechanism.gs2Header(plus: false, bindings: ChannelBindings(), serverTypes: [], serverOffersPlus: false)?.header == "n,,")
    }

    @Test func theUsernameIsEscapedAsASaslName() {
        #expect(ScramMechanism.saslName("a,b=c") == "a=2Cb=3Dc")
        #expect(ScramMechanism.saslName("alice") == "alice")
    }

    /// The nonce used to come from 20 letters only (A to T).
    @Test func theNonceUsesTheWholeAlphabet() {
        let scram = ScramMechanism.ScramSha1()
        let seen = Set((0..<200).flatMap { _ in scram.randomString() })
        #expect(seen.contains { $0.isNumber })
        #expect(seen.contains { $0.isLowercase })
        #expect(seen.contains("Z"))
        #expect(scram.randomString().count == 32)
    }
}
