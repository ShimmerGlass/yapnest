import CoreLocation
import Testing
@testable import Yapnest

@MainActor
struct LocationProviderTests {
    // SwiftUI builds a view's `@State` default again at every render and keeps
    // only the first; a manager given its delegate in `init` asks for a fix
    // each time, for providers nobody uses.
    @Test func aProviderBuiltButNeverStartedDoesNotListenOrAsk() {
        let manager = CLLocationManager()

        _ = LocationProvider(manager: manager)

        #expect(manager.delegate == nil)
    }
}
