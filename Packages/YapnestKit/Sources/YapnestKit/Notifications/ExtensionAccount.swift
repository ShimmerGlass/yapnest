import Foundation

/// The signed-in account as an extension sees it: who it is, where its files
/// are, the resource its session connects with, and the locks that decide who
/// gets to run that session. Both extensions' tests replace the locks and the
/// identity.
struct ExtensionAccount: Sendable {
    var credentials: XMPPSession.Credentials
    var directory: URL
    var resource: String
    var lock: ProcessLock = SharedContainer.sessionLock
    /// Held by the app while it holds or waits for `lock`.
    var appLock: ProcessLock = SharedContainer.appLock
    /// This device's OMEMO identity, the app's, which the session needs to
    /// decrypt; nil for the keychain's.
    var identityKeys: (any IdentityKeyStore)?

    var files: AccountDirectory { AccountDirectory(url: directory) }

    /// Nil if the app hasn't been signed in. `role` tells the extension's
    /// sessions from the app's and from each other's.
    static func current(role: String) -> ExtensionAccount? {
        guard let credentials = try? CredentialStore().load(), let deviceId = SharedContainer.existingDeviceId else { return nil }
        return ExtensionAccount(
            credentials: credentials,
            directory: SharedContainer.directory(for: credentials.jid),
            resource: "yapnest-\(deviceId)-\(role)",
        )
    }
}
