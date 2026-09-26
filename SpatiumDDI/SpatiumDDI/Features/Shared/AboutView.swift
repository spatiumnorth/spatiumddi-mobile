//
//  AboutView.swift
//  SpatiumDDI
//

import SwiftUI

/// What this is, what it's built on, and what licence it's under.
///
/// Apache 2.0 requires that the licence and any NOTICE travel with the work,
/// and a repo file satisfies that for source. It does not satisfy it for
/// someone holding a compiled app — so the terms are reachable from inside the
/// app too, alongside the third-party notices for everything it links.
struct AboutView: View {
    /// Read from the bundle rather than hard-coded, so it cannot drift from
    /// what was actually built.
    private var version: String {
        let marketing =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(marketing) (\(build))"
    }

    private static let repository = URL(string: "https://github.com/spatiumnorth/spatiumddi-mobile")!
    private static let platform = URL(string: "https://github.com/spatiumnorth/spatiumddi")!
    private static let licence = URL(
        string: "https://github.com/spatiumnorth/spatiumddi-mobile/blob/main/LICENSE")!
    private static let issues = URL(
        string: "https://github.com/spatiumnorth/spatiumddi-mobile/issues")!

    var body: some View {
        List {
            Section {
                BrandLockup(markSize: 64, caption: "Native client for the SpatiumDDI control plane.")
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section("Version") {
                LabeledContent("App", value: version)
                LabeledContent("Minimum server", value: SupportedServer.minimum.displayName)
            }

            Section {
                Link(destination: Self.repository) {
                    Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Self.platform) {
                    Label("SpatiumDDI platform", systemImage: "server.rack")
                }
                Link(destination: Self.issues) {
                    Label("Report an app bug", systemImage: "ladybug")
                }
            } header: {
                Text("Project")
            } footer: {
                // Where a report goes decides whether it gets read. Feature work
                // lives upstream; splitting a roadmap across two trackers is how
                // things get lost.
                Text(
                    "App bugs — layout, navigation, crashes — belong on this repo. Feature requests and anything about the API belong on the platform repo."
                )
            }

            Section {
                Link(destination: Self.licence) {
                    Label("Apache License 2.0", systemImage: "doc.text")
                }
            } header: {
                Text("Licence")
            } footer: {
                Text(
                    "Copyright the SpatiumDDI contributors. Licensed under the Apache License, Version 2.0. You may not use this software except in compliance with the licence."
                )
            }

            Section {
                ForEach(ThirdParty.all) { package in
                    Link(destination: package.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.name)
                            Text("\(package.licence) · \(package.owner)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Open source")
            } footer: {
                Text("This app links the following, each under its own licence.")
            }

            Section {
                Label(
                    "No telemetry, analytics or crash reporting leaves this device.",
                    systemImage: "hand.raised"
                )
                .font(.callout)
                Label(
                    "No data from your control plane is written to disk.",
                    systemImage: "externaldrive.badge.xmark"
                )
                .font(.callout)
                Label(
                    "Your token is held in the Keychain behind biometrics.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    "Operators run SpatiumDDI self-hosted and often air-gapped. This app talks to your control plane and nothing else."
                )
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What this app links, for the attribution those licences require.
///
/// Listed by hand rather than generated: Swift Package Manager has no
/// acknowledgements export, and a stale generated list would be worse than a
/// short accurate one. Everything here ships inside the binary.
nonisolated struct ThirdParty: Identifiable {
    let name: String
    let owner: String
    let licence: String
    let url: URL

    var id: String { name }

    static let all: [ThirdParty] = [
        ThirdParty(
            name: "swift-openapi-generator", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-openapi-generator")!),
        ThirdParty(
            name: "swift-openapi-runtime", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-openapi-runtime")!),
        ThirdParty(
            name: "swift-openapi-urlsession", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-openapi-urlsession")!),
        ThirdParty(
            name: "swift-http-types", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-http-types")!),
        ThirdParty(
            name: "swift-collections", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-collections")!),
        ThirdParty(
            name: "swift-algorithms", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-algorithms")!),
        ThirdParty(
            name: "swift-numerics", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-numerics")!),
        ThirdParty(
            name: "swift-argument-parser", owner: "Apple", licence: "Apache 2.0",
            url: URL(string: "https://github.com/apple/swift-argument-parser")!),
        ThirdParty(
            name: "OpenAPIKit", owner: "Mathew Polzin", licence: "MIT",
            url: URL(string: "https://github.com/mattpolzin/OpenAPIKit")!),
        ThirdParty(
            name: "Yams", owner: "JP Simard", licence: "MIT",
            url: URL(string: "https://github.com/jpsim/Yams")!),
    ]
}
