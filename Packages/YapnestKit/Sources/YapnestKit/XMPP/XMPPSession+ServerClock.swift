import Foundation
@preconcurrency import Martin

/// What a session's estimate of the server's clock rests on.
enum ClockState: Sendable, Equatable {
    /// The highest archive stamp less its arrival seen so far: a floor, as a
    /// message is archived some time before it reaches us.
    case archive(best: TimeInterval)
    /// The server's own answer to a time request (XEP-0202).
    case entityTime
}

/// How far this device's clock is from the server's. Synced settings that
/// hold a time cross between devices in the server's clock, so devices whose
/// own clocks differ still agree (see `AppDatabase.serverClockOffset`).
extension XMPPSession {
    static let entityTimeNamespace = "urn:xmpp:time"
    static let entityTimeTimeout: TimeInterval = 10
    /// An archive stamp older than this at arrival says more about how late
    /// the message came than about the clocks, so it isn't used.
    static let archiveStampMaxAge: TimeInterval = 600

    /// Asks the server for its time, once per connection, ahead of the
    /// settings sync, which waits for the answer. Not retried or shown if it
    /// fails: it is an estimate, and a server that doesn't answer leaves the
    /// archive stamps (or no offset, as before) to go by.
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
    /// until one is.
    var serverClockOffset: TimeInterval { (try? database.serverClockOffset()) ?? 0 }

    /// A stored message time as the server's clock reads it, for anything
    /// that asks the server about a time (an archive query's bounds, a
    /// room's history). Stored times are this device's clock.
    func serverTime(of local: Date) -> Date { local.addingTimeInterval(serverClockOffset) }

    /// The server's clock less ours, taking the server to have read its clock
    /// halfway through the round trip.
    static func offset(server: Date, sent: Date, received: Date) -> TimeInterval {
        server.timeIntervalSince(sent.addingTimeInterval(received.timeIntervalSince(sent) / 2))
    }

    /// A message the archive stamps as it arrives live was stored a moment
    /// before, so the stamp less our arrival time is close to the offset, and
    /// never above it. The highest seen is the best bound; a stamp from a
    /// message that waited long is ignored. Not used once the server has told
    /// us its time.
    func noteArchiveStamp(_ stamp: Date, arrivedAt arrival: Date) {
        guard policy.syncsAccountState else { return }
        let candidate = stamp.timeIntervalSince(arrival)
        guard candidate > -Self.archiveStampMaxAge else { return }
        let shouldRecord = lock.withLock { state -> Bool in
            switch state.clock {
            case .entityTime: return false
            case .archive(let best) where candidate <= best: return false
            case .archive, nil: break
            }
            state.clock = .archive(best: candidate)
            // An estimate is only good to a second, and each record is a write.
            if let recorded = state.recordedClockOffset, abs(candidate - recorded) < 1 { return false }
            state.recordedClockOffset = candidate
            return true
        }
        if shouldRecord { record(candidate) }
    }

    func noteClockOffset(_ offset: TimeInterval) {
        lock.withLock {
            $0.clock = .entityTime
            $0.recordedClockOffset = offset
        }
        record(offset)
    }

    private func record(_ offset: TimeInterval) {
        do {
            try database.noteServerClockOffset(offset)
        } catch {
            logger.error("Failed to record the server clock offset: \(error)")
        }
    }
}
