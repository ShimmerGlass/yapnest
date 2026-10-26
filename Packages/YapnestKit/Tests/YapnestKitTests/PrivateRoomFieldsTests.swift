import Testing
@testable import YapnestKit

/// What a new private group's owner form is answered with, per server.
struct PrivateRoomFieldsTests {
    private let common: Set<String> = [
        "muc#roomconfig_roomname", "muc#roomconfig_persistentroom", "muc#roomconfig_membersonly",
    ]
    private let logging = "muc#roomconfig_enablelogging"

    @Test func ejabberdsRoomLogIsLeftOffWhenItHasAnArchive() {
        let fields = XMPPSession.privateRoomFields(name: "Club", offered: common.union(["mam", logging]))
        #expect(fields[logging] == nil)
        #expect(fields["mam"] == ["1"])
    }

    @Test func prosodyGetsItsArchive() {
        let fields = XMPPSession.privateRoomFields(name: "Club", offered: common.union(["muc#roomconfig_enablearchiving"]))
        #expect(fields[logging] == nil)
        #expect(fields["muc#roomconfig_enablearchiving"] == ["1"])
    }

    @Test func openfiresLoggingIsItsArchive() {
        let openfire = common.union([logging, "x-muc#roomconfig_canchangenick", "x-muc#roomconfig_registration", "x-muc#roomconfig_reservednick"])
        let fields = XMPPSession.privateRoomFields(name: "Club", offered: openfire)
        #expect(fields[logging] == ["1"])
    }

    @Test func ejabberdsRoomLogIsLeftOffWithoutAnArchive() {
        let fields = XMPPSession.privateRoomFields(name: "Club", offered: common.union([logging]))
        #expect(fields[logging] == nil)
    }
}
