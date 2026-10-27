#if targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import YapnestKit

/// Shows the Mac's session away while the Mac is idle or locked (`IdleRules`),
/// tells the server (XEP-0352) it is inactive while the screen is locked,
/// and gives it the Mac's idle time for last seen. The app never suspends
/// there, so leaving it says nothing about whether the user is at the Mac.
@MainActor
final class IdleWatch {
    private let session: XMPPSession
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var screenLocked = false

    init(session: XMPPSession) {
        self.session = session
        session.setIdleSource { Self.systemIdle() }
        // The system's own names for these; nothing else says the screen locked.
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenLocked = locked
                    self?.session.setScreenLocked(locked)
                    self?.check()
                }
            })
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let away = self?.check() else { return }
                try? await Task.sleep(for: .seconds(IdleRules.interval(away: away)))
            }
        }
    }

    func stop() {
        loop?.cancel()
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers = []
        session.setIdleSource(nil)
        session.setAway(false)
        session.setScreenLocked(false)
    }

    @discardableResult
    private func check() -> Bool {
        let away = IdleRules.isAway(idle: Self.systemIdle(), screenLocked: screenLocked)
        session.setAway(away)
        return away
    }

    /// Seconds since the last key press, click or mouse movement, in any app.
    nonisolated private static func systemIdle() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
#endif
