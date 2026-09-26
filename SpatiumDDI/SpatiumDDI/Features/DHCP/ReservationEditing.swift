//
//  ReservationEditing.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// The writes an operator makes **standing next to the machine**.
///
/// Phase 2's writes were chosen for the operator away from the estate —
/// approvals, alert triage, allocating an address. These are the opposite case:
/// the phone is not a fallback console, it is the nearest keyboard, and the MAC
/// is on a label six inches from your face.
///
/// What is deliberately *not* here is as much of the point: scope and pool
/// configuration, client classes, option templates and PXE are all desk work,
/// either because the form is the size of a laptop screen or because the blast
/// radius deserves one.

// MARK: - Creating a reservation

/// "This MAC gets this IP" — the canonical rack-side write.
struct CreateReservationView: View {
    let session: ControlPlaneSession
    let scope: Components.Schemas.ScopeResponse
    /// The network this scope serves, when it could be resolved. Used to say
    /// which subnet the address has to fall inside — the server enforces it,
    /// and finding that out from a 422 is a worse way to learn it.
    let network: String?
    let onCreated: (Components.Schemas.StaticResponse) -> Void
    let onDismiss: () -> Void

    @State private var mac = ""
    @State private var ip = ""
    @State private var hostname = ""
    @State private var notes = ""
    @State private var isConfirming = false
    @State private var isSending = false
    @State private var failure: FailureMessage?

    private var trimmedMAC: String { mac.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedIP: String { ip.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHostname: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Save is off, said near the field at fault rather than left to be
    /// guessed at from a greyed-out button.
    private var blocker: LocalizedStringResource? {
        if trimmedMAC.isEmpty { return "A MAC address is what the reservation matches on." }
        if !MACAddress.looksValid(trimmedMAC) {
            return "That doesn't look like a MAC address — six pairs of hex digits."
        }
        if trimmedIP.isEmpty { return "An address is what the reservation hands out." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Scope", value: scope.name ?? String(localized: "Unnamed scope"))
                    if let network { LabeledContent("Network", value: network) }
                } footer: {
                    if let network {
                        Text("The address has to be inside \(network) — the server refuses anything else.")
                    }
                }

                Section {
                    TextField("aa:bb:cc:dd:ee:ff", text: $mac)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced())
                    TextField("10.1.0.50", text: $ip)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced())
                } header: {
                    Text("Reservation")
                } footer: {
                    if let blocker {
                        Label(blocker, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Whenever that MAC asks, this scope answers with that address.")
                    }
                }

                Section {
                    TextField("Host name (optional)", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Description (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Identity")
                } footer: {
                    Text("A description is worth the seconds — the next person here will be reading it.")
                }

                if let failure {
                    Section("Not created") {
                        Label(failure, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Reservation")
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Save") { isConfirming = true }
                            .disabled(blocker != nil)
                    }
                }
            }
            .alert("Create this reservation?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await create() } }
            } message: {
                Text(verbatim: summary)
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    /// The reservation in the terms the operator will check it against — the
    /// MAC and the address, not "are you sure".
    private var summary: String {
        var lines = ["\(trimmedMAC) → \(trimmedIP)"]
        if !trimmedHostname.isEmpty { lines.append(trimmedHostname) }
        lines.append(
            String(
                localized:
                    "Pushed to the DHCP servers in this group. The device picks it up at its next renewal, not immediately."
            )
        )
        return lines.joined(separator: "\n\n")
    }

    private func create() async {
        isSending = true
        failure = nil
        defer { isSending = false }

        do {
            let response = try await session.client
                .createStaticApiV1DhcpScopesScopeIdStaticsPost(
                    path: .init(scopeId: scope.id),
                    body: .json(
                        .init(
                            description: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                            hostname: trimmedHostname,
                            ipAddress: trimmedIP,
                            macAddress: trimmedMAC
                        ))
                )
            switch response {
            case .created(let created):
                onCreated(try created.body.json)
                onDismiss()
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            // `StaticCreate` carries no `force`, so a soft conflict here has
            // nothing to re-send with and is never offered as waivable.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }
}

/// Whether something looks like a MAC address before the server is asked.
///
/// Deliberately permissive about separators — colons, hyphens, dots, or none —
/// because a MAC gets copied out of a switch, a lease table or a sticker and
/// arrives in whichever shape that source uses. What it does insist on is
/// twelve hex digits, which is the part a typo actually breaks.
nonisolated enum MACAddress {
    static func looksValid(_ text: String) -> Bool {
        let digits = text.filter { !":-. ".contains($0) }
        return digits.count == 12 && digits.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Removing a reservation

/// Deleting a static assignment.
@MainActor
@Observable
final class DeleteReservationModel: Identifiable {
    let id = UUID()
    private(set) var isDeleting = false
    private(set) var failure: FailureMessage?

    private let session: ControlPlaneSession
    let entry: Components.Schemas.StaticResponse
    /// Whether the scope has any pool to fall back to, when that is known.
    /// Decides which of two genuinely different outcomes the copy describes.
    let hasPool: Bool?

    init(
        session: ControlPlaneSession,
        entry: Components.Schemas.StaticResponse,
        hasPool: Bool?
    ) {
        self.session = session
        self.entry = entry
        self.hasPool = hasPool
    }

    /// Typed as the address, which is what the row leads with.
    var subject: String { entry.ipAddress }

    var consequence: LocalizedStringResource {
        switch hasPool {
        case true:
            """
            That MAC stops being pinned to this address. At its next renewal it \
            gets whatever the pool hands out instead, which will not be this \
            address.
            """
        case false:
            """
            That MAC stops being pinned to this address, and this scope has no \
            pool to fall back on — so at its next renewal the device gets \
            nothing at all.
            """
        default:
            """
            That MAC stops being pinned to this address. What it gets at its \
            next renewal depends on whether this scope has a pool.
            """
        }
    }

    var caution: FailureMessage? {
        guard !entry.hostname.isEmpty else { return nil }
        return .server(entry.hostname)
    }

    func delete() async -> Bool {
        isDeleting = true
        failure = nil
        defer { isDeleting = false }
        do {
            let response = try await session.client
                .deleteStaticApiV1DhcpStaticsStaticIdDelete(path: .init(staticId: entry.id))
            switch response {
            case .noContent: return true
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
            return false
        }
    }
}

// MARK: - Removing a lease

/// Deleting a live lease.
///
/// The consequence here is genuinely surprising and so it is spelled out: the
/// server forgets the lease, but **the client does not**. A device holds its
/// address until its own timer runs down, so for that window the address is
/// free as far as the server is concerned and still in use as far as the
/// network is concerned. That is how a duplicate address happens, and an
/// operator deleting a lease one-handed on a train is entitled to know it
/// before rather than after.
@MainActor
@Observable
final class DeleteLeaseModel: Identifiable {
    let id = UUID()
    private(set) var isDeleting = false
    private(set) var failure: FailureMessage?

    private let session: ControlPlaneSession
    private let serverID: String
    let lease: Components.Schemas.LeaseResponse

    init(
        session: ControlPlaneSession,
        serverID: String,
        lease: Components.Schemas.LeaseResponse
    ) {
        self.session = session
        self.serverID = serverID
        self.lease = lease
    }

    var subject: String { lease.ipAddress }

    var consequence: LocalizedStringResource {
        """
        The server forgets this lease and may hand the address to something \
        else. The device holding it does not find out — it keeps using the \
        address until its own timer expires.
        """
    }

    var caution: FailureMessage? {
        var parts: [String] = [lease.macAddress]
        if let hostname = lease.hostname, !hostname.isEmpty { parts.append(hostname) }
        return .server(parts.joined(separator: " · "))
    }

    func delete() async -> Bool {
        isDeleting = true
        failure = nil
        defer { isDeleting = false }
        do {
            let response = try await session.client
                .deleteLeaseApiV1DhcpServersServerIdLeasesLeaseIdDelete(
                    path: .init(serverId: serverID, leaseId: lease.id)
                )
            switch response {
            case .noContent: return true
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
            return false
        }
    }
}

// MARK: - Blocked MACs

/// MACs this server group refuses to answer.
///
/// Typed-gated in both directions, which is unusual and deliberate. Blocking is
/// an availability decision about a device you may be misreading — the MAC on
/// the sticker and the MAC in the lease table are not always the same device —
/// and unblocking silently readmits something somebody blocked on purpose.
/// Neither belongs on a single tap.
struct MACBlocksView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.AppApiV1DhcpServerGroupsGroupResponse

    @Environment(Permissions.self) private var permissions

    @State private var state: LoadState<[Components.Schemas.MACBlockResponse]> = .idle
    @State private var isAdding = false
    @State private var pendingRemoval: PendingUnblock?
    @State private var isRemoving = false
    @State private var failure: FailureMessage?

    private var mayChange: Bool {
        permissions.canWrite("dhcp_mac_block", "dhcp_server_group", "dhcp_server")
    }

    var body: some View {
        List {
            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: "No MAC is blocked in this group.",
                    retry: { Task { await fetch() } }
                ) { blocks in
                    ForEach(blocks, id: \.id) { block in
                        MACBlockRow(block: block)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if mayChange {
                                    Button(role: .destructive) {
                                        failure = nil
                                        pendingRemoval = PendingUnblock(block: block)
                                    } label: {
                                        Label("Unblock", systemImage: "lock.open")
                                    }
                                }
                            }
                    }
                }
            } header: {
                Text("Blocked")
            } footer: {
                Text(
                    "A blocked MAC gets no address from any server in this group. It is not a firewall rule — the device can still use a static address."
                )
            }

            if let failure {
                Section("Not changed") {
                    Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Blocked MACs")
        .navigationBarTitleDisplayMode(.inline)
        .breadcrumbs([group.name])
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
        .toolbar {
            if mayChange {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        failure = nil
                        isAdding = true
                    } label: {
                        Label("Block a MAC", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            BlockMACView(
                session: session,
                group: group,
                onCreated: { _ in Task { await fetch() } },
                onDismiss: { isAdding = false }
            )
        }
        .sheet(item: $pendingRemoval) { pending in
            let block = pending.block
            DeleteConfirmationSheet(
                subject: block.macAddress,
                title: "Unblock this MAC?",
                consequence:
                    "It can take an address from this group again, at its next request.",
                caution: block.reason.isEmpty ? nil : .server(block.reason),
                failure: failure,
                isDeleting: isRemoving,
                onDelete: { Task { await unblock(block) } },
                onCancel: { pendingRemoval = nil }
            )
        }
    }

    private func unblock(_ block: Components.Schemas.MACBlockResponse) async {
        isRemoving = true
        failure = nil
        defer { isRemoving = false }
        do {
            let response = try await session.client
                .deleteMacBlockApiV1DhcpMacBlocksBlockIdDelete(path: .init(blockId: block.id))
            switch response {
            case .noContent:
                if case .loaded(let rows) = state {
                    state = .loaded(rows.filter { $0.id != block.id })
                }
                pendingRemoval = nil
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .listMacBlocksApiV1DhcpServerGroupsGroupIdMacBlocksGet(path: .init(groupId: group.id))
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted { $0.createdAt > $1.createdAt }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// The block waiting on its typed confirmation.
///
/// Wrapped because the generated row types are not `Identifiable`. Keyed on the
/// block's own id rather than a fresh `UUID`, so a re-render cannot look like a
/// different sheet and re-present it.
private struct PendingUnblock: Identifiable {
    let block: Components.Schemas.MACBlockResponse
    var id: String { block.id }
}

private struct MACBlockRow: View {
    let block: Components.Schemas.MACBlockResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(block.macAddress).font(.body.monospaced())
                Spacer()
                if !block.enabled { Badge(localised: "not enforced", tint: .secondary) }
                if block.matchCount > 0 {
                    // Not inflection Markdown: a badge renders verbatim, so
                    // "^[3 hit](inflect: true)" would reach the screen as-is.
                    Badge(
                        localised: block.matchCount == 1 ? "1 hit" : "\(block.matchCount) hits",
                        tint: .orange)
                }
            }
            if let vendor = block.vendor, !vendor.isEmpty {
                Text(vendor).font(.caption).foregroundStyle(.secondary)
            }
            if !block.reason.isEmpty {
                Text(block.reason).font(.caption).foregroundStyle(.secondary)
            }
            // What this MAC is known to hold in IPAM. The single most useful
            // thing to see before unblocking something: it names what comes
            // back on the network.
            if let matches = block.ipamMatches, !matches.isEmpty {
                ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                    Text(verbatim: "\(match.ipAddress) · \(match.subnetCidr)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Text("blocked \(block.createdAt.formatted(.relative(presentation: .named)))")
                if let last = block.lastMatchAt {
                    Text("last tried \(last.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// Blocking a MAC, behind the same typed gate a delete gets.
private struct BlockMACView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.AppApiV1DhcpServerGroupsGroupResponse
    let onCreated: (Components.Schemas.MACBlockResponse) -> Void
    let onDismiss: () -> Void

    /// The server's own vocabulary, not this app's invention.
    private static let reasons: [Components.Schemas.MACBlockCreate.ReasonPayload] = [
        .rogue, .lostStolen, .quarantine, .policy, .other,
    ]

    @State private var mac = ""
    @State private var reason: Components.Schemas.MACBlockCreate.ReasonPayload = .rogue
    @State private var notes = ""
    @State private var isConfirming = false
    @State private var isSending = false
    @State private var failure: FailureMessage?

    private var trimmedMAC: String { mac.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var blocker: LocalizedStringResource? {
        if trimmedMAC.isEmpty { return "A MAC address is what gets blocked." }
        if !MACAddress.looksValid(trimmedMAC) {
            return "That doesn't look like a MAC address — six pairs of hex digits."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("aa:bb:cc:dd:ee:ff", text: $mac)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced())
                } header: {
                    Text("MAC address")
                } footer: {
                    if let blocker {
                        Label(blocker, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Every DHCP server in \(group.name) will refuse it.")
                    }
                }

                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(Self.reasons, id: \.self) { reason in
                            Text(verbatim: Self.label(for: reason)).tag(reason)
                        }
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text("The reason is recorded against the block, and read by whoever finds it later.")
                }

                if let failure {
                    Section("Not blocked") {
                        Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Block a MAC")
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Save") { isConfirming = true }
                            .disabled(blocker != nil)
                    }
                }
            }
            .alert("Block this MAC?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Block It", role: .destructive) { Task { await create() } }
            } message: {
                Text(
                    verbatim:
                        "\(trimmedMAC)\n\n"
                        + String(
                            localized:
                                "It gets no address from \(group.name) from now on. A device already holding a lease keeps it until that lease expires."
                        )
                )
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private static func label(for reason: Components.Schemas.MACBlockCreate.ReasonPayload) -> String {
        switch reason {
        case .rogue: String(localized: "Rogue device")
        case .lostStolen: String(localized: "Lost or stolen")
        case .quarantine: String(localized: "Quarantine")
        case .policy: String(localized: "Policy")
        case .other: String(localized: "Other")
        }
    }

    private func create() async {
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            let response = try await session.client
                .createMacBlockApiV1DhcpServerGroupsGroupIdMacBlocksPost(
                    path: .init(groupId: group.id),
                    body: .json(
                        .init(
                            description: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                            enabled: true,
                            macAddress: trimmedMAC,
                            reason: reason
                        ))
                )
            switch response {
            case .created(let created):
                onCreated(try created.body.json)
                onDismiss()
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }
}
