#if DEBUG
import Foundation
import YapnestKit

/// An offline command whose every string is very long, for screenshots of how
/// the command screen lays out what an entity can send it. `YAPNEST_DEV_COMMAND=long`
/// opens it. Each kind of text also gets a token without spaces, as a hash or a
/// URL has no place to wrap at a word.
enum LongCommandFixture {
    private static let sentence = "This text is deliberately much longer than any entity would reasonably send, so that it has to wrap over several lines even on a wide screen and over a great many on a phone."
    private static let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567"
    private static let url = "https://example.org/a/very/long/path/without/any/spaces/that/cannot/wrap/at/a/word/boundary/0123456789abcdef0123456789abcdef"

    static func long(_ what: String) -> String { "\(what): \(sentence)" }

    @MainActor
    static func run() -> AdHocRun {
        let command = AdHocCommand(
            jid: "long@example.org", node: "long",
            name: "A command with a name much longer than a navigation title could ever show on one line",
        )
        return AdHocRun(command: command) { action, _, _ in
            try? await Task.sleep(for: .milliseconds(300))
            switch action {
            case .next, .complete: return completed
            case .cancel: return AdHocResponse(sessionID: "long", status: .canceled)
            default: return first
            }
        }
    }

    private static let first = AdHocResponse(
        sessionID: "long", status: .executing, form: firstForm,
        allowed: [.prev, .next, .complete], defaultAction: .next,
        notes: [
            AdHocNote(kind: .info, text: long("Info note")),
            AdHocNote(kind: .warn, text: long("Warning note") + " " + token),
            AdHocNote(kind: .error, text: long("Error note")),
        ],
    )

    private static let firstForm = XDataForm(
        type: .form, title: long("Form title"),
        instructions: [long("First line of instructions"), long("Second line of instructions") + " " + url],
        fields: [
            .init(name: "text", type: .textSingle, label: long("Text label") + " " + token, desc: long("Description of the text field"), required: true, values: [token]),
            .init(name: "secret", type: .textPrivate, label: long("Private label")),
            .init(name: "flag", type: .boolean, label: long("Boolean label")),
            .init(
                name: "one", type: .listSingle, label: long("Single choice label"), values: ["a"],
                options: [
                    .init(label: long("First option"), value: "a"),
                    .init(label: token, value: "b"),
                    .init(label: long("Third option"), value: "c"),
                ],
            ),
            .init(
                name: "many", type: .listMulti, label: long("Multiple choice label"), values: ["a"],
                options: [
                    .init(label: long("First option"), value: "a"),
                    .init(label: long("Second option") + " " + url, value: "b"),
                ],
            ),
            .init(name: "jids", type: .jidMulti, label: long("Addresses label"), values: ["someone@example.org"]),
            .init(name: "notes", type: .textMulti, label: long("Multi-line label"), values: [long("First line of the value"), token, long("Third line")]),
            .init(name: nil, type: .fixed, values: [long("Fixed text")]),
            .init(name: "FORM_TYPE", type: .hidden, values: ["urn:example:long"]),
        ],
    )

    private static let completed = AdHocResponse(
        sessionID: "long", status: .completed,
        form: XDataForm(
            type: .result, title: long("Result title"),
            instructions: [long("Result instructions")],
            fields: [
                .init(name: "a", type: .textSingle, label: long("First result label"), values: [long("First result value")]),
                .init(name: "b", type: .textSingle, label: token, values: [token]),
            ],
            reported: [
                .init(name: "col1", label: long("First column")),
                .init(name: "col2", label: long("Second column")),
            ],
            items: [
                [.init(name: "col1", values: [long("First row, first value")]), .init(name: "col2", values: [token])],
                [.init(name: "col1", values: [url]), .init(name: "col2", values: [long("Second row, second value")])],
            ],
        ),
        notes: [AdHocNote(kind: .info, text: long("Closing note"))],
    )
}
#endif
