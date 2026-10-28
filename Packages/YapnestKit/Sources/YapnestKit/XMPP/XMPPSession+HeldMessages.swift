import Foundation
@preconcurrency import Martin
@preconcurrency import MartinOMEMO

/// Encrypted group messages from devices we had never seen. A room names
/// each message's sender, and could name any member for a device of its
/// own, so such a message waits as undecryptable until the member's own
/// server lists the device and publishes the key it carries.
extension XMPPSession {
    /// A message waiting on its device, kept until it's known what it is.
    struct HeldStanza {
        let sender: JID
        let device: Int32
        let stanza: String
        let source: InboundMessage.Source
        let isHistory: Bool
    }

    /// What storing a group message means for holds: one to keep for its
    /// placeholder, or one its decrypted copy takes the place of.
    func storedEncrypted(_ inbound: InboundMessage, _ result: IngestResult, held: HeldStanza?, isPrivate: Bool) {
        if let held { keep(held, for: result) }
        replaceHeldCopy(of: inbound, result, isPrivate: isPrivate)
    }

    /// Keeps `held` beside the placeholder stored for it, then looks into its
    /// device, in the app. The extensions only store: the check is a round
    /// trip to another server, and the app picks it up on connecting.
    private func keep(_ held: HeldStanza, for result: IngestResult) {
        guard let messageId = result.newMessage?.id else { return }
        do {
            try database.hold(
                messageId: messageId, sender: held.sender, deviceId: held.device, stanza: held.stanza,
                source: held.source, isHistory: held.isHistory,
            )
        } catch {
            DiagLog.error(.omemo, "Held message not kept", .error(error))
            return
        }
        resolveHeldGroupMessages()
    }

    /// Checks the devices that held messages wait on, in one run however many
    /// ask for it meanwhile.
    func resolveHeldGroupMessages() {
        guard mode == .app else { return }
        let start = lock.withLock { state in
            defer { state.heldRun = state.heldRun == .idle ? .running : .runAgain }
            return state.heldRun == .idle
        }
        guard start else { return }
        Task.detached(priority: .utility) { [weak self] in
            while let self {
                await self.resolveHeld()
                let again = self.lock.withLock { state in
                    defer { state.heldRun = state.heldRun == .runAgain ? .running : .idle }
                    return state.heldRun == .runAgain
                }
                guard again else { return }
            }
        }
    }

    /// How long a hold whose sender's server doesn't answer is kept trying.
    /// A room naming members on servers that never answer would otherwise
    /// cost every run a timeout for each of them, for good.
    static let heldMessageLifetime: TimeInterval = 3 * 24 * 60 * 60

    private func resolveHeld() async {
        guard let held = try? database.heldGroupMessages(), !held.isEmpty else { return }
        // Each sender's server on its own, so one that's slow to answer holds
        // up only its own member's messages.
        await withTaskGroup(of: Void.self) { group in
            for sender in Self.firstSeen(held.map(\.sender)) {
                let theirs = held.filter { $0.sender == sender }
                group.addTask { [self] in await resolveHeld(theirs, of: sender) }
            }
        }
    }

    // Where a final error ends a hold, the message stays a placeholder that
    // says it couldn't be decrypted, which is all the user can act on: the
    // error is about another account's keys, on their server.
    private func resolveHeld(_ theirs: [HeldGroupMessage], of sender: JID) async {
        guard isConnected else { return }
        let devices = Self.firstSeen(theirs.map(\.deviceId))
        // One read of their list for however many devices the room names.
        switch await omemo.readDeviceList(of: sender) {
        case .failure(let error):
            switch error.error.errorCondition {
            case .not_authorized, .forbidden:
                // Their server keeps the list from all but their contacts:
                // read on the room's word, from a device left undecided.
                release(theirs, decryptingWith: .roomUnchecked)
            default:
                if ServerError(error).isFinal { release(theirs, decryptingWith: nil) } else { expire(theirs) }
            }
        case .success(let listed):
            for device in devices {
                // In the order they were held, which for what arrives live is
                // the order they were sent.
                let messages = theirs.filter { $0.deviceId == device }
                // A device they've taken off their list stays refused, even
                // with its bundle left behind: that's how a lost one is revoked.
                guard listed.contains(device) else {
                    DiagLog.notice(.omemo, "Group message from a device its sender doesn't list", .id("device", Redacted.id(String(device))))
                    release(messages, decryptingWith: nil)
                    continue
                }
                guard isConnected else { return }
                switch await omemo.readIdentityKey(of: device, of: sender) {
                case .published(let key):
                    // Without a key kept, the message would be read on the
                    // room's word; it waits for the next run instead.
                    guard omemo.vouch(for: device, of: sender, identityKey: key) else {
                        expire(messages)
                        continue
                    }
                    release(messages, decryptingWith: .room)
                case .unusable:
                    release(messages, decryptingWith: nil)
                case .unavailable(let error):
                    if ServerError(error).isFinal { release(messages, decryptingWith: nil) } else { expire(messages) }
                }
            }
        }
    }

    /// `values` without repeats, in the order they first came.
    private static func firstSeen<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Gives up on the holds that have waited past `heldMessageLifetime`.
    private func expire(_ messages: [HeldGroupMessage]) {
        for held in messages where Date().timeIntervalSince(held.heldAt) > Self.heldMessageLifetime {
            try? database.release(held)
        }
    }

    /// A held message arriving again decrypted, as its archive copy can once
    /// the device is vouched for, would otherwise be dropped as a copy of
    /// its placeholder, and the held one then read as already decoded.
    private func replaceHeldCopy(of inbound: InboundMessage, _ result: IngestResult, isPrivate: Bool) {
        guard inbound.encryption == .omemo, result.newMessage == nil, let conversationId = result.conversationId,
              let held = try? database.hold(matching: inbound, in: conversationId) else { return }
        replace(held, with: inbound, isPrivate: isPrivate)
    }

    private func replace(_ held: HeldGroupMessage, with inbound: InboundMessage, isPrivate: Bool) {
        do {
            guard let result = try database.replace(held, with: inbound) else { return }
            if !held.isHistory { storedRoomMessage(inbound, result, isPrivate: isPrivate) }
        } catch {
            DiagLog.error(.omemo, "Held message not replaced", .error(error))
        }
    }

    /// Decrypts each of `messages` in place of its placeholder, or with no
    /// claim leaves the placeholders as they are. Either way they're no
    /// longer held.
    private func release(_ messages: [HeldGroupMessage], decryptingWith claim: OMEMOEncryption.SenderClaim?) {
        for held in messages {
            guard let claim, let (inbound, isPrivate) = decrypted(held, claim: claim) else {
                try? database.release(held)
                continue
            }
            replace(held, with: inbound, isPrivate: isPrivate)
        }
    }

    /// The message, and whether its group is private.
    private func decrypted(_ held: HeldGroupMessage, claim: OMEMOEncryption.SenderClaim) -> (InboundMessage, Bool)? {
        guard let element = Element.from(string: held.stanza), let stanza = Stanza.from(element: element) as? Martin.Message,
              let room = stanza.from.flatMap({ JID($0) }), let nick = stanza.from?.resource,
              let group = try? database.groupChat(room) else { return nil }
        let result = omemo.decrypt(
            stanza, from: held.sender, ownCopy: held.sender == account, isHistory: held.isHistory,
            sentAt: held.source.archivedAt ?? held.heldAt, claim: claim,
        )
        guard case .decrypted(let device, let trust) = result else { return nil }
        let status = roomStatus(room)
        // The sender is whom the room named when the message came, who may
        // have left since.
        let context = RoomContext(
            jid: room, nickname: status?.nickname ?? group.nickname, occupants: [nick: held.sender],
            trustsOccupantIds: group.hasOccupantIds, ownOccupantId: status?.occupantId, isNonAnonymous: group.isNonAnonymous,
        )
        guard var inbound = InboundMessage(groupchat: stanza, room: context, account: account, source: held.source, encryption: .omemo) else { return nil }
        inbound.omemoDevice = device
        inbound.omemoTrust = trust
        inbound.isHistory = held.isHistory
        return (inbound, group.isPrivate)
    }
}
