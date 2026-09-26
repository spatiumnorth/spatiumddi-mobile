//
//  VendorRollupView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Whose hardware is on the network, counted by MAC vendor (#20).
///
/// The question behind it is usually "how many of that model are still out
/// there" — a recall, an end-of-life notice, a vendor advisory — asked of the
/// whole fleet at once rather than of one subnet. The source matters and is
/// the operator's to choose: what IPAM records, what DHCP is leasing right
/// now, or both.
struct VendorRollupView: View {
    let session: ControlPlaneSession

    /// The server's three sources, in its own words.
    enum Source: String, CaseIterable, Identifiable {
        case ipam
        case dhcpActive = "dhcp_active"
        case all

        var id: Self { self }

        var label: LocalizedStringResource {
            switch self {
            case .ipam: "IPAM"
            case .dhcpActive: "Leasing now"
            case .all: "Both"
            }
        }

        var explanation: LocalizedStringResource {
            switch self {
            case .ipam: "Addresses IPAM manages, by the MAC recorded on each."
            case .dhcpActive: "Clients holding a DHCP lease right now."
            case .all: "Both, counted once per MAC."
            }
        }
    }

    @State private var source: Source = .ipam
    @State private var search = ""
    @State private var state: LoadState<Components.Schemas.VendorRollup> = .idle

    var body: some View {
        List {
            Section {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(source.explanation)
            }

            switch state {
            case .idle, .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await fetch() } }
                }
            case .loaded(let rollup):
                Section {
                    LabeledContent("MACs seen", value: rollup.totalMacsSeen.formatted())
                    LabeledContent("With a known vendor", value: rollup.totalWithVendor.formatted())
                    LabeledContent("Distinct vendors", value: rollup.distinctVendors.formatted())
                }
                vendorList(rollup)
            }
        }
        .navigationTitle("Vendors")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Vendor name"))
        .dismissableKeyboard()
        .refreshable { await fetch() }
        // Keyed on both, so changing either refetches and a superseded fetch
        // is cancelled rather than landing late under the newer choice.
        .task(id: "\(source.rawValue)|\(search)") {
            // A short pause while typing, so each keystroke is not a request.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await fetch()
        }
    }

    @ViewBuilder
    private func vendorList(_ rollup: Components.Schemas.VendorRollup) -> some View {
        let top = rollup.vendors.map(\.count).max() ?? 1
        Section {
            if rollup.vendors.isEmpty {
                Text(search.isEmpty ? "No vendors recorded." : "No vendor matches that name.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rollup.vendors, id: \.vendor) { vendor in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: vendor.vendor)
                        Spacer()
                        Text(verbatim: vendor.count.formatted()).monospacedDigit()
                    }
                    // Relative to the largest, so the shape of the fleet reads
                    // at a glance; the number beside it is the fact.
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.tint.opacity(0.35))
                            .frame(width: proxy.size.width * CGFloat(vendor.count) / CGFloat(max(top, 1)))
                    }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            if !search.isEmpty {
                Text("^[\(rollup.matchingMacs) MAC](inflect: true) from a matching vendor")
            } else {
                Text("By vendor")
            }
        }
    }

    private func fetch() async {
        state = .loading
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = await LoadState.fetching {
            let response = try await session.client.getVendorRollupApiV1IpamReportsVendorsGet(
                query: .init(
                    source: .init(rawValue: source.rawValue),
                    vendorSearch: term.isEmpty ? nil : term,
                    limit: 100
                )
            )
            switch response {
            case .ok(let ok): return try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
        guard !Task.isCancelled else { return }
        state = next
    }
}
