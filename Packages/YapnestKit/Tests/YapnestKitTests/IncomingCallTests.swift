import Foundation
import Testing
@testable import YapnestKit

struct IncomingCallTests {
    private let call = IncomingCall(sid: "s1", peer: JID("bob@localhost")!, name: "Bob", isVideo: true)

    @Test func aPayloadRoundTrips() throws {
        let payload = call.payload
        #expect(payload["sid"] as? String == "s1")
        #expect(payload["peer"] as? String == "bob@localhost")
        #expect(payload["name"] as? String == "Bob")
        #expect(payload["video"] as? Bool == true)
        #expect(IncomingCall(payload: payload) == call)
    }

    @Test func aMalformedPayloadIsRejected() {
        let good = call.payload
        func rejected(_ change: (inout [AnyHashable: Any]) -> Void) -> Bool {
            var payload = good
            change(&payload)
            return IncomingCall(payload: payload) == nil
        }
        for key in ["sid", "peer", "name", "video"] {
            #expect(rejected { $0[key] = nil }, "without \(key)")
            #expect(rejected { $0[key] = 7 }, "\(key) of the wrong type")
        }
        #expect(rejected { $0["sid"] = "" })
        #expect(rejected { $0["sid"] = String(repeating: "a", count: 300) })
        #expect(rejected { $0["peer"] = "" })
        #expect(rejected { $0["peer"] = "a@b/c" }, "a peer that isn't bare")
        #expect(rejected { $0["peer"] = "Bob@Localhost" }, "a peer that isn't normalized")
        #expect(rejected { $0["name"] = String(repeating: "n", count: 1000) })
    }
}
