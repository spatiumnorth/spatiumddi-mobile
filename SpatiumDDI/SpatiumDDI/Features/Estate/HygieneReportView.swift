//
//  HygieneReportView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Where IPAM and the network disagree, as three triage lists (#20).
///
/// Each bucket is a different kind of wrong, and each has a different owner:
///
/// - **Free but answering** — IPAM says nobody has it, something replies. The
///   next allocation of that address is a collision waiting to happen.
/// - **Stale reservations** — held for someone who has not turned up in
///   months. Capacity that is not really in use.
/// - **Unknown MAC in a static range** — the honest place to say "this
///   address is squatted": a device IPAM did not put there.
///
/// Read-only on purpose. Each finding opens the address itself, where the
/// actions already live behind their own confirmations.
struct HygieneReportView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<Components.Schemas.HygieneReport> = .idle

    var body: some View {
        List {
            switch state {
            case .idle, .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
                    .task { if case .idle = state { await fetch() } }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await fetch() } }
                }
            case .loaded(let report):
                bucket(
                    title: "Free but answering",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    count: report.counts.freeButResponding,
                    findings: report.freeButResponding,
                    explanation:
                        "Marked available in IPAM, but something answered within \(report.thresholds.freeRespondingDays) days. Allocating one would hand out an address that's already in use."
                )
                bucket(
                    title: "Stale reservations",
                    systemImage: "clock.badge.exclamationmark",
                    tint: .orange,
                    count: report.counts.staleReservations,
                    findings: report.staleReservations,
                    explanation:
                        "Reserved, and nothing has seen them in \(report.thresholds.staleReservationDays) days."
                )
                bucket(
                    title: "Unknown MAC in a static range",
                    systemImage: "person.fill.questionmark",
                    tint: .orange,
                    count: report.counts.unknownMacInStaticRange,
                    findings: report.unknownMacInStaticRange,
                    explanation:
                        "A device other than the recorded one was seen on these within \(report.thresholds.squatDays) days — something is using an address IPAM gave to someone else."
                )
            }
        }
        .navigationTitle("Address Hygiene")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
    }

    @ViewBuilder
    private func bucket(
        title: LocalizedStringResource,
        systemImage: String,
        tint: Color,
        count: Int,
        findings: [Components.Schemas.HygieneFinding],
        explanation: LocalizedStringResource
    ) -> some View {
        Section {
            if findings.isEmpty {
                Text("Nothing here.").foregroundStyle(.secondary)
            } else {
                ForEach(findings, id: \.ipId) { finding in
                    NavigationLink {
                        AddressByIDView(session: session, addressID: finding.ipId)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: finding.address).font(.body.monospaced())
                            if !finding.detail.isEmpty {
                                Text(verbatim: finding.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(count > 0 ? tint : .secondary)
                }
                Spacer()
                Text(verbatim: count.formatted())
            }
        } footer: {
            // A bucket capped at the request's limit says so, rather than
            // letting "12 findings" read as the whole estate when it isn't.
            if count > findings.count {
                Text("Showing \(findings.count) of \(count). \(Text(explanation))")
            } else {
                Text(explanation)
            }
        }
    }

    private func fetch() async {
        state = .loading
        let next = await LoadState.fetching {
            let response = try await session.client.getIpHygieneReportApiV1IpamReportsHygieneGet(
                // The server's own thresholds: the screen reports them in each
                // footer rather than choosing different ones and disagreeing
                // with the web console about what counts.
                query: .init(limit: 100)
            )
            switch response {
            case .ok(let ok): return try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
        // A superseded fetch must not write, or the idle branch above would
        // start another.
        guard !Task.isCancelled else { return }
        state = next
    }
}

/// Opens an address from nothing but its id.
///
/// Reports name addresses by id, and the detail screen needs the address and
/// the subnet it sits in — the subnet decides what may be done with it. Both
/// are fetched fresh, which is also the right thing for a report: the row may
/// have moved on since the report was generated.
struct AddressByIDView: View {
    let session: ControlPlaneSession
    let addressID: String

    struct Loaded {
        let address: Components.Schemas.IPAddressResponse
        let subnet: Components.Schemas.SubnetResponse
    }

    @State private var state: LoadState<Loaded> = .idle

    var body: some View {
        switch state {
        case .loaded(let loaded):
            IPAMAddressDetailView(session: session, address: loaded.address, subnet: loaded.subnet)
        case .failed(let message):
            List {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try Again") { Task { await fetch() } }
            }
        case .idle, .loading:
            ProgressView().task { if case .idle = state { await fetch() } }
        }
    }

    private func fetch() async {
        state = .loading
        let next = await LoadState.fetching {
            let address: Components.Schemas.IPAddressResponse
            switch try await session.client.getAddressApiV1IpamAddressesAddressIdGet(
                path: .init(addressId: addressID))
            {
            case .ok(let ok): address = try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
            switch try await session.client.getSubnetApiV1IpamSubnetsSubnetIdGet(
                path: .init(subnetId: address.subnetId))
            {
            case .ok(let ok): return Loaded(address: address, subnet: try ok.body.json)
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
        guard !Task.isCancelled else { return }
        state = next
    }
}
