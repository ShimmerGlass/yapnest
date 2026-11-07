import Dispatch
import Foundation
@preconcurrency @testable import Martin
import Testing
@testable import YapnestKit

struct FakeWireTests {
    /// Several requests are written at once when a session asks for the lists together. One that is
    /// still being answered when the test stops holding and releases must be delivered, not kept.
    @Test func aRequestInFlightWhenRepliesAreReleasedIsNotHeldAfterwards() async throws {
        let wire = FakeWire()
        let inFlight = Locked(false)
        let proceed = DispatchSemaphore(value: 0)
        let delivered = Locked(false)
        wire.answer { iq in
            if iq.id == "slow" {
                inFlight.value = true
                proceed.wait()
            }
            return FakeWire.result(to: iq)
        }
        wire.holdReplies { _ in true }

        let slow = Iq()
        slow.id = "slow"
        slow.type = .get
        let writer = Thread { wire.write(slow, timeout: 5, errorDecoder: { _ in XMPPError.undefined_condition }) { (_: Result<Iq, XMPPError>) in delivered.value = true } }
        writer.start()
        #expect(await eventually(timeout: 5) { inFlight.value })

        wire.holdReplies(to: nil)
        wire.releasePings()
        proceed.signal()

        #expect(await eventually(timeout: 5) { delivered.value })
    }
}
