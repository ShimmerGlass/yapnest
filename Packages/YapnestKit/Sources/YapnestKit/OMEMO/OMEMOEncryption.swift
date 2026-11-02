import Combine
import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import os

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
        /// A group message from a device we've never seen, left undecoded
        /// until the sender's own server says the device is theirs.
        case unvouched(device: Int32)
    }

    /// Who says the stanza is from `sender`.
    enum SenderClaim {
        /// The stanza's own address, which their server stands behind.
        case stanza
        /// A room, which could name anyone: a device we've never seen must
        /// first be vouched for by the sender's own server.
        case room
        /// A room, for a sender whose server won't show us their devices.
        /// Read on the room's word alone, a new device is left undecided, so
        /// its messages show as from a device nobody has vouched for.
        case roomUnchecked
    }

    let store: OMEMOStore
    let module: OMEMOModule
    private let storage: SignalStorage
    private let context: SignalContext
    private let account: JID
    /// Chats send at the same time; one message encrypts at a time, as each
    /// advances the sessions it uses.
    private let encodeLock = NSLock()
    /// Held group messages are decrypted off the queue that decrypts what
    /// arrives, and two decodes of one device's messages at once would each
    /// store the session as they left it. Not `encodeLock`, so that a decode
    /// doesn't wait behind the encryption of a send.
    private let decodeLock = NSLock()
    /// Whether `replaceDevice` has made the module's device a stale one. Set
    /// holding both locks, and read holding either.
    private var isRetired = false
    /// Replaced devices to take off our list: see `retireReplacedDevices`.
    private struct Retirement {
        /// Whether any are noted, so that every other install's list reads
        /// cost nothing.
        var isPending: Bool
        /// When the removal under way started. One whose answer never came,
        /// with the connection gone, stops holding the next back after a while.
        var startedAt: Date?

        func isBusy(at now: Date) -> Bool {
            startedAt.map { now.timeIntervalSince($0) < 120 } ?? false
        }
    }

    private let retirement: OSAllocatedUnfairLock<Retirement>
    private var ownListHeard: AnyCancellable?

    /// How long to wait for device lists and bundles before giving up on a send.
    var setupTimeout: TimeInterval = 45

    /// How long a call waits for the peer's device list before its fingerprint
    /// goes out plain. The caller's session-initiate is due within the
    /// callee's setup window after `proceed`, and a send is not worth 45 s.
    var callFetchTimeout: TimeInterval = 5

    /// - Parameter rotatesSignedPreKey: whether this process replaces the signed prekey when it is due. Only the
    ///   app's does: the extensions run beside it and would make the next one at the same time, each with the
    ///   next id and a key of its own, so that the bundle published and the one kept could differ.
    init(database: AppDatabase, account: JID, identityKeys: any IdentityKeyStore, rotatesSignedPreKey: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.account = account
        store = OMEMOStore(database: database, account: account, identityKeys: identityKeys, now: now)
        storage = SignalStorage(sessionStore: store, preKeyStore: store, signedPreKeyStore: store, identityKeyStore: store, senderKeyStore: store)
        guard let context = SignalContext(withStorage: storage) else { throw OMEMOError.keyGenerationFailed }
        self.context = context
        store.signalContext = context
        try store.setUpIdentityIfNeeded(context: context)
        retirement = OSAllocatedUnfairLock(initialState: Retirement(isPending: !store.replacedDeviceIds().isEmpty))
        module = OMEMOModule(aesGCMEngine: CryptoKitAESGCM(), signalContext: context, signalStorage: storage)
        if rotatesSignedPreKey { module.signedPreKeyRotationDue = { [store] in store.signedPreKeyRotationDue() } }
        module.limitDevices = { [store] jid, ids in store.limited(ids, of: jid.stringValue) }
        module.diagnostics = { [store] event in
            if case let .bundlePublished(signedPreKeyId, _, _, _) = event { store.signedPreKeyPublished(id: signedPreKeyId) }
            OMEMOEvent.log(event)
        }
        module.defaultBody = "This message is encrypted with OMEMO, which your client doesn't support."
        ownListHeard = module.activeDevicesPublisher.sink { [weak self] change in
            // An extension doesn't publish our keys, so it leaves our list alone.
            guard let self, change.readFromServer, change.jid.stringValue == account.description, module.publishesKeys else { return }
            retireReplacedDevices(listed: change.activeDevices)
        }
    }

    var deviceId: UInt32 { store.localRegistrationId() }

    /// Makes the install a new device: see `OMEMOStore.replaceIdentity`. The
    /// module reads its device id and keys from the store each time, so it
    /// answers as the new device from here on, though that device is not yet
    /// on our list or published, and its state was built for the old one. This
    /// instance therefore refuses to encrypt or decrypt from then on, and only
    /// the next `OMEMOEncryption` over the database may be used.
    func replaceDevice() throws {
        // A send or decode still under way would store its session after
        // they're all deleted, built on the old key. So would a session
        // MartinOMEMO builds from a fetched bundle, which holds neither lock
        // but takes libsignal's, so the swap takes that one too. Always in
        // this order: a decode takes its lock and then libsignal's, a send
        // its lock and then the store's.
        try encodeLock.withLock {
            try decodeLock.withLock {
                try context.withLock { try store.replaceIdentity(context: context) }
                isRetired = true
            }
        }
    }

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
    ///   - claim: who names `sender` as the author.
    func decrypt(_ stanza: Martin.Message, from sender: JID, ownCopy: Bool, isHistory: Bool = false, sentAt: Date = Date(), claim: SenderClaim = .stanza) -> DecryptResult {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        // Decoding as the old device would store a session built on its key,
        // and a failure would start a session repair under the new, unpublished id.
        if isRetired { return .failed("the device was replaced") }
        // Martin only rebuilds broken sessions for messages that came through
        // the server, which it recognizes by a server id; ours are all such,
        // except old history. Sessions have moved on since then, so most of
        // it fails however often the session is rebuilt, and each message
        // would start another rebuild.
        let device = stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy)?.firstChild(name: "header")?
            .getAttribute("sid").flatMap { Int32(omemoId: $0) }
        let status = device.flatMap { store.status(forName: sender.description, deviceId: $0) }
        let fromThisDevice = device.map { isLocalDevice(sender, $0) } ?? false
        let keys = keysForUs(in: stanza)
        let prekey = keys.contains(where: Self.isPreKey)
        // Decoding a prekey message for us stores the identity it carries, so
        // a room could otherwise give any member a device of its own, which
        // would then also count among theirs in use and push real ones past
        // the cap. Nothing else from an unknown device can be decoded, and
        // goes on as before: our own messages from before this device
        // existed must still be taken as ours.
        if claim == .room, let device, status == nil, !fromThisDevice, prekey {
            // One with no payload only sets up a session, which would store
            // the key all the same, and has nothing to show once vouched for.
            return Self.isKeyTransport(stanza) ? .ignore : .unvouched(device: device)
        }
        // A message that decrypts shows the device is in use. One that
        // doesn't counts only from a device we already have a session with:
        // its repair needs it not to age out, but anyone who can name a
        // sender could otherwise keep a lost device looking active with
        // messages it never wrote. Recorded on the way out, after decoding,
        // which is where a new device's identity is first stored.
        let hadSession = device.map { store.containsSessionRecord(forAddress: SignalAddress(name: sender.description, deviceId: $0)) } ?? false
        var decrypted = false
        defer {
            if let device, decrypted || hadSession { store.noteUsed(name: sender.description, deviceId: device, at: sentAt) }
        }
        // Signal checks trust only when it builds a session, so a device with
        // a session would go on being read. Not decoding also leaves the
        // ratchet alone and starts no session repair.
        if status?.trust == .compromised {
            logFailure(.compromised, keys: keys, device: device, isHistory: isHistory)
            return .failed("sent from a device marked compromised")
        }
        // A room's claim doesn't vouch for the device, so a new one is saved
        // undecided as libsignal stores it, whatever becomes of the payload.
        let unvouched = claim == .roomUnchecked && status == nil && !fromThisDevice
        let decode = { self.module.decode(message: stanza, from: sender.martin, serverMsgId: isHistory ? nil : "") }
        let decoded = if let device, unvouched {
            store.admittingUndecided(SignalAddress(name: sender.description, deviceId: device), decode)
        } else {
            decode()
        }
        switch decoded {
        case .successMessage:
            decrypted = true
            guard let device else { return .decrypted(device: nil, trust: nil) }
            DiagLog.debug(.omemo, "Decrypted", .id("device", Redacted.id(String(device))), .bool("ownAccount", sender == account), .bool("preKey", prekey), .bool("history", isHistory))
            // Decoding is where a first message's identity is saved, so read
            // the status again: a new device of a verified contact is
            // undecided only from here on.
            let decoded = store.status(forName: sender.description, deviceId: device)
            return .decrypted(device: device, trust: (decoded ?? status).map(OMEMODevice.Trust.init))
        case .successTransportKey:
            decrypted = true
            return .ignore
        case .failure(.duplicateMessage):
            return .ignore
        case .failure(let error):
            // Copies of what this device sent, or what our other devices sent
            // before this one existed, were never encrypted for us; there's
            // nothing to recover. One with a key for us was meant to be read
            // here, so its failure is logged like anyone's.
            if ownCopy {
                if !keys.isEmpty { logFailure(DecryptFailure(error), keys: keys, device: device, isHistory: isHistory) }
                return .ownCopy
            }
            logFailure(DecryptFailure(error), keys: keys, device: device, isHistory: isHistory)
            return .failed("\(error)")
        }
    }

    /// Takes the devices an older build made in this install off our list,
    /// `listed` as read from the server, with their bundles, once this device
    /// is registered: see `OMEMOStore.findOrMakeIdentity`. Before that,
    /// registration's own publish could put them back.
    func retireReplacedDevices(listed: [Int32]) {
        guard module.isReady, retirement.withLock({ $0.isPending }) else { return }
        // Lists are announced from the module's devices queue, which the
        // removal syncs onto first; the database work goes along.
        DispatchQueue.global(qos: .utility).async { [self] in
            let replaced = store.replacedDeviceIds()
            let ids = replaced.filter(listed.contains)
            // While a removal is out, the list it publishes is announced
            // before the server takes it: a device missing from it isn't gone yet.
            let starts = retirement.withLock { state in
                guard !state.isBusy(at: Date()) else { return false }
                if !ids.isEmpty { state.startedAt = Date() }
                return true
            }
            guard starts else { return }
            guard !ids.isEmpty else {
                forgetReplaced(replaced)
                return
            }
            module.removeDevices(withIds: ids) { [self] result in
                retirement.withLock { $0.startedAt = nil }
                switch result {
                case .success:
                    forgetReplaced(replaced)
                case .failure(let error):
                    // Not the user's to act on: the next read of our list, at
                    // the latest on the next connection, tries again.
                    DiagLog.error(.omemo, "Replaced device not removed", .error(ServerError(error)))
                }
            }
        }
    }

    private func forgetReplaced(_ ids: [Int32]) {
        store.forgetReplaced(ids)
        let left = store.replacedDeviceIds()
        retirement.withLock { $0.isPending = !left.isEmpty }
    }

    /// Whether `stanza` carries a key for this device at all.
    func hasKeyForThisDevice(_ stanza: Martin.Message) -> Bool {
        !keysForUs(in: stanza).isEmpty
    }

    /// Which of the devices `stanza` holds keys for are ours: this one, and
    /// the other devices of the account.
    func keyHolders(in stanza: Martin.Message) -> (forThisDevice: Bool, forOtherOwnDevices: Bool) {
        let ours = Int32(bitPattern: deviceId).omemoId
        let others = Set(store.ownDevicesToEncryptTo().map(\.omemoId)).subtracting([ours])
        let rids = Self.keyRids(in: stanza)
        return (rids.contains(ours), rids.contains { others.contains($0) })
    }

    /// The keys in `stanza` for this device. Martin tries each of them.
    private func keysForUs(in stanza: Martin.Message) -> [Element] {
        let ours = String(deviceId)
        return Self.keyElements(in: stanza).filter { $0.getAttribute("rid") == ours }
    }

    private static func keyElements(in stanza: Martin.Message) -> [Element] {
        stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy)?.firstChild(name: "header")?.filterChildren(name: "key", xmlns: nil) ?? []
    }

    private static func keyRids(in stanza: Martin.Message) -> [String] {
        keyElements(in: stanza).compactMap { $0.getAttribute("rid") }
    }

    private static func isPreKey(_ key: Element) -> Bool {
        ["true", "1"].contains(key.getAttribute("prekey"))
    }

    private func isLocalDevice(_ sender: JID, _ device: Int32) -> Bool {
        sender == account && UInt32(bitPattern: device) == deviceId
    }

    /// How long a read of a held message's sender's keys waits. Martin may
    /// never answer a request whose stream went away, and the run waiting on
    /// it would hold up every held message until the app is restarted.
    var heldReadTimeout: TimeInterval = 30

    /// The devices the sender's own server lists for them now.
    func readDeviceList(of sender: JID) async -> Result<[Int32], PubSubError> {
        let (module, timeout) = (module, heldReadTimeout)
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            module.readDeviceList(of: sender.martin) { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.failure(.remote_server_timeout)) }
        }
    }

    /// The identity key the sender's own server publishes for `device`.
    func readIdentityKey(of device: Int32, of sender: JID) async -> OMEMOModule.IdentityKeyRead {
        let (module, timeout) = (module, heldReadTimeout)
        return await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            module.readIdentityKey(of: device, of: sender.martin) { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.unavailable(.remote_server_timeout)) }
        }
    }

    /// Keeps the identity key the sender's own server published for `device`,
    /// which a prekey message from it must then carry to be read. A key we
    /// already hold for it stays. Whether one is now kept: a failed write
    /// would leave the device to be read on the room's word.
    func vouch(for device: Int32, of sender: JID, identityKey: Data) -> Bool {
        _ = store.save(identity: SignalAddress(name: sender.description, deviceId: device), publicKeyData: identityKey)
        return store.status(forName: sender.description, deviceId: device) != nil
    }

    /// Martin's own reason only reaches the private system log, which the
    /// diagnostics export can't carry. A message with no key for this device
    /// was never readable here; a prekey message points at our published keys.
    private func logFailure(_ failure: DecryptFailure, keys: [Element], device: Int32?, isHistory: Bool) {
        let key = keys.first
        let prekey = key.map(Self.isPreKey) ?? false
        var fields: [DiagField] = [.value("error", failure), .bool("keyForUs", key != nil), .bool("preKey", prekey), .bool("history", isHistory)]
        if let device { fields.append(.id("device", Redacted.id(String(device)))) }
        DiagLog.notice(.omemo, "Couldn't decrypt", fields: fields)
    }

    // MARK: Outbound

    enum EncryptError: Error, LocalizedError {
        case unsupported(JID)
        /// The server wouldn't give us their device list.
        case listWithheld(JID)
        case noTrustedDevices(JID)
        /// Nobody but our own devices would be able to read it: a room whose
        /// members aren't known, or has none besides us. The message is marked
        /// failed, with a way to try again, and not held to be sent by itself.
        case noRecipients
        case setupFailed(JID)
        /// The server answered a request for their device list or bundle with
        /// an error that isn't "no such thing", or didn't answer in time.
        case fetchFailed(JID, ServerError)

        /// The `detail` of the error for a setup that ran out of time with no answer.
        static let setupTimeoutDetail = "setup-timeout"

        /// Whether sending again soon may work, so it is retried and not shown:
        /// a server's answer that may pass. Not the whole setup running out of
        /// time, which has already held the send queue for its full wait and
        /// would again, once per message, for a peer whose server never answers.
        var isPassing: Bool {
            if case .fetchFailed(_, let error) = self { return error.isPassing && error.detail != Self.setupTimeoutDetail }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .unsupported(let peer): "\(peer) can't receive encrypted messages. Turn off encryption to send without it."
            case .listWithheld(let peer): "\(peer)'s server doesn't let us read their encryption keys, as we aren't in their contacts. Turn off encryption to send without it."
            case .noTrustedDevices(let peer): "None of \(peer)'s devices are trusted."
            case .noRecipients: "There is no one to encrypt this message for yet. It isn't sent: try again once the group has other members."
            case .setupFailed(let peer): "Couldn't set up encryption with \(peer)."
            case .fetchFailed(let peer, let error): error.describe("Couldn't get \(peer)'s encryption keys. Turn off encryption to send without it")
            }
        }
    }

    /// Encrypts `stanza` for the trusted devices of every recipient and our
    /// own, in place. Also returns `.verified` if every recipient device it
    /// went to is verified, `.trusted` otherwise.
    /// Blocks while fetching device lists and bundles; never call it on a
    /// queue those callbacks need (Martin's or the main queue).
    func encrypt(_ stanza: Martin.Message, for recipients: [JID]) -> Result<(Martin.Message, OMEMODevice.Trust), EncryptError> {
        var unsupported = Set<JID>()
        return encrypt(stanza, for: recipients, skippingUnreachable: false, unsupported: &unsupported).map { ($0.message, $0.trust) }
    }

    /// Whether `stanza` has an `<encrypted>` element with keys and no
    /// payload: it sets up sessions and has nothing to show.
    static func isKeyTransport(_ stanza: Martin.Message) -> Bool {
        guard let encrypted = stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy) else { return false }
        return encrypted.firstChild(name: "payload") == nil
    }

    struct KeyTransportOutcome {
        var result: Result<(message: Martin.Message, reached: Set<JID>), EncryptError>
        var unsupported: Set<JID>
    }

    /// Encrypts the body-less `stanza` into keys alone for the devices of
    /// `recipients` that can be reached and our own, by the rules of
    /// `encrypt(_:for:)`. A recipient with no device to encrypt to is left
    /// out, as the others are still to be reached; only when none can be
    /// does it fail. `reached` is who the message holds a key for, and
    /// `unsupported` who has no OMEMO at all, whether or not it succeeded.
    func keyTransport(_ stanza: Martin.Message, for recipients: [JID]) -> KeyTransportOutcome {
        var unsupported = Set<JID>()
        let result: Result<(message: Martin.Message, reached: Set<JID>), EncryptError> = encrypt(stanza, for: recipients, skippingUnreachable: true, unsupported: &unsupported).map { encrypted in
            // MartinOMEMO's `encode` puts the fallback text on every message
            // it encrypts, which would show as one here.
            encrypted.message.body = nil
            return (encrypted.message, encrypted.reached)
        }
        return KeyTransportOutcome(result: result, unsupported: unsupported)
    }

    private func encrypt(_ stanza: Martin.Message, for recipients: [JID], skippingUnreachable: Bool, unsupported: inout Set<JID>) -> Result<(message: Martin.Message, trust: OMEMODevice.Trust, reached: Set<JID>), EncryptError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // Otherwise the message would be sealed for our own devices alone and
        // go out looking encrypted for the room, which no member could read.
        if !skippingUnreachable, recipients.isEmpty { return .failure(.noRecipients) }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var fetched: [SignalAddress]?
        // Our own list too, so sessions get built with a device of ours that
        // just appeared: MartinOMEMO adds our devices it has sessions with.
        module.addresses(for: (recipients + [account]).map(\.martin)) { result in
            if case .success(let addresses) = result { fetched = addresses }
            done.signal()
        }
        guard done.wait(timeout: .now() + setupTimeout) == .success, let fetched else {
            // The wait ended with no answer, which may pass.
            return .failure(.fetchFailed(recipients.first ?? account, ServerError(condition: "remote-server-timeout", type: .wait, detail: EncryptError.setupTimeoutDetail)))
        }

        var usable: [SignalAddress] = []
        var devicesOf: [JID: [SignalAddress]] = [:]
        var reached: [JID] = []
        var firstFailure: EncryptError?
        var skipped = 0
        var allVerified = true
        var unsupportedRecipients = Set<JID>()
        defer { unsupported = unsupportedRecipients }
        // The failure to return, or nil for a recipient that is left out.
        func unreachable(_ failure: EncryptError, of recipient: JID? = nil) -> EncryptError? {
            if case .unsupported = failure, let recipient { unsupportedRecipients.insert(recipient) }
            guard skippingUnreachable else { return failure }
            firstFailure = firstFailure ?? failure
            return nil
        }
        let states = store.sendState(forNames: recipients.map(\.description))
        for recipient in recipients {
            let state = states[recipient.description] ?? OMEMOStore.SendState()
            let identities = state.statuses
            let devices = Set(fetched.filter { $0.name == recipient.description })
            guard !devices.isEmpty else {
                if let failure = unreachable(Self.missingDevices(of: recipient, listError: module.deviceListError(for: recipient.martin), bundleError: module.bundleError(for: recipient.martin)), of: recipient) { return .failure(failure) }
                continue
            }
            let trustedAll = devices.filter { address in
                guard state.sessions.contains(address.deviceId), let status = identities[address.deviceId] else { return false }
                return status.isActive && (status.trust == .trusted || status.trust == .verified)
            }
            // Devices that went quiet are skipped, but never all of them.
            let current = Set(store.excludingInactive(trustedAll.map(\.deviceId), usage: state.usage))
            let trusted = trustedAll.filter { current.contains($0.deviceId) }
            guard !trusted.isEmpty else {
                let hasSessions = devices.contains { state.sessions.contains($0.deviceId) }
                let failure: EncryptError
                if !hasSessions, let error = module.bundleError(for: recipient.martin) {
                    failure = .fetchFailed(recipient, ServerError(error))
                } else {
                    failure = hasSessions ? .noTrustedDevices(recipient) : .setupFailed(recipient)
                }
                if let failure = unreachable(failure) { return .failure(failure) }
                continue
            }
            skipped += devices.count - trusted.count
            usable += trusted
            devicesOf[recipient] = Array(trusted)
            reached.append(recipient)
            allVerified = allVerified && trusted.allSatisfy { identities[$0.deviceId]?.trust == .verified }
        }
        if skippingUnreachable, reached.isEmpty { return .failure(firstFailure ?? .setupFailed(account)) }
        let own = store.ownDevicesToEncryptTo().map { SignalAddress(name: account.description, deviceId: $0) }
        DiagLog.info(.omemo, "Encrypting", .int("recipients", reached.count), .int("recipientDevices", usable.count), .int("ownDevices", own.count), .int("skipped", skipped))
        // MartinOMEMO drops a device it fails to encrypt for, so a key
        // transport counts who got a key rather than fail for one session.
        let result = encode(stanza, for: usable + own, verified: allVerified, checking: skippingUnreachable ? [] : reached)
        guard skippingUnreachable else { return result.map { ($0.0, $0.1, Set(reached)) } }
        return result.flatMap { message, trust in
            let keys = Set(Self.keyRids(in: message))
            let got = Set(reached.filter { recipient in devicesOf[recipient]?.contains { keys.contains($0.deviceId.omemoId) } == true })
            guard !got.isEmpty else { return .failure(firstFailure ?? .setupFailed(reached.first ?? account)) }
            return .success((message, trust, got))
        }
    }

    // MARK: Calls

    /// A call's DTLS fingerprint as an OMEMO message for one device of the
    /// peer: the element that goes into the Jingle session. Unlike a chat
    /// message it is not held back for an undecided device, as the fingerprint
    /// is no secret and the point is for the peer to check it; only a device
    /// marked compromised is refused.
    func encryptCallFingerprint(_ fingerprint: String, to peer: JID, device: Int32) async -> Result<Element, CallFingerprintError> {
        let module = module
        let name = peer.description
        // Before any waiting, and whatever the peer's list says.
        if store.status(forName: name, deviceId: device)?.trust == .compromised { return .failure(.compromisedDevice) }
        let timeout = callFetchTimeout
        let listed: [Int32]? = await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            module.addresses(for: [peer.martin]) { result in
                once.resume((try? result.get())?.filter { $0.name == name }.map(\.deviceId))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
        if listed == nil { return .failure(.setupFailed) }
        // The peer's own list, from which sessions are built: a device the
        // peer's caller names that isn't on it is not theirs to vouch with.
        let address = SignalAddress(name: name, deviceId: device)
        guard listed?.contains(device) == true, store.containsSessionRecord(forAddress: address) else { return .failure(.noSession) }
        guard let status = store.status(forName: address.name, deviceId: device), status.isActive else { return .failure(.noSession) }
        if status.trust == .compromised { return .failure(.compromisedDevice) }

        let message = Martin.Message()
        message.body = fingerprint
        guard case .successMessage(let result, _) = encodeKeepingSessions(message, for: [address]),
              let encrypted = result.firstChild(name: "encrypted", xmlns: NS.omemoLegacy),
              encrypted.firstChild(name: "header")?.filterChildren(name: "key", xmlns: nil).contains(where: { $0.getAttribute("rid") == device.omemoId }) == true,
              encrypted.firstChild(name: "payload") != nil else { return .failure(.setupFailed) }
        result.removeChild(encrypted)
        return .success(encrypted)
    }

    /// The fingerprint in a call's `<encrypted>` element, with the device that
    /// sent it and how far we trust it. A device marked compromised, and
    /// anything that doesn't decrypt, is refused.
    func decryptCallFingerprint(_ encrypted: Element, from sender: JID) -> Result<CallFingerprintCipher.Opened, CallFingerprintError> {
        let message = Martin.Message()
        message.type = .chat
        message.addChild(Element(element: encrypted))
        // Marked as history so a failure starts no session repair: a repair
        // is for messages that came through the server and will come again,
        // and a call's fingerprint doesn't.
        switch decrypt(message, from: sender, ownCopy: false, isHistory: true) {
        case .decrypted(let device?, let trust):
            guard let text = message.body, !text.isEmpty else { return .failure(.undecryptable) }
            return .success(.init(fingerprint: text, device: device, trust: trust ?? .undecided))
        case .decrypted(nil, _), .ignore, .ownCopy, .unvouched:
            return .failure(.undecryptable)
        case .failed:
            let device = encrypted.firstChild(name: "header")?.getAttribute("sid").flatMap { Int32(omemoId: $0) }
            if let device, store.status(forName: sender.description, deviceId: device)?.trust == .compromised { return .failure(.compromisedDevice) }
            return .failure(.undecryptable)
        }
    }

    var callCipher: CallFingerprintCipher {
        CallFingerprintCipher(
            encrypt: { [self] fingerprint, peer, device in await encryptCallFingerprint(fingerprint, to: peer, device: device) },
            decrypt: { [self] encrypted, sender in decryptCallFingerprint(encrypted, from: sender) },
        )
    }

    /// Why `recipient` has no devices to encrypt to. A list kept from
    /// strangers is not a lack of OMEMO, and nor is a server that failed or
    /// didn't answer: only a list that isn't there, or a server without
    /// PEP, is.
    static func missingDevices(of recipient: JID, listError: PubSubError?, bundleError: PubSubError?) -> EncryptError {
        if let listError {
            let error = ServerError(listError)
            switch listError.error.errorCondition {
            case .not_authorized, .forbidden: return .listWithheld(recipient)
            case .item_not_found: return .unsupported(recipient)
            default: return error.isUnsupported ? .unsupported(recipient) : .fetchFailed(recipient, error)
            }
        }
        // Their devices were left out for failing to give a bundle a moment ago.
        if let bundleError { return .fetchFailed(recipient, ServerError(bundleError)) }
        return .unsupported(recipient)
    }

    /// Lets a send that failed with something passing look again at once.
    func forgetFetchFailures(of recipients: [JID]) {
        for recipient in recipients + [account] { module.forgetFetchFailures(for: recipient.martin) }
    }

    /// Encrypts `stanza` for exactly `addresses`, with their sessions read and
    /// written once for the message: see `OMEMOStore.batchingSessions`. A
    /// message whose sessions couldn't be kept comes back as a failure, so it
    /// never goes out.
    func encodeKeepingSessions(_ stanza: Martin.Message, for addresses: [SignalAddress]) -> EncryptionResult<Martin.Message, SignalError> {
        nonisolated(unsafe) var encoded: EncryptionResult<Martin.Message, SignalError> = .failure(.unknown)
        encodeLock.withLock {
            guard !isRetired else { return }
            let kept = store.batchingSessions(for: addresses) {
                // `addresses` has our own devices already; MartinOMEMO would add the inactive ones too.
                // The store hint is the one `_encode` puts on every message it encrypts.
                module.encode(message: stanza, forAddresses: addresses, withStoreHint: false, forSelf: false) { encoded = $0 }
            }
            if !kept { encoded = .failure(.unknown) }
        }
        return encoded
    }

    private func encode(_ stanza: Martin.Message, for addresses: [SignalAddress], verified: Bool, checking recipients: [JID]) -> Result<(Martin.Message, OMEMODevice.Trust), EncryptError> {
        guard case .successMessage(let message, _) = encodeKeepingSessions(stanza, for: addresses) else { return .failure(.setupFailed(recipients.first ?? account)) }

        // MartinOMEMO drops devices it fails to encrypt for; make sure every
        // recipient can read it at all.
        let keys = Set(Self.keyRids(in: message))
        for recipient in recipients {
            let devices = addresses.filter { $0.name == recipient.description }.map { $0.deviceId.omemoId }
            guard devices.contains(where: keys.contains) else { return .failure(.setupFailed(recipient)) }
        }
        return .success((message, verified ? .verified : .trusted))
    }
}

/// Resumes a continuation once, from whichever of an answer and a timeout comes first.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let taken = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
