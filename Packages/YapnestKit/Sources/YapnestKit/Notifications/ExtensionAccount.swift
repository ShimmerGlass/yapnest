import Foundation

/// The signed-in account as an extension sees it: who it is, where its files
/// are, the resource its session connects with, and the locks that decide who
/// gets to run that session. Both extensions' tests replace the locks and the
/// identity.
struct ExtensionAccount: Sendable {
    var credentials: XMPPSession.Credentials
    var directory: URL
    var resource: String
    /// The resource the app's session binds, which an extension's session asks
    /// to bind too when it has to open one: it takes over the app's stream or,
    /// if that is gone, its place, so the server never sees a second session
    /// come and go. Over SASL2 the server picks the resource and this is
    /// ignored. Its own `resource` still names it for sign-in, keeping its FAST token.
    var appResource: String
    var lock: ProcessLock = SharedContainer.sessionLock
    /// Held by the app while it holds or waits for `lock`.
    var appLock: ProcessLock = SharedContainer.appLock
    /// This device's OMEMO identity, the app's, which the session needs to
    /// decrypt; nil for the keychain's.
    var identityKeys: (any IdentityKeyStore)?

    /// `appResource` is `resource` unless given: a session that isn't taking
    /// the app's place binds its own.
    init(
        credentials: XMPPSession.Credentials, directory: URL, resource: String, appResource: String? = nil,
        lock: ProcessLock = SharedContainer.sessionLock, appLock: ProcessLock = SharedContainer.appLock,
        identityKeys: (any IdentityKeyStore)? = nil,
    ) {
        self.credentials = credentials
        self.directory = directory
        self.resource = resource
        self.appResource = appResource ?? resource
        self.lock = lock
        self.appLock = appLock
        self.identityKeys = identityKeys
    }

    var files: AccountDirectory { AccountDirectory(url: directory) }

    /// Nil if the app hasn't been signed in. `role` tells the extension's
    /// sessions from the app's and from each other's.
    static func current(role: String) -> ExtensionAccount? {
        guard let credentials = try? CredentialStore().load(), let deviceId = SharedContainer.existingDeviceId else { return nil }
        return ExtensionAccount(
            credentials: credentials,
            directory: SharedContainer.directory(for: credentials.jid),
            resource: "yapnest-\(deviceId)-\(role)",
            appResource: "yapnest-\(deviceId)",
        )
    }
}
