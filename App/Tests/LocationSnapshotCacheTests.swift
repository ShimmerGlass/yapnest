import Testing
import UIKit
import YapnestKit
@testable import Yapnest

@MainActor
struct LocationSnapshotCacheTests {
    private let place = GeoLocation(latitude: 48.8584, longitude: 2.2945)

    private func cache(limit: Int = 200) -> SnapshotDiskCache {
        SnapshotDiskCache(directory: FileManager.default.temporaryDirectory.appending(path: "snapshots-\(UUID().uuidString)"), limit: limit)
    }

    private func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
    }

    @Test func theKeyChangesWithEverythingThatDecidesThePicture() {
        let base = LocationSnapshotCache.key(place, dark: false, scale: 2)
        #expect(base == LocationSnapshotCache.key(place, dark: false, scale: 2))
        #expect(base != LocationSnapshotCache.key(place, dark: true, scale: 2))
        #expect(base != LocationSnapshotCache.key(place, dark: false, scale: 3))
        #expect(base != LocationSnapshotCache.key(GeoLocation(latitude: 48.8585, longitude: 2.2945), dark: false, scale: 2))
        #expect(base != LocationSnapshotCache.key(GeoLocation(latitude: 48.8584, longitude: 2.2946), dark: false, scale: 2))
        #expect(LocationSnapshotCache.scale(inKey: base) == 2)
    }

    @Test func aStoredPictureIsFoundAgain() throws {
        let disk = cache()
        let key = LocationSnapshotCache.key(place, dark: false, scale: 2)
        #expect(disk.image(for: key) == nil)
        disk.store(picture(), for: key)
        let found = try #require(disk.image(for: key))
        #expect(found.scale == 2)
        #expect(disk.image(for: LocationSnapshotCache.key(place, dark: true, scale: 2)) == nil)
    }

    @Test func pastTheLimitTheOldestAreRemoved() throws {
        let disk = cache(limit: 3)
        let keys = (0..<5).map { LocationSnapshotCache.key(GeoLocation(latitude: Double($0), longitude: 0), dark: false, scale: 2) }
        for (index, key) in keys.enumerated() {
            disk.store(picture(), for: key)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: disk.url(for: key).path)
        }
        disk.trim()
        let left = try FileManager.default.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil)
        #expect(left.count == 3)
        #expect(disk.image(for: keys[0]) == nil)
        #expect(disk.image(for: keys[1]) == nil)
        #expect(disk.image(for: keys[4]) != nil)
    }
}
