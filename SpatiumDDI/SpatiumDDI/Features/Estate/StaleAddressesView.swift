//
//  StaleAddressesView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What has rotted, and one action to mark it.
///
/// The hygiene screen. An estate accumulates addresses that nothing has
/// answered for in months — a decommissioned host, a VM that moved — and each
/// one is a row somebody will hesitate over before reusing. Marking them
/// deprecated is not a delete: the row stays, with its history, and stops
/// counting as live.
struct StaleAddressesView: View {
    let session: ControlPlaneSession

    @Environment(Permissions.self) private var permissions

    /// The spans worth offering. Ninety days is the server's own default.
    private static let windows = [30, 60, 90, 180, 365]

    @State private var staleDays = 90
    @State private var includeNeverSeen = false
    @State private var state: LoadState<Components.Schemas.StaleIPReport> = .idle
    @State private var selection: Set<String> = []
    @State private var isConfirming = false
    @State private var isDeprecating = false
    @State private var outcome: FailureMessage?
    /// Whether `outcome` is a receipt or a refusal. One slot rendered one way
    /// showed a maintenance-mode 503 with the same neutral glyph as a
    /// completed write — non-negotiables #4 and #5 both want the difference.
    @State private var outcomeIsFailure = false

    private var mayDeprecate: Bool { permissions.canWrite("ip_address") }

    /// The report's rows as their own `LoadState`, so `LoadStateView` can tell
    /// "loaded and empty" from "loaded".
    private var entriesState: LoadState<[Components.Schemas.StaleIPEntry]> {
        switch state {
        case .idle: .idle
        case .loading: .loading
        case .loaded(let report): .loaded(report.entries)
        case .failed(let message): .failed(message)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Stale for", selection: $staleDays) {
                    ForEach(Self.windows, id: \.self) { days in
                        Text("^[\(days) day](inflect: true)").tag(days)
                    }
                }
                Toggle("Include never-seen addresses", isOn: $includeNeverSeen)
            } header: {
                Text("What counts as stale")
            } footer: {
                // The two are genuinely different findings and the distinction
                // decides what to do about them: an address nothing has ever
                // answered for may simply predate discovery being switched on.
                Text(
                    "An address nothing has answered for in that long. \"Never seen\" means discovery has no record of it at all, which is not the same as it having gone quiet."
                )
            }

            Section {
                // The rows rather than the whole report, so `emptyMessage`
                // actually fires: `LoadStateView` tests the value for an empty
                // `Collection`, and a report struct is never one. The total is
                // read from `state` in the header instead.
                LoadStateView(
                    state: entriesState,
                    emptyMessage: "Nothing has gone stale in this window.",
                    retry: { Task { await fetch() } }
                ) { entries in
                    ForEach(entries, id: \.id) { entry in
                        StaleAddressRow(
                            entry: entry,
                            isSelected: selection.contains(entry.id),
                            isSelectable: mayDeprecate
                        ) {
                            if selection.contains(entry.id) {
                                selection.remove(entry.id)
                            } else {
                                selection.insert(entry.id)
                            }
                        }
                    }
                }
            } header: {
                if case .loaded(let report) = state, report.total > report.entries.count {
                    Text("Stale — showing \(report.entries.count) of \(report.total)")
                } else {
                    Text("Stale")
                }
            } footer: {
                if mayDeprecate, case .loaded(let report) = state, !report.entries.isEmpty {
                    Text("Tap a row to select it. Deprecating keeps the row and its history.")
                }
            }

            if let outcome {
                Section("Result") {
                    Label(
                        outcome,
                        systemImage: outcomeIsFailure
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(outcomeIsFailure ? Color.red : Color.primary)
                }
            }
        }
        .navigationTitle("Stale Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            outcome = nil
            await fetch()
        }
        // Clearing `outcome` here and not inside `fetch()`: the post-write
        // refetch calls `fetch()` too, and it must not wipe the receipt it
        // was just given.
        .task(id: [staleDays, includeNeverSeen ? 1 : 0]) {
            outcome = nil
            await fetch()
        }
        .toolbar {
            if mayDeprecate, !selection.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    if isDeprecating {
                        ProgressView()
                    } else {
                        Button("Deprecate \(selection.count)") { isConfirming = true }
                    }
                }
            }
        }
        .alert("Deprecate ^[\(selection.count) address](inflect: true)?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button("Deprecate") { Task { await deprecate() } }
        } message: {
            Text(verbatim: confirmationText)
        }
    }

    /// Names the addresses rather than only counting them.
    ///
    /// A count alone is not checkable — the operator cannot tell a mis-tap from
    /// the selection they meant. Listing the first few and saying how many more
    /// there are makes it possible to notice.
    private var confirmationText: String {
        let selected = selectedEntries
        var lines = selected.prefix(5).map(\.address)
        if selected.count > lines.count {
            lines.append(String(localized: "…and ^[\(selected.count - lines.count) more](inflect: true)"))
        }
        // No backticks: this reaches the alert through `Text(verbatim:)`,
        // which parses nothing, so they would be shown to the operator as
        // literal characters.
        lines.append(
            String(
                localized:
                    "Each is marked deprecated. The row and its history stay, and it stops counting as allocated."
            )
        )
        return lines.joined(separator: "\n")
    }

    private var selectedEntries: [Components.Schemas.StaleIPEntry] {
        guard case .loaded(let report) = state else { return [] }
        return report.entries.filter { selection.contains($0.id) }
    }

    private func deprecate() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        isDeprecating = true
        outcome = nil
        defer { isDeprecating = false }

        do {
            let response = try await session.client
                .deprecateStaleIpsApiV1IpamReportsStaleIpsDeprecatePost(
                    // Explicit ids only. `all_matching` exists and is
                    // deliberately not sent: "deprecate everything that matches
                    // a filter I cannot see the whole of" is a blast radius
                    // that deserves a desk and a bigger screen.
                    body: .json(.init(allMatching: false, ipIds: ids))
                )
            switch response {
            case .ok(let ok):
                let result = try ok.body.json
                selection = []
                var text = String(
                    localized: "^[\(result.deprecatedCount) address](inflect: true) deprecated.")
                if let skipped = result.skipped, !skipped.isEmpty {
                    // The server refuses some rows — one mirroring a live lease,
                    // for instance. Saying how many were skipped stops the
                    // count reading as a failure of the whole action.
                    text += " "
                    text += String(
                        localized: "^[\(skipped.count) address](inflect: true) skipped.")
                }
                if result.capped == true {
                    // Never report a truncated write as a finished one: the
                    // rows the server dropped are still allocated, and the
                    // count alone reads as though they were dealt with.
                    text += " "
                    text += String(
                        localized:
                            "The server capped this batch, so some selected addresses were not deprecated."
                    )
                }
                outcomeIsFailure = false
                outcome = .app("\(text)")
                await fetch()
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            // `forced: true` means `classify` can only answer `.failed` —
            // the `.confirmable` branch is gated on `!forced` — so nothing is
            // being dropped here.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                outcomeIsFailure = true
                outcome = message
            }
        }
    }

    private func fetch() async {
        state = .loading
        let next = await LoadState.fetching {
            let response = try await session.client.getStaleIpReportApiV1IpamReportsStaleIpsGet(
                query: .init(
                    staleDays: staleDays,
                    includeNeverSeen: includeNeverSeen,
                    limit: 200
                )
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }

        // A superseded task must not write. `LoadState.fetching` answers
        // `.idle` for a cancelled fetch, and assigning that would both clobber
        // the newer task's state and re-arm `LoadStateView`'s idle branch,
        // which starts a fetch of its own.
        guard !Task.isCancelled else { return }
        state = next

        // Keep the selection across a refresh rather than discarding the
        // operator's taps, but drop anything the new report no longer lists so
        // a ghost id cannot reach `deprecate()`.
        if case .loaded(let report) = next {
            selection.formIntersection(report.entries.map(\.id))
        } else {
            selection = []
        }
    }
}

private struct StaleAddressRow: View {
    let entry: Components.Schemas.StaleIPEntry
    let isSelected: Bool
    let isSelectable: Bool
    let toggle: () -> Void

    var body: some View {
        // A button only when there is something to toggle. `.disabled` on the
        // row instead would dim the address, hostname and MAC of every row for
        // a read-only operator and mark each one `notEnabled` to VoiceOver —
        // presenting a perfectly readable report as unavailable.
        if isSelectable {
            Button(action: toggle) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            if isSelectable {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: entry.address).font(.body.monospaced())
                    Spacer()
                    Badge(text: entry.status, tint: .secondary)
                }
                if let hostname = entry.hostname, !hostname.isEmpty {
                    Text(verbatim: hostname).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    // Null days is the "never seen" case, and it needs its
                    // own words: "0 days stale" would be the exact opposite
                    // of what it means.
                    if let days = entry.daysStale {
                        Text("^[\(days) day](inflect: true) stale")
                    } else {
                        Text("never seen")
                    }
                    if let network = entry.subnetName ?? entry.subnetNetwork {
                        Text(verbatim: network)
                    }
                    if let mac = entry.macAddress, !mac.isEmpty {
                        Text(verbatim: mac)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
