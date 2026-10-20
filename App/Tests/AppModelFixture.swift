import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// A keychain stand-in that can refuse to save.
final class FakeCredentials: CredentialStoring, @unchecked Sendable {
    struct SaveFailed: Error {}

    private let state = NSLock()
    private var stored: XMPPSession.Credentials?
    private var refuses = false

    var refusesToSave: Bool {
        get { state.withLock { refuses } }
        set { state.withLock { refuses = newValue } }
    }

    func load() throws -> XMPPSession.Credentials? { state.withLock { stored } }

    func save(_ credentials: XMPPSession.Credentials) throws {
        try state.withLock {
            if refuses { throw SaveFailed() }
            stored = credentials
        }
    }

    func update(_ credentials: XMPPSession.Credentials) throws { try save(credentials) }

    func delete() throws { state.withLock { stored = nil } }
}

/// An `AppModel` over a scratch directory, its own process lock and a
/// connection that answers as the test says, so signing in needs no server.
@MainActor
final class AppModelFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "appmodel-\(UUID().uuidString)")
    let lock: ProcessLock
    /// Another process's handle on the same lock.
    let otherProcess: ProcessLock
    let credentials = FakeCredentials()
    let account = JID("me-\(UUID().uuidString.prefix(8).lowercased())@example.com")!
    private(set) var model: AppModel!
    private(set) var connects: [XMPPSession] = []
    /// Whether a connection attempt ends with the server accepting the session.
    var accepts = true
    /// The passwords the server was asked to change to, with the current ones sent.
    private(set) var passwordChanges: [(new: String, current: String)] = []
    /// What the server answers a password change with; nil accepts it.
    var passwordChangeError: Error?
    /// The passwords the server was asked to vouch for, a stale keychain's tell.
    private(set) var passwordVerifications: [String] = []
    /// The passwords the server takes as the account's current one.
    var acceptedPasswords: Set<String> = []
    /// What stops a verification before the server answers; nil lets it answer.
    var passwordVerificationError: Error?
    private(set) var fastTokenWipes = 0

    init(
        lockTimeout: TimeInterval = 0.2, suspendDelay: Duration = .milliseconds(100),
        typingLifetime: TimeInterval = 30, disablePush: @escaping @MainActor (XMPPSession) async -> Void = { _ in },
    ) {
        lock = ProcessLock(url: root.appending(path: "session.lock"))
        otherProcess = ProcessLock(url: root.appending(path: "session.lock"))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var environment = AppModel.Environment()
        environment.credentials = credentials
        environment.sessionLock = lock
        environment.lockTimeout = lockTimeout
        environment.accountDirectory = { [root] in AccountDirectory(url: root.appending(path: $0.description)) }
        environment.suspendDelay = suspendDelay
        environment.typingLifetime = typingLifetime
        environment.typingSweepInterval = .milliseconds(50)
        environment.registersForNotifications = false
        environment.managesBadge = false
        environment.forgetSharedState = {}
        environment.forgetFastTokens = { [unowned self] in fastTokenWipes += 1 }
        environment.changePassword = { [unowned self] _, new, current in
            passwordChanges.append((new, current))
            if let passwordChangeError { throw passwordChangeError }
        }
        environment.verifyPassword = { [unowned self] _, password in
            passwordVerifications.append(password)
            if let passwordVerificationError { throw passwordVerificationError }
            return acceptedPasswords.contains(password)
        }
        environment.disablePush = disablePush
        environment.connect = { [unowned self] session in
            connects.append(session)
            guard accepts else { return }
            session.state.send(.connecting)
            session.state.send(.connected(isSyncing: false))
        }
        model = AppModel(environment: environment)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var credentialsToSignIn: XMPPSession.Credentials { .init(jid: account, password: "x", disableTLS: true) }

    var databaseFile: URL { root.appending(path: account.description).appending(path: "db.sqlite") }
}
