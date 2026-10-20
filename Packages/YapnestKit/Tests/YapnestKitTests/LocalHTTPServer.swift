import Foundation
import Network
import os
@testable import YapnestKit

/// A throwaway HTTP/1.1 server on 127.0.0.1, so that the real
/// `NWFetchConnection` has something to talk to.
final class LocalHTTPServer: @unchecked Sendable {
    enum Reply: Sendable {
        /// Sends the pieces one by one, then closes the connection.
        case send([Data])
        /// Sends the pieces one by one and keeps the connection open.
        case sendAndHold([Data])
        /// Reads the request and never answers.
        case silent
        /// Sends the head, then body pieces until the client goes away.
        case endless(head: Data, piece: Data)
        case closeWithoutAnswer
    }

    struct State {
        var requests: [String] = []
        var accepted = 0
        var closedByClient = 0
        var bytesSent = 0
        var replies: [Reply] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "yapnest.test.server")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let closing = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())
    private(set) var port: UInt16 = 0

    init(replies: [Reply] = []) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        state.withLock { $0.replies = replies }

        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Result<UInt16, Error>) -> Void = { result in
                guard once.withLock({ was in defer { was = true }; return !was }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [listener] newState in
                switch newState {
                case .ready: resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): resume(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        port = ready
    }

    func stop() { listener.cancel() }

    func queue(_ reply: Reply) { state.withLock { $0.replies.append(reply) } }

    var requests: [String] { state.withLock { $0.requests } }
    var accepted: Int { state.withLock { $0.accepted } }
    var closedByClient: Int { state.withLock { $0.closedByClient } }
    var bytesSent: Int { state.withLock { $0.bytesSent } }

    static func response(_ status: Int, _ headers: [String: String] = [:], body: String = "", length: Bool = true) -> Data {
        var text = "HTTP/1.1 \(status) X\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if length { text += "Content-Length: \(body.utf8.count)\r\n" }
        return Data((text + "\r\n" + body).utf8)
    }

    private func accept(_ connection: NWConnection) {
        let reply = state.withLock { state -> Reply in
            state.accepted += 1
            return state.replies.isEmpty ? .silent : state.replies.removeFirst()
        }
        connection.start(queue: queue)
        readRequest(connection, received: Data(), reply: reply)
    }

    private func readRequest(_ connection: NWConnection, received: Data, reply: Reply) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            let text = String(decoding: received, as: UTF8.self)
            if text.contains("\r\n\r\n") {
                state.withLock { $0.requests.append(text) }
                respond(connection, reply)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                readRequest(connection, received: received, reply: reply)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ reply: Reply) {
        watchForClose(connection)
        switch reply {
        case .send(let pieces): sendAll(connection, pieces[...], thenClose: true)
        case .sendAndHold(let pieces): sendAll(connection, pieces[...], thenClose: false)
        case .silent: break
        case .closeWithoutAnswer: closeFromServer(connection)
        case .endless(let head, let piece):
            write(connection, head) { [weak self] ok in if ok { self?.pump(connection, piece) } }
        }
    }

    /// Closes with a FIN after the last bytes, rather than cancelling the
    /// connection. A cancel can reset it while the data is still in flight,
    /// which the client then sees as an error instead of the end of the body.
    private func closeFromServer(_ connection: NWConnection, after last: Data? = nil) {
        closing.withLock { _ = $0.insert(ObjectIdentifier(connection)) }
        connection.send(content: last, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            if let last { self?.state.withLock { $0.bytesSent += last.count } }
        })
    }

    private func sendAll(_ connection: NWConnection, _ pieces: ArraySlice<Data>, thenClose: Bool) {
        guard let first = pieces.first else {
            if thenClose { closeFromServer(connection) }
            return
        }
        if thenClose, pieces.count == 1 {
            closeFromServer(connection, after: first)
            return
        }
        write(connection, first) { [weak self] ok in
            if ok { self?.sendAll(connection, pieces.dropFirst(), thenClose: thenClose) }
        }
    }

    private func pump(_ connection: NWConnection, _ piece: Data) {
        write(connection, piece) { [weak self] ok in if ok { self?.pump(connection, piece) } }
    }

    private func write(_ connection: NWConnection, _ data: Data, then: @escaping @Sendable (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error == nil { self?.state.withLock { $0.bytesSent += data.count } }
            then(error == nil)
        })
    }

    /// The client closing shows up as end of stream or an error on our read.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                if let self, !closing.withLock({ $0.contains(ObjectIdentifier(connection)) }) {
                    state.withLock { $0.closedByClient += 1 }
                }
                connection.cancel()
            } else {
                self?.watchForClose(connection)
            }
        }
    }
}

/// Polls until `condition` holds, for things that settle on another queue.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
