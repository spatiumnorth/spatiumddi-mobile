//
//  SelfServiceRequestsView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Self-service requests (platform #696): someone asked for an address, a
/// subnet, a DNS record or a DHCP reservation they cannot create themselves,
/// and it is waiting on an approver who can.
///
/// The sibling of Change Requests, not a tab inside it, because the platform
/// keeps them apart: separate endpoints, a separate feature module
/// (`governance.requests`), and a separate audience — a Requester holds no
/// grant on change requests at all, and would find a combined screen half
/// refusing them. The web console puts this at the top level for the same
/// reason. Approving is the opposite direction of privilege to a change
/// request, too: it *provisions*, under the approver's account.
///
/// Who sees what is the server's call — someone without the approve grant is
/// scoped to their own rows whatever the app asks for — so nothing here is
/// load-bearing for authorisation.
struct SelfServiceRequestsView: View {
    let session: ControlPlaneSession

    @Environment(Permissions.self) private var permissions
    @State private var state: LoadState<[Components.Schemas.ProvisioningRequestResponse]> = .idle
    @State private var stateFilter: String? = "pending"

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: String(localized: "All"), selected: stateFilter == nil) {
                            stateFilter = nil
                        }
                        ForEach(ProvisioningRequestState.filters, id: \.self) { value in
                            FilterChip(
                                label: ProvisioningRequestState.label(value).map { String(localized: $0) }
                                    ?? value,
                                selected: stateFilter == value
                            ) {
                                stateFilter = stateFilter == value ? nil : value
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: stateFilter == "pending"
                        ? "Nothing is waiting for a decision."
                        : "No requests recorded.",
                    retry: load
                ) { requests in
                    ForEach(requests, id: \.id) { request in
                        NavigationLink {
                            SelfServiceRequestDetailView(
                                session: session,
                                request: request,
                                onDecided: settle
                            )
                        } label: {
                            SelfServiceRequestRow(request: request)
                        }
                    }
                }
            } footer: {
                // The server narrows the list silently, so say so — otherwise
                // a requester reads "nothing pending" as the whole queue.
                if !permissions.can("approve", on: "change_request") {
                    Text("You see your own requests. Approvers see everyone's.")
                }
            }
        }
        .navigationTitle("Requests")
        .refreshable { await fetch() }
        .task(id: stateFilter) { await fetch() }
    }

    private func load() { Task { await fetch() } }

    /// Folds a decided request back into the list without a round trip. A row
    /// that no longer matches the filter leaves rather than sitting under a
    /// heading it now contradicts.
    private func settle(_ decided: Components.Schemas.ProvisioningRequestResponse) {
        guard case .loaded(let rows) = state else { return }
        state = .loaded(
            RowUpdate.apply(decided, to: rows, id: \.id) { row in
                guard let stateFilter else { return true }
                return row.state.caseInsensitiveCompare(stateFilter) == .orderedSame
            }
        )
    }

    private func fetch() async {
        let filter = stateFilter
        state = .loading
        let result = await LoadState.fetching {
            let response = try await session.client.listRequestsApiV1RequestsGet(
                query: .init(state: filter, limit: 100)
            )
            switch response {
            case .ok(let ok):
                return ProvisioningRequestState.sorted(
                    try ok.body.json,
                    state: \.state,
                    created: \.createdAt,
                    expires: \.expiresAt
                )
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
        // A pull-to-refresh is not cancelled when the filter changes, so it can
        // land after the fetch for the newer filter. Only the current one does.
        guard filter == stateFilter else { return }
        state = result
    }
}

extension Components.Schemas.ProvisioningRequestResponse {
    /// What it asks for, lifted out of the payload.
    var summary: ProvisioningSummary {
        ProvisioningSummary(
            operation: operation,
            args: ProvisioningArgs.flatten(args.additionalProperties),
            result: result.map { ProvisioningArgs.flatten($0.additionalProperties) } ?? [:]
        )
    }

    /// "IP address 10.0.5.10" — the kind in this app's words, the thing in the
    /// server's. Falls back to the server's own description of the request.
    var subject: String {
        let summary = summary
        guard let kind = summary.kind, !summary.headline.isEmpty else {
            return resourceDisplay.isEmpty ? resourceType : resourceDisplay
        }
        return String(localized: kind) + " " + summary.headline
    }
}

/// A state word: this app's label where it has one, the server's otherwise.
private struct RequestStateBadge: View {
    let state: String

    var body: some View {
        if let label = ProvisioningRequestState.label(state) {
            Badge(localised: label, tint: ProvisioningRequestState.tint(state))
        } else {
            Badge(text: state, tint: ProvisioningRequestState.tint(state))
        }
    }
}

private struct SelfServiceRequestRow: View {
    let request: Components.Schemas.ProvisioningRequestResponse

    var body: some View {
        let summary = request.summary
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: summary.headline.isEmpty ? request.resourceType : summary.headline)
                    .font(.subheadline.weight(.semibold).monospaced())
                    .lineLimit(1)
                Spacer(minLength: 4)
                RequestStateBadge(state: request.state)
            }
            Text(verbatim: request.previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let kind = summary.kind { Text(kind) }
                Text("by \(request.requestedByDisplay)")
                if ProvisioningRequestState.isPending(request.state) {
                    // The deadline is the actionable part of a pending request.
                    Text("expires \(request.expiresAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(Expiry(request.expiresAt).tint)
                } else {
                    Text(request.createdAt.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// One request in full — what it would create, who asked and why — and the
/// decision it is waiting for.
struct SelfServiceRequestDetailView: View {
    let session: ControlPlaneSession
    /// Called with the row the server returned, so the list behind this screen
    /// stops showing a decision that has already been made.
    let onDecided: (Components.Schemas.ProvisioningRequestResponse) -> Void

    @Environment(Permissions.self) private var permissions
    @State private var request: Components.Schemas.ProvisioningRequestResponse
    @State private var model: RequestDecisionModel

    init(
        session: ControlPlaneSession,
        request: Components.Schemas.ProvisioningRequestResponse,
        onDecided: @escaping (Components.Schemas.ProvisioningRequestResponse) -> Void = { _ in }
    ) {
        self.session = session
        self.onDecided = onDecided
        _request = State(initialValue: request)
        _model = State(initialValue: RequestDecisionModel(session: session, requestID: request.id))
    }

    private var isRequester: Bool { permissions.isMe(request.requestedByUserId) }
    private var mayDecide: Bool { permissions.can("approve", on: "change_request") }

    private var approveBlock: ProvisioningRequestRules.Block? {
        let needed = ProvisioningRequestRules.requiredPermission(forOperation: request.operation)
        return ProvisioningRequestRules.blocksApproving(
            state: request.state,
            expiresAt: request.expiresAt,
            hasRequester: !(request.requestedByUserId ?? "").isEmpty,
            isRequester: isRequester,
            mayDecide: mayDecide,
            mayRunOperation: needed.map { permissions.can($0.action, on: $0.resourceType) } ?? true,
            operation: request.operation
        )
    }

    private var rejectBlock: ProvisioningRequestRules.Block? {
        ProvisioningRequestRules.blocksRejecting(
            state: request.state, isRequester: isRequester, mayDecide: mayDecide
        )
    }

    private var cancelBlock: ProvisioningRequestRules.Block? {
        ProvisioningRequestRules.blocksCancelling(
            state: request.state, isRequester: isRequester, isSuperadmin: permissions.isSuperadmin
        )
    }

    var body: some View {
        let summary = request.summary
        List {
            // A failed provision first. Approving returns success even when
            // the provisioning step then fails — the row comes back `failed`
            // with the reason — so a decision that "worked" can still have
            // created nothing, and that must not hide at the foot of a screen.
            if let error = request.error, !error.isEmpty {
                Section("Provisioning failed") {
                    Label {
                        Text(verbatim: error).font(.callout).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                    }
                    .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("State") { RequestStateBadge(state: request.state) }
                LabeledContent("Kind") {
                    if let kind = summary.kind { Text(kind) } else { Text(verbatim: request.resourceType) }
                }
                if let line = summary.zoneFileLine {
                    Text(verbatim: line)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                ForEach(summary.fields, id: \.key) { field in
                    LabeledContent {
                        Text(verbatim: field.value).textSelection(.enabled)
                    } label: {
                        if let label = field.label { Text(label) } else { Text(verbatim: field.key) }
                    }
                }
            } header: {
                Text("What it asks for")
            }

            // The server's own sentence, which is the only place the parent —
            // the subnet, the zone, the scope — is named: the payload carries
            // its UUID.
            Section("What approving would do") {
                Text(verbatim: request.previewText)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            if let justification = request.justification, !justification.isEmpty {
                Section("Why they need it") {
                    Text(verbatim: justification)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            Section("Requested") {
                LabeledContent("By") { Text(verbatim: request.requestedByDisplay) }
                LabeledContent("At", value: request.createdAt.formatted(date: .abbreviated, time: .shortened))
                if ProvisioningRequestState.isPending(request.state) {
                    LabeledContent("Expires") {
                        Text(request.expiresAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(Expiry(request.expiresAt).tint)
                    }
                }
            }

            if request.decidedAt != nil || request.decidedByDisplay != nil {
                Section("Decision") {
                    if let by = request.decidedByDisplay {
                        LabeledContent("By") { Text(verbatim: by) }
                    }
                    if let at = request.decidedAt {
                        LabeledContent("At", value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let at = request.executedAt {
                        LabeledContent(
                            "Provisioned", value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let note = request.decisionNote, !note.isEmpty {
                        LabeledContent("Note") { Text(verbatim: note) }
                    }
                }
            }

            decideSection
            withdrawSection

            if let failure = model.failure {
                Section("Not decided") {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableKeyboard()
        .alert(
            Text(model.pending?.confirmationTitle ?? LocalizedStringResource("Confirm")),
            isPresented: Binding(
                get: { model.pending != nil },
                set: { if !$0 { model.pending = nil } }
            ),
            presenting: model.pending
        ) { decision in
            Button("Cancel", role: .cancel) { model.pending = nil }
            Button(role: decision == .approve ? nil : .destructive) {
                Task { await decide(decision) }
            } label: {
                Text(decision.confirmationVerb)
            }
        } message: { decision in
            // Names the actual thing — the address and its subnet, the record
            // line — never "are you sure".
            Text(
                verbatim: decision.consequence(
                    subject: request.subject,
                    preview: request.previewText,
                    requester: request.requestedByDisplay
                )
            )
        }
        .overlay {
            if model.isSending {
                ProgressView().controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var decideSection: some View {
        if approveBlock == nil || rejectBlock == nil {
            Section {
                // The note is the decision's own record: it lands in the audit
                // row, and the requester reads it on their copy of the request.
                TextField("Note (optional)", text: $model.note, axis: .vertical)
                    .lineLimit(1...3)
                if approveBlock == nil {
                    Button {
                        model.confirm(.approve)
                    } label: {
                        Label("Approve and Provision", systemImage: "checkmark.seal")
                    }
                    .disabled(model.isSending)
                }
                if rejectBlock == nil {
                    Button(role: .destructive) {
                        model.confirm(.reject)
                    } label: {
                        Label("Reject", systemImage: "xmark.seal")
                    }
                    .disabled(model.isSending)
                }
                // Reject can be on offer while Approve is not — a missing
                // operation grant, a lapsed deadline. Say why in place.
                if let block = approveBlock {
                    blockLabel(block)
                }
            } header: {
                Text("Decide")
            } footer: {
                if approveBlock == nil {
                    Text(
                        "Approving creates this now, under your account. Rejecting declines it and creates nothing. The requester sees your note."
                    )
                } else {
                    Text("Rejecting declines it and creates nothing. The requester sees your note.")
                }
            }
        } else if let block = approveBlock, ProvisioningRequestState.isPending(request.state) {
            // A pending request with no visible action and no explanation reads
            // as a screen that forgot to finish loading.
            Section("Decide") { blockLabel(block) }
        }
    }

    @ViewBuilder
    private var withdrawSection: some View {
        if cancelBlock == nil {
            Section {
                Button(role: .destructive) {
                    model.confirm(.cancel)
                } label: {
                    Label("Withdraw This Request", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.isSending)
            } footer: {
                Text("Withdrawing takes it off the approvers' queue. Nothing is created.")
            }
        }
    }

    private func blockLabel(_ block: ProvisioningRequestRules.Block) -> some View {
        Label {
            Text(explanation(for: block))
        } icon: {
            Image(systemName: block.symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func decide(_ decision: RequestDecisionModel.Decision) async {
        if let decided = await model.send(decision) {
            request = decided
            onDecided(decided)
        } else if let current = await model.reload() {
            // Refused — very often because someone else decided first, or the
            // deadline passed. Show the row as it is now, so the screen stops
            // offering a decision the server has already closed.
            request = current
            onDecided(current)
        }
    }

    /// The refusal, in the operator's terms rather than the grammar's.
    private func explanation(for block: ProvisioningRequestRules.Block) -> LocalizedStringResource {
        switch block {
        case .ownRequest:
            "This is your own request. Someone else has to decide it — you can withdraw it instead."
        case .noGrant:
            "Deciding requests needs the approve permission on change requests on this control plane."
        case .missingGrant(let action, let resourceType):
            "Approving creates this under your account, so it also needs \(action) on \(resourceType) — the same permission as creating it yourself."
        case .lapsed:
            "This request's deadline has passed, so it can no longer be approved."
        case .orphaned:
            "The account that asked for this no longer exists, so the platform won't provision it."
        case .notYours:
            "Only the person who asked for this can withdraw it."
        case .settled(let state):
            "This request is \(state). There is nothing left to decide."
        }
    }
}

extension ProvisioningRequestRules.Block {
    var symbol: String {
        switch self {
        case .ownRequest: "person.crop.circle.badge.exclamationmark"
        case .noGrant, .missingGrant: "lock"
        case .lapsed: "clock.badge.xmark"
        case .orphaned: "person.slash"
        case .notYours: "person.2.slash"
        case .settled: "checkmark.circle"
        }
    }
}

/// Sending one decision on a self-service request, and what came back if it
/// wasn't taken.
@MainActor
@Observable
final class RequestDecisionModel {
    enum Decision: Identifiable, Equatable {
        case approve
        case reject
        case cancel

        var id: Self { self }

        var confirmationTitle: LocalizedStringResource {
            switch self {
            case .approve: "Approve and create this?"
            case .reject: "Reject this request?"
            case .cancel: "Withdraw this request?"
            }
        }

        var confirmationVerb: LocalizedStringResource {
            switch self {
            case .approve: "Approve"
            case .reject: "Reject"
            case .cancel: "Withdraw"
            }
        }

        /// What happens, stated as fact, naming the thing.
        ///
        /// `subject`, `preview` and `requester` are the server's text and go
        /// in verbatim; only the framing is this app's.
        func consequence(subject: String, preview: String, requester: String) -> String {
            switch self {
            case .approve:
                String(localized: "This is created now, under your account, for \(requester):")
                    + "\n\n" + subject + "\n\n" + preview
            case .reject:
                subject + "\n\n"
                    + String(localized: "Declined for \(requester). Nothing is created.")
            case .cancel:
                subject + "\n\n"
                    + String(localized: "It comes off the approvers' queue. Nothing is created.")
            }
        }
    }

    var note = ""
    var pending: Decision?
    private(set) var isSending = false
    private(set) var failure: FailureMessage?

    private let session: ControlPlaneSession
    private let requestID: String

    init(session: ControlPlaneSession, requestID: String) {
        self.session = session
        self.requestID = requestID
    }

    func confirm(_ decision: Decision) {
        failure = nil
        pending = decision
    }

    /// Sends the decision. Returns the row the server settled on, or nil.
    ///
    /// A success can still be a `failed` row — approving returns 200 when the
    /// provisioning step then fails — and the detail screen leads with it.
    func send(_ decision: Decision) async -> Components.Schemas.ProvisioningRequestResponse? {
        pending = nil
        isSending = true
        failure = nil
        defer { isSending = false }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Components.Schemas.DecisionBody(decisionNote: trimmed.isEmpty ? nil : trimmed)

        do {
            // Three near-identical switches: each route generates its own
            // Output enum, and the cases only look alike.
            switch decision {
            case .approve:
                switch try await session.client.approveRequestApiV1RequestsReqIdApprovePost(
                    path: .init(reqId: requestID), body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            case .reject:
                switch try await session.client.rejectRequestApiV1RequestsReqIdRejectPost(
                    path: .init(reqId: requestID), body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            case .cancel:
                switch try await session.client.cancelRequestApiV1RequestsReqIdCancelPost(
                    path: .init(reqId: requestID), body: .json(body)
                ) {
                case .ok(let ok): return try ok.body.json
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        } catch {
            // No soft-conflict path: a 409 is a lost race, a lapsed deadline
            // or a stale preview, all final for this attempt. `forced` keeps
            // anything from offering to re-send it. A change window's 503 and
            // a 403 come through worded for a write, the server's own detail
            // verbatim where it gave one.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
            return nil
        }
    }

    /// The row as the server has it now, best-effort. Nil on any failure —
    /// this only tidies up after a refusal that has already been reported.
    func reload() async -> Components.Schemas.ProvisioningRequestResponse? {
        guard
            case .ok(let ok) = try? await session.client.getRequestApiV1RequestsReqIdGet(
                path: .init(reqId: requestID)
            )
        else { return nil }
        return try? ok.body.json
    }
}
