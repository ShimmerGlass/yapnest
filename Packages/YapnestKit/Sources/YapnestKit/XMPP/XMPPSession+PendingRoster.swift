import Foundation
@preconcurrency import Martin

/// Roster changes and answers to contact requests are kept until the server
/// confirms them, so they can be made offline. The contact is untouched
/// meanwhile (`Contact.pendingRoster`), apart from a rename's name.
extension XMPPSession {
    func queueRosterChange(_ jid: JID, kind: PendingRosterKind, name: String? = nil) throws {
        try rosterQueueLock.withLock {
            // A change being sent can't be replaced before the server has it.
            let sending = lock.withLock { $0.rosterInFlight }
            try database.queueRosterChange(jid, kind: kind, name: name, inFlight: sending)
        }
        sendPendingRosterChanges()
    }

    /// Sends the queued changes in the order they were made, once connected
    /// and the roster has been read. A passing error leaves the rest for the
    /// next connect, and a refusal for good drops the change and tells the
    /// user. Only the app sends.
    func sendPendingRosterChanges() {
        guard policy.resendsPending else { return }
        coalesced(\.rosterRun) { await $0.sendQueuedRosterChanges() }
    }

    private func sendQueuedRosterChanges() async {
        await drainQueue(
            queueLock: rosterQueueLock,
            ready: { !lock.withLock { $0.awaitsRoster } },
            // Stored changes always have an id.
            next: { try database.nextPendingRosterChange().flatMap { $0.id == nil ? nil : $0 } },
            afterChosen: { afterRosterChangeChosenForTesting?() },
            // Marked as in flight in the step that chose it, so that a later
            // change can't replace it after that.
            markInFlight: { change in lock.withLock { $0.rosterInFlight = change?.id } },
            deliver: { change in
                guard let id = change.id else { return }
                try await send(change)
                try database.removePendingRosterChange(id: id)
                warnings.clear("roster/\(change.jid)")
            },
            isRefusal: { $0 is ContactError || ServerError.isFinalRefusal($0) },
            refuse: { change in
                do {
                    guard let id = change.id else { return .stop }
                    try database.removePendingRosterChange(id: id)
                    return .warn
                } catch {
                    logger.error("Failed to drop a roster change the server refused: \(error)")
                    return .stop
                }
            },
            warn: { postRosterWarning($0, error: $1) },
            logFailure: { _, error in
                logger.info("Couldn't send a roster change: \(error.localizedDescription, privacy: .private)")
            },
        )
    }

    private func send(_ change: PendingRosterChange) async throws {
        let jid = change.jid
        let target = Martin.JID(jid.martin)
        let contact = try database.contact(jid)
        switch change.kind {
        case .accept:
            // Answered on another device, or withdrawn, meanwhile.
            guard contact?.hasContactRequest == true else { return }
            try await acceptNow(jid)
        case .decline:
            guard contact?.hasContactRequest == true else { return }
            try await client.module(.presence).unsubscribed(by: target)
            try database.clearContactRequest(from: jid)
        case .remove:
            // Already off the roster, such as removed on another device.
            guard contact?.isInRoster != false else { return }
            // Removing the item should withdraw our request too (RFC 6121),
            // but ejabberd keeps it, and they'd still be asked.
            if contact?.isSubscriptionPending == true {
                try await client.module(.presence).unsubscribe(from: target)
            }
            _ = try await retryingPassingErrors { try await client.module(.roster).removeItem(jid: target) }
            // The server's push says the same; this is for the UI, right away.
            try database.removeRosterItem(jid: jid)
        case .rename:
            guard let contact, contact.isInRoster else { throw ContactError.notInRoster }
            // A roster set replaces the item's name and groups, so the groups are
            // the current ones. Its subscription is left out, which keeps it.
            _ = try await retryingPassingErrors { try await client.module(.roster).updateItem(jid: target, name: change.name, groups: contact.rosterGroups) }
        }
    }

    private func postRosterWarning(_ change: PendingRosterChange, error: Error) {
        let (jid, kind, name) = (change.jid, change.kind, change.name)
        let title: String
        let friendly: String
        switch kind {
        case .accept:
            title = String(localized: "Couldn't accept the request")
            friendly = String(localized: "The server wouldn't add \(jid.description) to your contacts")
        case .decline:
            title = String(localized: "Couldn't decline the request")
            friendly = String(localized: "The server wouldn't decline the request from \(jid.description)")
        case .remove:
            title = String(localized: "Couldn't remove the contact")
            friendly = String(localized: "The server wouldn't remove \(jid.description) from your contacts")
        case .rename:
            title = String(localized: "Couldn't save the nickname")
            friendly = String(localized: "The server wouldn't save the nickname for \(jid.description)")
        }
        var retry: (@Sendable () async throws -> Void)?
        if !(error is ContactError) {
            retry = { [weak self] in
                guard let self else { return }
                switch kind {
                case .accept: try await acceptContactRequest(from: jid)
                case .decline: try declineContactRequest(from: jid)
                case .remove: try await removeContact(jid)
                case .rename: try await setContactName(jid, name: name)
                }
                warnings.clear("roster/\(jid)")
            }
        }
        warnings.post("roster/\(jid)", title: title, friendly: friendly, error: error, retry: retry)
    }
}
