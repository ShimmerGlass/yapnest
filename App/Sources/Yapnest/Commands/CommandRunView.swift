import SwiftUI
import YapnestKit

/// A command being run: its notes and form, and the buttons for the steps its
/// current stage allows.
struct CommandRunView: View {
    @State private var run: AdHocRun
    @Environment(\.dismiss) private var dismiss

    init(command: AdHocCommand, session: XMPPSession) {
        _run = State(initialValue: AdHocRun(command: command, session: session))
    }

    init(run: AdHocRun) {
        _run = State(initialValue: run)
    }

    private var isCompleted: Bool { run.response?.status == .completed }

    var body: some View {
        Form {
            if let response = run.response {
                if !response.notes.isEmpty {
                    Section {
                        ForEach(Array(response.notes.enumerated()), id: \.offset) { _, note in
                            NoteRow(note: note)
                        }
                    }
                }
                if run.form != nil {
                    XDataFormView(
                        form: Binding(get: { run.form ?? XDataForm() }, set: { run.form = $0 }),
                        problems: run.problems,
                        isReadOnly: isCompleted || run.form?.type == .result,
                    )
                }
                if isCompleted, response.notes.isEmpty, run.form?.fields.contains(where: { $0.type != .hidden }) != true, run.form?.items.isEmpty != false {
                    Section { Text("Done.") }
                }
            } else if run.isBusy {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else {
                Section {
                    Button("Try Again") { Task { await run.start() } }
                }
            }
        }
        .dismissesKeyboardOnTap()
        .navigationTitle(Text(verbatim: run.command.name))
        .navigationBarTitleDisplayMode(.inline)
        // Not mid-command, where a checkmark would read as sending the step.
        .sheetDoneButton(isShown: !run.isExecuting)
        .navigationBarBackButtonHidden(run.isExecuting)
        .toolbar {
            // A command's name can be long, and the inline title keeps one line.
            ToolbarItem(placement: .principal) {
                Text(verbatim: run.command.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if run.isExecuting {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton {
                        Task {
                            await run.cancel()
                            dismiss()
                        }
                    }
                    .disabled(run.isBusy)
                }
                ToolbarItemGroup(placement: .bottomBar) { actions }
            } else if isCompleted {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Done") { dismiss() }
                        .modifier(StepButtonStyle(prominent: true))
                }
            }
        }
        .task {
            if run.response == nil, !run.isBusy { await run.start() }
        }
        .onChange(of: run.isCanceled) { _, canceled in
            if canceled { dismiss() }
        }
        .onDisappear { run.abandon() }
        .alert("Couldn't run the command", isPresented: Binding(isPresent: $run.error)) {
            if run.needsRestart {
                Button("Start again") { Task { await run.start() } }
                Button("Close", role: .cancel) { dismiss() }
            } else {
                Button("OK") {}
            }
        } message: {
            Text(verbatim: run.error ?? "")
        }
    }

    @ViewBuilder
    private var actions: some View {
        let allowed = run.response?.allowed ?? []
        let preferred = run.response?.defaultAction
        ForEach([AdHocAction.prev, .next, .complete].filter(allowed.contains), id: \.self) { action in
            Button {
                Task { await run.perform(action) }
            } label: {
                HStack(spacing: 6) {
                    if run.inFlight == action { ProgressView() }
                    Text(Self.title(of: action))
                }
            }
            .disabled(run.isBusy)
            .modifier(StepButtonStyle(prominent: action == preferred))
        }
    }

    private static func title(of action: AdHocAction) -> LocalizedStringKey {
        switch action {
        case .prev: "Back"
        case .next: "Next"
        case .complete: "Complete"
        case .execute: "Start"
        case .cancel: "Cancel"
        }
    }
}

/// The bottom bar of iOS 26 already puts each button on glass, so a bordered
/// style would draw a second, dark capsule inside it. Earlier systems have no
/// glass and need the border to look like buttons.
private struct StepButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct NoteRow: View {
    let note: AdHocNote

    var body: some View {
        Label {
            Text(verbatim: note.text)
        } icon: {
            switch note.kind {
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}
