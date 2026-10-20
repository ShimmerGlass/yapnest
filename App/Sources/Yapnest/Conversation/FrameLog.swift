import SwiftUI

/// A per-frame log of everything that can move what the user sees in a
/// conversation, for finding a jitter that shows on a device and not in the
/// simulator. Off unless `YAPNEST_DEV_FRAME_LOG=1`, and not in Release at
/// all: the hooks are empty there. Lines go to `frame-log.txt` in the app's
/// Documents, which holds the latest conversation only.
///
/// Each line is the time (`systemUptime`) and a kind: `geo` for every scroll
/// geometry change, `event` for what the model does about the scroll and for
/// the keyboard. Writes are buffered and flushed a
/// couple of times a second, so the logging doesn't cause what it looks for.
#if DEBUG
enum FrameLog {
    static let enabled = ProcessInfo.processInfo.environment["YAPNEST_DEV_FRAME_LOG"] == "1"

    private static let queue = DispatchQueue(label: "fr.yapnest.frame-log")
    // Only touched on `queue`.
    nonisolated(unsafe) private static var buffer = ""
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var observing = false

    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("frame-log.txt")
    }

    /// A conversation opened: starts the file over.
    static func begin() {
        guard enabled else { return }
        queue.async {
            buffer = ""
            if let url { try? Data().write(to: url) }
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
                timer.setEventHandler { flush() }
                timer.resume()
                self.timer = timer
            }
            if !observing {
                observing = true
                let names: [Notification.Name] = [
                    UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                    UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                ]
                for name in names {
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                        let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect).map { "\($0)" } ?? "?"
                        event("keyboard \(name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "").replacingOccurrences(of: "Notification", with: "")) end=\(end)")
                    }
                }
            }
        }
        event("begin")
    }

    private static func flush() {
        guard !buffer.isEmpty, let url, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }

    private static func line(_ kind: String, _ text: String) {
        let time = ProcessInfo.processInfo.systemUptime
        queue.async { buffer += String(format: "%.4f ", time) + kind + " " + text + "\n" }
    }

    static func event(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        line("event", message())
    }

    @MainActor
    static func geometry(_ g: ScrollGeometry, model: ConversationModel) {
        guard enabled else { return }
        line("geo", String(
            format: "offset=%.2f content=%.2f container=%.2f insetTop=%.2f insetBottom=%.2f distFromBottom=%.2f flipped=%d phase=%@ follows=%d nudge=%.0f",
            g.contentOffset.y, g.contentSize.height, g.containerSize.height, g.contentInsets.top, g.contentInsets.bottom,
            ConversationModel.distanceFromBottom(g, flipped: model.isFlipped), model.isFlipped ? 1 : 0, "\(model.scrollPhase)", model.followsBottom ? 1 : 0, model.layoutNudge,
        ))
    }
}
#else
enum FrameLog {
    static func begin() {}
    static func event(_ message: @autoclosure () -> String) {}
    @MainActor static func geometry(_ g: ScrollGeometry, model: ConversationModel) {}
}
#endif
