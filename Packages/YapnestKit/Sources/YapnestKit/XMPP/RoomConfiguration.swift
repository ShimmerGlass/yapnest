import Foundation
@preconcurrency import Martin

/// The parts of a room's configuration (XEP-0045 §10.2) a group's owner can
/// change. A nil field is one the room's form doesn't have, which a screen
/// should hide; as a change, nil means leave it as it is.
public struct RoomConfiguration: Equatable, Sendable {
    public enum AddressVisibility: String, Sendable {
        case anyone
        case moderators
    }

    public var name: String?
    public var description: String?
    public var isMembersOnly: Bool?
    public var whoCanSeeAddresses: AddressVisibility?
    public var membersCanInvite: Bool?
    public var membersCanChangeSubject: Bool?

    public init(
        name: String? = nil, description: String? = nil, isMembersOnly: Bool? = nil, whoCanSeeAddresses: AddressVisibility? = nil,
        membersCanInvite: Bool? = nil, membersCanChangeSubject: Bool? = nil,
    ) {
        self.name = name
        self.description = description
        self.isMembersOnly = isMembersOnly
        self.whoCanSeeAddresses = whoCanSeeAddresses
        self.membersCanInvite = membersCanInvite
        self.membersCanChangeSubject = membersCanChangeSubject
    }

    enum Field {
        static let name = "muc#roomconfig_roomname"
        static let description = "muc#roomconfig_roomdesc"
        static let membersOnly = "muc#roomconfig_membersonly"
        static let whois = "muc#roomconfig_whois"
        static let allowInvites = "muc#roomconfig_allowinvites"
        static let changeSubject = "muc#roomconfig_changesubject"
    }

    /// What the owner's form says. Rooms differ in what they offer, and in
    /// writing a boolean as 1 or true.
    init(form: Element?) {
        func values(_ name: String) -> [String]? { XMPPSession.formValues(name, in: form) }
        func flag(_ name: String) -> Bool? { values(name).map { XMPPSession.formBool($0.first) ?? false } }
        name = values(Field.name).map { $0.first ?? "" }
        description = values(Field.description).map { $0.first ?? "" }
        isMembersOnly = flag(Field.membersOnly)
        whoCanSeeAddresses = values(Field.whois)?.first.flatMap(AddressVisibility.init(rawValue:))
        membersCanInvite = flag(Field.allowInvites)
        membersCanChangeSubject = flag(Field.changeSubject)
    }

    /// One configuration field: where it lives here and in the room's form.
    /// A new field is added to `fields` and nowhere else.
    private struct Slot: @unchecked Sendable {
        let field: String
        let copyIfChanged: (_ draft: RoomConfiguration, _ base: RoomConfiguration, _ into: inout RoomConfiguration) -> Void
        let copyIfSet: (_ change: RoomConfiguration, _ into: inout RoomConfiguration) -> Void
        /// The form's value for what `wanted` sets, or nil if it leaves the
        /// field be. Throws if that changes a field `current` doesn't have.
        let formValue: (_ wanted: RoomConfiguration, _ current: RoomConfiguration, _ writesWords: Bool) throws -> String?

        init<Value: Equatable>(_ path: WritableKeyPath<RoomConfiguration, Value?>, field: String, text: @escaping (Value, Bool) -> String) {
            self.field = field
            copyIfChanged = { draft, base, target in
                if draft[keyPath: path] != base[keyPath: path] { target[keyPath: path] = draft[keyPath: path] }
            }
            copyIfSet = { change, target in
                if let value = change[keyPath: path] { target[keyPath: path] = value }
            }
            formValue = { wanted, current, writesWords in
                guard let value = wanted[keyPath: path], value != current[keyPath: path] else { return nil }
                guard current[keyPath: path] != nil else { throw GroupError.unsupported }
                return text(value, writesWords)
            }
        }

        static func flag(_ path: WritableKeyPath<RoomConfiguration, Bool?>, field: String) -> Slot {
            Slot(path, field: field) { value, words in words ? (value ? "true" : "false") : (value ? "1" : "0") }
        }
    }

    private static let fields: [Slot] = [
        Slot(\.name, field: Field.name) { value, _ in value },
        Slot(\.description, field: Field.description) { value, _ in value },
        .flag(\.isMembersOnly, field: Field.membersOnly),
        Slot(\.whoCanSeeAddresses, field: Field.whois) { value, _ in value.rawValue },
        .flag(\.membersCanInvite, field: Field.allowInvites),
        .flag(\.membersCanChangeSubject, field: Field.changeSubject),
    ]

    /// The fields of this that differ from `base`, or nil if none do. A
    /// field this leaves nil is one the room doesn't offer, and isn't a change.
    public func difference(from base: RoomConfiguration) -> RoomConfiguration? {
        var change = RoomConfiguration()
        for slot in Self.fields { slot.copyIfChanged(self, base, &change) }
        return change == RoomConfiguration() ? nil : change
    }

    /// This with the fields `change` sets.
    public func merging(_ change: RoomConfiguration) -> RoomConfiguration {
        var merged = self
        for slot in Self.fields { slot.copyIfSet(change, &merged) }
        return merged
    }

    /// The form fields that turn `current` into this, with their values
    /// written the way the room's own `form` writes a boolean. Throws if this
    /// changes a field the room doesn't offer.
    func changes(from current: RoomConfiguration, in form: Element) throws -> [String: [String]] {
        var changes: [String: [String]] = [:]
        for slot in Self.fields {
            // A form that writes true and false is answered in kind.
            let writesWords = XMPPSession.formValues(slot.field, in: form)?.first.map { ["true", "false"].contains($0) } ?? false
            if let value = try slot.formValue(self, current, writesWords) { changes[slot.field] = [value] }
        }
        return changes
    }
}

extension XMPPSession {
    /// The values of the field `name` in the data form `form`, or nil if the
    /// form has no such field.
    static func formValues(_ name: String, in form: Element?) -> [String]? {
        guard let field = form?.filterChildren(name: "field", xmlns: nil).first(where: { $0.getAttribute("var") == name }) else { return nil }
        return field.filterChildren(name: "value", xmlns: nil).map { $0.value ?? "" }
    }

    static func formBool(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "1", "true": true
        case "0", "false": false
        default: nil
        }
    }

    /// Every field of `form` with its values, to be sent back as it came.
    static func formFields(_ form: Element) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        for field in form.filterChildren(name: "field", xmlns: nil) {
            // A fixed field is only text, and FORM_TYPE is added on submitting.
            guard let name = field.getAttribute("var"), name != "FORM_TYPE", field.getAttribute("type") != "fixed" else { continue }
            fields[name] = field.filterChildren(name: "value", xmlns: nil).map { $0.value ?? "" }
        }
        return fields
    }
}
