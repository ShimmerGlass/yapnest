import Foundation

/// The signed-in account as an extension sees it: who it is, where its files
/// are, and the resource its session connects with.
struct ExtensionAccount {
    var credentials: XMPPSession.Credentials
    var directory: URL
    var resource: String

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
