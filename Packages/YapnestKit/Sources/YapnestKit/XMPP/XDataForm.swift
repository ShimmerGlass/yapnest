import Foundation
@preconcurrency import Martin

/// A XEP-0004 data form: what an entity asks for in a command, and what a
/// command returns as a table. Kept as a plain value, apart from Martin's
/// `DataForm`, so a view can edit a copy and the session can send it back.
///
/// The media element (XEP-0221) is not read. A form comes from whichever
/// entity the user ran a command on, and loading its images or videos would
/// tell that entity when and from where the form was opened.
public struct XDataForm: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case form, submit, cancel, result
    }

    public var type: Kind
    public var title: String?
    public var instructions: [String]
    public var fields: [Field]
    /// The columns of a result table, if it is one; `items` holds the rows.
    public var reported: [Field]?
    /// The rows of a result table. A row names only the fields it has a value
    /// for, so look a column up by its `var`.
    public var items: [[Field]]

    public init(
        type: Kind = .form, title: String? = nil, instructions: [String] = [], fields: [Field] = [],
        reported: [Field]? = nil, items: [[Field]] = [],
    ) {
        self.type = type
        self.title = title
        self.instructions = instructions
        self.fields = fields
        self.reported = reported
        self.items = items
    }

    public struct Field: Hashable, Sendable {
        public enum Kind: String, Sendable {
            case boolean
            case fixed
            case hidden
            case jidMulti = "jid-multi"
            case jidSingle = "jid-single"
            case listMulti = "list-multi"
            case listSingle = "list-single"
            case textMulti = "text-multi"
            case textPrivate = "text-private"
            case textSingle = "text-single"
        }

        public struct Option: Hashable, Sendable {
            public var label: String?
            public var value: String

            public init(label: String? = nil, value: String) {
                self.label = label
                self.value = value
            }

            /// What to show for the option: its label, or else its value.
            public var title: String { label.nonEmpty ?? value }
        }

        /// The field's name. A `fixed` field, which is only text to read, has none.
        public var name: String?
        public var type: Kind
        public var label: String?
        public var desc: String?
        public var required: Bool
        public var values: [String]
        public var options: [Option]

        public init(
            name: String?, type: Kind = .textSingle, label: String? = nil, desc: String? = nil, required: Bool = false,
            values: [String] = [], options: [Option] = [],
        ) {
            self.name = name
            self.type = type
            self.label = label
            self.desc = desc
            self.required = required
            self.values = values
            self.options = options
        }

        /// What to call the field: its label, or else its name.
        public var title: String { label.nonEmpty ?? name ?? "" }

        /// Whether the user is shown the field as something to fill in.
        public var isEditable: Bool { type != .fixed && type != .hidden }

        // MARK: Values for a view to bind to

        /// The one value of a single-valued field, "" if it has none.
        public var value: String {
            get { values.first ?? "" }
            set { values = newValue.isEmpty ? [] : [newValue] }
        }

        /// A boolean field's answer. XEP-0004 spells true "1" or "true"; a
        /// field without a value is false.
        public var boolValue: Bool {
            get { Self.isTrue(values.first) }
            set { values = [newValue ? "1" : "0"] }
        }

        /// A text-multi field as the text of one box: a value is a line.
        public var text: String {
            get { values.joined(separator: "\n") }
            set { values = newValue.isEmpty ? [] : newValue.components(separatedBy: "\n") }
        }

        /// Whether a list-multi field has `value` ticked.
        public func isSelected(_ value: String) -> Bool { values.contains(value) }

        /// Ticks or unticks `value` in a list-multi field. The values stay in
        /// the order of the options, whatever order the user ticked them in.
        public mutating func setSelected(_ value: String, _ selected: Bool) {
            var chosen = Set(values)
            if selected { chosen.insert(value) } else { chosen.remove(value) }
            let ordered = options.map(\.value).filter(chosen.contains)
            values = ordered + values.filter { !ordered.contains($0) && chosen.contains($0) }
        }

        static func isTrue(_ value: String?) -> Bool {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
            return value == "1" || value == "true"
        }
    }

    // MARK: Reading

    /// The form in a `<x xmlns='jabber:x:data'>` element, nil if it isn't one.
    public init?(_ element: Element) {
        guard element.name == "x", element.xmlns == NS.dataForms else { return nil }
        type = element.getAttribute("type").flatMap(Kind.init(rawValue:)) ?? .form
        title = element.firstChild(name: "title")?.value
        instructions = element.filterChildren(name: "instructions", xmlns: nil).compactMap(\.value)
        fields = element.filterChildren(name: "field", xmlns: nil).compactMap(Field.init)
        reported = element.firstChild(name: "reported").map { $0.filterChildren(name: "field", xmlns: nil).compactMap(Field.init) }
        items = element.filterChildren(name: "item", xmlns: nil).map { $0.filterChildren(name: "field", xmlns: nil).compactMap(Field.init) }
    }

    // MARK: Sending

    /// The answer to send: a `submit` form with every field that has a name,
    /// as the entity needs the ones it didn't ask the user about too
    /// (`FORM_TYPE` and other hidden fields come back as they were). Fixed
    /// fields are text for the reader and are left out.
    public func submission() -> Element {
        let form = Element(name: "x", xmlns: NS.dataForms)
        form.setAttribute("type", value: Kind.submit.rawValue)
        for field in fields where field.type != .fixed {
            guard let name = field.name else { continue }
            let element = Element(name: "field", attributes: ["var": name])
            // The type is repeated so an entity that loses track of its own
            // form can still read a boolean or a JID.
            element.setAttribute("type", value: field.type.rawValue)
            for value in field.valuesToSend { element.addChild(Element(name: "value", cdata: value)) }
            form.addChild(element)
        }
        return form
    }

    // MARK: Checking

    /// Something wrong with what's been filled in.
    public struct Problem: Hashable, Sendable {
        public enum Reason: Hashable, Sendable {
            /// A required field has no value.
            case required
            /// A JID field holds something that isn't an address.
            case invalidJID(String)
            /// A list field holds a value that isn't one of its options.
            case notAnOption(String)
        }

        /// Where the field is in `fields`.
        public var index: Int
        public var field: String?
        public var reason: Reason

        public var message: String {
            switch reason {
            case .required: String(localized: "This is required.")
            case .invalidJID(let value): String(localized: "\"\(value)\" isn't a valid address.")
            case .notAnOption(let value): String(localized: "\"\(value)\" isn't one of the choices.")
            }
        }
    }

    /// What's wrong with the form as it stands, in field order; empty if it
    /// can be sent. Checked before sending, so the user is told which field
    /// is at fault rather than that the entity refused.
    public func validationProblems() -> [Problem] {
        var problems: [Problem] = []
        for (index, field) in fields.enumerated() where field.isEditable {
            func add(_ reason: Problem.Reason) { problems.append(Problem(index: index, field: field.name, reason: reason)) }
            let given = field.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // A boolean is always answered, as unticked is "no".
            if field.required, field.type != .boolean, given.isEmpty {
                add(.required)
                continue
            }
            switch field.type {
            case .jidSingle, .jidMulti:
                if let bad = given.first(where: { !Self.isAddress($0) }) { add(.invalidJID(bad)) }
            case .listSingle, .listMulti:
                // An entity that gives no options can't be held to them.
                if !field.options.isEmpty, let bad = given.first(where: { value in !field.options.contains { $0.value == value } }) {
                    add(.notAnOption(bad))
                }
            default:
                break
            }
        }
        return problems
    }

    /// Whether `value` is a JID, with or without a resource. The kit's `JID`
    /// drops the resource, so it checks what comes before it.
    static func isAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare: Substring
        if let slash = trimmed.firstIndex(of: "/") {
            guard trimmed.index(after: slash) < trimmed.endIndex else { return false }
            bare = trimmed[..<slash]
        } else {
            bare = Substring(trimmed)
        }
        return !bare.contains(where: \.isWhitespace) && JID(String(bare)) != nil
    }
}

extension XDataForm.Field {
    init?(_ element: Element) {
        let kind = element.getAttribute("type").flatMap(Kind.init(rawValue:)) ?? .textSingle
        let name = element.getAttribute("var")
        // Only a fixed field may go without a name: it is just text.
        guard name != nil || kind == .fixed else { return nil }
        self.init(
            name: name, type: kind, label: element.getAttribute("label"), desc: element.firstChild(name: "desc")?.value,
            required: element.firstChild(name: "required") != nil,
            values: element.filterChildren(name: "value", xmlns: nil).map { $0.value ?? "" },
            options: element.filterChildren(name: "option", xmlns: nil).compactMap { option in
                option.firstChild(name: "value")?.value.map { Option(label: option.getAttribute("label"), value: $0) }
            },
        )
    }

    /// The values as they go on the wire: a boolean always says "1" or "0",
    /// and a field the user left empty sends no value at all.
    fileprivate var valuesToSend: [String] {
        switch type {
        case .boolean:
            return [Self.isTrue(values.first) ? "1" : "0"]
        case .textMulti:
            return values
        default:
            return values.filter { !$0.isEmpty }
        }
    }
}

extension XMPPSession {
    /// A form of the given type with `FORM_TYPE` first and the fields sorted
    /// by name, so the same fields always make the same stanza.
    static func dataForm(type: String, formType: String, fields: [String: [String]]) -> Element {
        let x = Element(name: "x", xmlns: NS.dataForms)
        x.setAttribute("type", value: type)
        var all = [("FORM_TYPE", [formType])]
        all += fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for (name, values) in all {
            let field = Element(name: "field")
            field.setAttribute("var", value: name)
            for value in values { field.addChild(Element(name: "value", cdata: value)) }
            x.addChild(field)
        }
        return x
    }
}

extension Optional where Wrapped == String {
    /// The text, or nil if there is none.
    var nonEmpty: String? {
        flatMap { $0.isEmpty ? nil : $0 }
    }
}
