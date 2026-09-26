//
//  OwnershipViews.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Customers, sites and providers on one screen.
///
/// Three small lists rather than three sidebar entries. They are the same kind
/// of thing — logical ownership tags that cross-cut IPAM, DNS and DHCP — and
/// nobody opens "Providers" on a phone as a destination in its own right. They
/// are looked up, which is what a segmented picker is for.
struct OwnershipView: View {
    let session: ControlPlaneSession

    enum Kind: String, CaseIterable, Identifiable {
        case customers = "Customers"
        case sites = "Sites"
        case providers = "Providers"
        var id: Self { self }
    }

    @State private var kind: Kind = .customers
    @State private var customers: LoadState<[Components.Schemas.CustomerRead]> = .idle
    @State private var sites: LoadState<[Components.Schemas.SiteRead]> = .idle
    @State private var providers: LoadState<[Components.Schemas.ProviderRead]> = .idle

    var body: some View {
        List {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            switch kind {
            case .customers:
                LoadStateView(
                    state: customers, emptyMessage: "No customers are defined.", retry: { load(.customers) }
                ) { rows in
                    ForEach(rows, id: \.id) { customer in
                        NavigationLink {
                            CustomerSummaryView(session: session, customer: customer)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(customer.name)
                                    Spacer()
                                    StatusLabel(status: customer.status)
                                }
                                if let account = customer.accountNumber, !account.isEmpty {
                                    Text(account).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                if let email = customer.contactEmail, !email.isEmpty {
                                    Text(email).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

            case .sites:
                LoadStateView(state: sites, emptyMessage: "No sites are defined.", retry: { load(.sites) }) {
                    rows in
                    ForEach(rows, id: \.id) { site in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(site.name)
                                Spacer()
                                Badge(text: site.kind, tint: .indigo)
                            }
                            HStack(spacing: 8) {
                                if let code = site.code, !code.isEmpty { Text(code) }
                                if let region = site.region, !region.isEmpty { Text(region) }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }

            case .providers:
                LoadStateView(
                    state: providers, emptyMessage: "No providers are defined.", retry: { load(.providers) }
                ) { rows in
                    ForEach(rows, id: \.id) { provider in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(provider.name)
                                Spacer()
                                Badge(text: provider.kind, tint: .teal)
                            }
                            if let account = provider.accountNumber, !account.isEmpty {
                                Text(account).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let email = provider.contactEmail, !email.isEmpty {
                                Text(email).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Ownership")
        .refreshable { await fetch(kind) }
        // Keyed on the segment, so switching loads that list once rather than
        // fetching all three up front for the two nobody looked at.
        .task(id: kind) { await fetch(kind) }
    }

    private func load(_ kind: Kind) { Task { await fetch(kind) } }

    private func fetch(_ kind: Kind) async {
        switch kind {
        case .customers:
            if case .loaded = customers { return }
            customers = .loading
            customers = await LoadState.fetching {
                switch try await session.client.listCustomersApiV1CustomersGet(query: .init(limit: 200)) {
                case .ok(let ok):
                    return try ok.body.json.items.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .sites:
            if case .loaded = sites { return }
            sites = .loading
            sites = await LoadState.fetching {
                switch try await session.client.listSitesApiV1SitesGet(query: .init(limit: 200)) {
                case .ok(let ok):
                    return try ok.body.json.items.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .providers:
            if case .loaded = providers { return }
            providers = .loading
            providers = await LoadState.fetching {
                switch try await session.client.listProvidersApiV1ProvidersGet(query: .init(limit: 200)) {
                case .ok(let ok):
                    return try ok.body.json.items.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}
