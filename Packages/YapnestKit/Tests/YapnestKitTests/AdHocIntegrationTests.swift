import Foundation
import Martin
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Ad-hoc commands (XEP-0050) on the real server: what an ordinary user is
    /// offered, and commands with forms, run by the admin account that the
    /// ejabberd dev config makes (dev/ejabberd/ejabberd.yml, created by
    /// setup.sh). The admin ones need ejabberd and are skipped elsewhere.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=ejabberd swift test --filter AdHocIntegration`
    struct AdHocIntegrationTests {
        static let admin = "http://jabber.org/protocol/admin"

        private func adminSession() async throws -> XMPPSession {
            guard LiveServer.target.name == "ejabberd" else {
                try Test.cancel("only the ejabberd dev config has an admin account with commands")
            }
            return try await LiveServer.connectedSession(LiveServer.jid("admin"), resource: "adhoc")
        }

        private func command(_ node: String) -> AdHocCommand { AdHocCommand(jid: "localhost", node: node, name: node) }

        @Test func aUserIsOfferedTheServersCommandsAndRunsOne() async throws {
            let alice = try await LiveServer.connectedSession(LiveServer.jid("alice"), resource: "adhoc")
            defer { alice.disconnect() }
            // A server without the module may answer that there is no such node.
            let commands = (try? await alice.adHocCommands(at: "localhost")) ?? []
            guard !commands.isEmpty else { try Test.cancel("\(LiveServer.target.name) offers a user no commands") }
            #expect(alice.serverOffersCommands)
            #expect(commands.allSatisfy { $0.jid == "localhost" && !$0.node.isEmpty && !$0.name.isEmpty })

            let ping = try #require(commands.first { $0.node == "ping" }, "commands: \(commands)")
            let response = try await alice.execute(ping)
            #expect(response.status == .completed)
            #expect(response.notes.contains { !$0.text.isEmpty })
        }

        @Test func aCommandWithAFormTakesAnAnswerAndReturnsAResult() async throws {
            let admin = try await adminSession()
            defer { admin.disconnect() }
            let offered = try await admin.adHocCommands(at: "localhost")
            let stats = try #require(offered.first { $0.node == "\(Self.admin)#user-stats" }, "commands: \(offered.map(\.node))")

            let first = try await admin.execute(stats)
            #expect(first.status == .executing)
            #expect(first.sessionID?.isEmpty == false)
            #expect(first.allowed.contains(.complete) || first.allowed.contains(.next))
            var form = try #require(first.form)
            #expect(form.type == .form)
            let index = try #require(form.fields.firstIndex { $0.name == "accountjid" })
            #expect(form.fields[index].type == .jidSingle && form.fields[index].required)
            // Left empty, the form is caught here, not by the server.
            #expect(form.validationProblems().map(\.index) == [index])

            form.fields[index].value = "alice@localhost"
            #expect(form.validationProblems().isEmpty)
            let done = try await admin.execute(stats, action: first.defaultAction ?? .complete, sessionID: first.sessionID, form: form)
            #expect(done.status == .completed)
            let result = try #require(done.form)
            #expect(result.fields.first { $0.name == "accountjid" }?.value == "alice@localhost")
            #expect(result.fields.contains { $0.name == "rostersize" })
        }

        @Test func aCancelledRunCannotBeContinued() async throws {
            let admin = try await adminSession()
            defer { admin.disconnect() }
            let stats = command("\(Self.admin)#user-stats")
            let first = try await admin.execute(stats)
            let session = try #require(first.sessionID)
            let cancelled = try await admin.execute(stats, action: .cancel, sessionID: session)
            #expect(cancelled.status == .canceled)
            await #expect(throws: AdHocError.self) { try await admin.execute(stats, action: .complete, sessionID: session, form: first.form) }
            // Best effort, and quiet about a run that is already gone.
            await admin.cancelAdHoc(stats, sessionID: session)
        }

        @Test func aUserIsRefusedTheAdminsCommands() async throws {
            let alice = try await LiveServer.connectedSession(LiveServer.jid("alice"), resource: "adhoc")
            defer { alice.disconnect() }
            do {
                _ = try await alice.execute(command("\(Self.admin)#user-stats"))
                Issue.record("alice ran an admin command")
            } catch let error as AdHocError {
                // Servers say forbidden, or pretend there is no such command.
                #expect([.forbidden, .notFound].contains(error.kind), "\(error)")
            }
        }

        @Test func aCommandThatDoesNotExistIsNotFound() async throws {
            let alice = try await LiveServer.connectedSession(LiveServer.jid("alice"), resource: "adhoc")
            defer { alice.disconnect() }
            do {
                _ = try await alice.execute(command("no-such-command"))
                Issue.record("the server ran a command that doesn't exist")
            } catch let error as AdHocError {
                #expect([.notFound, .unsupported].contains(error.kind), "\(error)")
            }
        }
    }
}

private extension AdHocError {
    enum Kind { case forbidden, notFound, unsupported, other }

    /// The case without the server's text, which a test can't know.
    var kind: Kind {
        switch self {
        case .forbidden: .forbidden
        case .notFound: .notFound
        case .unsupported: .unsupported
        default: .other
        }
    }
}
