//
//  DNSServersView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// The resolvers behind a DNS group.
///
/// Parity with the DHCP side, which has had a server screen since Phase 1. The
/// asymmetry was doing real damage: "is DHCP still handing out addresses" could
/// be answered from a phone and "is the resolver still answering" could not,
/// even though the second is the one that takes the whole estate down when the
/// answer is no.
struct DNSServersView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.ServerGroupResponse

    @State private var state: LoadState<[Components.Schemas.AppApiV1DnsRouterServerResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(
                state: state,
                emptyMessage: "This group has no servers.",
                retry: { Task { await fetch() } }
            ) { servers in
                ForEach(servers, id: \.id) { server in
                    NavigationLink {
                        DNSServerDetailView(session: session, group: group, server: server)
                    } label: {
                        DNSServerRow(server: server)
                    }
                }
            }
        }
        .navigationTitle("DNS Servers")
        .navigationBarTitleDisplayMode(.inline)
        .breadcrumbs([group.name])
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .listServersApiV1DnsGroupsGroupIdServersGet(path: .init(groupId: group.id))
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    // Primaries first: on a group with one primary and three
                    // secondaries, the primary is the one whose health decides
                    // whether anything can be changed.
                    ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name)
                }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct DNSServerRow: View {
    let server: Components.Schemas.AppApiV1DnsRouterServerResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(server.name)
                Spacer()
                if server.isPrimary { Badge(localised: "primary", tint: .indigo) }
                if server.maintenanceMode == true { Badge(localised: "maintenance", tint: .orange) }
                StatusLabel(status: server.status)
            }
            Text("\(server.host):\(String(server.port)) · \(server.driver)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if !server.roles.isEmpty {
                Text(verbatim: server.roles.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One resolver: whether it is answering, and what it has been asked.
struct DNSServerDetailView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.ServerGroupResponse
    let server: Components.Schemas.AppApiV1DnsRouterServerResponse

    @State private var window: MetricsWindow = .day
    @State private var series: LoadState<Components.Schemas.DNSTimeseries> = .idle
    @State private var events: LoadState<[Components.Schemas.ServerEventEntry]> = .idle

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Status") { StatusLabel(status: server.status) }
                LabeledContent("Driver", value: server.driver)
                LabeledContent("Address", value: "\(server.host):\(String(server.port))")
                LabeledContent("Enabled", value: server.isEnabled ? "Yes" : "No")
                if !server.roles.isEmpty {
                    LabeledContent("Roles", value: server.roles.joined(separator: ", "))
                }
                LabeledContent("Last seen", value: Date.relativeOrNever(server.lastSeenAt))
                LabeledContent("Last sync", value: Date.relativeOrNever(server.lastSyncAt))

                // A configuration the server refused matters more than any of
                // the above: the control plane's idea of the zone and the
                // resolver's have diverged, and only one of them is answering
                // queries.
                if let status = server.configApplyStatus, status.lowercased() != "ok" {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The last configuration push did not apply.")
                            if let error = server.configApplyError, !error.isEmpty {
                                Text(verbatim: error).font(.caption)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Window", selection: $window) {
                    ForEach(MetricsWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))

                switch series {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .loaded(let series):
                    LabeledContent("Queries") {
                        Text(series.totalQueries.formatted()).monospacedDigit()
                    }
                    TrafficChart(
                        volume: series.queries,
                        volumeLabel: String(localized: "Queries"),
                        volumeTint: .indigo,
                        problem: series.failures,
                        problemLabel: String(localized: "SERVFAIL"),
                        problemTint: .red,
                        accessibilitySummary: String(
                            localized:
                                "\(series.totalQueries) queries to \(server.name) over \(String(localized: window.spokenName)), of which \(series.totalServfail) failed."
                        )
                    )
                    if series.totalNXDomain > 0 || series.totalServfail > 0 {
                        Text(
                            "^[\(series.totalNXDomain) NXDOMAIN](inflect: true) · ^[\(series.totalServfail) SERVFAIL](inflect: true)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Query rate")
            } footer: {
                Text("Only this server's share of the group's traffic.")
            }

            Section("Recent events") {
                LoadStateView(
                    state: events,
                    emptyMessage: "Nothing has been recorded for this server.",
                    retry: { Task { await fetchEvents() } }
                ) { rows in
                    ForEach(rows.prefix(20), id: \.id) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: event.action).font(.subheadline)
                                Spacer()
                                Badge(
                                    text: event.result,
                                    tint: event.result.lowercased() == "success" ? .green : .red
                                )
                            }
                            Text(event.timestamp.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .breadcrumbs([group.name])
        .refreshable { await refresh() }
        .task(id: window) { await fetchSeries() }
        .task { if case .idle = events { await fetchEvents() } }
    }

    private func refresh() async {
        async let a: Void = fetchSeries()
        async let b: Void = fetchEvents()
        _ = await (a, b)
    }

    private func fetchSeries() async {
        series = .loading
        series = await LoadState.fetching {
            let response = try await session.client.dnsTimeseriesApiV1MetricsDnsTimeseriesGet(
                query: .init(serverId: server.id, window: window.rawValue)
            )
            switch response {
            case .ok(let ok): return try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchEvents() async {
        events = .loading
        events = await LoadState.fetching {
            let response = try await session.client
                .getServerRecentEventsApiV1DnsServersServerIdRecentEventsGet(
                    path: .init(serverId: server.id)
                )
            switch response {
            case .ok(let ok): return try ok.body.json.items
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
