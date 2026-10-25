import Foundation
import Martin

/// What reading a PEP node's items came to. A node that isn't there is an
/// empty one, and a server that doesn't offer the node has nothing to read,
/// but a failure is neither: concluding that nothing is there would delete
/// what we hold, or turn a timeout into "not supported".
enum NodeRead: @unchecked Sendable {
    case items(PubSubModule.RetrievedItems)
    /// The node isn't there (item-not-found).
    case noNode
    /// The server doesn't offer it (feature-not-implemented, service-unavailable).
    case unsupported
    case failed(ServerError)

    /// Whether there is nothing more to read: all of it was, or none can be.
    var isRead: Bool {
        if case .failed = self { false } else { true }
    }

    init(_ error: PubSubError) {
        let error = ServerError(error)
        // A `wait` answer to a request the server can't serve right now isn't a
        // server without the node.
        self = error.isNotFound ? .noNode : error.isUnsupported && error.isFinal ? .unsupported : .failed(error)
    }
}

extension XMPPSession {
    /// Reads `node` of our own account. A failure is logged here, once, as
    /// `what` unavailable; each caller says where the read is retried.
    func readNode(
        _ node: String, as what: StaticString, limit: PubSubModule.QueryLimit = .none,
        _ done: @escaping @Sendable (NodeRead) -> Void,
    ) {
        client.module(.pubsub).retrieveItems(from: account.martin, for: node, limit: limit) { [weak self] result in
            switch result {
            case .success(let items): done(.items(items))
            case .failure(let error):
                let read = NodeRead(error)
                if case .failed(let error) = read {
                    self?.logger.info("\(what.description, privacy: .public) unavailable: \(error.condition, privacy: .private)")
                }
                done(read)
            }
        }
    }

    func readNode(_ node: String, as what: StaticString, limit: PubSubModule.QueryLimit = .none) async -> NodeRead {
        await withCheckedContinuation { continuation in
            readNode(node, as: what, limit: limit) { continuation.resume(returning: $0) }
        }
    }
}
