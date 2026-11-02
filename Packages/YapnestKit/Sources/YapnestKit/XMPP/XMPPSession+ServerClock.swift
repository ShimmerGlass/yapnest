import Foundation
@preconcurrency import Martin

/// How far this device's clock is from the server's. Synced settings that
/// hold a time cross between devices in the server's clock, so devices whose
/// own clocks differ still agree (see `AppDatabase.serverClockOffset`).
extension XMPPSession {
    static let entityTimeNamespace = "urn:xmpp:time"
    static let entityTimeTimeout: TimeInterval = 10

    /// Asks the server for its time, once per connection, ahead of the
    /// settings sync, which waits for the answer. Not retried or shown if it
    /// fails: it is an estimate, and a server that doesn't answer leaves the
    /// offset as it was (none, until one is recorded).
    func estimateServerClock() {
        guard policy.syncsAccountState else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let sent = Date()
            let iq = Self.entityTimeRequest(to: account.domain)
            guard let reply = try? await client.context.writer.write(iq: iq, timeout: Self.entityTimeTimeout) else { return }
            let received = Date()
            guard let server = Self.entityTime(in: reply) else { return }
            noteClockOffset(Self.offset(server: server, sent: sent, received: received))
        }
        lock.withLock { $0.clockEstimate = task }
    }

    static func entityTimeRequest(to domain: String) -> Iq {
        Iq.make(.get, to: Martin.JID(domain), Element(name: "time", xmlns: entityTimeNamespace))
    }

    /// The server's time in an Entity Time answer.
    static func entityTime(in reply: Iq) -> Date? {
        guard let utc = reply.firstChild(name: "time", xmlns: entityTimeNamespace)?.firstChild(name: "utc")?.value else { return nil }
        return UploadSlotParser.date(from: utc)
    }

    /// How far the server's clock is ahead of ours, as last recorded; zero
    /// until one is. Read from the database once and kept, as every inbound
    /// stanza asks.
    var serverClockOffset: TimeInterval {
        if let cached = lock.withLock({ $0.clockOffset }) { return cached }
        let stored = (try? database.serverClockOffset()) ?? 0
        return lock.withLock { $0.clockOffset ?? stored }
    }

    /// A stored message time as the server's clock reads it, for anything
    /// that asks the server about a time (an archive query's bounds, a
    /// room's history). Stored times are this device's clock.
    func serverTime(of local: Date) -> Date { AppDatabase.wireTime(local, offset: serverClockOffset) }

    /// The server's clock less ours, taking the server to have read its clock
    /// halfway through the round trip.
    static func offset(server: Date, sent: Date, received: Date) -> TimeInterval {
        server.timeIntervalSince(sent.addingTimeInterval(received.timeIntervalSince(sent) / 2))
    }

    func noteClockOffset(_ offset: TimeInterval) {
        do {
            try database.noteServerClockOffset(offset)
        } catch {
            logger.error("Failed to record the server clock offset: \(error)")
            return
        }
        // The database keeps the old estimate when the new one is within a
        // second of it, so the cache follows what it holds.
        let stored = (try? database.serverClockOffset()) ?? offset
        lock.withLock { $0.clockOffset = stored }
    }
}
