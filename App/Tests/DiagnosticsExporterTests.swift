import Foundation
import Testing
@testable import Yapnest

@MainActor
struct DiagnosticsExporterTests {
    private struct Refused: LocalizedError {
        var errorDescription: String? { "no room" }
    }

    @Test func aFinishedExportIsPresentedAndForgottenOnceDismissed() async throws {
        let file = try makeTemporaryFile("diagnostics.log")
        var finish: (@MainActor () -> Void)?
        var shown: [URL] = []
        let exporter = DiagnosticsExporter(make: { file }, present: { url, finished in
            shown.append(url)
            finish = finished
        })
        await exporter.start()
        #expect(shown == [file])
        #expect(exporter.presented == file)
        #expect(exporter.error == nil)
        #expect(!exporter.isExporting)

        await exporter.start()
        #expect(shown == [file], "a second export opened over the first")

        finish?()
        #expect(exporter.presented == nil)
        await exporter.start()
        #expect(shown.count == 2)
    }

    @Test func aFailedExportReportsTheErrorAndPresentsNothing() async {
        var shown = 0
        let exporter = DiagnosticsExporter(make: { throw Refused() }, present: { _, _ in shown += 1 })
        await exporter.start()
        #expect(shown == 0)
        #expect(exporter.presented == nil)
        #expect(exporter.error == "no room")
        #expect(!exporter.isExporting)
    }
}
