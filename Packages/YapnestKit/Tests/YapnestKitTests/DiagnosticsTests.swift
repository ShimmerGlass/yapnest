import CryptoKit
import Foundation
import Martin
import Testing
@testable import YapnestKit

struct DiagnosticsTests {
    private enum Phase: String, DiagEnum {
        case dns, tls
        var description: String { rawValue }
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)")
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func rotationKeepsTwoFilesPerProcess() throws {
        let dir = makeDirectory()
        let store = DiagnosticsStore(directory: dir, process: .app, maxFileBytes: 2_000, flushInterval: 60)
        for index in 0..<200 {
            DiagLog.write(.info, .send, "queued", [.int("n", index)], to: store)
            if index % 10 == 0 { store.flush() }
        }
        store.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["app.1.log", "app.log"])
        let current = try Data(contentsOf: store.currentFile).count
        let previous = try Data(contentsOf: store.previousFile).count
        #expect(current <= 2_000 && previous <= 2_000)
        // The newest line survived, the oldest was dropped.
        #expect(try lines(of: store.currentFile).last?.hasSuffix("n=199") == true)
        let all = try lines(of: store.previousFile) + lines(of: store.currentFile)
        #expect(!all.contains { $0.hasSuffix("n=0") })
    }

    @Test func lineFormat() throws {
        let dir = makeDirectory()
        let store = DiagnosticsStore(directory: dir, process: .nse, flushInterval: 60)
        DiagLog.write(.notice, .push, "fetched", [.bool("ok", true), .value("phase", Phase.tls), .duration("took", 1.5)], to: store)
        store.flush()
        let line = try #require(lines(of: store.currentFile).first)
        #expect(line.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ nse push notice fetched ok=true phase=tls took=1.500s$"#, options: .regularExpression) != nil)
    }

    @Test func sizesAreBucketedToAPowerOfTwo() {
        #expect(DiagField.size("bytes", 0).rendered == "lt2e0")
        #expect(DiagField.size("bytes", 1).rendered == "lt2e1")
        #expect(DiagField.size("bytes", 2_097_151).rendered == "lt2e21")
        #expect(DiagField.size("bytes", 2_097_152).rendered == "lt2e22")
        #expect(DiagField.size("bytes", 2_500_000).rendered == "lt2e22")
        #expect(DiagField.size("bytes", -5).rendered == "lt2e0")
        #expect(DiagField.size("bytes", Int.max).rendered == "lt2e63")
        // Two sizes in a bucket can't be told apart.
        #expect(DiagField.size("bytes", 1_234_567).rendered == DiagField.size("bytes", 1_048_576).rendered)
    }

    @Test func portsAreLoggedAsAKind() {
        #expect(PortKind(5222) == .standard)
        #expect(PortKind(5223) == .directTLS)
        #expect(PortKind(443) == .directTLS)
        #expect(PortKind(5269) == .custom)
        #expect(PortKind(35222) == .custom)
    }

    @Test func exportMergesProcessesInTimeOrderWithHeader() throws {
        let dir = makeDirectory()
        let app = DiagnosticsStore(directory: dir, process: .app, flushInterval: 60)
        let nse = DiagnosticsStore(directory: dir, process: .nse, flushInterval: 60)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        app.append(date: base, category: .app, level: .info, text: "first")
        nse.append(date: base + 1, category: .push, level: .info, text: "second")
        app.append(date: base + 2, category: .app, level: .info, text: "third")
        nse.append(date: base + 3, category: .push, level: .info, text: "fourth")
        nse.flush()

        let url = try DiagnosticsExport.make(at: base + 10, store: app)
        let text = try String(contentsOf: url, encoding: .utf8)
        for label in ["App:", "Platform:", "OS:", "Device:", "Exported:"] {
            #expect(text.contains(label))
        }
        let messages = text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ")
            return parts.count >= 5 && parts[0].hasPrefix("20") ? String(parts[4]) : nil
        }
        #expect(messages == ["first", "second", "third", "fourth"])
        #expect(url.pathExtension == "txt")
    }

    @Test func concurrentWritersLoseNoLines() throws {
        let dir = makeDirectory()
        let store = DiagnosticsStore(directory: dir, process: .app, flushInterval: 0.01)
        let threads = 8, perThread = 500
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for index in 0..<perThread {
                DiagLog.write(.debug, .sync, "tick", [.int("t", thread), .int("i", index)], to: store)
            }
        }
        store.flush()
        let all = try lines(of: store.currentFile)
        #expect(all.count == threads * perThread)
        let pattern = #"^\S+ app sync debug tick t=\d+ i=\d+$"#
        #expect(all.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil })
        #expect(Set(all.map { $0.split(separator: " ").suffix(2).joined(separator: " ") }).count == threads * perThread)
    }

    private func withKeyDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    @Test func racingProcessesEndWithOneKey() async throws {
        try await withKeyDirectory { (directory: URL) async throws -> Void in
            let suite = "key-\(UUID().uuidString)"
            let keys = await withTaskGroup(of: Data.self) { group in
                for _ in 0..<16 {
                    group.addTask { Redacted.loadKey(in: directory, defaults: UserDefaults(suiteName: suite)!).withUnsafeBytes { Data($0) } }
                }
                return await group.reduce(into: Set<Data>()) { $0.insert($1) }
            }
            #expect(keys.count == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [Redacted.keyFileName])
        }
    }

    @Test func anExistingDefaultsKeyIsKept() async throws {
        try await withKeyDirectory { (directory: URL) async throws -> Void in
            let defaults = UserDefaults(suiteName: "key-\(UUID().uuidString)")!
            let old = Data(repeating: 7, count: 32)
            defaults.set(old, forKey: Redacted.defaultsKey)
            #expect(Redacted.loadKey(in: directory, defaults: defaults).withUnsafeBytes { Data($0) } == old)
            // Now the file decides, wherever the defaults went.
            #expect(Redacted.loadKey(in: directory, defaults: UserDefaults(suiteName: "key-\(UUID().uuidString)")!).withUnsafeBytes { Data($0) } == old)
        }
    }

    @Test func redactedIdsAreStableShortAndKeyed() {
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        let other = SymmetricKey(data: Data(repeating: 2, count: 32))
        let a = Redacted.id("alice@example.org", key: key)
        #expect(a == Redacted.id("alice@example.org", key: key))
        #expect(a.hex.count == 8)
        #expect(a.hex.allSatisfy { $0.isHexDigit })
        #expect(a != Redacted.id("bob@example.org", key: key))
        #expect(a != Redacted.id("alice@example.org", key: other))
        #expect(Redacted.id("x") == Redacted.id("x"))
    }

    @Test func errorFieldIsDomainAndCodeOnly() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "Could not reach https://files.example.org/alice@example.org/secret.png",
            NSURLErrorFailingURLStringErrorKey: "https://files.example.org/secret.png",
        ])
        #expect(DiagField.error(error).rendered == "NSURLErrorDomain/-1009")
        let xmpp = DiagField.error(XMPPError.not_acceptable("bob@example.org says no"))
        #expect(xmpp.rendered.hasSuffix("condition=not-acceptable"))
        #expect(!xmpp.rendered.contains("bob"))
    }

    @Test func exportHoldsNoIdentifiersOrBodies() throws {
        struct LeakyError: LocalizedError {
            var errorDescription: String? { "failed for alice@secret.example in room Secret Room" }
        }
        let dir = makeDirectory()
        let store = DiagnosticsStore(directory: dir, process: .share, flushInterval: 60)
        let jid = "alice@secret.example/phone"
        let body = "my password is hunter2"
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        DiagLog.write(.error, .send, "failed", [
            .id("to", Redacted.id(jid, key: key)),
            .id("msg", Redacted.id(body, key: key)),
            .error(LeakyError()),
            .error(NSError(domain: NSCocoaErrorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: body, "jid": jid])),
            .error(XMPPError.forbidden("alice@secret.example is banned")),
        ], to: store)
        let url = try DiagnosticsExport.make(store: store)
        let text = try String(contentsOf: url, encoding: .utf8)
        for secret in ["alice", "secret.example", "hunter2", "Secret Room", body, jid] {
            #expect(!text.contains(secret), "\(secret)")
        }
        #expect(text.contains(Redacted.id(jid, key: key).hex))
        #expect(text.contains("condition=forbidden"))
    }

    @Test func concurrentExportsDoNotDeleteEachOther() async throws {
        let store = DiagnosticsStore(directory: makeDirectory(), process: .share, flushInterval: 60)
        DiagLog.write(.info, .send, "queued", [], to: store)
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<30 { group.addTask { try DiagnosticsExport.make(store: store, root: root) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        for url in urls {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func exportClearsOlderExportsButNotNewOnes() throws {
        let store = DiagnosticsStore(directory: makeDirectory(), process: .share, flushInterval: 60)
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try DiagnosticsExport.make(store: store, root: root)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: old.deletingLastPathComponent().path)
        let recent = try DiagnosticsExport.make(store: store, root: root)
        let latest = try DiagnosticsExport.make(store: store, root: root)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: latest.path))
    }
}
