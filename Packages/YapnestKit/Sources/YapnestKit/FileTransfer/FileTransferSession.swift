import CryptoKit
import Foundation
@preconcurrency import Martin

/// How long each wait of a Jingle file transfer may last.
struct FileTransferTimeouts: Sendable {
    /// The peer's answer to our offer.
    var accept: TimeInterval = 5 * 60
    /// Without a block, an acknowledgement or an open, while the stream is under way.
    var idle: TimeInterval = 60
    /// The receiver's word that it has the file, once all of it is sent.
    var confirmation: TimeInterval = 60
    /// How long an ended session keeps answering its peer's last stanzas.
    var linger: TimeInterval = 30
}

/// One file offer's live state, in memory only. Receiver:
/// `offered` -> `accepted` (session-accept sent, waiting for the open) ->
/// `receiving` -> `completed` | `failed`. Sender: `offering` (waiting for the
/// accept) -> `sending` -> `awaitingConfirmation` (everything sent, waiting
/// for the receiver's session-terminate) -> `completed` | `failed`.
///
/// Every method takes the session's lock and nothing here writes a stanza, so
/// a caller can act on what it returns outside the lock: a write may be
/// answered on the same stack.
final class FileTransferSession: @unchecked Sendable {
    enum Role: Sendable { case receiver, sender }

    enum Phase: Sendable, Equatable {
        case offered, accepted, receiving
        case offering, sending, awaitingConfirmation
        case completed, failed

        var isEnded: Bool { self == .completed || self == .failed }

        /// The moves a session makes. Anything else is a stanza out of turn.
        func canMove(to next: Phase) -> Bool {
            switch (self, next) {
            case (.offered, .accepted), (.accepted, .receiving), (.receiving, .completed),
                 (.offering, .sending), (.sending, .awaitingConfirmation), (.sending, .completed), (.awaitingConfirmation, .completed):
                true
            case (.completed, _), (.failed, _): false
            case (_, .failed): true
            default: false
            }
        }
    }

    let sid: String
    let messageId: Int64
    let role: Role
    /// The peer's full address, which every stanza of the session must come from.
    let peer: Martin.JID
    let offer: JingleFileOffer
    var size: Int64 { offer.size }
    var ibbSid: String { offer.ibbSid }

    private let lock = NSLock()
    private var phase: Phase
    private var blockSize: Int
    private var expectedHash: Data?
    private var timerGeneration = 0
    private var lastActivity = Date()
    private var throttle = ProgressThrottle()

    // Receiving.
    private var temporary: URL?
    private var output: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var nextSeq = 0

    // Sending.
    private var input: FileHandle?
    private var sentAll = false
    private var sentBytes: Int64 = 0
    private var acknowledged: Int64 = 0
    private var inFlight = 0
    private var closeSent = false
    private var outcome: Result<Void, FileTransferFailure>?
    private var waiter: CheckedContinuation<Void, Error>?

    init(sid: String, messageId: Int64, role: Role, peer: Martin.JID, offer: JingleFileOffer) {
        self.sid = sid
        self.messageId = messageId
        self.role = role
        self.peer = peer
        self.offer = offer
        self.blockSize = offer.blockSize
        self.expectedHash = offer.sha256
        self.phase = role == .receiver ? .offered : .offering
    }

    var currentPhase: Phase { lock.withLock { phase } }
    var negotiatedBlockSize: Int { lock.withLock { blockSize } }
    /// Whether every byte has been handed to the stream.
    var hasSentEverything: Bool { lock.withLock { sentAll } }

    /// Moves to `next` if the session is in one of `from`; false if it is not.
    @discardableResult
    func move(from allowed: Set<Phase>, to next: Phase) -> Bool {
        lock.withLock {
            guard allowed.contains(phase), phase.canMove(to: next) else { return false }
            phase = next
            return true
        }
    }

    /// Ends the session as failed unless it already ended. Returns the phase
    /// it was in for the caller that ended it, which is the one to clean up.
    func fail() -> Phase? {
        let previous = lock.withLock { () -> Phase? in
            guard !phase.isEnded else { return nil }
            defer { phase = .failed }
            return phase
        }
        if previous != nil { release() }
        return previous
    }

    /// Progress to publish, or nil while it hasn't moved enough to be worth
    /// redrawing for: a large file has a hundred thousand blocks.
    private func progress(_ bytes: Int64) -> Double? {
        guard size > 0 else { return nil }
        return throttle.admit(min(1, Double(bytes) / Double(size)))
    }

    // MARK: Timer

    /// Runs `expired` on `queue` once `limit` passes without `touch()` or
    /// another `watch`, or never if `disarm` comes first. Checking when the
    /// time is up, instead of rearming on every block, keeps a long transfer
    /// from queueing a timer for each of its hundred thousand blocks.
    func watch(_ limit: TimeInterval, on queue: DispatchQueue, _ expired: @escaping @Sendable () -> Void) {
        let generation = lock.withLock { () -> Int in
            timerGeneration += 1
            lastActivity = Date()
            return timerGeneration
        }
        schedule(after: limit, limit: limit, generation: generation, on: queue, expired)
    }

    private func schedule(after delay: TimeInterval, limit: TimeInterval, generation: Int, on queue: DispatchQueue, _ expired: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let remaining = lock.withLock { () -> TimeInterval? in
                guard timerGeneration == generation else { return nil }
                return limit - Date().timeIntervalSince(lastActivity)
            }
            guard let remaining else { return }
            if remaining <= 0.001 {
                expired()
            } else {
                schedule(after: remaining, limit: limit, generation: generation, on: queue, expired)
            }
        }
    }

    /// Something happened, so the wait starts over.
    func touch() {
        lock.withLock { lastActivity = Date() }
    }

    func disarm() {
        lock.withLock { timerGeneration += 1 }
    }

    // MARK: Hash

    func setExpectedHash(_ hash: Data) {
        lock.withLock { if expectedHash == nil { expectedHash = hash } }
    }

    // MARK: Receiving

    /// Opens the file the bytes are written to.
    func startReceiving(into file: URL, blockSize: Int) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        lock.withLock {
            temporary = file
            output = handle
            self.blockSize = blockSize
        }
    }

    /// The IBB stream was opened with `blockSize`; false if it asks for more
    /// than was agreed.
    func opened(blockSize requested: Int) -> Bool {
        lock.withLock {
            guard phase == .accepted, requested <= blockSize else { return false }
            phase = .receiving
            return true
        }
    }

    enum Received: Equatable {
        case accepted(progress: Double?, isComplete: Bool)
        /// A block out of order, too big, or past the end: the stream is broken.
        case broken
        /// Not receiving, so the block is for nobody.
        case unexpected
    }

    func append(seq: Int, _ data: Data) -> Received {
        lock.withLock {
            guard phase == .receiving, let output else { return .unexpected }
            guard seq == nextSeq, data.count <= blockSize, received + Int64(data.count) <= size else { return .broken }
            do {
                try output.write(contentsOf: data)
            } catch {
                return .broken
            }
            hasher.update(data: data)
            lastActivity = Date()
            received += Int64(data.count)
            nextSeq = (nextSeq + 1) & 0xFFFF
            return .accepted(progress: progress(received), isComplete: received == size)
        }
    }

    enum Finished {
        case file(URL, size: Int64)
        case mismatch
    }

    /// Closes the file and checks it: everything arrived, and its SHA-256
    /// matches if one is known. The file is left for the caller to move or delete.
    func finishReceiving() -> Finished {
        lock.withLock {
            try? output?.close()
            output = nil
            guard let temporary, received == size else { return .mismatch }
            if let expectedHash, Data(hasher.finalize()) != expectedHash { return .mismatch }
            return .file(temporary, size: received)
        }
    }

    /// Closes and removes what was written so far.
    func discardReceived() {
        let file = lock.withLock { () -> URL? in
            try? output?.close()
            output = nil
            defer { temporary = nil }
            return temporary
        }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Sending

    func startSending(from file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        lock.withLock { input = handle }
    }

    /// The block size the receiver accepted, which can only be lower.
    func negotiate(blockSize agreed: Int) {
        lock.withLock { blockSize = min(blockSize, agreed) }
    }

    enum Outgoing {
        case block(seq: Int, Data)
        /// Everything is sent and acknowledged: close the stream.
        case close
        case nothing
        case failed
    }

    /// The next block to send, if the window has room.
    func nextBlock(window: Int) -> Outgoing {
        lock.withLock {
            guard phase == .sending else { return .nothing }
            if !sentAll {
                guard inFlight < window else { return .nothing }
                let chunk: Data?
                do {
                    chunk = sentBytes < size ? try input?.read(upToCount: Int(min(Int64(blockSize), size - sentBytes))) : nil
                } catch {
                    return .failed
                }
                if let chunk, !chunk.isEmpty {
                    let seq = nextSeq
                    nextSeq = (nextSeq + 1) & 0xFFFF
                    sentBytes += Int64(chunk.count)
                    inFlight += 1
                    return .block(seq: seq, chunk)
                }
                // A file that ended early is not the file we offered.
                guard sentBytes == size else { return .failed }
                sentAll = true
            }
            if inFlight == 0, !closeSent {
                closeSent = true
                return .close
            }
            return .nothing
        }
    }

    /// A block of `count` bytes was acknowledged.
    func acknowledge(_ count: Int) -> Double? {
        lock.withLock {
            inFlight -= 1
            acknowledged += Int64(count)
            lastActivity = Date()
            return progress(acknowledged)
        }
    }

    // MARK: Outcome of a send

    /// Waits for the session to end. A sender's caller does this.
    func finished() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready = lock.withLock { () -> Result<Void, FileTransferFailure>? in
                if outcome == nil { waiter = continuation }
                return outcome
            }
            if let ready { continuation.resume(with: ready.mapError { $0 as Error }) }
        }
    }

    /// Reports how the send ended, once.
    func complete(_ result: Result<Void, FileTransferFailure>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result.mapError { $0 as Error })
    }

    /// Closes the file being sent, which a session that ended no longer needs.
    /// The one being received is closed by finishing or discarding it.
    func release() {
        lock.withLock {
            try? input?.close()
            input = nil
        }
    }
}

/// Why our own file transfer didn't end well, in words for the person who sent it.
struct FileTransferFailure: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    static var declined: Self { .init(message: String(localized: "Declined.")) }
    static var cancelled: Self { .init(message: String(localized: "The contact cancelled the transfer.")) }
    static var failed: Self { .init(message: String(localized: "The transfer failed.")) }
    static var noAnswer: Self { .init(message: String(localized: "No answer from the contact's device.")) }
    static var interrupted: Self { .init(message: String(localized: "The transfer was interrupted.")) }
    static var unconfirmed: Self { .init(message: String(localized: "The contact's device didn't confirm it got the file.")) }

    /// What the receiver's reason in a session-terminate says to the sender.
    static func from(_ reason: JingleSessionTerminateReason?) -> Self {
        switch reason {
        case .decline: .declined
        case .cancel: .cancelled
        case .timeout, .busy, .gone, .expired: .noAnswer
        default: .failed
        }
    }
}

/// The sessions of an account, by Jingle sid and by IBB sid.
final class FileTransfers: @unchecked Sendable {
    private let lock = NSLock()
    private var bySid: [String: FileTransferSession] = [:]
    private var byIBB: [String: String] = [:]

    var timeouts = FileTransferTimeouts()
    /// Where deferred work runs: timers and block pumping.
    let queue = DispatchQueue(label: "Yapnest.fileTransfer")

    func session(sid: String) -> FileTransferSession? { lock.withLock { bySid[sid] } }

    func session(ibb: String) -> FileTransferSession? {
        lock.withLock { byIBB[ibb].flatMap { bySid[$0] } }
    }

    func session(messageId: Int64) -> FileTransferSession? {
        lock.withLock { bySid.values.first { $0.messageId == messageId } }
    }

    var all: [FileTransferSession] { lock.withLock { Array(bySid.values) } }

    /// False if the sid is taken.
    func add(_ session: FileTransferSession) -> Bool {
        lock.withLock {
            guard bySid[session.sid] == nil else { return false }
            bySid[session.sid] = session
            return true
        }
    }

    /// Lets the IBB stream's stanzas find `session`.
    func routeIBB(to session: FileTransferSession) {
        lock.withLock { byIBB[session.ibbSid] = session.sid }
    }

    func remove(_ session: FileTransferSession) {
        lock.withLock {
            guard bySid[session.sid] === session else { return }
            bySid[session.sid] = nil
            byIBB[session.ibbSid] = nil
        }
    }
}
