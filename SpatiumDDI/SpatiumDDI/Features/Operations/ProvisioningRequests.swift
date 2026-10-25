//
//  ProvisioningRequests.swift
//  SpatiumDDI
//

import Foundation
import OpenAPIRuntime
import SwiftUI

/// The pure half of self-service requests (platform #696): which states the
/// list offers, how it orders them, who may decide one, and what a request is
/// asking for in an operator's terms.
///
/// Kept apart from the views for the same reason `ChangeRequestRules` is — a
/// rule only exercised by tapping through a screen is one nobody exercises.

// MARK: - States

/// The lifecycle the platform gives a request, as the filter offers it.
///
/// The same seven states as a change request (the two share one table and one
/// approval spine server-side), but read differently: approving a request
/// *provisions* something, so `executed` is what the requester was waiting
/// for and the web portal calls it "provisioned". The app follows it.
nonisolated enum ProvisioningRequestState {
    /// The filter chips, in the web portal's order. `approved` is left out on
    /// purpose: it is transient — a row passes through it on the way to
    /// `executed` or `failed` inside one request — so filtering on it shows
    /// nothing, and the web leaves it out for the same reason.
    static let filters = ["pending", "executed", "rejected", "failed", "cancelled", "expired"]

    /// The state's name as the operator reads it.
    static func label(_ state: String) -> LocalizedStringResource? {
        switch state.lowercased() {
        case "pending": "Pending"
        case "approved": "Approved"
        case "executed": "Provisioned"
        case "rejected": "Rejected"
        case "failed": "Failed"
        case "cancelled": "Cancelled"
        case "expired": "Expired"
        default: nil
        }
    }

    static func tint(_ state: String) -> Color {
        switch state.lowercased() {
        case "pending": .orange
        case "approved": .blue
        case "executed": .green
        case "rejected", "failed": .red
        default: .secondary
        }
    }

    static func isPending(_ state: String) -> Bool {
        state.caseInsensitiveCompare("pending") == .orderedSame
    }

    /// Pending first, the one about to lapse at the top — it is the one that
    /// needs a decision soonest. Everything else newest first, which is the
    /// order the server returns and the order "what happened to mine" is
    /// answered in.
    ///
    /// Only matters under "All": a single-state filter returns one group.
    static func sorted<Row>(
        _ rows: [Row],
        state: (Row) -> String,
        created: (Row) -> Date,
        expires: (Row) -> Date
    ) -> [Row] {
        rows.sorted { lhs, rhs in
            let lhsPending = isPending(state(lhs))
            let rhsPending = isPending(state(rhs))
            if lhsPending != rhsPending { return lhsPending }
            if lhsPending { return expires(lhs) < expires(rhs) }
            return created(lhs) > created(rhs)
        }
    }
}

// MARK: - Who may decide

/// Who may approve, reject or withdraw a request — and why not.
///
/// Every rule is the server's (`services/approvals/service.py` in the platform
/// repo, reached through `api/v1/requests/router.py`), restated so the app can
/// say before the tap what the server would say after it. UX, not security —
/// non-negotiable #4: the server re-checks all of it.
///
/// The one rule a change request does not have is the second grant on
/// approve. A request provisions something the *requester* could not, so the
/// approver must hold the operation's own permission as well as
/// `{approve, change_request}` — approving a subnet request needs
/// `{write, subnet}`. Without that check here, an approver with the approve
/// grant alone would read the case, decide, and only then be told 403.
nonisolated enum ProvisioningRequestRules {
    enum Block: Equatable {
        /// Already decided, or lapsed. Carries the state as the server spells it.
        case settled(String)
        /// Still `pending`, but its deadline has passed. The server expires it
        /// on an approve attempt rather than running it; a reject still lands.
        case lapsed
        /// The requester's account is gone. The platform refuses to approve an
        /// orphaned request — the two-person check would pass vacuously.
        case orphaned
        /// Your own request: approving defeats the two-person rule, and
        /// rejecting it is withdrawing.
        case ownRequest
        /// No `{approve, change_request}` grant.
        case noGrant
        /// The approve grant, but not the operation's own permission.
        case missingGrant(action: String, resourceType: String)
        /// Withdrawing is the requester's move, or a superadmin's.
        case notYours
    }

    /// The operation's own permission, which the approver must also hold.
    ///
    /// The four operations the platform's catalog maps request kinds onto
    /// (`services/requests/catalog.py`), with the `required_permission` each
    /// registers in `services/ai/operations.py`. An operation not listed here
    /// is not gated client-side — the server still checks it, and guessing a
    /// grant would hide a button from someone entitled to it.
    static func requiredPermission(
        forOperation operation: String
    ) -> (action: String, resourceType: String)? {
        switch operation {
        case "allocate_subnet": ("write", "subnet")
        case "create_ip_address": ("write", "ip_address")
        case "create_dns_record": ("write", "dns_record")
        case "create_dhcp_static": ("write", "dhcp_static")
        default: nil
        }
    }

    /// Why Approve is not offered, or `nil` when it is.
    ///
    /// Ordered as the server checks: state, deadline, orphan, self, grant.
    /// - Parameters:
    ///   - mayDecide: holds `{approve, change_request}`.
    ///   - mayRunOperation: holds the operation's own permission (see
    ///     `requiredPermission(forOperation:)`); pass `true` when there is none.
    static func blocksApproving(
        state: String,
        expiresAt: Date,
        now: Date = .now,
        hasRequester: Bool,
        isRequester: Bool,
        mayDecide: Bool,
        mayRunOperation: Bool,
        operation: String
    ) -> Block? {
        if !ProvisioningRequestState.isPending(state) { return .settled(state) }
        if expiresAt <= now { return .lapsed }
        if !hasRequester { return .orphaned }
        if isRequester { return .ownRequest }
        if !mayDecide { return .noGrant }
        if !mayRunOperation, let needed = requiredPermission(forOperation: operation) {
            return .missingGrant(action: needed.action, resourceType: needed.resourceType)
        }
        return nil
    }

    /// Why Reject is not offered, or `nil` when it is.
    ///
    /// Looser than approving: no deadline check, no orphan check and no
    /// operation grant — declining provisions nothing, so the server asks only
    /// for `{approve, change_request}` and a different person.
    static func blocksRejecting(
        state: String, isRequester: Bool, mayDecide: Bool
    ) -> Block? {
        if !ProvisioningRequestState.isPending(state) { return .settled(state) }
        if isRequester { return .ownRequest }
        if !mayDecide { return .noGrant }
        return nil
    }

    /// Why Withdraw is not offered, or `nil` when it is.
    static func blocksCancelling(
        state: String, isRequester: Bool, isSuperadmin: Bool
    ) -> Block? {
        if !ProvisioningRequestState.isPending(state) { return .settled(state) }
        if !isRequester && !isSuperadmin { return .notYours }
        return nil
    }
}

// MARK: - What it asks for

/// A request's frozen arguments, flattened to the scalars a screen can show.
///
/// The payload is an open object on the wire — its shape is the backing
/// operation's own args model — so the generated client can only hand it over
/// as a container of `Any`. This is the one place that is turned into text.
nonisolated enum ProvisioningArgs {
    static func flatten(_ container: OpenAPIObjectContainer) -> [String: String] {
        container.value.reduce(into: [:]) { flat, entry in
            if let text = scalarText(entry.value) { flat[entry.key] = text }
        }
    }

    /// Text for one JSON scalar, or nil for null, nested values and blanks.
    ///
    /// `Bool` is tested before the numeric types because Foundation will
    /// bridge `true` to the number 1, and a status reading "1" is a lie.
    private static func scalarText(_ value: (any Sendable)?) -> String? {
        switch value {
        case let bool as Bool: return bool ? "true" : "false"
        case let int as Int: return String(int)
        case let double as Double:
            return double.rounded() == double ? String(Int(double)) : String(double)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return nil
        }
    }
}

/// What a request would create, in the terms an operator reads.
///
/// The server's `preview_text` names the parent — the subnet, the zone, the
/// scope — because only the server can resolve the UUIDs in the payload, and
/// the screens show it verbatim. This is the other half: the thing itself,
/// lifted out of the payload so it can be read at a glance and quoted in a
/// confirmation, rather than dug out of a comma-joined sentence.
nonisolated struct ProvisioningSummary: Equatable {
    /// One labelled value. `label` is nil when the key is not one this app
    /// knows, and the screen then shows the server's own key verbatim.
    struct Field: Equatable {
        let label: LocalizedStringResource?
        let key: String
        let value: String
    }

    /// What kind of thing, in this app's words. Nil for an operation this app
    /// doesn't know — the screen falls back to the server's resource type.
    let kind: LocalizedStringResource?
    /// The thing itself: an address, a size, a record line. Server values only.
    let headline: String
    /// The record as it would be written, for a DNS request.
    let zoneFileLine: String?
    let fields: [Field]

    init(operation: String, args: [String: String], result: [String: String] = [:]) {
        switch operation {
        case "create_ip_address":
            kind = "IP address"
            headline = args["address"] ?? ""
            zoneFileLine = nil
            fields = Self.pick(
                args,
                [
                    ("address", "Address"), ("status", "Status"), ("hostname", "Hostname"),
                    ("fqdn", "FQDN"), ("mac_address", "MAC address"), ("description", "Description"),
                ])
        case "allocate_subnet":
            kind = "Subnet"
            // Executed, the size has become a network — the carve the
            // requester was waiting for. Before that it is only a size: which
            // CIDR it lands on is decided under the block lock at approve.
            let carved = result["network"]
            headline = carved ?? args["prefix_len"].map { "/" + $0 } ?? ""
            zoneFileLine = nil
            var picked: [Field] = []
            if let carved { picked.append(Field(label: "Network", key: "network", value: carved)) }
            if let size = args["prefix_len"] {
                picked.append(Field(label: "Size", key: "prefix_len", value: "/" + size))
            }
            fields = picked + Self.pick(args, [("name", "Name"), ("description", "Description")])
        case "create_dns_record":
            kind = "DNS record"
            let line = Self.zoneFileLine(args)
            headline = line
            zoneFileLine = line
            fields = Self.pick(
                args,
                [
                    ("name", "Name"), ("record_type", "Type"), ("value", "Value"), ("ttl", "TTL"),
                    ("priority", "Priority"), ("weight", "Weight"), ("port", "Port"),
                ])
        case "create_dhcp_static":
            kind = "DHCP reservation"
            headline = [args["ip_address"], args["mac_address"]]
                .compactMap { $0 }
                .joined(separator: " → ")
            zoneFileLine = nil
            fields = Self.pick(
                args,
                [
                    ("ip_address", "Address"), ("mac_address", "MAC address"),
                    ("hostname", "Hostname"), ("description", "Description"),
                ])
        default:
            // Something newer than this build. Show every scalar under the
            // server's own key rather than pretend to understand it; the
            // UUID-valued references are dropped as unreadable noise, and the
            // preview text names what they point at.
            kind = nil
            headline = ""
            zoneFileLine = nil
            fields = args.keys.sorted()
                .filter { !$0.hasSuffix("_id") }
                .compactMap { key in args[key].map { Field(label: nil, key: key, value: $0) } }
        }
    }

    /// The fields that are present, in the given order.
    private static func pick(
        _ args: [String: String], _ keys: [(String, LocalizedStringResource)]
    ) -> [Field] {
        keys.compactMap { key, label in
            args[key].map { Field(label: label, key: key, value: $0) }
        }
    }

    /// `name  ttl  TYPE  priority weight port value` — the same order and
    /// spacing the create-record confirmation uses, so a record reads the same
    /// on both paths. The name is relative: the payload carries the zone's
    /// UUID, not its name, and the preview text alongside names the zone.
    static func zoneFileLine(_ args: [String: String]) -> String {
        let type = args["record_type"]?.uppercased() ?? ""
        var line = "\(args["name"] ?? "@")  "
        if let ttl = args["ttl"] { line += "\(ttl)  " }
        line += "\(type)  "
        if let priority = args["priority"], ["MX", "SRV"].contains(type) { line += "\(priority) " }
        if type == "SRV" {
            if let weight = args["weight"] { line += "\(weight) " }
            if let port = args["port"] { line += "\(port) " }
        }
        line += args["value"] ?? ""
        return line
    }
}
