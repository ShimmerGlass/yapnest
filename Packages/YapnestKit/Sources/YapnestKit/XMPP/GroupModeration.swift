import Foundation

/// Who may act on whom in a room (XEP-0045 §5.2, §9 and §10). The room has
/// the last word; this keeps us from offering what it would refuse, and from
/// sending it.
public enum GroupModeration {
    public struct MemberActions: Equatable, Sendable {
        /// Takes membership away, which also removes them from a members-only room.
        public var canRemove = false
        public var canBan = false
        /// Lets a banned member come back, as an ordinary non-member.
        public var canUnban = false
        public var canMakeAdmin = false
        public var canRemoveAdmin = false
        public var canMakeOwner = false
        /// Gives ownership up, to admin. For ourselves this is the one thing
        /// we may do to ourselves, unless we're the last owner.
        public var canRemoveOwner = false
        /// Puts an occupant out of the room for now, keeping their membership.
        public var canKick = false

        public init() {}

        public var isEmpty: Bool { self == MemberActions() }
    }

    /// What someone with affiliation `actor` may do to a member with
    /// `target`. Nobody acts on themselves, except that an owner may step down
    /// while another owner remains: leaving is another action.
    ///
    /// Owners may change anyone's affiliation. Admins may only add and remove
    /// members and ban those below admin, never touching an owner or another
    /// admin (§10.5). Members and the rest have no say.
    ///
    /// A kick (§8.2) needs `actorRole` moderator and a target who is
    /// present, and the target's affiliation must be below the actor's, so a
    /// moderator never removes someone of equal or higher standing.
    public static func actions(
        by actor: RoomAffiliation, on target: RoomAffiliation, isSelf: Bool = false,
        isLastOwner: Bool = true, actorRole: String? = nil, targetIsPresent: Bool = false,
    ) -> MemberActions {
        var actions = MemberActions()
        guard !isSelf else {
            actions.canRemoveOwner = actor == .owner && !isLastOwner
            return actions
        }
        switch actor {
        case .owner:
            actions.canRemove = target.isMember
            actions.canBan = target != .outcast
            actions.canUnban = target == .outcast
            actions.canMakeAdmin = target == .member
            actions.canRemoveAdmin = target == .admin
            actions.canMakeOwner = target == .member || target == .admin
            actions.canRemoveOwner = target == .owner
        case .admin:
            actions.canRemove = target == .member
            actions.canBan = target == .member || target == .none
            actions.canUnban = target == .outcast
        case .member, .none, .outcast:
            break
        }
        actions.canKick = actorRole == "moderator" && targetIsPresent && target != .outcast && rank(target) < rank(actor)
        return actions
    }

    private static func rank(_ affiliation: RoomAffiliation) -> Int {
        switch affiliation {
        case .owner: 3
        case .admin: 2
        case .member: 1
        case .none, .outcast: 0
        }
    }
}
