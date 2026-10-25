//
//  ProvisioningRequestTests.swift
//  SpatiumDDITests
//

import Foundation
import OpenAPIRuntime
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// Who the app offers a decision on a self-service request to.
///
/// The rules are the platform's approval spine, restated. The one that differs
/// from a change request is the second grant on approve: a request provisions
/// something its requester could not, so the approver must also hold the
/// operation's own permission.
@Suite("Self-service request rules")
struct ProvisioningRequestRuleTests {
    private let future = Date.now.addingTimeInterval(3600)

    private func approveBlock(
        state: String = "pending",
        expiresAt: Date? = nil,
        hasRequester: Bool = true,
        isRequester: Bool = false,
        mayDecide: Bool = true,
        mayRunOperation: Bool = true,
        operation: String = "create_ip_address"
    ) -> ProvisioningRequestRules.Block? {
        ProvisioningRequestRules.blocksApproving(
            state: state,
            expiresAt: expiresAt ?? future,
            hasRequester: hasRequester,
            isRequester: isRequester,
            mayDecide: mayDecide,
            mayRunOperation: mayRunOperation,
            operation: operation
        )
    }

    @Test("A pending request from someone else, with both grants, is approvable")
    func approvable() {
        #expect(approveBlock() == nil)
    }

    @Test("Your own request is never yours to decide")
    func ownRequest() {
        #expect(approveBlock(isRequester: true) == .ownRequest)
        #expect(
            ProvisioningRequestRules.blocksRejecting(
                state: "pending", isRequester: true, mayDecide: true
            ) == .ownRequest
        )
    }

    @Test("Deciding needs the approve grant on change requests")
    func noGrant() {
        #expect(approveBlock(mayDecide: false) == .noGrant)
        #expect(
            ProvisioningRequestRules.blocksRejecting(
                state: "pending", isRequester: false, mayDecide: false
            ) == .noGrant
        )
    }

    /// The approve grant alone is not enough to provision: approving a subnet
    /// request needs `{write, subnet}`. Rejecting provisions nothing, so it
    /// stays on offer.
    @Test("Approving also needs the operation's own permission; rejecting doesn't")
    func operationGrant() {
        #expect(
            approveBlock(mayRunOperation: false, operation: "allocate_subnet")
                == .missingGrant(action: "write", resourceType: "subnet")
        )
        #expect(
            ProvisioningRequestRules.blocksRejecting(
                state: "pending", isRequester: false, mayDecide: true
            ) == nil
        )
    }

    /// An operation this build doesn't know has no grant to name, so the app
    /// leaves it to the server rather than hide the button on a guess.
    @Test("An unknown operation is not gated on a guessed grant")
    func unknownOperation() {
        #expect(approveBlock(mayRunOperation: false, operation: "something_newer") == nil)
    }

    @Test(
        "Each catalogued operation names the grant the platform registers for it",
        arguments: [
            ("allocate_subnet", "subnet"),
            ("create_ip_address", "ip_address"),
            ("create_dns_record", "dns_record"),
            ("create_dhcp_static", "dhcp_static"),
        ])
    func requiredPermissions(operation: String, resourceType: String) {
        let needed = ProvisioningRequestRules.requiredPermission(forOperation: operation)
        #expect(needed?.action == "write")
        #expect(needed?.resourceType == resourceType)
    }

    /// The server expires a lapsed-but-pending row on an approve attempt and
    /// answers 409. A reject of the same row still lands.
    @Test("A pending request past its deadline can be rejected but not approved")
    func lapsed() {
        let past = Date.now.addingTimeInterval(-60)
        #expect(approveBlock(expiresAt: past) == .lapsed)
        #expect(
            ProvisioningRequestRules.blocksRejecting(
                state: "pending", isRequester: false, mayDecide: true
            ) == nil
        )
    }

    /// The two-person check would pass vacuously with no requester, so the
    /// platform fails closed.
    @Test("A request whose requester was deleted can't be approved")
    func orphaned() {
        #expect(approveBlock(hasRequester: false) == .orphaned)
    }

    @Test(
        "A settled request reports its state, not a permission problem",
        arguments: ["approved", "executed", "rejected", "failed", "expired", "cancelled"])
    func settled(state: String) {
        #expect(approveBlock(state: state, isRequester: true, mayDecide: false) == .settled(state))
        #expect(
            ProvisioningRequestRules.blocksRejecting(
                state: state, isRequester: true, mayDecide: false
            ) == .settled(state)
        )
        #expect(
            ProvisioningRequestRules.blocksCancelling(
                state: state, isRequester: true, isSuperadmin: true
            ) == .settled(state)
        )
    }

    @Test("Only the requester, or a superadmin, may withdraw")
    func withdrawing() {
        #expect(
            ProvisioningRequestRules.blocksCancelling(
                state: "pending", isRequester: true, isSuperadmin: false
            ) == nil
        )
        #expect(
            ProvisioningRequestRules.blocksCancelling(
                state: "pending", isRequester: false, isSuperadmin: true
            ) == nil
        )
        #expect(
            ProvisioningRequestRules.blocksCancelling(
                state: "pending", isRequester: false, isSuperadmin: false
            ) == .notYours
        )
    }

    @Test("Pending is recognised whatever its casing", arguments: ["pending", "Pending", "PENDING"])
    func pendingCasing(state: String) {
        #expect(approveBlock(state: state) == nil)
    }
}

/// The gate the detail screen actually asks, through `Permissions`.
@MainActor
@Suite("Self-service request gating")
struct ProvisioningRequestGatingTests {
    private func grant(_ action: String, _ type: String) -> Components.Schemas.PermissionGrant {
        .init(action: action, resourceId: nil, resourceType: type)
    }

    private func mayApprove(_ permissions: Permissions, operation: String) -> Bool {
        let needed = ProvisioningRequestRules.requiredPermission(forOperation: operation)
        return ProvisioningRequestRules.blocksApproving(
            state: "pending",
            expiresAt: .now.addingTimeInterval(3600),
            hasRequester: true,
            isRequester: false,
            mayDecide: permissions.can("approve", on: "change_request"),
            mayRunOperation: needed.map { permissions.can($0.action, on: $0.resourceType) } ?? true,
            operation: operation
        ) == nil
    }

    @Test("An approver who can also create the thing may approve it")
    func bothGrants() {
        let permissions = Permissions(
            isSuperadmin: false,
            grants: [grant("approve", "change_request"), grant("write", "dns_record")]
        )
        #expect(mayApprove(permissions, operation: "create_dns_record"))
        #expect(!mayApprove(permissions, operation: "allocate_subnet"))
    }

    /// `admin` on a type implies write, as everywhere else in the grammar.
    @Test("admin on the resource type is enough for the operation grant")
    func adminImpliesWrite() {
        let permissions = Permissions(
            isSuperadmin: false,
            grants: [grant("approve", "change_request"), grant("admin", "subnet")]
        )
        #expect(mayApprove(permissions, operation: "allocate_subnet"))
    }

    /// A Requester holds `provisioning_request` grants only — which confer no
    /// provisioning ability and no decision at all.
    @Test("A Requester is offered no decision")
    func requester() {
        let permissions = Permissions(
            isSuperadmin: false,
            grants: [grant("write", "provisioning_request"), grant("read", "provisioning_request")]
        )
        #expect(!mayApprove(permissions, operation: "create_ip_address"))
    }

    @Test("An unread grant list hides nothing")
    func failsOpen() {
        #expect(mayApprove(Permissions(), operation: "allocate_subnet"))
    }
}

/// Ordering and naming the request states.
@Suite("Self-service request states")
struct ProvisioningRequestStateTests {
    private struct Row: Equatable {
        let id: String
        let state: String
        let created: Date
        let expires: Date
    }

    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: minutes * 60) }

    @Test("Pending first, soonest deadline on top; the rest newest first")
    func ordering() {
        let rows = [
            Row(id: "old-done", state: "executed", created: at(1), expires: at(100)),
            Row(id: "late-pending", state: "pending", created: at(2), expires: at(300)),
            Row(id: "new-done", state: "rejected", created: at(5), expires: at(100)),
            Row(id: "urgent-pending", state: "pending", created: at(3), expires: at(200)),
        ]
        let sorted = ProvisioningRequestState.sorted(
            rows, state: \.state, created: \.created, expires: \.expires
        )
        #expect(sorted.map(\.id) == ["urgent-pending", "late-pending", "new-done", "old-done"])
    }

    /// The web portal calls an executed request "provisioned", because that is
    /// what the requester was waiting for.
    @Test("Executed reads as Provisioned")
    func executedLabel() {
        let label = ProvisioningRequestState.label("executed")
        #expect(label.map { FailureMessage.app($0).englishText } == "Provisioned")
    }

    @Test("A state this build doesn't know has no label of the app's own")
    func unknownLabel() {
        #expect(ProvisioningRequestState.label("on_hold") == nil)
    }

    /// `approved` is transient — a row passes through it within one request —
    /// so a chip for it would only ever show an empty list.
    @Test("The filter offers every terminal state and pending, not the transient one")
    func filters() {
        #expect(ProvisioningRequestState.filters.first == "pending")
        #expect(!ProvisioningRequestState.filters.contains("approved"))
        #expect(Set(ProvisioningRequestState.filters).count == ProvisioningRequestState.filters.count)
    }
}

/// What a request asks for, lifted out of its open payload.
@Suite("Self-service request summaries")
struct ProvisioningSummaryTests {
    /// Decoded the way the generated client decodes the payload.
    private func args(_ json: String) throws -> [String: String] {
        ProvisioningArgs.flatten(try JSONDecoder().decode(OpenAPIObjectContainer.self, from: Data(json.utf8)))
    }

    private func english(_ field: ProvisioningSummary.Field) -> String? {
        field.label.map { FailureMessage.app($0).englishText }
    }

    @Test("Scalars flatten to text; nulls, blanks and nested values drop out")
    func flatten() throws {
        let flat = try args(
            #"{"a": "x", "n": 24, "f": 1.5, "b": true, "z": null, "blank": "  ", "nested": {"k": 1}}"#
        )
        #expect(flat == ["a": "x", "n": "24", "f": "1.5", "b": "true"])
    }

    @Test("An address request leads with the address")
    func ipAddress() throws {
        let summary = ProvisioningSummary(
            operation: "create_ip_address",
            args: try args(
                #"{"subnet_id": "6f1c", "address": "10.0.5.10", "status": "allocated", "hostname": "web01", "description": ""}"#
            )
        )
        #expect(summary.headline == "10.0.5.10")
        #expect(summary.kind.map { FailureMessage.app($0).englishText } == "IP address")
        #expect(summary.fields.map(\.key) == ["address", "status", "hostname"])
        // The subnet is a UUID in the payload; the preview text names it.
        #expect(!summary.fields.contains { $0.value == "6f1c" })
    }

    /// Before approval a subnet request is only a size — the CIDR is chosen
    /// under the block lock. After, it is the network that was carved.
    @Test("A subnet request is a size until it has been carved")
    func subnet() throws {
        let payload = try args(#"{"block_id": "b1", "prefix_len": 24, "name": "lab"}"#)
        let pending = ProvisioningSummary(operation: "allocate_subnet", args: payload)
        #expect(pending.headline == "/24")
        #expect(pending.fields.map(\.key) == ["prefix_len", "name"])

        let carved = ProvisioningSummary(
            operation: "allocate_subnet", args: payload, result: ["network": "10.20.0.0/24"]
        )
        #expect(carved.headline == "10.20.0.0/24")
        #expect(carved.fields.first?.value == "10.20.0.0/24")
    }

    @Test("A DNS request reads as its zone-file line")
    func dnsRecord() throws {
        let summary = ProvisioningSummary(
            operation: "create_dns_record",
            args: try args(
                #"{"zone_id": "z", "name": "mail", "record_type": "mx", "value": "mx1.example.com.", "ttl": 3600, "priority": 10}"#
            )
        )
        #expect(summary.zoneFileLine == "mail  3600  MX  10 mx1.example.com.")
        #expect(summary.headline == summary.zoneFileLine)
    }

    @Test("An SRV line carries priority, weight and port; an A line carries none")
    func srvAndA() {
        #expect(
            ProvisioningSummary.zoneFileLine([
                "name": "_sip._tcp", "record_type": "SRV", "value": "sip.example.com.",
                "priority": "10", "weight": "5", "port": "5060",
            ]) == "_sip._tcp  SRV  10 5 5060 sip.example.com."
        )
        // Priority on an A record is meaningless and must not appear.
        #expect(
            ProvisioningSummary.zoneFileLine([
                "name": "host1", "record_type": "A", "value": "10.0.0.5", "priority": "10",
            ]) == "host1  A  10.0.0.5"
        )
    }

    @Test("A reservation pairs the address with the MAC")
    func reservation() throws {
        let summary = ProvisioningSummary(
            operation: "create_dhcp_static",
            args: try args(
                #"{"scope_id": "s", "ip_address": "10.0.9.20", "mac_address": "aa:bb:cc:dd:ee:ff"}"#
            )
        )
        #expect(summary.headline == "10.0.9.20 → aa:bb:cc:dd:ee:ff")
        #expect(summary.fields.compactMap(english) == ["Address", "MAC address"])
    }

    /// Something newer than this build: shown under the server's own keys,
    /// never presented as a kind the app understands.
    @Test("An unknown operation shows its scalars under the server's keys")
    func unknownOperation() throws {
        let summary = ProvisioningSummary(
            operation: "create_vlan",
            args: try args(#"{"router_id": "r", "vid": 42, "name": "guests"}"#)
        )
        #expect(summary.kind == nil)
        #expect(summary.headline.isEmpty)
        #expect(summary.fields.map(\.key) == ["name", "vid"])
        #expect(summary.fields.allSatisfy { $0.label == nil })
    }
}

/// The confirmation names the thing being written.
@MainActor
@Suite("Self-service request confirmations")
struct ProvisioningConfirmationTests {
    @Test("Approving quotes the subject, the server's preview and who asked")
    func approve() {
        let text = RequestDecisionModel.Decision.approve.consequence(
            subject: "IP address 10.0.5.10",
            preview: "Create IP 10.0.5.10, in subnet 10.0.5.0/24, status=allocated",
            requester: "alice"
        )
        #expect(text.contains("IP address 10.0.5.10"))
        #expect(text.contains("in subnet 10.0.5.0/24"))
        #expect(text.contains("alice"))
    }

    @Test("Rejecting and withdrawing both name the request and say nothing is created")
    func rejectAndCancel() {
        for decision in [RequestDecisionModel.Decision.reject, .cancel] {
            let text = decision.consequence(
                subject: "DNS record mail  MX  10 mx1.example.com.", preview: "", requester: "bob"
            )
            #expect(text.hasPrefix("DNS record mail"))
            #expect(text.contains("Nothing is created."))
        }
    }
}
