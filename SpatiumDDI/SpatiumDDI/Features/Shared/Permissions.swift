//
//  Permissions.swift
//  SpatiumDDI
//

import Foundation
import SpatiumAPI

/// What this account is granted, as the control plane reports it.
///
/// **This is UX, not security** — non-negotiable #4. The server enforces every
/// one of these independently and will return a 403 regardless of what the app
/// decided to show. Hiding an Allocate button from someone who cannot allocate
/// saves them a pointless round trip; it does not stop anybody doing anything,
/// and every write path still handles a 403 honestly rather than assuming this
/// check already ruled it out.
///
/// The grammar is `docs/PERMISSIONS.md` in the platform repo: an entry is
/// `{action, resource_type, resource_id?}`, `admin` implies read + write +
/// delete for its type, `*` matches any action, and an entry with no
/// `resource_id` covers every instance of the type.
@MainActor
@Observable
final class Permissions {
    private(set) var isSuperadmin = false
    private(set) var grants: [Components.Schemas.PermissionGrant] = []
    /// Whether the grant list was actually read.
    private(set) var isKnown = false

    /// Who this account *is*, which some rules turn on as much as the grants.
    ///
    /// Identity sits here rather than in a screen because the rules that need
    /// it are permission rules wearing a different hat: the platform refuses a
    /// self-approval on a change request no matter what the approver holds. An
    /// app that cannot compare the two can only find that out by being told
    /// 409 after the operator has already decided.
    private(set) var userID: String?

    init() {}

    /// A known grant list, for previews and tests.
    init(isSuperadmin: Bool, grants: [Components.Schemas.PermissionGrant], userID: String? = nil) {
        self.isSuperadmin = isSuperadmin
        self.grants = grants
        self.userID = userID
        self.isKnown = true
    }

    /// Whether this account is the person named by `userID`.
    ///
    /// Answers **false when the app doesn't know** — the opposite of the
    /// fails-open rule below, and deliberately. This gates warnings that say
    /// "you can't decide your own request"; asserting that without knowing who
    /// is signed in would put the words in front of the wrong operator.
    func isMe(_ userID: String?) -> Bool {
        guard let userID, let mine = self.userID, !userID.isEmpty else { return false }
        return userID == mine
    }

    /// Whether a write of `resourceType` should be offered.
    ///
    /// Fails **open**. An unread grant list means the app doesn't know, and the
    /// honest response to not knowing is to let the operator try and let the
    /// server answer — a 403 with a reason beats a button that silently isn't
    /// there, which looks like the feature was never built.
    func canWrite(_ resourceTypes: String..., id: String? = nil) -> Bool {
        guard isKnown else { return true }
        if isSuperadmin { return true }
        return resourceTypes.contains { allows(action: "write", type: $0, id: id) }
    }

    /// Whether an action other than `write` should be offered.
    ///
    /// Same fails-open rule as `canWrite`. Not every action in the grammar is
    /// a write: deciding a change request needs `{approve, change_request}`,
    /// which no amount of write access on the underlying resource implies.
    func can(_ action: String, on resourceType: String, id: String? = nil) -> Bool {
        guard isKnown else { return true }
        if isSuperadmin { return true }
        return allows(action: action, type: resourceType, id: id)
    }

    /// Whether an operation the platform reserves for superadmins — no grant
    /// confers it — should be offered.
    ///
    /// Same fails-open rule as `canWrite`. `is_superadmin` is the platform's
    /// *effective* answer (the legacy flag or a `{*, *}` role), so there is
    /// nothing in the grant list left to inspect.
    var canDoSuperadminOnly: Bool {
        !isKnown || isSuperadmin
    }

    private func allows(action: String, type: String, id: String?) -> Bool {
        grants.contains { grant in
            guard grant.resourceType == type else { return false }
            // A grant scoped to one UUID says nothing about any other row.
            if let scoped = grant.resourceId, !scoped.isEmpty, scoped != id { return false }
            switch grant.action {
            case action, "*", "admin": return true
            default: return false
            }
        }
    }

    func load(from session: ControlPlaneSession) async {
        // Two calls, run together: the grant list and who is holding it. Both
        // are best-effort — a failure here leaves `isKnown` false, which means
        // every affordance stays visible and the server decides.
        async let grantList = session.client.getMyPermissionsApiV1AuthMePermissionsGet()
        async let identity = session.client.getMeApiV1AuthMeGet()

        if case .ok(let ok) = try? await identity, let me = try? ok.body.json {
            userID = me.id
        }

        guard case .ok(let ok) = try? await grantList, let permissions = try? ok.body.json else {
            return
        }
        isSuperadmin = permissions.isSuperadmin
        grants = permissions.grants
        isKnown = true
    }
}
