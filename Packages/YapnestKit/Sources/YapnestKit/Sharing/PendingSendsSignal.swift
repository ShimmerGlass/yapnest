import Foundation

/// How the share extension tells the running app that it left messages to
/// send. The app holds the session lock while it's open, so the extension
/// can't send them itself; a Darwin notification crosses the process
/// boundary without either side needing the other to be there.
public final class PendingSendsSignal: @unchecked Sendable {
    private static var name: CFString {
        "\(SharedContainer.appGroup).pending-sends" as CFString
    }

    private let handler: @Sendable () -> Void

    /// Calls `handler`, on an arbitrary thread, each time an extension posts.
    public init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<PendingSendsSignal>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            Self.name, nil, .deliverImmediately,
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(Self.name), nil)
    }

    public static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
    }
}
