//
//  AppRootView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

struct AppRootView: View {
    @State private var flow = AppFlowModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .animation(.default, value: flow.stage)
            .onChange(of: scenePhase) { _, phase in
                // Lock as the app leaves the foreground, not when it returns —
                // the token must not be resident while the app is backgrounded.
                if phase != .active {
                    flow.lockForBackground()
                } else {
                    // Becoming active is the first moment the Keychain is
                    // certain to answer. A launch that happened while the
                    // device was locked — a prewarm, or a relaunch after a
                    // force-quit — cannot see an item stored
                    // `WhenPasscodeSetThisDeviceOnly`, and would otherwise
                    // spend the whole session believing there was no token.
                    flow.reconsiderIfUntouched()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {
        case .servers:
            ServerListView(
                servers: flow.servers,
                currentID: flow.currentServerID,
                hasToken: { flow.hasToken(for: $0) },
                protection: { flow.protection(for: $0) },
                onSelect: { flow.select($0) },
                onAdd: { flow.showAddServer() },
                onRemove: { flow.remove($0) },
                onRename: { flow.rename($0, to: $1) }
            )

        case .addServer:
            ServerSetupView(
                onConnected: { outcome in
                    switch outcome {
                    case .enrolled(let server, let token):
                        flow.enrolled(with: token, to: server)
                    case .needsSignIn(let server, let prefill):
                        flow.connected(to: server, pendingToken: prefill)
                    }
                },
                // Only offered when there is a list to go back to.
                onCancel: flow.servers.isEmpty ? nil : { flow.showServers() }
            )

        case .signIn(let server):
            SignInView(
                model: SignInModel(server: server, prefilledToken: flow.pendingToken) { token in
                    flow.signedIn(with: token, to: server)
                },
                onChangeServer: { flow.showServers() },
                absence: flow.tokenAbsence
            )

        case .locked(let server, let message):
            UnlockView(
                address: server.address,
                protection: flow.protection(for: server) ?? .biometrics,
                message: message,
                onUnlock: { Task { await flow.unlock() } },
                onSignOut: { flow.signOut() }
            )
            // Keyed on the scene phase, not a bare `.task`: locking happens the
            // moment the app stops being active, so a plain on-appear prompt
            // fires while the app is backgrounded, is cancelled by the system,
            // and never comes back. Re-running on the way to `.active` asks at
            // the only moment biometry can actually succeed.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await flow.unlock()
            }

        case .signedIn(let server):
            if let token = flow.token {
                SignedInView(
                    server: server,
                    token: token,
                    protection: flow.protection(for: server),
                    onSignOut: { flow.signOut() },
                    onSwitchServer: { flow.showServers() },
                    onRename: { flow.rename(server, to: $0) },
                    onSessionRejected: { flow.sessionRejected() }
                )
            } else {
                // Only reachable if the token was dropped between the state
                // change and this render; locking is the honest response.
                ProgressView().task { flow.lockForBackground() }
            }
        }
    }
}

/// The signed-in shell.
///
/// Only the surfaces that are actually built appear here — an app for production
/// networking should not show a screen implying it knows something it does not.
struct SignedInView: View {
    let server: StoredServer
    let token: String
    /// What is holding this server's token, for the Server screen to report.
    let protection: KeychainProtection?
    let onSignOut: () -> Void
    let onSwitchServer: () -> Void
    let onRename: (String?) -> Void
    /// Called when the server rejects the credential this session was built with.
    let onSessionRejected: () -> Void

    private var address: ServerAddress { server.address }

    /// Built once and torn down explicitly.
    ///
    /// A `URLSession` with a delegate holds that delegate until it is
    /// invalidated, so constructing the session inline in `body` — which SwiftUI
    /// re-evaluates freely — leaks a session and a `ServerTrustDelegate` every
    /// time it runs. State that owns a resource has to outlive a render.
    @State private var session: ControlPlaneSession?

    /// Which section the sidebar has selected.
    ///
    /// Starts as `nil` so signing in lands on the menu rather than pushing
    /// straight into a screen. On a phone that means the first thing after
    /// unlocking is a list of where you can go — which is also what makes the
    /// back button read as "Menu" rather than stranding you one level deep with
    /// no obvious way to the rest of the app.
    @State private var section: AppSection?
    @State private var features = FeatureModules()
    /// Read once per session and handed down, so a write button can be hidden
    /// from someone who cannot use it. UX only — see `Permissions`.
    @State private var permissions = Permissions()
    /// Bound so the system can open and close the sidebar itself.
    ///
    /// Left at `.automatic` deliberately: that is what keeps the sidebar
    /// on screen beside the detail on a landscape iPad, and folds it away when
    /// the window is too narrow to justify it. Pinning it to `.all` would force
    /// it into portrait and on a Slide Over window, where it leaves no room for
    /// the screen you actually opened.
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        Group {
            if let session {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    List(selection: $section) {
                        Section {
                            HStack(spacing: 10) {
                                BrandMark(size: 30)
                                VStack(alignment: .leading, spacing: 0) {
                                    // The server, not the product. Which estate
                                    // is loaded is the fact that decides whether
                                    // a write lands in the right place, so it is
                                    // the one that gets the headline.
                                    Text(verbatim: server.displayName)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(verbatim: server.subtitle ?? session.address.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .listRowBackground(Color.clear)
                        }

                        ForEach(AppSection.Group.allCases) { group in
                            let available = group.sections.filter {
                                features.isAvailable($0.featureModule)
                            }
                            // A group whose every section is switched off is
                            // not rendered as an empty heading.
                            if !available.isEmpty {
                                Section(group.rawValue) {
                                    ForEach(available) { item in
                                        Label(item.title, systemImage: item.symbol).tag(item)
                                    }
                                }
                            }
                        }
                    }
                    // Titled so the back button from any section reads
                    // "Menu" — the affordance an operator is looking for when
                    // they want to go somewhere else.
                    .navigationTitle("Menu")
                    .navigationBarTitleDisplayMode(.inline)
                } detail: {
                    // A NavigationStack here is the documented split-view
                    // pattern: SwiftUI merges it with the sidebar's stack when
                    // the layout collapses on a phone, so pushes still get
                    // exactly one back button.
                    NavigationStack {
                        if let section {
                            detail(for: section, session: session)
                        } else {
                            // Only ever seen on iPad, where the detail column
                            // is always on screen. A collapsed split view shows
                            // the sidebar itself instead of pushing this.
                            ContentUnavailableView {
                                BrandLockup(markSize: 64)
                            } description: {
                                Text("Choose a section to begin.")
                            }
                        }
                    }
                }
                // `.balanced` gives the sidebar its own column beside the
                // detail. The default would let the detail keep full width and
                // slide the sidebar over the top of it, which is the wrong
                // trade on a screen big enough to show both.
                .navigationSplitViewStyle(.balanced)
                .environment(permissions)
                .environment(features)
            } else {
                ProgressView()
            }
        }
        // Keyed on the server as well as the token: two control planes are two
        // sessions even if a token were somehow shared, and a stale client
        // pointed at the estate you just left is the exact failure that makes
        // "which server am I on" dangerous rather than merely confusing.
        .task(id: [server.id, token]) {
            session?.invalidate()
            let created = ControlPlaneSession(address: address, token: token) {
                // The middleware runs on whatever queue the response arrived on.
                Task { @MainActor in onSessionRejected() }
            }
            session = created
            // Read once per session, before the sidebar settles. Both fail
            // open: a module list or a grant list this app couldn't read
            // leaves everything visible rather than hiding the app.
            async let modules: Void = features.load(from: created)
            async let grants: Void = permissions.load(from: created)
            _ = await (modules, grants)
        }
        .onDisappear {
            session?.invalidate()
            session = nil
        }
    }

    @ViewBuilder
    private func detail(for section: AppSection, session: ControlPlaneSession) -> some View {
        switch section {
        case .overview:
            OverviewView(session: session, onSelfRevoked: onSessionRejected)
        case .alerts:
            AlertsView(session: session)
        case .changeRequests:
            ChangeRequestsView(session: session)
        case .requests:
            SelfServiceRequestsView(session: session)
        case .clientLookup:
            ClientLookupView(session: session)
        case .dhcpLog:
            DHCPActivityView(session: session)
        case .dnsLog:
            DNSQueryLogView(session: session)
        case .newDevices:
            NewDevicesView(session: session)
        case .ipam:
            IPAMBrowseView(session: session)
        case .dns:
            DNSBrowseView(session: session)
        case .dhcp:
            DHCPBrowseView(session: session)
        case .domains:
            DomainsView(session: session)
        case .certificates:
            CertificatesView(session: session)
        case .devices:
            NetworkDevicesView(session: session)
        case .vlans:
            VLANRoutersView(session: session)
        case .vrfs:
            VRFsView(session: session)
        case .circuits:
            CircuitsView(session: session)
        case .asns:
            ASNsView(session: session)
        case .lookingGlass:
            LookingGlassView(session: session)
        case .ownership:
            OwnershipView(session: session)
        case .integrations:
            IntegrationsView(session: session)
        case .access:
            // The sign-out path is the same one a server-side rejection takes:
            // revoking this device's own token *is* the server rejecting it,
            // one request early.
            AccessView(session: session, onSelfRevoked: onSessionRejected)
        case .audit:
            AuditLogView(session: session)
        case .trash:
            TrashView(session: session)
        case .networkTools:
            NetworkToolsView(session: session)
        case .search:
            SearchView(session: session)
        case .about:
            AboutView()
        case .server:
            ServerDetailView(
                server: server,
                session: session,
                protection: protection,
                onSignOut: onSignOut,
                onSwitchServer: onSwitchServer,
                onRename: onRename
            )
        }
    }
}

/// Connection, identity and session controls.
struct ServerDetailView: View {
    let server: StoredServer
    let session: ControlPlaneSession
    let protection: KeychainProtection?
    let onSignOut: () -> Void
    let onSwitchServer: () -> Void
    let onRename: (String?) -> Void

    private var address: ServerAddress { server.address }

    @State private var isRenaming = false
    @State private var identity: LoadState<Components.Schemas.AppApiV1AuthRouterUserResponse> = .idle
    @State private var permissions: LoadState<Components.Schemas.MyPermissionsResponse> = .idle

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Name") {
                    // The operator's own word for this estate. Rendered
                    // verbatim: it is their text, not this app's, so it is
                    // neither translated nor parsed as Markdown.
                    Text(verbatim: server.trimmedLabel ?? server.address.displayName)
                }
                LabeledContent("Address", value: address.displayName)
                LabeledContent("Built against", value: SupportedServer.minimum.displayName)
                Button("Rename This Server") { isRenaming = true }
            }

            // What is actually holding the token on this device. Stated rather
            // than assumed: a passcode-gated token is a weaker promise than a
            // biometric one, and the operator is entitled to know which they
            // have without working it out from their device settings.
            Section {
                if let protection {
                    LabeledContent("Protected by") {
                        Label(protection.summary, systemImage: protection.symbol)
                            .foregroundStyle(protection == .passcode ? .orange : .primary)
                    }
                } else {
                    // The in-memory token outlives the Keychain item after a
                    // sign-out elsewhere; saying "none" beats implying one.
                    Label("No token is stored on this device.", systemImage: "lock.slash")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("This Device")
            } footer: {
                if let caveat = protection?.caveat { Text(caveat) }
            }

            MaintenanceSection(
                session: session,
                serverName: server.trimmedLabel ?? address.displayName
            )

            Section("Signed in as") {
                LoadStateView(
                    state: identity,
                    emptyMessage: "The server didn't return an identity.",
                    retry: { Task { await fetchIdentity() } }
                ) { me in
                    LabeledContent("User", value: me.displayName.isEmpty ? me.username : me.displayName)
                    LabeledContent("Username", value: me.username)
                    if !me.email.isEmpty { LabeledContent("Email", value: me.email) }
                    LabeledContent("Auth source", value: me.authSource)
                    if me.forcePasswordChange {
                        Label(
                            "This account must change its password on the web console.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                LoadStateView(
                    state: permissions,
                    emptyMessage: "This account has no grants.",
                    retry: { Task { await fetchPermissions() } }
                ) { permissions in
                    if permissions.isSuperadmin {
                        Label("Superadmin — every action on every resource.", systemImage: "key.fill")
                            .foregroundStyle(.orange)
                    } else if permissions.grants.isEmpty {
                        // LoadStateView's empty message cannot fire here — the
                        // response is an object, not a collection — so an
                        // account with no grants would otherwise get a blank
                        // section and no explanation for why every other screen
                        // is empty too.
                        Label(
                            "This account has no grants. Most screens will stay empty until an administrator gives it read access.",
                            systemImage: "lock.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else {
                        ForEach(Array(permissions.grants.enumerated()), id: \.offset) { _, grant in
                            LabeledContent(grant.resourceType) {
                                Text(grant.action).font(.caption.monospaced())
                            }
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                // Non-negotiable #4, said out loud rather than only honoured in
                // code: this list is what the app uses to decide what to show,
                // and it is not what stops anyone doing anything.
                Text(
                    "The server enforces these independently. What this app shows or hides is a convenience, not a security boundary."
                )
            }

            Section {
                Button("Switch Server", action: onSwitchServer)
                Button("Sign Out", role: .destructive, action: onSignOut)
            } footer: {
                Text(
                    "Signing out deletes this device's stored token for \(address.displayName). The server stays in your list, with its name and its approved certificate."
                )
            }
        }
        .navigationTitle("Server")
        .refreshable { await refresh() }
        .task { if case .idle = identity { await refresh() } }
        .sheet(isPresented: $isRenaming) {
            RenameServerSheet(server: server) { label in
                onRename(label)
                isRenaming = false
            } onCancel: {
                isRenaming = false
            }
        }
    }

    private func refresh() async {
        async let a: Void = fetchIdentity()
        async let b: Void = fetchPermissions()
        _ = await (a, b)
    }

    private func fetchIdentity() async {
        identity = .loading
        identity = await LoadState.fetching {
            switch try await session.client.getMeApiV1AuthMeGet() {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchPermissions() async {
        permissions = .loading
        permissions = await LoadState.fetching {
            switch try await session.client.getMyPermissionsApiV1AuthMePermissionsGet() {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
