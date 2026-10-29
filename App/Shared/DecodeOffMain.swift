import Foundation

/// Decodes a picture off the main thread unless the view asking has gone.
/// A detached task doesn't inherit its caller's cancellation, so a flick
/// past a chat's photos would otherwise leave a full-size decode queued for
/// every row it passed.
func decodeOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
    guard !Task.isCancelled else { return nil }
    let task = Task.detached(priority: .userInitiated) { () -> T? in
        Task.isCancelled ? nil : work()
    }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}
