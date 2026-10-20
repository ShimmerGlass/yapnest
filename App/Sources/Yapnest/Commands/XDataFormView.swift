import SwiftUI
import YapnestKit

/// A data form, for the sections of a `Form`: to fill in, or, for a command's
/// result, to read. Everything in it comes from whichever entity the command
/// runs on, so every string is shown as it is (`verbatim`), never read as
/// markup, which would let that entity put links or formatting on the screen.
struct XDataFormView: View {
    @Binding var form: XDataForm
    var problems: [Int: String] = [:]
    var isReadOnly = false

    var body: some View {
        if form.title?.isEmpty == false || !form.instructions.isEmpty {
            Section {
                if let title = form.title, !title.isEmpty {
                    Text(verbatim: title).font(.headline)
                }
                ForEach(Array(form.instructions.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).foregroundStyle(.secondary)
                }
            }
        }
        if let reported = form.reported {
            ForEach(Array(form.items.enumerated()), id: \.offset) { _, item in
                Section {
                    ForEach(Array(item.enumerated()), id: \.offset) { _, field in
                        ReadOnlyField(field: field, title: reported.first { $0.name == field.name }?.title, showsEmpty: true)
                    }
                }
            }
        }
        if form.fields.contains(where: { $0.type != .hidden }) {
            Section {
                ForEach(form.fields.indices, id: \.self) { index in
                    if isReadOnly {
                        ReadOnlyField(field: form.fields[index])
                    } else {
                        FieldRow(field: $form.fields[index], problem: problems[index])
                    }
                }
            }
        }
    }

    /// Whether a list's options need room to wrap. In a menu the chosen one is
    /// squeezed onto the label's row and cut short, so long ones are listed in full.
    static func hasLongOptions(_ options: [XDataForm.Field.Option]) -> Bool {
        options.contains { $0.title.count > 30 || $0.title.contains("\n") }
    }

    /// A field's value as text to read.
    static func shown(_ field: XDataForm.Field) -> String {
        switch field.type {
        case .boolean:
            return field.boolValue ? String(localized: "Yes") : String(localized: "No")
        case .textPrivate:
            return field.values.isEmpty ? "" : "••••••"
        case .listSingle, .listMulti:
            return field.values.map { value in field.options.first { $0.value == value }?.title ?? value }.joined(separator: ", ")
        default:
            return field.values.joined(separator: "\n")
        }
    }
}

/// A result's field: its label over its value, which can be copied.
private struct ReadOnlyField: View {
    let field: XDataForm.Field
    /// The reported column's title, which a table's items are labelled with.
    var title: String?
    /// Whether a field with no value still shows its label. A table's rows
    /// need every column, or they lose cells and stop lining up with the rest.
    var showsEmpty = false

    var body: some View {
        switch field.type {
        case .hidden:
            EmptyView()
        case .fixed:
            Text(verbatim: field.values.joined(separator: "\n")).foregroundStyle(.secondary)
        default:
            let value = XDataFormView.shown(field)
            if showsEmpty || !value.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title ?? field.title).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: value).textSelection(.enabled)
                }
            }
        }
    }
}

private struct FieldRow: View {
    @Binding var field: XDataForm.Field
    let problem: String?

    /// A taller field would grow past the screen and swallow the swipes meant
    /// for the form, so a longer value scrolls inside the field instead.
    private static let maxLines = 6

    private var title: String { field.required ? "\(field.title) *" : field.title }

    var body: some View {
        switch field.type {
        case .hidden:
            EmptyView()
        case .fixed:
            Text(verbatim: field.values.joined(separator: "\n")).foregroundStyle(.secondary)
        default:
            VStack(alignment: .leading, spacing: 6) {
                control
                if let desc = field.desc, !desc.isEmpty {
                    Text(verbatim: desc).font(.footnote).foregroundStyle(.secondary)
                }
                if let problem {
                    Text(verbatim: problem).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.type {
        case .boolean:
            Toggle(isOn: $field.boolValue) { Text(verbatim: title) }
        case .textSingle:
            labelled { TextField("", text: $field.value) }
        case .textPrivate:
            labelled { SecureField("", text: $field.value) }
        case .jidSingle:
            labelled {
                TextField("", text: $field.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
            }
        case .jidMulti:
            labelled {
                TextField("", text: $field.text, axis: .vertical)
                    .lineLimit(1...Self.maxLines)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
            }
        case .textMulti:
            labelled { TextField("", text: $field.text, axis: .vertical).lineLimit(1...Self.maxLines) }
        case .listSingle where XDataFormView.hasLongOptions(field.options):
            Text(verbatim: title)
            if !field.required {
                choice(Text("None"), value: "")
            }
            ForEach(field.options.indices, id: \.self) { index in
                choice(Text(verbatim: field.options[index].title), value: field.options[index].value)
            }
        case .listSingle:
            Picker(selection: $field.value) {
                if !field.required { Text("None").tag("") }
                ForEach(field.options.indices, id: \.self) { index in
                    Text(verbatim: field.options[index].title).tag(field.options[index].value)
                }
            } label: {
                Text(verbatim: title)
            }
        case .listMulti:
            Text(verbatim: title)
            ForEach(field.options.indices, id: \.self) { index in
                let option = field.options[index]
                checkRow(label: Text(verbatim: option.title), isOn: field.isSelected(option.value)) {
                    field.setSelected(option.value, !field.isSelected(option.value))
                }
            }
        case .fixed, .hidden:
            EmptyView()
        }
    }

    private func choice(_ label: Text, value: String) -> some View {
        checkRow(label: label, isOn: field.value == value) { field.value = value }
    }

    private func checkRow(label: Text, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                label
                Spacer()
                if isOn { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func labelled<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }
}
