import Foundation
@preconcurrency import Martin

/// What a group's owner can change about it: its configuration, its picture,
/// and its existence. The room has the last word on each.
extension XMPPSession {
    // MARK: Configuration

    /// The room's configuration as its owner form has it (XEP-0045 §10.2).
    /// Fields the room doesn't offer are nil.
    public func roomConfiguration(of room: JID) async throws -> RoomConfiguration {
        try requireOwner(of: room)
        guard let form = try await ownerForm(of: room) else { throw GroupError.unsupported }
        let configuration = RoomConfiguration(form: form)
        if let allowed = configuration.membersCanChangeSubject {
            updateRoom(room) { $0?.participantsMayChangeSubject = allowed }
        }
        return configuration
    }

    /// Changes the fields `configuration` sets that differ from the room's.
    /// The room's form is read first and sent back whole with those
    /// changed, as a server keeps only what a form submits. Returns once
    /// what we keep of the room (its name, who may join, whether it's private
    /// and so can be encrypted) is up to date.
    ///
    /// The name is the room's own: a renamed room shows its new name in every
    /// member's chat list, and our bookmark follows.
    public func updateRoomConfiguration(_ configuration: RoomConfiguration, in room: JID) async throws {
        try requireOwner(of: room)
        guard let form = try await ownerForm(of: room) else { throw GroupError.unsupported }
        let changes = try configuration.changes(from: RoomConfiguration(form: form), in: form)
        guard !changes.isEmpty else { return }
        try await submitOwnerForm(Self.formFields(form).merging(changes) { _, new in new }, to: room)

        // The room announces the change (status 104) and we'd read it then,
        // but the caller wants to see the result when this returns.
        await refreshedRoomInfo(room)
    }

    private func requireOwner(of room: JID) throws {
        guard try joinedStatus(room).canEditInfo else { throw GroupError.notAllowed }
    }

    // MARK: Picture

    /// Sets the group's picture, which everyone in it sees (XEP-0486, kept in
    /// the room's vCard), or removes it with nil. `image` is already scaled
    /// and encoded, as for `publishAvatar`. Throws `GroupError.unsupported`
    /// if the room's server keeps no vCard for rooms.
    public func setGroupAvatar(_ image: Data?, mimeType: String = "image/png", in room: JID) async throws {
        try requireOwner(of: room)
        // Checked before the room hears of it: it would show a picture that
        // we can't. The store names files by their hash, so a picture the
        // room then refuses is only left unused.
        let hash = image.map(AvatarStore.hash(of:))
        if let image, let hash, !avatars.save(image, hash: hash) { throw ProfileError.imageTooLarge }
        // The rest of the card stays as the room has it.
        // Only a room with no card yet starts from an empty one; any other
        // failure would otherwise write over fields we couldn't read.
        var kept: [Element] = []
        do {
            let current = try await client.context.writer.write(iq: OutboundStanza.vCardRequest(of: room))
            kept = current.firstChild(name: "vCard", xmlns: NS.vcardTemp)?.children ?? []
        } catch let error as XMPPError where error.errorCondition == .item_not_found {
        } catch let error as XMPPError {
            throw Self.groupError(error)
        }
        let card = Element(name: "vCard", xmlns: NS.vcardTemp)
        for child in kept where child.name != "PHOTO" {
            card.addChild(child)
        }
        if let image {
            let photo = Element(name: "PHOTO")
            photo.addChild(Element(name: "TYPE", cdata: mimeType))
            photo.addChild(Element(name: "BINVAL", cdata: image.base64EncodedString()))
            card.addChild(photo)
        }
        do {
            _ = try await client.context.writer.write(iq: OutboundStanza.vCard(card, of: room))
        } catch let error as XMPPError {
            throw Self.groupError(error)
        }
        // Shown at once, instead of when the room's notice of it arrives.
        try database.setAvatarHash(hash, for: room)
    }

    private static func groupError(_ error: XMPPError) -> Error {
        switch error.errorCondition {
        case .service_unavailable, .feature_not_implemented, .item_not_found: GroupError.unsupported
        case .forbidden, .not_allowed: GroupError.notAllowed
        default: error
        }
    }

    // MARK: Destroying

    /// Deletes the group for everyone (XEP-0045 §10.9). Our chat ends up as
    /// the other members' do: kept for its history, marked left, with its
    /// bookmark gone. The room's destruction comes first, as a bookmark
    /// removed from a group that then stays would only be a lost bookmark.
    public func destroyGroup(_ room: JID, reason: String? = nil) async throws {
        guard try joinedStatus(room).canDestroy else { throw GroupError.notAllowed }
        _ = try await client.context.writer.write(iq: OutboundStanza.destroy(room, reason: reason))
        groupDestroyed(room)
    }
}
