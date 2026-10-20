import Foundation
import Testing
@testable import Martin

struct PacketWriterTests {
    /// The session drops what is written while it isn't connected, and the
    /// writer used to report success for it regardless.
    @Test func aWriteOnADisconnectedSessionFails() async throws {
        let client = XMPPClient()
        let responses = ResponseManager()
        let logic = SocketSessionLogic(connector: SocketConnectorNetwork(context: client.context), responseManager: responses, context: client.context, seeOtherHost: nil)
        let writer = LogicPacketWriter(sessionLogic: logic, responseManager: responses)

        let result: Result<Void, XMPPError> = await withCheckedContinuation { continuation in
            writer.write(Message(), writeCompleted: { continuation.resume(returning: $0) })
        }
        guard case .failure = result else {
            Issue.record("a dropped write reported success")
            return
        }
    }
}
