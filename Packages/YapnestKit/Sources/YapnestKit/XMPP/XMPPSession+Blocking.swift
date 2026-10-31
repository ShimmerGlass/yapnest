import Foundation
@preconcurrency import Martin

/// XEP-0191 blocking, with XEP-0377 reports to the server's operators.
extension XMPPSession {
    public enum ReportReason: String, Codable, Sendable {
        /// Unwanted messages.
        case spam
        /// Harassment and other abuse.
        case abuse

        var cause: BlockingCommandModule.Cause {
            switch self {
            case .spam: .spam
            case .abuse: .abuse
            }
        }
    }

    public enum BlockingError: Error, LocalizedError {
        case unavailable

        public var errorDescription: String? {
            String(localized: "Your server doesn't support blocking.")
        }
    }

    /// Whether the server offers blocking, once a discovery has said so;
    /// nil before that, such as offline since the app started.
    private var serverBlocks: Bool? {
        let features = client.module(.disco).serverDiscoResult.features
        return features.isEmpty ? nil : features.contains(BlockingCommandModule.BC_XMLNS)
    }

    /// Whether the Block action is offered: unless the server has said it
    /// can't. Offline, a change is kept and sent once connected.
    public var canBlock: Bool {
        serverBlocks ?? true
    }

    /// Whether the server takes reports along with blocks, as last known.
    public var canReport: Bool {
        client.module(.disco).serverDiscoResult.features.contains(BlockingCommandModule.REPORTING_XMLNS)
    }

    /// Stops everything from `jid` reaching any of our devices, and with a
    /// reason, reports them to our server's operators along with the last
    /// messages they sent us. The change is applied here at once and kept
    /// until the server confirms it, so it is made offline too; a server that
    /// refuses it for good puts the person back and shows a warning.
    public func block(_ jid: JID, reporting reason: ReportReason? = nil) async throws {
        guard canBlock else { throw BlockingError.unavailable }
        let declines = (try? database.contact(jid))??.subscriptionRequestedAt != nil
        try queueBlock(jid, blocked: true, reason: reason, declinesRequest: declines)
    }

    public func unblock(_ jid: JID) async throws {
        guard canBlock else { throw BlockingError.unavailable }
        try queueBlock(jid, blocked: false, reason: nil, declinesRequest: false)
    }

    private func queueBlock(_ jid: JID, blocked: Bool, reason: ReportReason?, declinesRequest: Bool) throws {
        let queued = try blockQueueLock.withLock {
            // A change being sent can't be taken back before the server has it.
            let sending = lock.withLock { $0.blockInFlight == jid }
            return try database.queueBlockChange(
                jid, blocked: blocked, reason: reason, declinesRequest: declinesRequest, canCancel: !sending,
            )
        }
        if queued { sendPendingBlocks() }
    }

    /// Sends the queued blocks and unblocks in the order they were made, once
    /// connected. A passing error leaves the rest for the next connect, and a
    /// refusal for good puts the person back and tells the user. Only the
    /// app sends.
    func sendPendingBlocks() {
        guard policy.resendsPending else { return }
        coalesced(\.blockRun) { await $0.sendQueuedBlocks() }
    }

    /// The oldest queued change, marked as in flight in the same step so that
    /// an undo can't cancel it after it was chosen.
    private func claimNextBlockChange() throws -> PendingBlockChange? {
        try blockQueueLock.withLock {
            let change = try database.nextPendingBlockChange()
            afterBlockChangeChosenForTesting?()
            lock.withLock { $0.blockInFlight = change?.jid }
            return change
        }
    }

    private func sendQueuedBlocks() async {
        while isConnected {
            let change: PendingBlockChange?
            do {
                change = try claimNextBlockChange()
            } catch {
                logger.error("Failed to read the queued blocks: \(error)")
                return
            }
            defer { lock.withLock { $0.blockInFlight = nil } }
            guard let change, let id = change.id else { return }
            do {
                if serverBlocks == false { throw BlockingError.unavailable }
                try await send(change)
                try database.removePendingBlockChange(id: id)
                // The decline went out with the block, and the server's push may not say so yet.
                if change.declinesRequest {
                    do {
                        try database.clearContactRequest(from: change.jid)
                    } catch {
                        logger.error("Failed to clear the declined contact request: \(error)")
                    }
                }
                warnings.clear("blocking/\(change.jid)")
            } catch {
                logger.info("Couldn't \(change.blocked ? "block" : "unblock", privacy: .public): \(error.localizedDescription, privacy: .private)")
                let refused = error is BlockingError || ServerError.isFinalRefusal(error)
                // Whatever passes by itself stays queued for the next connect.
                guard refused else { return }
                do {
                    let dropped = try database.dropPendingBlockChange(change, serverBlocked: client.module(.blockingCommand).blockedJids?.contains(Martin.JID(change.jid.martin)))
                    // A change the user has since replaced isn't theirs to retry.
                    guard dropped else { continue }
                } catch {
                    logger.error("Failed to put back a block the server refused: \(error)")
                }
                postBlockWarning(change, error: error)
            }
        }
    }

    private func send(_ change: PendingBlockChange) async throws {
        let module = client.module(.blockingCommand)
        let target = Martin.JID(change.jid.martin)
        if !change.blocked {
            try await retryingPassingErrors(callback: { done in module.unblock(jid: target) { done($0.mapError { $0 }) } })
            return
        }
        let report = change.reason.flatMap { reason in
            canReport ? BlockingCommandModule.Report(cause: reason.cause, stanzas: reportedMessages(from: change.jid)) : nil
        }
        // Before the block: once it is in place our server bounces what we
        // send them (XEP-0191), the decline with it, and their request would
        // be kept and repeated on unblocking. The stream keeps the order.
        if change.declinesRequest { try await client.module(.presence).unsubscribed(by: target) }
        try await retryingPassingErrors(callback: { done in module.block(jid: target, report: report) { done($0.mapError { $0 }) } })
    }

    private func postBlockWarning(_ change: PendingBlockChange, error: Error) {
        let (jid, blocked) = (change.jid, change.blocked)
        let reason = change.reason
        let title = blocked ? String(localized: "Couldn't block") : String(localized: "Couldn't unblock")
        let friendly = blocked ? String(localized: "The server wouldn't block them") : String(localized: "The server wouldn't unblock them")
        var retry: (@Sendable () async throws -> Void)?
        if !(error is BlockingError) {
            retry = { [weak self] in
                guard let self else { return }
                if blocked { try await block(jid, reporting: reason) } else { try await unblock(jid) }
                warnings.clear("blocking/\(jid)")
            }
        }
        warnings.post("blocking/\(jid)", title: title, friendly: friendly, error: error, retry: retry)
    }

    /// The server's ids for what `jid` last sent us, so its operators can
    /// look at them. Only 1:1 messages: our server numbers those.
    private func reportedMessages(from jid: JID) -> [BlockingCommandModule.Report.ReportedStanza] {
        let ids = (try? database.lastServerIds(from: jid, limit: 10)) ?? []
        return ids.map { .init(id: $0, by: Martin.JID(account.martin)) }
    }

    func blocklistChanged(_ jids: [Martin.JID]?) {
        guard let jids else { return }
        do {
            try database.setBlocklist(Set(jids.compactMap { JID($0) }))
        } catch {
            logger.error("Failed to store the blocklist: \(error)")
        }
    }
}
