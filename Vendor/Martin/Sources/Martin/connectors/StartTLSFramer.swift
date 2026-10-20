//
// StartTLSFramer.swift
//
// Not part of upstream Martin. See Vendor/README.md.
//

import Foundation
import Network

/// What a connection and its STARTTLS framer share: what the framer needs to
/// know, and why it gave up.
final class StartTLSContext: @unchecked Sendable {

    let domain: String
    private let lock = NSLock()
    private var _failure: StartTLSPreamble.Failure?

    init(domain: String) {
        self.domain = domain
    }

    /// Why the framer failed the connection, if it did.
    var failure: StartTLSPreamble.Failure? {
        lock.lock()
        defer { lock.unlock() }
        return _failure
    }

    fileprivate func fail(_ failure: StartTLSPreamble.Failure) {
        lock.lock()
        _failure = _failure ?? failure
        lock.unlock()
    }
}

/// A protocol layer that sits between TCP and TLS and does the STARTTLS
/// exchange in the clear, so that Network.framework's own TLS can take over
/// the same connection afterwards.
///
/// Its start handler returns `.willMarkReady`, which keeps the layers above
/// (TLS) from starting. Once the server has said `<proceed/>` it marks itself
/// ready and passes everything through, and TLS handshakes on the socket as
/// if it had been a direct TLS connection. It never lets the pre-TLS stream
/// reach the XMPP code: the stream is opened afresh over TLS, as RFC 6120
/// requires after STARTTLS.
@available(macOS 12.3, iOS 15.4, macCatalyst 15.4, *)
final class StartTLSFramer: NWProtocolFramerImplementation {

    static let label = "XMPP STARTTLS"
    static let definition = NWProtocolFramer.Definition(implementation: StartTLSFramer.self)
    private static let contextKey = "context"

    /// Options for a connection: the framer needs the domain, and reports its
    /// failure through `context`.
    static func options(context: StartTLSContext) -> NWProtocolFramer.Options {
        let options = NWProtocolFramer.Options(definition: definition)
        options[contextKey] = context
        return options
    }

    private let context: StartTLSContext?
    private var preamble = StartTLSPreamble()

    required init(framer: NWProtocolFramer.Instance) {
        context = framer.options[Self.contextKey] as? StartTLSContext
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let context else {
            framer.markFailed(error: .posix(.EINVAL))
            return .willMarkReady
        }
        framer.writeOutput(data: StartTLSPreamble.streamHeader(to: context.domain))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var step = StartTLSPreamble.Step.needMore
        while true {
            var ended = false, consumed = false
            let parsed = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { buffer, isComplete in
                guard let buffer, !buffer.isEmpty else {
                    ended = isComplete
                    return 0
                }
                consumed = true
                step = preamble.receive(Data(buffer))
                return buffer.count
            }
            if ended { step = preamble.receiveEnd() }
            if !consumed && !ended { return 0 }
            switch step {
            case .needMore:
                guard parsed else { return 0 }
            case .sendStartTLS:
                framer.writeOutput(data: StartTLSPreamble.request)
                step = .needMore
                guard parsed else { return 0 }
            case .proceed:
                // Anything above this layer sees the connection from here
                // as the server's TLS side.
                framer.passThroughOutput()
                framer.passThroughInput()
                framer.markReady()
                return 0
            case .fail(let failure):
                context?.fail(failure)
                framer.markFailed(error: .posix(.ECONNABORTED))
                return 0
            }
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

    func cleanup(framer: NWProtocolFramer.Instance) {}
}
