import Foundation
@preconcurrency import Martin

/// What a message offers the reader to answer with (XEP-0439): replies to send
/// as text, and actions to trigger. Both come from the sender, typically a bot,
/// so they are checked before they are kept, and shown as plain text.
public struct QuickResponses: Codable, Hashable, Sendable {
    public struct Response: Codable, Hashable, Sendable {
        /// What choosing it sends, as the body of a message.
        public var value: String
        public var label: String?

        public init(value: String, label: String? = nil) {
            self.value = value
            self.label = label
        }

        /// What its button says.
        public var title: String { label ?? value }
    }

    public struct Action: Codable, Hashable, Sendable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var responses: [Response]
    public var actions: [Action]
    /// The ids of actions we have chosen, so each is offered once.
    public var chosen: [String] = []

    public init(responses: [Response] = [], actions: [Action] = [], chosen: [String] = []) {
        self.responses = responses
        self.actions = actions
        self.chosen = chosen
    }

    static let maxEntries = 8
    static let maxValueLength = 256
    static let maxLabelLength = 64

    /// What the message's `<response>` and `<action>` elements offer, if any
    /// entry survives the checks. A bad entry is dropped alone, so one
    /// careless label doesn't take the good ones with it.
    init?(_ stanza: Martin.Message) {
        var responses: [Response] = []
        var actions: [Action] = []
        var seenValues = Set<String>(), seenLabels = Set<String>(), seenActionLabels = Set<String>(), seenIds = Set<String>()

        for element in stanza.filterChildren(name: "response", xmlns: NS.quickResponse) where responses.count < Self.maxEntries {
            guard let value = Self.clean(element.getAttribute("value"), maxLength: Self.maxValueLength) else { continue }
            let label = Self.clean(element.getAttribute("label"), maxLength: Self.maxLabelLength)
            // A label that is present but unusable doesn't fall back to the value.
            if element.getAttribute("label") != nil, label == nil { continue }
            guard seenValues.insert(value).inserted else { continue }
            if let label, !seenLabels.insert(label).inserted { continue }
            responses.append(Response(value: value, label: label))
        }
        for element in stanza.filterChildren(name: "action", xmlns: NS.quickResponse) where actions.count < Self.maxEntries {
            // With nothing to show, a button for it would be a blank one.
            guard let id = Self.clean(element.getAttribute("id"), maxLength: Self.maxValueLength),
                  let label = Self.clean(element.getAttribute("label"), maxLength: Self.maxLabelLength),
                  seenIds.insert(id).inserted, seenActionLabels.insert(label).inserted else { continue }
            actions.append(Action(id: id, label: label))
        }
        guard !responses.isEmpty || !actions.isEmpty else { return nil }
        self.init(responses: responses, actions: actions)
    }

    /// The text trimmed, or nil if nothing is left, it is too long, or it holds
    /// a control or a character that changes how text reads or hides it.
    static func clean(_ raw: String?, maxLength: Int) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= maxLength,
              !text.unicodeScalars.contains(where: { XMPPURI.isHiddenInText($0) || XMPPURI.isControl($0) }) else { return nil }
        return text
    }
}
