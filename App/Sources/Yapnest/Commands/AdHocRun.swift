import Foundation
import Observation
import YapnestKit

/// One run of an ad-hoc command, from the first step to its end: the stage the
/// command is at, the form being filled in for it, and what the screen has to
/// say about a step in flight or one that failed.
@MainActor
@Observable
final class AdHocRun {
    /// Takes one step: the action, the run's session ID and the form to send.
    /// The session's own is the default; tests give their own.
    typealias Step = @Sendable (AdHocAction, String?, XDataForm?) async throws -> AdHocResponse

    let command: AdHocCommand
    private(set) var response: AdHocResponse?
    /// The stage's form, as the user has edited it. A failed step leaves it be,
    /// so nothing typed is lost.
    var form: XDataForm?
    /// The action waiting for an answer, which the screen shows a spinner for.
    private(set) var inFlight: AdHocAction?
    var error: String?
    /// Whether the run can only go on by starting again.
    private(set) var needsRestart = false
    /// What's wrong with the fields, by their place in the form.
    private(set) var problems: [Int: String] = [:]

    @ObservationIgnored private let step: Step
    @ObservationIgnored private var isAbandoned = false

    init(command: AdHocCommand, step: @escaping Step) {
        self.command = command
        self.step = step
    }

    convenience init(command: AdHocCommand, session: XMPPSession) {
        self.init(command: command) { action, sessionID, form in
            try await session.execute(command, action: action, sessionID: sessionID, form: form)
        }
    }

    var isBusy: Bool { inFlight != nil }
    var isExecuting: Bool { response?.status == .executing }
    var isCanceled: Bool { response?.status == .canceled }

    func start() async {
        guard !isBusy else { return }
        response = nil
        form = nil
        problems = [:]
        error = nil
        needsRestart = false
        await take(.execute, sessionID: nil, form: nil)
    }

    /// Takes the step the user chose. Going on or completing checks the form
    /// first, so the user is told which field is at fault; going back and
    /// cancelling take whatever is there.
    func perform(_ action: AdHocAction) async {
        guard !isBusy, isExecuting, let sessionID = response?.sessionID else { return }
        if action == .next || action == .complete, let form {
            let found = form.validationProblems()
            problems = Dictionary(found.map { ($0.index, $0.message) }, uniquingKeysWith: { first, _ in first })
            if !found.isEmpty { return }
        }
        error = nil
        await take(action, sessionID: sessionID, form: form)
    }

    /// Ends the run at the user's request, and says so when it's done.
    func cancel() async {
        guard !isBusy else { return }
        if isExecuting, let sessionID = response?.sessionID {
            inFlight = .cancel
            // The user is leaving either way, so a refusal is of no use to them.
            _ = try? await step(.cancel, sessionID, nil)
            inFlight = nil
        }
        response = AdHocResponse(sessionID: response?.sessionID, status: .canceled)
        form = nil
    }

    /// For when the screen goes away in the middle of a run: tells the entity
    /// to drop it, without making anyone wait for the answer.
    @discardableResult
    func abandon() -> Task<Void, Never>? {
        isAbandoned = true
        guard isExecuting, let sessionID = response?.sessionID else { return nil }
        response?.status = .canceled
        return Task.detached { [step] in _ = try? await step(.cancel, sessionID, nil) }
    }

    private func take(_ action: AdHocAction, sessionID: String?, form: XDataForm?) async {
        inFlight = action
        defer { inFlight = nil }
        do {
            let next = try await step(action, sessionID, form)
            if isAbandoned {
                // The screen left while this was on its way, so the run it
                // opened would otherwise stay open on the entity.
                if next.status == .executing, let id = next.sessionID {
                    Task.detached { [step] in _ = try? await step(.cancel, id, nil) }
                }
                return
            }
            response = next
            self.form = next.form
            problems = [:]
        } catch {
            guard !isAbandoned else { return }
            self.error = error.localizedDescription
            switch error as? AdHocError {
            case .sessionExpired, .badSessionID: needsRestart = true
            default: break
            }
        }
    }
}
