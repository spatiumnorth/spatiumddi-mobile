//
//  SurfaceIntegrationTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// The Phase 1 surfaces beyond IPAM, against a live control plane.
///
/// These exist because a compile only proves the generated types exist — it
/// proves nothing about whether the server fills the fields the screens read.
/// The two bugs this style of test has already caught here were both of that
/// kind: dropped nullable fields, and timestamps the decoder rejected.
@Suite(.enabled(if: LiveServer.isConfigured))
@MainActor
struct SurfaceIntegrationTests {

    // MARK: - Platform

    @Test("The health rollup parses into the shape the overview renders")
    func healthParses() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let container = try await session.client.platformHealthHealthPlatformGet().ok.body.json
        let health = try #require(
            PlatformHealth(container: container),
            "The overview cannot render a rollup it can't parse"
        )
        #expect(!health.status.isEmpty)
        #expect(!health.components.isEmpty, "A real control plane reports its components")
        #expect(health.components.allSatisfy { !$0.name.isEmpty && !$0.status.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("The version handshake returns something the gate can classify")
    func versionParses() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let version = try await session.client.getVersionApiV1VersionGet().ok.body.json
        #expect(!version.version.isEmpty)

        // Either it is CalVer or it is a development build; both are handled,
        // and neither may crash the gate.
        let parsed = ServerVersion(version.version)
        #expect(parsed.displayName == version.version || !parsed.isDevelopment)

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Identity and permissions decode")
    func identityDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let me = try await session.client.getMeApiV1AuthMeGet().ok.body.json
        #expect(!me.username.isEmpty)

        let permissions = try await session.client
            .getMyPermissionsApiV1AuthMePermissionsGet().ok.body.json
        #expect(permissions.isSuperadmin || !permissions.grants.isEmpty)

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - DNS

    @Test("DNS groups, zones and records decode down the whole chain")
    func dnsChainDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let groups = try await session.client.listGroupsApiV1DnsGroupsGet().ok.body.json
        #expect(!groups.isEmpty, "The lab should have at least one DNS group")
        #expect(groups.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })

        // Walk every group until one has zones: which group holds them is a
        // property of the lab's data, not of the client.
        var zonesFound: [Components.Schemas.ZoneResponse] = []
        var owningGroup: String?
        for group in groups {
            let zones = try await session.client
                .listZonesApiV1DnsGroupsGroupIdZonesGet(path: .init(groupId: group.id))
                .ok.body.json
            if !zones.isEmpty {
                zonesFound = zones
                owningGroup = group.id
                break
            }
        }

        let groupId = try #require(owningGroup, "No DNS group in the lab has zones")
        #expect(zonesFound.allSatisfy { !$0.name.isEmpty && !$0.zoneType.isEmpty })

        // A zone with no records still renders; one with records must decode.
        for zone in zonesFound {
            let page = try await session.client
                .listRecordsApiV1DnsGroupsGroupIdZonesZoneIdRecordsGet(
                    path: .init(groupId: groupId, zoneId: zone.id),
                    query: .init(page: 1, pageSize: 50)
                )
                .ok.body.json
            #expect(page.total >= page.items.count)
            #expect(page.items.allSatisfy { !$0.recordType.isEmpty })
            if !page.items.isEmpty { break }
        }

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - DHCP

    @Test("DHCP servers, stats, groups and scopes decode")
    func dhcpChainDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let servers = try await session.client.listServersApiV1DhcpServersGet().ok.body.json
        #expect(!servers.isEmpty, "The lab should have at least one DHCP server")
        #expect(servers.allSatisfy { !$0.name.isEmpty && !$0.status.isEmpty && !$0.driver.isEmpty })

        // Stats drive the traffic chart. `rateBuckets` carries timestamps, which
        // is exactly where a date-decoding mismatch would surface.
        let server = try #require(servers.first)
        let stats = try await session.client
            .getServerStatsApiV1DhcpServersServerIdStatsGet(path: .init(serverId: server.id))
            .ok.body.json
        #expect(stats.leasesActive >= 0)
        #expect(stats.bucketSeconds > 0)

        // Leases are paginated; an empty lab still has to return a valid page.
        let leases = try await session.client
            .listLeasesApiV1DhcpServersServerIdLeasesGet(
                path: .init(serverId: server.id),
                query: .init(page: 1, pageSize: 25)
            )
            .ok.body.json
        #expect(leases.total >= leases.items.count)
        #expect(leases.items.allSatisfy { !$0.ipAddress.isEmpty && !$0.macAddress.isEmpty })

        let groups = try await session.client.listGroupsApiV1DhcpServerGroupsGet().ok.body.json
        #expect(!groups.isEmpty)

        for group in groups {
            let scopes = try await session.client
                .listScopesForGroupApiV1DhcpServerGroupsGroupIdScopesGet(path: .init(groupId: group.id))
                .ok.body.json
            guard let scope = scopes.first else { continue }

            // The scope screen resolves the subnet behind the scope, and reads
            // pools and reservations. All three have to decode.
            #expect(!scope.subnetId.isEmpty)
            let pools = try await session.client
                .listPoolsApiV1DhcpScopesScopeIdPoolsGet(path: .init(scopeId: scope.id))
                .ok.body.json
            #expect(pools.allSatisfy { !$0.startIp.isEmpty && !$0.endIp.isEmpty })

            let statics = try await session.client
                .listStaticsApiV1DhcpScopesScopeIdStaticsGet(path: .init(scopeId: scope.id))
                .ok.body.json
            #expect(statics.allSatisfy { !$0.ipAddress.isEmpty && !$0.macAddress.isEmpty })
            break
        }

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - Alerts and search

    @Test("Alert events decode and classify into known severities")
    func alertsDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let events = try await session.client
            .listEventsApiV1AlertsEventsGet(query: .init(openOnly: false, limit: 50))
            .ok.body.json
        #expect(events.allSatisfy { !$0.message.isEmpty && !$0.severity.isEmpty })

        // `firedAt` is a date, and the lab has already produced microsecond
        // timestamps that a stricter decoder rejected.
        #expect(events.allSatisfy { $0.firedAt.timeIntervalSince1970 > 0 })

        // Unresolved-only must actually filter, or the overview's count is wrong.
        let open = try await session.client
            .listEventsApiV1AlertsEventsGet(query: .init(openOnly: true, limit: 50))
            .ok.body.json
        #expect(open.allSatisfy { $0.resolvedAt == nil })
        #expect(open.count <= events.count)

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Global search returns typed, labelled results")
    func searchDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let types = try await session.client.searchableTypesApiV1SearchTypesGet().ok.body.json
        #expect(!types.isEmpty)
        #expect(types.allSatisfy { !$0._type.isEmpty && !$0.label.isEmpty && !$0.group.isEmpty })

        // "e" matches broadly enough to return something on any populated lab
        // without depending on a particular object existing.
        let response = try await session.client
            .globalSearchApiV1SearchGet(query: .init(q: "e", limit: 25))
            .ok.body.json
        #expect(response.total >= response.results.count)
        #expect(response.results.allSatisfy { !$0._type.isEmpty && !$0.display.isEmpty })

        // Every result type must be one the type list named, or the search
        // screen has no label to group it under.
        let known = Set(types.map(\._type))
        #expect(response.results.allSatisfy { known.contains($0._type) })

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - The wider operator surfaces

    /// Every screen added for web-console parity, against the live control
    /// plane. These are the ones most likely to be wrong: they were written
    /// from the generated types alone, because nine of them answered 404 on a
    /// stock lab until their feature modules were switched on.
    @Test("Domains and TLS certificates decode, with the fields the expiry sort needs")
    func expirySurfacesDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let domains = try await session.client
            .listDomainsApiV1DomainsGet(query: .init(page: 1, pageSize: 50)).ok.body.json
        #expect(domains.total >= domains.items.count)
        #expect(domains.items.allSatisfy { !$0.name.isEmpty })

        let certs = try await session.client
            .listTargetsApiV1TlsCertsGet(query: .init(limit: 50)).ok.body.json
        #expect(certs.total >= certs.items.count)
        #expect(certs.items.allSatisfy { !$0.host.isEmpty && $0.port > 0 && !$0.state.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Network modelling surfaces decode")
    func networkSurfacesDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let vrfs = try await session.client.listVrfsApiV1VrfsGet(query: .init(limit: 50)).ok.body.json
        #expect(vrfs.allSatisfy { !$0.name.isEmpty })

        let routers = try await session.client.listRoutersApiV1VlansRoutersGet().ok.body.json
        #expect(routers.allSatisfy { !$0.name.isEmpty })
        // Walk into one router's VLANs — the nested call is the one a compile
        // cannot vouch for.
        if let router = routers.first {
            let vlans = try await session.client
                .listVlansApiV1VlansRoutersRouterIdVlansGet(path: .init(routerId: router.id))
                .ok.body.json
            #expect(vlans.allSatisfy { $0.vlanId > 0 })
        }

        let circuits = try await session.client
            .listCircuitsApiV1CircuitsGet(query: .init(limit: 50)).ok.body.json
        #expect(circuits.items.allSatisfy { !$0.name.isEmpty && !$0.transportClass.isEmpty })

        let asns = try await session.client.listAsnsApiV1AsnsGet(query: .init(limit: 50)).ok.body.json
        #expect(asns.items.allSatisfy { $0.number > 0 && !$0.registry.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Ownership entities decode")
    func ownershipDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let customers = try await session.client
            .listCustomersApiV1CustomersGet(query: .init(limit: 50)).ok.body.json
        #expect(customers.items.allSatisfy { !$0.name.isEmpty && !$0.status.isEmpty })

        let sites = try await session.client
            .listSitesApiV1SitesGet(query: .init(limit: 50)).ok.body.json
        #expect(sites.items.allSatisfy { !$0.name.isEmpty && !$0.kind.isEmpty })

        let providers = try await session.client
            .listProvidersApiV1ProvidersGet(query: .init(limit: 50)).ok.body.json
        #expect(providers.items.allSatisfy { !$0.name.isEmpty && !$0.kind.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Administration surfaces decode")
    func adminSurfacesDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let users = try await session.client.listUsersApiV1UsersGet().ok.body.json
        #expect(!users.isEmpty)
        #expect(users.allSatisfy { !$0.username.isEmpty && !$0.authSource.isEmpty })

        let sessions = try await session.client.listAllSessionsApiV1SessionsGet().ok.body.json
        #expect(sessions.allSatisfy { !$0.username.isEmpty })
        // The session doing the asking is a token, not a browser session, so
        // "exactly one is current" is not a safe assertion — but no more than
        // one ever may be.
        #expect(sessions.filter(\.isCurrent).count <= 1)

        let tokens = try await session.client.listTokensApiV1ApiTokensGet().ok.body.json
        #expect(tokens.allSatisfy { !$0.name.isEmpty && !$0.prefix.isEmpty })
        // The secret is shown once at mint time and must never come back on a
        // list. If this ever fails, the app is displaying live credentials.
        #expect(tokens.allSatisfy { $0.prefix.count < 32 })

        let audit = try await session.client.listAuditLogApiV1AuditGet(query: .init(limit: 25)).ok.body.json
        #expect(audit.total >= audit.items.count)
        #expect(audit.items.allSatisfy { !$0.action.isEmpty && !$0.result.isEmpty })

        let trash = try await session.client
            .listTrashApiV1AdminTrashGet(query: .init(limit: 25)).ok.body.json
        #expect(trash.items.allSatisfy { !$0._type.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Change requests and new-device sightings decode")
    func operationsSurfacesDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let requests = try await session.client
            .listRequestsApiV1ChangeRequestsGet(query: .init(limit: 50)).ok.body.json
        #expect(requests.allSatisfy { !$0.state.isEmpty && !$0.operation.isEmpty })

        let sightings = try await session.client
            .listSightingsApiV1NewDevicesSightingsGet(query: .init(page: 1, pageSize: 50))
            .ok.body.json
        #expect(sightings.total >= sightings.items.count)
        #expect(sightings.items.allSatisfy { !$0.macAddress.isEmpty && !$0.classification.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    /// The gate the sidebar depends on.
    @Test("The feature-module list is readable and reports a mix of states")
    func featureModulesDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let modules = try await session.client
            .listFeatureModulesApiV1AdminFeatureModulesGet().ok.body.json
        #expect(!modules.isEmpty)
        #expect(modules.allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty && !$0.group.isEmpty })
        // Every section the sidebar gates must name a module the server knows
        // about — a typo here would silently hide a screen forever.
        let known = Set(modules.map(\.id))
        for section in AppSection.allCases {
            if let module = section.featureModule {
                #expect(known.contains(module), "\(section.title) gates on unknown module \(module)")
            }
        }

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - Surfaces the 2026.09.04-1 re-pin added (#20)

    /// Generated since the re-pin; before it, this was the one hand-decoded
    /// report in the app. A null `days_stale` must survive as nil — "never
    /// seen" — not arrive as zero.
    @Test("The stale-address report decodes through the generated type")
    func staleReportDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let report = try await session.client
            .getStaleIpReportApiV1IpamReportsStaleIpsGet(
                query: .init(staleDays: 1, includeNeverSeen: true, limit: 20)
            ).ok.body.json
        #expect(report.total >= report.entries.count)
        #expect(report.entries.allSatisfy { !$0.id.isEmpty && !$0.address.isEmpty && !$0.status.isEmpty })
        #expect(report.entries.allSatisfy { ($0.daysStale ?? 0) >= 0 })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Fleet-wide leases and lease history decode")
    func fleetLeasesDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let leases = try await session.client
            .listAllLeasesApiV1DhcpLeasesGet(query: .init(page: 1, pageSize: 50)).ok.body.json
        #expect(leases.total >= leases.items.count)
        #expect(leases.items.allSatisfy { !$0.macAddress.isEmpty && !$0.ipAddress.isEmpty })

        let history = try await session.client
            .listAllLeaseHistoryApiV1DhcpLeaseHistoryGet(query: .init(page: 1, perPage: 50)).ok.body.json
        #expect(history.total >= history.items.count)
        #expect(history.items.allSatisfy { !$0.macAddress.isEmpty && !$0.leaseState.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("The hygiene report's counts agree with its lists")
    func hygieneDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let report = try await session.client
            .getIpHygieneReportApiV1IpamReportsHygieneGet(query: .init(limit: 50)).ok.body.json
        // A list can be truncated to `limit`; a count is never smaller than it.
        #expect(report.counts.freeButResponding >= report.freeButResponding.count)
        #expect(report.counts.staleReservations >= report.staleReservations.count)
        #expect(report.counts.unknownMacInStaticRange >= report.unknownMacInStaticRange.count)

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("The vendor rollup and a customer summary decode")
    func rollupsDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let vendors = try await session.client
            .getVendorRollupApiV1IpamReportsVendorsGet(query: .init(limit: 20)).ok.body.json
        #expect(vendors.totalWithVendor <= vendors.totalMacsSeen)
        #expect(vendors.vendors.allSatisfy { !$0.vendor.isEmpty && $0.count > 0 })

        let customers = try await session.client
            .listCustomersApiV1CustomersGet(query: .init(limit: 1)).ok.body.json
        if let customer = customers.items.first {
            let summary = try await session.client
                .getCustomerSummaryRouteApiV1CustomersCustomerIdSummaryGet(
                    path: .init(customerId: customer.id)
                ).ok.body.json
            #expect(summary.id == customer.id)
            #expect(summary.ownedResourceTotal >= 0)
        }

        try store.removePin(for: #require(LiveServer.address))
    }
}
