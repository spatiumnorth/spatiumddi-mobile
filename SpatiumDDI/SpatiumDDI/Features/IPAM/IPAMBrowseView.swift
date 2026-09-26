//
//  IPAMBrowseView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// IPAM browse: space → block → subnet → address.
///
/// Read all the way down; the one write is taking an address in a subnet, and
/// it lives behind an explicit sheet with its own confirmation. Every row here
/// is still a navigation, not an action.
struct IPAMBrowseView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.IPSpaceResponse]> = .idle

    var body: some View {
        List {
            Section {
                NavigationLink {
                    StaleAddressesView(session: session)
                } label: {
                    Label("Stale Addresses", systemImage: "clock.badge.exclamationmark")
                }
                NavigationLink {
                    HygieneReportView(session: session)
                } label: {
                    Label("Address Hygiene", systemImage: "stethoscope")
                }
                NavigationLink {
                    VendorRollupView(session: session)
                } label: {
                    Label("Vendors", systemImage: "shippingbox")
                }
            } header: {
                Text("Reports")
            } footer: {
                Text(
                    "Addresses nothing has answered for; where IPAM and the network disagree; and whose hardware is out there."
                )
            }

            LoadStateView(state: state, emptyMessage: "No IP spaces are defined on this server.", retry: load)
            { spaces in
                ForEach(spaces, id: \.id) { space in
                    NavigationLink {
                        IPAMBlocksView(session: session, space: space)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(space.name)
                                if space.isDefault {
                                    Text("DEFAULT")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                }
                            }
                            if !space.description.isEmpty {
                                Text(space.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("IP Spaces")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            // Switched rather than `.ok`: the shorthand collapses every status
            // the document doesn't declare — 401, 403, 503 — into an opaque
            // runtime error, and non-negotiable #4 says those must be shown for
            // what they are.
            switch try await session.client.listSpacesApiV1IpamSpacesGet() {
            case .ok(let ok):
                return try ok.body.json
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Blocks within a space.
struct IPAMBlocksView: View {
    let session: ControlPlaneSession
    let space: Components.Schemas.IPSpaceResponse

    @State private var state: LoadState<[Components.Schemas.IPBlockResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "This space has no blocks.", retry: load) { blocks in
                ForEach(blocks, id: \.id) { block in
                    NavigationLink {
                        IPAMSubnetsView(session: session, block: block, trail: [space.name])
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.network).font(.body.monospaced())
                            if block.name != block.network, !block.name.isEmpty {
                                Text(block.name).font(.caption).foregroundStyle(.secondary)
                            }
                            UtilisationBar(percent: block.utilizationPercent)
                            if let allocated = block.allocatedIps, let total = block.totalIps {
                                // `formattedAddressCount` rather than raw: an
                                // IPv6 block's total comes back clamped to
                                // Int64.max, and printing that as an address
                                // count states a number that is not real.
                                Text(
                                    "\(allocated.formatted()) of \(total.formattedAddressCount) addresses"
                                )
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            // Filtered by the server: `/ipam/blocks` takes a `space_id`, and an
            // estate's worth of blocks is not something to pull down and discard
            // on a phone. The client-side filter stays as a backstop in case the
            // server ever ignores the parameter.
            let response = try await session.client.listBlocksApiV1IpamBlocksGet(
                query: .init(spaceId: space.id)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json.filter { $0.spaceId == space.id }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Subnets within a block.
struct IPAMSubnetsView: View {
    let session: ControlPlaneSession
    let block: Components.Schemas.IPBlockResponse
    /// The space this block was reached through.
    var trail: [String] = []

    @State private var state: LoadState<[Components.Schemas.SubnetResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "This block has no subnets.", retry: load) { subnets in
                ForEach(subnets, id: \.id) { subnet in
                    NavigationLink {
                        IPAMAddressesView(
                            session: session, subnet: subnet, trail: trail + [block.network]
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(subnet.network).font(.body.monospaced())
                                Spacer()
                                if let vlan = subnet.vlanId {
                                    Text("VLAN \(vlan)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if !subnet.name.isEmpty {
                                Text(subnet.name).font(.caption).foregroundStyle(.secondary)
                            }
                            UtilisationBar(percent: subnet.utilizationPercent)
                        }
                    }
                }
            }
        }
        .navigationTitle(block.network)
        .navigationBarTitleDisplayMode(.inline)
        .breadcrumbs(trail)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listSubnetsApiV1IpamSubnetsGet(
                query: .init(blockId: block.id)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json.filter { $0.blockId == block.id }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Addresses within a subnet.
struct IPAMAddressesView: View {
    let session: ControlPlaneSession
    let subnet: Components.Schemas.SubnetResponse
    /// The space and block this subnet was reached through.
    var trail: [String] = []

    @State private var state: LoadState<[Components.Schemas.IPAddressResponse]> = .idle
    @State private var query = ""
    @State private var isAllocating = false
    @State private var isEditing = false
    /// The subnet as last saved, when this screen has changed it.
    ///
    /// The row that got here is a copy the parent list still holds, so an edit
    /// has to be reflected locally or the screen keeps showing the old name
    /// under a sheet that just succeeded.
    @State private var edited: Components.Schemas.SubnetResponse?
    @State private var history: LoadState<[Components.Schemas.UtilizationHistoryPoint]> = .idle
    @Environment(Permissions.self) private var permissions

    private var current: Components.Schemas.SubnetResponse { edited ?? subnet }

    private var visible: [Components.Schemas.IPAddressResponse] {
        guard case .loaded(let addresses) = state else { return [] }
        guard !query.isEmpty else { return addresses }
        return addresses.filter {
            $0.address.localizedCaseInsensitiveContains(query)
                || ($0.hostname ?? "").localizedCaseInsensitiveContains(query)
                || ($0.fqdn ?? "").localizedCaseInsensitiveContains(query)
                || ($0.macAddress ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Network", value: current.network)
                if !current.name.isEmpty { LabeledContent("Name", value: current.name) }
                if let gateway = current.gateway { LabeledContent("Gateway", value: gateway) }
                LabeledContent("Status", value: current.status)
                LabeledContent("Utilisation") {
                    Text(
                        "\(current.allocatedIps.formatted()) / \(current.totalIps.formattedAddressCount)"
                    )
                }
                if !current.description.isEmpty {
                    Text(verbatim: current.description).font(.caption).foregroundStyle(.secondary)
                }
                // Beside the fields it edits rather than in the bar, which is
                // where the one thing an operator comes here to *do* lives.
                if permissions.canWrite("subnet", id: subnet.id) {
                    Button("Edit Subnet Details") { isEditing = true }
                }
            }

            Section {
                switch history {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .loaded(let points):
                    UtilisationTrendChart(points: points)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Utilisation over 90 days")
            } footer: {
                Text("Whether this subnet is filling up, or has always looked like this.")
            }

            Section("Addresses") {
                LoadStateView(
                    state: state, emptyMessage: "No addresses are recorded in this subnet.", retry: load
                ) { _ in
                    if visible.isEmpty {
                        NoMatchesView(
                            query: query,
                            filterDescription: "No address matches that IP, hostname or MAC."
                        )
                    } else {
                        ForEach(visible, id: \.id) { address in
                            NavigationLink {
                                IPAMAddressDetailView(
                                    session: session,
                                    address: address,
                                    subnet: current,
                                    trail: trail + [current.network],
                                    onChanged: { Task { await fetch() } }
                                )
                            } label: {
                                AddressRow(address: address)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(current.name.isEmpty ? current.network : current.name)
        .navigationBarTitleDisplayMode(.inline)
        .breadcrumbs(trail)
        .searchable(text: $query, prompt: "Filter by IP, hostname or MAC")
        .dismissableKeyboard()
        .refreshable { await refresh() }
        .task { if case .idle = state { await refresh() } }
        .toolbar {
            // Hidden from an account with no write grant as a courtesy. The
            // server enforces this independently — non-negotiable #4 — and the
            // sheet still reports a 403 honestly if the gate here was wrong.
            if permissions.canWrite("subnet", "ip_address", id: subnet.id) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAllocating = true
                    } label: {
                        Label("Allocate Address", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isAllocating) {
            AllocateAddressView(
                session: session,
                subnet: current,
                onCreated: { _ in
                    // Refetched rather than inserted locally. The row the
                    // server returns is pre-enrichment — no `fqdn`, no vendor,
                    // no pool membership — so splicing it in would show a
                    // freshly created address as the one row missing the
                    // details every other row has.
                    Task { await fetch() }
                },
                onDismiss: { isAllocating = false }
            )
        }
        .sheet(isPresented: $isEditing) {
            EditSubnetView(
                session: session,
                subnet: current,
                onSaved: { edited = $0 },
                onDismiss: { isEditing = false }
            )
        }
    }

    private func load() { Task { await refresh() } }

    private func refresh() async {
        async let a: Void = fetch()
        async let b: Void = fetchHistory()
        _ = await (a, b)
    }

    /// Occupancy over time. Its own state, not folded into the address fetch:
    /// a control plane that has never sampled this subnet still has addresses
    /// worth showing, so a missing trend is not a failure of the screen.
    private func fetchHistory() async {
        history = .loading
        history = await LoadState.fetching {
            let response = try await session.client
                .getSubnetUtilizationHistoryApiV1IpamSubnetsSubnetIdUtilizationHistoryGet(
                    path: .init(subnetId: subnet.id),
                    query: .init(days: 90)
                )
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted { $0.sampledAt < $1.sampledAt }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .listAddressesApiV1IpamSubnetsSubnetIdAddressesGet(path: .init(subnetId: subnet.id))
            switch response {
            case .ok(let ok):
                return try ok.body.json
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// One row in the address list.
private struct AddressRow: View {
    let address: Components.Schemas.IPAddressResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(address.address).font(.body.monospaced())
                Spacer()
                Text(address.status).font(.caption2).foregroundStyle(.secondary)
            }
            // An unnamed address comes back as "" rather than null, so `??`
            // alone would hide an fqdn that is present.
            if let name = [address.hostname, address.fqdn]
                .compactMap({ $0 }).first(where: { !$0.isEmpty })
            {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if let mac = address.macAddress, !mac.isEmpty {
                Text(mac).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
    }
}
