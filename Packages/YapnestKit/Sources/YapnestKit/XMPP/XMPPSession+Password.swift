import Foundation
import os
@preconcurrency import Martin

/// Changing the account's password (XEP-0077 §3.3). Nothing here logs or
/// keeps a password beyond handing it to the connection's configuration.
extension XMPPSession {
    public enum PasswordError: Error, LocalizedError, Equatable {
        case offline
        /// The server doesn't offer password changes, or refused this one.
        case notAllowed
        /// The server didn't accept the current password.
        case notAuthorized
        /// The server's policy refused the new password; `reason` is its own text.
        case notAcceptable(reason: String?)
        /// The server asks for something Yapnest can't fill in.
        case formRequired
        case timedOut
        /// The request was sent and the connection or the answer was lost, so
        /// the server may have changed the password. Both are accepted for now.
        case outcomeUnknown
        case refused(reason: String)
        /// The current password typed isn't the one this device signed in with.
        case wrongCurrentPassword
        /// The server took the new password, but this device couldn't store
        /// it. Signing out and in again with it fixes that.
        case changedButNotSaved

        public var errorDescription: String? {
            switch self {
            case .offline: String(localized: "You're offline.")
            case .notAllowed: String(localized: "Your server doesn't let you change your password here.")
            case .notAuthorized: String(localized: "Your server didn't accept the current password.")
            case .notAcceptable(let reason):
                if let reason { String(localized: "Your server won't accept that new password: \(reason)") } else {
                    String(localized: "Your server won't accept that new password. Try a longer one.")
                }
            case .formRequired: String(localized: "Your server asks for details that Yapnest can't give, so the password can't be changed here.")
            case .timedOut: String(localized: "The server didn't answer.")
            case .outcomeUnknown:
                String(localized: "The server didn't say whether it changed your password. Yapnest will use the new one if the old one stops working. Check by signing in elsewhere.")
            case .refused(let reason): String(localized: "The server refused it: \(reason)")
            case .wrongCurrentPassword: String(localized: "That isn't your current password.")
            case .changedButNotSaved:
                String(localized: "The server changed your password, but this device couldn't save it. Sign out and sign in again with the new one.")
            }
        }
    }

    /// Why a typed password change can't be sent, checked before asking the server.
    public enum PasswordProblem: Equatable, Sendable {
        case emptyCurrent
        case emptyNew
        case mismatch
        case unchanged

        public var message: String {
            switch self {
            case .emptyCurrent: String(localized: "Enter your current password.")
            case .emptyNew: String(localized: "Enter a new password.")
            case .mismatch: String(localized: "The new passwords don't match.")
            case .unchanged: String(localized: "The new password is the same as the current one.")
            }
        }
    }

    /// The first thing wrong with what was typed, nil if it can be sent. Some
    /// servers (Prosody) take an empty password and lock the account with it,
    /// so that is refused here rather than left to them.
    public static func passwordProblem(current: String, new: String, confirmation: String) -> PasswordProblem? {
        if current.isEmpty { return .emptyCurrent }
        if new.isEmpty { return .emptyNew }
        if new != confirmation { return .mismatch }
        if new == current { return .unchanged }
        return nil
    }

    /// Whether the server says it takes password changes: it lists the
    /// registration namespace in the features of its domain.
    public var canChangePassword: Bool {
        client.module(.disco).serverDiscoResult.features.contains(NS.register)
    }

    /// Changes the password on the server, and makes this session and its
    /// reconnections use the new one. `current` is only sent when the
    /// server's form asks for it. The caller stores the password and drops the
    /// other clients' FAST tokens (see `AppModel.changePassword`).
    public func changePassword(to new: String, current: String) async throws {
        guard isConnected else { throw PasswordError.offline }
        guard let username = account.localPart else { throw PasswordError.notAllowed }
        let domain = account.domain
        let request = try await changeRequest(username: username, domain: domain, new: new, current: current)
        do {
            // Setting the same password again does no harm, so a request that
            // timed out, or whose connection dropped, is sent once more.
            _ = try await retryingPassingErrors { try await client.context.writer.write(iq: request) }
        } catch {
            if (error as? XMPPError)?.errorCondition == .remote_server_timeout {
                // It may have been applied: the sign-in after this one has to
                // be able to find out, with a password, as a token the server
                // kept would sign in either way and confirm the old one.
                lock.withLock { $0.candidatePassword = new }
                fastTokens.save(nil)
                client.module(.sasl2).fastToken = nil
                throw PasswordError.outcomeUnknown
            }
            throw Self.passwordError(from: error)
        }
        lock.withLock { $0.candidatePassword = nil }
        client.connectionConfiguration.credentials = .password(password: new)
        // The server drops tokens on a password change, or keeps them: either
        // way the next sign-in is better off with the password, which also
        // gets a token again.
        fastTokens.save(nil)
        client.module(.sasl2).fastToken = nil
    }

    /// A refused sign-in after a password change of unknown outcome: the new
    /// password is tried once, in place of the old. False when there is
    /// nothing to try, or the failure isn't a refused password.
    func switchToCandidatePassword(after failure: Error) -> Bool {
        switch failure as? SaslError {
        case .not_authorized?, .invalid_authzid?: break
        default: return false
        }
        let candidate = lock.withLock { state -> String? in
            guard !state.triedCandidate, let candidate = state.candidatePassword else { return nil }
            state.triedCandidate = true
            state.usesCandidate = true
            return candidate
        }
        guard let candidate else { return false }
        client.connectionConfiguration.credentials = .password(password: candidate)
        // A token was issued for the old password.
        fastTokens.save(nil)
        client.module(.sasl2).fastToken = nil
        return true
    }

    /// Called when a new session has signed in: tells the owner of the stored
    /// credentials which password worked, if a candidate was in play, so it
    /// can keep that one and forget the other.
    func confirmPassword() {
        let confirmed = lock.withLock { state -> (password: String, wasCandidate: Bool, handler: (@Sendable (String, Bool) -> Void))? in
            guard let candidate = state.candidatePassword, let handler = state.passwordConfirmed else { return nil }
            let wasCandidate = state.usesCandidate
            state.candidatePassword = nil
            state.usesCandidate = false
            guard case .password(let current, _, _) = client.connectionConfiguration.credentials else { return nil }
            return (wasCandidate ? candidate : current, wasCandidate, handler)
        }
        guard let confirmed else { return }
        if confirmed.wasCandidate {
            // The other clients' tokens were issued for the old password.
            fastTokens.save(nil)
        }
        confirmed.handler(confirmed.password, confirmed.wasCandidate)
    }

    /// Hands `handler` which password a new session signed in with, when the
    /// credentials held a candidate (`Credentials.candidatePassword`), and
    /// whether it was the candidate. The owner stores that one alone.
    public func onPasswordConfirmed(_ handler: @escaping @Sendable (_ password: String, _ wasCandidate: Bool) -> Void) {
        lock.withLock { $0.passwordConfirmed = handler }
    }

    /// `onPasswordConfirmed` for the extensions, which have no owner to tell:
    /// the password that worked is kept in `store` and the other forgotten,
    /// so they stop trying both on every run.
    public func savesConfirmedPassword(to store: CredentialStore) {
        savesConfirmedPassword(load: store.load, update: store.update, forgetTokens: KeychainFastTokenStore.deleteAll)
    }

    func savesConfirmedPassword(
        load: @escaping @Sendable () throws -> Credentials?, update: @escaping @Sendable (Credentials) throws -> Void,
        forgetTokens: @escaping @Sendable () -> Void,
    ) {
        let account = account
        onPasswordConfirmed { password, wasCandidate in
            do {
                if let stored = try load(), stored.jid == account { try update(stored.confirming(password)) }
            } catch {
                DiagLog.error(.connection, "Storing the confirmed password failed", .error(error))
            }
            // The old password's tokens, in the app too.
            if wasCandidate { forgetTokens() }
        }
    }

    /// Whether the server accepts `password` for this account, by signing in
    /// once more on a connection of its own. Nothing of the session is touched
    /// or stored: that connection has no SASL2 module, so it neither presents
    /// nor asks for a FAST token and resumes no stream, it binds a resource
    /// of its own, and it is closed as soon as the server has answered.
    /// It starts from a copy of this session's connection settings (host,
    /// TLS, trust), so it reaches the server the way the session does. False
    /// means the server refused the password; anything else that stops it throws.
    public func accepts(password: String) async throws -> Bool {
        var configuration = client.connectionConfiguration
        configuration.credentials = .password(password: password)
        configuration.resource = "check-\(UUID().uuidString.prefix(8))"
        let probe = XMPPClient()
        probe.connectionConfiguration = configuration
        let modules = probe.modulesManager
        modules.register(AuthModule())
        let insecure = OSAllocatedUnfairLock(initialState: false)
        if configuration.disableTLS {
            modules.register(StreamFeaturesModule())
        } else {
            modules.register(RequireTLSStreamFeaturesModule(
                isTLSActive: { [weak probe] in probe?.connector?.activeFeatures.contains(.TLS) ?? false },
                onInsecure: { [weak probe] in
                    insecure.withLock { $0 = true }
                    _ = probe?.disconnect(true)
                },
            ))
        }
        modules.register(SaslModule())
        modules.register(ResourceBinderModule())
        modules.register(SessionEstablishmentModule())

        enum Outcome: Sendable { case signedIn, failed(Error), timedOut }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { try await probe.loginAndWait(); return .signedIn } catch { return .failed(error) }
            }
            group.addTask {
                try? await Task.sleep(for: Self.passwordCheckTimeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            // Closing it also resolves the login above when it timed out.
            _ = probe.disconnect(true)
            group.cancelAll()
            return first
        }
        switch outcome {
        case .signedIn: return true
        case .timedOut: throw PasswordError.timedOut
        case .failed(let error):
            if insecure.withLock({ $0 }) { throw PasswordError.refused(reason: String(localized: "The server doesn't support encryption.")) }
            switch error as? XMPPClient.State.DisconnectionReason {
            case .authenticationFailure(let failure):
                switch failure as? SaslError {
                case .not_authorized?, .invalid_authzid?: return false
                default: throw PasswordError.refused(reason: failure.localizedDescription)
                }
            case .timeout?: throw PasswordError.timedOut
            case .noRouteToServer?: throw PasswordError.offline
            default: throw PasswordError.refused(reason: error.localizedDescription)
            }
        }
    }

    static let passwordCheckTimeout: Duration = .seconds(30)

    /// Asks what the server wants first, as it may want a form (with the old
    /// password); a server that won't say gets the plain request.
    private func changeRequest(username: String, domain: String, new: String, current: String) async throws -> Iq {
        let ask = PasswordStanza.fieldsRequest(domain: domain)
        let reply: Iq
        do {
            reply = try await client.context.writer.write(iq: ask)
        } catch let error as XMPPError where error.errorCondition == .remote_server_timeout {
            throw PasswordError.timedOut
        } catch {
            return PasswordStanza.plainChange(username: username, password: new, domain: domain)
        }
        guard let form = PasswordStanza.form(in: reply) else {
            return PasswordStanza.plainChange(username: username, password: new, domain: domain)
        }
        guard let answer = PasswordStanza.answer(form, username: username, new: new, current: current) else {
            throw PasswordError.formRequired
        }
        return PasswordStanza.formChange(answer, domain: domain)
    }

    static func passwordError(from error: Error) -> PasswordError {
        guard let error = error as? XMPPError else { return .refused(reason: String(localized: "Unknown error.")) }
        let text = error.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch error.errorCondition {
        case .not_allowed, .forbidden, .service_unavailable, .feature_not_implemented: return .notAllowed
        case .not_authorized: return .notAuthorized
        case .not_acceptable, .policy_violation: return .notAcceptable(reason: text?.isEmpty == false ? text : nil)
        case .remote_server_timeout: return .timedOut
        case let condition: return .refused(reason: text?.isEmpty == false ? text! : condition.rawValue)
        }
    }
}

/// The stanzas of XEP-0077 §3.3, and the form a server may answer with.
enum PasswordStanza {
    /// Asks the server what it wants for a change.
    static func fieldsRequest(domain: String) -> Iq {
        let iq = Iq()
        iq.type = .get
        iq.to = Martin.JID(domain)
        iq.addChild(Element(name: "query", xmlns: NS.register))
        return iq
    }

    static func plainChange(username: String, password: String, domain: String) -> Iq {
        change(domain: domain, children: [Element(name: "username", cdata: username), Element(name: "password", cdata: password)])
    }

    static func formChange(_ answer: Element, domain: String) -> Iq {
        change(domain: domain, children: [answer])
    }

    private static func change(domain: String, children: [Element]) -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(domain)
        let query = Element(name: "query", xmlns: NS.register)
        for child in children { query.addChild(child) }
        iq.addChild(query)
        return iq
    }

    /// The data form in a reply to `fieldsRequest`, if it came with one.
    static func form(in reply: Iq) -> Element? {
        reply.firstChild(name: "query", xmlns: NS.register)?.firstChild(name: "x", xmlns: NS.dataForms)
    }

    private static let newPasswordNames: Set<String> = ["password", "new_password", "new-password", "newpassword"]
    private static let oldPasswordNames: Set<String> = ["old_password", "old-password", "oldpassword", "current_password", "current-password"]

    /// The submission for `form`, or nil if it asks for a required field we
    /// have no answer for. Hidden fields (FORM_TYPE) are echoed back.
    static func answer(_ form: Element, username: String, new: String, current: String) -> Element? {
        let answer = Element(name: "x", xmlns: NS.dataForms)
        answer.setAttribute("type", value: "submit")
        for field in form.filterChildren(name: "field", xmlns: nil) {
            guard let name = field.getAttribute("var") else { continue }
            let type = field.getAttribute("type")
            let value: [String]
            if type == "hidden" {
                value = field.filterChildren(name: "value", xmlns: nil).compactMap(\.value)
            } else if name == "username" {
                value = [username]
            } else if newPasswordNames.contains(name.lowercased()) {
                value = [new]
            } else if oldPasswordNames.contains(name.lowercased()) {
                value = [current]
            } else if type == "fixed" || field.firstChild(name: "required") == nil {
                continue
            } else {
                return nil
            }
            let reply = Element(name: "field", attributes: ["var": name])
            for text in value { reply.addChild(Element(name: "value", cdata: text)) }
            answer.addChild(reply)
        }
        return answer
    }
}
