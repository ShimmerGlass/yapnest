import Foundation
@preconcurrency import Martin

/// XEP-0191 blocking, with XEP-0377 reports to the server's operators.
extension XMPPSession {
    public enum ReportReason: Sendable {
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

    /// Whether the server can block people for us.
    public var canBlock: Bool {
        isConnected && client.module(.blockingCommand).isAvailable
    }

    /// Whether the server takes reports along with blocks.
    public var canReport: Bool {
        isConnected && client.module(.blockingCommand).isReportingSupported
    }

    /// Stops everything from `jid` reaching any of our devices, and with a
    /// reason, reports them to our server's operators along with the last
    /// messages they sent us.
    public func block(_ jid: JID, reporting reason: ReportReason? = nil) async throws {
        guard canBlock else { throw BlockingError.unavailable }
        let module = client.module(.blockingCommand)
        let report = reason.flatMap { reason in
            canReport ? BlockingCommandModule.Report(cause: reason.cause, stanzas: reportedMessages(from: jid)) : nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            module.block(jid: Martin.JID(jid.martin), report: report) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
        // The server's push says the same; this is for the UI, right away.
        try database.setBlocked(true, jid)
        // Otherwise the server keeps their request, and repeats it once
        // they're unblocked.
        if (try? database.contact(jid))??.subscriptionRequestedAt != nil {
            try? declineContactRequest(from: jid)
        }
    }

    public func unblock(_ jid: JID) async throws {
        guard canBlock else { throw BlockingError.unavailable }
        try await client.module(.blockingCommand).unblock(jids: [Martin.JID(jid.martin)])
        try database.setBlocked(false, jid)
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
