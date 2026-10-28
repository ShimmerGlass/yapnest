import Testing
import UIKit
import YapnestKit
@testable import Yapnest

@MainActor
struct LocationSnapshotCacheTests {
    private let place = GeoLocation(latitude: 48.8584, longitude: 2.2945)

    private func cache(limit: Int = 200, keep: Int = 150) -> SnapshotDiskCache {
        SnapshotDiskCache(directory: FileManager.default.temporaryDirectory.appending(path: "snapshots-\(UUID().uuidString)"), limit: limit, keep: keep)
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
    }

    @Test func aStoredPictureIsFoundAgain() throws {
        let disk = cache()
        let key = LocationSnapshotCache.key(place, dark: false, scale: 2)
        #expect(disk.image(for: key, scale: 2) == nil)
        disk.store(picture(), for: key, generation: 0)
        let found = try #require(disk.image(for: key, scale: 2))
        #expect(found.scale == 2)
        #expect(disk.image(for: LocationSnapshotCache.key(place, dark: true, scale: 2), scale: 2) == nil)
    }

    @Test func pastTheLimitTheOldestAreRemovedDownToTheMark() throws {
        let disk = cache(limit: 4, keep: 2)
        let keys = (0..<5).map { LocationSnapshotCache.key(GeoLocation(latitude: Double($0), longitude: 0), dark: false, scale: 2) }
        for (index, key) in keys.enumerated() {
            disk.store(picture(), for: key, generation: 0)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: disk.url(for: key).path)
        }
        let left = try FileManager.default.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: nil)
        #expect(left.count == 2)
        for key in keys[0..<3] { #expect(disk.image(for: key, scale: 2) == nil) }
        #expect(disk.image(for: keys[3], scale: 2) != nil)
        #expect(disk.image(for: keys[4], scale: 2) != nil)
    }

    /// A snapshot can finish drawing just as its account signs out.
    @Test func aPictureDrawnBeforeTheCacheWasEmptiedIsNotStored() {
        let disk = cache()
        let key = LocationSnapshotCache.key(place, dark: false, scale: 2)
        let asked = disk.generation.withLock { $0 }
        disk.removeAll()
        disk.store(picture(), for: key, generation: asked)
        #expect(disk.image(for: key, scale: 2) == nil)
        #expect(!FileManager.default.fileExists(atPath: disk.directory.path))
    }

    /// A picture read from disk, or drawn, as its account signs out must not go back into memory.
    @Test func aPictureLoadedAcrossASignOutIsNotKept() async throws {
        let disk = cache()
        let key = LocationSnapshotCache.key(place, dark: false, scale: 2)
        disk.store(picture(), for: key, generation: disk.generation.withLock { $0 })
        LocationSnapshotCache.removeAll()
        let load = Task { await LocationSnapshotCache.load(place, dark: false, scale: 2, key: key, disk: disk) }
        // The load runs to its wait for the disk read, which can't resume while this holds the main actor.
        await Task.yield()
        disk.removeAll()
        LocationSnapshotCache.removeAll()
        #expect(await load.value == nil)
        #expect(LocationSnapshotCache.cached(key) == nil)
    }
}
