//
//  DHCPBrowseView.swift
//  SpatiumDDI
//

import Charts
import SpatiumAPI
import SwiftUI

/// DHCP root: the servers that answer, and the scopes they serve.
///
/// Servers come first deliberately. The question that takes an operator to DHCP
/// on a phone is almost always "is it still handing out addresses", and that is
/// a server-health question before it is a scope question.
struct DHCPBrowseView: View {
    let session: ControlPlaneSession

    @State private var servers: LoadState<[Components.Schemas.AppApiV1DhcpServersServerResponse]> = .idle
    @State private var groups: LoadState<[Components.Schemas.AppApiV1DhcpServerGroupsGroupResponse]> = .idle

    var body: some View {
        List {
            Section("Servers") {
                LoadStateView(
                    state: servers,
                    emptyMessage: "No DHCP servers are registered.",
                    retry: { Task { await fetchServers() } }
                ) { servers in
                    ForEach(servers, id: \.id) { server in
                        NavigationLink {
                            DHCPServerDetailView(session: session, server: server)
                        } label: {
                            DHCPServerRow(server: server)
                        }
                    }
                }
            }

            Section("Scopes by group") {
                LoadStateView(
                    state: groups,
                    emptyMessage: "No DHCP server groups are defined.",
                    retry: { Task { await fetchGroups() } }
                ) { groups in
                    ForEach(groups, id: \.id) { group in
                        NavigationLink {
                            DHCPScopesView(session: session, group: group)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.name)
                                HStack(spacing: 6) {
                                    Badge(text: group.mode, tint: .teal)
                                    if group.autoFailover { Badge(localised: "auto-failover") }
                                    if let members = group.keaMemberCount {
                                        Text("^[\(members) member](inflect: true)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("DHCP")
        .refreshable { await refresh() }
        .task {
            if case .idle = servers { await refresh() }
        }
    }

    private func refresh() async {
        // Independent endpoints; serialising them would double the wait for no
        // benefit, and neither depends on the other's result.
        async let a: Void = fetchServers()
        async let b: Void = fetchGroups()
        _ = await (a, b)
    }

    private func fetchServers() async {
        servers = .loading
        servers = await LoadState.fetching {
            switch try await session.client.listServersApiV1DhcpServersGet() {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchGroups() async {
        groups = .loading
        groups = await LoadState.fetching {
            switch try await session.client.listGroupsApiV1DhcpServerGroupsGet() {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct DHCPServerRow: View {
    let server: Components.Schemas.AppApiV1DhcpServersServerResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.name)
                Spacer()
                StatusLabel(status: server.status)
            }
            Text("\(server.host):\(server.port)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Badge(text: server.driver, tint: .teal)
                if let ha = server.haState, !ha.isEmpty { Badge(text: "HA \(ha)") }
                if server.maintenanceMode == true { Badge(localised: "maintenance", tint: .orange) }
                if server.isReadOnly { Badge(localised: "read-only") }
            }
        }
    }
}

/// One DHCP server: health, the last hour of traffic, and its leases.
struct DHCPServerDetailView: View {
    let session: ControlPlaneSession
    let server: Components.Schemas.AppApiV1DhcpServersServerResponse

    @State private var stats: LoadState<Components.Schemas.DHCPServerStatsResponse> = .idle
    @State private var leases: LoadState<[Components.Schemas.LeaseResponse]> = .idle
    @State private var leaseTotal = 0
    @State private var pendingLeaseDelete: DeleteLeaseModel?
    @Environment(Permissions.self) private var permissions

    private var mayDeleteLeases: Bool {
        permissions.canWrite("dhcp_server", "dhcp_scope", id: server.id)
    }
    @State private var query = ""

    private var visibleLeases: [Components.Schemas.LeaseResponse] {
        guard case .loaded(let leases) = leases else { return [] }
        guard !query.isEmpty else { return leases }
        return leases.filter {
            $0.ipAddress.localizedCaseInsensitiveContains(query)
                || $0.macAddress.localizedCaseInsensitiveContains(query)
                || ($0.hostname ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Status") { StatusLabel(status: server.status) }
                LabeledContent("Endpoint", value: "\(server.host):\(server.port)")
                LabeledContent("Driver", value: server.driver)
                if !server.roles.isEmpty {
                    LabeledContent("Roles", value: server.roles.joined(separator: ", "))
                }
                if let ha = server.haState, !ha.isEmpty {
                    LabeledContent("HA state", value: ha)
                    LabeledContent("HA heartbeat", value: Date.relativeOrNever(server.haLastHeartbeatAt))
                }
                LabeledContent("Health check", value: Date.relativeOrNever(server.lastHealthCheckAt))
                if !server.isAgentless {
                    LabeledContent("Agent", value: server.agentVersion ?? "unknown")
                    LabeledContent("Agent seen", value: Date.relativeOrNever(server.agentLastSeen))
                }
            }

            // A rolled-back config is the failure that looks healthy: the daemon
            // is up and answering, just not with what the control plane holds.
            if let applyStatus = server.configApplyStatus, applyStatus.lowercased() != "ok" {
                Section("Configuration") {
                    LabeledContent("Apply status") { StatusLabel(status: applyStatus) }
                    if let error = server.configApplyError, !error.isEmpty {
                        Text(error).font(.caption.monospaced()).foregroundStyle(.red)
                    }
                }
            }

            if server.maintenanceMode == true {
                Section {
                    Label(
                        server.maintenanceReason.map { $0.isEmpty ? "In maintenance." : $0 }
                            ?? "In maintenance.",
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Traffic") {
                LoadStateView(
                    state: stats,
                    emptyMessage: "No traffic statistics.",
                    retry: { Task { await fetchStats() } }
                ) { stats in
                    LabeledContent("Active leases", value: stats.leasesActive.formatted())
                    LeaseRateChart(stats: stats)
                }
            }

            Section {
                LoadStateView(
                    state: leases,
                    emptyMessage: "This server is not holding any leases.",
                    retry: { Task { await fetchLeases() } }
                ) { _ in
                    if visibleLeases.isEmpty {
                        NoMatchesView(
                            query: query,
                            filterDescription: "No lease matches that address, MAC or hostname."
                        )
                    } else {
                        ForEach(visibleLeases, id: \.id) { lease in
                            LeaseRow(lease: lease)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if mayDeleteLeases {
                                        Button(role: .destructive) {
                                            pendingLeaseDelete = DeleteLeaseModel(
                                                session: session, serverID: server.id, lease: lease
                                            )
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }
            } header: {
                if case .loaded(let loaded) = leases, leaseTotal > loaded.count {
                    Text("Leases — showing \(loaded.count) of \(leaseTotal)")
                } else {
                    Text("Leases")
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filter by IP, hostname or MAC")
        .dismissableKeyboard()
        .refreshable { await refresh() }
        .task { if case .idle = stats { await refresh() } }
        .sheet(item: $pendingLeaseDelete) { model in
            DeleteConfirmationSheet(
                subject: model.subject,
                title: "Delete this lease?",
                consequence: model.consequence,
                caution: model.caution,
                failure: model.failure,
                isDeleting: model.isDeleting,
                onDelete: {
                    Task {
                        if await model.delete() {
                            pendingLeaseDelete = nil
                            await fetchLeases()
                        }
                    }
                },
                onCancel: { pendingLeaseDelete = nil }
            )
        }
    }

    private func refresh() async {
        async let a: Void = fetchStats()
        async let b: Void = fetchLeases()
        _ = await (a, b)
    }

    private func fetchStats() async {
        stats = .loading
        stats = await LoadState.fetching {
            let response = try await session.client
                .getServerStatsApiV1DhcpServersServerIdStatsGet(path: .init(serverId: server.id))
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

    private func fetchLeases() async {
        leases = .loading
        leases = await LoadState.fetching {
            let response = try await session.client
                .listLeasesApiV1DhcpServersServerIdLeasesGet(
                    path: .init(serverId: server.id),
                    query: .init(page: 1, pageSize: 300)
                )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                leaseTotal = page.total
                return page.items
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// The last hour of DHCP message rate.
///
/// ACK and NAK only. The full seven counters make an unreadable chart at phone
/// width, and these are the two that answer "are clients getting addresses" —
/// a NAK line lifting off zero is the shape worth spotting.
private struct LeaseRateChart: View {
    let stats: Components.Schemas.DHCPServerStatsResponse

    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 120

    /// The numbers, not just what the chart is of: "a chart of NAKs" tells a
    /// VoiceOver user nothing about whether there were any.
    private var descriptor: TimeSeriesChartDescriptor {
        let acks = stats.rateBuckets.reduce(0) { $0 + $1.ack }
        let naks = stats.rateBuckets.reduce(0) { $0 + $1.nak }
        return TimeSeriesChartDescriptor(
            title: String(localized: "DHCP acknowledgements and refusals"),
            summary: String(
                localized: "\(acks) acknowledgements and \(naks) refusals over the last \(stats.range)."),
            valueTitle: String(localized: "Count"),
            series: [
                .init(name: "ACK", points: stats.rateBuckets.map { ($0.ts, Double($0.ack)) }),
                .init(name: "NAK", points: stats.rateBuckets.map { ($0.ts, Double($0.nak)) }),
            ]
        )
    }

    private var isSilent: Bool {
        stats.rateBuckets.allSatisfy { $0.ack == 0 && $0.nak == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSilent {
                Text("No DHCP traffic in the last \(stats.range).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(stats.rateBuckets, id: \.ts) { bucket in
                        AreaMark(x: .value("Time", bucket.ts), y: .value("ACK", bucket.ack))
                            .foregroundStyle(by: .value("Kind", "ACK"))
                    }
                    ForEach(stats.rateBuckets, id: \.ts) { bucket in
                        LineMark(x: .value("Time", bucket.ts), y: .value("NAK", bucket.nak))
                            .foregroundStyle(by: .value("Kind", "NAK"))
                    }
                }
                .chartForegroundStyleScale(["ACK": Color.green, "NAK": Color.red])
                .chartLegend(.visible)
                .frame(height: height)
                .chartAccessibility(descriptor)
            }
        }
    }
}

private struct LeaseRow: View {
    let lease: Components.Schemas.LeaseResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(lease.ipAddress).font(.body.monospaced())
                Spacer()
                Badge(text: lease.state, tint: lease.state.lowercased() == "active" ? .green : .secondary)
            }
            Text(lease.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let hostname = lease.hostname, !hostname.isEmpty {
                Text(hostname).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                // The fingerprinted device class is the fastest way to tell what
                // is actually on an address you did not expect to be leased.
                if let deviceClass = lease.deviceClass, !deviceClass.isEmpty { Text(deviceClass) }
                if let vendor = lease.vendor, !vendor.isEmpty { Text(vendor) }
                if let expires = lease.expiresAt {
                    Text("expires \(expires.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// Scopes within a DHCP server group.
struct DHCPScopesView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.AppApiV1DhcpServerGroupsGroupResponse

    @State private var state: LoadState<[Components.Schemas.ScopeResponse]> = .idle

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MACBlocksView(session: session, group: group)
                } label: {
                    Label("Blocked MACs", systemImage: "nosign")
                }
            }

            LoadStateView(state: state, emptyMessage: "This group has no scopes.", retry: load) { scopes in
                ForEach(scopes, id: \.id) { scope in
                    NavigationLink {
                        DHCPScopeDetailView(session: session, scope: scope, trail: [group.name])
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(scope.name ?? "Unnamed scope")
                                Spacer()
                                if !scope.enabled { Badge(localised: "disabled", tint: .orange) }
                            }
                            if let description = scope.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Badge(text: scope.addressFamily ?? "ipv4", tint: .teal)
                                Text("lease \(Duration.seconds(scope.leaseTime).formattedCompact)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if scope.ddnsEnabled { Badge(localised: "DDNS", tint: .green) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .listScopesForGroupApiV1DhcpServerGroupsGroupIdScopesGet(path: .init(groupId: group.id))
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// One scope: its settings, the subnet it serves, its pools and its reservations.
struct DHCPScopeDetailView: View {
    let session: ControlPlaneSession
    let scope: Components.Schemas.ScopeResponse
    /// The server group this scope was reached through.
    var trail: [String] = []

    @State private var subnet: Components.Schemas.SubnetResponse?
    @State private var pools: LoadState<[Components.Schemas.AppApiV1DhcpPoolsPoolResponse]> = .idle
    @State private var statics: LoadState<[Components.Schemas.StaticResponse]> = .idle
    @State private var isAddingReservation = false
    @State private var pendingReservationDelete: DeleteReservationModel?
    @Environment(Permissions.self) private var permissions

    /// Whether this scope hands anything out dynamically.
    ///
    /// `nil` until the pools are known, which is the honest third answer:
    /// deleting a reservation means something different in a scope with a pool
    /// than in one without, and guessing which is worse than saying so.
    private var hasPool: Bool? {
        guard case .loaded(let pools) = pools else { return nil }
        return !pools.isEmpty
    }

    private var mayEditReservations: Bool {
        permissions.canWrite("dhcp_static", "dhcp_scope", "dhcp_server", id: scope.id)
    }

    var body: some View {
        List {
            Section("Scope") {
                // The scope carries a subnet id but no CIDR, and a scope without
                // its network is close to meaningless on a phone — so the subnet
                // is resolved rather than left as a UUID.
                if let subnet {
                    LabeledContent("Network", value: subnet.network)
                    if let gateway = subnet.gateway { LabeledContent("Gateway", value: gateway) }
                    UtilisationBar(percent: subnet.utilizationPercent)
                }
                LabeledContent("Enabled", value: scope.enabled ? "Yes" : "No")
                LabeledContent("Address family", value: scope.addressFamily ?? "ipv4")
                LabeledContent("Lease time", value: Duration.seconds(scope.leaseTime).formattedCompact)
                if let minimum = scope.minLeaseTime {
                    LabeledContent("Min lease", value: Duration.seconds(minimum).formattedCompact)
                }
                if let maximum = scope.maxLeaseTime {
                    LabeledContent("Max lease", value: Duration.seconds(maximum).formattedCompact)
                }
                LabeledContent("Dynamic DNS", value: scope.ddnsEnabled ? "Enabled" : "Disabled")
                if let relays = scope.relayAddresses, !relays.isEmpty {
                    LabeledContent("Relays", value: relays.joined(separator: ", "))
                }
                if scope.raEnabled == true {
                    LabeledContent("Router advertisements", value: "Enabled")
                }
                LabeledContent("Last pushed", value: Date.relativeOrNever(scope.lastPushedAt))
            }

            Section("Pools") {
                LoadStateView(
                    state: pools,
                    emptyMessage: "This scope has no pools — it hands out nothing dynamically.",
                    retry: { Task { await fetchPools() } }
                ) { pools in
                    ForEach(pools, id: \.id) { pool in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(pool.startIp) – \(pool.endIp)").font(.body.monospaced())
                            HStack(spacing: 6) {
                                if !pool.name.isEmpty {
                                    Text(pool.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Badge(text: pool.poolType, tint: .teal)
                                if let restriction = pool.classRestriction, !restriction.isEmpty {
                                    Badge(text: restriction, tint: .purple)
                                }
                            }
                        }
                    }
                }
            }

            Section("Reservations") {
                LoadStateView(
                    state: statics,
                    emptyMessage: "This scope has no static reservations.",
                    retry: { Task { await fetchStatics() } }
                ) { statics in
                    ForEach(statics, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.ipAddress).font(.body.monospaced())
                                Spacer()
                                if !entry.hostname.isEmpty {
                                    Text(entry.hostname).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.macAddress).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if mayEditReservations {
                                Button(role: .destructive) {
                                    pendingReservationDelete = DeleteReservationModel(
                                        session: session, entry: entry, hasPool: hasPool
                                    )
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(scope.name ?? "Scope")
        .breadcrumbs(trail)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { if case .idle = pools { await refresh() } }
        .toolbar {
            if mayEditReservations {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingReservation = true
                    } label: {
                        Label("Add Reservation", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingReservation) {
            CreateReservationView(
                session: session,
                scope: scope,
                network: subnet?.network,
                // Refetched rather than spliced: the server fills in the IPAM
                // link and the resolved address id, so the created row is not
                // the row the list will show a second later.
                onCreated: { _ in Task { await fetchStatics() } },
                onDismiss: { isAddingReservation = false }
            )
        }
        .sheet(item: $pendingReservationDelete) { model in
            DeleteConfirmationSheet(
                subject: model.subject,
                title: "Delete this reservation?",
                consequence: model.consequence,
                caution: model.caution,
                failure: model.failure,
                isDeleting: model.isDeleting,
                onDelete: {
                    Task {
                        if await model.delete() {
                            pendingReservationDelete = nil
                            await fetchStatics()
                        }
                    }
                },
                onCancel: { pendingReservationDelete = nil }
            )
        }
    }

    private func refresh() async {
        async let a: Void = fetchSubnet()
        async let b: Void = fetchPools()
        async let c: Void = fetchStatics()
        _ = await (a, b, c)
    }

    private func fetchSubnet() async {
        // Best-effort context, not the point of the screen: if it fails the
        // scope's own settings are still worth showing, so this one does not
        // become a failure state for the whole view.
        let response = try? await session.client
            .getSubnetApiV1IpamSubnetsSubnetIdGet(path: .init(subnetId: scope.subnetId))
        if case .ok(let ok) = response { subnet = try? ok.body.json }
    }

    private func fetchPools() async {
        pools = .loading
        pools = await LoadState.fetching {
            let response = try await session.client
                .listPoolsApiV1DhcpScopesScopeIdPoolsGet(path: .init(scopeId: scope.id))
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

    private func fetchStatics() async {
        statics = .loading
        statics = await LoadState.fetching {
            let response = try await session.client
                .listStaticsApiV1DhcpScopesScopeIdStaticsGet(path: .init(scopeId: scope.id))
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    $0.ipAddress.localizedStandardCompare($1.ipAddress) == .orderedAscending
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
