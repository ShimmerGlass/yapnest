import Testing
@testable import YapnestKit

struct LinkPreviewPolicyTests {
    private func decide(_ global: LinkPreviewSetting, _ chat: Bool?, _ direction: Message.Direction) -> LinkPreviewPolicy.Decision {
        LinkPreviewPolicy.decide(global: global, chat: chat, isOurs: direction == .outgoing)
    }

    @Test func ownLinksShowUnlessTheChatSaysNever() {
        #expect(decide(.askPerConversation, nil, .outgoing) == .show)
        #expect(decide(.askPerConversation, true, .outgoing) == .show)
        #expect(decide(.askPerConversation, false, .outgoing) == .off)
    }

    @Test func linksFromOthersNeedConsent() {
        #expect(decide(.askPerConversation, nil, .incoming) == .ask)
        #expect(decide(.askPerConversation, true, .incoming) == .show)
        #expect(decide(.askPerConversation, false, .incoming) == .off)
    }

    @Test func globalNeverTurnsEverythingOff() {
        for chat in [nil, true, false] as [Bool?] {
            #expect(decide(.never, chat, .outgoing) == .off)
            #expect(decide(.never, chat, .incoming) == .off)
        }
    }

    @Test func settingDefaultsToAskAndRoundTrips() throws {
        let db = try AppDatabase.inMemory()
        #expect(db.linkPreviewSetting == .askPerConversation)
        try db.setLinkPreviewSetting(.never)
        #expect(db.linkPreviewSetting == .never)
    }

    @Test func gifSettingDefaultsToOn() throws {
        let db = try AppDatabase.inMemory()
        #expect(db.flag(.gifs, default: true))
        try db.setFlag(.gifs, false)
        #expect(!db.flag(.gifs, default: true))
    }
}
