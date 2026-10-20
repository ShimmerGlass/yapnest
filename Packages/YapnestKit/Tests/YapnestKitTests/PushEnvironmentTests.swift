import Foundation
import Testing
@testable import YapnestKit

struct PushEnvironmentTests {
    /// Binary bytes around an XML plist, like a CMS-signed profile.
    private func profile(entitlements: String) -> Data {
        var data = Data([0x30, 0x82, 0x0A, 0xFF, 0x00, 0x06, 0x09])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Name</key><string>x</string>
        <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """.utf8))
        data.append(Data([0x00, 0xFE, 0x81, 0x30, 0x0D]))
        return data
    }

    @Test func developmentIsSandbox() {
        let data = profile(entitlements: "<key>aps-environment</key><string>development</string>")
        #expect(PushEnvironment.from(profile: data) == .sandbox)
    }

    @Test func productionIsProduction() {
        let data = profile(entitlements: "<key>aps-environment</key><string>production</string>")
        #expect(PushEnvironment.from(profile: data) == .production)
    }

    @Test func macKeyIsRead() {
        let data = profile(entitlements: "<key>com.apple.developer.aps-environment</key><string>development</string>")
        #expect(PushEnvironment.from(profile: data) == .sandbox)
    }

    @Test func noProfileIsProduction() {
        #expect(PushEnvironment.from(profile: nil) == .production)
    }

    @Test func missingKeyIsProduction() {
        #expect(PushEnvironment.from(profile: profile(entitlements: "")) == .production)
        #expect(PushEnvironment.from(profile: Data([1, 2, 3])) == .production)
    }
}
