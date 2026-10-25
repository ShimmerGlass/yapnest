import Foundation
@preconcurrency import Martin

/// Ad-hoc commands (XEP-0050), the client side: find the commands an entity
/// offers (our server, a contact's device, a group) and run them, one stage at
/// a time. What a command asks is a data form (`XDataForm`).
///
/// Martin's own module isn't used: it sends no `action` and no `sessionid`,
/// so a command with more than one stage can't be continued with it.

/// A command an entity offers.
public struct AdHocCommand: Sendable, Hashable, Identifiable {
    /// The full address of the entity that offers it.
    public let jid: String
    public let node: String
    /// What to call it, as the entity names it.
    public let name: String

    public init(jid: String, node: String, name: String) {
        self.jid = jid
        self.node = node
        self.name = name
    }

    public var id: String { "\(jid) \(node)" }
}

/// What a client asks of a command (XEP-0050 §3.4).
public enum AdHocAction: String, Sendable, Hashable {
    /// Starts the command.
    case execute
    case next
    case prev
    case complete
    case cancel
}

/// One message from a command, to read beside its form.
public struct AdHocNote: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case info, warn, error
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A command's answer to a step.
public struct AdHocResponse: Sendable, Hashable {
    public enum Status: String, Sendable {
        /// It has more to ask, or is waiting for the user to complete it.
        case executing
        /// It's done; `form` may hold its result.
        case completed
        case canceled
    }

    /// Names the command's run, to send back with each next step. Nil if the
    /// entity left it out, as one may for a command that completed at once.
    public var sessionID: String?
    public var status: Status
    public var form: XDataForm?
    /// What the user may do next besides cancelling, which is always allowed
    /// while `status` is `executing`. XEP-0050 §3.4: an `<actions>` element
    /// lists `prev`, `next` and `complete`; an executing command without one
    /// can only be completed.
    public var allowed: [AdHocAction]
    /// What a button that isn't one of the actions does: the `execute`
    /// attribute of `<actions>` when it names an allowed action. Where it
    /// doesn't say, `next` if allowed, else `complete`, else nil.
    public var defaultAction: AdHocAction?
    public var notes: [AdHocNote]

    public init(
        sessionID: String? = nil, status: Status, form: XDataForm? = nil, allowed: [AdHocAction] = [],
        defaultAction: AdHocAction? = nil, notes: [AdHocNote] = [],
    ) {
        self.sessionID = sessionID
        self.status = status
        self.form = form
        self.allowed = allowed
        self.defaultAction = defaultAction
        self.notes = notes
    }
}

public enum AdHocError: Error, LocalizedError, Equatable, Sendable {
    case offline
    /// The entity didn't answer in time.
    case timedOut
    /// The user may not run it (`forbidden`, `not-allowed`, `not-authorized`).
    case forbidden(text: String?)
    /// The entity or the command isn't there (`item-not-found`, or a
    /// recipient that has gone offline).
    case notFound(text: String?)
    /// The entity can't do commands (`service-unavailable`, `feature-not-implemented`).
    case unsupported(text: String?)
    /// The step asked for isn't one this stage allows (`bad-action`).
    case badAction(text: String?)
    /// The step asked for isn't one the entity knows (`malformed-action`).
    case malformedAction(text: String?)
    /// The run is not one the entity knows (`bad-sessionid`).
    case badSessionID(text: String?)
    /// The run took too long and is gone (`session-expired`).
    case sessionExpired(text: String?)
    /// The form sent was refused (`bad-payload`).
    case badPayload(text: String?)
    /// Any other refusal, with the entity's text or else the error's name.
    case refused(reason: String)
    /// The answer wasn't from who was asked, was for another command, or
    /// wasn't a command at all, so it is not applied.
    case unexpectedReply

    public var errorDescription: String? {
        func with(_ message: String, _ text: String?) -> String {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return message }
            return "\(message) \(text)"
        }
        switch self {
        case .offline: return String(localized: "You're offline.")
        case .timedOut: return String(localized: "It didn't answer.")
        case .forbidden(let text): return with(String(localized: "You aren't allowed to do that."), text)
        case .notFound(let text): return with(String(localized: "That command or its owner is no longer there."), text)
        case .unsupported(let text): return with(String(localized: "That doesn't offer commands."), text)
        case .badAction(let text): return with(String(localized: "That step isn't allowed here."), text)
        case .malformedAction(let text): return with(String(localized: "That step isn't understood."), text)
        case .badSessionID(let text): return with(String(localized: "The command doesn't know this run. Start it again."), text)
        case .sessionExpired(let text): return with(String(localized: "The command took too long and ended. Start it again."), text)
        case .badPayload(let text): return with(String(localized: "The answers were refused."), text)
        case .refused(let reason): return String(localized: "It refused: \(reason)")
        case .unexpectedReply: return String(localized: "The answer didn't make sense, so it was ignored.")
        }
    }
}

extension XMPPSession {
    /// How long a command's step, or the list of commands, may go unanswered.
    /// Some commands do real work in a step, so this is generous.
    static let adHocTimeout: TimeInterval = 30

    /// How long to wait for an occupant to say whether it offers commands.
    /// Short, as every occupant of a room is asked and a client that never
    /// answers shouldn't hold the rest up.
    static let adHocProbeTimeout: TimeInterval = 8

    // MARK: Finding commands

    /// Whether our server offers commands: its domain, or our account on it,
    /// lists the feature.
    public var serverOffersCommands: Bool {
        let disco = client.module(.disco)
        return disco.serverDiscoResult.features.contains(NS.commands) || disco.accountDiscoResult.features.contains(NS.commands)
    }

    /// The online devices of `contact` that say in their capabilities that
    /// they take commands, as full addresses. Contacts' clients mostly offer
    /// none, so this says which are worth asking.
    public func commandEntities(of contact: JID) -> [String] {
        guard let caps = client.modulesManager.moduleOrNil(CapabilitiesModule.IDENTIFIER) else { return [] }
        let resources = lock.withLock { $0.resources[contact]?.keys.sorted() ?? [] }
        return resources.map { "\(contact)/\($0)" }
            .filter { caps.isFeatureSupported(NS.commands, by: Martin.JID($0)) }
    }

    /// The commands `jid` offers us. A server's or a group's is its bare
    /// address; a contact's is one of its devices' full addresses (see
    /// `commandEntities(of:)`).
    public func adHocCommands(at jid: String) async throws -> [AdHocCommand] {
        guard await waitForConnection() else { throw AdHocError.offline }
        let entity = Martin.JID(jid)
        let query = Element(name: "query", xmlns: DiscoveryModule.ITEMS_XMLNS)
        query.setAttribute("node", value: NS.commands)
        let iq = Iq()
        iq.type = .get
        iq.to = entity
        iq.addChild(query)
        let reply = try await send(iq, to: entity)
        return AdHocStanza.commands(in: reply, offeredBy: entity)
    }

    /// Whether `jid` says in its disco#info that it takes commands. A group
    /// member's address is `room/nick`, and its presence needn't carry
    /// capabilities, so it is asked. Any failure counts as no.
    public func offersCommands(at jid: String) async -> Bool {
        guard await waitForConnection() else { return false }
        let entity = Martin.JID(jid)
        let iq = Iq()
        iq.type = .get
        iq.to = entity
        iq.addChild(Element(name: "query", xmlns: DiscoveryModule.INFO_XMLNS))
        guard let reply = try? await send(iq, to: entity, timeout: Self.adHocProbeTimeout) else { return false }
        return AdHocStanza.offersCommands(in: reply)
    }

    // MARK: Running a command

    /// Takes one step of `command`: starts it, or goes on with the run
    /// `sessionID` names, sending `form` filled in for the step. The first
    /// step is `.execute` with no session; the entity's answer names the
    /// session for the rest. Throws `AdHocError`.
    @discardableResult
    public func execute(
        _ command: AdHocCommand, action: AdHocAction = .execute, sessionID: String? = nil, form: XDataForm? = nil,
    ) async throws -> AdHocResponse {
        guard await waitForConnection() else { throw AdHocError.offline }
        let entity = Martin.JID(command.jid)
        let iq = AdHocStanza.request(to: entity, node: command.node, action: action, sessionID: sessionID, form: form)
        let reply = try await send(iq, to: entity)
        return try AdHocStanza.response(in: reply, node: command.node, sessionID: sessionID)
    }

    /// Tells the entity to drop a run the user walked away from, so it frees
    /// what it holds for it. Best effort: nobody is waiting for the answer.
    public func cancelAdHoc(_ command: AdHocCommand, sessionID: String) async {
        _ = try? await execute(command, action: .cancel, sessionID: sessionID)
    }

    /// Writes a request and returns the answer, if it comes from `entity`.
    /// A reply from anyone else could be a hostile entity's trying to answer
    /// for another, so it is dropped. A missing `from` is our own server's,
    /// and counts only for a request to our own account.
    private func send(_ iq: Iq, to entity: Martin.JID, timeout: TimeInterval = adHocTimeout) async throws -> Iq {
        let reply: Iq
        do {
            reply = try await client.context.writer.write(iq: iq, timeout: timeout) { [logger] stanza in
                // Who refused, and how, is what tells an entity's refusal from
                // a server's that couldn't reach it.
                if let stanza { logger.notice("Ad-hoc error: \(stanza.element.stringValue, privacy: .private)") }
                return AdHocStanza.error(from: stanza)
            }
        } catch let error as AdHocError {
            throw error
        } catch {
            throw AdHocError.refused(reason: error.localizedDescription)
        }
        let ours = Martin.JID(account.martin)
        guard let from = reply.from ?? (entity == ours ? entity : nil), from == entity else { throw AdHocError.unexpectedReply }
        return reply
    }
}

/// The stanzas of XEP-0050, as Yapnest builds and reads them.
enum AdHocStanza {
    static func request(to entity: Martin.JID, node: String, action: AdHocAction, sessionID: String?, form: XDataForm?) -> Iq {
        let command = Element(name: "command", xmlns: NS.commands)
        command.setAttribute("node", value: node)
        command.setAttribute("action", value: action.rawValue)
        if let sessionID, !sessionID.isEmpty { command.setAttribute("sessionid", value: sessionID) }
        // Cancelling sends nothing: the form is the step's answers.
        if let form, action != .cancel { command.addChild(form.submission()) }
        let iq = Iq()
        iq.type = .set
        iq.to = entity
        iq.addChild(command)
        return iq
    }

    /// The commands a disco#items answer lists. Only ones the asked entity
    /// offers itself count, as a list naming another entity's commands would
    /// have the user run them under the wrong name.
    static func commands(in reply: Iq, offeredBy entity: Martin.JID) -> [AdHocCommand] {
        guard let query = reply.firstChild(name: "query", xmlns: DiscoveryModule.ITEMS_XMLNS) else { return [] }
        return query.filterChildren(name: "item", xmlns: nil).compactMap { item in
            guard let node = item.getAttribute("node"), !node.isEmpty, let jid = item.getAttribute("jid"), Martin.JID(jid) == entity else { return nil }
            let name = item.getAttribute("name")
            return AdHocCommand(jid: jid, node: node, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? node)
        }
    }

    /// Whether a disco#info answer lists the commands feature.
    static func offersCommands(in reply: Iq) -> Bool {
        guard let query = reply.firstChild(name: "query", xmlns: DiscoveryModule.INFO_XMLNS) else { return false }
        return query.filterChildren(name: "feature", xmlns: nil).contains { $0.getAttribute("var") == NS.commands }
    }

    /// The step's answer, which has to be for the command asked for and, when
    /// a run was continued, for the same run.
    static func response(in reply: Iq, node: String, sessionID: String?) throws -> AdHocResponse {
        guard let command = reply.firstChild(name: "command", xmlns: NS.commands), command.getAttribute("node") == node,
              let status = command.getAttribute("status").flatMap(AdHocResponse.Status.init(rawValue:)) else { throw AdHocError.unexpectedReply }
        let session = command.getAttribute("sessionid").flatMap { $0.isEmpty ? nil : $0 }
        if let sessionID, let session, session != sessionID { throw AdHocError.unexpectedReply }

        var allowed: [AdHocAction] = []
        var preferred: AdHocAction?
        if let actions = command.firstChild(name: "actions") {
            let order: [AdHocAction] = [.prev, .next, .complete]
            allowed = order.filter { actions.firstChild(name: $0.rawValue) != nil }
            preferred = actions.getAttribute("execute").flatMap(AdHocAction.init(rawValue:)).flatMap { allowed.contains($0) ? $0 : nil }
        } else if status == .executing {
            allowed = [.complete]
        }
        let defaultAction = preferred ?? (allowed.contains(.next) ? .next : allowed.contains(.complete) ? .complete : nil)

        let notes = command.filterChildren(name: "note", xmlns: nil).compactMap { note -> AdHocNote? in
            guard let text = note.value, !text.isEmpty else { return nil }
            return AdHocNote(kind: note.getAttribute("type").flatMap(AdHocNote.Kind.init(rawValue:)) ?? .info, text: text)
        }
        let form = command.firstChild(name: "x", xmlns: NS.dataForms).flatMap(XDataForm.init)
        return AdHocResponse(sessionID: session ?? sessionID, status: status, form: form, allowed: allowed, defaultAction: defaultAction, notes: notes)
    }

    /// Reads an error stanza, which `nil` stands for when none came in time.
    /// The conditions XEP-0050 adds are children in the commands namespace
    /// beside the general one, which Martin's decoder doesn't look at.
    static func error(from stanza: Stanza?) -> Error {
        guard let stanza else { return AdHocError.timedOut }
        guard let error = stanza.firstChild(name: "error"), let server = ServerError(error) else { return AdHocError.refused(reason: "undefined-condition") }
        let text = server.text
        let specific = error.children.first { $0.xmlns == NS.commands }?.name
        let general = server.condition
        switch specific {
        case "bad-action": return AdHocError.badAction(text: text)
        case "malformed-action": return AdHocError.malformedAction(text: text)
        case "bad-sessionid": return AdHocError.badSessionID(text: text)
        case "session-expired": return AdHocError.sessionExpired(text: text)
        case "bad-payload": return AdHocError.badPayload(text: text)
        default: break
        }
        switch general {
        case "forbidden", "not-allowed", "not-authorized": return AdHocError.forbidden(text: text)
        case "item-not-found", "recipient-unavailable", "gone": return AdHocError.notFound(text: text)
        case "service-unavailable", "feature-not-implemented": return AdHocError.unsupported(text: text)
        case "remote-server-timeout": return AdHocError.timedOut
        case let other: return AdHocError.refused(reason: text ?? other)
        }
    }
}
