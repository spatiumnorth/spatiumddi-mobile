//
//  TrafficSection.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// "What is the traffic doing" — the question the Overview could not answer.
///
/// The app had exactly one chart, built from a DHCP server's own stats, and
/// nothing at all for DNS. So "is the resolver being hammered right now" needed
/// a laptop, which for a screen an operator opens to decide whether something
/// needs them is close to the worst possible gap.
///
/// One window picker drives both charts. Two pickers would let them drift out
/// of step, and the comparison between them — DNS busy while DHCP is silent —
/// is most of the value of having both on one screen.
struct TrafficSection: View {
    let session: ControlPlaneSession

    @State private var window: MetricsWindow = .day
    @State private var dns: LoadState<Components.Schemas.DNSTimeseries> = .idle
    @State private var dhcp: LoadState<Components.Schemas.DHCPTimeseries> = .idle

    var body: some View {
        Section {
            Picker("Window", selection: $window) {
                ForEach(MetricsWindow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))

            LabeledContent("DNS queries") {
                if case .loaded(let series) = dns {
                    Text(series.totalQueries.formatted()).monospacedDigit()
                }
            }
            chart(for: dns) { series in
                TrafficChart(
                    volume: series.queries,
                    volumeLabel: String(localized: "Queries"),
                    volumeTint: .indigo,
                    problem: series.failures,
                    problemLabel: String(localized: "SERVFAIL"),
                    problemTint: .red,
                    accessibilitySummary: dnsSummary(series)
                )
                if series.totalNXDomain > 0 || series.totalServfail > 0 {
                    // Counted rather than plotted. NXDOMAIN is a normal answer
                    // — a name that does not exist — and drawing it beside
                    // SERVFAIL would make an ordinary resolver look sick.
                    Text(
                        "^[\(series.totalNXDomain) NXDOMAIN](inflect: true) · ^[\(series.totalServfail) SERVFAIL](inflect: true)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            LabeledContent("DHCP acknowledgements") {
                if case .loaded(let series) = dhcp {
                    Text(series.totalAck.formatted()).monospacedDigit()
                }
            }
            chart(for: dhcp) { series in
                TrafficChart(
                    volume: series.acks,
                    volumeLabel: String(localized: "ACK"),
                    volumeTint: .green,
                    problem: series.naks,
                    problemLabel: String(localized: "NAK"),
                    problemTint: .red,
                    accessibilitySummary: dhcpSummary(series)
                )
                if series.totalDiscover > 0 {
                    Text("^[\(series.totalDiscover) DISCOVER](inflect: true) in this window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Traffic")
        } footer: {
            Text("Every DNS and DHCP server this control plane knows about, added together.")
        }
        .task(id: window) { await fetch() }
    }

    /// The four states of one chart, in one place so both read the same.
    @ViewBuilder
    private func chart<Series, Content: View>(
        for state: LoadState<Series>,
        @ViewBuilder content: (Series) -> Content
    ) -> some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .loaded(let series):
            content(series)
        case .failed(let message):
            // A module that is switched off, or a grant this account does not
            // hold, both land here — and both are worth saying out loud rather
            // than leaving an empty space where a chart should be.
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func dnsSummary(_ series: Components.Schemas.DNSTimeseries) -> String {
        String(
            localized:
                "\(series.totalQueries) DNS queries over \(String(localized: window.spokenName)), of which \(series.totalServfail) failed and \(series.totalNXDomain) were for names that do not exist."
        )
    }

    private func dhcpSummary(_ series: Components.Schemas.DHCPTimeseries) -> String {
        String(
            localized:
                "\(series.totalAck) DHCP acknowledgements and \(series.totalNak) refusals over \(String(localized: window.spokenName))."
        )
    }

    private func fetch() async {
        // Both together: the point of one window picker is that the two charts
        // describe the same span, and fetching them in series would leave one
        // showing the previous window for as long as the other took.
        async let a: Void = fetchDNS()
        async let b: Void = fetchDHCP()
        _ = await (a, b)
    }

    private func fetchDNS() async {
        dns = .loading
        dns = await LoadState.fetching {
            let response = try await session.client.dnsTimeseriesApiV1MetricsDnsTimeseriesGet(
                query: .init(window: window.rawValue)
            )
            switch response {
            case .ok(let ok): return try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchDHCP() async {
        dhcp = .loading
        dhcp = await LoadState.fetching {
            let response = try await session.client.dhcpTimeseriesApiV1MetricsDhcpTimeseriesGet(
                query: .init(window: window.rawValue)
            )
            switch response {
            case .ok(let ok): return try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// The Top-N report cards, when this control plane has them.
///
/// Gated on `reports.top_n`, which is off by default: without the gate all
/// three sections would render a 404 apiece on most installs, which reads as a
/// broken app rather than a module nobody switched on.
///
/// Top subnets by utilisation is deliberately **not** here — the Overview
/// already builds that list from the IPAM figures it fetches anyway, so adding
/// the report would put the same table on the screen twice.
struct TopReportsSection: View {
    let session: ControlPlaneSession

    @Environment(FeatureModules.self) private var features

    @State private var owners: LoadState<[Components.Schemas.TopOwnerRow]> = .idle
    @State private var modified: LoadState<[Components.Schemas.TopModifiedResourceRow]> = .idle
    @State private var clients: LoadState<[Components.Schemas.TopDNSClientRow]> = .idle

    var body: some View {
        if features.isAvailable("reports.top_n") {
            Section("Busiest DNS clients") {
                LoadStateView(
                    state: clients,
                    emptyMessage: "No client queried in the last day.",
                    retry: { Task { await fetchClients() } }
                ) { rows in
                    ForEach(rows.prefix(5), id: \.clientIp) { row in
                        LabeledContent {
                            Text(row.queryCount.formatted()).monospacedDigit()
                        } label: {
                            Text(row.clientIp).font(.body.monospaced())
                        }
                    }
                }
            }

            Section("Most-changed resources") {
                LoadStateView(
                    state: modified,
                    emptyMessage: "Nothing has been changed recently.",
                    retry: { Task { await fetchModified() } }
                ) { rows in
                    ForEach(rows.prefix(5), id: \.resourceId) { row in
                        LabeledContent {
                            Text(row.changeCount.formatted()).monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                // Server text, so verbatim: a resource display
                                // name is whatever an operator called it.
                                Text(verbatim: row.resourceDisplay).lineLimit(1)
                                Text(verbatim: row.resourceType)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Owners by address count") {
                LoadStateView(
                    state: owners,
                    emptyMessage: "No addresses are attributed to a customer.",
                    retry: { Task { await fetchOwners() } }
                ) { rows in
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        LabeledContent {
                            Text(row.ipCount.formatted()).monospacedDigit()
                        } label: {
                            Text(verbatim: row.customerName).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func fetchClients() async {
        clients = .loading
        clients = await LoadState.fetching {
            switch try await session.client.topDnsClientsApiV1ReportsTopDnsClientsGet() {
            case .ok(let ok): return try ok.body.json.rows
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchModified() async {
        modified = .loading
        modified = await LoadState.fetching {
            switch try await session.client.topModifiedResourcesApiV1ReportsTopModifiedResourcesGet() {
            case .ok(let ok): return try ok.body.json.rows
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchOwners() async {
        owners = .loading
        owners = await LoadState.fetching {
            switch try await session.client.topOwnersByIpCountApiV1ReportsTopOwnersByIpCountGet() {
            case .ok(let ok): return try ok.body.json.rows
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
