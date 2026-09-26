//
//  OverviewModel.swift
//  SpatiumDDI
//

import Foundation
import OpenAPIRuntime
import SpatiumAPI

/// The platform's own view of itself, from the unauthenticated health rollup.
///
/// Read out of an untyped container rather than a generated model because the
/// document declares no response schema for `/health/platform` — there is no
/// generated type to use. This is not the hand-written model non-negotiable #1
/// forbids; that rule is about not re-typing schemas the document does define.
nonisolated struct PlatformHealth: Sendable, Equatable {
    struct Component: Sendable, Equatable, Identifiable {
        let name: String
        let status: String
        let detail: String
        var id: String { name }
    }

    var status: String
    var demoMode: Bool
    var maintenanceMode: Bool
    var maintenanceMessage: String?
    var components: [Component]

    init?(container: OpenAPIValueContainer) {
        guard let root = container.value as? [String: any Sendable] else { return nil }
        status = root["status"] as? String ?? "unknown"
        demoMode = root["demo_mode"] as? Bool ?? false
        maintenanceMode = root["maintenance_mode"] as? Bool ?? false
        let message = root["maintenance_message"] as? String
        maintenanceMessage = (message?.isEmpty ?? true) ? nil : message
        components = (root["components"] as? [any Sendable] ?? []).compactMap { entry in
            guard let entry = entry as? [String: any Sendable],
                let name = entry["name"] as? String
            else { return nil }
            return Component(
                name: name,
                status: entry["status"] as? String ?? "unknown",
                detail: entry["detail"] as? String ?? ""
            )
        }
    }
}

/// Counts and health for the overview screen.
///
/// There is no server-side DDI rollup to call. `/api/v1/dashboards/` carries
/// exactly three summaries — network (ASN/RPKI/circuits), security and
/// integrations — and none of them counts a subnet, a zone or a lease. So the
/// DDI figures here are counted from the resource endpoints, which is why they
/// arrive in stages rather than in one response.
///
/// Nothing is persisted. Non-negotiable #3: this is in-memory for the session,
/// and a stale-but-plausible KPI is exactly the kind of thing an operator would
/// act on without being able to tell it was stale.
@MainActor
@Observable
final class OverviewModel {
    /// Not private: the view compares it to decide whether the model it holds
    /// still belongs to the current session.
    let session: ControlPlaneSession

    var health: LoadState<PlatformHealth> = .idle
    var version: LoadState<Components.Schemas.VersionResponse> = .idle
    var alerts: LoadState<[Components.Schemas.AlertEventResponse]> = .idle
    var ipam: LoadState<IPAMTotals> = .idle
    var dns: LoadState<DNSTotals> = .idle
    var dhcp: LoadState<DHCPTotals> = .idle

    init(session: ControlPlaneSession) {
        self.session = session
    }

    nonisolated struct IPAMTotals: Sendable, Equatable {
        var spaces: Int
        var blocks: Int
        var subnets: [Components.Schemas.SubnetResponse]

        /// A subnet's family, from its network. A colon can only be IPv6 — an
        /// IPv4 CIDR cannot contain one — and the API carries no family field.
        var ipv4Subnets: [Components.Schemas.SubnetResponse] {
            subnets.filter { !$0.network.contains(":") }
        }

        var ipv6SubnetCount: Int { subnets.count - ipv4Subnets.count }

        /// IPv4 only, deliberately.
        ///
        /// Counting IPv6 here is not merely imprecise, it is meaningless: one
        /// /64 holds 2^64 addresses, so a single one drags any size-weighted
        /// figure to zero and keeps it there no matter how full the estate's
        /// real subnets get. Nobody measures a /64's fill rate.
        var utilisationPercent: Double {
            IPAMTotals.weightedUtilisation(ipv4Subnets.map { ($0.allocatedIps, $0.totalIps) })
        }

        /// Allocation across the subnets given, not the mean of the percentages
        /// — a /30 at 100% and a /16 at 1% average to 50% only if you ignore
        /// that they differ in size by a factor of sixteen thousand.
        ///
        /// Accumulated in `Double`. `Int` addition traps on overflow in Swift,
        /// and the control plane clamps a count it cannot express to
        /// `Int64.max` — an IPv6 /64 comes back as exactly that. Summing it
        /// with anything at all overflows and takes the whole app down, which
        /// is precisely how this crashed on a real estate. Callers filter IPv6
        /// out, but a display metric must not be able to crash the app even if
        /// one slips through.
        static func weightedUtilisation(_ subnets: [(allocated: Int, total: Int)]) -> Double {
            var total = 0.0
            var allocated = 0.0
            for subnet in subnets {
                total += Double(subnet.total)
                allocated += Double(subnet.allocated)
            }
            guard total > 0 else { return 0 }
            return min(allocated / total * 100, 100)
        }

        /// Busiest by the server's own percentage, which is safe for both
        /// families — it is a `Double` the control plane computed.
        var busiest: [Components.Schemas.SubnetResponse] {
            subnets.sorted { $0.utilizationPercent > $1.utilizationPercent }.prefix(5).map { $0 }
        }
    }

    nonisolated struct DNSTotals: Sendable, Equatable {
        var groups: Int
        /// `nil` when at least one group's zones could not be listed.
        ///
        /// Not zero, and not a partial sum. A group this account cannot read
        /// answers 403, and counting it as "no zones" turns a permission
        /// boundary into a factual claim about the estate — which is exactly
        /// the swallowed-403 that non-negotiable #4 forbids.
        var zones: Int?
        var signedZones: Int?
    }

    nonisolated struct DHCPTotals: Sendable, Equatable {
        var servers: [Components.Schemas.AppApiV1DhcpServersServerResponse]
        var activeLeases: Int?

        var healthy: Int { servers.filter { $0.status.lowercased() == "active" }.count }
        var unhealthy: Int { servers.count - healthy }
    }

    var openAlertCounts: [Severity: Int] {
        guard case .loaded(let events) = alerts else { return [:] }
        return events.reduce(into: [:]) { counts, event in
            counts[Severity(apiValue: event.severity), default: 0] += 1
        }
    }

    /// Whether the running control plane is old enough that this build should
    /// not be trusted against it. `nil` while unknown.
    var versionShortfall: ServerVersion? {
        guard case .loaded(let version) = version else { return nil }
        let running = ServerVersion(version.version)
        return running.satisfiesMinimum(SupportedServer.minimum) ? nil : running
    }

    /// Whether any section still has nothing to show.
    ///
    /// Not just `health`: leaving the screen mid-load cancels the fetches still
    /// in flight, which returns them to `.idle` — and the section that finished
    /// first is usually health. Checking it alone left the others spinning.
    var hasIdleSection: Bool {
        health.isIdle || version.isIdle || alerts.isIdle || ipam.isIdle || dns.isIdle
            || dhcp.isIdle
    }

    func refresh() async {
        // Every call is independent, and a phone on a VPN pays the round trip
        // once rather than eight times if they overlap.
        async let health: Void = loadHealth()
        async let version: Void = loadVersion()
        async let alerts: Void = loadAlerts()
        async let ipam: Void = loadIPAM()
        async let dns: Void = loadDNS()
        async let dhcp: Void = loadDHCP()
        _ = await (health, version, alerts, ipam, dns, dhcp)
    }

    private func loadHealth() async {
        health = .loading
        health = await LoadState.fetching {
            switch try await session.client.platformHealthHealthPlatformGet() {
            case .ok(let ok):
                guard let parsed = PlatformHealth(container: try ok.body.json) else {
                    throw APIStatusError(status: 500)
                }
                return parsed
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func loadVersion() async {
        version = .loading
        version = await LoadState.fetching {
            switch try await session.client.getVersionApiV1VersionGet() {
            case .ok(let ok):
                return try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func loadAlerts() async {
        alerts = .loading
        alerts = await LoadState.fetching {
            let response = try await session.client.listEventsApiV1AlertsEventsGet(
                query: .init(openOnly: true, limit: 200)
            )
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

    private func loadIPAM() async {
        ipam = .loading
        ipam = await LoadState.fetching {
            async let spaces = countSpaces()
            async let blocks = countBlocks()
            async let subnets = allSubnets()
            return IPAMTotals(spaces: try await spaces, blocks: try await blocks, subnets: try await subnets)
        }
    }

    private func countSpaces() async throws -> Int {
        switch try await session.client.listSpacesApiV1IpamSpacesGet() {
        case .ok(let ok): return try ok.body.json.count
        case .unprocessableContent: throw APIStatusError(status: 422)
        case .undocumented(let statusCode, let payload):
            throw await APIStatusError(status: statusCode, payload: payload)
        }
    }

    private func countBlocks() async throws -> Int {
        switch try await session.client.listBlocksApiV1IpamBlocksGet() {
        case .ok(let ok): return try ok.body.json.count
        case .unprocessableContent: throw APIStatusError(status: 422)
        case .undocumented(let statusCode, let payload):
            throw await APIStatusError(status: statusCode, payload: payload)
        }
    }

    /// Every subnet, because there is no count endpoint and no pagination on
    /// this one.
    ///
    /// The utilisation leaderboard is computed from this rather than from
    /// `/reports/top-subnets-by-utilization`, which is behind the `reports.top_n`
    /// feature module and answers **404** when that module is off — the exact
    /// status an RBAC-filtered surface returns. Ranking five subnets locally is
    /// cheaper than being unable to tell those two cases apart.
    private func allSubnets() async throws -> [Components.Schemas.SubnetResponse] {
        switch try await session.client.listSubnetsApiV1IpamSubnetsGet() {
        case .ok(let ok): return try ok.body.json
        case .unprocessableContent: throw APIStatusError(status: 422)
        case .undocumented(let statusCode, let payload):
            throw await APIStatusError(status: statusCode, payload: payload)
        }
    }

    private func loadDNS() async {
        dns = .loading
        dns = await LoadState.fetching {
            let groups: [Components.Schemas.ServerGroupResponse]
            switch try await session.client.listGroupsApiV1DnsGroupsGet() {
            case .ok(let ok): groups = try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }

            // Zones are per group, so the count costs one call per group; they
            // run concurrently. A group that fails yields `nil` rather than an
            // empty list, so the difference between "this group has no zones"
            // and "this account may not read this group" survives the sum.
            let perGroup = await withTaskGroup(of: [Components.Schemas.ZoneResponse]?.self) { tasks in
                for group in groups {
                    tasks.addTask { [session] in
                        let response = try? await session.client
                            .listZonesApiV1DnsGroupsGroupIdZonesGet(path: .init(groupId: group.id))
                        if case .ok(let ok) = response, let zones = try? ok.body.json { return zones }
                        return nil
                    }
                }
                // Accumulated with `for await` rather than `reduce(into:)`: the
                // reducing closure is `inout` across an isolation boundary, and
                // Swift 6 rejects it as a data race.
                var collected: [[Components.Schemas.ZoneResponse]?] = []
                for await zones in tasks { collected.append(zones) }
                return collected
            }

            guard !perGroup.contains(where: { $0 == nil }) else {
                return DNSTotals(groups: groups.count, zones: nil, signedZones: nil)
            }
            let zones = perGroup.compactMap { $0 }.flatMap { $0 }
            return DNSTotals(
                groups: groups.count,
                zones: zones.count,
                signedZones: zones.filter(\.dnssecEnabled).count
            )
        }
    }

    private func loadDHCP() async {
        dhcp = .loading
        dhcp = await LoadState.fetching {
            let servers: [Components.Schemas.AppApiV1DhcpServersServerResponse]
            switch try await session.client.listServersApiV1DhcpServersGet() {
            case .ok(let ok): servers = try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }

            // Active leases is per server. An unreachable server has no stats to
            // give, so the total is `nil` rather than a number that silently
            // omits one — under-reporting a lease count reads as capacity that
            // isn't there.
            let counts = await withTaskGroup(of: Int?.self) { tasks in
                for server in servers {
                    tasks.addTask { [session] in
                        let response = try? await session.client
                            .getServerStatsApiV1DhcpServersServerIdStatsGet(
                                path: .init(serverId: server.id)
                            )
                        if case .ok(let ok) = response, let stats = try? ok.body.json {
                            return stats.leasesActive
                        }
                        return nil
                    }
                }
                var collected: [Int?] = []
                for await count in tasks { collected.append(count) }
                return collected
            }

            return DHCPTotals(
                servers: servers,
                activeLeases: counts.contains(where: { $0 == nil })
                    ? nil : counts.compactMap { $0 }.reduce(0, +)
            )
        }
    }
}
