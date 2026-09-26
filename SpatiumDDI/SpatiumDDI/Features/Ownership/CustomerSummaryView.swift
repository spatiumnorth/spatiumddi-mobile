//
//  CustomerSummaryView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What a customer still owns (#20).
///
/// The question it answers is "can this customer be decommissioned?", and the
/// honest answer is only ever about what the platform tracks — so the zero
/// case says exactly that, and never "safe to delete". A circuit in a
/// spreadsheet somewhere is not something this screen can see.
struct CustomerSummaryView: View {
    let session: ControlPlaneSession
    let customer: Components.Schemas.CustomerRead

    @State private var state: LoadState<Components.Schemas.CustomerSummary> = .idle

    var body: some View {
        List {
            Section {
                LabeledContent("Status") { StatusLabel(status: customer.status) }
                if let account = customer.accountNumber, !account.isEmpty {
                    LabeledContent("Account") {
                        Text(verbatim: account).font(.body.monospaced())
                    }
                }
                if let email = customer.contactEmail, !email.isEmpty {
                    LabeledContent("Contact") { Text(verbatim: email) }
                }
                if let phone = customer.contactPhone, !phone.isEmpty {
                    LabeledContent("Phone") { Text(verbatim: phone) }
                }
            }

            switch state {
            case .idle, .loading:
                Section("Owns") { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let message):
                Section("Owns") {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await fetch() } }
                }
            case .loaded(let summary):
                owned(summary)
            }
        }
        .navigationTitle(customer.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    @ViewBuilder
    private func owned(_ summary: Components.Schemas.CustomerSummary) -> some View {
        let resources = summary.ownedResources
        // Only the kinds it actually owns: nine rows of zero bury the one that
        // matters.
        let rows: [(LocalizedStringResource, Int)] = [
            ("IP spaces", resources.ipSpaces),
            ("IP blocks", resources.ipBlocks),
            ("Subnets", resources.subnets),
            ("DNS zones", resources.dnsZones),
            ("Domains", resources.domains),
            ("ASNs", resources.asns),
            ("Circuits", resources.circuits),
            ("Services", resources.services),
            ("Overlays", resources.overlays),
        ].filter { $0.1 > 0 }

        Section {
            if rows.isEmpty {
                Label(
                    "Owns nothing this platform tracks.",
                    systemImage: "checkmark.circle"
                )
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent {
                        Text(verbatim: row.1.formatted()).monospacedDigit()
                    } label: {
                        Text(row.0)
                    }
                }
            }
        } header: {
            HStack {
                Text("Owns")
                Spacer()
                Text(verbatim: summary.ownedResourceTotal.formatted())
            }
        } footer: {
            // The limit of what "nothing" means, said where it is read.
            Text(
                "Counts what is tagged to this customer in SpatiumDDI. Anything recorded elsewhere isn't included."
            )
        }
    }

    private func fetch() async {
        state = .loading
        let next = await LoadState.fetching {
            let response = try await session.client
                .getCustomerSummaryRouteApiV1CustomersCustomerIdSummaryGet(
                    path: .init(customerId: customer.id))
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
