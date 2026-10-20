import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// A command that answers as the test scripts it, and records what it was sent.
private final class ScriptedCommand: @unchecked Sendable {
    struct Sent: Equatable {
        var action: AdHocAction
        var sessionID: String?
        var hasForm: Bool
    }

    private let state = NSLock()
    private var answers: [Result<AdHocResponse, AdHocError>]
    private var log: [Sent] = []

    init(_ answers: [Result<AdHocResponse, AdHocError>]) { self.answers = answers }

    var sent: [Sent] { state.withLock { log } }

    func step(_ action: AdHocAction, _ sessionID: String?, _ form: XDataForm?) async throws -> AdHocResponse {
        let answer = state.withLock {
            log.append(Sent(action: action, sessionID: sessionID, hasForm: form != nil))
            return answers.isEmpty ? Result<AdHocResponse, AdHocError>.success(AdHocResponse(status: .canceled)) : answers.removeFirst()
        }
        return try answer.get()
    }
}

@MainActor
struct AdHocRunTests {
    private let command = AdHocCommand(jid: "example.com", node: "setup", name: "Setup")

    private func form(_ fields: [XDataForm.Field]) -> XDataForm { XDataForm(fields: fields) }

    private func stage(_ session: String = "s1", fields: [XDataForm.Field], allowed: [AdHocAction]) -> AdHocResponse {
        AdHocResponse(sessionID: session, status: .executing, form: form(fields), allowed: allowed, defaultAction: allowed.last)
    }

    private func run(_ script: ScriptedCommand) -> AdHocRun {
        AdHocRun(command: command, step: script.step)
    }

    @Test func aTwoStageRunSendsTheEditedFormWithItsSession() async {
        let name = XDataForm.Field(name: "name", required: true)
        let script = ScriptedCommand([
            .success(stage(fields: [name], allowed: [.next])),
            .success(stage(fields: [XDataForm.Field(name: "ok", type: .boolean)], allowed: [.prev, .complete])),
            .success(AdHocResponse(sessionID: "s1", status: .completed, notes: [AdHocNote(kind: .info, text: "Done")])),
        ])
        let run = run(script)
        await run.start()
        run.form?.fields[0].value = "Ada"
        await run.perform(.next)
        #expect(run.form?.fields.first?.name == "ok")
        await run.perform(.complete)
        #expect(run.response?.status == .completed)
        #expect(run.response?.notes.first?.text == "Done")
        #expect(script.sent == [
            .init(action: .execute, sessionID: nil, hasForm: false),
            .init(action: .next, sessionID: "s1", hasForm: true),
            .init(action: .complete, sessionID: "s1", hasForm: true),
        ])
    }

    @Test func goingBackIsSentEvenWithARequiredFieldEmpty() async {
        let script = ScriptedCommand([
            .success(stage(fields: [XDataForm.Field(name: "a", required: true)], allowed: [.prev, .next])),
            .success(stage(fields: [XDataForm.Field(name: "first")], allowed: [.next])),
        ])
        let run = run(script)
        await run.start()
        await run.perform(.prev)
        #expect(script.sent.last?.action == .prev)
        #expect(run.form?.fields.first?.name == "first")
        #expect(run.problems.isEmpty)
    }

    @Test func aProblemInTheFormBlocksNextAndIsShownOnItsField() async {
        let script = ScriptedCommand([
            .success(stage(fields: [XDataForm.Field(name: "note"), XDataForm.Field(name: "who", type: .jidSingle, required: true)], allowed: [.next])),
        ])
        let run = run(script)
        await run.start()
        await run.perform(.next)
        #expect(script.sent.count == 1)
        #expect(run.problems.keys.sorted() == [1])
        #expect(run.error == nil)
        run.form?.fields[1].value = "ada@example.com"
        await run.perform(.next)
        #expect(script.sent.count == 2)
        #expect(run.problems.isEmpty)
    }

    @Test func cancelAndAbandonSendCancelOnlyWhileExecutingWithASession() async {
        // Never started: nothing to cancel.
        let idle = ScriptedCommand([])
        let notStarted = run(idle)
        #expect(notStarted.abandon() == nil)
        await notStarted.cancel()
        #expect(idle.sent.isEmpty)

        // Executing: cancel is sent once, and leaving afterwards sends nothing.
        let script = ScriptedCommand([.success(stage(fields: [], allowed: [.next])), .success(AdHocResponse(status: .canceled))])
        let running = run(script)
        await running.start()
        await running.cancel()
        #expect(running.isCanceled)
        #expect(running.abandon() == nil)
        #expect(script.sent.map(\.action) == [.execute, .cancel])
        #expect(script.sent.last?.sessionID == "s1")

        // Leaving in the middle of a run cancels it, without a form.
        let left = ScriptedCommand([.success(stage(fields: [XDataForm.Field(name: "a")], allowed: [.next]))])
        let walkedAway = run(left)
        await walkedAway.start()
        await walkedAway.abandon()?.value
        #expect(left.sent.map(\.action) == [.execute, .cancel])
        #expect(left.sent.last?.hasForm == false)

        // A completed command has nothing left to cancel.
        let done = ScriptedCommand([.success(AdHocResponse(sessionID: "s2", status: .completed))])
        let finished = run(done)
        await finished.start()
        #expect(finished.abandon() == nil)
        #expect(done.sent.count == 1)
    }

    @Test func anErrorKeepsTheFormAsItWas() async {
        let script = ScriptedCommand([
            .success(stage(fields: [XDataForm.Field(name: "a")], allowed: [.next])),
            .failure(.badPayload(text: "no")),
        ])
        let run = run(script)
        await run.start()
        run.form?.fields[0].value = "typed"
        await run.perform(.next)
        #expect(run.form?.fields[0].value == "typed")
        #expect(run.response?.status == .executing)
        #expect(run.error != nil)
        #expect(run.needsRestart == false)
        #expect(run.inFlight == nil)
    }

    @Test func anExpiredSessionOffersStartingAgain() async {
        let script = ScriptedCommand([
            .success(stage(fields: [XDataForm.Field(name: "a")], allowed: [.next])),
            .failure(.sessionExpired(text: nil)),
            .success(stage("s2", fields: [XDataForm.Field(name: "a")], allowed: [.next])),
        ])
        let run = run(script)
        await run.start()
        await run.perform(.next)
        #expect(run.needsRestart)
        await run.start()
        #expect(run.needsRestart == false)
        #expect(run.error == nil)
        #expect(run.response?.sessionID == "s2")
        #expect(script.sent.last == .init(action: .execute, sessionID: nil, hasForm: false))
    }
}
