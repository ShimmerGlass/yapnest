import Testing
@testable import Yapnest

struct AvatarImageCacheTests {
    // The share sheet's 40 pt pictures were decoded at 256 px into a cache of
    // 28 MB, in an extension that has about 120 MB.
    @Test func theShareSheetDecodesSmallAndKeepsLittle() {
        let app = AvatarImageCache.budget(isExtension: false)
        let share = AvatarImageCache.budget(isExtension: true)
        #expect(app == .init(smallPixels: 256, smallBytes: 28_000_000))
        #expect(share.smallPixels >= 120, "still sharp at 40 pt on a 3x screen")
        #expect(share.smallPixels < app.smallPixels)
        #expect(share.smallBytes <= 4_000_000)
    }
}
