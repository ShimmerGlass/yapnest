import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO

/// OMEMO 0.3 (`eu.siacs.conversations.axolotl`) for one account: owns the
/// key store and MartinOMEMO's module, and turns their callback API into
/// what the session needs.
final class OMEMOEncryption: @unchecked Sendable {
    enum DecryptResult {
        /// `trust` is how far the sending device was trusted, if known.
        case decrypted(device: Int32?, trust: OMEMODevice.Trust?)
        /// Nothing to show: a key-transport message that only sets up a
        /// session, or one we already decrypted.
        case ignore
        /// A copy of our own message, which only our other devices could
        /// decrypt: nothing to show, but we wrote it.
        case ownCopy
        case failed(String)
    }

    let store: OMEMOStore
    let module: OMEMOModule
    private let storage: SignalStorage
    private let context: SignalContext
    private let account: JID
    /// Chats send at the same time; one message encrypts at a time, as each
    /// advances the sessions it uses.
    private let encodeLock = NSLock()

    /// How long to wait for device lists and bundles before giving up on a send.
    static let setupTimeout: TimeInterval = 45

    init(database: AppDatabase, account: JID, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.account = account
        store = OMEMOStore(database: database, account: account, now: now)
        storage = SignalStorage(sessionStore: store, preKeyStore: store, signedPreKeyStore: store, identityKeyStore: store, senderKeyStore: store)
        guard let context = SignalContext(withStorage: storage) else { throw OMEMOError.keyGenerationFailed }
        self.context = context
        try store.setUpIdentityIfNeeded(context: context)
        module = OMEMOModule(aesGCMEngine: CryptoKitAESGCM(), signalContext: context, signalStorage: storage)
        module.defaultBody = "This message is encrypted with OMEMO, which your client doesn't support."
    }

    var deviceId: UInt32 { store.localRegistrationId() }

    // MARK: Inbound

    /// Decrypts `stanza` in place, replacing its `<encrypted>` element with the body.
    ///
    /// - Parameters:
    ///   - sender: the real bare JID of the sending account; in group chats,
    ///     the occupant's, which the stanza itself doesn't carry.
    ///   - ownCopy: the stanza is a copy of one of our own messages, which
    ///     only our other devices could decrypt if this one sent it.
    ///   - sentAt: when the message was sent, for the device's last use. An
    ///     archived message is from its day, not today.
    func decrypt(_ stanza: Martin.Message, from sender: JID, ownCopy: Bool, isHistory: Bool = false, sentAt: Date = Date()) -> DecryptResult {
        // Martin only rebuilds broken sessions for messages that came through
        // the server, which it recognizes by a server id; ours are all such,
        // except old history. Sessions have moved on since then, so most of
        // it fails however often the session is rebuilt, and each message
        // would start another rebuild.
        let device = stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy)?.firstChild(name: "header")?
            .getAttribute("sid").flatMap { Int32($0) }
        // Whatever becomes of the message, it shows the device exists and is
        // in use. Recorded on the way out, after decoding, which is where a
        // new device's identity is first stored.
        defer {
            if let device { store.noteUsed(name: sender.description, deviceId: device, at: sentAt) }
        }
        let status = device.flatMap { store.status(forName: sender.description, deviceId: $0) }
        // Signal checks trust only when it builds a session, so a device with
        // a session would go on being read. Not decoding also leaves the
        // ratchet alone and starts no session repair.
        if status?.trust == .compromised { return .failed("sent from a device marked compromised") }
        switch module.decode(message: stanza, from: sender.martin, serverMsgId: isHistory ? nil : "") {
        case .successMessage:
            guard let device else { return .decrypted(device: nil, trust: nil) }
            // Decoding is where a first message's identity is saved, so read
            // the status again: a new device of a verified contact is
            // undecided only from here on.
            let decoded = store.status(forName: sender.description, deviceId: device)
            return .decrypted(device: device, trust: (decoded ?? status).map(OMEMODevice.Trust.init))
        case .successTransportKey:
            return .ignore
        case .failure(.duplicateMessage):
            return .ignore
        case .failure(let error):
            // Copies of what this device sent, or what our other devices sent
            // before this one existed, were never encrypted for us; there's
            // nothing to recover.
            if ownCopy { return .ownCopy }
            return .failed("\(error)")
        }
    }

    // MARK: Outbound

    enum EncryptError: Error, LocalizedError {
        case unsupported(JID)
        /// The server wouldn't give us their device list.
        case listWithheld(JID)
        case noTrustedDevices(JID)
        case setupFailed(JID)

        var errorDescription: String? {
            switch self {
            case .unsupported(let peer): "\(peer) can't receive encrypted messages. Turn off encryption to send without it."
            case .listWithheld(let peer): "\(peer)'s server doesn't let us read their encryption keys, as we aren't in their contacts. Turn off encryption to send without it."
            case .noTrustedDevices(let peer): "None of \(peer)'s devices are trusted."
            case .setupFailed(let peer): "Couldn't set up encryption with \(peer)."
            }
        }
    }

    /// Encrypts `stanza` for the trusted devices of every recipient and our
    /// own, in place. Also returns `.verified` if every recipient device it
    /// went to is verified, `.trusted` otherwise.
    /// Blocks while fetching device lists and bundles; never call it on a
    /// queue those callbacks need (Martin's or the main queue).
    func encrypt(_ stanza: Martin.Message, for recipients: [JID]) -> Result<(Martin.Message, OMEMODevice.Trust), EncryptError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var fetched: [SignalAddress]?
        // Our own list too, so sessions get built with a device of ours that
        // just appeared: MartinOMEMO adds our devices it has sessions with.
        module.addresses(for: (recipients + [account]).map(\.martin)) { result in
            if case .success(let addresses) = result { fetched = addresses }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.setupTimeout) == .success, let fetched else {
            return .failure(.setupFailed(recipients.first ?? account))
        }

        var usable: [SignalAddress] = []
        var allVerified = true
        for recipient in recipients {
            let devices = Set(fetched.filter { $0.name == recipient.description })
            guard !devices.isEmpty else {
                // A list kept from strangers is not a lack of OMEMO.
                switch module.deviceListError(for: recipient.martin) {
                case .not_authorized, .forbidden: return .failure(.listWithheld(recipient))
                default: return .failure(.unsupported(recipient))
                }
            }
            let identities = Dictionary(store.identities(forName: recipient.description).map { ($0.address.deviceId, $0.status) }, uniquingKeysWith: { a, _ in a })
            let trustedAll = devices.filter { address in
                guard store.containsSessionRecord(forAddress: address), let status = identities[address.deviceId] else { return false }
                return status.isActive && (status.trust == .trusted || status.trust == .verified)
            }
            // Devices that went quiet are skipped, but never all of them.
            let current = Set(store.excludingInactive(trustedAll.map(\.deviceId), of: recipient.description))
            let trusted = trustedAll.filter { current.contains($0.deviceId) }
            guard !trusted.isEmpty else {
                let hasSessions = devices.contains { store.containsSessionRecord(forAddress: $0) }
                return .failure(hasSessions ? .noTrustedDevices(recipient) : .setupFailed(recipient))
            }
            usable += trusted
            allVerified = allVerified && trusted.allSatisfy { identities[$0.deviceId]?.trust == .verified }
        }
        let own = store.ownDevicesToEncryptTo().map { SignalAddress(name: account.description, deviceId: $0) }
        return encode(stanza, for: usable + own, verified: allVerified, checking: recipients)
    }

    private func encode(_ stanza: Martin.Message, for addresses: [SignalAddress], verified: Bool, checking recipients: [JID]) -> Result<(Martin.Message, OMEMODevice.Trust), EncryptError> {
        nonisolated(unsafe) var encoded: EncryptionResult<Martin.Message, SignalError> = .failure(.unknown)
        encodeLock.withLock {
            // `addresses` has our own devices already; MartinOMEMO would add the inactive ones too.
            module.encode(message: stanza, forAddresses: addresses, forSelf: false) { encoded = $0 }
        }
        guard case .successMessage(let message, _) = encoded else { return .failure(.setupFailed(recipients.first ?? account)) }

        // MartinOMEMO drops devices it fails to encrypt for; make sure every
        // recipient can read it at all.
        let keys = Set(message.firstChild(name: "encrypted", xmlns: NS.omemoLegacy)?.firstChild(name: "header")?
            .filterChildren(name: "key", xmlns: nil).compactMap { $0.getAttribute("rid") } ?? [])
        for recipient in recipients {
            let devices = addresses.filter { $0.name == recipient.description }.map { String($0.deviceId) }
            guard devices.contains(where: keys.contains) else { return .failure(.setupFailed(recipient)) }
        }
        return .success((message, verified ? .verified : .trusted))
    }
}
