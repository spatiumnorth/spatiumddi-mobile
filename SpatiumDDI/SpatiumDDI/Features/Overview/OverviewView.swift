//
//  OverviewView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// The landing screen: is the platform healthy, is anything firing, and how big
/// is the estate.
///
/// Deliberately not a copy of the web dashboard's nine tabs. This is the screen
/// an operator opens on a phone to answer "does this need me right now", and
/// every tile earns its place against that question.
struct OverviewView: View {
    let session: ControlPlaneSession
    /// Handed on to Access, which a security tile opens. Revoking this
    /// device's own token there is a sign-out, and needs the real one.
    var onSelfRevoked: () -> Void = {}

    @State private var model: OverviewModel?
    /// Where a tapped tile goes.
    @State private var destination: OverviewDestination?

    var body: some View {
        List {
            if let model {
                PlatformSection(model: model)
                AlertsSummarySection(model: model, session: session)
                IPAMSummarySection(model: model)
                DNSSummarySection(model: model)
                DHCPSummarySection(model: model)
                // After the DDI counts: these are signals about the estate
                // around DDI, and each is gated on whether this control plane
                // has the thing at all.
                NewDevicesSummarySection(model: model, open: { destination = $0 })
                NetworkSummarySection(model: model, open: { destination = $0 })
                SecuritySummarySection(model: model, open: { destination = $0 })
                // Below the estate counts on purpose: the counts answer "how
                // big is this", which is a glance, and the charts answer "what
                // is it doing", which is a scroll.
                TrafficSection(session: session)
                TopReportsSection(session: session)
            }
        }
        .navigationTitle("Overview")
        // On the list, not on a tile: a destination declared inside a lazy
        // container is ignored. One row holds several tiles, so each tile is
        // its own button rather than the row being one link.
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .newDevices: NewDevicesView(session: session)
            case .asns: ASNsView(session: session)
            case .circuits: CircuitsView(session: session)
            case .access: AccessView(session: session, onSelfRevoked: onSelfRevoked)
            case .audit: AuditLogView(session: session)
            }
        }
        .refreshable { await model?.refresh() }
        // Rebuilt when the session is, not merely built once. A session is
        // invalidated and replaced when the token changes, and a model still
        // holding the old one would make every call through a dead URLSession
        // while looking, from here, like it had simply loaded nothing.
        .task(id: ObjectIdentifier(session)) {
            if model?.session !== session { model = OverviewModel(session: session) }
            if model?.hasIdleSection == true { await model?.refresh() }
        }
    }
}

// MARK: - Platform

private struct PlatformSection: View {
    let model: OverviewModel

    var body: some View {
        Section("Platform") {
            switch model.health {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)

            case .loaded(let health):
                // Maintenance is a real state, not an error and not a footnote.
                // Non-negotiable #5: it is surfaced as itself, up top.
                if health.maintenanceMode {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Maintenance mode").font(.subheadline.weight(.semibold))
                            Text(health.maintenanceMessage ?? "The server is in a change window.")
                                .font(.caption)
                        }
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver.fill")
                    }
                    .foregroundStyle(.orange)
                }

                if health.demoMode {
                    Label(
                        "Demo mode — this control plane holds seeded data.", systemImage: "theatermasks.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.purple)
                }

                LabeledContent("Status") { StatusLabel(status: health.status) }

                ForEach(health.components) { component in
                    LabeledContent {
                        StatusLabel(status: component.status)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(component.name)
                            if !component.detail.isEmpty {
                                Text(component.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }

            VersionRow(model: model)
        }
    }
}

private struct VersionRow: View {
    let model: OverviewModel

    var body: some View {
        switch model.version {
        case .idle, .loading:
            EmptyView()

        case .loaded(let version):
            let running = ServerVersion(version.version)
            LabeledContent("Server version", value: running.displayName)

            // A development or nightly build has no place in the release order,
            // CalVer or SemVer, so it cannot be compared against the minimum.
            // Saying so is the honest report — the alternative is a green tick
            // that was never actually checked.
            if running.isDevelopment {
                Label(
                    "This is a development or nightly build, so it can't be checked against the minimum supported release (\(SupportedServer.minimum.displayName)).",
                    systemImage: "hammer.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if model.versionShortfall != nil {
                Label(
                    "This app is built against \(SupportedServer.minimum.displayName). Parts of it may not work against \(running.displayName).",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if version.updateAvailable, let latest = version.latestVersion {
                Label("Update available: \(latest)", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Alerts

private struct AlertsSummarySection: View {
    let model: OverviewModel
    let session: ControlPlaneSession

    var body: some View {
        Section("Unresolved alerts") {
            switch model.alerts {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)

            case .loaded(let events):
                if events.isEmpty {
                    Label("Nothing firing.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 10) {
                        ForEach(Severity.allCases, id: \.self) { severity in
                            CountTile(
                                value: model.openAlertCounts[severity] ?? 0,
                                label: severity.label,
                                tint: severity.tint
                            )
                        }
                    }
                    .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                    NavigationLink("See all alerts") { AlertsView(session: session) }
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - IPAM

private struct IPAMSummarySection: View {
    let model: OverviewModel

    var body: some View {
        Section("IPAM") {
            switch model.ipam {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)

            case .loaded(let totals):
                HStack(spacing: 10) {
                    CountTile(value: totals.spaces, label: "Spaces", tint: .blue)
                    CountTile(value: totals.blocks, label: "Blocks", tint: .blue)
                    CountTile(value: totals.subnets.count, label: "Subnets", tint: .blue)
                }
                .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                VStack(alignment: .leading, spacing: 4) {
                    // Named IPv4 rather than left ambiguous: a /64 would drag
                    // any all-family figure to zero and hold it there, so a bar
                    // labelled "address space" would be quietly meaningless on
                    // every dual-stack estate.
                    Text("IPv4 address space in use").font(.caption).foregroundStyle(.secondary)
                    UtilisationBar(percent: totals.utilisationPercent)
                    if totals.ipv6SubnetCount > 0 {
                        Text(
                            "^[\(totals.ipv6SubnetCount) IPv6 subnet](inflect: true) excluded — utilisation isn't a useful measure of a /64."
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }

                if !totals.busiest.isEmpty {
                    DisclosureGroup("Busiest subnets") {
                        ForEach(totals.busiest, id: \.id) { subnet in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(subnet.network).font(.caption.monospaced())
                                    Spacer()
                                    Text(
                                        "\(subnet.utilizationPercent, format: .number.precision(.fractionLength(1)))%"
                                    )
                                    .font(.caption.weight(.semibold))
                                }
                                UtilisationBar(percent: subnet.utilizationPercent)
                            }
                        }
                    }
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - DNS

private struct DNSSummarySection: View {
    let model: OverviewModel

    var body: some View {
        Section("DNS") {
            switch model.dns {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)

            case .loaded(let totals):
                HStack(spacing: 10) {
                    CountTile(value: totals.groups, label: "Groups", tint: .indigo)
                    CountTile(value: totals.zones, label: "Zones", tint: .indigo)
                    CountTile(value: totals.signedZones, label: "Signed", tint: .green)
                }
                .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                if totals.zones == nil {
                    Text(
                        "Zone totals are unavailable — at least one DNS group could not be listed, which may be a permission this account doesn't have."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - DHCP

private struct DHCPSummarySection: View {
    let model: OverviewModel

    var body: some View {
        Section("DHCP") {
            switch model.dhcp {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)

            case .loaded(let totals):
                HStack(spacing: 10) {
                    CountTile(value: totals.healthy, label: "Healthy", tint: .green)
                    CountTile(
                        value: totals.unhealthy,
                        label: "Unhealthy",
                        tint: totals.unhealthy > 0 ? .red : .secondary
                    )
                    CountTile(value: totals.activeLeases, label: "Leases", tint: .teal)
                }
                .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                if totals.activeLeases == nil {
                    Text("Lease totals are unavailable — at least one server didn't report statistics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(totals.servers.filter { $0.status.lowercased() != "active" }, id: \.id) { server in
                    LabeledContent(server.name) { StatusLabel(status: server.status) }
                }

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - New devices

private struct NewDevicesSummarySection: View {
    let model: OverviewModel
    let open: (OverviewDestination) -> Void

    @Environment(FeatureModules.self) private var features

    var body: some View {
        // The same gate as the sidebar's New Devices section. The module is
        // off by default, and its endpoints answer 404 when it is.
        if features.isAvailable(AppSection.newDevices.featureModule) {
            Section("New devices") {
                LoadStateView(
                    state: model.newDevices,
                    emptyMessage: "No new-device figures.",
                    retry: { Task { await model.loadNewDevices() } }
                ) { summary in
                    HStack(spacing: 10) {
                        LinkedCountTile(
                            value: summary.newLast24h,
                            label: "Last 24h",
                            tint: SignalTint.of(summary.newLast24h),
                            action: { open(.newDevices) }
                        )
                        LinkedCountTile(
                            value: summary.newCount,
                            label: "To review",
                            tint: SignalTint.of(summary.newCount),
                            action: { open(.newDevices) }
                        )
                        LinkedCountTile(
                            value: summary.acknowledgedCount,
                            label: "Acknowledged",
                            tint: .secondary,
                            action: { open(.newDevices) }
                        )
                    }
                    .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
        }
    }
}

// MARK: - Network

private struct NetworkSummarySection: View {
    let model: OverviewModel
    let open: (OverviewDestination) -> Void

    @Environment(FeatureModules.self) private var features

    /// Each tile follows the module of the screen it opens. The rollup itself
    /// is ungated, but a count of drifting ASNs on a control plane that does
    /// not track ASNs is a zero that means nothing, behind a tap that goes
    /// nowhere.
    private var showsASNs: Bool { features.isAvailable(AppSection.asns.featureModule) }
    private var showsCircuits: Bool { features.isAvailable(AppSection.circuits.featureModule) }

    var body: some View {
        if showsASNs || showsCircuits {
            Section("Network") {
                LoadStateView(
                    state: model.network,
                    emptyMessage: "No network figures.",
                    retry: { Task { await model.loadNetwork() } }
                ) { signals in
                    HStack(spacing: 10) {
                        if showsASNs {
                            LinkedCountTile(
                                value: signals.asnDrift,
                                label: "ASN drift",
                                tint: SignalTint.of(signals.asnDrift),
                                action: { open(.asns) }
                            )
                            LinkedCountTile(
                                value: signals.roasExpiring,
                                label: "ROAs expiring",
                                tint: SignalTint.of(signals.roasExpiring),
                                action: { open(.asns) }
                            )
                        }
                        if showsCircuits {
                            LinkedCountTile(
                                value: signals.circuitAlerts,
                                label: "Circuit alerts",
                                tint: SignalTint.of(signals.circuitAlerts),
                                action: { open(.circuits) }
                            )
                        }
                    }
                    .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                    // An expired ROA is already invalidating routes, which is
                    // worse than any count above — so it is said in words, in
                    // red, rather than as a fourth tile.
                    if showsASNs, signals.roasExpired > 0 {
                        Label(
                            "^[\(signals.roasExpired) ROA](inflect: true) already expired.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                    if showsCircuits, signals.circuitAlerts > 0 {
                        Text(
                            "^[\(signals.circuitTermsEnding) term](inflect: true) ending · ^[\(signals.circuitStatusChanged) status change](inflect: true)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Security

/// Shown to everyone, as the web console's Security tab is: the server hands
/// every caller the headline counts and strips the per-user detail from those
/// without audit or user access. The screens the tiles open may still refuse
/// such a caller, and say so themselves.
private struct SecuritySummarySection: View {
    let model: OverviewModel
    let open: (OverviewDestination) -> Void

    var body: some View {
        Section("Security") {
            LoadStateView(
                state: model.security,
                emptyMessage: "No security figures.",
                retry: { Task { await model.loadSecurity() } }
            ) { signals in
                HStack(spacing: 10) {
                    LinkedCountTile(
                        value: signals.failedLogins,
                        label: "Failed logins",
                        tint: SignalTint.of(signals.failedLogins),
                        action: { open(.audit) }
                    )
                    LinkedCountTile(
                        value: signals.tokensExpiring,
                        label: "Tokens expiring",
                        tint: SignalTint.of(signals.tokensExpiring),
                        action: { open(.access) }
                    )
                    LinkedCountTile(
                        value: signals.withoutMFA,
                        label: "Without MFA",
                        tint: SignalTint.of(signals.withoutMFA),
                        action: { open(.access) }
                    )
                }
                .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                // The windows are the server's, so they are quoted rather than
                // assumed — a "24 hours" baked into the app would be wrong the
                // day the platform changes it.
                Text(
                    "Failed logins over the last ^[\(signals.failedLoginWindowHours) hour](inflect: true); MFA counts local users only. ^[\(signals.permissionChanges) permission change](inflect: true) in the last ^[\(signals.permissionChangeWindowDays) day](inflect: true)."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared

/// The screens an overview tile can open.
enum OverviewDestination: Hashable {
    case newDevices
    case asns
    case circuits
    case access
    case audit
}

/// How loud a count of things-that-need-looking-at should be.
///
/// Green at zero rather than grey: "none" is the answer an operator opened
/// the screen hoping for, and it should read as an answer — the tile's dash
/// is what says a number could not be established.
nonisolated enum SignalTint {
    static func of(_ count: Int, raised: Color = .orange) -> Color {
        count > 0 ? raised : .green
    }
}

/// A count tile that opens the screen behind the number.
///
/// A plain-style button, so a row of three is three targets: a List otherwise
/// hands every tap in a row to the row's first link.
private struct LinkedCountTile: View {
    let value: Int?
    let label: LocalizedStringResource
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CountTile(value: value, label: label, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the list behind this count."))
    }
}
