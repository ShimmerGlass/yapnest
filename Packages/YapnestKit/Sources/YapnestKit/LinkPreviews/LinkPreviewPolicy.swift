import GRDB

/// The app-wide link preview choice. Per-chat choices only apply under `askPerConversation`.
public enum LinkPreviewSetting: String, Sendable, CaseIterable {
    case askPerConversation
    case never

    init(stored raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .askPerConversation
    }
}

/// What to do about a message's link preview.
public enum LinkPreviewPolicy {
    public enum Decision: Sendable, Equatable {
        case show, ask, off
    }

    /// One place for display and fetching to agree. Our own links preview
    /// unless the chat says never, since we chose to share them and asking
    /// would be pointless; links from others need the chat's consent, because
    /// loading one tells the linked site we received it. `isOurs` is
    /// `Message.isTrustedOutgoing`: a room's word that a message is ours
    /// doesn't make it so.
    public static func decide(global: LinkPreviewSetting, chat: Bool?, isOurs: Bool) -> Decision {
        if global == .never || chat == false { return .off }
        if chat == true || isOurs { return .show }
        return .ask
    }
}

extension AppDatabase {
    public var linkPreviewSetting: LinkPreviewSetting {
        LinkPreviewSetting(stored: (try? setting(.linkPreviews)) ?? nil)
    }

    public func setLinkPreviewSetting(_ value: LinkPreviewSetting) throws {
        try setSetting(.linkPreviews, value.rawValue)
    }

    public func observeLinkPreviewSetting() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<LinkPreviewSetting>>> {
        ValueObservation.tracking { db in
            LinkPreviewSetting(stored: try Self.setting(db, .linkPreviews))
        }
        .removeDuplicates()
    }
}
