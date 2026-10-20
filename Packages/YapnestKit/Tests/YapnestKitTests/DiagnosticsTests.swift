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
        #expect(line.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z nse push notice fetched ok=true phase=tls took=1.500s$"#, options: .regularExpression) != nil)
    }

    @Test func exportMergesProcessesInTimeOrderWithHeader() throws {
        let dir = makeDirectory()
        let app = DiagnosticsStore(directory: dir, process: .app, flushInterval: 60)
        let nse = DiagnosticsStore(directory: dir, process: .nse, flushInterval: 60)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        app.append(date: base, category: .app, level: .info, message: "first", fields: [])
        nse.append(date: base + 1, category: .push, level: .info, message: "second", fields: [])
        app.append(date: base + 2, category: .app, level: .info, message: "third", fields: [])
        nse.append(date: base + 3, category: .push, level: .info, message: "fourth", fields: [])
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
}
