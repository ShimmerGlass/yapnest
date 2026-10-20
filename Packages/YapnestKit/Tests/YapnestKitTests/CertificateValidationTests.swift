import Foundation
import Security
import Testing
@testable import YapnestKit

/// The live tests trust the dev servers' local CA to run over TLS. That has
/// to stay a test-only widening: with no anchors given, a certificate from
/// an unknown CA is refused like any other.
struct CertificateValidationTests {
    // A throwaway CA, and a certificate it signed for "localhost", made with
    // openssl for this test. Nothing else trusts them.
    private static let caDER = "MIIDBDCCAeygAwIBAgIUIcnwiLIhDM4dVA49VlQZeBFHVvMwDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPWWFwbmVzdCB0ZXN0IENBMB4XDTI2MTAxMTEwMTgxMFoXDTM2MTAwODEwMTgxMFowGjEYMBYGA1UEAwwPWWFwbmVzdCB0ZXN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoubk7tnKzXOmSO/IG6v34DxO/6GKeUsK0h5KKqHPXQDIedurWElmmPUPOyUcfoTJOIxXwY5cZeB37ulJeneH4Z9RPTIODQbdASS9cX9CU0//Y9EPp98LWpNK4X/Kg/54ADS+U+x7sbuNhgyIKnaWZaXyJKvFMBKdDlJjagm6XC8x+fcvHxdwkMheAcUg2mxx1HJU541+iRSgssWQ1C8BuUjYHPkgvmhU/VptwrE4nWODxBk+0x+iyJZ+ncX4r73JeRomVaQYZK1tmpdUAF44ZXb8hWbxkoUiavp7/0oiyWuBnwDrh4ubdZJYMj/T0xPy4MfLTvQQIreNQVPQpxbM7wIDAQABo0IwQDAdBgNVHQ4EFgQUKp8xTnQIJmvJtifM4P+Qt5A7PJowDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAgQwDQYJKoZIhvcNAQELBQADggEBAIi6zkN3YBv0t4K6coWAgNNXQwzVJhH7n+6GoHYbXJmU/KuJlJtHkhLgmgMdt/ofqNoCWf3b2qxvDVRs6I9lmwD3ZUhFuF7ZzuxJJqHMB9mLfwxoqaNaUBmFwiJ8sJkHhbVCNp0ow3NL+Uf80jxeDS8y5kUHR5Ew48wc9PZhbanUkqa5z/vbm/QQTM+h0R6B8+Jn3rBA54otOXCC9v42BcXcJzm63c2RJXKd6+I2P/L+ogKsg/MS/gGOb4DRhrWLvsGCypAJLlYeHJoWqvhxEOiOXnMdDYUFcqB9g4fp8YxPPIoReT8/UaJ9pXAXdHyst9bokOGZ6UsozagwcS2Q+q0="
    private static let leafDER = "MIIDBzCCAe+gAwIBAgIUfU4wwyilbDykNu087Z130MD9P5wwDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPWWFwbmVzdCB0ZXN0IENBMB4XDTI2MTAxMTEwMTgxMFoXDTI4MTIxOTEwMTgxMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoKv3yyTyq3y2qD4ZOlVaijUQur3WMwS117gnobJbqNQtzzqngs3QMU0vllU5I7QyojH5EHh310xxaeJqha/sGCEJwl5/cuuAVUELRNRrNFoHwd0x6A4BGqyPPWkAMG5RqIG9GyRvAZXkxm5+fDTE8DZsyu7x5iuCdHCF7kUDtwqTWTPDD+npa2yYYLRCHwA13IqBm3/SJhDzIRSWMy+qRDWxnRFl/6xbjwD+j0hFotZWoOVog3VnDcCz++v7W5fGfeGUJ8FmswL3Yn5yox8yogfvJeSgSdoc74CejAMmAV977vB7icDjn693xKtxGnwjT+Q5XIkdbXoOtuIpE2XS3wIDAQABo0swSTAUBgNVHREEDTALgglsb2NhbGhvc3QwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDQYJKoZIhvcNAQELBQADggEBADcOi7pSy3hISmZ5eZlheN0UcZtBsP7k8dfk++qo4cuLAABSaIz1QK1i1iEOBJPtRXKtR5T2blTbMb/6yEYRgymVbqRP1KHBZo1eN6lgCLltuap04gZ4Q83FSkf04fFmHdL68zPMnvjFpgJLyVFA7C+SuszSpoKTVFtNroL6vea/ySoitSgrWh9BWgQQI2QMEv2DQY1ETJ4ZxA9KxiMwqHgWbAX05wS/V6iYJW+kkDCgDM84rCoem7fK2Cae8ZlrRP9spBDJgyjOdizh5v/pVKGiZ0/o182odirKPwQDQDKSnLj14upYAfTodrIumgzJa+pC+BYZAjev6Am2kR91IfQ="

    /// The certificate is valid until December 2028; evaluating on a fixed
    /// date inside that keeps the test from expiring.
    private static let verifyDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static func certificate(_ base64: String) throws -> SecCertificate {
        let der = try #require(Data(base64Encoded: base64))
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    private static func trust(at date: Date = verifyDate) throws -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(try certificate(leafDER), SecPolicyCreateBasicX509(), &trust)
        let result = try #require(trust)
        SecTrustSetVerifyDate(result, date as CFDate)
        return result
    }

    @Test func anUnknownCAIsRefusedByDefault() throws {
        #expect(!XMPPSession.validate(try Self.trust(), domain: "localhost"))
    }

    @Test func aGivenAnchorIsTrusted() throws {
        let anchors = [try Self.certificate(Self.caDER)]
        #expect(XMPPSession.validate(try Self.trust(), domain: "localhost", anchors: anchors))
    }

    @Test func theNameIsStillChecked() throws {
        let anchors = [try Self.certificate(Self.caDER)]
        #expect(!XMPPSession.validate(try Self.trust(), domain: "example.org", anchors: anchors))
    }

    @Test func expiryIsStillChecked() throws {
        let anchors = [try Self.certificate(Self.caDER)]
        let later = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(!XMPPSession.validate(try Self.trust(at: later), domain: "localhost", anchors: anchors))
    }
}
