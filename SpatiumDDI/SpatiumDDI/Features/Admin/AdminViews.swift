//
//  AdminViews.swift
//  SpatiumDDI
//

import OpenAPIRuntime
import SpatiumAPI
import SwiftUI

/// Never-before-seen MACs on the network.
///
/// Arpwatch, essentially. The value on a phone is that "something new appeared
/// on the plant floor segment" is a question you want answered while you are
/// standing near the plant floor.
struct NewDevicesView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.SightingOut]> = .idle
    @State private var total = 0
    @State private var includeRandomised = false
    /// The sighting waiting on a confirmation, if any.
    @State private var pending: Components.Schemas.SightingOut?
    @State private var acknowledgingID: String?
    @State private var failure: FailureMessage?

    var body: some View {
        List {
            Section {
                // Randomised MACs are excluded by default upstream too: a modern
                // phone walking past generates a new one every time, and they
                // would bury the sightings that mean something.
                Toggle("Include randomised MACs", isOn: $includeRandomised)
            } footer: {
                Text("Phones rotate their MAC by design, so those sightings are usually noise.")
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: "No new devices have been seen.",
                    retry: { Task { await fetch() } }
                ) { sightings in
                    ForEach(sightings, id: \.id) { sighting in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(sighting.ipAddress).font(.body.monospaced())
                                Spacer()
                                if acknowledgingID == sighting.id {
                                    ProgressView()
                                } else if sighting.acknowledgedAt != nil {
                                    Badge(localised: "acknowledged", tint: .green)
                                }
                                Badge(
                                    text: sighting.classification,
                                    tint: sighting.classification.lowercased() == "unknown"
                                        ? .orange : .secondary
                                )
                            }
                            Text(sighting.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if let vendor = sighting.ouiVendor, !vendor.isEmpty { Text(vendor) }
                                if let subnet = sighting.subnetName, !subnet.isEmpty { Text(subnet) }
                                Text(
                                    "first seen \(sighting.firstSeen.formatted(.relative(presentation: .named)))"
                                )
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            if sighting.isRandomized {
                                Badge(localised: "randomised MAC")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if sighting.acknowledgedAt == nil {
                                Button {
                                    failure = nil
                                    pending = sighting
                                } label: {
                                    Label("Acknowledge", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            } header: {
                if case .loaded(let rows) = state, total > rows.count {
                    Text("Sightings — showing \(rows.count) of \(total)")
                } else {
                    Text("Sightings")
                }
            }

            if let failure {
                Section("Not acknowledged") {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("New Devices")
        .refreshable { await fetch() }
        .task(id: includeRandomised) { await fetch() }
        .alert(
            "Acknowledge this device?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { sighting in
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Acknowledge") { Task { await acknowledge(sighting) } }
        } message: { sighting in
            Text(verbatim: acknowledgementSummary(for: sighting))
        }
    }

    /// What is being acknowledged, in the terms the row shows it.
    ///
    /// Names the MAC as well as the address: the address is what the row leads
    /// with, but the MAC is the thing the sighting is actually about, and on a
    /// randomised one it is also the reason this may not stay acknowledged.
    private func acknowledgementSummary(for sighting: Components.Schemas.SightingOut) -> String {
        var lines = ["\(sighting.macAddress) at \(sighting.ipAddress)"]
        if let vendor = sighting.ouiVendor, !vendor.isEmpty { lines.append(vendor) }
        lines.append(
            String(
                localized:
                    "It stops counting as new. This says you have seen it, and changes nothing about what it is allowed to do."
            )
        )
        if sighting.isRandomized {
            lines.append(
                String(
                    localized:
                        "This MAC is randomised, so the same device will appear again under a different one."
                )
            )
        }
        return lines.joined(separator: "\n\n")
    }

    private func acknowledge(_ sighting: Components.Schemas.SightingOut) async {
        pending = nil
        acknowledgingID = sighting.id
        failure = nil
        defer { acknowledgingID = nil }

        do {
            let response =
                try await session.client
                .acknowledgeApiV1NewDevicesSightingsSightingIdAcknowledgePost(
                    path: .init(sightingId: sighting.id),
                    // No note from the phone: the sheet that would collect one
                    // costs more taps than the acknowledgement is worth, and
                    // an empty note is not worse than no note.
                    body: .json(.init(note: nil))
                )
            switch response {
            case .ok(let ok):
                let acknowledged = try ok.body.json
                guard case .loaded(let rows) = state else { return }
                // The list is not filtered on acknowledgement, so the row
                // stays and gains its badge.
                state = .loaded(RowUpdate.apply(acknowledged, to: rows, id: \.id))
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listSightingsApiV1NewDevicesSightingsGet(
                query: .init(includeRandomized: includeRandomised, page: 1, pageSize: 200)
            )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                return page.items.sorted { $0.firstSeen > $1.firstSeen }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// A credential the operator has asked to revoke.
///
/// One type for both kinds because the sheet is the same shape either way and
/// only the sentence differs — and that sentence is the part that has to be
/// right, so each is written once here rather than assembled at three call
/// sites.
private enum RevocationTarget: Identifiable {
    /// An API token. `isThisDevice` is what stops the operator killing the
    /// credential they are standing on without being told.
    case token(Components.Schemas.ApiTokenResponse, isThisDevice: Bool)
    case session(Components.Schemas.SessionRow)

    var id: String {
        switch self {
        case .token(let token, _): "token-\(token.id)"
        case .session(let row): "session-\(row.id)"
        }
    }

    /// What the operator types to prove they meant it.
    var subject: String {
        switch self {
        case .token(let token, _): token.name
        case .session(let row): row.username
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .token(_, isThisDevice: true): "Revoke this device's own token?"
        case .token(_, isThisDevice: false): "Revoke this token?"
        case .session: "Revoke this session?"
        }
    }

    /// What happens, stated as fact. Never "are you sure".
    var consequence: LocalizedStringResource {
        switch self {
        case .token(_, isThisDevice: true):
            """
            This is the token this app is signed in with. Revoking it signs \
            you out on this device immediately — sign in again to mint a \
            replacement.
            """
        case .token(_, isThisDevice: false):
            """
            Whatever holds this token stops working immediately, including a \
            lost or stolen device. It cannot be restored; a replacement has to \
            be minted.
            """
        case .session:
            """
            That browser session is signed out immediately and lands back at \
            the login page. Anything unsaved in it is lost.
            """
        }
    }

    var caution: FailureMessage? {
        switch self {
        case .token(let token, isThisDevice: false) where !token.isActive:
            .app("This token is already inactive, so revoking it changes nothing that is still working.")
        case .session(let row) where row.isCurrent:
            .app("The server reports this as the session making this request.")
        default:
            nil
        }
    }
}

/// Who can sign in, who is signed in, and what tokens exist — and which of
/// them should stop.
///
/// One screen with a picker rather than three sidebar entries, for the same
/// reason ownership is: these are looked up together when answering one
/// question — "who has access, and should they still".
///
/// The second half of that question is the write this screen carries. Every
/// sign-in mints a per-device `sddi_` token, so the phone that leaves a pocket
/// is a credential still in the wild; the operator wants it dead from whatever
/// device they are still holding, and a response that begins "find a laptop"
/// is not a response.
struct AccessView: View {
    let session: ControlPlaneSession
    /// Called when the operator revokes the credential this app itself holds.
    ///
    /// A no-op default keeps previews and tests buildable, but the app always
    /// passes the real sign-out: after this particular revocation every
    /// subsequent request is a 401, and staying on the screen would present
    /// that as a series of errors rather than as the sign-out it is.
    var onSelfRevoked: () -> Void = {}

    @Environment(Permissions.self) private var permissions

    enum Kind: String, CaseIterable, Identifiable {
        case users = "Users"
        case sessions = "Sessions"
        case tokens = "Tokens"
        var id: Self { self }
    }

    @State private var kind: Kind = .users
    @State private var users: LoadState<[Components.Schemas.AppApiV1UsersRouterUserResponse]> = .idle
    @State private var sessions: LoadState<[Components.Schemas.SessionRow]> = .idle
    @State private var tokens: LoadState<[Components.Schemas.ApiTokenResponse]> = .idle

    /// The credential waiting on a typed confirmation, if any.
    @State private var pending: RevocationTarget?
    @State private var isRevoking = false
    @State private var revocationFailure: FailureMessage?

    /// Tokens are their own resource type in the grammar; sessions are part of
    /// user administration, which the platform notes is superadmin in practice.
    private var mayRevokeTokens: Bool { permissions.canWrite("api_token") }
    private var mayRevokeSessions: Bool { permissions.canWrite("user") }

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
            case .users:
                LoadStateView(state: users, emptyMessage: "No users.", retry: { load(.users) }) { rows in
                    ForEach(rows, id: \.id) { user in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(user.displayName.isEmpty ? user.username : user.displayName)
                                Spacer()
                                if user.isSuperadmin { Badge(localised: "superadmin", tint: .orange) }
                                if !user.isActive { Badge(localised: "disabled", tint: .secondary) }
                                if user.locked == true { Badge(localised: "locked", tint: .red) }
                            }
                            Text("\(user.username) · \(user.authSource)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("last login \(Date.relativeOrNever(user.lastLoginAt))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

            case .sessions:
                LoadStateView(
                    state: sessions, emptyMessage: "No active sessions.", retry: { load(.sessions) }
                ) { rows in
                    ForEach(rows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.displayName.isEmpty ? row.username : row.displayName)
                                Spacer()
                                if row.isCurrent { Badge(localised: "this device", tint: .green) }
                                if row.revoked { Badge(localised: "revoked", tint: .red) }
                            }
                            if let ip = row.sourceIp, !ip.isEmpty {
                                Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let agent = row.userAgent, !agent.isEmpty {
                                Text(agent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Text(
                                "seen \(Date.relativeOrNever(row.lastSeenAt)) · expires \(row.expiresAt.formatted(.relative(presentation: .named)))"
                            )
                            .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // An already-revoked session has nothing left to
                            // revoke, so the affordance is absent rather than
                            // present and pointless.
                            if mayRevokeSessions && !row.revoked {
                                Button(role: .destructive) {
                                    revocationFailure = nil
                                    pending = .session(row)
                                } label: {
                                    Label("Revoke", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }

            case .tokens:
                LoadStateView(state: tokens, emptyMessage: "No API tokens.", retry: { load(.tokens) }) {
                    rows in
                    ForEach(rows, id: \.id) { token in
                        let mine = isThisDevice(token, among: rows)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(token.name)
                                Spacer()
                                // Named on the row, not only in the sheet. The
                                // operator scanning for the phone they lost
                                // needs to know which one *not* to pick before
                                // they swipe, not after.
                                if mine { Badge(localised: "this device", tint: .green) }
                                if !token.isActive { Badge(localised: "inactive", tint: .secondary) }
                                ExpiryBadge(date: token.expiresAt)
                            }
                            // The prefix only. The secret is shown once, at
                            // mint time, and this app has no business
                            // displaying one even if the API offered it.
                            Text("\(token.prefix)… · \(token.scope)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("last used \(Date.relativeOrNever(token.lastUsedAt))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if mayRevokeTokens {
                                Button(role: .destructive) {
                                    revocationFailure = nil
                                    pending = .token(token, isThisDevice: mine)
                                } label: {
                                    Label("Revoke", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Access")
        .refreshable { await fetch(kind) }
        .task(id: kind) { await fetch(kind) }
        .sheet(item: $pending) { target in
            DeleteConfirmationSheet(
                subject: target.subject,
                title: target.title,
                consequence: target.consequence,
                caution: target.caution,
                failure: revocationFailure,
                isDeleting: isRevoking,
                onDelete: { Task { await revoke(target) } },
                onCancel: { pending = nil }
            )
        }
    }

    /// Whether this row is the credential this app is holding.
    ///
    /// Matched on the prefix the server itself publishes, and only when
    /// exactly one row carries it. Two rows sharing a prefix is unlikely, not
    /// impossible — and labelling the wrong one "this device" would aim the
    /// warning at precisely the operator it exists to protect, so an ambiguous
    /// match claims nothing.
    private func isThisDevice(
        _ token: Components.Schemas.ApiTokenResponse,
        among rows: [Components.Schemas.ApiTokenResponse]
    ) -> Bool {
        let prefix = session.tokenPrefix
        guard !prefix.isEmpty, token.prefix == prefix else { return false }
        return rows.count(where: { $0.prefix == prefix }) == 1
    }

    private func revoke(_ target: RevocationTarget) async {
        isRevoking = true
        revocationFailure = nil
        defer { isRevoking = false }

        do {
            switch target {
            case .token(let token, let isThisDevice):
                let response = try await session.client
                    .deleteTokenApiV1ApiTokensTokenIdDelete(path: .init(tokenId: token.id))
                switch response {
                case .noContent: break
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
                if case .loaded(let rows) = tokens {
                    tokens = .loaded(rows.filter { $0.id != token.id })
                }
                pending = nil
                // Revoking this device's own credential is a sign-out, so it
                // is reported as one. Every request after this point is a 401,
                // and staying here would render that as a wall of errors on a
                // screen the operator can no longer read.
                if isThisDevice { onSelfRevoked() }

            case .session(let row):
                let response = try await session.client
                    .revokeSessionApiV1SessionsSessionIdDelete(path: .init(sessionId: row.id))
                switch response {
                case .noContent: break
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
                if case .loaded(let rows) = sessions {
                    // The list shows revoked sessions with a badge rather than
                    // dropping them, so the row stays and reports its new state.
                    var revoked = row
                    revoked.revoked = true
                    sessions = .loaded(RowUpdate.apply(revoked, to: rows, id: \.id))
                }
                pending = nil
            }
        } catch {
            // A revocation carries no body the server could soft-conflict on,
            // so nothing here is ever offered as re-sendable.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                revocationFailure = message
            }
        }
    }

    private func load(_ kind: Kind) { Task { await fetch(kind) } }

    private func fetch(_ kind: Kind) async {
        switch kind {
        case .users:
            if case .loaded = users { return }
            users = .loading
            users = await LoadState.fetching {
                switch try await session.client.listUsersApiV1UsersGet() {
                case .ok(let ok):
                    return try ok.body.json.sorted {
                        $0.username.localizedStandardCompare($1.username) == .orderedAscending
                    }
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .sessions:
            if case .loaded = sessions { return }
            sessions = .loading
            sessions = await LoadState.fetching {
                switch try await session.client.listAllSessionsApiV1SessionsGet() {
                case .ok(let ok):
                    return try ok.body.json.sorted {
                        ($0.lastSeenAt ?? $0.createdAt) > ($1.lastSeenAt ?? $1.createdAt)
                    }
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .tokens:
            if case .loaded = tokens { return }
            tokens = .loading
            tokens = await LoadState.fetching {
                switch try await session.client.listTokensApiV1ApiTokensGet() {
                case .ok(let ok):
                    return try ok.body.json.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}

/// The audit log — what was done, by whom, and whether it worked.
struct AuditLogView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.AuditLogResponse]> = .idle
    @State private var total = 0

    var body: some View {
        List {
            LoadStateView(
                state: state, emptyMessage: "Nothing has been recorded.", retry: { Task { await fetch() } }
            ) { entries in
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.action).font(.subheadline.weight(.medium))
                            Spacer()
                            // A failed action in an audit log is the row worth
                            // finding, so it is coloured rather than uniform.
                            Badge(
                                text: entry.result,
                                tint: entry.result.lowercased() == "success" ? .green : .red
                            )
                        }
                        Text(entry.resourceDisplay.isEmpty ? entry.resourceType : entry.resourceDisplay)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(entry.userDisplayName)
                            if let ip = entry.sourceIp, !ip.isEmpty { Text(ip) }
                            Text(entry.timestamp.formatted(.relative(presentation: .named)))
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Audit Log")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listAuditLogApiV1AuditGet(query: .init(limit: 200)) {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                return page.items
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Soft-deleted rows, still restorable.
///
/// Restore is the one write here. Permanent removal stays off the phone: it is
/// the delete that cannot be walked back, and nothing about it is urgent.
struct TrashView: View {
    let session: ControlPlaneSession

    @Environment(Permissions.self) private var permissions

    @State private var state: LoadState<[Components.Schemas.TrashEntry]> = .idle
    /// The entry waiting on its confirmation.
    @State private var pendingRestore: Components.Schemas.TrashEntry?
    /// The alert's title, kept apart from `pendingRestore` so it doesn't read
    /// "Restore ?" while the alert animates away after that is cleared.
    @State private var restoreSubject = ""
    @State private var restoring: String?
    @State private var outcome: RestoreOutcome?

    /// The list and restore routes both depend on `SuperAdmin`.
    private var mayRestore: Bool { permissions.canDoSuperadminOnly }

    var body: some View {
        List {
            if let restoring {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Restoring \(restoring)…")
                    }
                }
            } else if let outcome {
                outcomeSection(outcome)
            }

            LoadStateView(
                state: state, emptyMessage: "Trash is empty.", retry: { Task { await fetch() } }
            ) { entries in
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.nameOrCidr).font(.body.monospaced()).lineLimit(1)
                            Spacer(minLength: 4)
                            Badge(text: entry._type, tint: .indigo)
                        }
                        HStack(spacing: 8) {
                            if let by = entry.deletedByUsername, !by.isEmpty { Text("by \(by)") }
                            Text(entry.deletedAt.formatted(.relative(presentation: .named)))
                            // A cascade delete took other rows with it, and
                            // restoring brings them all back — worth knowing
                            // before anyone reaches for the web console.
                            if entry.batchSize > 1 {
                                Text("^[\(entry.batchSize) row](inflect: true) in this deletion")
                            }
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if mayRestore {
                            Button {
                                outcome = nil
                                restoreSubject = entry.nameOrCidr
                                pendingRestore = entry
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                            .disabled(restoring != nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Trash")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
        .alert(
            "Restore \(restoreSubject)?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Restore") { Task { await restore(entry) } }
        } message: { entry in
            Text(
                verbatim: TrashRestore.subject(type: entry._type, name: entry.nameOrCidr) + "\n\n"
                    + TrashRestore.consequence(type: entry._type, batchSize: entry.batchSize)
            )
        }
    }

    @ViewBuilder
    private func outcomeSection(_ outcome: RestoreOutcome) -> some View {
        switch outcome {
        case .restored(let name, let count):
            Section {
                Label {
                    if count > 1 {
                        Text("Restored \(name), with ^[\(count - 1) other row](inflect: true).")
                    } else {
                        Text("Restored \(name).")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        case .failed(let name, let message):
            Section {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } header: {
                Text("\(name) not restored")
            }
        case .refused(let name, let refusal):
            Section {
                Label {
                    if let message = refusal.message {
                        Text(verbatim: message)
                    } else {
                        Text("It would clash with something live.")
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
                ForEach(Array(refusal.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.footnote)
                }
            } header: {
                Text("\(name) not restored")
            } footer: {
                Text(
                    "Nothing in this deletion was restored. Rename or remove what it clashes with, then try again."
                )
            }
        }
    }

    private func restore(_ entry: Components.Schemas.TrashEntry) async {
        let name = entry.nameOrCidr
        restoring = name
        outcome = nil
        defer { restoring = nil }
        do {
            let response = try await session.client.restoreRowApiV1AdminTrashTypeRowIdRestorePost(
                path: .init(_type: entry._type, rowId: entry.id)
            )
            switch response {
            case .ok(let ok):
                let result = try ok.body.json
                outcome = .restored(name: name, count: result.restored)
                await fetch()
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                // A clash is the expected refusal and the most useful one to
                // read in full, so its body is parsed before the generic path.
                if statusCode == 409, let body = payload.body,
                    let data = try? await Data(collecting: body, upTo: 64 * 1024)
                {
                    if let refusal = TrashRestoreRefusal.parse(data) {
                        outcome = .refused(name: name, refusal)
                        return
                    }
                    throw await APIStatusError(status: statusCode, body: HTTPBody(data))
                }
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                outcome = .failed(name: name, message)
            }
        }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listTrashApiV1AdminTrashGet(query: .init(limit: 200)) {
            case .ok(let ok):
                let page = try ok.body.json
                return page.items.sorted { $0.deletedAt > $1.deletedAt }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// How the last restore went. Held in memory for the screen's life only.
private enum RestoreOutcome {
    case restored(name: String, count: Int)
    case refused(name: String, TrashRestoreRefusal)
    case failed(name: String, FailureMessage)
}
