//
//  AppSection.swift
//  SpatiumDDI
//

import Foundation

/// One destination in the app's sidebar.
///
/// A sidebar rather than a tab bar, and not only as a matter of taste. Seven
/// tabs do not fit on a phone, so UIKit pushes the overflow into a "More" list
/// that wraps them in *its own* navigation controller — and since every section
/// here is already a navigation stack, that nesting drew two navigation bars and
/// two back buttons on exactly the sections that overflowed. A sidebar has no
/// overflow, so the problem cannot recur as sections are added.
nonisolated enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case alerts
    case changeRequests
    case requests
    case clientLookup
    case dhcpLog
    case newDevices
    case ipam
    case dns
    case dhcp
    case domains
    case certificates
    case devices
    case vlans
    case vrfs
    case circuits
    case asns
    case lookingGlass
    case ownership
    case integrations
    case access
    case audit
    case trash
    case networkTools
    case search
    case server
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .alerts: "Alerts"
        case .changeRequests: "Change Requests"
        case .requests: "Requests"
        case .clientLookup: "Client Lookup"
        case .dhcpLog: "DHCP Log"
        case .newDevices: "New Devices"
        case .ipam: "IPAM"
        case .dns: "DNS"
        case .dhcp: "DHCP"
        case .domains: "Domains"
        case .certificates: "Certificates"
        case .devices: "Devices"
        case .vlans: "VLANs"
        case .vrfs: "VRFs"
        case .circuits: "Circuits"
        case .asns: "ASNs"
        case .lookingGlass: "Looking Glass"
        case .integrations: "Integrations"
        case .ownership: "Ownership"
        case .access: "Access"
        case .audit: "Audit Log"
        case .trash: "Trash"
        case .networkTools: "Network Tools"
        case .search: "Search"
        case .server: "Server"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .alerts: "bell"
        case .changeRequests: "checkmark.seal"
        case .requests: "tray"
        case .clientLookup: "person.crop.circle.badge.questionmark"
        case .dhcpLog: "doc.text.magnifyingglass"
        case .newDevices: "sensor.tag.radiowaves.forward"
        case .ipam: "square.grid.3x3"
        case .dns: "globe"
        case .dhcp: "arrow.left.arrow.right"
        case .domains: "at"
        case .certificates: "lock.shield"
        case .devices: "switch.2"
        case .vlans: "point.3.connected.trianglepath.dotted"
        case .vrfs: "arrow.triangle.branch"
        case .circuits: "cable.connector"
        case .asns: "number"
        case .lookingGlass: "binoculars"
        case .integrations: "puzzlepiece.extension"
        case .ownership: "building.2"
        case .access: "person.2.badge.key"
        case .audit: "list.bullet.rectangle"
        case .trash: "trash"
        case .networkTools: "stethoscope"
        case .search: "magnifyingglass"
        case .server: "gear"
        case .about: "info.circle"
        }
    }

    /// The optional platform module this section needs, if any.
    ///
    /// A control plane with the module switched off answers 404 from every one
    /// of that section's endpoints, so the section is hidden rather than
    /// offered as a screen that can only ever report being unavailable. Core
    /// DDI — IPAM, DNS, DHCP, alerts, search — is not togglable and so is not
    /// gated here.
    var featureModule: String? {
        switch self {
        // Domains deliberately absent: there is no `network.domain` module —
        // domain tracking is always on. Naming a module the server does not
        // have would hide the screen permanently, because the gate only fails
        // open while the module list is unknown.
        //
        // Integrations deliberately absent too, for the opposite reason: the
        // modules are per-integration (`integrations.unifi`, `.netbox`, and so
        // on), so there is no one id to name — and the summary endpoint is
        // ungated and reports each panel's own `enabled`, which the screen
        // filters on. The gate is one layer down, not missing.
        case .changeRequests: "governance.approvals"
        // A separate, default-off module: an install can run the approval
        // gate without the self-service portal, and the reverse.
        case .requests: "governance.requests"
        case .newDevices: "security.new_device_watch"
        case .certificates: "security.tls_certs"
        case .devices: "network.device"
        case .vlans: "network.vlan"
        case .vrfs: "network.vrf"
        case .circuits: "network.circuit"
        case .asns: "network.asn"
        case .lookingGlass: "network.looking_glass"
        case .ownership: "network.customer"
        case .networkTools: "tools.network"
        default: nil
        }
    }

    /// Grouped so the sidebar reads as the estate first, then the tools, then
    /// the connection — rather than as seven equally-weighted items.
    enum Group: String, CaseIterable, Identifiable {
        case monitor = "Monitor"
        case estate = "Estate"
        case network = "Network"
        case administration = "Administration"
        case tools = "Tools"

        var id: Self { self }

        var sections: [AppSection] {
            switch self {
            case .monitor: [.overview, .alerts, .clientLookup, .changeRequests, .requests, .newDevices]
            case .estate: [.ipam, .dns, .dhcp, .dhcpLog, .domains, .certificates]
            case .network: [.devices, .vlans, .vrfs, .circuits, .asns, .lookingGlass]
            case .administration: [.ownership, .access, .integrations, .audit, .trash]
            case .tools: [.networkTools, .search, .server, .about]
            }
        }
    }
}
