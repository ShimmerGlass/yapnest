import Foundation
import Testing
@testable import Martin

/// A request that goes unanswered is failed by Martin's timer, which fires on
/// the main thread. Its callback reads the database (a group join asks for the
/// last message's date), and the debug build traps on such a read there.
@Suite struct ResponseTimeoutTests {
    private func request() -> Iq {
        let iq = Iq()
        iq.type = .get
        iq.to = JID("room@conference.example.org")
        return iq
    }

    @Test func aTimedOutRequestFailsOffTheMainThread() async throws {
        nonisolated(unsafe) let manager = ResponseManager()
        let iq = request()
        let onMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = manager.registerResponseHandler(for: iq, timeout: 0, errorDecoder: XMPPError.from(stanza:)) { (_: Result<Iq, XMPPError>) in
                continuation.resume(returning: Thread.isMainThread)
            }
            DispatchQueue.main.async { manager.checkTimeouts() }
        }
        #expect(!onMain)
    }

    /// The callbacks run outside the manager's lock: one that cancels or
    /// registers a request mustn't wait on it.
    @Test func aTimeoutCallbackCanSendAnotherRequest() async throws {
        nonisolated(unsafe) let manager = ResponseManager()
        let first = request()
        let second = request()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = manager.registerResponseHandler(for: first, timeout: 0, errorDecoder: XMPPError.from(stanza:)) { (_: Result<Iq, XMPPError>) in
                manager.registerResponseHandler(for: second, timeout: 30, errorDecoder: XMPPError.from(stanza:)) { (_: Result<Iq, XMPPError>) in }.cancel()
                continuation.resume()
            }
            DispatchQueue.main.async { manager.checkTimeouts() }
        }
    }
}
